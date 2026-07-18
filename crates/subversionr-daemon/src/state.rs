use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    path::{Path, PathBuf},
    sync::Arc,
    time::{Duration, Instant},
};

use base64::{Engine as _, engine::general_purpose::STANDARD};
use serde_json::{Value, json};
use subversionr_protocol::{
    ContentGetResponse, DiagnosticsBackendStderr, DiagnosticsGetResponse,
    DiagnosticsRepositorySummary, HistoryBlameResponse, HistoryLogResponse, InitializeParams,
    InitializeResponse, OperationReconcileHint, OperationRunResponse, OperationSummary,
    OperationWarning, PropertiesListResponse, PropertyEntry as ProtocolPropertyEntry,
    ProtocolVersion, RemoteAttentionReason, RemoteConnectionState, RemoteFailureClass,
    RemoteIndeterminateReason, RemoteRecoveryOutcome, RemoteRecoveryState, RemoteScheme,
    RemoteUnreachableReason, RepositoryCheckoutResponse, RepositoryCloseResponse,
    RepositoryDiscoverResponse, RepositoryDiscoveryCandidate, RepositoryIdentity,
    RepositoryOpenResponse, StatusCoverageScope, StatusDelta, StatusEntry, StatusRefreshTarget,
    StatusSnapshot, StatusSummary, StatusSummaryDelta, WorkspaceTrustState,
    WorkspaceTrustUpdateParams, WorkspaceTrustUpdateResponse, current_platform,
    default_cache_schema,
};

use crate::remote::{
    MAX_REMOTE_TIMEOUT_MS, RemoteLaunchPlan, RemoteTrustState, attach_remote_failure,
    classify_remote_failure, envelope_value, is_canonical_uuid, preflight_repository_urls,
    unsupported_transport,
};
use crate::remote_checkout_journal::{
    RemoteCheckoutJournalError, RemoteCheckoutJournalErrorKind, RemoteCheckoutMutationJournal,
    RemoteCheckoutMutationState,
};
use crate::{
    AddOperationRequest, AuthRequestBroker, BranchCreateOperationRequest, BridgeApi,
    BridgeCancellationToken, BridgeFailure, ChangelistClearOperationRequest,
    ChangelistSetOperationRequest, CleanupOperationRequest, CommitOperationRequest,
    DispatchOutcome, DispatchResult, HistoryBlameRequest, HistoryLogRequest, JsonRpcRequest,
    LockOperationRequest, MergeOperationRequest, MoveOperationRequest, NeverCancelled,
    PropertyDeleteOperationRequest, PropertySetOperationRequest, RelocateOperationRequest,
    RemoveOperationRequest, RepositoryCheckoutRequest, ResolveOperationRequest,
    RevertOperationRequest, SwitchOperationRequest, UnavailableAuthRequestBroker,
    UnlockOperationRequest, UpdateOperationRequest, UpgradeOperationRequest, bridge_error,
    current_timestamp, rpc_error,
};
use crate::{
    InlineRemoteWorkerSupervisor, RemoteOperationEffect, RemoteWorkerSettlement,
    RemoteWorkerSupervisor,
};

const MAX_SVN_REVNUM: u64 = 2_147_483_647;
const SVN_ADMIN_DIR_NAME: &str = ".svn";
const MAX_REPOSITORY_DISCOVERY_DEPTH: u64 = 64;
const MAX_REMOTE_RECOVERY_OPERATION_IDS: usize = 64;

pub struct DaemonState {
    repositories: BTreeMap<String, RepositorySession>,
    next_epoch: u64,
    next_operation_id: u64,
    pending_notifications: Vec<Value>,
    remote_trust: Option<RemoteTrustState>,
    remote_worker: Arc<dyn RemoteWorkerSupervisor>,
    pending_remote_launch: Option<RemoteLaunchPlan>,
    pending_remote_recovery_launch: Option<RemoteRecoveryLaunchPlan>,
    remote_native_lanes: BTreeMap<String, RemoteNativeLaneState>,
    active_remote_operation_ids: BTreeSet<String>,
    remote_checkout_journal: Option<RemoteCheckoutMutationJournal>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum RemoteNativeLaneState {
    Active {
        operation_id: String,
        effect: RemoteOperationEffect,
        repository_id: Option<String>,
        epoch: Option<u64>,
    },
    Recovering {
        origin_operation_id: String,
        recovery_operation_id: Option<String>,
        used_recovery_operation_ids: BTreeSet<String>,
    },
    Blocked {
        origin_operation_id: String,
        reason: RemoteFailureClass,
        cleanup_appropriate: bool,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct RemoteRecoveryLaunchPlan {
    pub request_id: Value,
    pub repository_id: String,
    pub epoch: u64,
    pub lane_key: String,
    pub origin_operation_id: String,
    pub operation_id: String,
    pub identity: RepositoryIdentity,
    pub boundary_roots: Vec<String>,
    pub generation: u64,
    pub deadline: Instant,
}

#[derive(Debug, Clone)]
struct RepositorySession {
    repository_id: String,
    epoch: u64,
    identity: RepositoryIdentity,
    boundary_roots: Vec<String>,
    next_generation: u64,
    local_entries: BTreeMap<String, StatusEntry>,
    remote_entries: BTreeMap<String, StatusEntry>,
}

struct OperationRunSuccess<'a> {
    kind: &'a str,
    result: crate::OperationResult,
    paths: &'a [String],
    depth: &'a str,
    reason: &'a str,
    revision: Option<i64>,
}

struct OperationRunFullReconcileSuccess<'a> {
    repository_id: String,
    epoch: u64,
    kind: &'a str,
    stale_reason: &'a str,
    result: crate::OperationResult,
    revision: Option<i64>,
}

struct OperationRunRemoteSuccess<'a> {
    repository_id: String,
    epoch: u64,
    kind: &'a str,
    result: crate::OperationResult,
    revision: Option<i64>,
}

impl DaemonState {
    pub fn new() -> Self {
        Self::with_remote_worker(Arc::new(InlineRemoteWorkerSupervisor::default()))
    }

    pub fn with_remote_worker(remote_worker: Arc<dyn RemoteWorkerSupervisor>) -> Self {
        Self {
            repositories: BTreeMap::new(),
            next_epoch: 1,
            next_operation_id: 1,
            pending_notifications: Vec::new(),
            remote_trust: None,
            remote_worker,
            pending_remote_launch: None,
            pending_remote_recovery_launch: None,
            remote_native_lanes: BTreeMap::new(),
            active_remote_operation_ids: BTreeSet::new(),
            remote_checkout_journal: None,
        }
    }

    pub(crate) fn take_pending_notifications(&mut self) -> Vec<Value> {
        std::mem::take(&mut self.pending_notifications)
    }

    pub fn dispatch_json_rpc_with_bridge(
        &mut self,
        input: &str,
        bridge: &dyn BridgeApi,
    ) -> Result<DispatchResult, serde_json::Error> {
        let request: JsonRpcRequest = serde_json::from_str(input)?;
        let mut auth = UnavailableAuthRequestBroker;
        Ok(self.dispatch_request_with_auth(request, bridge, &mut auth))
    }

    pub(crate) fn dispatch_request_with_auth(
        &mut self,
        request: JsonRpcRequest,
        bridge: &dyn BridgeApi,
        auth: &mut dyn AuthRequestBroker,
    ) -> DispatchResult {
        let cancellation = NeverCancelled;
        self.dispatch_request_with_auth_and_cancellation(request, bridge, auth, &cancellation)
    }

    pub(crate) fn dispatch_request_with_auth_and_cancellation(
        &mut self,
        request: JsonRpcRequest,
        bridge: &dyn BridgeApi,
        auth: &mut dyn AuthRequestBroker,
        cancellation: &dyn BridgeCancellationToken,
    ) -> DispatchResult {
        if let Some(failure) = self.native_lane_failure_for_request(&request) {
            return DispatchResult {
                outcome: DispatchOutcome::Continue,
                response: json!({
                    "jsonrpc": "2.0",
                    "id": request.id,
                    "error": bridge_error(failure),
                }),
                notifications: std::mem::take(&mut self.pending_notifications),
                remote_launch: None,
                remote_recovery_launch: None,
            };
        }
        let (outcome, response) = match request.method.as_str() {
            "initialize" => self.dispatch_initialize(&request, bridge),
            "workspaceTrust/update" => self.dispatch_workspace_trust_update(&request),
            "repository/discover" => self.dispatch_repository_discover(&request, bridge),
            "repository/open" => self.dispatch_repository_open(&request, bridge, auth),
            "repository/checkout" => {
                self.dispatch_repository_checkout(&request, bridge, auth, cancellation)
            }
            "repository/close" => self.dispatch_repository_close(&request),
            "status/getSnapshot" => {
                self.dispatch_status_get_snapshot(&request, bridge, cancellation)
            }
            "status/refresh" => self.dispatch_status_refresh(&request, bridge, cancellation),
            "status/checkRemote" => {
                self.dispatch_status_check_remote(&request, bridge, auth, cancellation)
            }
            "content/get" => self.dispatch_content_get(&request, bridge, auth, cancellation),
            "properties/list" => self.dispatch_properties_list(&request, bridge),
            "history/log" => self.dispatch_history_log(&request, bridge, auth, cancellation),
            "history/blame" => self.dispatch_history_blame(&request, bridge, auth, cancellation),
            "operation/run" => self.dispatch_operation_run(&request, bridge, auth, cancellation),
            "remote/recoverWorkingCopy" => self.dispatch_remote_recover_working_copy(&request),
            "remote/listCheckoutTargetRecoveries" => {
                self.dispatch_list_checkout_target_recoveries(&request)
            }
            "remote/confirmCheckoutTargetDisposition" => {
                self.dispatch_confirm_checkout_target_disposition(&request)
            }
            "diagnostics/get" => self.dispatch_diagnostics_get(&request, bridge),
            "shutdown" => self.dispatch_shutdown(&request),
            _ => crate::dispatch_known_request(&request, bridge),
        };

        let notifications = std::mem::take(&mut self.pending_notifications);
        DispatchResult {
            outcome,
            response,
            notifications,
            remote_launch: self.pending_remote_launch.take(),
            remote_recovery_launch: self.pending_remote_recovery_launch.take(),
        }
    }

    fn dispatch_initialize(
        &mut self,
        request: &JsonRpcRequest,
        bridge: &dyn BridgeApi,
    ) -> (DispatchOutcome, Value) {
        if self.remote_trust.is_some() {
            return (
                DispatchOutcome::Continue,
                json!({
                    "jsonrpc": "2.0",
                    "id": request.id,
                    "error": rpc_error(
                        "SUBVERSIONR_INITIALIZE_ALREADY_COMPLETED",
                        "state",
                        "error.backend.initializeAlreadyCompleted",
                        json!({}),
                        false,
                    ),
                }),
            );
        }
        let Some(params_value) = request.params.clone() else {
            return invalid_param(request, "params");
        };
        let Some(params_object) = params_value.as_object() else {
            return invalid_param(request, "params");
        };
        let initialize_fields = [
            "clientName",
            "clientVersion",
            "locale",
            "workspaceTrust",
            "trustEpoch",
            "cacheRoot",
            "remoteStateRoot",
        ];
        if let Some(field) = params_object
            .keys()
            .find(|field| !initialize_fields.contains(&field.as_str()))
        {
            return invalid_param(request, field);
        }
        for field in ["clientName", "clientVersion", "locale"] {
            if !params_object
                .get(field)
                .and_then(Value::as_str)
                .is_some_and(|value| !value.trim().is_empty())
            {
                return invalid_param(request, field);
            }
        }
        if !params_object
            .get("cacheRoot")
            .and_then(Value::as_str)
            .is_some_and(|value| !value.trim().is_empty() && Path::new(value).is_absolute())
        {
            return invalid_param(request, "cacheRoot");
        }
        if !params_object
            .get("remoteStateRoot")
            .and_then(Value::as_str)
            .is_some_and(|value| !value.trim().is_empty() && Path::new(value).is_absolute())
        {
            return invalid_param(request, "remoteStateRoot");
        }
        if params_object.get("trustEpoch").and_then(Value::as_u64) != Some(1) {
            return invalid_param(request, "trustEpoch");
        }
        if !matches!(
            params_object.get("workspaceTrust").and_then(Value::as_str),
            Some("trusted" | "untrusted")
        ) {
            return invalid_param(request, "workspaceTrust");
        }
        let Ok(params) = serde_json::from_value::<InitializeParams>(params_value) else {
            return invalid_param(request, "params");
        };
        let trust = match RemoteTrustState::new(
            params.workspace_trust == WorkspaceTrustState::Trusted,
            params.trust_epoch,
        ) {
            Ok(trust) => trust,
            Err(failure) => return bridge_failure_response(request, failure),
        };
        let checkout_journal = match RemoteCheckoutMutationJournal::open(&params.remote_state_root)
        {
            Ok(journal) => journal,
            Err(error) => {
                return bridge_failure_response(request, remote_checkout_journal_failure(error));
            }
        };
        let mut restored_checkout_lanes = BTreeMap::new();
        for entry in checkout_journal.entries() {
            let lane_key = absolute_path_key(&normalize_absolute_path_text(&entry.target_path));
            if restored_checkout_lanes
                .insert(
                    lane_key,
                    RemoteNativeLaneState::Blocked {
                        origin_operation_id: entry.origin_operation_id.clone(),
                        reason: RemoteFailureClass::RemoteRecoveryBlocked,
                        cleanup_appropriate: false,
                    },
                )
                .is_some()
            {
                return bridge_failure_response(
                    request,
                    remote_checkout_journal_contract_failure("duplicateLane"),
                );
            }
        }
        if let Err(failure) = self
            .remote_worker
            .update_workspace_trust(params.workspace_trust == WorkspaceTrustState::Trusted)
        {
            return bridge_failure_response(request, failure);
        }
        let acknowledged_trust_epoch = trust.acknowledged_epoch();
        self.remote_trust = Some(trust);
        self.remote_checkout_journal = Some(checkout_journal);
        self.remote_native_lanes = restored_checkout_lanes;
        let bridge_info = bridge.info();
        let mut capabilities = bridge_info.capabilities();
        capabilities.remote_worker_isolation = self.remote_worker.capability_available();
        capabilities.remote_connection_state = true;
        capabilities.credential_lease_settlement =
            self.remote_worker.credential_lease_settlement_available();
        capabilities.remote_svn_anonymous =
            self.remote_checkout_journal.is_some() && self.remote_worker.svn_anonymous_available();
        let result = InitializeResponse::new(
            env!("CARGO_PKG_VERSION").to_string(),
            bridge_info.bridge_version.clone(),
            bridge_info.libsvn_version.clone(),
            current_platform(),
            capabilities,
            acknowledged_trust_epoch,
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

    fn dispatch_workspace_trust_update(
        &mut self,
        request: &JsonRpcRequest,
    ) -> (DispatchOutcome, Value) {
        let Some(params_value) = request.params.clone() else {
            return invalid_param(request, "params");
        };
        let Ok(params) = serde_json::from_value::<WorkspaceTrustUpdateParams>(params_value) else {
            return invalid_param(request, "params");
        };
        let Some(trust) = self.remote_trust.as_ref() else {
            return (
                DispatchOutcome::Continue,
                json!({
                    "jsonrpc": "2.0",
                    "id": request.id,
                    "error": rpc_error(
                        "SUBVERSIONR_REMOTE_TRUST_NOT_INITIALIZED",
                        "state",
                        "error.remote.trustNotInitialized",
                        json!({}),
                        false,
                    ),
                }),
            );
        };
        if let Err(failure) = trust.validate_update(params.trust_epoch) {
            return bridge_failure_response(request, failure);
        }
        if let Err(failure) = self.remote_worker.update_workspace_trust(params.trusted) {
            return bridge_failure_response(request, failure);
        }
        let acknowledged_trust_epoch = self
            .remote_trust
            .as_mut()
            .expect("validated trust state must remain initialized")
            .commit_update(params.trusted, params.trust_epoch);
        (
            DispatchOutcome::Continue,
            json!({
                "jsonrpc": "2.0",
                "id": request.id,
                "result": WorkspaceTrustUpdateResponse { acknowledged_trust_epoch },
            }),
        )
    }

    fn dispatch_list_checkout_target_recoveries(
        &self,
        request: &JsonRpcRequest,
    ) -> (DispatchOutcome, Value) {
        if let Some(field) = unexpected_param(request, &[]) {
            return invalid_param(request, &field);
        }
        let Some(journal) = self.remote_checkout_journal.as_ref() else {
            return bridge_failure_response(
                request,
                remote_checkout_journal_contract_failure("notInitialized"),
            );
        };
        let entries = journal
            .entries()
            .iter()
            .map(|entry| {
                json!({
                    "targetPath": entry.target_path,
                    "targetSha256": entry.target_sha256,
                    "originOperationId": entry.origin_operation_id,
                    "state": match entry.state {
                        RemoteCheckoutMutationState::Armed => "armed",
                        RemoteCheckoutMutationState::Blocked => "blocked",
                    },
                })
            })
            .collect::<Vec<_>>();
        (
            DispatchOutcome::Continue,
            json!({
                "jsonrpc": "2.0",
                "id": request.id,
                "result": { "entries": entries },
            }),
        )
    }

    fn dispatch_confirm_checkout_target_disposition(
        &mut self,
        request: &JsonRpcRequest,
    ) -> (DispatchOutcome, Value) {
        if let Some(field) = unexpected_param(
            request,
            &[
                "targetPath",
                "targetSha256",
                "originOperationId",
                "confirmation",
            ],
        ) {
            return invalid_param(request, &field);
        }
        let Some(target_path) =
            string_param(request, "targetPath").filter(|path| valid_checkout_target_path(path))
        else {
            return invalid_param(request, "targetPath");
        };
        let Some(target_sha256) =
            string_param(request, "targetSha256").filter(|value| is_lowercase_sha256(value))
        else {
            return invalid_param(request, "targetSha256");
        };
        let Some(origin_operation_id) =
            string_param(request, "originOperationId").filter(|value| is_canonical_uuid(value))
        else {
            return invalid_param(request, "originOperationId");
        };
        if string_param(request, "confirmation") != Some("reviewedAndResolved") {
            return invalid_param(request, "confirmation");
        }
        let lane_key = absolute_path_key(&normalize_absolute_path_text(target_path));
        if !matches!(
            self.remote_native_lanes.get(&lane_key),
            Some(RemoteNativeLaneState::Blocked { origin_operation_id: lane_origin, .. })
                if lane_origin == origin_operation_id
        ) {
            return bridge_failure_response(
                request,
                remote_checkout_journal_contract_failure("laneAttribution"),
            );
        }
        let Some(journal) = self.remote_checkout_journal.as_mut() else {
            return bridge_failure_response(
                request,
                remote_checkout_journal_contract_failure("notInitialized"),
            );
        };
        let entry_matches = journal.entries().iter().any(|entry| {
            entry.state == RemoteCheckoutMutationState::Blocked
                && entry.target_path == target_path
                && entry.target_sha256 == target_sha256
                && entry.origin_operation_id == origin_operation_id
        });
        if !entry_matches {
            return bridge_failure_response(
                request,
                remote_checkout_journal_contract_failure("entryAttribution"),
            );
        }
        if let Err(error) = journal.clear(target_sha256, origin_operation_id) {
            return bridge_failure_response(request, remote_checkout_journal_failure(error));
        }
        self.remote_native_lanes.remove(&lane_key);
        (
            DispatchOutcome::Continue,
            json!({
                "jsonrpc": "2.0",
                "id": request.id,
                "result": {
                    "released": true,
                    "targetSha256": target_sha256,
                    "originOperationId": origin_operation_id,
                },
            }),
        )
    }

    fn dispatch_diagnostics_get(
        &self,
        request: &JsonRpcRequest,
        bridge: &dyn BridgeApi,
    ) -> (DispatchOutcome, Value) {
        if let Some(field) = unexpected_param(request, &[]) {
            return invalid_param(request, &field);
        }
        let bridge_info = bridge.info();
        let mut capabilities = bridge_info.capabilities();
        capabilities.remote_worker_isolation = self.remote_worker.capability_available();
        capabilities.remote_connection_state = true;
        capabilities.credential_lease_settlement =
            self.remote_worker.credential_lease_settlement_available();
        capabilities.remote_svn_anonymous =
            self.remote_checkout_journal.is_some() && self.remote_worker.svn_anonymous_available();
        let response = DiagnosticsGetResponse {
            backend_version: env!("CARGO_PKG_VERSION").to_string(),
            bridge_version: bridge_info.bridge_version,
            libsvn_version: bridge_info.libsvn_version,
            protocol: ProtocolVersion {
                major: 1,
                minor: 35,
            },
            platform: current_platform(),
            cache_schema: default_cache_schema(),
            capabilities,
            repository_summary: DiagnosticsRepositorySummary {
                open_repositories: self.repositories.len() as u32,
                cached_local_entries: self
                    .repositories
                    .values()
                    .map(|session| session.local_entries.len() as u32)
                    .sum(),
            },
            backend_stderr: DiagnosticsBackendStderr {
                truncated: false,
                text: None,
            },
            generated_at: current_timestamp(),
            source: "subversionr-daemon".to_string(),
        };

        (
            DispatchOutcome::Continue,
            json!({
                "jsonrpc": "2.0",
                "id": request.id,
                "result": response,
            }),
        )
    }

    fn dispatch_repository_discover(
        &self,
        request: &JsonRpcRequest,
        bridge: &dyn BridgeApi,
    ) -> (DispatchOutcome, Value) {
        let Some(workspace_roots) = string_array_param(request, "workspaceRoots") else {
            return invalid_param(request, "workspaceRoots");
        };
        let Some(discover_nested) = bool_param(request, "discoverNested") else {
            return invalid_param(request, "discoverNested");
        };
        let Some(discovery_depth) = u64_param(request, "discoveryDepth") else {
            return invalid_param(request, "discoveryDepth");
        };
        if discovery_depth > MAX_REPOSITORY_DISCOVERY_DEPTH {
            return invalid_param(request, "discoveryDepth");
        }
        let Some(discovery_ignore) = string_array_param_allow_empty(request, "discoveryIgnore")
        else {
            return invalid_param(request, "discoveryIgnore");
        };
        let Some(ignored_roots) = string_array_param_allow_empty(request, "ignoredRoots") else {
            return invalid_param(request, "ignoredRoots");
        };
        let Some(externals_mode) = string_param(request, "externalsMode") else {
            return invalid_param(request, "externalsMode");
        };
        if !matches!(externals_mode, "off" | "lazy") {
            return unsupported_discovery_mode(request, "externalsMode");
        }

        let mut candidates = Vec::new();
        let mut seen_candidate_roots = BTreeSet::new();
        let mut file_external_boundaries = Vec::new();
        let mut seen_file_external_boundaries = BTreeSet::new();
        let ignored_root_keys = ignored_roots
            .iter()
            .map(|root| discovery_path_key(root))
            .collect::<BTreeSet<_>>();

        for workspace_root in workspace_roots {
            let ignored_workspace_root =
                matching_ignored_root(&ignored_roots, &workspace_root).map(str::to_string);
            let mut workspace_parent_root = ignored_workspace_root;

            if workspace_parent_root.is_none() {
                match bridge.open_working_copy(&workspace_root) {
                    Ok(identity) => {
                        workspace_parent_root = Some(identity.working_copy_root.clone());
                        push_discovery_candidate(
                            &mut candidates,
                            &mut seen_candidate_roots,
                            &ignored_root_keys,
                            identity.clone(),
                            None,
                        );
                        if externals_mode == "lazy" {
                            match bridge.status_snapshot(&identity, 0) {
                                Ok(snapshot) => {
                                    for file_external_boundary in external_file_boundary_paths(
                                        &identity,
                                        &snapshot.local_entries,
                                    ) {
                                        let boundary_key =
                                            discovery_path_key(&file_external_boundary);
                                        if seen_file_external_boundaries.insert(boundary_key) {
                                            file_external_boundaries.push(file_external_boundary);
                                        }
                                    }
                                    for external_path in external_directory_candidate_paths(
                                        &identity,
                                        &snapshot.local_entries,
                                    ) {
                                        match bridge.open_working_copy(&external_path) {
                                            Ok(external_identity) => {
                                                push_external_discovery_candidate(
                                                    &mut candidates,
                                                    &mut seen_candidate_roots,
                                                    &ignored_root_keys,
                                                    external_identity,
                                                    &identity.working_copy_root,
                                                );
                                            }
                                            Err(failure) if failure.code == "SVN_WC_NOT_FOUND" => {}
                                            Err(failure) => {
                                                return discovery_bridge_failure(request, failure);
                                            }
                                        }
                                    }
                                }
                                Err(failure) => {
                                    return discovery_bridge_failure(request, failure);
                                }
                            }
                        }
                    }
                    Err(failure) if failure.code == "SVN_WC_NOT_FOUND" => {}
                    Err(failure) => {
                        return discovery_bridge_failure(request, failure);
                    }
                }
            }

            if !discover_nested {
                continue;
            }

            for nested_path in
                nested_working_copy_hint_paths(&workspace_root, discovery_depth, &discovery_ignore)
            {
                let nested_path = nested_path.to_string_lossy().to_string();
                if ignored_root_keys.contains(&discovery_path_key(&nested_path)) {
                    continue;
                }
                match bridge.open_working_copy(&nested_path) {
                    Ok(identity) => {
                        push_discovery_candidate(
                            &mut candidates,
                            &mut seen_candidate_roots,
                            &ignored_root_keys,
                            identity,
                            workspace_parent_root.as_deref(),
                        );
                    }
                    Err(failure) if failure.code == "SVN_WC_NOT_FOUND" => {}
                    Err(failure) => {
                        return discovery_bridge_failure(request, failure);
                    }
                }
            }
        }

        (
            DispatchOutcome::Continue,
            json!({
                "jsonrpc": "2.0",
                "id": request.id,
                "result": RepositoryDiscoverResponse { candidates, file_external_boundaries },
            }),
        )
    }

    fn dispatch_repository_open(
        &mut self,
        request: &JsonRpcRequest,
        bridge: &dyn BridgeApi,
        auth: &mut dyn AuthRequestBroker,
    ) -> (DispatchOutcome, Value) {
        let Some(path) = request
            .params
            .as_ref()
            .and_then(|params| params.get("path"))
            .and_then(Value::as_str)
            .filter(|path| !path.trim().is_empty())
        else {
            return (
                DispatchOutcome::Continue,
                json!({
                    "jsonrpc": "2.0",
                    "id": request.id,
                    "error": rpc_error(
                        "RPC_INVALID_PARAMS",
                        "protocol",
                        "error.rpc.invalidParams",
                        json!({ "field": "path" }),
                        false,
                    ),
                }),
            );
        };
        let boundary_roots = match repository_open_boundary_roots(request) {
            Ok(boundary_roots) => boundary_roots,
            Err(field) => return invalid_param(request, &field),
        };

        match bridge.open_working_copy_with_auth(path, auth) {
            Ok(identity) => {
                let boundary_roots = match repository_boundary_roots(&identity, &boundary_roots) {
                    Ok(boundary_roots) => boundary_roots,
                    Err(field) => return invalid_param(request, &field),
                };
                let repository_id = repository_id(&identity);
                if self.repositories.contains_key(&repository_id) {
                    return repository_already_open(request, &repository_id);
                }

                let epoch = self.next_epoch;
                self.next_epoch += 1;
                let session = RepositorySession {
                    repository_id: repository_id.clone(),
                    epoch,
                    identity,
                    boundary_roots,
                    next_generation: 1,
                    local_entries: BTreeMap::new(),
                    remote_entries: BTreeMap::new(),
                };
                let response = RepositoryOpenResponse {
                    repository_id: repository_id.clone(),
                    epoch,
                    identity: session.identity.clone(),
                };
                self.repositories.insert(repository_id, session);

                (
                    DispatchOutcome::Continue,
                    json!({
                        "jsonrpc": "2.0",
                        "id": request.id,
                        "result": response,
                    }),
                )
            }
            Err(failure) => (
                DispatchOutcome::Continue,
                json!({
                    "jsonrpc": "2.0",
                    "id": request.id,
                    "error": bridge_error(failure),
                }),
            ),
        }
    }

    fn dispatch_repository_checkout(
        &mut self,
        request: &JsonRpcRequest,
        bridge: &dyn BridgeApi,
        auth: &mut dyn AuthRequestBroker,
        cancellation: &dyn BridgeCancellationToken,
    ) -> (DispatchOutcome, Value) {
        let checkout_request = match repository_checkout_request(request) {
            Ok(checkout_request) => checkout_request,
            Err(field) => return invalid_param(request, &field),
        };
        if let Some(response) = self.begin_remote_preflight(
            request,
            &[&checkout_request.url],
            &checkout_request.target_path,
            bridge,
            cancellation,
            Some(crate::RemoteSvnAnonymousRequest::Checkout {
                request: checkout_request.clone(),
            }),
        ) {
            return response;
        }

        match bridge.repository_checkout_with_cancellation(&checkout_request, auth, cancellation) {
            Ok(result) => (
                DispatchOutcome::Continue,
                json!({
                    "jsonrpc": "2.0",
                    "id": request.id,
                    "result": RepositoryCheckoutResponse {
                        working_copy_path: result.working_copy_path,
                        revision: result.revision,
                    },
                }),
            ),
            Err(failure) => (
                DispatchOutcome::Continue,
                json!({
                    "jsonrpc": "2.0",
                    "id": request.id,
                    "error": bridge_error(failure),
                }),
            ),
        }
    }

    fn dispatch_repository_close(&mut self, request: &JsonRpcRequest) -> (DispatchOutcome, Value) {
        let Some(repository_id) = repository_id_param(request) else {
            return invalid_repository_id(request);
        };
        let Some(epoch) = epoch_param(request) else {
            return invalid_param(request, "epoch");
        };

        let Some(session) = self.repositories.get(repository_id) else {
            return repository_not_open(request, repository_id);
        };
        if epoch != session.epoch {
            return repository_not_open(request, repository_id);
        }

        let removed = self.repositories.remove(repository_id).is_some();
        (
            DispatchOutcome::Continue,
            json!({
                "jsonrpc": "2.0",
                "id": request.id,
                "result": RepositoryCloseResponse {
                    repository_id: repository_id.to_string(),
                    epoch,
                    closed: removed,
                },
            }),
        )
    }

    fn dispatch_status_get_snapshot(
        &mut self,
        request: &JsonRpcRequest,
        bridge: &dyn BridgeApi,
        cancellation: &dyn BridgeCancellationToken,
    ) -> (DispatchOutcome, Value) {
        let Some(repository_id) = repository_id_param(request) else {
            return invalid_repository_id(request);
        };
        let Some(epoch) = epoch_param(request) else {
            return invalid_param(request, "epoch");
        };
        let Some(session) = self.repositories.get_mut(repository_id) else {
            return repository_not_open(request, repository_id);
        };
        if epoch != session.epoch {
            return repository_not_open(request, repository_id);
        }

        let generation = session.next_generation;
        session.next_generation += 1;
        match bridge.status_snapshot_with_cancellation(&session.identity, generation, cancellation)
        {
            Ok(mut snapshot) => {
                snapshot.repository_id = session.repository_id.clone();
                snapshot.epoch = session.epoch;
                snapshot.generation = generation;
                snapshot.identity = session.identity.clone();
                snapshot.timestamp = current_timestamp();
                for entry in &mut snapshot.local_entries {
                    entry.generation = generation;
                }
                for entry in &mut snapshot.remote_entries {
                    entry.generation = generation;
                }
                filter_snapshot_boundaries(&mut snapshot, &session.boundary_roots);
                remove_conflict_artifact_entries(&mut snapshot.local_entries);
                replace_session_local_entries(session, &snapshot.local_entries);
                if snapshot.remote_entries.is_empty() {
                    snapshot.remote_entries = session.remote_entries.values().cloned().collect();
                    for entry in &mut snapshot.remote_entries {
                        entry.generation = generation;
                    }
                }
                replace_session_remote_entries(session, &snapshot.remote_entries);
                snapshot.summary = summarize_snapshot_entries(
                    snapshot.local_entries.iter(),
                    snapshot.remote_entries.iter(),
                );
                (
                    DispatchOutcome::Continue,
                    json!({
                        "jsonrpc": "2.0",
                        "id": request.id,
                        "result": snapshot,
                    }),
                )
            }
            Err(failure) => (
                DispatchOutcome::Continue,
                json!({
                    "jsonrpc": "2.0",
                    "id": request.id,
                    "error": bridge_error(failure),
                }),
            ),
        }
    }

    fn dispatch_status_refresh(
        &mut self,
        request: &JsonRpcRequest,
        bridge: &dyn BridgeApi,
        cancellation: &dyn BridgeCancellationToken,
    ) -> (DispatchOutcome, Value) {
        let Some(repository_id) = repository_id_param(request) else {
            return invalid_repository_id(request);
        };
        let Some(epoch) = epoch_param(request) else {
            return invalid_param(request, "epoch");
        };
        let targets = match status_refresh_targets(request) {
            Ok(targets) => targets,
            Err(field) => return invalid_param(request, field),
        };
        let Some(session) = self.repositories.get_mut(repository_id) else {
            return repository_not_open(request, repository_id);
        };
        if epoch != session.epoch {
            return repository_not_open(request, repository_id);
        }

        let boundary_roots = session.boundary_roots.clone();
        let targets = targets
            .into_iter()
            .filter(|target| !path_inside_boundary_roots(&target.path, &boundary_roots))
            .collect::<Vec<_>>();
        let target_count = targets.len();
        let generation = session.next_generation;
        let mut scans = Vec::with_capacity(target_count);
        for target in targets {
            match bridge.status_scan_with_cancellation(
                &session.identity,
                &target.path,
                &target.depth,
                generation,
                cancellation,
            ) {
                Ok(mut snapshot) => {
                    snapshot.repository_id = session.repository_id.clone();
                    snapshot.epoch = session.epoch;
                    snapshot.generation = generation;
                    for entry in &mut snapshot.local_entries {
                        entry.generation = generation;
                    }
                    for entry in &mut snapshot.remote_entries {
                        entry.generation = generation;
                    }
                    filter_snapshot_boundaries(&mut snapshot, &boundary_roots);
                    remove_conflict_artifact_entries(&mut snapshot.local_entries);
                    scans.push((target, snapshot));
                }
                Err(failure) => {
                    return (
                        DispatchOutcome::Continue,
                        json!({
                            "jsonrpc": "2.0",
                            "id": request.id,
                            "error": bridge_error(failure),
                        }),
                    );
                }
            }
        }

        let before_summary = summarize_snapshot_entries(
            session.local_entries.values(),
            session.remote_entries.values(),
        );
        let before_entries = session.local_entries.clone();
        let before_remote_entries = session.remote_entries.clone();
        let mut next_entries = session.local_entries.clone();
        let next_remote_entries = session.remote_entries.clone();
        let mut coverage = Vec::with_capacity(target_count);
        let mut artifact_paths = next_entries
            .values()
            .flat_map(|entry| entry.conflict_artifacts.iter())
            .cloned()
            .collect::<BTreeSet<_>>();

        for (target, snapshot) in scans {
            artifact_paths.extend(
                snapshot
                    .local_entries
                    .iter()
                    .flat_map(|entry| entry.conflict_artifacts.iter())
                    .cloned(),
            );
            next_entries.retain(|path, entry| {
                entry.local_status != "unversioned" || !artifact_paths.contains(path)
            });
            let incoming_entries = snapshot
                .local_entries
                .into_iter()
                .filter(|entry| {
                    entry.local_status != "unversioned" || !artifact_paths.contains(&entry.path)
                })
                .collect::<Vec<_>>();
            let seen_paths = incoming_entries
                .iter()
                .map(|entry| entry.path.clone())
                .collect::<BTreeSet<_>>();
            for entry in incoming_entries {
                if is_projectable_status(&entry) {
                    next_entries.insert(entry.path.clone(), entry.clone());
                } else if next_entries.remove(&entry.path).is_some() {
                }
            }

            let covered_existing = next_entries
                .values()
                .filter(|entry| coverage_matches(&target.path, &target.depth, entry))
                .map(|entry| entry.path.clone())
                .collect::<Vec<_>>();
            for existing_path in covered_existing {
                if !seen_paths.contains(&existing_path) {
                    next_entries.remove(&existing_path);
                }
            }

            coverage.push(StatusCoverageScope {
                path: target.path,
                depth: target.depth,
                generation,
                reason: target.reason,
            });
        }

        let after_summary =
            summarize_snapshot_entries(next_entries.values(), next_remote_entries.values());
        let upsert = changed_upserts(&before_entries, &next_entries);
        let remove = removed_paths(&before_entries, &next_entries);
        let remote_upsert = changed_upserts(&before_remote_entries, &next_remote_entries);
        let remote_remove = removed_paths(&before_remote_entries, &next_remote_entries);
        session.local_entries = next_entries;
        session.remote_entries = next_remote_entries;
        session.next_generation += 1;
        let completeness = if is_complete_delta_coverage(&coverage) {
            "complete".to_string()
        } else {
            "partial".to_string()
        };
        let delta = StatusDelta {
            repository_id: session.repository_id.clone(),
            epoch: session.epoch,
            generation,
            coverage,
            upsert,
            remove,
            remote_upsert,
            remote_remove,
            summary_delta: summary_delta(&before_summary, &after_summary),
            completeness,
            timestamp: current_timestamp(),
            source: "libsvn-local".to_string(),
        };

        (
            DispatchOutcome::Continue,
            json!({
                "jsonrpc": "2.0",
                "id": request.id,
                "result": delta,
            }),
        )
    }

    fn dispatch_status_check_remote(
        &mut self,
        request: &JsonRpcRequest,
        bridge: &dyn BridgeApi,
        auth: &mut dyn AuthRequestBroker,
        cancellation: &dyn BridgeCancellationToken,
    ) -> (DispatchOutcome, Value) {
        if let Some(field) = unexpected_param(request, &["repositoryId", "epoch", "remote"]) {
            return invalid_param(request, &field);
        }
        let Some(repository_id) = repository_id_param(request) else {
            return invalid_repository_id(request);
        };
        let Some(epoch) = epoch_param(request) else {
            return invalid_param(request, "epoch");
        };
        let Some(session) = self.repositories.get(repository_id) else {
            return repository_not_open(request, repository_id);
        };
        if epoch != session.epoch {
            return repository_not_open(request, repository_id);
        }
        let lane_key = session.identity.working_copy_root.clone();
        let repository_root_url = session.identity.repository_root_url.clone();
        let remote_request = crate::RemoteSvnAnonymousRequest::Status {
            identity: session.identity.clone(),
            generation: session.next_generation,
        };
        if let Some(response) = self.begin_remote_preflight(
            request,
            &[&repository_root_url],
            &lane_key,
            bridge,
            cancellation,
            Some(remote_request),
        ) {
            return response;
        }
        let session = self
            .repositories
            .get_mut(repository_id)
            .expect("preflight does not remove repository sessions");

        let generation = session.next_generation;
        let mut snapshot = match bridge.status_remote_check_with_cancellation(
            &session.identity,
            generation,
            auth,
            cancellation,
        ) {
            Ok(snapshot) => snapshot,
            Err(failure) => {
                return (
                    DispatchOutcome::Continue,
                    json!({
                        "jsonrpc": "2.0",
                        "id": request.id,
                        "error": bridge_error(failure),
                    }),
                );
            }
        };
        snapshot.repository_id = session.repository_id.clone();
        snapshot.epoch = session.epoch;
        snapshot.generation = generation;
        snapshot.identity = session.identity.clone();
        snapshot.timestamp = current_timestamp();
        for entry in &mut snapshot.remote_entries {
            entry.generation = generation;
        }
        filter_snapshot_boundaries(&mut snapshot, &session.boundary_roots);

        let before_summary = summarize_snapshot_entries(
            session.local_entries.values(),
            session.remote_entries.values(),
        );
        let before_remote_entries = session.remote_entries.clone();
        let next_remote_entries = snapshot
            .remote_entries
            .into_iter()
            .filter(is_projectable_remote_status)
            .map(|entry| (entry.path.clone(), entry))
            .collect::<BTreeMap<_, _>>();
        let after_summary = summarize_snapshot_entries(
            session.local_entries.values(),
            next_remote_entries.values(),
        );
        let remote_upsert = changed_upserts(&before_remote_entries, &next_remote_entries);
        let remote_remove = removed_paths(&before_remote_entries, &next_remote_entries);

        session.remote_entries = next_remote_entries;
        session.next_generation += 1;
        let delta = StatusDelta {
            repository_id: session.repository_id.clone(),
            epoch: session.epoch,
            generation,
            coverage: vec![StatusCoverageScope {
                path: ".".to_string(),
                depth: "workingCopy".to_string(),
                generation,
                reason: "manualRemoteCheck".to_string(),
            }],
            upsert: Vec::new(),
            remove: Vec::new(),
            remote_upsert,
            remote_remove,
            summary_delta: summary_delta(&before_summary, &after_summary),
            completeness: "complete".to_string(),
            timestamp: current_timestamp(),
            source: "libsvn-remote".to_string(),
        };

        (
            DispatchOutcome::Continue,
            json!({
                "jsonrpc": "2.0",
                "id": request.id,
                "result": delta,
            }),
        )
    }

    fn dispatch_content_get(
        &mut self,
        request: &JsonRpcRequest,
        bridge: &dyn BridgeApi,
        auth: &mut dyn AuthRequestBroker,
        cancellation: &dyn BridgeCancellationToken,
    ) -> (DispatchOutcome, Value) {
        if let Some(field) = unexpected_param(
            request,
            &["repositoryId", "epoch", "path", "revision", "remote"],
        ) {
            return invalid_param(request, &field);
        }
        let Some(repository_id) = repository_id_param(request) else {
            return invalid_repository_id(request);
        };
        let Some(epoch) = epoch_param(request) else {
            return invalid_param(request, "epoch");
        };
        let Some(path) = content_path_param(request) else {
            return invalid_param(request, "path");
        };
        let Some(revision) = content_revision_param(request) else {
            return invalid_param(request, "revision");
        };
        let Some(session) = self.repositories.get(repository_id) else {
            return repository_not_open(request, repository_id);
        };
        if epoch != session.epoch {
            return repository_not_open(request, repository_id);
        }
        if revision != "base" {
            let repository_root_url = session.identity.repository_root_url.clone();
            let lane_key = session.identity.working_copy_root.clone();
            let remote_request = crate::RemoteSvnAnonymousRequest::Content {
                identity: session.identity.clone(),
                path: path.to_string(),
                revision: revision.to_string(),
            };
            if let Some(response) = self.begin_remote_preflight(
                request,
                &[&repository_root_url],
                &lane_key,
                bridge,
                cancellation,
                Some(remote_request),
            ) {
                return response;
            }
        } else if envelope_value(request).is_some() {
            return invalid_param(request, "remote");
        }
        let session = self
            .repositories
            .get(repository_id)
            .expect("preflight does not remove repository sessions");

        match bridge.content_get(&session.identity, path, revision, auth) {
            Ok(blob) => {
                let response = ContentGetResponse {
                    repository_id: session.repository_id.clone(),
                    epoch: session.epoch,
                    path: path.to_string(),
                    revision: revision.to_string(),
                    content_base64: STANDARD.encode(&blob.data),
                    byte_length: blob.data.len() as u64,
                    mime_type: blob.mime_type,
                    is_binary: blob.is_binary,
                    source: blob.source,
                };
                (
                    DispatchOutcome::Continue,
                    json!({
                        "jsonrpc": "2.0",
                        "id": request.id,
                        "result": response,
                    }),
                )
            }
            Err(failure) => (
                DispatchOutcome::Continue,
                json!({
                    "jsonrpc": "2.0",
                    "id": request.id,
                    "error": bridge_error(failure),
                }),
            ),
        }
    }

    fn dispatch_properties_list(
        &self,
        request: &JsonRpcRequest,
        bridge: &dyn BridgeApi,
    ) -> (DispatchOutcome, Value) {
        if let Some(field) = unexpected_param(request, &["repositoryId", "epoch", "path"]) {
            return invalid_param(request, &field);
        }
        let Some(repository_id) = repository_id_param(request) else {
            return invalid_repository_id(request);
        };
        let Some(epoch) = epoch_param(request) else {
            return invalid_param(request, "epoch");
        };
        let Some(path) = property_path_param(request) else {
            return invalid_param(request, "path");
        };
        let Some(session) = self.repositories.get(repository_id) else {
            return repository_not_open(request, repository_id);
        };
        if epoch != session.epoch {
            return repository_not_open(request, repository_id);
        }

        match bridge.properties_list(&session.identity, path) {
            Ok(result) => {
                let response = PropertiesListResponse {
                    repository_id: session.repository_id.clone(),
                    epoch: session.epoch,
                    path: path.to_string(),
                    properties: result
                        .properties
                        .into_iter()
                        .map(|entry| ProtocolPropertyEntry {
                            name: entry.name,
                            value: entry.value,
                            value_encoding: entry.value_encoding,
                        })
                        .collect(),
                    source: result.source,
                };
                (
                    DispatchOutcome::Continue,
                    json!({
                        "jsonrpc": "2.0",
                        "id": request.id,
                        "result": response,
                    }),
                )
            }
            Err(failure) => (
                DispatchOutcome::Continue,
                json!({
                    "jsonrpc": "2.0",
                    "id": request.id,
                    "error": bridge_error(failure),
                }),
            ),
        }
    }

    fn dispatch_history_log(
        &mut self,
        request: &JsonRpcRequest,
        bridge: &dyn BridgeApi,
        auth: &mut dyn AuthRequestBroker,
        cancellation: &dyn BridgeCancellationToken,
    ) -> (DispatchOutcome, Value) {
        if let Some(field) = unexpected_param(
            request,
            &[
                "repositoryId",
                "epoch",
                "path",
                "startRevision",
                "endRevision",
                "limit",
                "discoverChangedPaths",
                "strictNodeHistory",
                "includeMergedRevisions",
                "remote",
            ],
        ) {
            return invalid_param(request, &field);
        }
        let Some(repository_id) = repository_id_param(request) else {
            return invalid_repository_id(request);
        };
        let Some(epoch) = epoch_param(request) else {
            return invalid_param(request, "epoch");
        };
        let log_request = match history_log_request(request) {
            Ok(request) => request,
            Err(field) => return invalid_param(request, field),
        };
        let Some(session) = self.repositories.get(repository_id) else {
            return repository_not_open(request, repository_id);
        };
        if epoch != session.epoch {
            return repository_not_open(request, repository_id);
        }
        let repository_root_url = session.identity.repository_root_url.clone();
        let lane_key = session.identity.working_copy_root.clone();
        let remote_request = crate::RemoteSvnAnonymousRequest::Log {
            identity: session.identity.clone(),
            request: log_request.clone(),
        };
        if let Some(response) = self.begin_remote_preflight(
            request,
            &[&repository_root_url],
            &lane_key,
            bridge,
            cancellation,
            Some(remote_request),
        ) {
            return response;
        }
        let session = self
            .repositories
            .get(repository_id)
            .expect("preflight does not remove repository sessions");

        match bridge.history_log(&session.identity, &log_request, auth) {
            Ok(log) => {
                let response = HistoryLogResponse {
                    repository_id: session.repository_id.clone(),
                    epoch: session.epoch,
                    path: log_request.path,
                    start_revision: log_request.start_revision,
                    end_revision: log_request.end_revision,
                    limit: log_request.limit,
                    entries: log.entries,
                    source: log.source,
                };
                (
                    DispatchOutcome::Continue,
                    json!({
                        "jsonrpc": "2.0",
                        "id": request.id,
                        "result": response,
                    }),
                )
            }
            Err(failure) => (
                DispatchOutcome::Continue,
                json!({
                    "jsonrpc": "2.0",
                    "id": request.id,
                    "error": bridge_error(failure),
                }),
            ),
        }
    }

    fn dispatch_history_blame(
        &mut self,
        request: &JsonRpcRequest,
        bridge: &dyn BridgeApi,
        auth: &mut dyn AuthRequestBroker,
        cancellation: &dyn BridgeCancellationToken,
    ) -> (DispatchOutcome, Value) {
        if let Some(field) = unexpected_param(
            request,
            &[
                "repositoryId",
                "epoch",
                "path",
                "pegRevision",
                "startRevision",
                "endRevision",
                "lineStart",
                "lineLimit",
                "ignoreWhitespace",
                "ignoreEolStyle",
                "ignoreMimeType",
                "includeMergedRevisions",
                "remote",
            ],
        ) {
            return invalid_param(request, &field);
        }
        let Some(repository_id) = repository_id_param(request) else {
            return invalid_repository_id(request);
        };
        let Some(epoch) = epoch_param(request) else {
            return invalid_param(request, "epoch");
        };
        let blame_request = match history_blame_request(request) {
            Ok(request) => request,
            Err(field) => return invalid_param(request, field),
        };
        let Some(session) = self.repositories.get(repository_id) else {
            return repository_not_open(request, repository_id);
        };
        if epoch != session.epoch {
            return repository_not_open(request, repository_id);
        }
        let repository_root_url = session.identity.repository_root_url.clone();
        let lane_key = session.identity.working_copy_root.clone();
        let remote_request = crate::RemoteSvnAnonymousRequest::Blame {
            identity: session.identity.clone(),
            request: blame_request.clone(),
        };
        if let Some(response) = self.begin_remote_preflight(
            request,
            &[&repository_root_url],
            &lane_key,
            bridge,
            cancellation,
            Some(remote_request),
        ) {
            return response;
        }
        let session = self
            .repositories
            .get(repository_id)
            .expect("preflight does not remove repository sessions");

        match bridge.history_blame(&session.identity, &blame_request, auth) {
            Ok(blame) => {
                let response = HistoryBlameResponse {
                    repository_id: session.repository_id.clone(),
                    epoch: session.epoch,
                    path: blame_request.path,
                    peg_revision: blame_request.peg_revision,
                    start_revision: blame_request.start_revision,
                    end_revision: blame_request.end_revision,
                    resolved_start_revision: blame.resolved_start_revision,
                    resolved_end_revision: blame.resolved_end_revision,
                    line_start: blame_request.line_start,
                    line_limit: blame_request.line_limit,
                    ignore_whitespace: blame_request.ignore_whitespace,
                    ignore_eol_style: blame_request.ignore_eol_style,
                    ignore_mime_type: blame_request.ignore_mime_type,
                    include_merged_revisions: blame_request.include_merged_revisions,
                    has_more: blame.has_more,
                    lines: blame.lines,
                    source: blame.source,
                };
                (
                    DispatchOutcome::Continue,
                    json!({
                        "jsonrpc": "2.0",
                        "id": request.id,
                        "result": response,
                    }),
                )
            }
            Err(failure) => (
                DispatchOutcome::Continue,
                json!({
                    "jsonrpc": "2.0",
                    "id": request.id,
                    "error": bridge_error(failure),
                }),
            ),
        }
    }

    fn dispatch_operation_run(
        &mut self,
        request: &JsonRpcRequest,
        bridge: &dyn BridgeApi,
        auth: &mut dyn AuthRequestBroker,
        cancellation: &dyn BridgeCancellationToken,
    ) -> (DispatchOutcome, Value) {
        if let Some(field) = unexpected_param(
            request,
            &["repositoryId", "epoch", "kind", "options", "remote"],
        ) {
            return invalid_param(request, &field);
        }
        let Some(repository_id) = repository_id_param(request) else {
            return invalid_repository_id(request);
        };
        let Some(epoch) = epoch_param(request) else {
            return invalid_param(request, "epoch");
        };
        let Some(kind) = string_param(request, "kind") else {
            return invalid_param(request, "kind");
        };
        enum ParsedOperation {
            Revert(RevertOperationRequest),
            Add(AddOperationRequest),
            Remove(RemoveOperationRequest),
            Move(MoveOperationRequest),
            Resolve(ResolveOperationRequest),
            Cleanup(CleanupOperationRequest),
            Upgrade(UpgradeOperationRequest),
            Update(UpdateOperationRequest),
            PropertySet(PropertySetOperationRequest),
            PropertyDelete(PropertyDeleteOperationRequest),
            ChangelistSet(ChangelistSetOperationRequest),
            ChangelistClear(ChangelistClearOperationRequest),
            Lock(LockOperationRequest),
            Unlock(UnlockOperationRequest),
            BranchCreate(BranchCreateOperationRequest),
            Switch(SwitchOperationRequest),
            Relocate(RelocateOperationRequest),
            Merge(MergeOperationRequest),
            Commit(CommitOperationRequest),
        }
        let operation = match kind {
            "revert" => match revert_options(request) {
                Ok(revert_request) => ParsedOperation::Revert(revert_request),
                Err(field) => return invalid_param(request, field),
            },
            "add" => match add_options(request) {
                Ok(add_request) => ParsedOperation::Add(add_request),
                Err(field) => return invalid_param(request, &field),
            },
            "remove" => match remove_options(request) {
                Ok(remove_request) => ParsedOperation::Remove(remove_request),
                Err(field) => return invalid_param(request, &field),
            },
            "move" => match move_options(request) {
                Ok(move_request) => ParsedOperation::Move(move_request),
                Err(field) => return invalid_param(request, &field),
            },
            "resolve" => match resolve_options(request) {
                Ok(resolve_request) => ParsedOperation::Resolve(resolve_request),
                Err(field) => return invalid_param(request, &field),
            },
            "cleanup" => match cleanup_options(request) {
                Ok(cleanup_request) => ParsedOperation::Cleanup(cleanup_request),
                Err(field) => return invalid_param(request, &field),
            },
            "upgrade" => match upgrade_options(request) {
                Ok(upgrade_request) => ParsedOperation::Upgrade(upgrade_request),
                Err(field) => return invalid_param(request, &field),
            },
            "update" => match update_options(request) {
                Ok(update_request) => ParsedOperation::Update(update_request),
                Err(field) => return invalid_param(request, &field),
            },
            "propertySet" => match property_set_options(request) {
                Ok(property_request) => ParsedOperation::PropertySet(property_request),
                Err(field) => return invalid_param(request, &field),
            },
            "propertyDelete" => match property_delete_options(request) {
                Ok(property_request) => ParsedOperation::PropertyDelete(property_request),
                Err(field) => return invalid_param(request, &field),
            },
            "changelistSet" => match changelist_set_options(request) {
                Ok(changelist_request) => ParsedOperation::ChangelistSet(changelist_request),
                Err(field) => return invalid_param(request, &field),
            },
            "changelistClear" => match changelist_clear_options(request) {
                Ok(changelist_request) => ParsedOperation::ChangelistClear(changelist_request),
                Err(field) => return invalid_param(request, &field),
            },
            "lock" => match lock_options(request) {
                Ok(lock_request) => ParsedOperation::Lock(lock_request),
                Err(field) => return invalid_param(request, &field),
            },
            "unlock" => match unlock_options(request) {
                Ok(unlock_request) => ParsedOperation::Unlock(unlock_request),
                Err(field) => return invalid_param(request, &field),
            },
            "branchCreate" => match branch_create_options(request) {
                Ok(branch_request) => ParsedOperation::BranchCreate(branch_request),
                Err(field) => return invalid_param(request, &field),
            },
            "switch" => match switch_options(request) {
                Ok(switch_request) => ParsedOperation::Switch(switch_request),
                Err(field) => return invalid_param(request, &field),
            },
            "relocate" => match relocate_options(request) {
                Ok(relocate_request) => ParsedOperation::Relocate(relocate_request),
                Err(field) => return invalid_param(request, &field),
            },
            "merge" => match merge_options(request) {
                Ok(merge_request) => ParsedOperation::Merge(merge_request),
                Err(field) => return invalid_param(request, &field),
            },
            "commit" => match commit_options(request) {
                Ok(commit_request) => ParsedOperation::Commit(commit_request),
                Err(field) => return invalid_param(request, &field),
            },
            _ => return unsupported_operation_kind(request, kind),
        };
        let Some(session) = self.repositories.get(repository_id) else {
            return repository_not_open(request, repository_id);
        };
        if epoch != session.epoch {
            return repository_not_open(request, repository_id);
        }
        let session_repository_id = session.repository_id.clone();
        let session_epoch = session.epoch;
        let session_identity = session.identity.clone();

        let svn_anonymous_request = match &operation {
            ParsedOperation::Update(request) => Some(crate::RemoteSvnAnonymousRequest::Update {
                identity: session_identity.clone(),
                request: request.clone(),
            }),
            ParsedOperation::Lock(request) => Some(crate::RemoteSvnAnonymousRequest::Lock {
                identity: session_identity.clone(),
                request: request.clone(),
            }),
            ParsedOperation::Unlock(request) => Some(crate::RemoteSvnAnonymousRequest::Unlock {
                identity: session_identity.clone(),
                request: request.clone(),
            }),
            ParsedOperation::BranchCreate(request) => {
                Some(crate::RemoteSvnAnonymousRequest::BranchCreate {
                    identity: session_identity.clone(),
                    request: request.clone(),
                })
            }
            ParsedOperation::Switch(request) => Some(crate::RemoteSvnAnonymousRequest::Switch {
                identity: session_identity.clone(),
                request: request.clone(),
            }),
            ParsedOperation::Commit(request) => Some(crate::RemoteSvnAnonymousRequest::Commit {
                identity: session_identity.clone(),
                request: request.clone(),
            }),
            _ => None,
        };

        let remote_preflight = match &operation {
            ParsedOperation::Update(_)
            | ParsedOperation::Lock(_)
            | ParsedOperation::Unlock(_)
            | ParsedOperation::Commit(_) => {
                Some(vec![session_identity.repository_root_url.as_str()])
            }
            ParsedOperation::BranchCreate(operation) => Some(vec![
                session_identity.repository_root_url.as_str(),
                operation.source_url.as_str(),
                operation.destination_url.as_str(),
            ]),
            ParsedOperation::Switch(operation) => Some(vec![
                session_identity.repository_root_url.as_str(),
                operation.url.as_str(),
            ]),
            ParsedOperation::Relocate(operation) => Some(vec![
                session_identity.repository_root_url.as_str(),
                operation.from_url.as_str(),
                operation.to_url.as_str(),
            ]),
            ParsedOperation::Merge(operation) => Some(vec![
                session_identity.repository_root_url.as_str(),
                operation.source_url.as_str(),
            ]),
            _ => None,
        };
        if let Some(urls) = remote_preflight {
            if let Some(response) = self.begin_remote_preflight(
                request,
                &urls,
                &session_identity.working_copy_root,
                bridge,
                cancellation,
                svn_anonymous_request,
            ) {
                return response;
            }
        } else if envelope_value(request).is_some() {
            return invalid_param(request, "remote");
        }

        match operation {
            ParsedOperation::Revert(revert_request) => {
                match bridge.operation_revert_with_cancellation(
                    &session_identity,
                    &revert_request,
                    cancellation,
                ) {
                    Ok(result) => self.operation_run_success(
                        request,
                        session_repository_id,
                        session_epoch,
                        OperationRunSuccess {
                            kind: "revert",
                            result,
                            paths: &revert_request.paths,
                            depth: &revert_request.depth,
                            reason: "operationRevert",
                            revision: None,
                        },
                    ),
                    Err(failure) => self.operation_run_failure(
                        request,
                        &session_repository_id,
                        session_epoch,
                        "operationRevertFailed",
                        failure,
                    ),
                }
            }
            ParsedOperation::Add(add_request) => {
                match bridge.operation_add_with_cancellation(
                    &session_identity,
                    &add_request,
                    cancellation,
                ) {
                    Ok(result) => self.operation_run_success(
                        request,
                        session_repository_id,
                        session_epoch,
                        OperationRunSuccess {
                            kind: "add",
                            result,
                            paths: &add_request.paths,
                            depth: &add_request.depth,
                            reason: "operationAdd",
                            revision: None,
                        },
                    ),
                    Err(failure) => self.operation_run_failure(
                        request,
                        &session_repository_id,
                        session_epoch,
                        "operationAddFailed",
                        failure,
                    ),
                }
            }
            ParsedOperation::Remove(remove_request) => {
                match bridge.operation_remove_with_cancellation(
                    &session_identity,
                    &remove_request,
                    cancellation,
                ) {
                    Ok(result) => self.operation_run_success(
                        request,
                        session_repository_id,
                        session_epoch,
                        OperationRunSuccess {
                            kind: "remove",
                            result,
                            paths: &remove_request.paths,
                            depth: "empty",
                            reason: "operationRemove",
                            revision: None,
                        },
                    ),
                    Err(failure) => self.operation_run_failure(
                        request,
                        &session_repository_id,
                        session_epoch,
                        "operationRemoveFailed",
                        failure,
                    ),
                }
            }
            ParsedOperation::Move(move_request) => {
                match bridge.operation_move_with_cancellation(
                    &session_identity,
                    &move_request,
                    cancellation,
                ) {
                    Ok(result) => {
                        let paths = move_reconcile_paths(
                            &move_request.source_path,
                            &move_request.destination_path,
                        );
                        self.operation_run_success(
                            request,
                            session_repository_id,
                            session_epoch,
                            OperationRunSuccess {
                                kind: "move",
                                result,
                                paths: &paths,
                                depth: "immediates",
                                reason: "operationMove",
                                revision: None,
                            },
                        )
                    }
                    Err(failure) => self.operation_run_failure(
                        request,
                        &session_repository_id,
                        session_epoch,
                        "operationMoveFailed",
                        failure,
                    ),
                }
            }
            ParsedOperation::Resolve(resolve_request) => {
                match bridge.operation_resolve_with_cancellation(
                    &session_identity,
                    &resolve_request,
                    cancellation,
                ) {
                    Ok(result) => self.operation_run_success(
                        request,
                        session_repository_id,
                        session_epoch,
                        OperationRunSuccess {
                            kind: "resolve",
                            result,
                            paths: &resolve_request.paths,
                            depth: &resolve_request.depth,
                            reason: "operationResolve",
                            revision: None,
                        },
                    ),
                    Err(failure) => self.operation_run_failure(
                        request,
                        &session_repository_id,
                        session_epoch,
                        "operationResolveFailed",
                        failure,
                    ),
                }
            }
            ParsedOperation::Cleanup(cleanup_request) => {
                match bridge.operation_cleanup_with_cancellation(
                    &session_identity,
                    &cleanup_request,
                    cancellation,
                ) {
                    Ok(result) => self.operation_run_full_reconcile_success(
                        request,
                        OperationRunFullReconcileSuccess {
                            repository_id: session_repository_id,
                            epoch: session_epoch,
                            kind: "cleanup",
                            stale_reason: "operationCleanupRequiresFullReconcile",
                            result,
                            revision: None,
                        },
                    ),
                    Err(failure) => self.operation_run_failure(
                        request,
                        &session_repository_id,
                        session_epoch,
                        "operationCleanupFailed",
                        failure,
                    ),
                }
            }
            ParsedOperation::Upgrade(upgrade_request) => {
                match bridge.operation_upgrade_with_cancellation(
                    &session_identity,
                    &upgrade_request,
                    cancellation,
                ) {
                    Ok(result) => self.operation_run_full_reconcile_success(
                        request,
                        OperationRunFullReconcileSuccess {
                            repository_id: session_repository_id,
                            epoch: session_epoch,
                            kind: "upgrade",
                            stale_reason: "operationUpgradeRequiresFullReconcile",
                            result,
                            revision: None,
                        },
                    ),
                    Err(failure) => self.operation_run_failure(
                        request,
                        &session_repository_id,
                        session_epoch,
                        "operationUpgradeFailed",
                        failure,
                    ),
                }
            }
            ParsedOperation::Update(update_request) => {
                match bridge.operation_update_with_cancellation(
                    &session_identity,
                    &update_request,
                    auth,
                    cancellation,
                ) {
                    Ok(update_result) => self.operation_run_full_reconcile_success(
                        request,
                        OperationRunFullReconcileSuccess {
                            repository_id: session_repository_id,
                            epoch: session_epoch,
                            kind: "update",
                            stale_reason: "operationUpdateRequiresFullReconcile",
                            result: update_result.result,
                            revision: Some(update_result.revision),
                        },
                    ),
                    Err(failure) => self.operation_run_failure(
                        request,
                        &session_repository_id,
                        session_epoch,
                        "operationUpdateFailed",
                        failure,
                    ),
                }
            }
            ParsedOperation::PropertySet(property_request) => {
                match bridge.operation_property_set_with_cancellation(
                    &session_identity,
                    &property_request,
                    cancellation,
                ) {
                    Ok(result) => self.operation_run_success(
                        request,
                        session_repository_id,
                        session_epoch,
                        OperationRunSuccess {
                            kind: "propertySet",
                            result,
                            paths: std::slice::from_ref(&property_request.path),
                            depth: "empty",
                            reason: "operationPropertySet",
                            revision: None,
                        },
                    ),
                    Err(failure) => self.operation_run_failure(
                        request,
                        &session_repository_id,
                        session_epoch,
                        "operationPropertySetFailed",
                        failure,
                    ),
                }
            }
            ParsedOperation::PropertyDelete(property_request) => {
                match bridge.operation_property_delete_with_cancellation(
                    &session_identity,
                    &property_request,
                    cancellation,
                ) {
                    Ok(result) => self.operation_run_success(
                        request,
                        session_repository_id,
                        session_epoch,
                        OperationRunSuccess {
                            kind: "propertyDelete",
                            result,
                            paths: std::slice::from_ref(&property_request.path),
                            depth: "empty",
                            reason: "operationPropertyDelete",
                            revision: None,
                        },
                    ),
                    Err(failure) => self.operation_run_failure(
                        request,
                        &session_repository_id,
                        session_epoch,
                        "operationPropertyDeleteFailed",
                        failure,
                    ),
                }
            }
            ParsedOperation::ChangelistSet(changelist_request) => {
                match bridge.operation_changelist_set_with_cancellation(
                    &session_identity,
                    &changelist_request,
                    cancellation,
                ) {
                    Ok(result) => self.operation_run_success(
                        request,
                        session_repository_id,
                        session_epoch,
                        OperationRunSuccess {
                            kind: "changelistSet",
                            result,
                            paths: &changelist_request.paths,
                            depth: &changelist_request.depth,
                            reason: "operationChangelistSet",
                            revision: None,
                        },
                    ),
                    Err(failure) => self.operation_run_failure(
                        request,
                        &session_repository_id,
                        session_epoch,
                        "operationChangelistSetFailed",
                        failure,
                    ),
                }
            }
            ParsedOperation::ChangelistClear(changelist_request) => {
                match bridge.operation_changelist_clear_with_cancellation(
                    &session_identity,
                    &changelist_request,
                    cancellation,
                ) {
                    Ok(result) => self.operation_run_success(
                        request,
                        session_repository_id,
                        session_epoch,
                        OperationRunSuccess {
                            kind: "changelistClear",
                            result,
                            paths: &changelist_request.paths,
                            depth: &changelist_request.depth,
                            reason: "operationChangelistClear",
                            revision: None,
                        },
                    ),
                    Err(failure) => self.operation_run_failure(
                        request,
                        &session_repository_id,
                        session_epoch,
                        "operationChangelistClearFailed",
                        failure,
                    ),
                }
            }
            ParsedOperation::Lock(lock_request) => {
                match bridge.operation_lock_with_cancellation(
                    &session_identity,
                    &lock_request,
                    auth,
                    cancellation,
                ) {
                    Ok(result) => self.operation_run_success(
                        request,
                        session_repository_id,
                        session_epoch,
                        OperationRunSuccess {
                            kind: "lock",
                            result,
                            paths: &lock_request.paths,
                            depth: "empty",
                            reason: "operationLock",
                            revision: None,
                        },
                    ),
                    Err(failure) => self.operation_run_failure(
                        request,
                        &session_repository_id,
                        session_epoch,
                        "operationLockFailed",
                        failure,
                    ),
                }
            }
            ParsedOperation::Unlock(unlock_request) => {
                match bridge.operation_unlock_with_cancellation(
                    &session_identity,
                    &unlock_request,
                    auth,
                    cancellation,
                ) {
                    Ok(result) => self.operation_run_success(
                        request,
                        session_repository_id,
                        session_epoch,
                        OperationRunSuccess {
                            kind: "unlock",
                            result,
                            paths: &unlock_request.paths,
                            depth: "empty",
                            reason: "operationUnlock",
                            revision: None,
                        },
                    ),
                    Err(failure) => self.operation_run_failure(
                        request,
                        &session_repository_id,
                        session_epoch,
                        "operationUnlockFailed",
                        failure,
                    ),
                }
            }
            ParsedOperation::BranchCreate(branch_request) => {
                match bridge.operation_branch_create_with_cancellation(
                    &session_identity,
                    &branch_request,
                    auth,
                    cancellation,
                ) {
                    Ok(branch_result) => self.operation_run_remote_success(
                        request,
                        OperationRunRemoteSuccess {
                            repository_id: session_repository_id,
                            epoch: session_epoch,
                            kind: "branchCreate",
                            result: branch_result.result,
                            revision: Some(branch_result.revision),
                        },
                    ),
                    Err(failure) => self.operation_run_failure(
                        request,
                        &session_repository_id,
                        session_epoch,
                        "operationBranchCreateFailed",
                        failure,
                    ),
                }
            }
            ParsedOperation::Switch(switch_request) => {
                match bridge.operation_switch_with_cancellation(
                    &session_identity,
                    &switch_request,
                    auth,
                    cancellation,
                ) {
                    Ok(switch_result) => self.operation_run_full_reconcile_success(
                        request,
                        OperationRunFullReconcileSuccess {
                            repository_id: session_repository_id,
                            epoch: session_epoch,
                            kind: "switch",
                            stale_reason: "operationSwitchRequiresFullReconcile",
                            result: switch_result.result,
                            revision: Some(switch_result.revision),
                        },
                    ),
                    Err(failure) => self.operation_run_failure(
                        request,
                        &session_repository_id,
                        session_epoch,
                        "operationSwitchFailed",
                        failure,
                    ),
                }
            }
            ParsedOperation::Relocate(relocate_request) => {
                match bridge.operation_relocate_with_cancellation(
                    &session_identity,
                    &relocate_request,
                    auth,
                    cancellation,
                ) {
                    Ok(result) => match self.refresh_relocated_session_identity(
                        bridge,
                        &session_repository_id,
                        session_epoch,
                        &session_identity.working_copy_root,
                    ) {
                        Ok(()) => self.operation_run_full_reconcile_success(
                            request,
                            OperationRunFullReconcileSuccess {
                                repository_id: session_repository_id,
                                epoch: session_epoch,
                                kind: "relocate",
                                stale_reason: "operationRelocateRequiresFullReconcile",
                                result,
                                revision: None,
                            },
                        ),
                        Err(failure) => self.operation_run_failure(
                            request,
                            &session_repository_id,
                            session_epoch,
                            "operationRelocateFailed",
                            failure,
                        ),
                    },
                    Err(failure) => self.operation_run_failure(
                        request,
                        &session_repository_id,
                        session_epoch,
                        "operationRelocateFailed",
                        failure,
                    ),
                }
            }
            ParsedOperation::Merge(merge_request) => {
                match bridge.operation_merge_with_cancellation(
                    &session_identity,
                    &merge_request,
                    auth,
                    cancellation,
                ) {
                    Ok(result) => {
                        if merge_request.dry_run {
                            let target_paths = if result.touched_paths.is_empty() {
                                vec![merge_request.target_path.clone()]
                            } else {
                                result.touched_paths.clone()
                            };
                            self.operation_run_success(
                                request,
                                session_repository_id,
                                session_epoch,
                                OperationRunSuccess {
                                    kind: "merge",
                                    result,
                                    paths: &target_paths,
                                    depth: &merge_request.depth,
                                    reason: "operationMergePreview",
                                    revision: None,
                                },
                            )
                        } else {
                            self.operation_run_full_reconcile_success(
                                request,
                                OperationRunFullReconcileSuccess {
                                    repository_id: session_repository_id,
                                    epoch: session_epoch,
                                    kind: "merge",
                                    stale_reason: "operationMergeRequiresFullReconcile",
                                    result,
                                    revision: None,
                                },
                            )
                        }
                    }
                    Err(failure) => self.operation_run_failure(
                        request,
                        &session_repository_id,
                        session_epoch,
                        "operationMergeFailed",
                        failure,
                    ),
                }
            }
            ParsedOperation::Commit(commit_request) => {
                match bridge.operation_commit_with_cancellation(
                    &session_identity,
                    &commit_request,
                    auth,
                    cancellation,
                ) {
                    Ok(commit_result) => self.operation_run_success(
                        request,
                        session_repository_id,
                        session_epoch,
                        OperationRunSuccess {
                            kind: "commit",
                            result: commit_result.result,
                            paths: &commit_request.paths,
                            depth: &commit_request.depth,
                            reason: "operationCommit",
                            revision: Some(commit_result.revision),
                        },
                    ),
                    Err(failure) => self.operation_run_failure(
                        request,
                        &session_repository_id,
                        session_epoch,
                        "operationCommitFailed",
                        failure,
                    ),
                }
            }
        }
    }

    fn refresh_relocated_session_identity(
        &mut self,
        bridge: &dyn BridgeApi,
        expected_repository_id: &str,
        epoch: u64,
        working_copy_root: &str,
    ) -> Result<(), BridgeFailure> {
        let refreshed_identity = bridge.open_working_copy(working_copy_root)?;
        let refreshed_repository_id = repository_id(&refreshed_identity);
        if refreshed_repository_id != expected_repository_id {
            return Err(BridgeFailure::new(
                "SVN_OPERATION_RELOCATE_IDENTITY_MISMATCH",
                "protocol",
                "error.operation.relocateIdentityMismatch",
                json!({
                    "repositoryId": expected_repository_id,
                    "actualRepositoryId": refreshed_repository_id,
                }),
                false,
            ));
        }

        let Some(session) = self.repositories.get_mut(expected_repository_id) else {
            return Err(BridgeFailure::new(
                "SVN_OPERATION_RELOCATE_SESSION_NOT_OPEN",
                "lifecycle",
                "error.operation.relocateSessionNotOpen",
                json!({ "repositoryId": expected_repository_id }),
                false,
            ));
        };
        if session.epoch != epoch {
            return Err(BridgeFailure::new(
                "SVN_OPERATION_RELOCATE_SESSION_NOT_OPEN",
                "lifecycle",
                "error.operation.relocateSessionNotOpen",
                json!({ "repositoryId": expected_repository_id, "epoch": epoch }),
                false,
            ));
        }
        session.identity = refreshed_identity;
        Ok(())
    }

    fn operation_run_success(
        &mut self,
        request: &JsonRpcRequest,
        repository_id: String,
        epoch: u64,
        success: OperationRunSuccess<'_>,
    ) -> (DispatchOutcome, Value) {
        let operation_id = format!("op-{}", self.next_operation_id);
        self.next_operation_id += 1;
        let warnings = success
            .result
            .skipped_paths
            .iter()
            .map(|path| OperationWarning {
                code: "SVN_OPERATION_PATH_SKIPPED".to_string(),
                message_key: "warning.operation.pathSkipped".to_string(),
                args: json!({ "path": path }),
            })
            .collect::<Vec<_>>();
        let response = OperationRunResponse {
            repository_id,
            epoch,
            operation_id,
            kind: success.kind.to_string(),
            touched_paths: success.result.touched_paths.clone(),
            revision: success.revision,
            summary: OperationSummary {
                affected_paths: success.result.touched_paths.len() as u32,
                skipped_paths: success.result.skipped_paths.len() as u32,
            },
            warnings,
            reconcile: OperationReconcileHint {
                targets: success
                    .paths
                    .iter()
                    .map(|path| StatusRefreshTarget {
                        path: path.clone(),
                        depth: success.depth.to_string(),
                        reason: success.reason.to_string(),
                    })
                    .collect(),
                requires_full_reconcile: false,
            },
        };
        (
            DispatchOutcome::Continue,
            json!({
                "jsonrpc": "2.0",
                "id": request.id,
                "result": response,
            }),
        )
    }

    fn operation_run_full_reconcile_success(
        &mut self,
        request: &JsonRpcRequest,
        success: OperationRunFullReconcileSuccess<'_>,
    ) -> (DispatchOutcome, Value) {
        let operation_id = format!("op-{}", self.next_operation_id);
        self.next_operation_id += 1;
        let warnings = success
            .result
            .skipped_paths
            .iter()
            .map(|path| OperationWarning {
                code: "SVN_OPERATION_PATH_SKIPPED".to_string(),
                message_key: "warning.operation.pathSkipped".to_string(),
                args: json!({ "path": path }),
            })
            .collect::<Vec<_>>();
        self.pending_notifications.push(status_stale_notification(
            &success.repository_id,
            success.epoch,
            success.stale_reason,
        ));
        let response = OperationRunResponse {
            repository_id: success.repository_id,
            epoch: success.epoch,
            operation_id,
            kind: success.kind.to_string(),
            touched_paths: success.result.touched_paths.clone(),
            revision: success.revision,
            summary: OperationSummary {
                affected_paths: success.result.touched_paths.len() as u32,
                skipped_paths: success.result.skipped_paths.len() as u32,
            },
            warnings,
            reconcile: OperationReconcileHint {
                targets: Vec::new(),
                requires_full_reconcile: true,
            },
        };
        (
            DispatchOutcome::Continue,
            json!({
                "jsonrpc": "2.0",
                "id": request.id,
                "result": response,
            }),
        )
    }

    fn operation_run_remote_success(
        &mut self,
        request: &JsonRpcRequest,
        success: OperationRunRemoteSuccess<'_>,
    ) -> (DispatchOutcome, Value) {
        let operation_id = format!("op-{}", self.next_operation_id);
        self.next_operation_id += 1;
        let warnings = success
            .result
            .skipped_paths
            .iter()
            .map(|path| OperationWarning {
                code: "SVN_OPERATION_PATH_SKIPPED".to_string(),
                message_key: "warning.operation.pathSkipped".to_string(),
                args: json!({ "path": path }),
            })
            .collect::<Vec<_>>();
        let response = OperationRunResponse {
            repository_id: success.repository_id,
            epoch: success.epoch,
            operation_id,
            kind: success.kind.to_string(),
            touched_paths: success.result.touched_paths.clone(),
            revision: success.revision,
            summary: OperationSummary {
                affected_paths: success.result.touched_paths.len() as u32,
                skipped_paths: success.result.skipped_paths.len() as u32,
            },
            warnings,
            reconcile: OperationReconcileHint {
                targets: Vec::new(),
                requires_full_reconcile: false,
            },
        };
        (
            DispatchOutcome::Continue,
            json!({
                "jsonrpc": "2.0",
                "id": request.id,
                "result": response,
            }),
        )
    }

    fn operation_run_failure(
        &mut self,
        request: &JsonRpcRequest,
        repository_id: &str,
        epoch: u64,
        stale_reason: &str,
        failure: crate::BridgeFailure,
    ) -> (DispatchOutcome, Value) {
        self.pending_notifications.push(status_stale_notification(
            repository_id,
            epoch,
            stale_reason,
        ));
        (
            DispatchOutcome::Continue,
            json!({
                "jsonrpc": "2.0",
                "id": request.id,
                "error": bridge_error(failure),
            }),
        )
    }

    fn dispatch_remote_recover_working_copy(
        &mut self,
        request: &JsonRpcRequest,
    ) -> (DispatchOutcome, Value) {
        if let Some(field) = unexpected_param(
            request,
            &[
                "repositoryId",
                "epoch",
                "originOperationId",
                "operationId",
                "timeoutMs",
            ],
        ) {
            return invalid_param(request, &field);
        }
        let Some(repository_id) = repository_id_param(request) else {
            return invalid_repository_id(request);
        };
        let Some(epoch) = epoch_param(request) else {
            return invalid_param(request, "epoch");
        };
        let Some(operation_id) = request
            .params
            .as_ref()
            .and_then(|params| params.get("operationId"))
            .and_then(Value::as_str)
            .filter(|operation_id| is_canonical_uuid(operation_id))
        else {
            return invalid_param(request, "operationId");
        };
        let operation_id = operation_id.to_string();
        let Some(origin_operation_id) = request
            .params
            .as_ref()
            .and_then(|params| params.get("originOperationId"))
            .and_then(Value::as_str)
            .filter(|origin_operation_id| is_canonical_uuid(origin_operation_id))
        else {
            return invalid_param(request, "originOperationId");
        };
        if origin_operation_id == operation_id {
            return invalid_param(request, "operationId");
        }
        let origin_operation_id = origin_operation_id.to_string();
        let Some(timeout_ms) = request
            .params
            .as_ref()
            .and_then(|params| params.get("timeoutMs"))
            .and_then(Value::as_u64)
            .filter(|timeout_ms| *timeout_ms > 0 && *timeout_ms <= MAX_REMOTE_TIMEOUT_MS)
        else {
            return invalid_param(request, "timeoutMs");
        };
        let Some(session) = self.repositories.get(repository_id) else {
            return repository_not_open(request, repository_id);
        };
        if session.epoch != epoch {
            return repository_not_open(request, repository_id);
        }
        let lane_key = absolute_path_key(&normalize_absolute_path_text(
            &session.identity.working_copy_root,
        ));
        let identity = session.identity.clone();
        let boundary_roots = session.boundary_roots.clone();
        let generation = session.next_generation;

        let recovery_id_reused = self
            .remote_native_lanes
            .get(&lane_key)
            .is_some_and(|state| {
                matches!(
                    state,
                    RemoteNativeLaneState::Recovering {
                        origin_operation_id,
                        recovery_operation_id,
                        used_recovery_operation_ids,
                    } if origin_operation_id == &operation_id
                        || recovery_operation_id.as_ref() == Some(&operation_id)
                        || used_recovery_operation_ids.contains(&operation_id)
                )
            });
        if recovery_id_reused || self.active_remote_operation_ids.contains(&operation_id) {
            return bridge_failure_response(
                request,
                BridgeFailure::new(
                    "SUBVERSIONR_REMOTE_RECOVERY_OPERATION_ID_REUSED",
                    "protocol",
                    "error.remote.recoveryOperationIdReused",
                    json!({}),
                    false,
                ),
            );
        }

        let (origin_operation_id, used_recovery_operation_ids) =
            match self.remote_native_lanes.get(&lane_key) {
                Some(RemoteNativeLaneState::Recovering {
                    origin_operation_id: lane_origin_operation_id,
                    recovery_operation_id: None,
                    used_recovery_operation_ids,
                }) if lane_origin_operation_id == &origin_operation_id => {
                    (origin_operation_id, used_recovery_operation_ids.clone())
                }
                Some(RemoteNativeLaneState::Recovering {
                    recovery_operation_id: None,
                    ..
                }) => {
                    return bridge_failure_response(
                        request,
                        BridgeFailure::new(
                            "SUBVERSIONR_REMOTE_RECOVERY_ORIGIN_MISMATCH",
                            "protocol",
                            "error.remote.recoveryOriginMismatch",
                            json!({}),
                            false,
                        ),
                    );
                }
                Some(RemoteNativeLaneState::Blocked {
                    cleanup_appropriate,
                    ..
                }) => {
                    let failure = subversionr_protocol::RemoteFailure {
                        category: subversionr_protocol::RemoteFailureCategory::Recovery,
                        reason: RemoteFailureClass::RemoteRecoveryBlocked,
                        cleanup_appropriate: *cleanup_appropriate,
                    };
                    return remote_recovery_response(
                        request,
                        RemoteRecoveryOutcome::Blocked {
                            operation_id,
                            failure,
                        },
                    );
                }
                Some(RemoteNativeLaneState::Recovering { .. })
                | Some(RemoteNativeLaneState::Active { .. }) => {
                    return bridge_failure_response(
                        request,
                        BridgeFailure::new(
                            "SUBVERSIONR_REMOTE_NATIVE_LANE_BUSY",
                            "state",
                            "error.remote.nativeLaneBusy",
                            json!({}),
                            true,
                        ),
                    );
                }
                None => (origin_operation_id, BTreeSet::new()),
            };

        if used_recovery_operation_ids.len() >= MAX_REMOTE_RECOVERY_OPERATION_IDS {
            self.remote_native_lanes.insert(
                lane_key,
                RemoteNativeLaneState::Blocked {
                    origin_operation_id: origin_operation_id.clone(),
                    reason: RemoteFailureClass::RemoteRecoveryBlocked,
                    cleanup_appropriate: false,
                },
            );
            self.push_remote_connection_state(
                Some(repository_id),
                Some(epoch),
                RemoteConnectionState::Indeterminate {
                    reason: RemoteIndeterminateReason::WorkerTerminated,
                    origin_operation_id,
                    recovery: RemoteRecoveryState::Blocked,
                    cleanup_appropriate: false,
                },
            );
            return remote_recovery_response(
                request,
                RemoteRecoveryOutcome::Blocked {
                    operation_id,
                    failure: subversionr_protocol::RemoteFailure {
                        category: subversionr_protocol::RemoteFailureCategory::Recovery,
                        reason: RemoteFailureClass::RemoteRecoveryBlocked,
                        cleanup_appropriate: false,
                    },
                },
            );
        }

        self.active_remote_operation_ids
            .insert(operation_id.clone());
        self.remote_native_lanes.insert(
            lane_key.clone(),
            RemoteNativeLaneState::Recovering {
                origin_operation_id: origin_operation_id.clone(),
                recovery_operation_id: Some(operation_id.clone()),
                used_recovery_operation_ids,
            },
        );
        let deadline = Instant::now() + Duration::from_millis(timeout_ms);
        self.pending_remote_recovery_launch = Some(RemoteRecoveryLaunchPlan {
            request_id: request.id.clone(),
            repository_id: repository_id.to_string(),
            epoch,
            lane_key,
            origin_operation_id,
            operation_id,
            identity,
            boundary_roots,
            generation,
            deadline,
        });
        (DispatchOutcome::Continue, Value::Null)
    }

    pub(crate) fn settle_remote_recovery(
        &mut self,
        launch: &RemoteRecoveryLaunchPlan,
        recovery: Result<StatusSnapshot, BridgeFailure>,
    ) -> (DispatchOutcome, Value) {
        let request = JsonRpcRequest {
            id: launch.request_id.clone(),
            method: "remote/recoverWorkingCopy".to_string(),
            params: None,
        };
        let lane_matches = matches!(
            self.remote_native_lanes.get(&launch.lane_key),
            Some(RemoteNativeLaneState::Recovering {
                origin_operation_id,
                recovery_operation_id: Some(recovery_operation_id),
                ..
            }) if origin_operation_id == &launch.origin_operation_id
                && recovery_operation_id == &launch.operation_id
        );
        self.active_remote_operation_ids
            .remove(&launch.operation_id);
        if !lane_matches {
            return bridge_failure_response(
                &request,
                BridgeFailure::new(
                    "SUBVERSIONR_REMOTE_RECOVERY_SETTLEMENT_INVALID",
                    "state",
                    "error.remote.recoverySettlementInvalid",
                    json!({}),
                    false,
                ),
            );
        }

        match recovery {
            Ok(mut snapshot) => {
                let Some(session) = self.repositories.get_mut(&launch.repository_id) else {
                    return bridge_failure_response(
                        &request,
                        BridgeFailure::new(
                            "SUBVERSIONR_REMOTE_RECOVERY_SESSION_LOST",
                            "state",
                            "error.remote.recoverySessionLost",
                            json!({}),
                            false,
                        ),
                    );
                };
                if session.epoch != launch.epoch {
                    return bridge_failure_response(
                        &request,
                        BridgeFailure::new(
                            "SUBVERSIONR_REMOTE_RECOVERY_SESSION_LOST",
                            "state",
                            "error.remote.recoverySessionLost",
                            json!({}),
                            false,
                        ),
                    );
                }
                snapshot.repository_id = launch.repository_id.clone();
                snapshot.epoch = launch.epoch;
                snapshot.generation = launch.generation;
                for entry in &mut snapshot.local_entries {
                    entry.generation = launch.generation;
                }
                filter_snapshot_boundaries(&mut snapshot, &launch.boundary_roots);
                remove_conflict_artifact_entries(&mut snapshot.local_entries);
                session.local_entries = snapshot
                    .local_entries
                    .into_iter()
                    .filter(is_projectable_status)
                    .map(|entry| (entry.path.clone(), entry))
                    .collect();
                session.next_generation += 1;
                self.remote_native_lanes.remove(&launch.lane_key);
                self.pending_notifications.push(status_stale_notification(
                    &launch.repository_id,
                    launch.epoch,
                    "remoteRecoverySafeRequiresFullReconcile",
                ));
                self.push_remote_connection_state(
                    Some(&launch.repository_id),
                    Some(launch.epoch),
                    RemoteConnectionState::Unchecked,
                );
                remote_recovery_response(
                    &request,
                    RemoteRecoveryOutcome::Safe {
                        operation_id: launch.operation_id.clone(),
                        completed_at: current_timestamp(),
                    },
                )
            }
            Err(failure) => self.finish_indeterminate_recovery(
                &request,
                &launch.lane_key,
                &launch.repository_id,
                launch.epoch,
                launch.origin_operation_id.clone(),
                launch.operation_id.clone(),
                failure,
            ),
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn finish_indeterminate_recovery(
        &mut self,
        request: &JsonRpcRequest,
        lane_key: &str,
        repository_id: &str,
        epoch: u64,
        origin_operation_id: String,
        operation_id: String,
        failure: BridgeFailure,
    ) -> (DispatchOutcome, Value) {
        let remote_failure = classify_remote_failure(&failure);
        if remote_failure.reason == RemoteFailureClass::RemoteRecoveryBlocked {
            self.remote_native_lanes.insert(
                lane_key.to_string(),
                RemoteNativeLaneState::Blocked {
                    origin_operation_id: origin_operation_id.clone(),
                    reason: remote_failure.reason,
                    cleanup_appropriate: remote_failure.cleanup_appropriate,
                },
            );
            self.push_remote_connection_state(
                Some(repository_id),
                Some(epoch),
                RemoteConnectionState::Indeterminate {
                    reason: RemoteIndeterminateReason::WorkerTerminated,
                    origin_operation_id,
                    recovery: RemoteRecoveryState::Blocked,
                    cleanup_appropriate: remote_failure.cleanup_appropriate,
                },
            );
            remote_recovery_response(
                request,
                RemoteRecoveryOutcome::Blocked {
                    operation_id,
                    failure: remote_failure,
                },
            )
        } else {
            let mut used_recovery_operation_ids = match self.remote_native_lanes.get(lane_key) {
                Some(RemoteNativeLaneState::Recovering {
                    used_recovery_operation_ids,
                    ..
                }) => used_recovery_operation_ids.clone(),
                _ => BTreeSet::new(),
            };
            used_recovery_operation_ids.insert(operation_id.clone());
            self.remote_native_lanes.insert(
                lane_key.to_string(),
                RemoteNativeLaneState::Recovering {
                    origin_operation_id: origin_operation_id.clone(),
                    recovery_operation_id: None,
                    used_recovery_operation_ids,
                },
            );
            self.push_remote_connection_state(
                Some(repository_id),
                Some(epoch),
                RemoteConnectionState::Indeterminate {
                    reason: RemoteIndeterminateReason::WorkerTerminated,
                    origin_operation_id,
                    recovery: RemoteRecoveryState::Pending,
                    cleanup_appropriate: remote_failure.cleanup_appropriate,
                },
            );
            remote_recovery_response(
                request,
                RemoteRecoveryOutcome::Indeterminate {
                    operation_id,
                    failure: remote_failure,
                },
            )
        }
    }

    fn dispatch_shutdown(&self, request: &JsonRpcRequest) -> (DispatchOutcome, Value) {
        if let Some(field) = unexpected_param(request, &[]) {
            return invalid_param(request, &field);
        }
        if let Err(failure) = self.remote_worker.disconnect() {
            return bridge_failure_response(request, failure);
        }
        (
            DispatchOutcome::Shutdown,
            json!({
                "jsonrpc": "2.0",
                "id": request.id,
                "result": { "accepted": true },
            }),
        )
    }

    fn begin_remote_preflight(
        &mut self,
        request: &JsonRpcRequest,
        urls: &[&str],
        lane_key: &str,
        bridge: &dyn BridgeApi,
        cancellation: &dyn BridgeCancellationToken,
        svn_anonymous_request: Option<crate::RemoteSvnAnonymousRequest>,
    ) -> Option<(DispatchOutcome, Value)> {
        let operation = match preflight_repository_urls(request, urls, self.remote_trust.as_ref()) {
            Ok(None) => return None,
            Ok(Some(operation)) => operation,
            Err(failure) => {
                return Some(bridge_failure_response(
                    request,
                    attach_remote_failure(failure),
                ));
            }
        };
        let effect = match remote_effect_for_request(request) {
            Some(effect) => effect,
            None => {
                return Some(bridge_failure_response(
                    request,
                    attach_remote_failure(BridgeFailure::new(
                        "SUBVERSIONR_REMOTE_EFFECT_UNCLASSIFIED",
                        "protocol",
                        "error.remote.effectUnclassified",
                        json!({}),
                        false,
                    )),
                ));
            }
        };

        let direct_svn_anonymous = operation.config.scheme == crate::RemoteConfigScheme::Svn
            && operation.config.server_auth == crate::RemoteConfigServerAuth::Anonymous;
        if direct_svn_anonymous {
            if !self.remote_worker.svn_anonymous_available() {
                return Some(bridge_failure_response(
                    request,
                    attach_remote_failure(unsupported_transport(&operation.endpoint)),
                ));
            }
            if svn_anonymous_request.is_none() {
                return Some(bridge_failure_response(
                    request,
                    attach_remote_failure(unsupported_transport(&operation.endpoint)),
                ));
            }
        }

        if !self.remote_worker.capability_available() {
            let endpoint = operation.endpoint.clone();
            let mut unavailable_auth = UnavailableAuthRequestBroker;
            return Some(
                match self
                    .remote_worker
                    .execute(
                        &operation.envelope,
                        operation.config,
                        lane_key,
                        effect,
                        cancellation,
                        &mut unavailable_auth,
                        bridge,
                        operation.deadline,
                    )
                    .result
                {
                    Ok(()) => bridge_failure_response(
                        request,
                        attach_remote_failure(unsupported_transport(&endpoint)),
                    ),
                    Err(failure) => {
                        bridge_failure_response(request, attach_remote_failure(failure))
                    }
                },
            );
        }

        let normalized_lane = absolute_path_key(&normalize_absolute_path_text(lane_key));
        let attribution = self.repositories.values().find(|session| {
            absolute_path_key(&normalize_absolute_path_text(
                &session.identity.working_copy_root,
            )) == normalized_lane
        });
        let repository_id = attribution.map(|session| session.repository_id.clone());
        let epoch = attribution.map(|session| session.epoch);
        if let Some(failure) = self.reserve_remote_lane(
            &normalized_lane,
            &operation.envelope.operation_id,
            effect,
            repository_id.clone(),
            epoch,
        ) {
            return Some(bridge_failure_response(request, failure));
        }
        if direct_svn_anonymous {
            if let Some(crate::RemoteSvnAnonymousRequest::Checkout { request: checkout }) =
                svn_anonymous_request.as_ref()
            {
                let Some(journal) = self.remote_checkout_journal.as_mut() else {
                    self.active_remote_operation_ids
                        .remove(&operation.envelope.operation_id);
                    self.remote_native_lanes.remove(&normalized_lane);
                    return Some(bridge_failure_response(
                        request,
                        remote_checkout_journal_contract_failure("notInitialized"),
                    ));
                };
                if let Err(error) =
                    journal.arm(&checkout.target_path, &operation.envelope.operation_id)
                {
                    self.active_remote_operation_ids
                        .remove(&operation.envelope.operation_id);
                    self.remote_native_lanes.remove(&normalized_lane);
                    return Some(bridge_failure_response(
                        request,
                        remote_checkout_journal_failure(error),
                    ));
                }
            }
        }
        let checking_state = RemoteConnectionState::Checking {
            operation_id: operation.envelope.operation_id.clone(),
            started_at: current_timestamp(),
        };
        self.pending_remote_launch = Some(RemoteLaunchPlan {
            request_id: request.id.clone(),
            lane_key: normalized_lane.clone(),
            repository_id: repository_id.clone(),
            epoch,
            effect,
            operation,
            svn_anonymous_request: direct_svn_anonymous
                .then_some(svn_anonymous_request)
                .flatten(),
        });
        self.push_remote_connection_state(repository_id.as_deref(), epoch, checking_state);
        Some((DispatchOutcome::Continue, Value::Null))
    }

    fn reserve_remote_lane(
        &mut self,
        lane_key: &str,
        operation_id: &str,
        effect: RemoteOperationEffect,
        repository_id: Option<String>,
        epoch: Option<u64>,
    ) -> Option<BridgeFailure> {
        if self.active_remote_operation_ids.contains(operation_id) {
            return Some(BridgeFailure::new(
                "SUBVERSIONR_REMOTE_OPERATION_IN_PROGRESS",
                "state",
                "error.remote.operationInProgress",
                json!({}),
                false,
            ));
        }
        if let Some(state) = self.remote_native_lanes.get(lane_key) {
            return Some(match state {
                RemoteNativeLaneState::Active { .. } => BridgeFailure::new(
                    "SUBVERSIONR_REMOTE_NATIVE_LANE_BUSY",
                    "state",
                    "error.remote.nativeLaneBusy",
                    json!({}),
                    true,
                ),
                RemoteNativeLaneState::Recovering { .. } => BridgeFailure::new(
                    "SUBVERSIONR_REMOTE_OPERATION_INDETERMINATE",
                    "state",
                    "error.remote.operationIndeterminate",
                    json!({}),
                    false,
                ),
                RemoteNativeLaneState::Blocked { .. } => BridgeFailure::new(
                    "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED",
                    "state",
                    "error.remote.recoveryBlocked",
                    json!({}),
                    false,
                ),
            });
        }
        self.active_remote_operation_ids
            .insert(operation_id.to_string());
        self.remote_native_lanes.insert(
            lane_key.to_string(),
            RemoteNativeLaneState::Active {
                operation_id: operation_id.to_string(),
                effect,
                repository_id,
                epoch,
            },
        );
        None
    }

    pub(crate) fn settle_remote_launch(
        &mut self,
        lane_key: &str,
        operation_id: &str,
        settlement: &RemoteWorkerSettlement,
    ) -> Option<BridgeFailure> {
        let (attributed_repository_id, attributed_epoch, daemon_effect) =
            match self.remote_native_lanes.get(lane_key) {
                Some(RemoteNativeLaneState::Active {
                    operation_id: active,
                    effect,
                    repository_id,
                    epoch,
                }) if active == operation_id => (repository_id.clone(), *epoch, *effect),
                _ => {
                    let owned_by_another_lane =
                        self.remote_native_lanes
                            .iter()
                            .any(|(candidate_lane, state)| {
                                candidate_lane != lane_key
                                    && matches!(
                                        state,
                                        RemoteNativeLaneState::Active {
                                            operation_id: active,
                                            ..
                                        } if active == operation_id
                                    )
                            });
                    if !owned_by_another_lane {
                        self.active_remote_operation_ids.remove(operation_id);
                    }
                    return None;
                }
            };
        let attribution = (attributed_repository_id, attributed_epoch);
        let checkout_entry = self.remote_checkout_journal.as_ref().and_then(|journal| {
            journal
                .entries()
                .iter()
                .find(|entry| entry.origin_operation_id == operation_id)
                .cloned()
        });
        if daemon_effect == settlement.effect
            && settlement.cleanup_safe()
            && settlement.result.is_ok()
            && settlement.operation_output.is_some()
        {
            return None;
        }
        self.active_remote_operation_ids.remove(operation_id);
        if let Some(entry) = checkout_entry {
            let journal_result = if settlement.cleanup_safe()
                && settlement.result.is_err()
                && !settlement.may_have_mutated()
            {
                self.remote_checkout_journal
                    .as_mut()
                    .expect("checkout journal entry requires initialized journal")
                    .clear(&entry.target_sha256, operation_id)
            } else {
                self.remote_checkout_journal
                    .as_mut()
                    .expect("checkout journal entry requires initialized journal")
                    .mark_blocked(&entry.target_sha256, operation_id)
            };
            if let Err(error) = journal_result {
                self.remote_native_lanes.insert(
                    lane_key.to_string(),
                    RemoteNativeLaneState::Blocked {
                        origin_operation_id: operation_id.to_string(),
                        reason: RemoteFailureClass::RemoteRecoveryBlocked,
                        cleanup_appropriate: false,
                    },
                );
                return Some(attach_remote_failure(remote_checkout_journal_failure(
                    error,
                )));
            }
        }
        if attribution.0.is_none() != attribution.1.is_none() {
            self.remote_native_lanes.insert(
                lane_key.to_string(),
                RemoteNativeLaneState::Blocked {
                    origin_operation_id: operation_id.to_string(),
                    reason: RemoteFailureClass::RemoteOperationIndeterminate,
                    cleanup_appropriate: false,
                },
            );
            return Some(attach_remote_failure(BridgeFailure::new(
                "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED",
                "state",
                "error.remote.recoveryBlocked",
                json!({}),
                false,
            )));
        }
        if daemon_effect != settlement.effect || !settlement.cleanup_safe() {
            self.remote_native_lanes.insert(
                lane_key.to_string(),
                RemoteNativeLaneState::Blocked {
                    origin_operation_id: operation_id.to_string(),
                    reason: RemoteFailureClass::RemoteRecoveryBlocked,
                    cleanup_appropriate: false,
                },
            );
            self.push_remote_connection_state(
                attribution.0.as_deref(),
                attribution.1,
                RemoteConnectionState::Indeterminate {
                    reason: RemoteIndeterminateReason::WorkerTerminated,
                    origin_operation_id: operation_id.to_string(),
                    recovery: RemoteRecoveryState::Blocked,
                    cleanup_appropriate: false,
                },
            );
            return Some(attach_remote_failure(BridgeFailure::new(
                "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED",
                "state",
                "error.remote.recoveryBlocked",
                json!({}),
                false,
            )));
        } else if settlement.result.is_err() && settlement.may_have_mutated() {
            if attribution.0.is_none() {
                self.remote_native_lanes.insert(
                    lane_key.to_string(),
                    RemoteNativeLaneState::Blocked {
                        origin_operation_id: operation_id.to_string(),
                        reason: RemoteFailureClass::RemoteOperationIndeterminate,
                        cleanup_appropriate: false,
                    },
                );
                return Some(attach_remote_failure(BridgeFailure::new(
                    "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED",
                    "state",
                    "error.remote.recoveryBlocked",
                    json!({}),
                    false,
                )));
            }
            let reason = if settlement
                .remote_failure
                .as_ref()
                .is_some_and(|failure| failure.reason == RemoteFailureClass::OperationCancelled)
            {
                RemoteIndeterminateReason::CancelledAfterMutation
            } else {
                RemoteIndeterminateReason::WorkerTerminated
            };
            self.remote_native_lanes.insert(
                lane_key.to_string(),
                RemoteNativeLaneState::Recovering {
                    origin_operation_id: operation_id.to_string(),
                    recovery_operation_id: None,
                    used_recovery_operation_ids: BTreeSet::new(),
                },
            );
            self.push_remote_connection_state(
                attribution.0.as_deref(),
                attribution.1,
                RemoteConnectionState::Indeterminate {
                    reason,
                    origin_operation_id: operation_id.to_string(),
                    recovery: RemoteRecoveryState::Pending,
                    cleanup_appropriate: false,
                },
            );
        } else {
            self.remote_native_lanes.remove(lane_key);
            let state = match settlement.result.as_ref() {
                Ok(()) if settlement.operation_output.is_some() => RemoteConnectionState::Online {
                    transport: RemoteScheme::Svn,
                    checked_at: current_timestamp(),
                },
                Ok(()) => RemoteConnectionState::Attention {
                    reason: RemoteAttentionReason::UnsupportedCapability,
                },
                Err(failure) => connection_state_for_failure(failure, operation_id),
            };
            self.push_remote_connection_state(attribution.0.as_deref(), attribution.1, state);
        }
        None
    }

    fn complete_checkout_journal_entry(
        &mut self,
        target_path: &str,
        operation_id: &str,
    ) -> Result<(), BridgeFailure> {
        let entry = self.checkout_journal_entry(target_path, operation_id)?;
        self.remote_checkout_journal
            .as_mut()
            .expect("validated checkout journal must remain initialized")
            .clear(&entry.target_sha256, operation_id)
            .map_err(remote_checkout_journal_failure)?;
        let lane_key = absolute_path_key(&normalize_absolute_path_text(target_path));
        self.active_remote_operation_ids.remove(operation_id);
        self.remote_native_lanes.remove(&lane_key);
        Ok(())
    }

    fn block_checkout_journal_entry(
        &mut self,
        target_path: &str,
        operation_id: &str,
    ) -> Result<(), BridgeFailure> {
        let entry = self.checkout_journal_entry(target_path, operation_id)?;
        let lane_key = absolute_path_key(&normalize_absolute_path_text(target_path));
        self.active_remote_operation_ids.remove(operation_id);
        self.remote_native_lanes.insert(
            lane_key,
            RemoteNativeLaneState::Blocked {
                origin_operation_id: operation_id.to_string(),
                reason: RemoteFailureClass::RemoteRecoveryBlocked,
                cleanup_appropriate: false,
            },
        );
        self.remote_checkout_journal
            .as_mut()
            .expect("validated checkout journal must remain initialized")
            .mark_blocked(&entry.target_sha256, operation_id)
            .map(|_| ())
            .map_err(remote_checkout_journal_failure)
    }

    fn block_remote_output_lane(
        &mut self,
        lane_key: &str,
        operation_id: &str,
        repository_id: Option<&str>,
        epoch: Option<u64>,
    ) {
        let attribution = match self.remote_native_lanes.get(lane_key) {
            Some(RemoteNativeLaneState::Active {
                repository_id,
                epoch,
                ..
            }) => (repository_id.clone(), *epoch),
            _ => (repository_id.map(str::to_string), epoch),
        };
        self.active_remote_operation_ids.remove(operation_id);
        self.remote_native_lanes.insert(
            lane_key.to_string(),
            RemoteNativeLaneState::Blocked {
                origin_operation_id: operation_id.to_string(),
                reason: RemoteFailureClass::RemoteRecoveryBlocked,
                cleanup_appropriate: false,
            },
        );
        self.push_remote_connection_state(
            attribution.0.as_deref(),
            attribution.1,
            RemoteConnectionState::Indeterminate {
                reason: RemoteIndeterminateReason::WorkerTerminated,
                origin_operation_id: operation_id.to_string(),
                recovery: RemoteRecoveryState::Blocked,
                cleanup_appropriate: false,
            },
        );
    }

    fn checkout_journal_entry(
        &self,
        target_path: &str,
        operation_id: &str,
    ) -> Result<crate::remote_checkout_journal::RemoteCheckoutMutationEntry, BridgeFailure> {
        let target_lane = absolute_path_key(&normalize_absolute_path_text(target_path));
        self.remote_checkout_journal
            .as_ref()
            .and_then(|journal| {
                journal.entries().iter().find(|entry| {
                    entry.origin_operation_id == operation_id
                        && absolute_path_key(&normalize_absolute_path_text(&entry.target_path))
                            == target_lane
                })
            })
            .cloned()
            .ok_or_else(|| remote_checkout_journal_contract_failure("entryAttribution"))
    }

    pub(crate) fn complete_remote_svn_anonymous(
        &mut self,
        request_id: Value,
        lane_key: &str,
        operation_id: &str,
        repository_id: Option<&str>,
        epoch: Option<u64>,
        request: crate::RemoteSvnAnonymousRequest,
        output: crate::RemoteSvnAnonymousOutput,
    ) -> Result<Value, BridgeFailure> {
        let checkout_target = match &request {
            crate::RemoteSvnAnonymousRequest::Checkout { request } => {
                Some(request.target_path.clone())
            }
            _ => None,
        };
        if !matches!(
            self.remote_native_lanes.get(lane_key),
            Some(RemoteNativeLaneState::Active {
                operation_id: active,
                repository_id: active_repository_id,
                epoch: active_epoch,
                ..
            }) if active == operation_id
                && active_repository_id.as_deref() == repository_id
                && *active_epoch == epoch
        ) {
            if let Some(target_path) = checkout_target.as_deref() {
                self.block_checkout_journal_entry(target_path, operation_id)?;
            } else {
                self.block_remote_output_lane(lane_key, operation_id, repository_id, epoch);
            }
            return Err(remote_worker_output_invalid());
        }
        let rpc_request = JsonRpcRequest {
            id: request_id,
            method: "remote/completeSvnAnonymous".to_string(),
            params: None,
        };
        let response = match (request, output) {
            (
                crate::RemoteSvnAnonymousRequest::Checkout { request },
                crate::RemoteSvnAnonymousOutput::Checkout(result),
            ) => {
                if absolute_path_key(&normalize_absolute_path_text(&request.target_path))
                    != absolute_path_key(&normalize_absolute_path_text(&result.working_copy_path))
                {
                    Err(remote_worker_output_invalid())
                } else {
                    match self.complete_checkout_journal_entry(&request.target_path, operation_id) {
                        Ok(()) => Ok(json!({
                            "jsonrpc": "2.0",
                            "id": rpc_request.id,
                            "result": RepositoryCheckoutResponse {
                                working_copy_path: result.working_copy_path,
                                revision: result.revision,
                            },
                        })),
                        Err(failure) => Err(failure),
                    }
                }
            }
            (
                crate::RemoteSvnAnonymousRequest::Status {
                    identity,
                    generation,
                },
                crate::RemoteSvnAnonymousOutput::Status(mut snapshot),
            ) => {
                let (repository_id, epoch) = required_remote_attribution(repository_id, epoch)?;
                let Some(session) = self.repositories.get_mut(repository_id) else {
                    return Err(remote_worker_output_invalid());
                };
                if session.epoch != epoch || session.identity != identity {
                    return Err(remote_worker_output_invalid());
                }
                snapshot.repository_id = session.repository_id.clone();
                snapshot.epoch = epoch;
                snapshot.generation = generation;
                snapshot.identity = session.identity.clone();
                snapshot.timestamp = current_timestamp();
                for entry in &mut snapshot.remote_entries {
                    entry.generation = generation;
                }
                filter_snapshot_boundaries(&mut snapshot, &session.boundary_roots);
                let before_summary = summarize_snapshot_entries(
                    session.local_entries.values(),
                    session.remote_entries.values(),
                );
                let before_remote_entries = session.remote_entries.clone();
                let next_remote_entries = snapshot
                    .remote_entries
                    .into_iter()
                    .filter(is_projectable_remote_status)
                    .map(|entry| (entry.path.clone(), entry))
                    .collect::<BTreeMap<_, _>>();
                let after_summary = summarize_snapshot_entries(
                    session.local_entries.values(),
                    next_remote_entries.values(),
                );
                let remote_upsert = changed_upserts(&before_remote_entries, &next_remote_entries);
                let remote_remove = removed_paths(&before_remote_entries, &next_remote_entries);
                let next_generation = generation
                    .checked_add(1)
                    .ok_or_else(remote_worker_output_invalid)?;
                session.remote_entries = next_remote_entries;
                session.next_generation = next_generation;
                let delta = StatusDelta {
                    repository_id: repository_id.to_string(),
                    epoch,
                    generation,
                    coverage: vec![StatusCoverageScope {
                        path: ".".to_string(),
                        depth: "workingCopy".to_string(),
                        generation,
                        reason: "manualRemoteCheck".to_string(),
                    }],
                    upsert: Vec::new(),
                    remove: Vec::new(),
                    remote_upsert,
                    remote_remove,
                    summary_delta: summary_delta(&before_summary, &after_summary),
                    completeness: "complete".to_string(),
                    timestamp: current_timestamp(),
                    source: "libsvn-remote".to_string(),
                };
                Ok(json!({ "jsonrpc": "2.0", "id": rpc_request.id, "result": delta }))
            }
            (
                crate::RemoteSvnAnonymousRequest::Content {
                    identity,
                    path,
                    revision,
                },
                crate::RemoteSvnAnonymousOutput::Content(blob),
            ) => {
                let (repository_id, epoch) = required_remote_attribution(repository_id, epoch)?;
                validate_remote_session(self, repository_id, epoch, &identity)?;
                let response = ContentGetResponse {
                    repository_id: repository_id.to_string(),
                    epoch,
                    path,
                    revision,
                    content_base64: STANDARD.encode(&blob.data),
                    byte_length: blob.data.len() as u64,
                    mime_type: blob.mime_type,
                    is_binary: blob.is_binary,
                    source: blob.source,
                };
                Ok(json!({ "jsonrpc": "2.0", "id": rpc_request.id, "result": response }))
            }
            (
                crate::RemoteSvnAnonymousRequest::Log { identity, request },
                crate::RemoteSvnAnonymousOutput::Log(log),
            ) => {
                let (repository_id, epoch) = required_remote_attribution(repository_id, epoch)?;
                validate_remote_session(self, repository_id, epoch, &identity)?;
                let response = HistoryLogResponse {
                    repository_id: repository_id.to_string(),
                    epoch,
                    path: request.path,
                    start_revision: request.start_revision,
                    end_revision: request.end_revision,
                    limit: request.limit,
                    entries: log.entries,
                    source: log.source,
                };
                Ok(json!({ "jsonrpc": "2.0", "id": rpc_request.id, "result": response }))
            }
            (
                crate::RemoteSvnAnonymousRequest::Blame { identity, request },
                crate::RemoteSvnAnonymousOutput::Blame(blame),
            ) => {
                let (repository_id, epoch) = required_remote_attribution(repository_id, epoch)?;
                validate_remote_session(self, repository_id, epoch, &identity)?;
                let response = HistoryBlameResponse {
                    repository_id: repository_id.to_string(),
                    epoch,
                    path: request.path,
                    peg_revision: request.peg_revision,
                    start_revision: request.start_revision,
                    end_revision: request.end_revision,
                    resolved_start_revision: blame.resolved_start_revision,
                    resolved_end_revision: blame.resolved_end_revision,
                    line_start: request.line_start,
                    line_limit: request.line_limit,
                    ignore_whitespace: request.ignore_whitespace,
                    ignore_eol_style: request.ignore_eol_style,
                    ignore_mime_type: request.ignore_mime_type,
                    include_merged_revisions: request.include_merged_revisions,
                    has_more: blame.has_more,
                    lines: blame.lines,
                    source: blame.source,
                };
                Ok(json!({ "jsonrpc": "2.0", "id": rpc_request.id, "result": response }))
            }
            (
                crate::RemoteSvnAnonymousRequest::Update { identity, .. },
                crate::RemoteSvnAnonymousOutput::Update(result),
            ) => {
                let (repository_id, epoch) = required_remote_attribution(repository_id, epoch)?;
                validate_remote_session(self, repository_id, epoch, &identity)?;
                Ok(self
                    .operation_run_full_reconcile_success(
                        &rpc_request,
                        OperationRunFullReconcileSuccess {
                            repository_id: repository_id.to_string(),
                            epoch,
                            kind: "update",
                            stale_reason: "operationUpdateRequiresFullReconcile",
                            result: result.result,
                            revision: Some(result.revision),
                        },
                    )
                    .1)
            }
            (
                crate::RemoteSvnAnonymousRequest::Lock { identity, request },
                crate::RemoteSvnAnonymousOutput::Lock(result),
            ) => self.complete_remote_targeted_operation(
                &rpc_request,
                repository_id,
                epoch,
                &identity,
                "lock",
                result,
                &request.paths,
                "operationLock",
                None,
            ),
            (
                crate::RemoteSvnAnonymousRequest::Unlock { identity, request },
                crate::RemoteSvnAnonymousOutput::Unlock(result),
            ) => self.complete_remote_targeted_operation(
                &rpc_request,
                repository_id,
                epoch,
                &identity,
                "unlock",
                result,
                &request.paths,
                "operationUnlock",
                None,
            ),
            (
                crate::RemoteSvnAnonymousRequest::BranchCreate { identity, .. },
                crate::RemoteSvnAnonymousOutput::BranchCreate(result),
            ) => {
                let (repository_id, epoch) = required_remote_attribution(repository_id, epoch)?;
                validate_remote_session(self, repository_id, epoch, &identity)?;
                Ok(self
                    .operation_run_remote_success(
                        &rpc_request,
                        OperationRunRemoteSuccess {
                            repository_id: repository_id.to_string(),
                            epoch,
                            kind: "branchCreate",
                            result: result.result,
                            revision: Some(result.revision),
                        },
                    )
                    .1)
            }
            (
                crate::RemoteSvnAnonymousRequest::Switch { identity, .. },
                crate::RemoteSvnAnonymousOutput::Switch(result),
            ) => {
                let (repository_id, epoch) = required_remote_attribution(repository_id, epoch)?;
                validate_remote_session(self, repository_id, epoch, &identity)?;
                Ok(self
                    .operation_run_full_reconcile_success(
                        &rpc_request,
                        OperationRunFullReconcileSuccess {
                            repository_id: repository_id.to_string(),
                            epoch,
                            kind: "switch",
                            stale_reason: "operationSwitchRequiresFullReconcile",
                            result: result.result,
                            revision: Some(result.revision),
                        },
                    )
                    .1)
            }
            (
                crate::RemoteSvnAnonymousRequest::Commit { identity, request },
                crate::RemoteSvnAnonymousOutput::Commit(result),
            ) => self.complete_remote_targeted_operation(
                &rpc_request,
                repository_id,
                epoch,
                &identity,
                "commit",
                result.result,
                &request.paths,
                "operationCommit",
                Some(result.revision),
            ),
            _ => Err(remote_worker_output_invalid()),
        };
        match response {
            Ok(response) => {
                if checkout_target.is_none() {
                    self.active_remote_operation_ids.remove(operation_id);
                    self.remote_native_lanes.remove(lane_key);
                    self.push_remote_connection_state(
                        repository_id,
                        epoch,
                        RemoteConnectionState::Online {
                            transport: RemoteScheme::Svn,
                            checked_at: current_timestamp(),
                        },
                    );
                }
                Ok(response)
            }
            Err(failure) => {
                if let Some(target_path) = checkout_target {
                    self.block_checkout_journal_entry(&target_path, operation_id)?;
                } else {
                    self.block_remote_output_lane(lane_key, operation_id, repository_id, epoch);
                }
                Err(failure)
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn complete_remote_targeted_operation(
        &mut self,
        rpc_request: &JsonRpcRequest,
        repository_id: Option<&str>,
        epoch: Option<u64>,
        identity: &RepositoryIdentity,
        kind: &str,
        result: crate::OperationResult,
        paths: &[String],
        reason: &str,
        revision: Option<i64>,
    ) -> Result<Value, BridgeFailure> {
        let (repository_id, epoch) = required_remote_attribution(repository_id, epoch)?;
        validate_remote_session(self, repository_id, epoch, identity)?;
        Ok(self
            .operation_run_success(
                rpc_request,
                repository_id.to_string(),
                epoch,
                OperationRunSuccess {
                    kind,
                    result,
                    paths,
                    depth: "empty",
                    reason,
                    revision,
                },
            )
            .1)
    }

    fn native_lane_failure_for_request(&self, request: &JsonRpcRequest) -> Option<BridgeFailure> {
        if matches!(
            request.method.as_str(),
            "initialize"
                | "workspaceTrust/update"
                | "diagnostics/get"
                | "remote/recoverWorkingCopy"
                | "remote/listCheckoutTargetRecoveries"
                | "remote/confirmCheckoutTargetDisposition"
                | "shutdown"
        ) {
            return None;
        }
        let mut request_path_keys = BTreeSet::new();
        if let Some(working_copy_root) = request
            .params
            .as_ref()
            .and_then(|params| params.get("repositoryId"))
            .and_then(Value::as_str)
            .and_then(|repository_id| self.repositories.get(repository_id))
            .map(|session| session.identity.working_copy_root.as_str())
        {
            request_path_keys.insert(absolute_path_key(&normalize_absolute_path_text(
                working_copy_root,
            )));
        }
        if let Some(path) = request.params.as_ref().and_then(|params| {
            params
                .get("targetPath")
                .or_else(|| params.get("path"))
                .and_then(Value::as_str)
        }) && Path::new(path).is_absolute()
        {
            request_path_keys.insert(absolute_path_key(&normalize_absolute_path_text(path)));
        }
        if request.method == "repository/discover"
            && let Some(workspace_roots) = request
                .params
                .as_ref()
                .and_then(|params| params.get("workspaceRoots"))
                .and_then(Value::as_array)
        {
            request_path_keys.extend(workspace_roots.iter().filter_map(Value::as_str).filter_map(
                |path| {
                    Path::new(path)
                        .is_absolute()
                        .then(|| absolute_path_key(&normalize_absolute_path_text(path)))
                },
            ));
        }

        for request_path_key in request_path_keys {
            for (lane_key, state) in &self.remote_native_lanes {
                if request_path_key != *lane_key
                    && !is_descendant_path_key(&request_path_key, lane_key)
                    && !is_descendant_path_key(lane_key, &request_path_key)
                {
                    continue;
                }
                return Some(match state {
                    RemoteNativeLaneState::Active { .. } => BridgeFailure::new(
                        "SUBVERSIONR_REMOTE_NATIVE_LANE_BUSY",
                        "state",
                        "error.remote.nativeLaneBusy",
                        json!({}),
                        true,
                    ),
                    RemoteNativeLaneState::Recovering { .. } => BridgeFailure::new(
                        "SUBVERSIONR_REMOTE_OPERATION_INDETERMINATE",
                        "state",
                        "error.remote.operationIndeterminate",
                        json!({}),
                        false,
                    ),
                    RemoteNativeLaneState::Blocked { .. } => BridgeFailure::new(
                        "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED",
                        "state",
                        "error.remote.recoveryBlocked",
                        json!({}),
                        false,
                    ),
                });
            }
        }
        None
    }

    fn push_remote_connection_state(
        &mut self,
        repository_id: Option<&str>,
        epoch: Option<u64>,
        state: RemoteConnectionState,
    ) {
        let (Some(repository_id), Some(epoch)) = (repository_id, epoch) else {
            return;
        };
        self.pending_notifications.push(json!({
            "jsonrpc": "2.0",
            "method": "remoteConnection/state",
            "params": {
                "repositoryId": repository_id,
                "epoch": epoch,
                "state": state,
            },
        }));
    }
}

fn required_remote_attribution(
    repository_id: Option<&str>,
    epoch: Option<u64>,
) -> Result<(&str, u64), BridgeFailure> {
    match (repository_id, epoch) {
        (Some(repository_id), Some(epoch)) => Ok((repository_id, epoch)),
        _ => Err(remote_worker_output_invalid()),
    }
}

fn validate_remote_session(
    state: &DaemonState,
    repository_id: &str,
    epoch: u64,
    identity: &RepositoryIdentity,
) -> Result<(), BridgeFailure> {
    match state.repositories.get(repository_id) {
        Some(session) if session.epoch == epoch && &session.identity == identity => Ok(()),
        _ => Err(remote_worker_output_invalid()),
    }
}

fn remote_worker_output_invalid() -> BridgeFailure {
    BridgeFailure::new(
        "SUBVERSIONR_REMOTE_WORKER_PROTOCOL_INVALID",
        "protocol",
        "error.remote.workerProtocolInvalid",
        json!({}),
        false,
    )
}

fn remote_checkout_journal_failure(error: RemoteCheckoutJournalError) -> BridgeFailure {
    let kind = match error.kind() {
        RemoteCheckoutJournalErrorKind::StorageRootNotAbsolute => "storageRootNotAbsolute",
        RemoteCheckoutJournalErrorKind::StorageRootUnavailable => "storageRootUnavailable",
        RemoteCheckoutJournalErrorKind::StorageRootNotDirectory => "storageRootNotDirectory",
        RemoteCheckoutJournalErrorKind::OrphanedTemporaryFile => "orphanedTemporaryFile",
        RemoteCheckoutJournalErrorKind::JournalTooLarge => "journalTooLarge",
        RemoteCheckoutJournalErrorKind::JournalCorrupt => "journalCorrupt",
        RemoteCheckoutJournalErrorKind::UnsupportedSchema => "unsupportedSchema",
        RemoteCheckoutJournalErrorKind::EntryLimitExceeded => "entryLimitExceeded",
        RemoteCheckoutJournalErrorKind::TargetPathInvalid => "targetPathInvalid",
        RemoteCheckoutJournalErrorKind::OperationIdInvalid => "operationIdInvalid",
        RemoteCheckoutJournalErrorKind::EntryAlreadyExists => "entryAlreadyExists",
        RemoteCheckoutJournalErrorKind::EntryNotFound => "entryNotFound",
        RemoteCheckoutJournalErrorKind::AtomicWriteFailed => "atomicWriteFailed",
    };
    BridgeFailure::new(
        "SUBVERSIONR_REMOTE_CHECKOUT_JOURNAL_INVALID",
        "configuration",
        "error.remote.checkoutJournalInvalid",
        json!({ "kind": kind }),
        false,
    )
}

fn remote_checkout_journal_contract_failure(field: &str) -> BridgeFailure {
    BridgeFailure::new(
        "SUBVERSIONR_REMOTE_CHECKOUT_JOURNAL_CONTRACT_INVALID",
        "protocol",
        "error.remote.checkoutJournalContractInvalid",
        json!({ "field": field }),
        false,
    )
}

fn connection_state_for_failure(
    failure: &BridgeFailure,
    operation_id: &str,
) -> RemoteConnectionState {
    match classify_remote_failure(failure).reason {
        RemoteFailureClass::NetworkDns => RemoteConnectionState::Unreachable {
            reason: RemoteUnreachableReason::Dns,
        },
        RemoteFailureClass::NetworkRefused => RemoteConnectionState::Unreachable {
            reason: RemoteUnreachableReason::Refused,
        },
        RemoteFailureClass::NetworkTimeout | RemoteFailureClass::OperationDeadlineExceeded => {
            RemoteConnectionState::Unreachable {
                reason: RemoteUnreachableReason::Timeout,
            }
        }
        RemoteFailureClass::ProxyAuthenticationRequired => RemoteConnectionState::Attention {
            reason: RemoteAttentionReason::AuthRequired,
        },
        RemoteFailureClass::ProxyUnreachable => RemoteConnectionState::Unreachable {
            reason: RemoteUnreachableReason::Proxy,
        },
        RemoteFailureClass::AuthenticationRequired | RemoteFailureClass::CredentialRejected => {
            RemoteConnectionState::Attention {
                reason: RemoteAttentionReason::AuthRequired,
            }
        }
        RemoteFailureClass::AuthorizationDenied => RemoteConnectionState::Attention {
            reason: RemoteAttentionReason::AuthorizationDenied,
        },
        RemoteFailureClass::TlsUntrusted
        | RemoteFailureClass::TlsChanged
        | RemoteFailureClass::TlsProtocol => RemoteConnectionState::Attention {
            reason: RemoteAttentionReason::CertificateRequired,
        },
        RemoteFailureClass::SshHostKeyRequired | RemoteFailureClass::SshHostKeyChanged => {
            RemoteConnectionState::Attention {
                reason: RemoteAttentionReason::HostKeyRequired,
            }
        }
        RemoteFailureClass::RemoteCapabilityUnsupported => RemoteConnectionState::Attention {
            reason: RemoteAttentionReason::UnsupportedCapability,
        },
        RemoteFailureClass::OperationCancelled | RemoteFailureClass::UnknownRemote => {
            RemoteConnectionState::Unchecked
        }
        RemoteFailureClass::WorkerContainmentFailed
        | RemoteFailureClass::RemoteOperationIndeterminate => {
            RemoteConnectionState::Indeterminate {
                reason: RemoteIndeterminateReason::WorkerTerminated,
                origin_operation_id: operation_id.to_string(),
                recovery: RemoteRecoveryState::NotRequired,
                cleanup_appropriate: false,
            }
        }
        RemoteFailureClass::SshTunnelFailed => RemoteConnectionState::Unreachable {
            reason: RemoteUnreachableReason::Tunnel,
        },
        RemoteFailureClass::RemoteConfigurationInvalid
        | RemoteFailureClass::RedirectRejected
        | RemoteFailureClass::CrossAuthorityRejected
        | RemoteFailureClass::SshExecutableInvalid
        | RemoteFailureClass::SshProvenanceInvalid => RemoteConnectionState::Attention {
            reason: RemoteAttentionReason::ConfigurationInvalid,
        },
        _ => RemoteConnectionState::Unchecked,
    }
}

fn remote_effect_for_request(request: &JsonRpcRequest) -> Option<RemoteOperationEffect> {
    match request.method.as_str() {
        "repository/checkout" => Some(RemoteOperationEffect::Mutation),
        "status/checkRemote" | "content/get" | "history/log" | "history/blame" => {
            Some(RemoteOperationEffect::ReadOnly)
        }
        "operation/run" => match request
            .params
            .as_ref()
            .and_then(|params| params.get("kind"))
            .and_then(Value::as_str)
        {
            Some(
                "update" | "lock" | "unlock" | "branchCreate" | "switch" | "relocate" | "merge"
                | "commit",
            ) => Some(RemoteOperationEffect::Mutation),
            _ => None,
        },
        _ => None,
    }
}

fn status_stale_notification(repository_id: &str, epoch: u64, reason: &str) -> Value {
    json!({
        "jsonrpc": "2.0",
        "method": "status/stale",
        "params": {
            "repositoryId": repository_id,
            "epoch": epoch,
            "reason": reason,
            "timestamp": current_timestamp(),
            "source": "subversionr-daemon",
        },
    })
}

pub(crate) fn repository_id(identity: &RepositoryIdentity) -> String {
    format!(
        "{}:{}",
        identity.repository_uuid, identity.working_copy_root
    )
}

fn repository_open_boundary_roots(request: &JsonRpcRequest) -> Result<Vec<String>, String> {
    let Some(value) = request
        .params
        .as_ref()
        .and_then(|params| params.get("boundaryRoots"))
    else {
        return Ok(Vec::new());
    };
    let Some(values) = value.as_array() else {
        return Err("boundaryRoots".to_string());
    };

    let mut boundary_roots = Vec::with_capacity(values.len());
    for (index, value) in values.iter().enumerate() {
        let Some(boundary_root) = value.as_str().filter(|value| !value.trim().is_empty()) else {
            return Err(format!("boundaryRoots.{index}"));
        };
        boundary_roots.push(boundary_root.to_string());
    }
    Ok(boundary_roots)
}

fn repository_checkout_request(
    request: &JsonRpcRequest,
) -> Result<RepositoryCheckoutRequest, String> {
    if let Some(field) = unexpected_param(
        request,
        &[
            "url",
            "targetPath",
            "revision",
            "depth",
            "ignoreExternals",
            "remote",
        ],
    ) {
        return Err(field);
    }
    let url = string_param(request, "url")
        .filter(|url| valid_checkout_url(url))
        .ok_or("url")?
        .to_string();
    let target_path = string_param(request, "targetPath")
        .filter(|path| valid_checkout_target_path(path))
        .ok_or("targetPath")?
        .to_string();
    let revision = request
        .params
        .as_ref()
        .and_then(|params| params.get("revision"))
        .and_then(checkout_revision_value)
        .ok_or("revision")?;
    let depth = string_param(request, "depth")
        .filter(|depth| valid_checkout_depth(depth))
        .ok_or("depth")?
        .to_string();
    let ignore_externals = bool_param(request, "ignoreExternals").ok_or("ignoreExternals")?;

    Ok(RepositoryCheckoutRequest {
        url,
        target_path,
        revision,
        depth,
        ignore_externals,
    })
}

fn repository_boundary_roots(
    identity: &RepositoryIdentity,
    boundary_roots: &[String],
) -> Result<Vec<String>, String> {
    let mut seen = BTreeSet::new();
    let mut relative_roots = Vec::with_capacity(boundary_roots.len());
    for (index, boundary_root) in boundary_roots.iter().enumerate() {
        let Some(relative_path) =
            boundary_root_relative_path(&identity.working_copy_root, boundary_root)
        else {
            return Err(format!("boundaryRoots.{index}"));
        };
        if !valid_repository_relative_path(&relative_path) || relative_path == "." {
            return Err(format!("boundaryRoots.{index}"));
        }
        let key = status_path_key(&relative_path);
        if seen.insert(key) {
            relative_roots.push(relative_path);
        }
    }
    Ok(relative_roots)
}

fn boundary_root_relative_path(working_copy_root: &str, boundary_root: &str) -> Option<String> {
    let working_copy_root = normalize_absolute_path_text(working_copy_root);
    let boundary_root = normalize_absolute_path_text(boundary_root);
    let working_copy_root_key = absolute_path_key(&working_copy_root);
    let boundary_root_key = absolute_path_key(&boundary_root);
    if !is_descendant_path_key(&boundary_root_key, &working_copy_root_key) {
        return None;
    }
    Some(
        boundary_root[working_copy_root.len() + 1..]
            .trim_matches('/')
            .to_string(),
    )
}

fn normalize_absolute_path_text(path: &str) -> String {
    path.replace('\\', "/").trim_end_matches('/').to_string()
}

fn absolute_path_key(path: &str) -> String {
    if cfg!(windows) {
        path.to_ascii_lowercase()
    } else {
        path.to_string()
    }
}

fn filter_snapshot_boundaries(snapshot: &mut StatusSnapshot, boundary_roots: &[String]) {
    if boundary_roots.is_empty() {
        return;
    }
    snapshot
        .local_entries
        .retain(|entry| !path_inside_boundary_roots(&entry.path, boundary_roots));
    snapshot
        .remote_entries
        .retain(|entry| !path_inside_boundary_roots(&entry.path, boundary_roots));
    snapshot.summary = summarize_snapshot_entries(
        snapshot.local_entries.iter(),
        snapshot.remote_entries.iter(),
    );
}

fn path_inside_boundary_roots(path: &str, boundary_roots: &[String]) -> bool {
    let path_key = status_path_key(path);
    boundary_roots.iter().any(|boundary_root| {
        let boundary_key = status_path_key(boundary_root);
        path_key == boundary_key || is_descendant_path_key(&path_key, &boundary_key)
    })
}

fn status_path_key(path: &str) -> String {
    let normalized = path.replace('\\', "/").trim_matches('/').to_string();
    if cfg!(windows) {
        normalized.to_ascii_lowercase()
    } else {
        normalized
    }
}

fn push_discovery_candidate(
    candidates: &mut Vec<RepositoryDiscoveryCandidate>,
    seen_candidate_roots: &mut BTreeSet<String>,
    ignored_root_keys: &BTreeSet<String>,
    identity: RepositoryIdentity,
    fallback_parent_working_copy_root: Option<&str>,
) {
    push_discovery_candidate_with_flags(
        candidates,
        seen_candidate_roots,
        ignored_root_keys,
        identity,
        fallback_parent_working_copy_root,
        false,
    );
}

fn push_external_discovery_candidate(
    candidates: &mut Vec<RepositoryDiscoveryCandidate>,
    seen_candidate_roots: &mut BTreeSet<String>,
    ignored_root_keys: &BTreeSet<String>,
    identity: RepositoryIdentity,
    parent_working_copy_root: &str,
) {
    push_discovery_candidate_with_flags(
        candidates,
        seen_candidate_roots,
        ignored_root_keys,
        identity,
        Some(parent_working_copy_root),
        true,
    );
}

fn push_discovery_candidate_with_flags(
    candidates: &mut Vec<RepositoryDiscoveryCandidate>,
    seen_candidate_roots: &mut BTreeSet<String>,
    ignored_root_keys: &BTreeSet<String>,
    identity: RepositoryIdentity,
    fallback_parent_working_copy_root: Option<&str>,
    is_external: bool,
) {
    let root_key = discovery_path_key(&identity.working_copy_root);
    if ignored_root_keys.contains(&root_key) || seen_candidate_roots.contains(&root_key) {
        return;
    }

    let parent_working_copy_root =
        nearest_parent_working_copy_root(candidates, &identity.working_copy_root).or_else(|| {
            fallback_parent_working_copy_root
                .filter(|parent| is_descendant_path_key(&root_key, &discovery_path_key(parent)))
                .map(str::to_string)
        });
    let is_nested = parent_working_copy_root.is_some();
    seen_candidate_roots.insert(root_key);
    candidates.push(RepositoryDiscoveryCandidate {
        identity,
        is_nested: is_nested && !is_external,
        is_external,
        parent_working_copy_root,
    });
}

fn external_directory_candidate_paths(
    identity: &RepositoryIdentity,
    entries: &[StatusEntry],
) -> Vec<String> {
    let mut seen = BTreeSet::new();
    let mut paths = Vec::new();
    for entry in entries {
        if !entry.external
            || entry.kind != "dir"
            || entry.path == "."
            || !valid_repository_relative_path(&entry.path)
        {
            continue;
        }
        let path = absolute_working_copy_path(identity, &entry.path);
        if seen.insert(discovery_path_key(&path)) {
            paths.push(path);
        }
    }
    paths
}

fn external_file_boundary_paths(
    identity: &RepositoryIdentity,
    entries: &[StatusEntry],
) -> Vec<String> {
    let mut seen = BTreeSet::new();
    let mut paths = Vec::new();
    for entry in entries {
        if !entry.external
            || entry.kind != "file"
            || entry.path == "."
            || !valid_repository_relative_path(&entry.path)
        {
            continue;
        }
        let path = absolute_working_copy_path(identity, &entry.path);
        if seen.insert(discovery_path_key(&path)) {
            paths.push(path);
        }
    }
    paths
}

fn absolute_working_copy_path(
    identity: &RepositoryIdentity,
    repository_relative_path: &str,
) -> String {
    let mut absolute_path = PathBuf::from(&identity.working_copy_root);
    let normalized = repository_relative_path.replace('\\', "/");
    for component in normalized.split('/') {
        absolute_path.push(component);
    }
    absolute_path.to_string_lossy().to_string()
}

fn matching_ignored_root<'a>(ignored_roots: &'a [String], path: &str) -> Option<&'a str> {
    let path_key = discovery_path_key(path);
    ignored_roots
        .iter()
        .find(|ignored| discovery_path_key(ignored) == path_key)
        .map(String::as_str)
}

fn nested_working_copy_hint_paths(
    workspace_root: &str,
    discovery_depth: u64,
    discovery_ignore: &[String],
) -> Vec<PathBuf> {
    if discovery_depth == 0 {
        return Vec::new();
    }

    let root = PathBuf::from(workspace_root);
    let mut hints = Vec::new();
    let mut pending = vec![(root.clone(), 0_u64)];
    while let Some((directory, depth)) = pending.pop() {
        if depth >= discovery_depth {
            continue;
        }

        for child in child_directories(&directory) {
            let Some(name) = child.file_name().and_then(|name| name.to_str()) else {
                continue;
            };
            if name == SVN_ADMIN_DIR_NAME
                || discovery_ignore_matches(&root, &child, discovery_ignore)
            {
                continue;
            }

            let child_depth = depth + 1;
            if child.join(SVN_ADMIN_DIR_NAME).is_dir() {
                hints.push(child.clone());
            }
            if child_depth < discovery_depth {
                pending.push((child, child_depth));
            }
        }
    }

    hints.sort_by(|left, right| {
        let left_depth = left.components().count();
        let right_depth = right.components().count();
        left_depth.cmp(&right_depth).then_with(|| {
            discovery_path_key(&left.to_string_lossy())
                .cmp(&discovery_path_key(&right.to_string_lossy()))
        })
    });
    hints
}

fn child_directories(directory: &Path) -> Vec<PathBuf> {
    let Ok(entries) = fs::read_dir(directory) else {
        return Vec::new();
    };

    let mut directories = Vec::new();
    for entry in entries.flatten() {
        let Ok(file_type) = entry.file_type() else {
            continue;
        };
        if !file_type.is_dir() || file_type.is_symlink() {
            continue;
        }
        directories.push(entry.path());
    }
    directories.sort_by_key(|path| discovery_path_key(&path.to_string_lossy()));
    directories
}

fn discovery_ignore_matches(root: &Path, path: &Path, patterns: &[String]) -> bool {
    let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
        return false;
    };
    let relative_path = path
        .strip_prefix(root)
        .unwrap_or(path)
        .to_string_lossy()
        .replace('\\', "/");
    let name_key = discovery_pattern_key(name);
    let relative_path_key = discovery_pattern_key(&relative_path);
    for pattern in patterns {
        let normalized = pattern.trim().replace('\\', "/");
        let normalized = normalized.trim_matches('/');
        if normalized.is_empty() {
            continue;
        }
        let normalized_key = discovery_pattern_key(normalized);
        if normalized_key == name_key || normalized_key == relative_path_key {
            return true;
        }
        if let Some(suffix) = normalized_key.strip_prefix("**/") {
            let suffix = suffix.trim_matches('/');
            if !suffix.is_empty()
                && (suffix == name_key
                    || suffix == relative_path_key
                    || relative_path_key.ends_with(&format!("/{suffix}")))
            {
                return true;
            }
        }
    }
    false
}

fn discovery_pattern_key(value: &str) -> String {
    if cfg!(windows) {
        value.to_ascii_lowercase()
    } else {
        value.to_string()
    }
}

fn nearest_parent_working_copy_root(
    candidates: &[RepositoryDiscoveryCandidate],
    working_copy_root: &str,
) -> Option<String> {
    let working_copy_root_key = discovery_path_key(working_copy_root);
    candidates
        .iter()
        .filter_map(|candidate| {
            let parent_key = discovery_path_key(&candidate.identity.working_copy_root);
            (parent_key != working_copy_root_key
                && is_descendant_path_key(&working_copy_root_key, &parent_key))
            .then(|| {
                (
                    parent_key.len(),
                    candidate.identity.working_copy_root.clone(),
                )
            })
        })
        .max_by_key(|(length, _)| *length)
        .map(|(_, root)| root)
}

fn is_descendant_path_key(child_key: &str, parent_key: &str) -> bool {
    child_key
        .strip_prefix(parent_key)
        .is_some_and(|suffix| suffix.starts_with('/'))
}

fn discovery_path_key(path: &str) -> String {
    let normalized = path.replace('\\', "/").trim_end_matches('/').to_string();
    if cfg!(windows) {
        normalized.to_ascii_lowercase()
    } else {
        normalized
    }
}

fn discovery_bridge_failure(
    request: &JsonRpcRequest,
    failure: BridgeFailure,
) -> (DispatchOutcome, Value) {
    (
        DispatchOutcome::Continue,
        json!({
            "jsonrpc": "2.0",
            "id": request.id,
            "error": bridge_error(failure),
        }),
    )
}

fn bridge_failure_response(
    request: &JsonRpcRequest,
    failure: BridgeFailure,
) -> (DispatchOutcome, Value) {
    (
        DispatchOutcome::Continue,
        json!({
            "jsonrpc": "2.0",
            "id": request.id,
            "error": bridge_error(failure),
        }),
    )
}

fn remote_recovery_response(
    request: &JsonRpcRequest,
    outcome: RemoteRecoveryOutcome,
) -> (DispatchOutcome, Value) {
    (
        DispatchOutcome::Continue,
        json!({
            "jsonrpc": "2.0",
            "id": request.id,
            "result": outcome,
        }),
    )
}

fn string_array_param(request: &JsonRpcRequest, field: &str) -> Option<Vec<String>> {
    string_array_param_inner(request, field, false)
}

fn string_array_param_allow_empty(request: &JsonRpcRequest, field: &str) -> Option<Vec<String>> {
    string_array_param_inner(request, field, true)
}

fn string_array_param_inner(
    request: &JsonRpcRequest,
    field: &str,
    allow_empty: bool,
) -> Option<Vec<String>> {
    let values = request
        .params
        .as_ref()
        .and_then(|params| params.get(field))
        .and_then(Value::as_array)?;
    let mut strings = Vec::with_capacity(values.len());
    for value in values {
        let text = value.as_str()?.trim();
        if text.is_empty() {
            return None;
        }
        strings.push(text.to_string());
    }

    (allow_empty || !strings.is_empty()).then_some(strings)
}

fn string_param<'a>(request: &'a JsonRpcRequest, field: &str) -> Option<&'a str> {
    request
        .params
        .as_ref()
        .and_then(|params| params.get(field))
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
}

fn bool_param(request: &JsonRpcRequest, field: &str) -> Option<bool> {
    request
        .params
        .as_ref()
        .and_then(|params| params.get(field))
        .and_then(Value::as_bool)
}

fn u64_param(request: &JsonRpcRequest, field: &str) -> Option<u64> {
    request
        .params
        .as_ref()
        .and_then(|params| params.get(field))
        .and_then(Value::as_u64)
}

fn repository_id_param(request: &JsonRpcRequest) -> Option<&str> {
    request
        .params
        .as_ref()
        .and_then(|params| params.get("repositoryId"))
        .and_then(Value::as_str)
        .filter(|id| !id.trim().is_empty())
}

fn epoch_param(request: &JsonRpcRequest) -> Option<u64> {
    request
        .params
        .as_ref()
        .and_then(|params| params.get("epoch"))
        .and_then(Value::as_u64)
}

fn unexpected_param(request: &JsonRpcRequest, expected_keys: &[&str]) -> Option<String> {
    let params = request.params.as_ref()?.as_object()?;
    params
        .keys()
        .find(|key| !expected_keys.contains(&key.as_str()))
        .cloned()
}

fn content_path_param(request: &JsonRpcRequest) -> Option<&str> {
    string_param(request, "path")
        .filter(|path| *path != ".")
        .filter(|path| valid_repository_relative_path(path))
}

fn property_path_param(request: &JsonRpcRequest) -> Option<&str> {
    string_param(request, "path")
        .filter(|path| !path.contains('\\'))
        .filter(|path| valid_repository_relative_path(path))
}

fn content_revision_param(request: &JsonRpcRequest) -> Option<&str> {
    string_param(request, "revision").filter(|revision| valid_content_revision(revision))
}

fn valid_content_revision(revision: &str) -> bool {
    if revision == "base" || revision == "head" {
        return true;
    }
    let Some(number) = revision.strip_prefix('r') else {
        return false;
    };
    if number.is_empty() || (number.len() > 1 && number.starts_with('0')) {
        return false;
    }
    if !number.chars().all(|character| character.is_ascii_digit()) {
        return false;
    }
    number
        .parse::<u64>()
        .is_ok_and(|revision| revision <= MAX_SVN_REVNUM)
}

fn history_log_request(request: &JsonRpcRequest) -> Result<HistoryLogRequest, &'static str> {
    let path = string_param(request, "path")
        .filter(|path| valid_history_path(path))
        .ok_or("path")?
        .to_string();
    let start_revision = string_param(request, "startRevision")
        .filter(|revision| valid_history_start_revision(revision))
        .ok_or("startRevision")?
        .to_string();
    let end_revision = string_param(request, "endRevision")
        .filter(|revision| valid_history_end_revision(revision))
        .ok_or("endRevision")?
        .to_string();
    let limit = u64_param(request, "limit")
        .filter(|limit| (1..=500).contains(limit))
        .ok_or("limit")? as u32;
    let discover_changed_paths =
        bool_param(request, "discoverChangedPaths").ok_or("discoverChangedPaths")?;
    let strict_node_history =
        bool_param(request, "strictNodeHistory").ok_or("strictNodeHistory")?;
    let include_merged_revisions =
        bool_param(request, "includeMergedRevisions").ok_or("includeMergedRevisions")?;

    Ok(HistoryLogRequest {
        path,
        start_revision,
        end_revision,
        limit,
        discover_changed_paths,
        strict_node_history,
        include_merged_revisions,
    })
}

fn valid_history_path(path: &str) -> bool {
    path == "." || (!path.contains('\\') && valid_repository_relative_path(path))
}

fn valid_history_start_revision(revision: &str) -> bool {
    revision == "head" || valid_numbered_revision(revision)
}

fn valid_history_end_revision(revision: &str) -> bool {
    valid_numbered_revision(revision)
}

fn valid_numbered_revision(revision: &str) -> bool {
    let Some(number) = revision.strip_prefix('r') else {
        return false;
    };
    valid_revision_number_text(number)
}

fn update_revision_value(value: &Value) -> Option<String> {
    if value.as_str() == Some("head") {
        return Some("head".to_string());
    }
    value
        .as_u64()
        .filter(|revision| *revision <= MAX_SVN_REVNUM)
        .map(|revision| revision.to_string())
}

fn checkout_revision_value(value: &Value) -> Option<String> {
    update_revision_value(value)
}

fn merge_revision_value(value: &Value) -> Option<i64> {
    value
        .as_i64()
        .filter(|revision| *revision >= 0 && *revision <= MAX_SVN_REVNUM as i64)
}

fn valid_update_depth(depth: &str) -> bool {
    matches!(
        depth,
        "workingCopy" | "empty" | "files" | "immediates" | "infinity"
    )
}

fn valid_checkout_depth(depth: &str) -> bool {
    matches!(depth, "empty" | "files" | "immediates" | "infinity")
}

fn valid_merge_depth(depth: &str) -> bool {
    valid_checkout_depth(depth)
}

fn valid_checkout_url(url: &str) -> bool {
    !url.trim().is_empty() && !url.contains('\0') && !url.contains('\r') && !url.contains('\n')
}

fn valid_branch_url(url: &str) -> bool {
    valid_checkout_url(url)
}

fn valid_checkout_target_path(path: &str) -> bool {
    !path.trim().is_empty() && !path.contains('\0') && Path::new(path).is_absolute()
}

fn is_lowercase_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn valid_revision_number_text(number: &str) -> bool {
    if number.is_empty() || (number.len() > 1 && number.starts_with('0')) {
        return false;
    }
    if !number.chars().all(|character| character.is_ascii_digit()) {
        return false;
    }
    number
        .parse::<u64>()
        .is_ok_and(|revision| revision <= MAX_SVN_REVNUM)
}

fn history_blame_request(request: &JsonRpcRequest) -> Result<HistoryBlameRequest, &'static str> {
    let path = string_param(request, "path")
        .filter(|path| valid_blame_path(path))
        .ok_or("path")?
        .to_string();
    let peg_revision = string_param(request, "pegRevision")
        .filter(|revision| valid_blame_peg_or_end_revision(revision))
        .ok_or("pegRevision")?
        .to_string();
    let start_revision = string_param(request, "startRevision")
        .filter(|revision| valid_numbered_revision(revision))
        .ok_or("startRevision")?
        .to_string();
    let end_revision = string_param(request, "endRevision")
        .filter(|revision| valid_blame_peg_or_end_revision(revision))
        .ok_or("endRevision")?
        .to_string();
    let line_start = u64_param(request, "lineStart")
        .filter(|line_start| *line_start > 0 && *line_start <= i64::MAX as u64)
        .ok_or("lineStart")?;
    let line_limit = u64_param(request, "lineLimit")
        .filter(|line_limit| (1..=5000).contains(line_limit))
        .ok_or("lineLimit")? as u32;
    let ignore_whitespace = string_param(request, "ignoreWhitespace")
        .filter(|value| matches!(*value, "none" | "change" | "all"))
        .ok_or("ignoreWhitespace")?
        .to_string();
    let ignore_eol_style = bool_param(request, "ignoreEolStyle").ok_or("ignoreEolStyle")?;
    let ignore_mime_type = bool_param(request, "ignoreMimeType").ok_or("ignoreMimeType")?;
    let include_merged_revisions =
        bool_param(request, "includeMergedRevisions").ok_or("includeMergedRevisions")?;

    Ok(HistoryBlameRequest {
        path,
        peg_revision,
        start_revision,
        end_revision,
        line_start,
        line_limit,
        ignore_whitespace,
        ignore_eol_style,
        ignore_mime_type,
        include_merged_revisions,
    })
}

fn valid_blame_path(path: &str) -> bool {
    path != "." && !path.contains('\\') && valid_repository_relative_path(path)
}

fn valid_blame_peg_or_end_revision(revision: &str) -> bool {
    matches!(revision, "base" | "head") || valid_numbered_revision(revision)
}

fn revert_options(request: &JsonRpcRequest) -> Result<RevertOperationRequest, &'static str> {
    let options = request
        .params
        .as_ref()
        .and_then(|params| params.get("options"))
        .and_then(Value::as_object)
        .ok_or("options")?;
    let version = options
        .get("version")
        .and_then(Value::as_u64)
        .ok_or("options.version")?;
    if version != 1 {
        return Err("options.version");
    }
    let paths = string_array_value(options.get("paths"), false)
        .filter(|paths| {
            paths
                .iter()
                .all(|path| valid_repository_relative_path(path))
        })
        .ok_or("options.paths")?;
    let depth = options
        .get("depth")
        .and_then(Value::as_str)
        .filter(|depth| matches!(*depth, "empty" | "files" | "immediates" | "infinity"))
        .ok_or("options.depth")?
        .to_string();
    let changelists =
        changelist_array_value(options.get("changelists"), true).ok_or("options.changelists")?;
    let clear_changelists = options
        .get("clearChangelists")
        .and_then(Value::as_bool)
        .ok_or("options.clearChangelists")?;
    let metadata_only = options
        .get("metadataOnly")
        .and_then(Value::as_bool)
        .ok_or("options.metadataOnly")?;
    let added_keep_local = options
        .get("addedKeepLocal")
        .and_then(Value::as_bool)
        .ok_or("options.addedKeepLocal")?;

    Ok(RevertOperationRequest {
        paths,
        depth,
        changelists,
        clear_changelists,
        metadata_only,
        added_keep_local,
    })
}

fn add_options(request: &JsonRpcRequest) -> Result<AddOperationRequest, String> {
    let options = request
        .params
        .as_ref()
        .and_then(|params| params.get("options"))
        .and_then(Value::as_object)
        .ok_or_else(|| "options".to_string())?;
    for key in options.keys() {
        if !matches!(
            key.as_str(),
            "version" | "paths" | "depth" | "force" | "noIgnore" | "noAutoprops" | "addParents"
        ) {
            return Err(format!("options.{key}"));
        }
    }
    let version = options
        .get("version")
        .and_then(Value::as_u64)
        .ok_or_else(|| "options.version".to_string())?;
    if version != 1 {
        return Err("options.version".to_string());
    }
    let paths = string_array_value(options.get("paths"), false)
        .filter(|paths| {
            paths.len() == 1
                && paths
                    .iter()
                    .all(|path| valid_repository_relative_path(path))
        })
        .ok_or_else(|| "options.paths".to_string())?;
    let depth = options
        .get("depth")
        .and_then(Value::as_str)
        .filter(|depth| matches!(*depth, "empty" | "files" | "immediates" | "infinity"))
        .ok_or_else(|| "options.depth".to_string())?
        .to_string();
    let force = options
        .get("force")
        .and_then(Value::as_bool)
        .ok_or_else(|| "options.force".to_string())?;
    let no_ignore = options
        .get("noIgnore")
        .and_then(Value::as_bool)
        .ok_or_else(|| "options.noIgnore".to_string())?;
    let no_autoprops = options
        .get("noAutoprops")
        .and_then(Value::as_bool)
        .ok_or_else(|| "options.noAutoprops".to_string())?;
    let add_parents = options
        .get("addParents")
        .and_then(Value::as_bool)
        .ok_or_else(|| "options.addParents".to_string())?;

    Ok(AddOperationRequest {
        paths,
        depth,
        force,
        no_ignore,
        no_autoprops,
        add_parents,
    })
}

fn remove_options(request: &JsonRpcRequest) -> Result<RemoveOperationRequest, String> {
    let options = request
        .params
        .as_ref()
        .and_then(|params| params.get("options"))
        .and_then(Value::as_object)
        .ok_or_else(|| "options".to_string())?;
    for key in options.keys() {
        if !matches!(key.as_str(), "version" | "paths" | "force" | "keepLocal") {
            return Err(format!("options.{key}"));
        }
    }
    let version = options
        .get("version")
        .and_then(Value::as_u64)
        .ok_or_else(|| "options.version".to_string())?;
    if version != 1 {
        return Err("options.version".to_string());
    }
    let paths = string_array_value(options.get("paths"), false)
        .filter(|paths| {
            paths
                .iter()
                .all(|path| valid_repository_relative_path(path))
        })
        .ok_or_else(|| "options.paths".to_string())?;
    if has_duplicate_strings(&paths) {
        return Err("options.paths".to_string());
    }
    let force = options
        .get("force")
        .and_then(Value::as_bool)
        .ok_or_else(|| "options.force".to_string())?;
    let keep_local = options
        .get("keepLocal")
        .and_then(Value::as_bool)
        .ok_or_else(|| "options.keepLocal".to_string())?;

    Ok(RemoveOperationRequest {
        paths,
        force,
        keep_local,
    })
}

fn move_options(request: &JsonRpcRequest) -> Result<MoveOperationRequest, String> {
    let options = request
        .params
        .as_ref()
        .and_then(|params| params.get("options"))
        .and_then(Value::as_object)
        .ok_or_else(|| "options".to_string())?;
    for key in options.keys() {
        if !matches!(
            key.as_str(),
            "version" | "sourcePath" | "destinationPath" | "makeParents"
        ) {
            return Err(format!("options.{key}"));
        }
    }
    let version = options
        .get("version")
        .and_then(Value::as_u64)
        .ok_or_else(|| "options.version".to_string())?;
    if version != 1 {
        return Err("options.version".to_string());
    }
    let source_path = options
        .get("sourcePath")
        .and_then(Value::as_str)
        .filter(|path| valid_move_path(path))
        .ok_or_else(|| "options.sourcePath".to_string())?
        .to_string();
    let destination_path = options
        .get("destinationPath")
        .and_then(Value::as_str)
        .filter(|path| valid_move_path(path))
        .ok_or_else(|| "options.destinationPath".to_string())?
        .to_string();
    if destination_path == source_path {
        return Err("options.destinationPath".to_string());
    }
    let make_parents = options
        .get("makeParents")
        .and_then(Value::as_bool)
        .ok_or_else(|| "options.makeParents".to_string())?;

    Ok(MoveOperationRequest {
        source_path,
        destination_path,
        make_parents,
    })
}

fn resolve_options(request: &JsonRpcRequest) -> Result<ResolveOperationRequest, String> {
    let options = request
        .params
        .as_ref()
        .and_then(|params| params.get("options"))
        .and_then(Value::as_object)
        .ok_or_else(|| "options".to_string())?;
    for key in options.keys() {
        if !matches!(key.as_str(), "version" | "paths" | "depth" | "choice") {
            return Err(format!("options.{key}"));
        }
    }
    let version = options
        .get("version")
        .and_then(Value::as_u64)
        .ok_or_else(|| "options.version".to_string())?;
    if version != 1 {
        return Err("options.version".to_string());
    }
    let paths = string_array_value(options.get("paths"), false)
        .filter(|paths| {
            paths
                .iter()
                .all(|path| valid_repository_relative_path(path))
        })
        .ok_or_else(|| "options.paths".to_string())?;
    if paths.len() != 1 {
        return Err("options.paths".to_string());
    }
    let depth = options
        .get("depth")
        .and_then(Value::as_str)
        .filter(|depth| *depth == "empty")
        .ok_or_else(|| "options.depth".to_string())?
        .to_string();
    let choice = options
        .get("choice")
        .and_then(Value::as_str)
        .filter(|choice| valid_resolve_choice(choice))
        .ok_or_else(|| "options.choice".to_string())?
        .to_string();

    Ok(ResolveOperationRequest {
        paths,
        depth,
        choice,
    })
}

fn valid_resolve_choice(choice: &str) -> bool {
    matches!(
        choice,
        "working" | "base" | "mineFull" | "theirsFull" | "mineConflict" | "theirsConflict"
    )
}

fn cleanup_options(request: &JsonRpcRequest) -> Result<CleanupOperationRequest, String> {
    let options = request
        .params
        .as_ref()
        .and_then(|params| params.get("options"))
        .and_then(Value::as_object)
        .ok_or_else(|| "options".to_string())?;
    for key in options.keys() {
        if !matches!(
            key.as_str(),
            "version"
                | "path"
                | "breakLocks"
                | "fixRecordedTimestamps"
                | "clearDavCache"
                | "vacuumPristines"
                | "includeExternals"
        ) {
            return Err(format!("options.{key}"));
        }
    }
    let version = options
        .get("version")
        .and_then(Value::as_u64)
        .ok_or_else(|| "options.version".to_string())?;
    if version != 1 {
        return Err("options.version".to_string());
    }
    let path = options
        .get("path")
        .and_then(Value::as_str)
        .filter(|path| *path == ".")
        .ok_or_else(|| "options.path".to_string())?
        .to_string();
    let break_locks = options
        .get("breakLocks")
        .and_then(Value::as_bool)
        .ok_or_else(|| "options.breakLocks".to_string())?;
    let fix_recorded_timestamps = options
        .get("fixRecordedTimestamps")
        .and_then(Value::as_bool)
        .ok_or_else(|| "options.fixRecordedTimestamps".to_string())?;
    let clear_dav_cache = options
        .get("clearDavCache")
        .and_then(Value::as_bool)
        .ok_or_else(|| "options.clearDavCache".to_string())?;
    let vacuum_pristines = options
        .get("vacuumPristines")
        .and_then(Value::as_bool)
        .ok_or_else(|| "options.vacuumPristines".to_string())?;
    let include_externals = options
        .get("includeExternals")
        .and_then(Value::as_bool)
        .ok_or_else(|| "options.includeExternals".to_string())?;

    Ok(CleanupOperationRequest {
        path,
        break_locks,
        fix_recorded_timestamps,
        clear_dav_cache,
        vacuum_pristines,
        include_externals,
    })
}

fn upgrade_options(request: &JsonRpcRequest) -> Result<UpgradeOperationRequest, String> {
    let options = request
        .params
        .as_ref()
        .and_then(|params| params.get("options"))
        .and_then(Value::as_object)
        .ok_or_else(|| "options".to_string())?;
    for key in options.keys() {
        if !matches!(key.as_str(), "version" | "path") {
            return Err(format!("options.{key}"));
        }
    }
    let version = options
        .get("version")
        .and_then(Value::as_u64)
        .ok_or_else(|| "options.version".to_string())?;
    if version != 1 {
        return Err("options.version".to_string());
    }
    let path = options
        .get("path")
        .and_then(Value::as_str)
        .filter(|path| *path == ".")
        .ok_or_else(|| "options.path".to_string())?
        .to_string();

    Ok(UpgradeOperationRequest { path })
}

fn update_options(request: &JsonRpcRequest) -> Result<UpdateOperationRequest, String> {
    let options = request
        .params
        .as_ref()
        .and_then(|params| params.get("options"))
        .and_then(Value::as_object)
        .ok_or_else(|| "options".to_string())?;
    for key in options.keys() {
        if !matches!(
            key.as_str(),
            "version" | "path" | "revision" | "depth" | "depthIsSticky" | "ignoreExternals"
        ) {
            return Err(format!("options.{key}"));
        }
    }
    let version = options
        .get("version")
        .and_then(Value::as_u64)
        .ok_or_else(|| "options.version".to_string())?;
    if version != 1 {
        return Err("options.version".to_string());
    }
    let path = options
        .get("path")
        .and_then(Value::as_str)
        .filter(|path| valid_update_path(path))
        .ok_or_else(|| "options.path".to_string())?
        .to_string();
    let revision = options
        .get("revision")
        .and_then(update_revision_value)
        .ok_or_else(|| "options.revision".to_string())?;
    let depth = options
        .get("depth")
        .and_then(Value::as_str)
        .filter(|depth| valid_update_depth(depth))
        .ok_or_else(|| "options.depth".to_string())?
        .to_string();
    let depth_is_sticky = options
        .get("depthIsSticky")
        .and_then(Value::as_bool)
        .ok_or_else(|| "options.depthIsSticky".to_string())?;
    if depth == "workingCopy" && depth_is_sticky {
        return Err("options.depthIsSticky".to_string());
    }
    let ignore_externals = options
        .get("ignoreExternals")
        .and_then(Value::as_bool)
        .ok_or_else(|| "options.ignoreExternals".to_string())?;

    Ok(UpdateOperationRequest {
        path,
        revision,
        depth,
        depth_is_sticky,
        ignore_externals,
    })
}

fn property_set_options(request: &JsonRpcRequest) -> Result<PropertySetOperationRequest, String> {
    let options = request
        .params
        .as_ref()
        .and_then(|params| params.get("options"))
        .and_then(Value::as_object)
        .ok_or_else(|| "options".to_string())?;
    for key in options.keys() {
        if !matches!(key.as_str(), "version" | "path" | "name" | "value") {
            return Err(format!("options.{key}"));
        }
    }
    let version = options
        .get("version")
        .and_then(Value::as_u64)
        .ok_or_else(|| "options.version".to_string())?;
    if version != 1 {
        return Err("options.version".to_string());
    }
    let path = options
        .get("path")
        .and_then(Value::as_str)
        .filter(|path| valid_property_path(path))
        .ok_or_else(|| "options.path".to_string())?
        .to_string();
    let name = options
        .get("name")
        .and_then(Value::as_str)
        .filter(|name| valid_property_name(name))
        .ok_or_else(|| "options.name".to_string())?
        .to_string();
    let value = options
        .get("value")
        .and_then(Value::as_str)
        .filter(|value| valid_property_value(value))
        .ok_or_else(|| "options.value".to_string())?
        .to_string();

    Ok(PropertySetOperationRequest { path, name, value })
}

fn property_delete_options(
    request: &JsonRpcRequest,
) -> Result<PropertyDeleteOperationRequest, String> {
    let options = request
        .params
        .as_ref()
        .and_then(|params| params.get("options"))
        .and_then(Value::as_object)
        .ok_or_else(|| "options".to_string())?;
    for key in options.keys() {
        if !matches!(key.as_str(), "version" | "path" | "name") {
            return Err(format!("options.{key}"));
        }
    }
    let version = options
        .get("version")
        .and_then(Value::as_u64)
        .ok_or_else(|| "options.version".to_string())?;
    if version != 1 {
        return Err("options.version".to_string());
    }
    let path = options
        .get("path")
        .and_then(Value::as_str)
        .filter(|path| valid_property_path(path))
        .ok_or_else(|| "options.path".to_string())?
        .to_string();
    let name = options
        .get("name")
        .and_then(Value::as_str)
        .filter(|name| valid_property_name(name))
        .ok_or_else(|| "options.name".to_string())?
        .to_string();

    Ok(PropertyDeleteOperationRequest { path, name })
}

fn changelist_set_options(
    request: &JsonRpcRequest,
) -> Result<ChangelistSetOperationRequest, String> {
    let options = request
        .params
        .as_ref()
        .and_then(|params| params.get("options"))
        .and_then(Value::as_object)
        .ok_or_else(|| "options".to_string())?;
    for key in options.keys() {
        if !matches!(
            key.as_str(),
            "version" | "paths" | "depth" | "changelist" | "changelists"
        ) {
            return Err(format!("options.{key}"));
        }
    }
    let version = options
        .get("version")
        .and_then(Value::as_u64)
        .ok_or_else(|| "options.version".to_string())?;
    if version != 1 {
        return Err("options.version".to_string());
    }
    let paths = string_array_value(options.get("paths"), false)
        .filter(|paths| paths.iter().all(|path| valid_changelist_path(path)))
        .ok_or_else(|| "options.paths".to_string())?;
    if has_duplicate_strings(&paths) {
        return Err("options.paths".to_string());
    }
    let depth = options
        .get("depth")
        .and_then(Value::as_str)
        .filter(|depth| matches!(*depth, "empty" | "files" | "immediates" | "infinity"))
        .ok_or_else(|| "options.depth".to_string())?
        .to_string();
    let changelist = options
        .get("changelist")
        .and_then(Value::as_str)
        .filter(|changelist| valid_changelist_name(changelist))
        .ok_or_else(|| "options.changelist".to_string())?
        .to_string();
    let changelists = changelist_array_value(options.get("changelists"), true)
        .ok_or_else(|| "options.changelists".to_string())?;

    Ok(ChangelistSetOperationRequest {
        paths,
        depth,
        changelist,
        changelists,
    })
}

fn changelist_clear_options(
    request: &JsonRpcRequest,
) -> Result<ChangelistClearOperationRequest, String> {
    let options = request
        .params
        .as_ref()
        .and_then(|params| params.get("options"))
        .and_then(Value::as_object)
        .ok_or_else(|| "options".to_string())?;
    for key in options.keys() {
        if !matches!(key.as_str(), "version" | "paths" | "depth" | "changelists") {
            return Err(format!("options.{key}"));
        }
    }
    let version = options
        .get("version")
        .and_then(Value::as_u64)
        .ok_or_else(|| "options.version".to_string())?;
    if version != 1 {
        return Err("options.version".to_string());
    }
    let paths = string_array_value(options.get("paths"), false)
        .filter(|paths| paths.iter().all(|path| valid_changelist_path(path)))
        .ok_or_else(|| "options.paths".to_string())?;
    if has_duplicate_strings(&paths) {
        return Err("options.paths".to_string());
    }
    let depth = options
        .get("depth")
        .and_then(Value::as_str)
        .filter(|depth| matches!(*depth, "empty" | "files" | "immediates" | "infinity"))
        .ok_or_else(|| "options.depth".to_string())?
        .to_string();
    let changelists = changelist_array_value(options.get("changelists"), true)
        .ok_or_else(|| "options.changelists".to_string())?;

    Ok(ChangelistClearOperationRequest {
        paths,
        depth,
        changelists,
    })
}

fn lock_options(request: &JsonRpcRequest) -> Result<LockOperationRequest, String> {
    let options = request
        .params
        .as_ref()
        .and_then(|params| params.get("options"))
        .and_then(Value::as_object)
        .ok_or_else(|| "options".to_string())?;
    for key in options.keys() {
        if !matches!(key.as_str(), "version" | "paths" | "comment" | "stealLock") {
            return Err(format!("options.{key}"));
        }
    }
    let version = options
        .get("version")
        .and_then(Value::as_u64)
        .ok_or_else(|| "options.version".to_string())?;
    if version != 1 {
        return Err("options.version".to_string());
    }
    let paths = string_array_value(options.get("paths"), false)
        .filter(|paths| paths.iter().all(|path| valid_lock_path(path)))
        .ok_or_else(|| "options.paths".to_string())?;
    if has_duplicate_strings(&paths) {
        return Err("options.paths".to_string());
    }
    let Some(raw_comment) = options.get("comment") else {
        return Err("options.comment".to_string());
    };
    let comment = if raw_comment.is_null() {
        None
    } else {
        Some(
            raw_comment
                .as_str()
                .filter(|comment| valid_lock_comment(comment))
                .ok_or_else(|| "options.comment".to_string())?
                .to_string(),
        )
    };
    let steal_lock = options
        .get("stealLock")
        .and_then(Value::as_bool)
        .ok_or_else(|| "options.stealLock".to_string())?;

    Ok(LockOperationRequest {
        paths,
        comment,
        steal_lock,
    })
}

fn unlock_options(request: &JsonRpcRequest) -> Result<UnlockOperationRequest, String> {
    let options = request
        .params
        .as_ref()
        .and_then(|params| params.get("options"))
        .and_then(Value::as_object)
        .ok_or_else(|| "options".to_string())?;
    for key in options.keys() {
        if !matches!(key.as_str(), "version" | "paths" | "breakLock") {
            return Err(format!("options.{key}"));
        }
    }
    let version = options
        .get("version")
        .and_then(Value::as_u64)
        .ok_or_else(|| "options.version".to_string())?;
    if version != 1 {
        return Err("options.version".to_string());
    }
    let paths = string_array_value(options.get("paths"), false)
        .filter(|paths| paths.iter().all(|path| valid_lock_path(path)))
        .ok_or_else(|| "options.paths".to_string())?;
    if has_duplicate_strings(&paths) {
        return Err("options.paths".to_string());
    }
    let break_lock = options
        .get("breakLock")
        .and_then(Value::as_bool)
        .ok_or_else(|| "options.breakLock".to_string())?;

    Ok(UnlockOperationRequest { paths, break_lock })
}

fn branch_create_options(request: &JsonRpcRequest) -> Result<BranchCreateOperationRequest, String> {
    let options = request
        .params
        .as_ref()
        .and_then(|params| params.get("options"))
        .and_then(Value::as_object)
        .ok_or_else(|| "options".to_string())?;
    for key in options.keys() {
        if !matches!(
            key.as_str(),
            "version"
                | "sourceUrl"
                | "destinationUrl"
                | "revision"
                | "message"
                | "makeParents"
                | "ignoreExternals"
        ) {
            return Err(format!("options.{key}"));
        }
    }
    let version = options
        .get("version")
        .and_then(Value::as_u64)
        .ok_or_else(|| "options.version".to_string())?;
    if version != 1 {
        return Err("options.version".to_string());
    }
    let source_url = options
        .get("sourceUrl")
        .and_then(Value::as_str)
        .filter(|url| valid_branch_url(url))
        .ok_or_else(|| "options.sourceUrl".to_string())?
        .to_string();
    let destination_url = options
        .get("destinationUrl")
        .and_then(Value::as_str)
        .filter(|url| valid_branch_url(url))
        .ok_or_else(|| "options.destinationUrl".to_string())?
        .to_string();
    if source_url == destination_url {
        return Err("options.destinationUrl".to_string());
    }
    let revision = options
        .get("revision")
        .and_then(update_revision_value)
        .ok_or_else(|| "options.revision".to_string())?;
    let message = options
        .get("message")
        .and_then(Value::as_str)
        .filter(|message| valid_commit_message(message))
        .ok_or_else(|| "options.message".to_string())?
        .to_string();
    let make_parents = options
        .get("makeParents")
        .and_then(Value::as_bool)
        .ok_or_else(|| "options.makeParents".to_string())?;
    let ignore_externals = options
        .get("ignoreExternals")
        .and_then(Value::as_bool)
        .ok_or_else(|| "options.ignoreExternals".to_string())?;

    Ok(BranchCreateOperationRequest {
        source_url,
        destination_url,
        revision,
        message,
        make_parents,
        ignore_externals,
    })
}

fn switch_options(request: &JsonRpcRequest) -> Result<SwitchOperationRequest, String> {
    let options = request
        .params
        .as_ref()
        .and_then(|params| params.get("options"))
        .and_then(Value::as_object)
        .ok_or_else(|| "options".to_string())?;
    for key in options.keys() {
        if !matches!(
            key.as_str(),
            "version"
                | "path"
                | "url"
                | "revision"
                | "depth"
                | "depthIsSticky"
                | "ignoreExternals"
                | "ignoreAncestry"
        ) {
            return Err(format!("options.{key}"));
        }
    }
    let version = options
        .get("version")
        .and_then(Value::as_u64)
        .ok_or_else(|| "options.version".to_string())?;
    if version != 1 {
        return Err("options.version".to_string());
    }
    let path = options
        .get("path")
        .and_then(Value::as_str)
        .filter(|path| valid_update_path(path))
        .ok_or_else(|| "options.path".to_string())?
        .to_string();
    let url = options
        .get("url")
        .and_then(Value::as_str)
        .filter(|url| valid_branch_url(url))
        .ok_or_else(|| "options.url".to_string())?
        .to_string();
    let revision = options
        .get("revision")
        .and_then(update_revision_value)
        .ok_or_else(|| "options.revision".to_string())?;
    let depth = options
        .get("depth")
        .and_then(Value::as_str)
        .filter(|depth| valid_update_depth(depth))
        .ok_or_else(|| "options.depth".to_string())?
        .to_string();
    let depth_is_sticky = options
        .get("depthIsSticky")
        .and_then(Value::as_bool)
        .ok_or_else(|| "options.depthIsSticky".to_string())?;
    if depth == "workingCopy" && depth_is_sticky {
        return Err("options.depthIsSticky".to_string());
    }
    let ignore_externals = options
        .get("ignoreExternals")
        .and_then(Value::as_bool)
        .ok_or_else(|| "options.ignoreExternals".to_string())?;
    let ignore_ancestry = options
        .get("ignoreAncestry")
        .and_then(Value::as_bool)
        .ok_or_else(|| "options.ignoreAncestry".to_string())?;

    Ok(SwitchOperationRequest {
        path,
        url,
        revision,
        depth,
        depth_is_sticky,
        ignore_externals,
        ignore_ancestry,
    })
}

fn relocate_options(request: &JsonRpcRequest) -> Result<RelocateOperationRequest, String> {
    let options = request
        .params
        .as_ref()
        .and_then(|params| params.get("options"))
        .and_then(Value::as_object)
        .ok_or_else(|| "options".to_string())?;
    for key in options.keys() {
        if !matches!(
            key.as_str(),
            "version" | "fromUrl" | "toUrl" | "ignoreExternals"
        ) {
            return Err(format!("options.{key}"));
        }
    }
    let version = options
        .get("version")
        .and_then(Value::as_u64)
        .ok_or_else(|| "options.version".to_string())?;
    if version != 1 {
        return Err("options.version".to_string());
    }
    let from_url = options
        .get("fromUrl")
        .and_then(Value::as_str)
        .filter(|url| valid_branch_url(url))
        .ok_or_else(|| "options.fromUrl".to_string())?
        .to_string();
    let to_url = options
        .get("toUrl")
        .and_then(Value::as_str)
        .filter(|url| valid_branch_url(url))
        .ok_or_else(|| "options.toUrl".to_string())?
        .to_string();
    if from_url == to_url {
        return Err("options.toUrl".to_string());
    }
    let ignore_externals = options
        .get("ignoreExternals")
        .and_then(Value::as_bool)
        .ok_or_else(|| "options.ignoreExternals".to_string())?;

    Ok(RelocateOperationRequest {
        from_url,
        to_url,
        ignore_externals,
    })
}

fn merge_options(request: &JsonRpcRequest) -> Result<MergeOperationRequest, String> {
    let options = request
        .params
        .as_ref()
        .and_then(|params| params.get("options"))
        .and_then(Value::as_object)
        .ok_or_else(|| "options".to_string())?;
    for key in options.keys() {
        if !matches!(
            key.as_str(),
            "version"
                | "sourceUrl"
                | "targetPath"
                | "startRevision"
                | "endRevision"
                | "depth"
                | "ignoreMergeinfo"
                | "diffIgnoreAncestry"
                | "forceDelete"
                | "recordOnly"
                | "dryRun"
                | "allowMixedRevisions"
        ) {
            return Err(format!("options.{key}"));
        }
    }
    let version = options
        .get("version")
        .and_then(Value::as_u64)
        .ok_or_else(|| "options.version".to_string())?;
    if version != 1 {
        return Err("options.version".to_string());
    }
    let source_url = options
        .get("sourceUrl")
        .and_then(Value::as_str)
        .filter(|url| valid_branch_url(url))
        .ok_or_else(|| "options.sourceUrl".to_string())?
        .to_string();
    let target_path = options
        .get("targetPath")
        .and_then(Value::as_str)
        .filter(|path| valid_update_path(path))
        .ok_or_else(|| "options.targetPath".to_string())?
        .to_string();
    let start_revision = options
        .get("startRevision")
        .and_then(merge_revision_value)
        .ok_or_else(|| "options.startRevision".to_string())?;
    let end_revision = options
        .get("endRevision")
        .and_then(merge_revision_value)
        .ok_or_else(|| "options.endRevision".to_string())?;
    if start_revision == end_revision {
        return Err("options.endRevision".to_string());
    }
    let depth = options
        .get("depth")
        .and_then(Value::as_str)
        .filter(|depth| valid_merge_depth(depth))
        .ok_or_else(|| "options.depth".to_string())?
        .to_string();
    let ignore_mergeinfo = options
        .get("ignoreMergeinfo")
        .and_then(Value::as_bool)
        .ok_or_else(|| "options.ignoreMergeinfo".to_string())?;
    let diff_ignore_ancestry = options
        .get("diffIgnoreAncestry")
        .and_then(Value::as_bool)
        .ok_or_else(|| "options.diffIgnoreAncestry".to_string())?;
    let force_delete = options
        .get("forceDelete")
        .and_then(Value::as_bool)
        .ok_or_else(|| "options.forceDelete".to_string())?;
    let record_only = options
        .get("recordOnly")
        .and_then(Value::as_bool)
        .ok_or_else(|| "options.recordOnly".to_string())?;
    let dry_run = options
        .get("dryRun")
        .and_then(Value::as_bool)
        .ok_or_else(|| "options.dryRun".to_string())?;
    let allow_mixed_revisions = options
        .get("allowMixedRevisions")
        .and_then(Value::as_bool)
        .ok_or_else(|| "options.allowMixedRevisions".to_string())?;

    Ok(MergeOperationRequest {
        source_url,
        target_path,
        start_revision,
        end_revision,
        depth,
        ignore_mergeinfo,
        diff_ignore_ancestry,
        force_delete,
        record_only,
        dry_run,
        allow_mixed_revisions,
    })
}

fn commit_options(request: &JsonRpcRequest) -> Result<CommitOperationRequest, String> {
    let options = request
        .params
        .as_ref()
        .and_then(|params| params.get("options"))
        .and_then(Value::as_object)
        .ok_or_else(|| "options".to_string())?;
    for key in options.keys() {
        if !matches!(
            key.as_str(),
            "version"
                | "paths"
                | "message"
                | "depth"
                | "changelists"
                | "keepLocks"
                | "keepChangelists"
                | "commitAsOperations"
                | "includeFileExternals"
                | "includeDirExternals"
        ) {
            return Err(format!("options.{key}"));
        }
    }
    let version = options
        .get("version")
        .and_then(Value::as_u64)
        .ok_or_else(|| "options.version".to_string())?;
    if version != 1 {
        return Err("options.version".to_string());
    }
    let message = options
        .get("message")
        .and_then(Value::as_str)
        .filter(|message| valid_commit_message(message))
        .ok_or_else(|| "options.message".to_string())?
        .to_string();
    let changelists = changelist_array_value(options.get("changelists"), true)
        .ok_or_else(|| "options.changelists".to_string())?;
    let paths = string_array_value(options.get("paths"), false)
        .filter(|paths| paths.iter().all(|path| valid_commit_path(path)))
        .ok_or_else(|| "options.paths".to_string())?;
    if has_duplicate_strings(&paths) {
        return Err("options.paths".to_string());
    }
    let depth = options
        .get("depth")
        .and_then(Value::as_str)
        .filter(|depth| *depth == "empty")
        .ok_or_else(|| "options.depth".to_string())?
        .to_string();
    let keep_locks = options
        .get("keepLocks")
        .and_then(Value::as_bool)
        .filter(|keep_locks| !*keep_locks)
        .ok_or_else(|| "options.keepLocks".to_string())?;
    let keep_changelists = options
        .get("keepChangelists")
        .and_then(Value::as_bool)
        .filter(|keep_changelists| !*keep_changelists)
        .ok_or_else(|| "options.keepChangelists".to_string())?;
    let commit_as_operations = options
        .get("commitAsOperations")
        .and_then(Value::as_bool)
        .filter(|commit_as_operations| !*commit_as_operations)
        .ok_or_else(|| "options.commitAsOperations".to_string())?;
    let include_file_externals = options
        .get("includeFileExternals")
        .and_then(Value::as_bool)
        .filter(|include_file_externals| !*include_file_externals)
        .ok_or_else(|| "options.includeFileExternals".to_string())?;
    let include_dir_externals = options
        .get("includeDirExternals")
        .and_then(Value::as_bool)
        .filter(|include_dir_externals| !*include_dir_externals)
        .ok_or_else(|| "options.includeDirExternals".to_string())?;

    Ok(CommitOperationRequest {
        paths,
        message,
        depth,
        changelists,
        keep_locks,
        keep_changelists,
        commit_as_operations,
        include_file_externals,
        include_dir_externals,
    })
}

fn string_array_value(value: Option<&Value>, allow_empty: bool) -> Option<Vec<String>> {
    let values = value.and_then(Value::as_array)?;
    let mut strings = Vec::with_capacity(values.len());
    for value in values {
        let text = value.as_str()?;
        if text.trim().is_empty() {
            return None;
        }
        strings.push(text.to_string());
    }

    (allow_empty || !strings.is_empty()).then_some(strings)
}

fn changelist_array_value(value: Option<&Value>, allow_empty: bool) -> Option<Vec<String>> {
    let values = string_array_value(value, allow_empty)?;
    if values.iter().all(|value| valid_changelist_name(value)) && !has_duplicate_strings(&values) {
        Some(values)
    } else {
        None
    }
}

fn invalid_param(request: &JsonRpcRequest, field: &str) -> (DispatchOutcome, Value) {
    (
        DispatchOutcome::Continue,
        json!({
            "jsonrpc": "2.0",
            "id": request.id,
            "error": rpc_error(
                "RPC_INVALID_PARAMS",
                "protocol",
                "error.rpc.invalidParams",
                json!({ "field": field }),
                false,
            ),
        }),
    )
}

fn invalid_repository_id(request: &JsonRpcRequest) -> (DispatchOutcome, Value) {
    invalid_param(request, "repositoryId")
}

fn status_refresh_targets(
    request: &JsonRpcRequest,
) -> Result<Vec<StatusRefreshTarget>, &'static str> {
    let values = request
        .params
        .as_ref()
        .and_then(|params| params.get("targets"))
        .and_then(Value::as_array)
        .ok_or("targets")?;
    if values.is_empty() {
        return Err("targets");
    }

    let mut targets = Vec::with_capacity(values.len());
    for value in values {
        let path = value
            .get("path")
            .and_then(Value::as_str)
            .filter(|path| valid_repository_relative_path(path))
            .ok_or("targets.path")?
            .to_string();
        let depth = value
            .get("depth")
            .and_then(Value::as_str)
            .filter(|depth| matches!(*depth, "empty" | "files" | "immediates" | "infinity"))
            .ok_or("targets.depth")?
            .to_string();
        let reason = value
            .get("reason")
            .and_then(Value::as_str)
            .filter(|reason| !reason.trim().is_empty())
            .ok_or("targets.reason")?
            .to_string();
        targets.push(StatusRefreshTarget {
            path,
            depth,
            reason,
        });
    }

    Ok(targets)
}

fn valid_repository_relative_path(path: &str) -> bool {
    if path == "." {
        return true;
    }
    if path.trim().is_empty() {
        return false;
    }
    let normalized = path.replace('\\', "/");
    if normalized.starts_with('/') || normalized.contains(':') || normalized.contains('\0') {
        return false;
    }
    normalized
        .split('/')
        .all(|part| !part.is_empty() && part != "." && part != "..")
}

fn move_reconcile_paths(source_path: &str, destination_path: &str) -> Vec<String> {
    let mut paths = Vec::with_capacity(2);
    push_unique_path(&mut paths, parent_reconcile_path(source_path));
    push_unique_path(&mut paths, parent_reconcile_path(destination_path));
    paths
}

fn parent_reconcile_path(path: &str) -> String {
    match path.rsplit_once('/') {
        Some((parent, _)) if !parent.is_empty() => parent.to_string(),
        _ => ".".to_string(),
    }
}

fn push_unique_path(paths: &mut Vec<String>, path: String) {
    if !paths.iter().any(|existing| existing == &path) {
        paths.push(path);
    }
}

fn valid_update_path(path: &str) -> bool {
    path == "." || (!path.contains('\\') && valid_repository_relative_path(path))
}

fn valid_property_path(path: &str) -> bool {
    path == "." || (!path.contains('\\') && valid_repository_relative_path(path))
}

fn valid_property_name(name: &str) -> bool {
    if name.trim().is_empty() || name.contains('\0') || name.contains('\r') || name.contains('\n') {
        return false;
    }
    svn_prop_name_is_valid(name)
}

fn svn_prop_name_is_valid(name: &str) -> bool {
    let mut parts = name.split(':');
    let first = parts.next().unwrap_or_default();
    if first.is_empty() || !valid_prop_name_part(first) {
        return false;
    }
    parts.all(|part| !part.is_empty() && valid_prop_name_part(part))
}

fn valid_prop_name_part(part: &str) -> bool {
    part.bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b'_'))
}

fn valid_property_value(value: &str) -> bool {
    !value.contains('\0') && !value.contains('\r')
}

fn valid_changelist_path(path: &str) -> bool {
    !path.contains('\\') && valid_repository_relative_path(path)
}

fn valid_changelist_name(name: &str) -> bool {
    !name.trim().is_empty() && !name.contains('\0') && !name.contains('\r') && !name.contains('\n')
}

fn valid_lock_path(path: &str) -> bool {
    path != "." && !path.contains('\\') && valid_repository_relative_path(path)
}

fn valid_lock_comment(comment: &str) -> bool {
    !comment.trim().is_empty() && !comment.contains('\0') && !comment.contains('\r')
}

fn valid_commit_path(path: &str) -> bool {
    path == "." || (!path.contains('\\') && valid_repository_relative_path(path))
}

fn valid_move_path(path: &str) -> bool {
    path != "." && !path.contains('\\') && valid_repository_relative_path(path)
}

fn has_duplicate_strings(values: &[String]) -> bool {
    let mut seen = BTreeSet::new();
    values.iter().any(|value| !seen.insert(value.as_str()))
}

fn valid_commit_message(message: &str) -> bool {
    !message.trim().is_empty() && !message.contains('\0') && !message.contains('\r')
}

fn replace_session_local_entries(session: &mut RepositorySession, entries: &[StatusEntry]) {
    session.local_entries.clear();
    for entry in entries {
        if is_projectable_status(entry) {
            session
                .local_entries
                .insert(entry.path.clone(), entry.clone());
        }
    }
}

fn replace_session_remote_entries(session: &mut RepositorySession, entries: &[StatusEntry]) {
    session.remote_entries.clear();
    for entry in entries {
        if is_projectable_remote_status(entry) {
            session
                .remote_entries
                .insert(entry.path.clone(), entry.clone());
        }
    }
}

fn remove_conflict_artifact_entries(entries: &mut Vec<StatusEntry>) {
    let artifact_paths = entries
        .iter()
        .flat_map(|entry| entry.conflict_artifacts.iter())
        .cloned()
        .collect::<BTreeSet<_>>();
    entries.retain(|entry| {
        entry.local_status != "unversioned" || !artifact_paths.contains(&entry.path)
    });
}

fn is_projectable_status(entry: &StatusEntry) -> bool {
    is_interesting_status(entry)
        || entry.switched
        || entry.lock.is_some()
        || entry.needs_lock
        || is_sparse_status_depth(&entry.depth)
}

fn is_projectable_remote_status(entry: &StatusEntry) -> bool {
    !matches!(
        entry.remote_status.as_str(),
        "none" | "normal" | "notChecked"
    )
}

fn is_interesting_status(entry: &StatusEntry) -> bool {
    entry.conflict.is_some()
        || is_actionable_local_status(&entry.local_status)
        || is_actionable_local_status(&entry.node_status)
        || is_actionable_local_status(&entry.text_status)
        || is_actionable_local_status(&entry.property_status)
}

fn is_sparse_status_depth(depth: &str) -> bool {
    matches!(depth, "empty" | "files" | "immediates")
}

fn is_actionable_local_status(status: &str) -> bool {
    !matches!(status, "none" | "normal")
}

fn coverage_matches(target_path: &str, depth: &str, entry: &StatusEntry) -> bool {
    let target = target_path.replace('\\', "/");
    let entry_path = entry.path.replace('\\', "/");
    if target == "." {
        if entry_path == "." {
            return true;
        }
        return match depth {
            "empty" => false,
            "files" => !entry_path.contains('/') && entry.kind == "file",
            "immediates" => !entry_path.contains('/'),
            "infinity" => true,
            _ => false,
        };
    }
    if entry_path == target {
        return true;
    }
    let prefix = format!("{target}/");
    let Some(rest) = entry_path.strip_prefix(&prefix) else {
        return false;
    };

    match depth {
        "empty" => false,
        "files" => !rest.contains('/') && entry.kind == "file",
        "immediates" => !rest.contains('/'),
        "infinity" => true,
        _ => false,
    }
}

fn is_complete_delta_coverage(coverage: &[StatusCoverageScope]) -> bool {
    coverage.len() == 1 && coverage[0].path == "." && coverage[0].depth == "infinity"
}

fn changed_upserts(
    before: &BTreeMap<String, StatusEntry>,
    after: &BTreeMap<String, StatusEntry>,
) -> Vec<StatusEntry> {
    after
        .iter()
        .filter(|(path, entry)| before.get(*path) != Some(*entry))
        .map(|(_, entry)| entry.clone())
        .collect()
}

fn removed_paths(
    before: &BTreeMap<String, StatusEntry>,
    after: &BTreeMap<String, StatusEntry>,
) -> Vec<String> {
    before
        .keys()
        .filter(|path| !after.contains_key(*path))
        .cloned()
        .collect()
}

fn summarize_entries<'a>(entries: impl Iterator<Item = &'a StatusEntry>) -> StatusSummary {
    let entries = entries.collect::<Vec<_>>();
    let artifact_paths = entries
        .iter()
        .flat_map(|entry| entry.conflict_artifacts.iter())
        .collect::<BTreeSet<_>>();
    let mut local_changes = 0;
    let mut conflicts = 0;
    let mut unversioned = 0;
    for entry in entries {
        if entry.local_status == "unversioned" && artifact_paths.contains(&entry.path) {
            continue;
        }
        if is_interesting_status(entry) {
            local_changes += 1;
        }
        if entry.local_status == "unversioned" {
            unversioned += 1;
        }
        if entry.conflict.is_some() || entry.local_status == "conflicted" {
            conflicts += 1;
        }
    }

    StatusSummary {
        local_changes,
        remote_changes: 0,
        conflicts,
        unversioned,
    }
}

fn summarize_snapshot_entries<'a>(
    local_entries: impl Iterator<Item = &'a StatusEntry>,
    remote_entries: impl Iterator<Item = &'a StatusEntry>,
) -> StatusSummary {
    let mut summary = summarize_entries(local_entries);
    summary.remote_changes = remote_entries
        .filter(|entry| {
            !matches!(
                entry.remote_status.as_str(),
                "none" | "normal" | "notChecked"
            )
        })
        .count() as u32;
    summary
}

fn summary_delta(before: &StatusSummary, after: &StatusSummary) -> StatusSummaryDelta {
    StatusSummaryDelta {
        local_changes: after.local_changes as i32 - before.local_changes as i32,
        remote_changes: after.remote_changes as i32 - before.remote_changes as i32,
        conflicts: after.conflicts as i32 - before.conflicts as i32,
        unversioned: after.unversioned as i32 - before.unversioned as i32,
    }
}

fn unsupported_discovery_mode(request: &JsonRpcRequest, field: &str) -> (DispatchOutcome, Value) {
    (
        DispatchOutcome::Continue,
        json!({
            "jsonrpc": "2.0",
            "id": request.id,
            "error": rpc_error(
                "REPOSITORY_DISCOVERY_MODE_UNSUPPORTED",
                "unsupported",
                "error.repository.discoveryModeUnsupported",
                json!({ "field": field }),
                false,
            ),
        }),
    )
}

fn repository_not_open(request: &JsonRpcRequest, repository_id: &str) -> (DispatchOutcome, Value) {
    (
        DispatchOutcome::Continue,
        json!({
            "jsonrpc": "2.0",
            "id": request.id,
            "error": rpc_error(
                "REPOSITORY_NOT_OPEN",
                "repository",
                "error.repository.notOpen",
                json!({ "repositoryId": repository_id }),
                false,
            ),
        }),
    )
}

fn repository_already_open(
    request: &JsonRpcRequest,
    repository_id: &str,
) -> (DispatchOutcome, Value) {
    (
        DispatchOutcome::Continue,
        json!({
            "jsonrpc": "2.0",
            "id": request.id,
            "error": rpc_error(
                "REPOSITORY_ALREADY_OPEN",
                "repository",
                "error.repository.alreadyOpen",
                json!({ "repositoryId": repository_id }),
                false,
            ),
        }),
    )
}

fn unsupported_operation_kind(request: &JsonRpcRequest, kind: &str) -> (DispatchOutcome, Value) {
    (
        DispatchOutcome::Continue,
        json!({
            "jsonrpc": "2.0",
            "id": request.id,
            "error": rpc_error(
                "OPERATION_KIND_UNSUPPORTED",
                "unsupported",
                "error.operation.kindUnsupported",
                json!({ "kind": kind }),
                false,
            ),
        }),
    )
}

#[cfg(test)]
mod i5_remote_lane_tests {
    use super::*;
    use subversionr_protocol::{RemoteFailure, RemoteFailureCategory};

    fn cancelled_settlement(
        effect: RemoteOperationEffect,
        worker_was_resumed: bool,
    ) -> RemoteWorkerSettlement {
        RemoteWorkerSettlement {
            result: Err(BridgeFailure::new(
                "SUBVERSIONR_REMOTE_WORKER_CANCELLED",
                "cancelled",
                "error.remote.workerCancelled",
                json!({}),
                false,
            )),
            remote_failure: Some(RemoteFailure {
                category: RemoteFailureCategory::Cancellation,
                reason: RemoteFailureClass::OperationCancelled,
                cleanup_appropriate: false,
            }),
            effect,
            worker_was_resumed,
            execution_origin_known: true,
            termination: crate::WorkerTerminationDisposition::Settled,
            job_descendants_zero: true,
            temp_root_removed: true,
            operation_output: None,
        }
    }

    fn insert_remote_recovery_session(state: &mut DaemonState, path: &str) -> String {
        let repository_id = format!("repo-uuid:{path}");
        state.repositories.insert(
            repository_id.clone(),
            RepositorySession {
                repository_id: repository_id.clone(),
                epoch: 1,
                identity: RepositoryIdentity {
                    repository_uuid: "repo-uuid".to_string(),
                    repository_root_url: "https://svn.example.invalid/project".to_string(),
                    working_copy_root: path.to_string(),
                    workspace_scope_root: path.to_string(),
                    format: 31,
                },
                boundary_roots: Vec::new(),
                next_generation: 1,
                local_entries: BTreeMap::new(),
                remote_entries: BTreeMap::new(),
            },
        );
        repository_id
    }

    #[test]
    fn effect_is_daemon_derived_for_each_remote_entrypoint() {
        let cases = [
            ("repository/checkout", None, RemoteOperationEffect::Mutation),
            ("status/checkRemote", None, RemoteOperationEffect::ReadOnly),
            ("content/get", None, RemoteOperationEffect::ReadOnly),
            ("history/log", None, RemoteOperationEffect::ReadOnly),
            ("history/blame", None, RemoteOperationEffect::ReadOnly),
            (
                "operation/run",
                Some("update"),
                RemoteOperationEffect::Mutation,
            ),
            (
                "operation/run",
                Some("switch"),
                RemoteOperationEffect::Mutation,
            ),
            (
                "operation/run",
                Some("merge"),
                RemoteOperationEffect::Mutation,
            ),
            (
                "operation/run",
                Some("commit"),
                RemoteOperationEffect::Mutation,
            ),
        ];
        for (method, kind, expected) in cases {
            let mut params = serde_json::Map::new();
            if let Some(kind) = kind {
                params.insert("kind".to_string(), json!(kind));
            }
            let request = JsonRpcRequest {
                id: json!(1),
                method: method.to_string(),
                params: Some(Value::Object(params)),
            };
            assert_eq!(remote_effect_for_request(&request), Some(expected));
        }
    }

    #[test]
    fn only_post_resume_mutation_failure_enters_recovery() {
        let lane = "c:/wc";
        let origin = "81234567-89ab-4def-8123-456789abcdef";
        let mut state = DaemonState::new();
        assert!(
            state
                .reserve_remote_lane(lane, origin, RemoteOperationEffect::Mutation, None, None,)
                .is_none()
        );
        state.settle_remote_launch(
            lane,
            origin,
            &cancelled_settlement(RemoteOperationEffect::Mutation, false),
        );
        assert!(!state.remote_native_lanes.contains_key(lane));

        assert!(
            state
                .reserve_remote_lane(
                    lane,
                    origin,
                    RemoteOperationEffect::Mutation,
                    Some("repo".to_string()),
                    Some(1),
                )
                .is_none()
        );
        state.settle_remote_launch(
            lane,
            origin,
            &cancelled_settlement(RemoteOperationEffect::Mutation, true),
        );
        assert!(matches!(
            state.remote_native_lanes.get(lane),
            Some(RemoteNativeLaneState::Recovering {
                origin_operation_id,
                recovery_operation_id: None,
                ..
            }) if origin_operation_id == origin
        ));
    }

    #[test]
    fn unattributed_post_resume_checkout_failure_is_terminally_blocked() {
        let lane = "c:/checkout/new";
        let origin = "a1234567-89ab-4def-8123-456789abcdef";
        let mut state = DaemonState::new();
        assert!(
            state
                .reserve_remote_lane(lane, origin, RemoteOperationEffect::Mutation, None, None)
                .is_none()
        );

        let override_failure = state
            .settle_remote_launch(
                lane,
                origin,
                &cancelled_settlement(RemoteOperationEffect::Mutation, true),
            )
            .expect("an unattributed mutation cannot enter repository-scoped recovery");

        assert_eq!(
            override_failure.code(),
            "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED"
        );
        assert!(matches!(
            state.remote_native_lanes.get(lane),
            Some(RemoteNativeLaneState::Blocked {
                origin_operation_id,
                reason: RemoteFailureClass::RemoteOperationIndeterminate,
                cleanup_appropriate: false,
            }) if origin_operation_id == origin
        ));
        assert!(state.take_pending_notifications().is_empty());

        let child_request = JsonRpcRequest {
            id: json!(2),
            method: "repository/open".to_string(),
            params: Some(json!({ "path": "C:/checkout/new/child" })),
        };
        assert_eq!(
            state
                .native_lane_failure_for_request(&child_request)
                .expect("the blocked checkout lane must reject child paths")
                .code(),
            "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED"
        );

        let unrelated_request = JsonRpcRequest {
            id: json!(3),
            method: "repository/open".to_string(),
            params: Some(json!({ "path": "C:/unrelated" })),
        };
        assert!(
            state
                .native_lane_failure_for_request(&unrelated_request)
                .is_none(),
            "a blocked checkout lane must not affect an unrelated working copy"
        );
    }

    #[test]
    fn unsafe_cleanup_blocks_success_before_lane_release() {
        let lane = "c:/wc";
        let origin = "91234567-89ab-4def-8123-456789abcdef";
        let mut state = DaemonState::new();
        assert!(
            state
                .reserve_remote_lane(lane, origin, RemoteOperationEffect::ReadOnly, None, None)
                .is_none()
        );
        state.settle_remote_launch(
            lane,
            origin,
            &RemoteWorkerSettlement {
                result: Ok(()),
                remote_failure: None,
                effect: RemoteOperationEffect::ReadOnly,
                worker_was_resumed: true,
                execution_origin_known: true,
                termination: crate::WorkerTerminationDisposition::Blocked,
                job_descendants_zero: true,
                temp_root_removed: false,
                operation_output: None,
            },
        );
        assert!(matches!(
            state.remote_native_lanes.get(lane),
            Some(RemoteNativeLaneState::Blocked {
                reason: RemoteFailureClass::RemoteRecoveryBlocked,
                ..
            })
        ));
    }

    #[test]
    fn all_used_recovery_ids_are_rejected_for_the_lane_lifetime() {
        let path = "C:/wc-recovery-id-history";
        let lane = absolute_path_key(&normalize_absolute_path_text(path));
        let origin = "41234567-89ab-4def-8123-456789abcdef";
        let older = "51234567-89ab-4def-8123-456789abcdef";
        let newer = "61234567-89ab-4def-8123-456789abcdef";
        let mut state = DaemonState::new();
        let repository_id = insert_remote_recovery_session(&mut state, path);
        state.remote_native_lanes.insert(
            lane,
            RemoteNativeLaneState::Recovering {
                origin_operation_id: origin.to_string(),
                recovery_operation_id: None,
                used_recovery_operation_ids: [older.to_string(), newer.to_string()]
                    .into_iter()
                    .collect(),
            },
        );
        let request = JsonRpcRequest {
            id: json!(1),
            method: "remote/recoverWorkingCopy".to_string(),
            params: Some(json!({
                "repositoryId": repository_id,
                "epoch": 1,
                "originOperationId": origin,
                "operationId": older,
                "timeoutMs": 30_000
            })),
        };

        let (_, response) = state.dispatch_remote_recover_working_copy(&request);
        assert_eq!(
            response["error"]["code"],
            "SUBVERSIONR_REMOTE_RECOVERY_OPERATION_ID_REUSED"
        );
        assert!(state.pending_remote_recovery_launch.is_none());
    }

    #[test]
    fn bounded_recovery_id_history_transitions_atomically_to_blocked() {
        let path = "C:/wc-recovery-id-limit";
        let lane = absolute_path_key(&normalize_absolute_path_text(path));
        let origin = "71234567-89ab-4def-8123-456789abcdef";
        let mut state = DaemonState::new();
        let repository_id = insert_remote_recovery_session(&mut state, path);
        let used_recovery_operation_ids = (0..MAX_REMOTE_RECOVERY_OPERATION_IDS)
            .map(|index| format!("{index:08x}-89ab-4def-8123-{index:012x}"))
            .collect();
        state.remote_native_lanes.insert(
            lane.clone(),
            RemoteNativeLaneState::Recovering {
                origin_operation_id: origin.to_string(),
                recovery_operation_id: None,
                used_recovery_operation_ids,
            },
        );
        let request = JsonRpcRequest {
            id: json!(1),
            method: "remote/recoverWorkingCopy".to_string(),
            params: Some(json!({
                "repositoryId": repository_id,
                "epoch": 1,
                "originOperationId": origin,
                "operationId": "81234567-89ab-4def-8123-456789abcdef",
                "timeoutMs": 30_000
            })),
        };

        let (_, response) = state.dispatch_remote_recover_working_copy(&request);
        assert_eq!(response["result"]["outcome"], "blocked");
        assert!(matches!(
            state.remote_native_lanes.get(&lane),
            Some(RemoteNativeLaneState::Blocked {
                reason: RemoteFailureClass::RemoteRecoveryBlocked,
                ..
            })
        ));
        assert!(state.pending_notifications.iter().any(|notification| {
            notification["method"] == "remoteConnection/state"
                && notification["params"]["state"]["recovery"] == "blocked"
        }));
    }

    #[test]
    fn unmatched_settlement_does_not_leak_or_steal_active_operation_ids() {
        let orphan = "91234567-89ab-4def-8123-456789abcdef";
        let owned = "a1234567-89ab-4def-8123-456789abcdef";
        let mut state = DaemonState::new();
        state.active_remote_operation_ids.insert(orphan.to_string());
        state.active_remote_operation_ids.insert(owned.to_string());
        state.remote_native_lanes.insert(
            "c:/owned".to_string(),
            RemoteNativeLaneState::Active {
                operation_id: owned.to_string(),
                effect: RemoteOperationEffect::ReadOnly,
                repository_id: None,
                epoch: None,
            },
        );
        let settlement = RemoteWorkerSettlement::pre_launch(
            RemoteOperationEffect::ReadOnly,
            Err(BridgeFailure::new(
                "SUBVERSIONR_REMOTE_WORKER_START_FAILED",
                "process",
                "error.remote.workerStartFailed",
                json!({}),
                false,
            )),
        );

        assert!(
            state
                .settle_remote_launch("c:/missing", orphan, &settlement)
                .is_none()
        );
        assert!(!state.active_remote_operation_ids.contains(orphan));
        assert!(
            state
                .settle_remote_launch("c:/wrong", owned, &settlement)
                .is_none()
        );
        assert!(state.active_remote_operation_ids.contains(owned));
    }

    #[test]
    fn repository_close_is_gated_for_every_non_free_lane_state() {
        let path = "C:/wc-close-gate";
        let lane = absolute_path_key(&normalize_absolute_path_text(path));
        let mut state = DaemonState::new();
        let repository_id = insert_remote_recovery_session(&mut state, path);
        let close = JsonRpcRequest {
            id: json!(1),
            method: "repository/close".to_string(),
            params: Some(json!({ "repositoryId": repository_id, "epoch": 1 })),
        };
        let cases = [
            (
                RemoteNativeLaneState::Active {
                    operation_id: "b1234567-89ab-4def-8123-456789abcdef".to_string(),
                    effect: RemoteOperationEffect::Mutation,
                    repository_id: Some("repo".to_string()),
                    epoch: Some(1),
                },
                "SUBVERSIONR_REMOTE_NATIVE_LANE_BUSY",
            ),
            (
                RemoteNativeLaneState::Recovering {
                    origin_operation_id: "c1234567-89ab-4def-8123-456789abcdef".to_string(),
                    recovery_operation_id: None,
                    used_recovery_operation_ids: BTreeSet::new(),
                },
                "SUBVERSIONR_REMOTE_OPERATION_INDETERMINATE",
            ),
            (
                RemoteNativeLaneState::Blocked {
                    origin_operation_id: "d1234567-89ab-4def-8123-456789abcdef".to_string(),
                    reason: RemoteFailureClass::RemoteRecoveryBlocked,
                    cleanup_appropriate: false,
                },
                "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED",
            ),
        ];
        for (lane_state, expected) in cases {
            state.remote_native_lanes.insert(lane.clone(), lane_state);
            assert_eq!(
                state
                    .native_lane_failure_for_request(&close)
                    .expect("close must be lane gated")
                    .code(),
                expected
            );
        }
    }

    #[test]
    fn checkout_journal_survives_restart_and_requires_exact_confirmation() {
        let storage = checkout_journal_test_root("restart-confirm");
        let target = storage.join("checkout-target");
        let operation_id = "e1234567-89ab-4def-8123-456789abcdef";
        let mut journal = RemoteCheckoutMutationJournal::open(&storage).expect("open journal");
        let armed = journal
            .arm(&target, operation_id)
            .expect("arm checkout target");
        drop(journal);

        let journal = RemoteCheckoutMutationJournal::open(&storage).expect("reopen journal");
        assert_eq!(
            journal.entries()[0].state,
            RemoteCheckoutMutationState::Blocked
        );
        let lane = absolute_path_key(&normalize_absolute_path_text(&armed.target_path));
        let mut state = DaemonState::new();
        state.remote_checkout_journal = Some(journal);
        state.remote_native_lanes.insert(
            lane.clone(),
            RemoteNativeLaneState::Blocked {
                origin_operation_id: operation_id.to_string(),
                reason: RemoteFailureClass::RemoteRecoveryBlocked,
                cleanup_appropriate: false,
            },
        );

        let list = JsonRpcRequest {
            id: json!(1),
            method: "remote/listCheckoutTargetRecoveries".to_string(),
            params: Some(json!({})),
        };
        let (_, listed) = state.dispatch_list_checkout_target_recoveries(&list);
        assert_eq!(listed["result"]["entries"][0]["state"], "blocked");
        assert_eq!(
            listed["result"]["entries"][0]["targetSha256"],
            armed.target_sha256
        );

        let wrong = JsonRpcRequest {
            id: json!(2),
            method: "remote/confirmCheckoutTargetDisposition".to_string(),
            params: Some(json!({
                "targetPath": armed.target_path,
                "targetSha256": "f".repeat(64),
                "originOperationId": operation_id,
                "confirmation": "reviewedAndResolved"
            })),
        };
        let (_, rejected) = state.dispatch_confirm_checkout_target_disposition(&wrong);
        assert_eq!(
            rejected["error"]["code"],
            "SUBVERSIONR_REMOTE_CHECKOUT_JOURNAL_CONTRACT_INVALID"
        );
        assert!(state.remote_native_lanes.contains_key(&lane));

        let confirm = JsonRpcRequest {
            id: json!(3),
            method: "remote/confirmCheckoutTargetDisposition".to_string(),
            params: Some(json!({
                "targetPath": armed.target_path,
                "targetSha256": armed.target_sha256,
                "originOperationId": operation_id,
                "confirmation": "reviewedAndResolved"
            })),
        };
        let (_, released) = state.dispatch_confirm_checkout_target_disposition(&confirm);
        assert_eq!(released["result"]["released"], true);
        assert!(!state.remote_native_lanes.contains_key(&lane));
        assert!(
            state
                .remote_checkout_journal
                .as_ref()
                .expect("journal remains initialized")
                .entries()
                .is_empty()
        );
        drop(state);
        assert!(
            RemoteCheckoutMutationJournal::open(&storage)
                .expect("reopen cleared journal")
                .entries()
                .is_empty()
        );
        std::fs::remove_dir_all(storage).expect("remove checkout journal test root");
    }

    #[test]
    fn checkout_journal_clears_only_after_safe_prelaunch_or_validated_output() {
        let storage = checkout_journal_test_root("settlement");
        let target = storage.join("checkout-target");
        let target_text = target.to_string_lossy().into_owned();
        let lane = absolute_path_key(&normalize_absolute_path_text(&target_text));
        let first = "f1234567-89ab-4def-8123-456789abcdef";
        let second = "01234567-89ab-4def-8123-456789abcdef";
        let mut state = DaemonState::new();
        state.remote_checkout_journal =
            Some(RemoteCheckoutMutationJournal::open(&storage).expect("open settlement journal"));

        state
            .remote_checkout_journal
            .as_mut()
            .expect("journal")
            .arm(&target, first)
            .expect("arm first checkout");
        assert!(
            state
                .reserve_remote_lane(&lane, first, RemoteOperationEffect::Mutation, None, None)
                .is_none()
        );
        let prelaunch = RemoteWorkerSettlement::pre_launch(
            RemoteOperationEffect::Mutation,
            Err(BridgeFailure::new(
                "SUBVERSIONR_REMOTE_WORKER_START_FAILED",
                "process",
                "error.remote.workerStartFailed",
                json!({}),
                false,
            )),
        );
        assert!(
            state
                .settle_remote_launch(&lane, first, &prelaunch)
                .is_none()
        );
        assert!(!state.remote_native_lanes.contains_key(&lane));
        assert!(
            state
                .remote_checkout_journal
                .as_ref()
                .expect("journal")
                .entries()
                .is_empty()
        );

        state
            .remote_checkout_journal
            .as_mut()
            .expect("journal")
            .arm(&target, second)
            .expect("arm second checkout");
        assert!(
            state
                .reserve_remote_lane(&lane, second, RemoteOperationEffect::Mutation, None, None)
                .is_none()
        );
        let output = crate::RepositoryCheckoutResult {
            working_copy_path: target_text.clone(),
            revision: 7,
        };
        let settlement = RemoteWorkerSettlement {
            result: Ok(()),
            operation_output: Some(crate::RemoteSvnAnonymousOutput::Checkout(output.clone())),
            remote_failure: None,
            effect: RemoteOperationEffect::Mutation,
            worker_was_resumed: true,
            execution_origin_known: true,
            termination: crate::WorkerTerminationDisposition::Settled,
            job_descendants_zero: true,
            temp_root_removed: true,
        };
        assert!(
            state
                .settle_remote_launch(&lane, second, &settlement)
                .is_none()
        );
        assert!(matches!(
            state.remote_native_lanes.get(&lane),
            Some(RemoteNativeLaneState::Active { operation_id, .. }) if operation_id == second
        ));
        assert_eq!(
            state
                .remote_checkout_journal
                .as_ref()
                .expect("journal")
                .entries()[0]
                .state,
            RemoteCheckoutMutationState::Armed
        );

        let response = state
            .complete_remote_svn_anonymous(
                json!(4),
                &lane,
                second,
                None,
                None,
                crate::RemoteSvnAnonymousRequest::Checkout {
                    request: RepositoryCheckoutRequest {
                        url: "svn://svn.example.invalid/project/trunk".to_string(),
                        target_path: target_text.clone(),
                        revision: "head".to_string(),
                        depth: "infinity".to_string(),
                        ignore_externals: true,
                    },
                },
                crate::RemoteSvnAnonymousOutput::Checkout(output),
            )
            .expect("validated checkout output");
        assert_eq!(response["result"]["revision"], 7);
        assert!(!state.remote_native_lanes.contains_key(&lane));
        assert!(
            state
                .remote_checkout_journal
                .as_ref()
                .expect("journal")
                .entries()
                .is_empty()
        );

        let third = "11234567-89ab-4def-8123-456789abcdef";
        state
            .remote_checkout_journal
            .as_mut()
            .expect("journal")
            .arm(&target, third)
            .expect("arm mismatched checkout");
        assert!(
            state
                .reserve_remote_lane(&lane, third, RemoteOperationEffect::Mutation, None, None)
                .is_none()
        );
        let mismatched_output = crate::RepositoryCheckoutResult {
            working_copy_path: storage.join("other-target").to_string_lossy().into_owned(),
            revision: 8,
        };
        let mismatched_settlement = RemoteWorkerSettlement {
            operation_output: Some(crate::RemoteSvnAnonymousOutput::Checkout(
                mismatched_output.clone(),
            )),
            ..settlement
        };
        assert!(
            state
                .settle_remote_launch(&lane, third, &mismatched_settlement)
                .is_none()
        );
        let mismatch = state
            .complete_remote_svn_anonymous(
                json!(5),
                &lane,
                third,
                None,
                None,
                crate::RemoteSvnAnonymousRequest::Checkout {
                    request: RepositoryCheckoutRequest {
                        url: "svn://svn.example.invalid/project/trunk".to_string(),
                        target_path: target_text,
                        revision: "head".to_string(),
                        depth: "infinity".to_string(),
                        ignore_externals: true,
                    },
                },
                crate::RemoteSvnAnonymousOutput::Checkout(mismatched_output),
            )
            .expect_err("mismatched checkout output must fail closed");
        assert_eq!(
            mismatch.code(),
            "SUBVERSIONR_REMOTE_WORKER_PROTOCOL_INVALID"
        );
        assert!(matches!(
            state.remote_native_lanes.get(&lane),
            Some(RemoteNativeLaneState::Blocked { origin_operation_id, .. }) if origin_operation_id == third
        ));
        assert_eq!(
            state
                .remote_checkout_journal
                .as_ref()
                .expect("journal")
                .entries()[0]
                .state,
            RemoteCheckoutMutationState::Blocked
        );
        drop(state);
        std::fs::remove_dir_all(storage).expect("remove checkout journal test root");
    }

    #[test]
    fn checkout_journal_clear_failure_blocks_lane_in_current_process() {
        let storage = checkout_journal_test_root("clear-failure");
        let target = storage.join("checkout-target");
        let target_text = target.to_string_lossy().into_owned();
        let lane = absolute_path_key(&normalize_absolute_path_text(&target_text));
        let operation_id = "31234567-89ab-4def-8123-456789abcdef";
        let mut state = DaemonState::new();
        state.remote_checkout_journal = Some(
            RemoteCheckoutMutationJournal::open(&storage).expect("open clear-failure journal"),
        );
        state
            .remote_checkout_journal
            .as_mut()
            .expect("journal")
            .arm(&target, operation_id)
            .expect("arm checkout");
        assert!(
            state
                .reserve_remote_lane(
                    &lane,
                    operation_id,
                    RemoteOperationEffect::Mutation,
                    None,
                    None,
                )
                .is_none()
        );
        let output = crate::RepositoryCheckoutResult {
            working_copy_path: target_text.clone(),
            revision: 9,
        };
        let settlement = RemoteWorkerSettlement {
            result: Ok(()),
            operation_output: Some(crate::RemoteSvnAnonymousOutput::Checkout(output.clone())),
            remote_failure: None,
            effect: RemoteOperationEffect::Mutation,
            worker_was_resumed: true,
            execution_origin_known: true,
            termination: crate::WorkerTerminationDisposition::Settled,
            job_descendants_zero: true,
            temp_root_removed: true,
        };
        assert!(
            state
                .settle_remote_launch(&lane, operation_id, &settlement)
                .is_none()
        );

        std::fs::remove_dir_all(&storage).expect("remove journal storage directory");
        std::fs::write(&storage, b"not-a-directory").expect("replace storage with a file");

        let failure = state
            .complete_remote_svn_anonymous(
                json!(6),
                &lane,
                operation_id,
                None,
                None,
                crate::RemoteSvnAnonymousRequest::Checkout {
                    request: RepositoryCheckoutRequest {
                        url: "svn://svn.example.invalid/project/trunk".to_string(),
                        target_path: target_text,
                        revision: "head".to_string(),
                        depth: "infinity".to_string(),
                        ignore_externals: true,
                    },
                },
                crate::RemoteSvnAnonymousOutput::Checkout(output),
            )
            .expect_err("journal clear persistence failure must fail closed");
        assert_eq!(
            failure.code(),
            "SUBVERSIONR_REMOTE_CHECKOUT_JOURNAL_INVALID"
        );
        assert!(matches!(
            state.remote_native_lanes.get(&lane),
            Some(RemoteNativeLaneState::Blocked { origin_operation_id, .. })
                if origin_operation_id == operation_id
        ));
        assert!(!state.active_remote_operation_ids.contains(operation_id));
        assert_eq!(
            state
                .remote_checkout_journal
                .as_ref()
                .expect("journal")
                .entries()[0]
                .state,
            RemoteCheckoutMutationState::Armed
        );

        drop(state);
        std::fs::remove_file(storage).expect("remove storage replacement file");
    }

    #[test]
    fn invalid_typed_worker_output_blocks_lane_before_release() {
        let lane = "c:/wc-output-validation";
        let operation_id = "21234567-89ab-4def-8123-456789abcdef";
        let repository_id = "repo-output-validation";
        let identity = RepositoryIdentity {
            repository_uuid: "uuid-output-validation".to_string(),
            repository_root_url: "svn://svn.example.invalid/project".to_string(),
            working_copy_root: "C:/wc-output-validation".to_string(),
            workspace_scope_root: "C:/wc-output-validation".to_string(),
            format: 31,
        };
        let mut state = DaemonState::new();
        state
            .active_remote_operation_ids
            .insert(operation_id.to_string());
        state.remote_native_lanes.insert(
            lane.to_string(),
            RemoteNativeLaneState::Active {
                operation_id: operation_id.to_string(),
                effect: RemoteOperationEffect::ReadOnly,
                repository_id: Some(repository_id.to_string()),
                epoch: Some(1),
            },
        );

        let failure = state
            .complete_remote_svn_anonymous(
                json!(1),
                lane,
                operation_id,
                Some(repository_id),
                Some(1),
                crate::RemoteSvnAnonymousRequest::Content {
                    identity,
                    path: "README.txt".to_string(),
                    revision: "head".to_string(),
                },
                crate::RemoteSvnAnonymousOutput::Checkout(crate::RepositoryCheckoutResult {
                    working_copy_path: "C:/unexpected".to_string(),
                    revision: 1,
                }),
            )
            .expect_err("wrong output variant must fail closed");

        assert_eq!(failure.code(), "SUBVERSIONR_REMOTE_WORKER_PROTOCOL_INVALID");
        assert!(!state.active_remote_operation_ids.contains(operation_id));
        assert!(matches!(
            state.remote_native_lanes.get(lane),
            Some(RemoteNativeLaneState::Blocked { origin_operation_id, .. })
                if origin_operation_id == operation_id
        ));
        assert!(state.pending_notifications.iter().any(|notification| {
            notification["method"] == "remoteConnection/state"
                && notification["params"]["state"]["kind"] == "indeterminate"
                && notification["params"]["state"]["recovery"] == "blocked"
        }));
    }

    fn checkout_journal_test_root(label: &str) -> std::path::PathBuf {
        static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(1);
        let path = std::env::temp_dir().join(format!(
            "subversionr-state-{label}-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed),
        ));
        std::fs::create_dir_all(&path).expect("create checkout journal test root");
        path.canonicalize()
            .expect("canonical checkout journal test root")
    }
}
