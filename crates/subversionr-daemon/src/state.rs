use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    path::{Path, PathBuf},
    sync::Arc,
};

use base64::{Engine as _, engine::general_purpose::STANDARD};
use serde_json::{Value, json};
use subversionr_protocol::{
    ContentGetResponse, DiagnosticsBackendStderr, DiagnosticsGetResponse,
    DiagnosticsRepositorySummary, HistoryBlameResponse, HistoryLogResponse, InitializeParams,
    InitializeResponse, OperationReconcileHint, OperationRunResponse, OperationSummary,
    OperationWarning, PropertiesListResponse, PropertyEntry as ProtocolPropertyEntry,
    ProtocolVersion, RepositoryCheckoutResponse, RepositoryCloseResponse,
    RepositoryDiscoverResponse, RepositoryDiscoveryCandidate, RepositoryIdentity,
    RepositoryOpenResponse, StatusCoverageScope, StatusDelta, StatusEntry, StatusRefreshTarget,
    StatusSnapshot, StatusSummary, StatusSummaryDelta, WorkspaceTrustState,
    WorkspaceTrustUpdateParams, WorkspaceTrustUpdateResponse, current_platform,
    default_cache_schema,
};

use crate::remote::{
    RemoteLaunchPlan, RemoteTrustState, envelope_value, preflight_repository_urls,
    unsupported_transport,
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
use crate::{InlineRemoteWorkerSupervisor, RemoteWorkerSupervisor};

const MAX_SVN_REVNUM: u64 = 2_147_483_647;
const SVN_ADMIN_DIR_NAME: &str = ".svn";
const MAX_REPOSITORY_DISCOVERY_DEPTH: u64 = 64;

pub struct DaemonState {
    repositories: BTreeMap<String, RepositorySession>,
    next_epoch: u64,
    next_operation_id: u64,
    pending_notifications: Vec<Value>,
    remote_trust: Option<RemoteTrustState>,
    remote_worker: Arc<dyn RemoteWorkerSupervisor>,
    pending_remote_launch: Option<RemoteLaunchPlan>,
    remote_native_lanes: BTreeMap<String, RemoteNativeLaneState>,
    active_remote_operation_ids: BTreeSet<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum RemoteNativeLaneState {
    Active { operation_id: String },
    Blocked { operation_id: String },
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
            remote_native_lanes: BTreeMap::new(),
            active_remote_operation_ids: BTreeSet::new(),
        }
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
        if let Err(failure) = self
            .remote_worker
            .update_workspace_trust(params.workspace_trust == WorkspaceTrustState::Trusted)
        {
            return bridge_failure_response(request, failure);
        }
        let acknowledged_trust_epoch = trust.acknowledged_epoch();
        self.remote_trust = Some(trust);
        let bridge_info = bridge.info();
        let mut capabilities = bridge_info.capabilities();
        capabilities.remote_worker_isolation = self.remote_worker.capability_available();
        capabilities.credential_lease_settlement =
            self.remote_worker.credential_lease_settlement_available();
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
        capabilities.credential_lease_settlement =
            self.remote_worker.credential_lease_settlement_available();
        let response = DiagnosticsGetResponse {
            backend_version: env!("CARGO_PKG_VERSION").to_string(),
            bridge_version: bridge_info.bridge_version,
            libsvn_version: bridge_info.libsvn_version,
            protocol: ProtocolVersion {
                major: 1,
                minor: 33,
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
        if let Some(response) = self.begin_remote_preflight(
            request,
            &[&repository_root_url],
            &lane_key,
            bridge,
            cancellation,
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
            if let Some(response) = self.begin_remote_preflight(
                request,
                &[&repository_root_url],
                &lane_key,
                bridge,
                cancellation,
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
        if let Some(response) = self.begin_remote_preflight(
            request,
            &[&repository_root_url],
            &lane_key,
            bridge,
            cancellation,
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
        if let Some(response) = self.begin_remote_preflight(
            request,
            &[&repository_root_url],
            &lane_key,
            bridge,
            cancellation,
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
    ) -> Option<(DispatchOutcome, Value)> {
        let operation = match preflight_repository_urls(request, urls, self.remote_trust.as_ref()) {
            Ok(None) => return None,
            Ok(Some(operation)) => operation,
            Err(failure) => return Some(bridge_failure_response(request, failure)),
        };

        if !self.remote_worker.capability_available() {
            let endpoint = operation.endpoint.clone();
            let mut unavailable_auth = UnavailableAuthRequestBroker;
            return Some(
                match self.remote_worker.execute(
                    &operation.envelope,
                    operation.config,
                    lane_key,
                    cancellation,
                    &mut unavailable_auth,
                    bridge,
                    operation.deadline,
                ) {
                    Ok(()) => bridge_failure_response(request, unsupported_transport(&endpoint)),
                    Err(failure) => bridge_failure_response(request, failure),
                },
            );
        }

        let normalized_lane = absolute_path_key(&normalize_absolute_path_text(lane_key));
        if let Some(failure) =
            self.reserve_remote_lane(&normalized_lane, &operation.envelope.operation_id)
        {
            return Some(bridge_failure_response(request, failure));
        }
        self.pending_remote_launch = Some(RemoteLaunchPlan {
            request_id: request.id.clone(),
            lane_key: normalized_lane,
            operation,
        });
        Some((DispatchOutcome::Continue, Value::Null))
    }

    fn reserve_remote_lane(&mut self, lane_key: &str, operation_id: &str) -> Option<BridgeFailure> {
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
            },
        );
        None
    }

    pub(crate) fn settle_remote_launch(
        &mut self,
        lane_key: &str,
        operation_id: &str,
        recovery_blocked: bool,
    ) {
        let matches = self.remote_native_lanes.get(lane_key).is_some_and(|state| {
            matches!(
                state,
                RemoteNativeLaneState::Active { operation_id: active } if active == operation_id
            )
        });
        if !matches {
            return;
        }
        self.active_remote_operation_ids.remove(operation_id);
        if recovery_blocked {
            self.remote_native_lanes.insert(
                lane_key.to_string(),
                RemoteNativeLaneState::Blocked {
                    operation_id: operation_id.to_string(),
                },
            );
        } else {
            self.remote_native_lanes.remove(lane_key);
        }
    }

    fn native_lane_failure_for_request(&self, request: &JsonRpcRequest) -> Option<BridgeFailure> {
        if matches!(
            request.method.as_str(),
            "initialize"
                | "workspaceTrust/update"
                | "diagnostics/get"
                | "repository/close"
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
