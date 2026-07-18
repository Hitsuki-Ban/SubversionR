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
    let mut remote_worker_operation_completed = false;

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
            "repository/checkout" => {
                if strict_remote_checkout_request(&request) {
                    remote_worker_operation_completed = true;
                    (
                        json!({
                            "jsonrpc": "2.0",
                            "id": id,
                            "error": {
                                "code": "SUBVERSIONR_REMOTE_TRANSPORT_UNSUPPORTED",
                                "category": "unsupported",
                                "messageKey": "error.remote.transportUnsupported",
                                "args": { "scheme": "https" },
                                "retryable": false,
                                "diagnostics": null,
                            },
                        }),
                        false,
                    )
                } else {
                    (
                        invalid_request(id, "SUBVERSIONR_REMOTE_ENVELOPE_INVALID"),
                        false,
                    )
                }
            }
            "diagnostics/get" => {
                if remote_worker_operation_completed {
                    (
                        json!({
                            "jsonrpc": "2.0",
                            "id": id,
                            "result": {
                                "protocol": { "major": 1, "minor": protocol_minor },
                                "backendVersion": backend_version,
                                "bridgeVersion": bridge_version,
                                "libsvnVersion": "fixture",
                                "capabilities": initialize_result(protocol_minor, backend_version, bridge_version)["capabilities"].clone(),
                                "source": "subversionr-daemon",
                            },
                        }),
                        false,
                    )
                } else {
                    (
                        invalid_request(id, "SUBVERSIONR_REMOTE_WORKER_EVIDENCE_MISSING"),
                        false,
                    )
                }
            }
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

fn strict_remote_checkout_request(request: &Value) -> bool {
    let Some(params) = request.get("params") else {
        return false;
    };
    let Some(target_path) = params.get("targetPath").and_then(Value::as_str) else {
        return false;
    };
    let Some(operation_id) = params
        .get("remote")
        .and_then(|remote| remote.get("operationId"))
        .and_then(Value::as_str)
        .filter(|operation_id| {
            matches!(
                *operation_id,
                "12700000-0000-4000-8000-000000000003"
                    | "12700000-0000-4000-8000-000000000004"
            )
        })
    else {
        return false;
    };
    if !target_path.ends_with("packaged-native-worker-target") {
        return false;
    }
    let endpoint = json!({
        "scheme": "https",
        "canonicalHost": "svn.example.invalid",
        "effectivePort": 443,
    });
    *params
        == json!({
            "url": "https://svn.example.invalid/project/trunk",
            "targetPath": target_path,
            "revision": "head",
            "depth": "infinity",
            "ignoreExternals": true,
            "remote": {
                "version": 1,
                "operationId": operation_id,
                "intent": "foreground",
                "interaction": "forbidden",
                "timeoutMs": 10000,
                "workspaceTrust": "trusted",
                "trustEpoch": 1,
                "profile": {
                    "schema": "subversionr.remote-profile.v1",
                    "profileId": "packaged-native-worker",
                    "authority": endpoint,
                    "serverAuth": "anonymous",
                    "serverAccount": "none",
                    "serverCredentialPersistence": "secretStorage",
                    "tls": { "trust": "windowsRootsThenBroker" },
                    "proxy": "none",
                    "ssh": "none",
                    "redirectPolicy": "rejectAll",
                },
                "expectedOrigin": endpoint,
            },
        })
}

fn invalid_request(id: Value, code: &str) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "error": {
            "code": code,
            "category": "configuration",
            "messageKey": "error.remote.envelopeInvalid",
            "args": {},
            "retryable": false,
            "diagnostics": null,
        },
    })
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
            "remoteWorkerIsolation": true,
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
