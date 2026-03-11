use std::fmt;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::Mutex;
use std::sync::mpsc as std_mpsc;
use std::time::Duration;

use codex_app_server::in_process::DEFAULT_IN_PROCESS_CHANNEL_CAPACITY;
use codex_app_server::in_process::InProcessClientSender;
use codex_app_server::in_process::InProcessServerEvent;
use codex_app_server::in_process::InProcessStartArgs;
use codex_app_server_protocol::ClientInfo;
use codex_app_server_protocol::ClientNotification;
use codex_app_server_protocol::ClientRequest;
use codex_app_server_protocol::ConfigWarningNotification;
use codex_app_server_protocol::InitializeCapabilities;
use codex_app_server_protocol::InitializeParams;
use codex_app_server_protocol::InitializeResponse;
use codex_app_server_protocol::JSONRPCError;
use codex_app_server_protocol::JSONRPCErrorError;
use codex_app_server_protocol::JSONRPCMessage;
use codex_app_server_protocol::JSONRPCNotification;
use codex_app_server_protocol::JSONRPCRequest;
use codex_app_server_protocol::JSONRPCResponse;
use codex_arg0::Arg0DispatchPaths;
use codex_core::config::ConfigBuilder;
use codex_core::config_loader::CloudRequirementsLoader;
use codex_core::config_loader::LoaderOverrides;
use codex_core::default_client::get_codex_user_agent;
use codex_feedback::CodexFeedback;
use codex_protocol::protocol::SessionSource;
use serde::Deserialize;
use serde::Serialize;
use serde_json::json;
use tokio::runtime::Runtime;
use tokio::sync::mpsc;

const SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(5);
const READY_TIMEOUT: Duration = Duration::from_secs(30);
const INTERNAL_ERROR_CODE: i64 = -32603;
const INVALID_REQUEST_CODE: i64 = -32600;
const LAGGED_NOTIFICATION_METHOD: &str = "codex/bridge/lagged";

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum BridgeSessionSource {
    Cli,
    Exec,
    #[default]
    AppServer,
}

impl From<BridgeSessionSource> for SessionSource {
    fn from(value: BridgeSessionSource) -> Self {
        match value {
            BridgeSessionSource::Cli => SessionSource::Cli,
            BridgeSessionSource::Exec => SessionSource::Exec,
            BridgeSessionSource::AppServer => SessionSource::Mcp,
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BridgeConfig {
    pub client_name: Option<String>,
    pub client_version: Option<String>,
    pub codex_home: Option<PathBuf>,
    pub cwd: Option<PathBuf>,
    pub experimental_api: Option<bool>,
    pub enable_codex_api_key_env: Option<bool>,
    pub opt_out_notification_methods: Option<Vec<String>>,
    pub session_source: Option<BridgeSessionSource>,
    pub channel_capacity: Option<usize>,
}

impl BridgeConfig {
    fn normalized(mut self) -> Self {
        if self.cwd.is_none() {
            self.cwd = self.codex_home.clone();
        }
        self
    }

    fn client_name(&self) -> String {
        self.client_name
            .clone()
            .unwrap_or_else(|| "codex-swift-sdk".to_string())
    }

    fn client_version(&self) -> String {
        self.client_version
            .clone()
            .unwrap_or_else(|| env!("CARGO_PKG_VERSION").to_string())
    }

    fn experimental_api(&self) -> bool {
        self.experimental_api.unwrap_or(true)
    }

    fn enable_codex_api_key_env(&self) -> bool {
        self.enable_codex_api_key_env.unwrap_or(false)
    }

    fn opt_out_notification_methods(&self) -> Vec<String> {
        self.opt_out_notification_methods
            .clone()
            .unwrap_or_default()
    }

    fn session_source(&self) -> SessionSource {
        self.session_source.clone().unwrap_or_default().into()
    }

    fn channel_capacity(&self) -> usize {
        self.channel_capacity
            .unwrap_or(DEFAULT_IN_PROCESS_CHANNEL_CAPACITY)
            .max(1)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgeError {
    message: String,
}

impl BridgeError {
    pub(crate) fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }

    fn internal_error(message: impl Into<String>) -> JSONRPCErrorError {
        JSONRPCErrorError {
            code: INTERNAL_ERROR_CODE,
            message: message.into(),
            data: None,
        }
    }

    fn invalid_request(message: impl Into<String>) -> JSONRPCErrorError {
        JSONRPCErrorError {
            code: INVALID_REQUEST_CODE,
            message: message.into(),
            data: None,
        }
    }
}

impl fmt::Display for BridgeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.message.fmt(f)
    }
}

impl std::error::Error for BridgeError {}

impl From<std::io::Error> for BridgeError {
    fn from(value: std::io::Error) -> Self {
        Self::new(value.to_string())
    }
}

impl From<serde_json::Error> for BridgeError {
    fn from(value: serde_json::Error) -> Self {
        Self::new(value.to_string())
    }
}

enum BridgeCommand {
    Send {
        payload: String,
        reply_tx: std_mpsc::SyncSender<Result<(), BridgeError>>,
    },
    Shutdown {
        reply_tx: std_mpsc::SyncSender<Result<(), BridgeError>>,
    },
}

pub struct CodexSwiftBridge {
    command_tx: mpsc::Sender<BridgeCommand>,
    outbound_rx: Mutex<std_mpsc::Receiver<String>>,
    runtime: Mutex<Option<Runtime>>,
}

impl CodexSwiftBridge {
    pub fn start(config: BridgeConfig) -> Result<Self, BridgeError> {
        let config = config.normalized();
        if let Some(codex_home) = &config.codex_home {
            std::fs::create_dir_all(codex_home)?;
        }

        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .map_err(BridgeError::from)?;
        let (command_tx, command_rx) = mpsc::channel::<BridgeCommand>(config.channel_capacity());
        let (outbound_tx, outbound_rx) = std_mpsc::channel::<String>();
        let (ready_tx, ready_rx) = std_mpsc::sync_channel(1);

        runtime.spawn(run_bridge_worker(config, command_rx, outbound_tx, ready_tx));
        match ready_rx.recv_timeout(READY_TIMEOUT) {
            Ok(Ok(())) => Ok(Self {
                command_tx,
                outbound_rx: Mutex::new(outbound_rx),
                runtime: Mutex::new(Some(runtime)),
            }),
            Ok(Err(error)) => {
                runtime.shutdown_timeout(SHUTDOWN_TIMEOUT);
                Err(error)
            }
            Err(std_mpsc::RecvTimeoutError::Timeout) => {
                runtime.shutdown_timeout(SHUTDOWN_TIMEOUT);
                Err(BridgeError::new(
                    "timed out starting embedded Codex runtime",
                ))
            }
            Err(std_mpsc::RecvTimeoutError::Disconnected) => {
                runtime.shutdown_timeout(SHUTDOWN_TIMEOUT);
                Err(BridgeError::new(
                    "embedded Codex runtime exited before startup completed",
                ))
            }
        }
    }

    pub fn send(&self, payload: &str) -> Result<(), BridgeError> {
        let (reply_tx, reply_rx) = std_mpsc::sync_channel(1);
        self.command_tx
            .blocking_send(BridgeCommand::Send {
                payload: payload.to_string(),
                reply_tx,
            })
            .map_err(|_| BridgeError::new("embedded Codex runtime is closed"))?;
        reply_rx
            .recv()
            .map_err(|_| BridgeError::new("embedded Codex runtime did not acknowledge send"))?
    }

    pub fn recv(&self, timeout: Duration) -> Result<Option<String>, BridgeError> {
        let outbound_rx = self
            .outbound_rx
            .lock()
            .map_err(|_| BridgeError::new("embedded Codex outbound queue is poisoned"))?;
        match outbound_rx.recv_timeout(timeout) {
            Ok(message) => Ok(Some(message)),
            Err(std_mpsc::RecvTimeoutError::Timeout) => Ok(None),
            Err(std_mpsc::RecvTimeoutError::Disconnected) => {
                Err(BridgeError::new("embedded Codex runtime disconnected"))
            }
        }
    }

    pub fn close(&self) -> Result<(), BridgeError> {
        let mut runtime = self
            .runtime
            .lock()
            .map_err(|_| BridgeError::new("embedded Codex runtime state is poisoned"))?;
        let Some(runtime) = runtime.take() else {
            return Ok(());
        };

        let (reply_tx, reply_rx) = std_mpsc::sync_channel(1);
        if self
            .command_tx
            .blocking_send(BridgeCommand::Shutdown { reply_tx })
            .is_ok()
        {
            let _ = reply_rx.recv_timeout(SHUTDOWN_TIMEOUT);
        }

        runtime.shutdown_timeout(SHUTDOWN_TIMEOUT);
        Ok(())
    }
}

impl Drop for CodexSwiftBridge {
    fn drop(&mut self) {
        let _ = self.close();
    }
}

async fn run_bridge_worker(
    config: BridgeConfig,
    mut command_rx: mpsc::Receiver<BridgeCommand>,
    outbound_tx: std_mpsc::Sender<String>,
    ready_tx: std_mpsc::SyncSender<Result<(), BridgeError>>,
) {
    let start_args = match build_start_args(&config).await {
        Ok(start_args) => start_args,
        Err(error) => {
            let _ = ready_tx.send(Err(error));
            return;
        }
    };

    let mut handle = match codex_app_server::in_process::start(start_args).await {
        Ok(handle) => handle,
        Err(error) => {
            let _ = ready_tx.send(Err(BridgeError::new(error.to_string())));
            return;
        }
    };
    let sender = handle.sender();
    let _ = ready_tx.send(Ok(()));

    loop {
        tokio::select! {
            command = command_rx.recv() => match command {
                Some(BridgeCommand::Send { payload, reply_tx }) => {
                    let sender = sender.clone();
                    let outbound_tx = outbound_tx.clone();
                    tokio::spawn(async move {
                        let result = process_inbound_message(sender, outbound_tx, payload).await;
                        let _ = reply_tx.send(result);
                    });
                }
                Some(BridgeCommand::Shutdown { reply_tx }) => {
                    let result = handle.shutdown().await.map_err(BridgeError::from);
                    let _ = reply_tx.send(result);
                    break;
                }
                None => {
                    let _ = handle.shutdown().await;
                    break;
                }
            },
            event = handle.next_event() => match event {
                Some(event) => {
                    if forward_server_event(&outbound_tx, event).is_err() {
                        break;
                    }
                }
                None => break,
            }
        }
    }
}

async fn build_start_args(config: &BridgeConfig) -> Result<InProcessStartArgs, BridgeError> {
    let opt_out_notification_methods = config.opt_out_notification_methods();
    let mut builder = ConfigBuilder::default();
    if let Some(codex_home) = &config.codex_home {
        builder = builder.codex_home(codex_home.clone());
    }
    if let Some(cwd) = &config.cwd {
        builder = builder.fallback_cwd(Some(cwd.clone()));
    }

    let built_config = builder.build().await.map_err(BridgeError::from)?;
    Ok(InProcessStartArgs {
        arg0_paths: Arg0DispatchPaths::default(),
        config: Arc::new(built_config),
        cli_overrides: Vec::new(),
        loader_overrides: LoaderOverrides::default(),
        cloud_requirements: CloudRequirementsLoader::default(),
        feedback: CodexFeedback::new(),
        config_warnings: Vec::<ConfigWarningNotification>::new(),
        session_source: config.session_source(),
        enable_codex_api_key_env: config.enable_codex_api_key_env(),
        initialize: InitializeParams {
            client_info: ClientInfo {
                name: config.client_name(),
                title: None,
                version: config.client_version(),
            },
            capabilities: Some(InitializeCapabilities {
                experimental_api: config.experimental_api(),
                opt_out_notification_methods: if opt_out_notification_methods.is_empty() {
                    None
                } else {
                    Some(opt_out_notification_methods)
                },
            }),
        },
        channel_capacity: config.channel_capacity(),
    })
}

async fn process_inbound_message(
    sender: InProcessClientSender,
    outbound_tx: std_mpsc::Sender<String>,
    payload: String,
) -> Result<(), BridgeError> {
    let message: JSONRPCMessage = serde_json::from_str(&payload)?;
    match message {
        JSONRPCMessage::Request(request) => {
            handle_client_request(sender, outbound_tx, request).await
        }
        JSONRPCMessage::Notification(notification) => {
            handle_client_notification(sender, notification).await
        }
        JSONRPCMessage::Response(response) => sender
            .respond_to_server_request(response.id, response.result)
            .map_err(BridgeError::from),
        JSONRPCMessage::Error(error) => sender
            .fail_server_request(error.id, error.error)
            .map_err(BridgeError::from),
    }
}

async fn handle_client_request(
    sender: InProcessClientSender,
    outbound_tx: std_mpsc::Sender<String>,
    request: JSONRPCRequest,
) -> Result<(), BridgeError> {
    if request.method == "initialize" {
        return queue_message(
            &outbound_tx,
            JSONRPCMessage::Response(JSONRPCResponse {
                id: request.id,
                result: serde_json::to_value(InitializeResponse {
                    user_agent: get_codex_user_agent(),
                })?,
            }),
        );
    }

    let request_id = request.id.clone();
    let client_request =
        match serde_json::from_value::<ClientRequest>(serde_json::to_value(request)?) {
            Ok(client_request) => client_request,
            Err(error) => {
                return queue_message(
                    &outbound_tx,
                    JSONRPCMessage::Error(JSONRPCError {
                        id: request_id,
                        error: BridgeError::invalid_request(format!(
                            "invalid client request payload: {error}"
                        )),
                    }),
                );
            }
        };

    match sender.request(client_request).await {
        Ok(Ok(result)) => queue_message(
            &outbound_tx,
            JSONRPCMessage::Response(JSONRPCResponse {
                id: request_id,
                result,
            }),
        ),
        Ok(Err(error)) => queue_message(
            &outbound_tx,
            JSONRPCMessage::Error(JSONRPCError {
                id: request_id,
                error,
            }),
        ),
        Err(error) => queue_message(
            &outbound_tx,
            JSONRPCMessage::Error(JSONRPCError {
                id: request_id,
                error: BridgeError::internal_error(format!(
                    "embedded Codex request transport error: {error}"
                )),
            }),
        ),
    }
}

async fn handle_client_notification(
    sender: InProcessClientSender,
    notification: JSONRPCNotification,
) -> Result<(), BridgeError> {
    if notification.method == "initialized" {
        return Ok(());
    }

    let notification =
        serde_json::from_value::<ClientNotification>(serde_json::to_value(notification)?)?;
    sender.notify(notification).map_err(BridgeError::from)
}

fn forward_server_event(
    outbound_tx: &std_mpsc::Sender<String>,
    event: InProcessServerEvent,
) -> Result<(), BridgeError> {
    let message = match event {
        InProcessServerEvent::ServerRequest(request) => {
            JSONRPCMessage::Request(serde_json::from_value(serde_json::to_value(request)?)?)
        }
        InProcessServerEvent::ServerNotification(notification) => JSONRPCMessage::Notification(
            serde_json::from_value(serde_json::to_value(notification)?)?,
        ),
        InProcessServerEvent::LegacyNotification(notification) => {
            JSONRPCMessage::Notification(notification)
        }
        InProcessServerEvent::Lagged { skipped } => {
            JSONRPCMessage::Notification(JSONRPCNotification {
                method: LAGGED_NOTIFICATION_METHOD.to_string(),
                params: Some(json!({ "skipped": skipped })),
            })
        }
    };
    queue_message(outbound_tx, message)
}

fn queue_message(
    outbound_tx: &std_mpsc::Sender<String>,
    message: JSONRPCMessage,
) -> Result<(), BridgeError> {
    let payload = serde_json::to_string(&message)?;
    outbound_tx
        .send(payload)
        .map_err(|_| BridgeError::new("embedded Codex outbound queue is closed"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use codex_app_server_protocol::JSONRPCMessage;
    use pretty_assertions::assert_eq;
    use tempfile::TempDir;

    fn build_bridge(session_source: BridgeSessionSource) -> (CodexSwiftBridge, TempDir) {
        let codex_home = TempDir::new().expect("create temp codex home");
        let bridge = CodexSwiftBridge::start(BridgeConfig {
            client_name: Some("codex-swift-bridge-tests".to_string()),
            client_version: Some("0.0.0-test".to_string()),
            codex_home: Some(codex_home.path().to_path_buf()),
            cwd: Some(codex_home.path().to_path_buf()),
            experimental_api: Some(true),
            enable_codex_api_key_env: Some(false),
            opt_out_notification_methods: None,
            session_source: Some(session_source),
            channel_capacity: Some(32),
        })
        .expect("bridge should start");
        (bridge, codex_home)
    }

    fn recv_until<F>(bridge: &CodexSwiftBridge, predicate: F) -> JSONRPCMessage
    where
        F: Fn(&JSONRPCMessage) -> bool,
    {
        for _ in 0..20 {
            let payload = bridge
                .recv(Duration::from_secs(5))
                .expect("recv should succeed")
                .expect("expected outbound payload");
            let message: JSONRPCMessage =
                serde_json::from_str(&payload).expect("payload should decode");
            if predicate(&message) {
                return message;
            }
        }
        panic!("did not receive expected outbound payload");
    }

    #[test]
    fn initialize_round_trip_returns_user_agent() {
        let (bridge, _codex_home) = build_bridge(BridgeSessionSource::AppServer);

        bridge
            .send(
                r#"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"ios","version":"1.0.0"},"capabilities":{"experimentalApi":true}}}"#,
            )
            .expect("initialize should send");

        let message = recv_until(&bridge, |message| {
            matches!(
                message,
                JSONRPCMessage::Response(JSONRPCResponse {
                    id: codex_app_server_protocol::RequestId::Integer(1),
                    ..
                })
            )
        });

        let JSONRPCMessage::Response(response) = message else {
            panic!("expected initialize response");
        };
        let user_agent = response
            .result
            .get("userAgent")
            .and_then(serde_json::Value::as_str)
            .expect("userAgent should be present");
        assert!(!user_agent.is_empty(), "userAgent should not be empty");

        bridge.close().expect("bridge should close");
    }

    #[test]
    fn thread_start_uses_requested_session_source() {
        let (bridge, _codex_home) = build_bridge(BridgeSessionSource::AppServer);

        bridge
            .send(r#"{"id":2,"method":"thread/start","params":{"ephemeral":true}}"#)
            .expect("thread/start should send");

        let message = recv_until(&bridge, |message| {
            matches!(
                message,
                JSONRPCMessage::Response(JSONRPCResponse {
                    id: codex_app_server_protocol::RequestId::Integer(2),
                    ..
                })
            )
        });

        let JSONRPCMessage::Response(response) = message else {
            panic!("expected thread/start response");
        };
        let source = response
            .result
            .get("thread")
            .and_then(|thread| thread.get("source"))
            .and_then(serde_json::Value::as_str)
            .expect("thread source should be present");
        assert_eq!(source, "appServer");

        bridge.close().expect("bridge should close");
    }
}
