use serde::Deserialize;
use serde_json::{Value, json};
use std::path::Path;
use subversionr_protocol::{InitializeResponse, current_platform};
use time::{OffsetDateTime, format_description::well_known::Rfc3339};

mod bridge;
mod native;
mod state;
mod stdio;

pub use bridge::{
    AddOperationRequest, AuthRequestBroker, BranchCreateOperationRequest,
    BranchCreateOperationResult, BridgeApi, BridgeCancellationToken, BridgeFailure, BridgeInfo,
    ChangelistClearOperationRequest, ChangelistSetOperationRequest, CleanupOperationRequest,
    CommitOperationRequest, CommitOperationResult, ContentBlob, HistoryBlameRequest,
    HistoryBlameResult, HistoryLogRequest, HistoryLogResult, LockOperationRequest,
    MergeOperationRequest, MoveOperationRequest, NeverCancelled, OperationResult,
    PropertiesListResult, PropertyDeleteOperationRequest, PropertyEntry,
    PropertySetOperationRequest, RelocateOperationRequest, RemoveOperationRequest,
    RepositoryCheckoutRequest, RepositoryCheckoutResult, ResolveOperationRequest,
    RevertOperationRequest, SwitchOperationRequest, SwitchOperationResult,
    UnavailableAuthRequestBroker, UnavailableBridge, UnlockOperationRequest,
    UpdateOperationRequest, UpdateOperationResult, UpgradeOperationRequest,
};
pub use native::{NativeBridge, NativeBridgeLoadError};
pub use state::DaemonState;
pub use stdio::run_json_rpc_stdio;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DispatchOutcome {
    Continue,
    Shutdown,
}

#[derive(Debug, Clone, PartialEq)]
pub struct DispatchResult {
    outcome: DispatchOutcome,
    response: Value,
    notifications: Vec<Value>,
}

impl DispatchResult {
    pub fn outcome(&self) -> DispatchOutcome {
        self.outcome
    }

    pub fn response(&self) -> &Value {
        &self.response
    }

    pub fn notifications(&self) -> &[Value] {
        &self.notifications
    }
}

impl PartialEq<DispatchOutcome> for DispatchResult {
    fn eq(&self, other: &DispatchOutcome) -> bool {
        self.outcome == *other
    }
}

#[derive(Debug, Deserialize)]
pub(crate) struct JsonRpcRequest {
    id: Value,
    method: String,
    params: Option<Value>,
}

pub fn dispatch_json_rpc(input: &str) -> Result<DispatchResult, serde_json::Error> {
    let mut state = DaemonState::new();
    state.dispatch_json_rpc_with_bridge(input, &UnavailableBridge)
}

pub fn dispatch_json_rpc_with_bridge(
    input: &str,
    bridge: &dyn BridgeApi,
) -> Result<DispatchResult, serde_json::Error> {
    let mut state = DaemonState::new();
    state.dispatch_json_rpc_with_bridge(input, bridge)
}

pub(crate) fn dispatch_known_request(
    request: &JsonRpcRequest,
    bridge: &dyn BridgeApi,
) -> (DispatchOutcome, Value) {
    let (outcome, response) = match request.method.as_str() {
        "initialize" => {
            if !has_valid_initialize_cache_root(request) {
                return (
                    DispatchOutcome::Continue,
                    json!({
                        "jsonrpc": "2.0",
                        "id": request.id,
                        "error": rpc_error(
                            "RPC_INVALID_PARAMS",
                            "protocol",
                            "error.rpc.invalidParams",
                            json!({ "field": "cacheRoot" }),
                            false,
                        ),
                    }),
                );
            }
            let bridge_info = bridge.info();
            let result = InitializeResponse::new(
                env!("CARGO_PKG_VERSION").to_string(),
                bridge_info.bridge_version.clone(),
                bridge_info.libsvn_version.clone(),
                current_platform(),
                bridge_info.capabilities(),
            );
            (
                DispatchOutcome::Continue,
                json!({
                    "jsonrpc": "2.0",
                    "id": request.id,
                    "result": result,
                }),
            )
        }
        "shutdown" => (
            DispatchOutcome::Shutdown,
            json!({
                "jsonrpc": "2.0",
                "id": request.id,
                "result": {
                    "accepted": true,
                },
            }),
        ),
        _ => (
            DispatchOutcome::Continue,
            json!({
                "jsonrpc": "2.0",
                "id": request.id,
                "error": rpc_error(
                    "RPC_METHOD_NOT_FOUND",
                    "unsupported",
                    "error.rpc.methodNotFound",
                    json!({ "method": request.method }),
                    false,
                ),
            }),
        ),
    };

    (outcome, response)
}

fn has_valid_initialize_cache_root(request: &JsonRpcRequest) -> bool {
    request
        .params
        .as_ref()
        .and_then(|params| params.get("cacheRoot"))
        .and_then(Value::as_str)
        .filter(|cache_root| !cache_root.trim().is_empty())
        .is_some_and(|cache_root| Path::new(cache_root).is_absolute())
}

pub(crate) fn rpc_error(
    code: &str,
    category: &str,
    message_key: &str,
    args: Value,
    retryable: bool,
) -> Value {
    json!({
        "code": code,
        "category": category,
        "messageKey": message_key,
        "args": args,
        "retryable": retryable,
        "diagnostics": null,
    })
}

pub(crate) fn current_timestamp() -> String {
    OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .expect("RFC3339 UTC timestamp formatting should succeed")
}

pub(crate) fn bridge_error(failure: BridgeFailure) -> Value {
    let mut error = rpc_error(
        &failure.code,
        &failure.category,
        &failure.message_key,
        failure.args,
        failure.retryable,
    );
    error["diagnostics"] = serde_json::to_value(failure.diagnostics)
        .expect("operation failure diagnostics must serialize");
    error
}

impl From<(DispatchOutcome, Value)> for DispatchResult {
    fn from((outcome, response): (DispatchOutcome, Value)) -> Self {
        Self {
            outcome,
            response,
            notifications: Vec::new(),
        }
    }
}

#[cfg(test)]
mod error_contract_tests {
    use super::*;
    use subversionr_protocol::{
        OperationFailureCause, OperationFailureDiagnostics, SvnErrorDiagnosticEntry,
        SvnErrorDiagnostics,
    };

    #[test]
    fn rpc_errors_always_include_nullable_diagnostics() {
        assert_eq!(
            rpc_error("RPC_TEST", "protocol", "error.rpc.test", json!({}), false)["diagnostics"],
            Value::Null
        );

        let failure =
            BridgeFailure::new("SVN_TEST", "native", "error.native.test", json!({}), false)
                .with_diagnostics(OperationFailureDiagnostics {
                    cause: OperationFailureCause::NotWorkingCopy,
                    svn: SvnErrorDiagnostics {
                        entries: vec![SvnErrorDiagnosticEntry {
                            code: 155007,
                            name: "SVN_ERR_WC_NOT_WORKING_COPY".to_string(),
                        }],
                        truncated: false,
                    },
                });
        let error = bridge_error(failure);
        assert_eq!(error["diagnostics"]["cause"], "notWorkingCopy");
        assert_eq!(error["diagnostics"]["svn"]["entries"][0]["code"], 155007);
    }
}
