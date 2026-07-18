use std::fs;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use subversionr_protocol::RemoteOperationEnvelope;

use crate::{
    BridgeApi, BridgeCancellationToken, BridgeFailure, RemoteConfigPlan, RemoteNativeBridge,
};

const PRIVATE_WORKER_PROTOCOL_VERSION: u16 = 1;
const PRIVATE_REMOTE_WORKER_MODE: &str = "--subversionr-private-remote-worker-v1";
const MAX_REQUEST_FRAME_BYTES: usize = 64 * 1024;
const MAX_RESPONSE_FRAME_BYTES: usize = 64 * 1024;
const CLEANUP_TIMEOUT: Duration = Duration::from_secs(5);
const SUPERVISION_POLL: Duration = Duration::from_millis(5);
const WORKER_TERMINATION_CODE: u32 = 0x5356_5201;

pub trait RemoteWorkerSupervisor: Send + Sync {
    fn execute(
        &self,
        envelope: &RemoteOperationEnvelope,
        plan: RemoteConfigPlan,
        lane_key: &str,
        cancellation: &dyn BridgeCancellationToken,
        bridge: &dyn BridgeApi,
        deadline: Instant,
    ) -> Result<(), BridgeFailure>;

    fn terminate_active(&self) -> Result<(), BridgeFailure>;

    fn update_workspace_trust(&self, _trusted: bool) -> Result<(), BridgeFailure> {
        Ok(())
    }

    fn disconnect(&self) -> Result<(), BridgeFailure>;

    fn capability_available(&self) -> bool;
}

#[derive(Debug, Default, Clone, Copy)]
pub struct InlineRemoteWorkerSupervisor;

impl RemoteWorkerSupervisor for InlineRemoteWorkerSupervisor {
    fn execute(
        &self,
        _envelope: &RemoteOperationEnvelope,
        plan: RemoteConfigPlan,
        _lane_key: &str,
        cancellation: &dyn BridgeCancellationToken,
        bridge: &dyn BridgeApi,
        deadline: Instant,
    ) -> Result<(), BridgeFailure> {
        if cancellation.is_cancelled() || Instant::now() >= deadline {
            return Err(cancelled_failure());
        }
        bridge.create_remote_context_foundation(plan)
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
    active: platform::ActiveWorkerRegistry,
    lanes: platform::LaneRegistry,
}

impl ProcessRemoteWorkerSupervisor {
    pub fn new(
        worker_executable: PathBuf,
        bridge_path: PathBuf,
        temp_base: PathBuf,
    ) -> Result<Self, BridgeFailure> {
        let worker_executable = verified_file(&worker_executable, "workerExecutable")?;
        let bridge_path = verified_file(&bridge_path, "bridgePath")?;
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
            active: platform::ActiveWorkerRegistry::default(),
            lanes: platform::LaneRegistry::default(),
        })
    }

    pub fn execute_with_disconnect(
        &self,
        envelope: &RemoteOperationEnvelope,
        plan: RemoteConfigPlan,
        lane_key: &str,
        cancellation: &dyn BridgeCancellationToken,
        parent_disconnected: &AtomicBool,
        deadline: Instant,
    ) -> Result<(), BridgeFailure> {
        if self.disconnected.load(Ordering::Acquire) || parent_disconnected.load(Ordering::Acquire)
        {
            return Err(disconnected_failure());
        }
        if plan.timeout_ms != envelope.timeout_ms {
            return Err(worker_protocol_failure());
        }
        if Instant::now() >= deadline {
            return Err(timed_out_failure());
        }
        validate_request_parts(envelope, plan, lane_key)?;
        let lane = self.lanes.reserve(lane_key)?;
        let result = platform::execute_worker(
            &self.worker_executable,
            &self.bridge_path,
            &self.temp_base,
            envelope,
            plan,
            cancellation,
            &self.disconnected,
            parent_disconnected,
            &self.active,
            deadline,
        );
        match &result {
            Err(failure) if failure.code() == "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED" => {
                lane.block();
            }
            _ => lane.release(),
        }
        result
    }

    pub fn blocked_lane_count(&self) -> usize {
        self.lanes.blocked_count()
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
        cancellation: &dyn BridgeCancellationToken,
        _bridge: &dyn BridgeApi,
        deadline: Instant,
    ) -> Result<(), BridgeFailure> {
        self.execute_with_disconnect(
            envelope,
            plan,
            lane_key,
            cancellation,
            &self.disconnected,
            deadline,
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
    Success,
    Failure { failure: WireFailure },
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct WireFailure {
    code: String,
    category: String,
    message_key: String,
    args: Value,
    retryable: bool,
}

impl WireFailure {
    fn from_bridge(failure: BridgeFailure) -> Self {
        Self {
            code: failure.code,
            category: failure.category,
            message_key: failure.message_key,
            args: failure.args,
            retryable: failure.retryable,
        }
    }
}

pub fn run_remote_worker(mut reader: impl Read, mut writer: impl Write) -> ExitCode {
    let response = match read_frame(&mut reader, MAX_REQUEST_FRAME_BYTES).and_then(|bytes| {
        let mut trailing = [0u8; 1];
        if reader.read(&mut trailing)? != 0 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "worker accepts exactly one request frame",
            ));
        }
        decode_request(&bytes)
    }) {
        Ok(request) => execute_worker_request(request),
        Err(_) => return ExitCode::from(3),
    };
    match encode_response(&response)
        .and_then(|bytes| write_frame(&mut writer, &bytes, MAX_RESPONSE_FRAME_BYTES))
    {
        Ok(()) => ExitCode::SUCCESS,
        Err(_) => ExitCode::from(4),
    }
}

pub fn remote_worker_control_channel_is_private() -> bool {
    platform::worker_control_channel_is_private()
}

fn execute_worker_request(request: WorkerRequest) -> WorkerResponse {
    let request_id = request.request_id.clone();
    let operation_id = request.envelope.operation_id.clone();
    let result = validate_worker_request(&request).and_then(|bridge_path| {
        let bridge = RemoteNativeBridge::load_foundation(&bridge_path)
            .map_err(|_| worker_start_failure())?;
        bridge.create_remote_context_foundation(request.plan)
    });
    WorkerResponse {
        protocol_version: PRIVATE_WORKER_PROTOCOL_VERSION,
        request_id,
        operation_id,
        result: match result {
            Ok(()) => WorkerResult::Success,
            Err(failure) => WorkerResult::Failure {
                failure: WireFailure::from_bridge(failure),
            },
        },
    }
}

fn decode_request(bytes: &[u8]) -> io::Result<WorkerRequest> {
    serde_json::from_slice(bytes)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid worker request"))
}

fn encode_response(response: &WorkerResponse) -> io::Result<Vec<u8>> {
    serde_json::to_vec(response)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid worker response"))
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

fn lane_busy_failure() -> BridgeFailure {
    BridgeFailure::new(
        "SUBVERSIONR_REMOTE_NATIVE_LANE_BUSY",
        "state",
        "error.remote.nativeLaneBusy",
        json!({}),
        true,
    )
}

#[cfg(windows)]
mod platform {
    include!("remote_worker_windows.rs");
}

#[cfg(not(windows))]
mod platform {
    use super::*;
    use std::collections::{HashMap, HashSet};
    use std::sync::{Arc, Mutex};

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
        pub(super) fn wait_for_zero(&self, _timeout: Duration) -> Result<(), BridgeFailure> {
            Ok(())
        }
    }

    #[derive(Debug, Default)]
    pub(super) struct LaneRegistry {
        state: Arc<Mutex<(HashSet<String>, HashSet<String>)>>,
    }
    pub(super) struct LaneReservation {
        key: String,
        state: Arc<Mutex<(HashSet<String>, HashSet<String>)>>,
    }
    impl LaneRegistry {
        pub(super) fn reserve(&self, key: &str) -> Result<LaneReservation, BridgeFailure> {
            let mut state = self.state.lock().expect("lane registry mutex poisoned");
            if state.1.contains(key) || !state.0.insert(key.to_string()) {
                return Err(if state.1.contains(key) {
                    cleanup_blocked_failure()
                } else {
                    lane_busy_failure()
                });
            }
            Ok(LaneReservation {
                key: key.to_string(),
                state: Arc::clone(&self.state),
            })
        }
        pub(super) fn blocked_count(&self) -> usize {
            self.state
                .lock()
                .expect("lane registry mutex poisoned")
                .1
                .len()
        }
    }
    impl LaneReservation {
        pub(super) fn release(&self) {
            self.state
                .lock()
                .expect("lane registry mutex poisoned")
                .0
                .remove(&self.key);
        }
        pub(super) fn block(&self) {
            let mut s = self.state.lock().expect("lane registry mutex poisoned");
            s.0.remove(&self.key);
            s.1.insert(self.key.clone());
        }
    }
    impl Drop for LaneReservation {
        fn drop(&mut self) {
            self.state
                .lock()
                .expect("lane registry mutex poisoned")
                .0
                .remove(&self.key);
        }
    }

    pub(super) fn execute_worker(
        _worker_executable: &Path,
        _bridge_path: &Path,
        _temp_base: &Path,
        _envelope: &RemoteOperationEnvelope,
        _plan: RemoteConfigPlan,
        _cancellation: &dyn BridgeCancellationToken,
        _disconnected: &AtomicBool,
        _parent_disconnected: &AtomicBool,
        _active: &ActiveWorkerRegistry,
        _deadline: Instant,
    ) -> Result<(), BridgeFailure> {
        Err(worker_start_failure())
    }

    pub(super) fn worker_control_channel_is_private() -> bool {
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
}
