use std::fs;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use base64::{Engine as _, engine::general_purpose::STANDARD};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use subversionr_protocol::{
    CertificateTrustRequest, CertificateTrustResponse, Credential, CredentialAttempt,
    CredentialPersistenceIntent, CredentialRequest, CredentialResponse, CredentialSettlementAck,
    CredentialSettlementOutcome, CredentialSettlementRequest, OperationFailureDiagnostics,
    RemoteFailure, RemoteOperationEnvelope,
};

use crate::remote_operation::{
    RemoteSvnAnonymousOutput, RemoteSvnAnonymousRequest, is_anonymous_identity_required_failure,
};
use crate::{
    AuthRequestBroker, BridgeApi, BridgeCancellationToken, BridgeFailure, NativeBridge,
    NeverCancelled, RemoteConfigPlan, RemoteConfigScheme, RemoteConfigServerAuth,
    RemoteNativeBridge, UnavailableAuthRequestBroker,
};

const PRIVATE_WORKER_PROTOCOL_VERSION: u16 = 3;
const PRIVATE_REMOTE_WORKER_MODE: &str = "--subversionr-private-remote-worker-v1";
const MAX_REQUEST_FRAME_BYTES: usize = 64 * 1024;
const MAX_RESPONSE_FRAME_BYTES: usize = 64 * 1024;
const MAX_OPERATION_RESULT_BYTES: usize = 32 * 1024 * 1024;
const OPERATION_RESULT_CHUNK_BYTES: usize = 32 * 1024;
const CLEANUP_TIMEOUT: Duration = Duration::from_secs(5);
const SUPERVISION_POLL: Duration = Duration::from_millis(5);
const WORKER_TERMINATION_CODE: u32 = 0x5356_5201;

pub trait RemoteWorkerSupervisor: Send + Sync {
    fn execute(
        &self,
        envelope: &RemoteOperationEnvelope,
        plan: RemoteConfigPlan,
        lane_key: &str,
        effect: RemoteOperationEffect,
        cancellation: &dyn BridgeCancellationToken,
        auth: &mut dyn AuthRequestBroker,
        bridge: &dyn BridgeApi,
        deadline: Instant,
    ) -> RemoteWorkerSettlement;

    fn execute_svn_anonymous(
        &self,
        _envelope: &RemoteOperationEnvelope,
        _plan: RemoteConfigPlan,
        _lane_key: &str,
        effect: RemoteOperationEffect,
        _request: RemoteSvnAnonymousRequest,
        _cancellation: &dyn BridgeCancellationToken,
        _deadline: Instant,
    ) -> RemoteWorkerSettlement {
        RemoteWorkerSettlement::pre_launch(effect, Err(svn_anonymous_unavailable()))
    }

    fn terminate_active(&self) -> Result<(), BridgeFailure>;

    fn update_workspace_trust(&self, _trusted: bool) -> Result<(), BridgeFailure> {
        Ok(())
    }

    fn disconnect(&self) -> Result<(), BridgeFailure>;

    fn capability_available(&self) -> bool;

    fn credential_lease_settlement_available(&self) -> bool {
        false
    }

    fn svn_anonymous_available(&self) -> bool {
        false
    }

    fn auth_wait_cancelled(&self) -> bool {
        false
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RemoteOperationEffect {
    ReadOnly,
    Mutation,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WorkerTerminationDisposition {
    NotRequired,
    Settled,
    Blocked,
}

#[derive(Debug, Clone, PartialEq)]
pub struct RemoteWorkerSettlement {
    pub result: Result<(), BridgeFailure>,
    pub operation_output: Option<RemoteSvnAnonymousOutput>,
    pub remote_failure: Option<RemoteFailure>,
    pub effect: RemoteOperationEffect,
    pub worker_was_resumed: bool,
    pub execution_origin_known: bool,
    pub termination: WorkerTerminationDisposition,
    pub job_descendants_zero: bool,
    pub temp_root_removed: bool,
}

impl RemoteWorkerSettlement {
    pub(crate) fn pre_launch(
        effect: RemoteOperationEffect,
        result: Result<(), BridgeFailure>,
    ) -> Self {
        let remote_failure = result
            .as_ref()
            .err()
            .map(crate::remote::classify_remote_failure);
        Self {
            result,
            operation_output: None,
            remote_failure,
            effect,
            worker_was_resumed: false,
            execution_origin_known: true,
            termination: WorkerTerminationDisposition::NotRequired,
            job_descendants_zero: true,
            temp_root_removed: true,
        }
    }

    pub fn cleanup_safe(&self) -> bool {
        self.job_descendants_zero && self.temp_root_removed
    }

    pub fn may_have_mutated(&self) -> bool {
        self.effect == RemoteOperationEffect::Mutation
            && (self.worker_was_resumed || !self.execution_origin_known)
            && !self.failure_proves_no_mutation()
    }

    fn failure_proves_no_mutation(&self) -> bool {
        self.execution_origin_known
            && self.result.as_ref().err().is_some_and(|failure| {
                matches!(
                    failure.code(),
                    "SUBVERSIONR_REMOTE_ORIGIN_MISMATCH" | "SUBVERSIONR_REMOTE_AUTH_UNSUPPORTED"
                ) || is_anonymous_identity_required_failure(failure)
            })
    }
}

#[doc(hidden)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RemoteCredentialProbeScenario {
    FirstSave,
    FirstNextSave,
    Unused,
    Cancelled,
    TimedOut,
}

impl RemoteCredentialProbeScenario {
    fn raw(self) -> u32 {
        match self {
            Self::FirstSave => 1,
            Self::FirstNextSave => 2,
            Self::Unused => 3,
            Self::Cancelled => 4,
            Self::TimedOut => 5,
        }
    }
}

#[derive(Debug, Default, Clone, Copy)]
pub struct InlineRemoteWorkerSupervisor;

impl RemoteWorkerSupervisor for InlineRemoteWorkerSupervisor {
    fn execute(
        &self,
        _envelope: &RemoteOperationEnvelope,
        plan: RemoteConfigPlan,
        _lane_key: &str,
        effect: RemoteOperationEffect,
        cancellation: &dyn BridgeCancellationToken,
        _auth: &mut dyn AuthRequestBroker,
        bridge: &dyn BridgeApi,
        deadline: Instant,
    ) -> RemoteWorkerSettlement {
        if cancellation.is_cancelled() || Instant::now() >= deadline {
            return RemoteWorkerSettlement::pre_launch(effect, Err(cancelled_failure()));
        }
        RemoteWorkerSettlement::pre_launch(effect, bridge.create_remote_context_foundation(plan))
    }

    fn disconnect(&self) -> Result<(), BridgeFailure> {
        Ok(())
    }

    fn terminate_active(&self) -> Result<(), BridgeFailure> {
        Ok(())
    }

    fn capability_available(&self) -> bool {
        false
    }
}

#[derive(Debug)]
pub struct ProcessRemoteWorkerSupervisor {
    worker_executable: PathBuf,
    bridge_path: PathBuf,
    temp_base: PathBuf,
    disconnected: AtomicBool,
    credential_contract_available: bool,
    svn_anonymous_contract_available: bool,
    active: platform::ActiveWorkerRegistry,
}

impl ProcessRemoteWorkerSupervisor {
    pub fn new(
        worker_executable: PathBuf,
        bridge_path: PathBuf,
        temp_base: PathBuf,
    ) -> Result<Self, BridgeFailure> {
        let worker_executable = verified_file(&worker_executable, "workerExecutable")?;
        let bridge_path = verified_file(&bridge_path, "bridgePath")?;
        let credential_contract_available =
            RemoteNativeBridge::load_foundation(&bridge_path).is_ok();
        let svn_anonymous_contract_available = NativeBridge::load(&bridge_path).is_ok();
        if !temp_base.is_absolute() {
            return Err(invalid_worker_field("tempBase"));
        }
        fs::create_dir_all(&temp_base).map_err(|_| invalid_worker_field("tempBase"))?;
        let temp_base = verified_directory(&temp_base, "tempBase")?;
        Ok(Self {
            worker_executable,
            bridge_path,
            temp_base,
            disconnected: AtomicBool::new(false),
            credential_contract_available,
            svn_anonymous_contract_available,
            active: platform::ActiveWorkerRegistry::default(),
        })
    }

    pub fn execute_with_disconnect(
        &self,
        envelope: &RemoteOperationEnvelope,
        plan: RemoteConfigPlan,
        lane_key: &str,
        effect: RemoteOperationEffect,
        cancellation: &dyn BridgeCancellationToken,
        auth: &mut dyn AuthRequestBroker,
        parent_disconnected: &AtomicBool,
        deadline: Instant,
    ) -> RemoteWorkerSettlement {
        if self.disconnected.load(Ordering::Acquire) || parent_disconnected.load(Ordering::Acquire)
        {
            return RemoteWorkerSettlement::pre_launch(effect, Err(disconnected_failure()));
        }
        if plan.timeout_ms != envelope.timeout_ms {
            return RemoteWorkerSettlement::pre_launch(effect, Err(worker_protocol_failure()));
        }
        if Instant::now() >= deadline {
            return RemoteWorkerSettlement::pre_launch(effect, Err(timed_out_failure()));
        }
        if let Err(failure) = validate_request_parts(envelope, plan, lane_key) {
            return RemoteWorkerSettlement::pre_launch(effect, Err(failure));
        }
        platform::execute_worker(
            &self.worker_executable,
            &self.bridge_path,
            &self.temp_base,
            envelope,
            plan,
            cancellation,
            auth,
            &self.disconnected,
            parent_disconnected,
            &self.active,
            deadline,
            WorkerExecution::Foundation,
            effect,
        )
    }

    #[doc(hidden)]
    pub fn execute_credential_probe(
        &self,
        envelope: &RemoteOperationEnvelope,
        plan: RemoteConfigPlan,
        lane_key: &str,
        cancellation: &dyn BridgeCancellationToken,
        auth: &mut dyn AuthRequestBroker,
        deadline: Instant,
        scenario: RemoteCredentialProbeScenario,
    ) -> Result<(), BridgeFailure> {
        if self.disconnected.load(Ordering::Acquire) {
            return Err(disconnected_failure());
        }
        if matches!(plan.server_auth, crate::RemoteConfigServerAuth::Anonymous)
            || plan.timeout_ms != envelope.timeout_ms
            || Instant::now() >= deadline
        {
            return Err(worker_protocol_failure());
        }
        validate_request_parts(envelope, plan, lane_key)?;
        let parent_connected = AtomicBool::new(false);
        let settlement = platform::execute_worker(
            &self.worker_executable,
            &self.bridge_path,
            &self.temp_base,
            envelope,
            plan,
            cancellation,
            auth,
            &self.disconnected,
            &parent_connected,
            &self.active,
            deadline,
            WorkerExecution::CredentialProbe { scenario },
            RemoteOperationEffect::ReadOnly,
        );
        settlement.result
    }

    pub fn active_worker_count(&self) -> usize {
        self.active.count()
    }
}

impl RemoteWorkerSupervisor for ProcessRemoteWorkerSupervisor {
    fn execute(
        &self,
        envelope: &RemoteOperationEnvelope,
        plan: RemoteConfigPlan,
        lane_key: &str,
        effect: RemoteOperationEffect,
        cancellation: &dyn BridgeCancellationToken,
        auth: &mut dyn AuthRequestBroker,
        _bridge: &dyn BridgeApi,
        deadline: Instant,
    ) -> RemoteWorkerSettlement {
        self.execute_with_disconnect(
            envelope,
            plan,
            lane_key,
            effect,
            cancellation,
            auth,
            &self.disconnected,
            deadline,
        )
    }

    fn execute_svn_anonymous(
        &self,
        envelope: &RemoteOperationEnvelope,
        plan: RemoteConfigPlan,
        lane_key: &str,
        effect: RemoteOperationEffect,
        request: RemoteSvnAnonymousRequest,
        cancellation: &dyn BridgeCancellationToken,
        deadline: Instant,
    ) -> RemoteWorkerSettlement {
        if !self.svn_anonymous_contract_available
            || plan.scheme != RemoteConfigScheme::Svn
            || plan.server_auth != RemoteConfigServerAuth::Anonymous
        {
            return RemoteWorkerSettlement::pre_launch(effect, Err(svn_anonymous_unavailable()));
        }
        let mut unavailable_auth = UnavailableAuthRequestBroker;
        if self.disconnected.load(Ordering::Acquire)
            || plan.timeout_ms != envelope.timeout_ms
            || Instant::now() >= deadline
        {
            return RemoteWorkerSettlement::pre_launch(effect, Err(worker_protocol_failure()));
        }
        if let Err(failure) = validate_request_parts(envelope, plan, lane_key) {
            return RemoteWorkerSettlement::pre_launch(effect, Err(failure));
        }
        platform::execute_worker(
            &self.worker_executable,
            &self.bridge_path,
            &self.temp_base,
            envelope,
            plan,
            cancellation,
            &mut unavailable_auth,
            &self.disconnected,
            &self.disconnected,
            &self.active,
            deadline,
            WorkerExecution::SvnAnonymous { request },
            effect,
        )
    }

    fn disconnect(&self) -> Result<(), BridgeFailure> {
        self.disconnected.store(true, Ordering::Release);
        self.terminate_active()
    }

    fn terminate_active(&self) -> Result<(), BridgeFailure> {
        self.active.block_launches_and_terminate_all();
        self.active.wait_for_zero(CLEANUP_TIMEOUT)
    }

    fn update_workspace_trust(&self, trusted: bool) -> Result<(), BridgeFailure> {
        if trusted {
            self.active.allow_launches(&self.disconnected)
        } else {
            self.terminate_active()
        }
    }

    fn capability_available(&self) -> bool {
        cfg!(windows) && !self.disconnected.load(Ordering::Acquire)
    }

    fn credential_lease_settlement_available(&self) -> bool {
        self.capability_available() && self.credential_contract_available
    }

    fn svn_anonymous_available(&self) -> bool {
        self.capability_available() && self.svn_anonymous_contract_available
    }

    fn auth_wait_cancelled(&self) -> bool {
        self.disconnected.load(Ordering::Acquire) || !self.active.launches_allowed()
    }
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct WorkerRequest {
    protocol_version: u16,
    request_id: String,
    bridge_path: String,
    operation_temp_root: String,
    envelope: RemoteOperationEnvelope,
    plan: RemoteConfigPlan,
    execution: WorkerExecution,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
enum WorkerExecution {
    Foundation,
    CredentialProbe {
        scenario: RemoteCredentialProbeScenario,
    },
    SvnAnonymous {
        request: RemoteSvnAnonymousRequest,
    },
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
enum ParentWorkerFrame {
    Start {
        protocol_version: u16,
        request: WorkerRequest,
    },
    CredentialResponse {
        protocol_version: u16,
        operation_id: String,
        sequence: u32,
        response: CredentialResponse,
    },
    CredentialSettlementAck {
        protocol_version: u16,
        operation_id: String,
        sequence: u32,
        ack: CredentialSettlementAck,
    },
    CredentialSettlementFailure {
        protocol_version: u16,
        operation_id: String,
        sequence: u32,
        failure: WireFailure,
    },
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
enum ChildWorkerFrame {
    CredentialRequest {
        protocol_version: u16,
        operation_id: String,
        sequence: u32,
        request: CredentialRequest,
    },
    CredentialSettlement {
        protocol_version: u16,
        operation_id: String,
        sequence: u32,
        request: CredentialSettlementRequest,
    },
    ResultChunk {
        protocol_version: u16,
        operation_id: String,
        sequence: u32,
        data_base64: String,
    },
    Final {
        protocol_version: u16,
        operation_id: String,
        response: WorkerResponse,
    },
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct WorkerResponse {
    protocol_version: u16,
    request_id: String,
    operation_id: String,
    result: WorkerResult,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "outcome", rename_all = "camelCase", deny_unknown_fields)]
enum WorkerResult {
    Success {
        operation_result: Option<WorkerOperationResultDescriptor>,
    },
    Failure {
        failure: WireFailure,
    },
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct WorkerOperationResultDescriptor {
    byte_count: u32,
    chunk_count: u32,
    sha256: String,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct WireFailure {
    code: String,
    category: String,
    message_key: String,
    args: Value,
    retryable: bool,
    diagnostics: Option<OperationFailureDiagnostics>,
}

impl WireFailure {
    fn from_bridge(failure: BridgeFailure) -> Self {
        Self {
            code: failure.code,
            category: failure.category,
            message_key: failure.message_key,
            args: failure.args,
            retryable: failure.retryable,
            diagnostics: failure.diagnostics.map(|diagnostics| *diagnostics),
        }
    }
}

fn validate_credential_settlement_wire_failure(
    failure: WireFailure,
) -> Result<BridgeFailure, BridgeFailure> {
    if failure.retryable || failure.diagnostics.is_some() {
        return Err(worker_protocol_failure());
    }
    let (category, message_key, includes_outcome) = match failure.code.as_str() {
        "SUBVERSIONR_CREDENTIAL_UNTRUSTED_WORKSPACE" => (
            "lifecycle",
            "error.auth.credentialUntrustedWorkspace",
            false,
        ),
        "SUBVERSIONR_CREDENTIAL_TIMEOUT" => ("auth", "error.auth.credentialTimeout", true),
        "SUBVERSIONR_CREDENTIAL_LEASE_UNKNOWN" => {
            ("auth", "error.auth.credentialLeaseUnknown", true)
        }
        "SUBVERSIONR_CREDENTIAL_LEASE_FOREIGN" => {
            ("auth", "error.auth.credentialLeaseForeign", true)
        }
        "SUBVERSIONR_CREDENTIAL_LEASE_EXPIRED" => {
            ("auth", "error.auth.credentialLeaseExpired", true)
        }
        "SUBVERSIONR_CREDENTIAL_SETTLEMENT_CONFLICT" => {
            ("auth", "error.auth.credentialSettlementConflict", true)
        }
        _ => return Err(worker_protocol_failure()),
    };
    if failure.category != category || failure.message_key != message_key {
        return Err(worker_protocol_failure());
    }
    let Some(args) = failure.args.as_object() else {
        return Err(worker_protocol_failure());
    };
    let expected_len = if includes_outcome { 3 } else { 2 };
    if args.len() != expected_len {
        return Err(worker_protocol_failure());
    }
    let Some(operation_hash) = args.get("operationHash").and_then(Value::as_str) else {
        return Err(worker_protocol_failure());
    };
    let Some(lease_hash) = args.get("leaseHash").and_then(Value::as_str) else {
        return Err(worker_protocol_failure());
    };
    if !is_lowercase_sha256(operation_hash) || !is_lowercase_sha256(lease_hash) {
        return Err(worker_protocol_failure());
    }
    let safe_args = if includes_outcome {
        let Some(outcome) = args.get("outcome").and_then(Value::as_str) else {
            return Err(worker_protocol_failure());
        };
        if !matches!(
            outcome,
            "accepted" | "rejected" | "unused" | "cancelled" | "timedOut"
        ) {
            return Err(worker_protocol_failure());
        }
        json!({
            "operationHash": operation_hash,
            "leaseHash": lease_hash,
            "outcome": outcome,
        })
    } else {
        json!({
            "operationHash": operation_hash,
            "leaseHash": lease_hash,
        })
    };
    Ok(BridgeFailure::new(
        failure.code,
        category,
        message_key,
        safe_args,
        false,
    ))
}

fn is_lowercase_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

pub fn run_remote_worker(mut reader: impl Read, mut writer: impl Write) -> ExitCode {
    let request = match read_frame(&mut reader, MAX_REQUEST_FRAME_BYTES)
        .and_then(|bytes| decode_parent_frame(&bytes))
    {
        Ok(ParentWorkerFrame::Start {
            protocol_version,
            request,
        }) if protocol_version == PRIVATE_WORKER_PROTOCOL_VERSION => request,
        Err(_) => return ExitCode::from(3),
        _ => return ExitCode::from(3),
    };
    let operation_id = request.envelope.operation_id.clone();
    let mut auth = WorkerControlAuthBroker {
        operation_id: operation_id.clone(),
        sequence: 0,
        reader: &mut reader,
        writer: &mut writer,
    };
    let executed = execute_worker_request(request, &mut auth);
    drop(auth);
    for (sequence, data_base64) in executed.result_chunks.into_iter().enumerate() {
        let Ok(sequence) = u32::try_from(sequence) else {
            return ExitCode::from(4);
        };
        let chunk_frame = ChildWorkerFrame::ResultChunk {
            protocol_version: PRIVATE_WORKER_PROTOCOL_VERSION,
            operation_id: operation_id.clone(),
            sequence,
            data_base64,
        };
        if encode_child_frame(&chunk_frame)
            .and_then(|bytes| write_frame(&mut writer, &bytes, MAX_RESPONSE_FRAME_BYTES))
            .and_then(|()| writer.flush())
            .is_err()
        {
            return ExitCode::from(4);
        }
    }
    let final_frame = ChildWorkerFrame::Final {
        protocol_version: PRIVATE_WORKER_PROTOCOL_VERSION,
        operation_id,
        response: executed.response,
    };
    match encode_child_frame(&final_frame)
        .and_then(|bytes| write_frame(&mut writer, &bytes, MAX_RESPONSE_FRAME_BYTES))
        .and_then(|()| writer.flush())
    {
        Ok(()) => ExitCode::SUCCESS,
        Err(_) => ExitCode::from(4),
    }
}

pub fn remote_worker_control_channel_is_private() -> bool {
    platform::worker_control_channel_is_private()
}

#[doc(hidden)]
pub fn run_private_credential_provider_probe(
    worker_executable: PathBuf,
    bridge_path: PathBuf,
    temp_base: PathBuf,
    mut writer: impl Write,
) -> ExitCode {
    let result =
        execute_private_credential_provider_probe(worker_executable, bridge_path, temp_base);
    let (report, exit_code) = match result {
        Ok(scenarios) => (
            json!({
                "schema": "subversionr.private.credential-provider-probe.v1",
                "status": "passed",
                "networkAccess": false,
                "scenarios": scenarios,
            }),
            ExitCode::SUCCESS,
        ),
        Err(failure) => (
            json!({
                "schema": "subversionr.private.credential-provider-probe.v1",
                "status": "failed",
                "code": failure.code(),
            }),
            ExitCode::from(1),
        ),
    };
    if serde_json::to_writer(&mut writer, &report).is_err()
        || writer.write_all(b"\n").is_err()
        || writer.flush().is_err()
    {
        return ExitCode::from(1);
    }
    exit_code
}

fn execute_private_credential_provider_probe(
    worker_executable: PathBuf,
    bridge_path: PathBuf,
    temp_base: PathBuf,
) -> Result<Vec<Value>, BridgeFailure> {
    if temp_base.exists() {
        return Err(invalid_worker_field("credentialProbeTempBase"));
    }
    let supervisor =
        ProcessRemoteWorkerSupervisor::new(worker_executable, bridge_path, temp_base.clone())?;
    supervisor.update_workspace_trust(true)?;
    if !supervisor.credential_lease_settlement_available() {
        return Err(worker_start_failure());
    }
    let scenarios = [
        (
            RemoteCredentialProbeScenario::FirstSave,
            vec!["request:initial", "settle:accepted"],
        ),
        (
            RemoteCredentialProbeScenario::FirstNextSave,
            vec![
                "request:initial",
                "settle:rejected",
                "request:retryAfterRejected",
                "settle:accepted",
            ],
        ),
        (
            RemoteCredentialProbeScenario::Unused,
            vec!["request:initial", "settle:unused"],
        ),
        (
            RemoteCredentialProbeScenario::Cancelled,
            vec!["request:initial", "settle:cancelled"],
        ),
        (
            RemoteCredentialProbeScenario::TimedOut,
            vec!["request:initial", "settle:timedOut"],
        ),
    ];
    let mut reports = Vec::with_capacity(scenarios.len());
    for (index, (scenario, expected)) in scenarios.into_iter().enumerate() {
        let operation_id = format!("12700000-0000-4000-8000-{index:012}");
        let envelope = private_probe_envelope(&operation_id)?;
        let mut broker = PrivateCredentialProbeBroker::default();
        supervisor.execute_credential_probe(
            &envelope,
            RemoteConfigPlan {
                scheme: RemoteConfigScheme::Https,
                server_auth: RemoteConfigServerAuth::Basic,
                timeout_ms: envelope.timeout_ms,
                trust_windows_roots: true,
            },
            "private-credential-provider-probe",
            &NeverCancelled,
            &mut broker,
            Instant::now() + Duration::from_secs(10),
            scenario,
        )?;
        if broker.events != expected || supervisor.active_worker_count() != 0 {
            return Err(worker_protocol_failure());
        }
        reports.push(json!({ "scenario": scenario, "events": broker.events }));
    }
    supervisor.disconnect()?;
    if fs::read_dir(&temp_base)
        .map_err(|_| worker_start_failure())?
        .next()
        .is_some()
    {
        return Err(cleanup_blocked_failure());
    }
    fs::remove_dir(&temp_base).map_err(|_| cleanup_blocked_failure())?;
    Ok(reports)
}

#[derive(Default)]
struct PrivateCredentialProbeBroker {
    events: Vec<&'static str>,
    leases: u32,
}

impl AuthRequestBroker for PrivateCredentialProbeBroker {
    fn native_credential_callback_policy(&self) -> crate::NativeCredentialCallbackPolicy {
        crate::NativeCredentialCallbackPolicy::RemoteWorkerRequired
    }

    fn request_credential(
        &mut self,
        request: CredentialRequest,
    ) -> Result<CredentialResponse, BridgeFailure> {
        match &request.attempt {
            CredentialAttempt::Initial => self.events.push("request:initial"),
            CredentialAttempt::RetryAfterRejected { previous_lease_id }
                if previous_lease_id == "12700000-0000-4000-8001-000000000001" =>
            {
                self.events.push("request:retryAfterRejected");
            }
            CredentialAttempt::RetryAfterRejected { .. } => return Err(worker_protocol_failure()),
        }
        self.leases = self
            .leases
            .checked_add(1)
            .ok_or_else(worker_protocol_failure)?;
        Ok(CredentialResponse::Provide {
            request_id: request.request_id,
            operation_id: request.operation_id,
            lease_id: format!("12700000-0000-4000-8001-{:012}", self.leases),
            credential: Credential {
                username: "packaged-probe".to_string(),
                secret: "packaged-probe-secret".to_string(),
            },
            persistence_intent: CredentialPersistenceIntent::Session,
        })
    }

    fn settle_credential(
        &mut self,
        request: CredentialSettlementRequest,
    ) -> Result<CredentialSettlementAck, BridgeFailure> {
        self.events.push(match request.outcome {
            CredentialSettlementOutcome::Accepted => "settle:accepted",
            CredentialSettlementOutcome::Rejected => "settle:rejected",
            CredentialSettlementOutcome::Unused => "settle:unused",
            CredentialSettlementOutcome::Cancelled => "settle:cancelled",
            CredentialSettlementOutcome::TimedOut => "settle:timedOut",
        });
        Ok(CredentialSettlementAck {
            request_id: request.request_id,
            operation_id: request.operation_id,
            lease_id: request.lease_id,
            outcome: request.outcome,
        })
    }

    fn request_certificate_trust(
        &mut self,
        _request: CertificateTrustRequest,
    ) -> Result<CertificateTrustResponse, BridgeFailure> {
        Err(worker_protocol_failure())
    }
}

fn private_probe_envelope(operation_id: &str) -> Result<RemoteOperationEnvelope, BridgeFailure> {
    serde_json::from_value(json!({
        "version": 1,
        "operationId": operation_id,
        "intent": "foreground",
        "interaction": "allowed",
        "timeoutMs": 10000,
        "workspaceTrust": "trusted",
        "trustEpoch": 1,
        "profile": {
            "schema": "subversionr.remote-profile.v1",
            "profileId": "packaged-native-credential-provider",
            "authority": {"scheme":"https","canonicalHost":"svn.example.invalid","effectivePort":443},
            "serverAuth": "basic",
            "serverAccount": {"mode":"fixed","username":"packaged-probe"},
            "serverCredentialPersistence": "secretStorage",
            "tls": {"trust":"windowsRootsThenBroker"},
            "proxy": "none",
            "ssh": "none",
            "redirectPolicy": "rejectAll"
        },
        "expectedOrigin": {"scheme":"https","canonicalHost":"svn.example.invalid","effectivePort":443}
    }))
    .map_err(|_| worker_protocol_failure())
}

struct ExecutedWorkerRequest {
    response: WorkerResponse,
    result_chunks: Vec<String>,
}

fn execute_worker_request(
    request: WorkerRequest,
    auth: &mut dyn AuthRequestBroker,
) -> ExecutedWorkerRequest {
    let request_id = request.request_id.clone();
    let operation_id = request.envelope.operation_id.clone();
    let result: Result<Option<RemoteSvnAnonymousOutput>, BridgeFailure> =
        validate_worker_request(&request).and_then(|bridge_path| {
            let deadline = worker_deadline(&request)?;
            match request.execution {
                WorkerExecution::Foundation => {
                    let bridge = RemoteNativeBridge::load_foundation(&bridge_path)
                        .map_err(|_| worker_start_failure())?;
                    bridge
                        .create_remote_context_foundation(
                            request.plan,
                            &request.envelope,
                            auth,
                            deadline,
                        )
                        .map(|()| None)
                }
                WorkerExecution::CredentialProbe { scenario } => {
                    let bridge = RemoteNativeBridge::load_foundation(&bridge_path)
                        .map_err(|_| worker_start_failure())?;
                    bridge
                        .probe_remote_credentials(&request.envelope, auth, deadline, scenario.raw())
                        .map(|()| None)
                }
                WorkerExecution::SvnAnonymous { request: operation } => {
                    let bridge =
                        NativeBridge::load(&bridge_path).map_err(|_| worker_start_failure())?;
                    operation
                        .execute(&bridge, &request.envelope.expected_origin, &NeverCancelled)
                        .map(Some)
                }
            }
        });
    let mut result_chunks = Vec::new();
    let result = match result {
        Ok(None) => WorkerResult::Success {
            operation_result: None,
        },
        Ok(Some(output)) => match encode_operation_result(output) {
            Ok((descriptor, chunks)) => {
                result_chunks = chunks;
                WorkerResult::Success {
                    operation_result: Some(descriptor),
                }
            }
            Err(failure) => WorkerResult::Failure {
                failure: WireFailure::from_bridge(failure),
            },
        },
        Err(failure) => WorkerResult::Failure {
            failure: WireFailure::from_bridge(failure),
        },
    };
    ExecutedWorkerRequest {
        response: WorkerResponse {
            protocol_version: PRIVATE_WORKER_PROTOCOL_VERSION,
            request_id,
            operation_id,
            result,
        },
        result_chunks,
    }
}

fn encode_operation_result(
    output: RemoteSvnAnonymousOutput,
) -> Result<(WorkerOperationResultDescriptor, Vec<String>), BridgeFailure> {
    let bytes = serde_json::to_vec(&output).map_err(|_| worker_protocol_failure())?;
    if bytes.is_empty() || bytes.len() > MAX_OPERATION_RESULT_BYTES {
        return Err(worker_protocol_failure());
    }
    let byte_count = u32::try_from(bytes.len()).map_err(|_| worker_protocol_failure())?;
    let chunks = bytes
        .chunks(OPERATION_RESULT_CHUNK_BYTES)
        .map(|chunk| STANDARD.encode(chunk))
        .collect::<Vec<_>>();
    let chunk_count = u32::try_from(chunks.len()).map_err(|_| worker_protocol_failure())?;
    Ok((
        WorkerOperationResultDescriptor {
            byte_count,
            chunk_count,
            sha256: format!("{:x}", Sha256::digest(&bytes)),
        },
        chunks,
    ))
}

fn worker_deadline(request: &WorkerRequest) -> Result<Instant, BridgeFailure> {
    Instant::now()
        .checked_add(Duration::from_millis(request.plan.timeout_ms))
        .ok_or_else(worker_protocol_failure)
}

#[cfg(test)]
fn decode_request(bytes: &[u8]) -> io::Result<WorkerRequest> {
    serde_json::from_slice(bytes)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid worker request"))
}

fn decode_parent_frame(bytes: &[u8]) -> io::Result<ParentWorkerFrame> {
    serde_json::from_slice(bytes)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid worker parent frame"))
}

fn encode_child_frame(frame: &ChildWorkerFrame) -> io::Result<Vec<u8>> {
    serde_json::to_vec(frame)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid worker child frame"))
}

struct WorkerControlAuthBroker<'a, R, W> {
    operation_id: String,
    sequence: u32,
    reader: &'a mut R,
    writer: &'a mut W,
}

impl<R: Read, W: Write> WorkerControlAuthBroker<'_, R, W> {
    fn next_sequence(&mut self) -> Result<u32, BridgeFailure> {
        self.sequence = self
            .sequence
            .checked_add(1)
            .ok_or_else(worker_protocol_failure)?;
        Ok(self.sequence)
    }

    fn send_and_receive(
        &mut self,
        frame: ChildWorkerFrame,
    ) -> Result<ParentWorkerFrame, BridgeFailure> {
        let bytes = encode_child_frame(&frame).map_err(|_| worker_protocol_failure())?;
        write_frame(self.writer, &bytes, MAX_RESPONSE_FRAME_BYTES)
            .and_then(|()| self.writer.flush())
            .map_err(|_| worker_protocol_failure())?;
        let bytes = read_frame(self.reader, MAX_REQUEST_FRAME_BYTES)
            .map_err(|_| worker_protocol_failure())?;
        decode_parent_frame(&bytes).map_err(|_| worker_protocol_failure())
    }
}

impl<R: Read, W: Write> AuthRequestBroker for WorkerControlAuthBroker<'_, R, W> {
    fn native_credential_callback_policy(&self) -> crate::NativeCredentialCallbackPolicy {
        crate::NativeCredentialCallbackPolicy::RemoteWorkerRequired
    }

    fn request_credential(
        &mut self,
        request: CredentialRequest,
    ) -> Result<CredentialResponse, BridgeFailure> {
        if request.operation_id != self.operation_id {
            return Err(worker_protocol_failure());
        }
        let sequence = self.next_sequence()?;
        let frame = ChildWorkerFrame::CredentialRequest {
            protocol_version: PRIVATE_WORKER_PROTOCOL_VERSION,
            operation_id: self.operation_id.clone(),
            sequence,
            request,
        };
        match self.send_and_receive(frame)? {
            ParentWorkerFrame::CredentialResponse {
                protocol_version,
                operation_id,
                sequence: response_sequence,
                response,
            } if protocol_version == PRIVATE_WORKER_PROTOCOL_VERSION
                && operation_id == self.operation_id
                && response_sequence == sequence =>
            {
                Ok(response)
            }
            _ => Err(worker_protocol_failure()),
        }
    }

    fn settle_credential(
        &mut self,
        request: CredentialSettlementRequest,
    ) -> Result<CredentialSettlementAck, BridgeFailure> {
        if request.operation_id != self.operation_id {
            return Err(worker_protocol_failure());
        }
        let sequence = self.next_sequence()?;
        let frame = ChildWorkerFrame::CredentialSettlement {
            protocol_version: PRIVATE_WORKER_PROTOCOL_VERSION,
            operation_id: self.operation_id.clone(),
            sequence,
            request,
        };
        match self.send_and_receive(frame)? {
            ParentWorkerFrame::CredentialSettlementAck {
                protocol_version,
                operation_id,
                sequence: response_sequence,
                ack,
            } if protocol_version == PRIVATE_WORKER_PROTOCOL_VERSION
                && operation_id == self.operation_id
                && response_sequence == sequence =>
            {
                Ok(ack)
            }
            ParentWorkerFrame::CredentialSettlementFailure {
                protocol_version,
                operation_id,
                sequence: response_sequence,
                failure,
            } if protocol_version == PRIVATE_WORKER_PROTOCOL_VERSION
                && operation_id == self.operation_id
                && response_sequence == sequence =>
            {
                Err(validate_credential_settlement_wire_failure(failure)?)
            }
            _ => Err(worker_protocol_failure()),
        }
    }

    fn request_certificate_trust(
        &mut self,
        _request: CertificateTrustRequest,
    ) -> Result<CertificateTrustResponse, BridgeFailure> {
        Err(worker_protocol_failure())
    }
}

fn validate_worker_request(request: &WorkerRequest) -> Result<PathBuf, BridgeFailure> {
    if request.protocol_version != PRIVATE_WORKER_PROTOCOL_VERSION
        || request.request_id != request.envelope.operation_id
    {
        return Err(worker_protocol_failure());
    }
    validate_request_parts(&request.envelope, request.plan, "worker")?;
    let bridge_path = verified_file(Path::new(&request.bridge_path), "bridgePath")?;
    let operation_temp_root = Path::new(&request.operation_temp_root);
    verified_directory(operation_temp_root, "operationTempRoot")?;
    let expected_temp_name = format!("subversionr-remote-{}", request.envelope.operation_id);
    if operation_temp_root
        .file_name()
        .and_then(|name| name.to_str())
        != Some(expected_temp_name.as_str())
    {
        return Err(invalid_worker_field("operationTempRoot"));
    }
    Ok(bridge_path)
}

fn validate_request_parts(
    envelope: &RemoteOperationEnvelope,
    plan: RemoteConfigPlan,
    lane_key: &str,
) -> Result<(), BridgeFailure> {
    if lane_key.is_empty() || lane_key.len() > 4096 {
        return Err(worker_protocol_failure());
    }
    crate::remote::validate_worker_envelope_plan(envelope, plan)
        .map_err(|_| worker_protocol_failure())
}

fn verified_file(path: &Path, field: &str) -> Result<PathBuf, BridgeFailure> {
    if !path.is_absolute() || !path.is_file() {
        return Err(invalid_worker_field(field));
    }
    path.canonicalize().map_err(|_| invalid_worker_field(field))
}

fn verified_directory(path: &Path, field: &str) -> Result<PathBuf, BridgeFailure> {
    if !path.is_absolute() || !path.is_dir() {
        return Err(invalid_worker_field(field));
    }
    path.canonicalize().map_err(|_| invalid_worker_field(field))
}

fn read_frame(reader: &mut impl Read, limit: usize) -> io::Result<Vec<u8>> {
    let mut header = [0u8; 4];
    reader.read_exact(&mut header)?;
    let length = u32::from_le_bytes(header) as usize;
    if length == 0 || length > limit {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "worker frame exceeds bound",
        ));
    }
    let mut bytes = vec![0u8; length];
    reader.read_exact(&mut bytes)?;
    Ok(bytes)
}

fn write_frame(writer: &mut impl Write, bytes: &[u8], limit: usize) -> io::Result<()> {
    if bytes.is_empty() || bytes.len() > limit || bytes.len() > u32::MAX as usize {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "worker frame exceeds bound",
        ));
    }
    writer.write_all(&(bytes.len() as u32).to_le_bytes())?;
    writer.write_all(bytes)?;
    writer.flush()
}

fn worker_protocol_failure() -> BridgeFailure {
    BridgeFailure::new(
        "SUBVERSIONR_REMOTE_WORKER_PROTOCOL_INVALID",
        "protocol",
        "error.remote.workerProtocolInvalid",
        json!({}),
        false,
    )
}

fn svn_anonymous_unavailable() -> BridgeFailure {
    BridgeFailure::new(
        "SUBVERSIONR_REMOTE_TRANSPORT_UNSUPPORTED",
        "unsupported",
        "error.remote.transportUnsupported",
        json!({ "scheme": "svn" }),
        false,
    )
}

fn invalid_worker_field(field: &str) -> BridgeFailure {
    BridgeFailure::new(
        "SUBVERSIONR_REMOTE_WORKER_CONFIGURATION_INVALID",
        "configuration",
        "error.remote.workerConfigurationInvalid",
        json!({ "field": field }),
        false,
    )
}

fn worker_start_failure() -> BridgeFailure {
    BridgeFailure::new(
        "SUBVERSIONR_REMOTE_WORKER_START_FAILED",
        "process",
        "error.remote.workerStartFailed",
        json!({}),
        false,
    )
}

fn cancelled_failure() -> BridgeFailure {
    BridgeFailure::new(
        "SUBVERSIONR_REMOTE_WORKER_CANCELLED",
        "cancelled",
        "error.remote.workerCancelled",
        json!({}),
        false,
    )
}

fn timed_out_failure() -> BridgeFailure {
    BridgeFailure::new(
        "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT",
        "timeout",
        "error.remote.workerTimedOut",
        json!({}),
        false,
    )
}

fn disconnected_failure() -> BridgeFailure {
    BridgeFailure::new(
        "SUBVERSIONR_REMOTE_WORKER_DISCONNECTED",
        "state",
        "error.remote.workerDisconnected",
        json!({}),
        false,
    )
}

fn cleanup_blocked_failure() -> BridgeFailure {
    BridgeFailure::new(
        "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED",
        "state",
        "error.remote.recoveryBlocked",
        json!({}),
        false,
    )
}

#[cfg(windows)]
mod platform {
    include!("remote_worker_windows.rs");
}

#[cfg(not(windows))]
mod platform {
    use super::*;
    use std::collections::HashMap;

    #[derive(Debug, Default)]
    pub(super) struct ActiveWorkerRegistry;
    impl ActiveWorkerRegistry {
        pub(super) fn count(&self) -> usize {
            0
        }
        pub(super) fn allow_launches(
            &self,
            disconnected: &AtomicBool,
        ) -> Result<(), BridgeFailure> {
            if disconnected.load(Ordering::Acquire) {
                Err(disconnected_failure())
            } else {
                Ok(())
            }
        }
        pub(super) fn block_launches_and_terminate_all(&self) {}
        pub(super) fn launches_allowed(&self) -> bool {
            true
        }
        pub(super) fn wait_for_zero(&self, _timeout: Duration) -> Result<(), BridgeFailure> {
            Ok(())
        }
    }

    pub(super) fn execute_worker(
        _worker_executable: &Path,
        _bridge_path: &Path,
        _temp_base: &Path,
        _envelope: &RemoteOperationEnvelope,
        _plan: RemoteConfigPlan,
        _cancellation: &dyn BridgeCancellationToken,
        _auth: &mut dyn AuthRequestBroker,
        _disconnected: &AtomicBool,
        _parent_disconnected: &AtomicBool,
        _active: &ActiveWorkerRegistry,
        _deadline: Instant,
        _execution: WorkerExecution,
        effect: RemoteOperationEffect,
    ) -> RemoteWorkerSettlement {
        RemoteWorkerSettlement::pre_launch(effect, Err(worker_start_failure()))
    }

    pub(super) fn worker_control_channel_is_private() -> bool {
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use subversionr_protocol::OperationFailureCause;

    fn failed_mutation_settlement(
        code: &str,
        execution_origin_known: bool,
    ) -> RemoteWorkerSettlement {
        RemoteWorkerSettlement {
            result: Err(BridgeFailure::new(
                code,
                "test",
                "error.remote.test",
                serde_json::json!({}),
                false,
            )),
            remote_failure: None,
            effect: RemoteOperationEffect::Mutation,
            worker_was_resumed: true,
            execution_origin_known,
            termination: WorkerTerminationDisposition::NotRequired,
            job_descendants_zero: true,
            temp_root_removed: true,
            operation_output: None,
        }
    }

    fn failed_authenticated_identity_settlement(code: &str) -> RemoteWorkerSettlement {
        let failure = BridgeFailure::new(
            code,
            "native",
            "error.native.operationLockFailed",
            json!({
                "path": "C:/wc/trunk.txt",
                "status": 2,
                "mayHaveMutated": false,
                "anonymousIdentityRequired": true
            }),
            false,
        )
        .with_diagnostics(OperationFailureDiagnostics {
            cause: OperationFailureCause::AuthenticationFailed,
            svn: subversionr_protocol::SvnErrorDiagnostics {
                entries: vec![subversionr_protocol::SvnErrorDiagnosticEntry {
                    code: 170001,
                    name: "SVN_ERR_RA_NOT_AUTHORIZED".to_string(),
                }],
                truncated: false,
            },
        });
        RemoteWorkerSettlement {
            result: Err(failure),
            remote_failure: None,
            effect: RemoteOperationEffect::Mutation,
            worker_was_resumed: true,
            execution_origin_known: true,
            termination: WorkerTerminationDisposition::NotRequired,
            job_descendants_zero: true,
            temp_root_removed: true,
            operation_output: None,
        }
    }

    #[test]
    fn only_origin_known_pre_operation_failures_prove_no_mutation() {
        for code in [
            "SUBVERSIONR_REMOTE_ORIGIN_MISMATCH",
            "SUBVERSIONR_REMOTE_AUTH_UNSUPPORTED",
        ] {
            assert!(!failed_mutation_settlement(code, true).may_have_mutated());
            assert!(failed_mutation_settlement(code, false).may_have_mutated());
        }
        assert!(
            failed_mutation_settlement("SUBVERSIONR_REMOTE_WORKER_TIMED_OUT", true)
                .may_have_mutated()
        );
    }

    #[test]
    fn authenticated_identity_lock_failures_prove_no_mutation_only_at_the_exact_boundary() {
        for code in ["SVN_OPERATION_LOCK_FAILED", "SVN_OPERATION_UNLOCK_FAILED"] {
            assert!(!failed_authenticated_identity_settlement(code).may_have_mutated());
        }
        let mut no_user = failed_authenticated_identity_settlement("SVN_OPERATION_UNLOCK_FAILED");
        no_user
            .result
            .as_mut()
            .expect_err("fixture must fail")
            .diagnostics
            .as_mut()
            .expect("fixture diagnostics")
            .svn
            .entries[0] = subversionr_protocol::SvnErrorDiagnosticEntry {
            code: 160034,
            name: "SVN_ERR_FS_NO_USER".to_string(),
        };
        assert!(!no_user.may_have_mutated());

        let mut ordinary_lock =
            failed_authenticated_identity_settlement("SVN_OPERATION_LOCK_FAILED");
        ordinary_lock
            .result
            .as_mut()
            .expect_err("fixture must fail")
            .diagnostics
            .as_mut()
            .expect("fixture diagnostics")
            .cause = OperationFailureCause::AuthorizationDenied;
        assert!(ordinary_lock.may_have_mutated());
        for field in ["anonymousIdentityRequired", "mayHaveMutated"] {
            let mut incomplete =
                failed_authenticated_identity_settlement("SVN_OPERATION_LOCK_FAILED");
            incomplete
                .result
                .as_mut()
                .expect_err("fixture must fail")
                .args
                .as_object_mut()
                .expect("fixture safe args")
                .remove(field);
            assert!(incomplete.may_have_mutated());
        }
        let mut partial = failed_authenticated_identity_settlement("SVN_OPERATION_LOCK_FAILED");
        partial.result.as_mut().expect_err("fixture must fail").args["mayHaveMutated"] =
            json!(true);
        assert!(partial.may_have_mutated());
        let mut unrelated_chain =
            failed_authenticated_identity_settlement("SVN_OPERATION_LOCK_FAILED");
        unrelated_chain
            .result
            .as_mut()
            .expect_err("fixture must fail")
            .diagnostics
            .as_mut()
            .expect("fixture diagnostics")
            .svn
            .entries[0]
            .name = "SVN_ERR_AUTHZ_UNWRITABLE".to_string();
        assert!(unrelated_chain.may_have_mutated());
        let mut truncated_chain =
            failed_authenticated_identity_settlement("SVN_OPERATION_LOCK_FAILED");
        truncated_chain
            .result
            .as_mut()
            .expect_err("fixture must fail")
            .diagnostics
            .as_mut()
            .expect("fixture diagnostics")
            .svn
            .truncated = true;
        assert!(truncated_chain.may_have_mutated());
        assert!(
            failed_authenticated_identity_settlement("SVN_OPERATION_UPDATE_FAILED")
                .may_have_mutated()
        );
    }

    #[test]
    fn frame_rejects_zero_oversized_and_truncated_payloads() {
        assert!(read_frame(&mut &0u32.to_le_bytes()[..], 8).is_err());
        assert!(read_frame(&mut &9u32.to_le_bytes()[..], 8).is_err());
        let mut truncated = Vec::from(4u32.to_le_bytes());
        truncated.extend_from_slice(b"abc");
        assert!(read_frame(&mut &truncated[..], 8).is_err());
    }

    #[test]
    fn strict_request_rejects_unknown_fields_and_versions() {
        let json = br#"{"protocolVersion":2,"requestId":"id","bridgePath":"x","operationTempRoot":"y","envelope":{},"plan":{},"unknown":true}"#;
        assert!(decode_request(json).is_err());
    }

    #[test]
    fn windows_argument_is_private_and_fixed() {
        assert_eq!(
            PRIVATE_REMOTE_WORKER_MODE,
            "--subversionr-private-remote-worker-v1"
        );
    }

    #[test]
    fn production_worker_source_uses_handle_allowlisting_without_environment_handles() {
        let source = include_str!("remote_worker_windows.rs");
        for required in [
            "CREATE_SUSPENDED",
            "CREATE_NO_WINDOW",
            "PROC_THREAD_ATTRIBUTE_HANDLE_LIST",
            "JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE",
            "AssignProcessToJobObject",
            "QueryInformationJobObject",
            "TerminateJobObject",
        ] {
            assert!(
                source.contains(required),
                "missing containment lock: {required}"
            );
        }
        assert!(!source.contains("SUBVERSIONR_M8_CONTROL"));
        assert!(!source.contains("parse_required_handle"));
        assert!(!source.contains("Command::new"));
    }

    #[test]
    fn child_deadline_uses_the_shortened_worker_plan_timeout() {
        let request: WorkerRequest = serde_json::from_value(json!({
            "protocolVersion": PRIVATE_WORKER_PROTOCOL_VERSION,
            "requestId": "01234567-89ab-4def-8123-456789abcdef",
            "bridgePath": "C:/bridge.dll",
            "operationTempRoot": "C:/subversionr-remote-01234567-89ab-4def-8123-456789abcdef",
            "envelope": {
                "version": 1,
                "operationId": "01234567-89ab-4def-8123-456789abcdef",
                "intent": "foreground",
                "interaction": "allowed",
                "timeoutMs": 10000,
                "workspaceTrust": "trusted",
                "trustEpoch": 1,
                "profile": {
                    "schema": "subversionr.remote-profile.v1",
                    "profileId": "deadline-test",
                    "authority": {"scheme":"https","canonicalHost":"svn.example.invalid","effectivePort":443},
                    "serverAuth": "anonymous",
                    "serverAccount": "none",
                    "serverCredentialPersistence": "secretStorage",
                    "tls": {"trust":"windowsRootsThenBroker"},
                    "proxy": "none",
                    "ssh": "none",
                    "redirectPolicy": "rejectAll"
                },
                "expectedOrigin": {"scheme":"https","canonicalHost":"svn.example.invalid","effectivePort":443}
            },
            "plan": {
                "scheme": "https",
                "serverAuth": "anonymous",
                "timeoutMs": 20,
                "trustWindowsRoots": true
            },
            "execution": {"kind": "foundation"}
        }))
        .expect("worker request fixture must match the private contract");
        let before = Instant::now();
        let deadline = worker_deadline(&request).expect("shortened worker deadline must fit");
        let elapsed = deadline.duration_since(before);
        assert!(elapsed >= Duration::from_millis(15));
        assert!(elapsed <= Duration::from_millis(50));
    }

    #[test]
    fn private_worker_settlement_failure_frames_preserve_all_stable_contracts() {
        for (code, category, message_key, args) in settlement_failure_contracts() {
            let operation_id = "01234567-89ab-4def-8123-456789abcdef";
            let parent = ParentWorkerFrame::CredentialSettlementFailure {
                protocol_version: PRIVATE_WORKER_PROTOCOL_VERSION,
                operation_id: operation_id.to_string(),
                sequence: 1,
                failure: WireFailure {
                    code: code.to_string(),
                    category: category.to_string(),
                    message_key: message_key.to_string(),
                    args: args.clone(),
                    retryable: false,
                    diagnostics: None,
                },
            };
            let parent_bytes = serde_json::to_vec(&parent).expect("parent frame must serialize");
            let mut framed_parent = Vec::new();
            write_frame(&mut framed_parent, &parent_bytes, MAX_REQUEST_FRAME_BYTES)
                .expect("parent frame must be bounded");
            let mut reader = std::io::Cursor::new(framed_parent);
            let mut writer = Vec::new();
            let mut broker = WorkerControlAuthBroker {
                operation_id: operation_id.to_string(),
                sequence: 0,
                reader: &mut reader,
                writer: &mut writer,
            };

            let failure = broker
                .settle_credential(CredentialSettlementRequest {
                    request_id: "settle-frame".to_string(),
                    operation_id: operation_id.to_string(),
                    lease_id: "lease-frame".to_string(),
                    outcome: subversionr_protocol::CredentialSettlementOutcome::Accepted,
                    timeout_ms: 30_000,
                })
                .expect_err("settlement failure frame must remain an error");

            assert_eq!(failure.code(), code);
            assert_eq!(failure.category, category);
            assert_eq!(failure.message_key, message_key);
            assert_eq!(failure.safe_args(), &args);
            let child_bytes =
                read_frame(&mut std::io::Cursor::new(writer), MAX_RESPONSE_FRAME_BYTES)
                    .expect("child settlement request must be framed");
            let child: ChildWorkerFrame =
                serde_json::from_slice(&child_bytes).expect("child frame must deserialize");
            assert!(matches!(
                child,
                ChildWorkerFrame::CredentialSettlement {
                    protocol_version: PRIVATE_WORKER_PROTOCOL_VERSION,
                    sequence: 1,
                    ..
                }
            ));
        }
    }

    #[test]
    fn private_worker_settlement_failure_rejects_unknown_codes_and_extra_args() {
        let safe_args = json!({
            "operationHash": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            "leaseHash": "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
            "outcome": "accepted"
        });
        let unknown = WireFailure {
            code: "SUBVERSIONR_CREDENTIAL_UNKNOWN".to_string(),
            category: "auth".to_string(),
            message_key: "error.auth.credentialUnknown".to_string(),
            args: safe_args.clone(),
            retryable: false,
            diagnostics: None,
        };
        assert_eq!(
            validate_credential_settlement_wire_failure(unknown)
                .expect_err("unknown settlement code must fail closed")
                .code(),
            "SUBVERSIONR_REMOTE_WORKER_PROTOCOL_INVALID"
        );

        let mut extra_args = safe_args;
        extra_args["realm"] = Value::String("must-not-cross-worker-boundary".to_string());
        let extra = WireFailure {
            code: "SUBVERSIONR_CREDENTIAL_TIMEOUT".to_string(),
            category: "auth".to_string(),
            message_key: "error.auth.credentialTimeout".to_string(),
            args: extra_args,
            retryable: false,
            diagnostics: None,
        };
        assert_eq!(
            validate_credential_settlement_wire_failure(extra)
                .expect_err("extra settlement args must fail closed")
                .code(),
            "SUBVERSIONR_REMOTE_WORKER_PROTOCOL_INVALID"
        );
    }

    fn settlement_failure_contracts() -> Vec<(&'static str, &'static str, &'static str, Value)> {
        let operation_hash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        let lease_hash = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";
        vec![
            (
                "SUBVERSIONR_CREDENTIAL_UNTRUSTED_WORKSPACE",
                "lifecycle",
                "error.auth.credentialUntrustedWorkspace",
                json!({ "operationHash": operation_hash, "leaseHash": lease_hash }),
            ),
            (
                "SUBVERSIONR_CREDENTIAL_TIMEOUT",
                "auth",
                "error.auth.credentialTimeout",
                json!({ "operationHash": operation_hash, "leaseHash": lease_hash, "outcome": "accepted" }),
            ),
            (
                "SUBVERSIONR_CREDENTIAL_LEASE_UNKNOWN",
                "auth",
                "error.auth.credentialLeaseUnknown",
                json!({ "operationHash": operation_hash, "leaseHash": lease_hash, "outcome": "accepted" }),
            ),
            (
                "SUBVERSIONR_CREDENTIAL_LEASE_FOREIGN",
                "auth",
                "error.auth.credentialLeaseForeign",
                json!({ "operationHash": operation_hash, "leaseHash": lease_hash, "outcome": "accepted" }),
            ),
            (
                "SUBVERSIONR_CREDENTIAL_LEASE_EXPIRED",
                "auth",
                "error.auth.credentialLeaseExpired",
                json!({ "operationHash": operation_hash, "leaseHash": lease_hash, "outcome": "accepted" }),
            ),
            (
                "SUBVERSIONR_CREDENTIAL_SETTLEMENT_CONFLICT",
                "auth",
                "error.auth.credentialSettlementConflict",
                json!({ "operationHash": operation_hash, "leaseHash": lease_hash, "outcome": "accepted" }),
            ),
        ]
    }
}
