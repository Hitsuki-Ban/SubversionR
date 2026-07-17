#![recursion_limit = "256"]

use std::ffi::{c_int, c_void};
use std::io::{self, BufRead, Write};

use serde_json::{Value, json};

pub fn run_daemon(
    protocol_minor: u64,
    backend_version: &str,
    bridge_version: &str,
) -> io::Result<()> {
    let stdin = io::stdin();
    let mut reader = stdin.lock();
    let stdout = io::stdout();
    let mut writer = stdout.lock();

    loop {
        let Some(request) = read_frame(&mut reader)? else {
            return Ok(());
        };
        let id = request.get("id").cloned().unwrap_or(Value::Null);
        let method = request.get("method").and_then(Value::as_str).unwrap_or("");
        let (response, shutdown) = match method {
            "initialize" => (
                json!({
                    "jsonrpc": "2.0",
                    "id": id,
                    "result": initialize_result(protocol_minor, backend_version, bridge_version),
                }),
                false,
            ),
            "repository/discover" => (
                json!({
                    "jsonrpc": "2.0",
                    "id": id,
                    "result": {
                        "candidates": [],
                        "fileExternalBoundaries": [],
                    },
                }),
                false,
            ),
            "shutdown" => (
                json!({
                    "jsonrpc": "2.0",
                    "id": id,
                    "result": { "accepted": true },
                }),
                true,
            ),
            _ => (
                json!({
                    "jsonrpc": "2.0",
                    "id": id,
                    "error": {
                        "code": "RPC_METHOD_NOT_FOUND",
                        "message": "RPC_METHOD_NOT_FOUND",
                    },
                }),
                false,
            ),
        };
        write_frame(&mut writer, &response)?;
        if shutdown {
            return Ok(());
        }
    }
}

fn initialize_result(protocol_minor: u64, backend_version: &str, bridge_version: &str) -> Value {
    json!({
        "protocol": { "major": 1, "minor": protocol_minor },
        "backendVersion": backend_version,
        "bridgeVersion": bridge_version,
        "libsvnVersion": "fixture",
        "platform": { "os": "windows", "arch": "x86_64" },
        "cacheSchema": {
            "schemaId": "subversionr.cache.v1",
            "version": 1,
            "rollback": "delete-and-reconcile",
        },
        "capabilities": {
            "contentLengthFraming": true,
            "realLibsvnBridge": true,
            "repositoryDiscover": true,
            "repositoryOpen": true,
            "repositoryClose": true,
            "repositoryCheckout": true,
            "statusSnapshot": true,
            "statusRefresh": true,
            "statusRemoteCheck": true,
            "statusStaleNotification": true,
            "contentGet": true,
            "contentGetRevision": true,
            "historyLog": true,
            "historyBlame": true,
            "operationRun": true,
            "operationRunAdd": true,
            "operationRunRemove": true,
            "operationRunMove": true,
            "operationRunCleanup": true,
            "operationRunResolve": true,
            "operationRunUpdate": true,
            "operationRunUpdateSelectedPath": true,
            "operationRunUpdateToRevision": true,
            "operationRunUpdateDepth": true,
            "operationRunUpdateExternalsPolicy": true,
            "propertiesList": true,
            "operationRunPropertySet": true,
            "operationRunPropertyDelete": true,
            "ignore": true,
            "operationRunChangelistSet": true,
            "operationRunChangelistClear": true,
            "operationRunLock": true,
            "operationRunUnlock": true,
            "operationRunBranchCreate": true,
            "operationRunSwitch": true,
            "operationRunCommit": true,
            "operationRunCommitMultiPath": true,
            "diagnosticsGet": true,
            "credentialRequest": true,
            "certificateRequest": true,
            "remoteOperationEnvelope": true,
            "trustedConfigSnapshot": true,
        },
        "acknowledgedTrustEpoch": 1,
    })
}

fn read_frame(reader: &mut impl BufRead) -> io::Result<Option<Value>> {
    let mut content_length = None;
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line)? == 0 {
            return Ok(None);
        }
        let line = line.trim_end_matches(['\r', '\n']);
        if line.is_empty() {
            break;
        }
        if let Some(value) = line.strip_prefix("Content-Length:") {
            content_length = Some(
                value
                    .trim()
                    .parse::<usize>()
                    .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?,
            );
        }
    }
    let length = content_length
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "Content-Length is required"))?;
    let mut body = vec![0; length];
    reader.read_exact(&mut body)?;
    serde_json::from_slice(&body)
        .map(Some)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
}

fn write_frame(writer: &mut impl Write, response: &Value) -> io::Result<()> {
    let body = serde_json::to_vec(response).map_err(io::Error::other)?;
    write!(writer, "Content-Length: {}\r\n\r\n", body.len())?;
    writer.write_all(&body)?;
    writer.flush()
}

#[unsafe(no_mangle)]
pub extern "C" fn subversionr_bridge_runtime_create(_runtime: *mut *mut c_void) -> c_int {
    0
}

#[unsafe(no_mangle)]
pub extern "C" fn subversionr_bridge_runtime_destroy(_runtime: *mut c_void) {}

#[unsafe(no_mangle)]
pub extern "C" fn subversionr_bridge_version() -> *const c_void {
    std::ptr::null()
}

// Deliberately omit subversionr_bridge_last_error_diagnostics. The release test
// uses this cdylib to prove that the current daemon rejects an incomplete C ABI.
