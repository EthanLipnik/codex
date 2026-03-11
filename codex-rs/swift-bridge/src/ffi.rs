use std::ffi::CStr;
use std::ffi::CString;
use std::os::raw::c_char;
use std::time::Duration;

use crate::BridgeConfig;
use crate::BridgeError;
use crate::CodexSwiftBridge;

fn write_error(error_out: *mut *mut c_char, error: BridgeError) {
    if error_out.is_null() {
        return;
    }

    // Safety: caller owns `error_out` and expects either null or a heap string
    // that must be released with `codex_swift_bridge_free_string`.
    unsafe {
        *error_out = into_raw_c_string(error.to_string());
    }
}

fn clear_error(error_out: *mut *mut c_char) {
    if error_out.is_null() {
        return;
    }

    // Safety: caller owns `error_out`.
    unsafe {
        *error_out = std::ptr::null_mut();
    }
}

fn sanitize_c_string(message: String) -> String {
    message.replace('\0', " ")
}

fn into_raw_c_string(value: String) -> *mut c_char {
    match CString::new(sanitize_c_string(value)) {
        Ok(value) => value.into_raw(),
        Err(_) => CString::default().into_raw(),
    }
}

fn string_from_ptr(ptr: *const c_char, context: &str) -> Result<String, BridgeError> {
    if ptr.is_null() {
        return Err(BridgeError::new(format!("missing {context} string")));
    }

    // Safety: caller promises a valid NUL-terminated UTF-8 string.
    let c_string = unsafe { CStr::from_ptr(ptr) };
    c_string
        .to_str()
        .map(str::to_owned)
        .map_err(|error| BridgeError::new(format!("invalid UTF-8 {context}: {error}")))
}

#[unsafe(no_mangle)]
pub extern "C" fn codex_swift_bridge_create(
    config_json: *const c_char,
    error_out: *mut *mut c_char,
) -> *mut CodexSwiftBridge {
    clear_error(error_out);

    let result = string_from_ptr(config_json, "bridge config")
        .and_then(|config_json| {
            serde_json::from_str::<BridgeConfig>(&config_json).map_err(BridgeError::from)
        })
        .and_then(CodexSwiftBridge::start);

    match result {
        Ok(bridge) => Box::into_raw(Box::new(bridge)),
        Err(error) => {
            write_error(error_out, error);
            std::ptr::null_mut()
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn codex_swift_bridge_send(
    bridge: *mut CodexSwiftBridge,
    payload_json: *const c_char,
    error_out: *mut *mut c_char,
) -> bool {
    clear_error(error_out);

    if bridge.is_null() {
        write_error(error_out, BridgeError::new("bridge handle is null"));
        return false;
    }

    let result = string_from_ptr(payload_json, "JSON-RPC payload").and_then(|payload| {
        // Safety: null was checked above and the handle remains owned by the caller.
        unsafe { &*bridge }.send(&payload)
    });
    if let Err(error) = result {
        write_error(error_out, error);
        return false;
    }
    true
}

#[unsafe(no_mangle)]
pub extern "C" fn codex_swift_bridge_recv(
    bridge: *mut CodexSwiftBridge,
    timeout_millis: u32,
    error_out: *mut *mut c_char,
) -> *mut c_char {
    clear_error(error_out);

    if bridge.is_null() {
        write_error(error_out, BridgeError::new("bridge handle is null"));
        return std::ptr::null_mut();
    }

    let result = unsafe { &*bridge }.recv(Duration::from_millis(u64::from(timeout_millis)));
    match result {
        Ok(Some(message)) => into_raw_c_string(message),
        Ok(None) => std::ptr::null_mut(),
        Err(error) => {
            write_error(error_out, error);
            std::ptr::null_mut()
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn codex_swift_bridge_destroy(bridge: *mut CodexSwiftBridge) {
    if bridge.is_null() {
        return;
    }

    // Safety: caller is transferring ownership back for destruction.
    let bridge = unsafe { Box::from_raw(bridge) };
    let _ = bridge.close();
}

#[unsafe(no_mangle)]
pub extern "C" fn codex_swift_bridge_free_string(value: *mut c_char) {
    if value.is_null() {
        return;
    }

    // Safety: strings returned by this library are allocated with `CString::into_raw`.
    unsafe {
        drop(CString::from_raw(value));
    }
}
