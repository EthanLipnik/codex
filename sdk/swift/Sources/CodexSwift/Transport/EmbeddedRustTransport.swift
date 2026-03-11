#if canImport(CodexEmbeddedBridge)
import CodexEmbeddedBridge
import Foundation

private struct BridgeHandle: @unchecked Sendable, Equatable {
    let rawValue: OpaquePointer
}

public actor EmbeddedRustTransport: CodexTransporting {
    private let bridgeConfigurationJSON: String
    private var handle: BridgeHandle?
    private var receiveTask: Task<Void, Never>?
    private var isClosing = false

    public init(
        runtimeConfiguration: CodexEmbeddedRuntimeConfiguration = CodexEmbeddedRuntimeConfiguration(),
        clientInfo: CodexClientInfo = CodexClientInfo(),
        experimentalAPI: Bool = true
    ) {
        let bridgeConfiguration = runtimeConfiguration.bridgeConfiguration(
            clientInfo: clientInfo,
            experimentalAPI: experimentalAPI
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let payload = try? encoder.encode(bridgeConfiguration)
        self.bridgeConfigurationJSON = payload.map {
            String(decoding: $0, as: UTF8.self)
        } ?? "{}"
    }

    public func connect(
        onEvent: @escaping @Sendable (String) async -> Void,
        onClose: @escaping @Sendable (Error?) async -> Void
    ) async throws {
        guard handle == nil else {
            return
        }

        let handle = BridgeHandle(
            rawValue: try Self.createBridgeHandle(configurationJSON: bridgeConfigurationJSON)
        )
        self.handle = handle
        isClosing = false

        receiveTask = Task.detached(priority: .utility) { [handle] in
            await Self.runReceiveLoop(
                handle: handle,
                onEvent: onEvent,
                onFailure: { error in
                    let shouldNotify = await self.markBridgeClosedIfNeeded(handle: handle)
                    if shouldNotify {
                        await onClose(error)
                    }
                }
            )
        }
    }

    public func send(_ payload: String) async throws {
        guard let handle else {
            throw CodexTransportError.notConnected
        }
        try Self.send(payload: payload, to: handle)
    }

    public func close() async {
        isClosing = true
        receiveTask?.cancel()
        _ = await receiveTask?.result
        receiveTask = nil

        guard let handle else {
            return
        }

        Self.destroy(handle)
        self.handle = nil
    }

    private static func runReceiveLoop(
        handle: BridgeHandle,
        onEvent: @escaping @Sendable (String) async -> Void,
        onFailure: @escaping @Sendable (Error) async -> Void
    ) async {
        while !Task.isCancelled {
            do {
                if let payload = try Self.receive(from: handle, timeoutMilliseconds: 250) {
                    await onEvent(payload)
                }
            } catch {
                await onFailure(error)
                return
            }
        }
    }

    private func markBridgeClosedIfNeeded(handle: BridgeHandle) -> Bool {
        guard !isClosing, self.handle == handle else {
            return false
        }
        self.handle = nil
        self.receiveTask = nil
        Self.destroy(handle)
        return true
    }

    private static func createBridgeHandle(configurationJSON: String) throws -> OpaquePointer {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let handle = configurationJSON.withCString { configurationCString in
            codex_swift_bridge_create(configurationCString, &errorPointer)
        }

        if let error = takeBridgeString(errorPointer) {
            throw CodexTransportError.closed(error)
        }
        guard let handle else {
            throw CodexTransportError.closed("Embedded Codex runtime failed to start.")
        }
        return handle
    }

    private static func destroy(_ handle: BridgeHandle) {
        codex_swift_bridge_destroy(handle.rawValue)
    }

    private static func send(payload: String, to handle: BridgeHandle) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let success = payload.withCString { payloadCString in
            codex_swift_bridge_send(handle.rawValue, payloadCString, &errorPointer)
        }
        if let error = takeBridgeString(errorPointer) {
            throw CodexTransportError.closed(error)
        }
        guard success else {
            throw CodexTransportError.closed("Embedded Codex runtime rejected the payload.")
        }
    }

    private static func receive(
        from handle: BridgeHandle,
        timeoutMilliseconds: UInt32
    ) throws -> String? {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let payloadPointer = codex_swift_bridge_recv(
            handle.rawValue,
            timeoutMilliseconds,
            &errorPointer
        )
        if let error = takeBridgeString(errorPointer) {
            throw CodexTransportError.closed(error)
        }
        return takeBridgeString(payloadPointer)
    }

    private static func takeBridgeString(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else {
            return nil
        }
        defer {
            codex_swift_bridge_free_string(pointer)
        }
        return String(cString: pointer)
    }
}

public extension CodexClient {
    /// Starts Codex using the embedded Rust runtime shipped with the Swift package.
    ///
    /// Use this from iOS when you want Codex running in-process instead of connecting to an
    /// external websocket server or launching a separate app-server process.
    static func embedded(
        runtimeConfiguration: CodexEmbeddedRuntimeConfiguration = CodexEmbeddedRuntimeConfiguration(),
        configuration: CodexConfiguration = CodexConfiguration()
    ) async throws -> CodexClient {
        let client = CodexClient(
            transport: EmbeddedRustTransport(
                runtimeConfiguration: runtimeConfiguration,
                clientInfo: configuration.clientInfo,
                experimentalAPI: configuration.experimentalAPI
            ),
            configuration: configuration
        )
        try await client.start()
        return client
    }
}
#endif
