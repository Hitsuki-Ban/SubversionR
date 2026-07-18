use std::collections::{BTreeMap, VecDeque};
use std::io::{self, BufRead, BufReader, Read, Write};
use std::str;
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicBool, AtomicU8, Ordering},
};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use serde::de::DeserializeOwned;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use subversionr_protocol::{
    CertificateTrustError, CertificateTrustRequest, CertificateTrustResponse, CredentialError,
    CredentialRequest, CredentialResponse, CredentialSettlementAck, CredentialSettlementRequest,
};

use crate::remote::{RemoteLaunchPlan, unsupported_transport};
use crate::{
    AuthRequestBroker, BridgeApi, BridgeCancellationToken, BridgeFailure, DaemonState,
    DispatchOutcome, InlineRemoteWorkerSupervisor, JsonRpcRequest, RemoteWorkerSupervisor,
    UnavailableBridge, bridge_error, rpc_error,
};

const MAX_JSON_RPC_FRAME_BYTES: usize = 4 * 1024 * 1024;
const MAX_JSON_RPC_HEADER_BYTES: usize = 8 * 1024;
const MAX_JSON_RPC_HEADER_LINE_BYTES: usize = 1024;
const MAX_AUTH_WAIT_INBOUND_MESSAGES: usize = 64;
const MAX_RETIRED_AUTH_REQUEST_IDS: usize = 64;
const MAX_STDIN_FRAME_QUEUE: usize = 64;
const MAX_PENDING_CANCEL_REQUEST_IDS: usize = 64;

pub fn run_json_rpc_stdio<R, W>(reader: R, mut writer: W, bridge: &dyn BridgeApi) -> io::Result<()>
where
    R: Read + Send + 'static,
    W: Write,
{
    run_json_rpc_stdio_with_remote_worker(
        reader,
        &mut writer,
        bridge,
        Arc::new(InlineRemoteWorkerSupervisor::default()),
    )
}

pub fn run_json_rpc_stdio_with_remote_worker<R, W>(
    reader: R,
    mut writer: W,
    bridge: &dyn BridgeApi,
    remote_worker: Arc<dyn RemoteWorkerSupervisor>,
) -> io::Result<()>
where
    R: Read + Send + 'static,
    W: Write,
{
    let mut frames = StdioFrameReceiver::spawn(reader, remote_worker.clone())?;
    let mut state = DaemonState::with_remote_worker(remote_worker.clone());
    let (worker_sender, worker_receiver) = mpsc::channel::<RemoteWorkerCompletion>();
    let (broker_sender, broker_receiver) = mpsc::channel::<RemoteBrokerCall>();
    let mut pending = BTreeMap::<String, PendingRemoteRequest>::new();
    let mut pending_broker = BTreeMap::<String, PendingRemoteBroker>::new();
    let mut terminal = false;

    loop {
        if !terminal && !pending.is_empty() && frames.connection_terminal() {
            terminal = true;
        }
        expire_remote_broker_calls(&mut frames, &mut pending_broker);
        while let Ok(call) = broker_receiver.try_recv() {
            accept_remote_broker_call(
                call,
                &pending,
                &mut pending_broker,
                terminal || frames.connection_terminal(),
                &mut writer,
            )?;
        }
        while let Ok(completion) = worker_receiver.try_recv() {
            let connection_terminal = terminal || frames.connection_terminal();
            settle_remote_completion(
                &mut state,
                &mut frames,
                &mut pending,
                &mut pending_broker,
                completion,
                connection_terminal,
                &mut writer,
            )?;
        }
        if terminal {
            fail_all_remote_broker_calls(&mut pending_broker, auth_response_unavailable);
            while let Ok(call) = broker_receiver.try_recv() {
                let method = call.method;
                fail_remote_broker_call(call, auth_response_unavailable(method));
            }
            if pending.is_empty() {
                break;
            }
            match worker_receiver.recv_timeout(Duration::from_millis(10)) {
                Ok(completion) => settle_remote_completion(
                    &mut state,
                    &mut frames,
                    &mut pending,
                    &mut pending_broker,
                    completion,
                    true,
                    &mut writer,
                )?,
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => {
                    return Err(io::Error::other(
                        "remote worker completion channel closed with pending operations",
                    ));
                }
            }
            continue;
        }

        let payload = match frames.recv_until(Instant::now() + Duration::from_millis(10))? {
            TimedStdioFrame::Payload(payload) => payload,
            TimedStdioFrame::Timeout => continue,
            TimedStdioFrame::Eof => {
                terminal = true;
                continue;
            }
        };
        if let Some(cancel_id) = cancel_notification_id(&payload) {
            if let Some(request_id) = cancel_id.as_str()
                && let Some(pending_call) = pending_broker.remove(request_id)
            {
                frames.retire_auth_request_id(request_id);
                let _ = pending_call
                    .responder
                    .send(Err(auth_cancelled(pending_call.method)));
            }
            continue;
        }
        if route_remote_broker_response(&payload, &mut pending_broker)? {
            continue;
        }
        let request = str::from_utf8(&payload)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
        let request: JsonRpcRequest = serde_json::from_str(request)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
        let cancellation = StdioCancellationToken::new();
        let active_cancellation =
            frames.activate_request_cancellation(request.id.clone(), cancellation.clone());
        let mut result = {
            let mut auth = StdioAuthRequestBroker {
                frames: &mut frames,
                writer: &mut writer,
                operation_cancellation: &cancellation,
            };
            state.dispatch_request_with_auth_and_cancellation(
                request,
                bridge,
                &mut auth,
                &cancellation,
            )
        };
        if let Some(launch) = result.take_remote_launch() {
            let operation_id = launch.operation.envelope.operation_id.clone();
            if frames.connection_terminal() {
                state.settle_remote_launch(&launch.lane_key, &operation_id, false);
                drop(active_cancellation);
                continue;
            }
            let pending_request = PendingRemoteRequest {
                _cancellation: active_cancellation,
                notifications: result.notifications().to_vec(),
            };
            match spawn_remote_worker(
                remote_worker.clone(),
                launch,
                cancellation,
                worker_sender.clone(),
                broker_sender.clone(),
            ) {
                Ok(()) => {
                    pending.insert(operation_id, pending_request);
                }
                Err(error) => {
                    drop(pending_request);
                    state.settle_remote_launch(
                        error.lane_key.as_str(),
                        error.operation_id.as_str(),
                        false,
                    );
                    write_content_length_frame(
                        &mut writer,
                        &remote_worker_start_error_response(error.request_id),
                    )?;
                    writer.flush()?;
                }
            }
            continue;
        }
        write_content_length_frame(&mut writer, result.response())?;
        for notification in result.notifications() {
            write_content_length_frame(&mut writer, notification)?;
        }
        writer.flush()?;

        if result.outcome() == DispatchOutcome::Shutdown {
            terminal = true;
        }
    }

    Ok(())
}

struct PendingRemoteRequest {
    _cancellation: ActiveStdioRequestCancellationGuard,
    notifications: Vec<Value>,
}

struct RemoteBrokerCall {
    operation_id: String,
    request_id: String,
    method: &'static str,
    params: Value,
    deadline: Instant,
    responder: mpsc::Sender<Result<Value, BridgeFailure>>,
}

struct PendingRemoteBroker {
    operation_id: String,
    method: &'static str,
    deadline: Instant,
    responder: mpsc::Sender<Result<Value, BridgeFailure>>,
}

struct RemoteWorkerCompletion {
    request_id: Value,
    operation_id: String,
    lane_key: String,
    endpoint: subversionr_protocol::CanonicalEndpoint,
    result: Result<(), BridgeFailure>,
}

struct RemoteWorkerSpawnError {
    request_id: Value,
    operation_id: String,
    lane_key: String,
}

fn spawn_remote_worker(
    remote_worker: Arc<dyn RemoteWorkerSupervisor>,
    launch: RemoteLaunchPlan,
    cancellation: StdioCancellationToken,
    sender: mpsc::Sender<RemoteWorkerCompletion>,
    broker_sender: mpsc::Sender<RemoteBrokerCall>,
) -> Result<(), RemoteWorkerSpawnError> {
    let request_id = launch.request_id.clone();
    let operation_id = launch.operation.envelope.operation_id.clone();
    let lane_key = launch.lane_key.clone();
    let endpoint = launch.operation.endpoint.clone();
    let spawn_error = RemoteWorkerSpawnError {
        request_id: request_id.clone(),
        operation_id: operation_id.clone(),
        lane_key: lane_key.clone(),
    };
    thread::Builder::new()
        .name(format!("subversionr-remote-worker-{operation_id}"))
        .spawn(move || {
            let unavailable_bridge = UnavailableBridge;
            let mut auth = RemoteWorkerAuthBroker::new(
                operation_id.clone(),
                broker_sender,
                cancellation.clone(),
                Arc::clone(&remote_worker),
                launch.operation.deadline,
            );
            let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                remote_worker.execute(
                    &launch.operation.envelope,
                    launch.operation.config,
                    &lane_key,
                    &cancellation,
                    &mut auth,
                    &unavailable_bridge,
                    launch.operation.deadline,
                )
            }))
            .unwrap_or_else(|_| {
                Err(BridgeFailure::new(
                    "SUBVERSIONR_REMOTE_WORKER_CRASHED",
                    "process",
                    "error.remote.workerCrashed",
                    json!({ "stage": "supervisor" }),
                    false,
                ))
            });
            let _ = sender.send(RemoteWorkerCompletion {
                request_id,
                operation_id,
                lane_key,
                endpoint,
                result,
            });
        })
        .map(|_| ())
        .map_err(|_| spawn_error)
}

struct RemoteWorkerAuthBroker {
    operation_id: String,
    sender: mpsc::Sender<RemoteBrokerCall>,
    cancellation: StdioCancellationToken,
    remote_worker: Arc<dyn RemoteWorkerSupervisor>,
    operation_deadline: Instant,
}

impl RemoteWorkerAuthBroker {
    fn new(
        operation_id: String,
        sender: mpsc::Sender<RemoteBrokerCall>,
        cancellation: StdioCancellationToken,
        remote_worker: Arc<dyn RemoteWorkerSupervisor>,
        operation_deadline: Instant,
    ) -> Self {
        Self {
            operation_id,
            sender,
            cancellation,
            remote_worker,
            operation_deadline,
        }
    }

    fn round_trip<TRequest, TResponse>(
        &self,
        method: &'static str,
        request_id: &str,
        timeout_ms: u64,
        request: TRequest,
    ) -> Result<TResponse, BridgeFailure>
    where
        TRequest: serde::Serialize,
        TResponse: DeserializeOwned,
    {
        if request_id.is_empty() || request_id.len() > 128 || timeout_ms == 0 {
            return Err(auth_response_invalid(method));
        }
        let deadline = auth_deadline(timeout_ms, method)?.min(self.operation_deadline);
        let params = serde_json::to_value(request).map_err(|_| auth_response_invalid(method))?;
        let (responder, receiver) = mpsc::channel();
        self.sender
            .send(RemoteBrokerCall {
                operation_id: self.operation_id.clone(),
                request_id: request_id.to_string(),
                method,
                params,
                deadline,
                responder,
            })
            .map_err(|_| auth_response_unavailable(method))?;
        let result = loop {
            if self.cancellation.is_cancelled() || self.remote_worker.auth_wait_cancelled() {
                return Err(auth_cancelled(method));
            }
            let remaining = deadline
                .checked_duration_since(Instant::now())
                .ok_or_else(|| auth_timeout(method))?;
            match receiver.recv_timeout(remaining.min(Duration::from_millis(5))) {
                Ok(result) => break result?,
                Err(RecvTimeoutError::Timeout) => continue,
                Err(RecvTimeoutError::Disconnected) => {
                    return Err(auth_response_unavailable(method));
                }
            }
        };
        serde_json::from_value(result).map_err(|_| auth_response_invalid(method))
    }
}

impl AuthRequestBroker for RemoteWorkerAuthBroker {
    fn request_credential(
        &mut self,
        request: CredentialRequest,
    ) -> Result<CredentialResponse, BridgeFailure> {
        if request.operation_id != self.operation_id
            || request.realm.is_empty()
            || request.realm.len() > 4096
        {
            return Err(auth_response_invalid("credentials/request"));
        }
        let request_id = request.request_id.clone();
        let operation_id = request.operation_id.clone();
        let safe_args = credential_safe_args(&request);
        let response: CredentialResponse = self.round_trip(
            "credentials/request",
            &request_id,
            request.timeout_ms,
            request,
        )?;
        match &response {
            CredentialResponse::Provide {
                request_id: response_request_id,
                operation_id: response_operation_id,
                lease_id,
                ..
            } if response_request_id == &request_id
                && response_operation_id == &operation_id
                && !lease_id.is_empty()
                && lease_id.len() <= 128 =>
            {
                Ok(response)
            }
            CredentialResponse::Cancel {
                request_id: response_request_id,
                operation_id: response_operation_id,
                error,
            } if response_request_id == &request_id && response_operation_id == &operation_id => {
                match credential_error_to_bridge(error, safe_args) {
                    Some(failure) => Err(failure),
                    None => Err(auth_response_invalid("credentials/request")),
                }
            }
            _ => Err(auth_response_invalid("credentials/request")),
        }
    }

    fn settle_credential(
        &mut self,
        request: CredentialSettlementRequest,
    ) -> Result<CredentialSettlementAck, BridgeFailure> {
        if request.operation_id != self.operation_id
            || request.lease_id.is_empty()
            || request.lease_id.len() > 128
        {
            return Err(auth_response_invalid("credentials/settle"));
        }
        let request_id = request.request_id.clone();
        let operation_id = request.operation_id.clone();
        let lease_id = request.lease_id.clone();
        let outcome = request.outcome;
        let response: CredentialSettlementAck = self.round_trip(
            "credentials/settle",
            &request_id,
            request.timeout_ms,
            request,
        )?;
        if response.request_id == request_id
            && response.operation_id == operation_id
            && response.lease_id == lease_id
            && response.outcome == outcome
        {
            Ok(response)
        } else {
            Err(auth_response_invalid("credentials/settle"))
        }
    }

    fn request_certificate_trust(
        &mut self,
        _request: CertificateTrustRequest,
    ) -> Result<CertificateTrustResponse, BridgeFailure> {
        Err(auth_response_unavailable("certificate/request"))
    }
}

fn accept_remote_broker_call<W: Write>(
    call: RemoteBrokerCall,
    operations: &BTreeMap<String, PendingRemoteRequest>,
    pending: &mut BTreeMap<String, PendingRemoteBroker>,
    terminal: bool,
    writer: &mut W,
) -> io::Result<()> {
    if terminal
        || !operations.contains_key(&call.operation_id)
        || call.request_id.is_empty()
        || call.request_id.len() > 128
        || pending.contains_key(&call.request_id)
        || Instant::now() >= call.deadline
        || pending.len() >= MAX_AUTH_WAIT_INBOUND_MESSAGES
    {
        let method = call.method;
        fail_remote_broker_call(call, auth_response_unavailable(method));
        return Ok(());
    }
    let message = json!({
        "jsonrpc": "2.0",
        "id": call.request_id,
        "method": call.method,
        "params": call.params,
    });
    if write_content_length_frame(writer, &message)
        .and_then(|()| writer.flush())
        .is_err()
    {
        let failure = auth_request_failed(call.method);
        fail_remote_broker_call(call, failure);
        return Err(io::Error::other("failed to write remote broker request"));
    }
    pending.insert(
        call.request_id,
        PendingRemoteBroker {
            operation_id: call.operation_id,
            method: call.method,
            deadline: call.deadline,
            responder: call.responder,
        },
    );
    Ok(())
}

fn route_remote_broker_response(
    payload: &[u8],
    pending: &mut BTreeMap<String, PendingRemoteBroker>,
) -> io::Result<bool> {
    let Ok(value) = serde_json::from_slice::<Value>(payload) else {
        return Ok(false);
    };
    let Some(object) = value.as_object() else {
        return Ok(false);
    };
    if object.get("jsonrpc") != Some(&Value::String("2.0".to_string()))
        || object.contains_key("method")
    {
        return Ok(false);
    }
    let Some(request_id) = object.get("id").and_then(Value::as_str) else {
        return Ok(false);
    };
    let Some(call) = pending.remove(request_id) else {
        return Ok(false);
    };
    let result = match (object.get("result"), object.get("error")) {
        (Some(result), None) if Instant::now() < call.deadline => Ok(result.clone()),
        (Some(_), None) => Err(auth_timeout(call.method)),
        (None, Some(error)) => match parse_auth_json_rpc_error(error, call.method) {
            Some(AuthJsonRpcErrorKind::Cancelled) => Err(auth_cancelled(call.method)),
            Some(AuthJsonRpcErrorKind::Rejected) => Err(auth_response_rejected(call.method)),
            Some(AuthJsonRpcErrorKind::Structured(failure)) => Err(failure),
            None => Err(auth_response_invalid(call.method)),
        },
        _ => Err(auth_response_invalid(call.method)),
    };
    let _ = call.responder.send(result);
    Ok(true)
}

fn expire_remote_broker_calls(
    frames: &mut StdioFrameReceiver,
    pending: &mut BTreeMap<String, PendingRemoteBroker>,
) {
    let expired = pending
        .iter()
        .filter_map(|(id, call)| (Instant::now() >= call.deadline).then_some(id.clone()))
        .collect::<Vec<_>>();
    for id in expired {
        if let Some(call) = pending.remove(&id) {
            frames.retire_auth_request_id(&id);
            let _ = call.responder.send(Err(auth_timeout(call.method)));
        }
    }
}

fn fail_remote_broker_call(call: RemoteBrokerCall, failure: BridgeFailure) {
    let _ = call.responder.send(Err(failure));
}

fn fail_operation_remote_broker_calls(
    frames: &mut StdioFrameReceiver,
    pending: &mut BTreeMap<String, PendingRemoteBroker>,
    operation_id: &str,
    failure: fn(&str) -> BridgeFailure,
) {
    let ids = pending
        .iter()
        .filter_map(|(id, call)| (call.operation_id == operation_id).then_some(id.clone()))
        .collect::<Vec<_>>();
    for id in ids {
        if let Some(call) = pending.remove(&id) {
            frames.retire_auth_request_id(&id);
            let _ = call.responder.send(Err(failure(call.method)));
        }
    }
}

fn fail_all_remote_broker_calls(
    pending: &mut BTreeMap<String, PendingRemoteBroker>,
    failure: fn(&str) -> BridgeFailure,
) {
    for (_, call) in std::mem::take(pending) {
        let _ = call.responder.send(Err(failure(call.method)));
    }
}

fn settle_remote_completion<W: Write>(
    state: &mut DaemonState,
    frames: &mut StdioFrameReceiver,
    pending: &mut BTreeMap<String, PendingRemoteRequest>,
    pending_broker: &mut BTreeMap<String, PendingRemoteBroker>,
    completion: RemoteWorkerCompletion,
    terminal: bool,
    writer: &mut W,
) -> io::Result<()> {
    let recovery_blocked = completion
        .result
        .as_ref()
        .is_err_and(|failure| failure.code() == "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED");
    state.settle_remote_launch(
        &completion.lane_key,
        &completion.operation_id,
        recovery_blocked,
    );
    fail_operation_remote_broker_calls(
        frames,
        pending_broker,
        &completion.operation_id,
        auth_response_unavailable,
    );
    let Some(pending_request) = pending.remove(&completion.operation_id) else {
        return Err(io::Error::other(
            "remote worker completed without a pending request",
        ));
    };
    if terminal {
        return Ok(());
    }
    let response = match completion.result {
        Ok(()) => json!({
            "jsonrpc": "2.0",
            "id": completion.request_id,
            "error": bridge_error(unsupported_transport(&completion.endpoint)),
        }),
        Err(failure) => json!({
            "jsonrpc": "2.0",
            "id": completion.request_id,
            "error": bridge_error(failure),
        }),
    };
    write_content_length_frame(writer, &response)?;
    for notification in pending_request.notifications {
        write_content_length_frame(writer, &notification)?;
    }
    writer.flush()
}

fn remote_worker_start_error_response(request_id: Value) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": request_id,
        "error": bridge_error(BridgeFailure::new(
            "SUBVERSIONR_REMOTE_WORKER_START_FAILED",
            "process",
            "error.remote.workerStartFailed",
            json!({ "stage": "supervisorThread" }),
            false,
        )),
    })
}

struct StdioFrameReceiver {
    receiver: Receiver<StdioFrameEvent>,
    reader_thread: Option<JoinHandle<()>>,
    terminal_consumed: bool,
    retired_auth_request_ids: RetiredAuthRequestIds,
    active_cancellation: ActiveStdioRequestCancellation,
    connection_terminal: Arc<AtomicBool>,
}

enum StdioFrameEvent {
    Payload(Vec<u8>),
    Eof,
    Error(io::Error),
}

enum TimedStdioFrame {
    Payload(Vec<u8>),
    Eof,
    Timeout,
}

#[derive(Debug, Clone)]
struct StdioCancellationToken {
    state: Arc<AtomicU8>,
}

impl StdioCancellationToken {
    fn new() -> Self {
        Self {
            state: Arc::new(AtomicU8::new(0)),
        }
    }

    fn cancel(&self) {
        self.state.store(1, Ordering::SeqCst);
    }

    fn disconnect(&self) {
        let _ = self
            .state
            .compare_exchange(0, 2, Ordering::SeqCst, Ordering::SeqCst);
    }

    fn was_explicitly_cancelled(&self) -> bool {
        self.state.load(Ordering::SeqCst) == 1
    }
}

impl BridgeCancellationToken for StdioCancellationToken {
    fn is_cancelled(&self) -> bool {
        self.state.load(Ordering::SeqCst) != 0
    }
}

#[derive(Debug, Default, Clone)]
struct ActiveStdioRequestCancellation {
    state: Arc<Mutex<ActiveStdioRequestCancellationState>>,
}

#[derive(Debug, Default)]
struct ActiveStdioRequestCancellationState {
    active: Vec<ActiveStdioRequest>,
    pending_cancel_ids: VecDeque<Value>,
}

#[derive(Debug, Clone)]
struct ActiveStdioRequest {
    id: Value,
    token: StdioCancellationToken,
}

#[derive(Debug)]
struct ActiveStdioRequestCancellationGuard {
    cancellation: ActiveStdioRequestCancellation,
    id: Value,
}

impl ActiveStdioRequestCancellation {
    fn new() -> Self {
        Self::default()
    }

    fn activate(
        &self,
        id: Value,
        token: StdioCancellationToken,
    ) -> ActiveStdioRequestCancellationGuard {
        let mut state = self
            .state
            .lock()
            .expect("stdio request cancellation state should not be poisoned");
        if remove_pending_cancel_id(&mut state.pending_cancel_ids, &id) {
            token.cancel();
        }
        state.active.push(ActiveStdioRequest {
            id: id.clone(),
            token,
        });
        ActiveStdioRequestCancellationGuard {
            cancellation: self.clone(),
            id,
        }
    }

    fn record_or_cancel_payload(&self, payload: &[u8]) -> bool {
        let Some(cancel_id) = cancel_notification_id(payload) else {
            return false;
        };
        let mut state = self
            .state
            .lock()
            .expect("stdio request cancellation state should not be poisoned");
        if let Some(active) = state.active.iter().find(|active| active.id == cancel_id) {
            active.token.cancel();
            return true;
        }
        insert_pending_cancel_id(&mut state.pending_cancel_ids, cancel_id);
        false
    }

    fn clear(&self, id: &Value) {
        let mut state = self
            .state
            .lock()
            .expect("stdio request cancellation state should not be poisoned");
        if let Some(index) = state.active.iter().position(|active| &active.id == id) {
            state.active.remove(index);
        }
    }

    fn cancel_all(&self) {
        let state = self
            .state
            .lock()
            .expect("stdio request cancellation state should not be poisoned");
        for active in &state.active {
            active.token.disconnect();
        }
    }
}

impl Drop for ActiveStdioRequestCancellationGuard {
    fn drop(&mut self) {
        self.cancellation.clear(&self.id);
    }
}

fn insert_pending_cancel_id(pending: &mut VecDeque<Value>, id: Value) {
    remove_pending_cancel_id(pending, &id);
    pending.push_back(id);
    while pending.len() > MAX_PENDING_CANCEL_REQUEST_IDS {
        pending.pop_front();
    }
}

fn remove_pending_cancel_id(pending: &mut VecDeque<Value>, id: &Value) -> bool {
    let Some(index) = pending.iter().position(|candidate| candidate == id) else {
        return false;
    };
    pending.remove(index);
    true
}

impl StdioFrameReceiver {
    fn spawn<R>(reader: R, remote_worker: Arc<dyn RemoteWorkerSupervisor>) -> io::Result<Self>
    where
        R: Read + Send + 'static,
    {
        let (sender, receiver) = mpsc::sync_channel(MAX_STDIN_FRAME_QUEUE);
        let active_cancellation = ActiveStdioRequestCancellation::new();
        let reader_active_cancellation = active_cancellation.clone();
        let connection_terminal = Arc::new(AtomicBool::new(false));
        let reader_connection_terminal = Arc::clone(&connection_terminal);
        let reader_thread = thread::Builder::new()
            .name("subversionr-stdio-reader".to_string())
            .spawn(move || {
                let mut reader = BufReader::new(reader);
                loop {
                    let event = match read_content_length_frame(&mut reader) {
                        Ok(Some(payload)) => {
                            if reader_active_cancellation.record_or_cancel_payload(&payload) {
                                continue;
                            }
                            StdioFrameEvent::Payload(payload)
                        }
                        Ok(None) => StdioFrameEvent::Eof,
                        Err(error) => StdioFrameEvent::Error(error),
                    };
                    let terminal =
                        matches!(event, StdioFrameEvent::Eof | StdioFrameEvent::Error(_));
                    if terminal {
                        reader_connection_terminal.store(true, Ordering::Release);
                        reader_active_cancellation.cancel_all();
                        let _ = remote_worker.disconnect();
                    }
                    if sender.send(event).is_err() || terminal {
                        break;
                    }
                }
            })?;

        Ok(Self {
            receiver,
            reader_thread: Some(reader_thread),
            terminal_consumed: false,
            retired_auth_request_ids: RetiredAuthRequestIds::new(),
            active_cancellation,
            connection_terminal,
        })
    }

    fn connection_terminal(&self) -> bool {
        self.connection_terminal.load(Ordering::Acquire)
    }

    fn activate_request_cancellation(
        &self,
        request_id: Value,
        token: StdioCancellationToken,
    ) -> ActiveStdioRequestCancellationGuard {
        self.active_cancellation.activate(request_id, token)
    }

    #[cfg(test)]
    fn recv(&mut self) -> io::Result<Option<Vec<u8>>> {
        loop {
            if self.terminal_consumed {
                return Ok(None);
            }
            match self.receiver.recv() {
                Ok(event) => match self.handle_event(event)? {
                    Some(payload) if self.consume_retired_auth_response(&payload) => continue,
                    result => return Ok(result),
                },
                Err(_) => return Err(reader_disconnected()),
            }
        }
    }

    fn recv_until(&mut self, deadline: Instant) -> io::Result<TimedStdioFrame> {
        loop {
            if self.terminal_consumed {
                return Ok(TimedStdioFrame::Eof);
            }
            let now = Instant::now();
            if now >= deadline {
                return Ok(TimedStdioFrame::Timeout);
            }
            match self.receiver.recv_timeout(deadline.duration_since(now)) {
                Ok(StdioFrameEvent::Payload(payload)) => {
                    if self.consume_retired_auth_response(&payload) {
                        continue;
                    }
                    return Ok(TimedStdioFrame::Payload(payload));
                }
                Ok(StdioFrameEvent::Eof) => {
                    self.consume_terminal_event();
                    return Ok(TimedStdioFrame::Eof);
                }
                Ok(StdioFrameEvent::Error(error)) => {
                    self.consume_terminal_event();
                    return Err(error);
                }
                Err(RecvTimeoutError::Timeout) => return Ok(TimedStdioFrame::Timeout),
                Err(RecvTimeoutError::Disconnected) => return Err(reader_disconnected()),
            }
        }
    }

    #[cfg(test)]
    fn handle_event(&mut self, event: StdioFrameEvent) -> io::Result<Option<Vec<u8>>> {
        match event {
            StdioFrameEvent::Payload(payload) => Ok(Some(payload)),
            StdioFrameEvent::Eof => {
                self.consume_terminal_event();
                Ok(None)
            }
            StdioFrameEvent::Error(error) => {
                self.consume_terminal_event();
                Err(error)
            }
        }
    }

    fn consume_terminal_event(&mut self) {
        self.terminal_consumed = true;
        if let Some(reader_thread) = self.reader_thread.take() {
            let _ = reader_thread.join();
        }
    }

    fn retire_auth_request_id(&mut self, request_id: &str) {
        self.retired_auth_request_ids.insert(request_id.to_string());
    }

    fn consume_retired_auth_response(&mut self, payload: &[u8]) -> bool {
        let Some(request_id) = retired_auth_response_id(payload) else {
            return false;
        };
        self.retired_auth_request_ids.remove(&request_id)
    }
}

#[derive(Debug, Default)]
struct RetiredAuthRequestIds {
    ids: VecDeque<String>,
}

impl RetiredAuthRequestIds {
    fn new() -> Self {
        Self {
            ids: VecDeque::new(),
        }
    }

    fn insert(&mut self, request_id: String) {
        self.remove(&request_id);
        self.ids.push_back(request_id);
        while self.ids.len() > MAX_RETIRED_AUTH_REQUEST_IDS {
            self.ids.pop_front();
        }
    }

    fn remove(&mut self, request_id: &str) -> bool {
        let Some(index) = self.ids.iter().position(|id| id == request_id) else {
            return false;
        };
        self.ids.remove(index);
        true
    }

    #[cfg(test)]
    fn len(&self) -> usize {
        self.ids.len()
    }

    #[cfg(test)]
    fn contains(&self, request_id: &str) -> bool {
        self.ids.iter().any(|id| id == request_id)
    }
}

fn retired_auth_response_id(payload: &[u8]) -> Option<String> {
    let value: Value = serde_json::from_slice(payload).ok()?;
    let object = value.as_object()?;
    if object.get("jsonrpc") != Some(&Value::String("2.0".to_string()))
        || object.contains_key("method")
    {
        return None;
    }
    object.get("id")?.as_str().map(str::to_string)
}

fn cancel_notification_id(payload: &[u8]) -> Option<Value> {
    let value: Value = serde_json::from_slice(payload).ok()?;
    let object = value.as_object()?;
    if object.get("jsonrpc") != Some(&Value::String("2.0".to_string()))
        || object.get("method") != Some(&Value::String("$/cancelRequest".to_string()))
        || object.contains_key("id")
    {
        return None;
    }
    object.get("params")?.as_object()?.get("id").cloned()
}

fn reader_disconnected() -> io::Error {
    io::Error::other("JSON-RPC stdio reader exited without a terminal frame event")
}

struct StdioAuthRequestBroker<'a, W>
where
    W: Write,
{
    frames: &'a mut StdioFrameReceiver,
    writer: &'a mut W,
    operation_cancellation: &'a StdioCancellationToken,
}

impl<W> AuthRequestBroker for StdioAuthRequestBroker<'_, W>
where
    W: Write,
{
    fn request_credential(
        &mut self,
        request: CredentialRequest,
    ) -> Result<CredentialResponse, BridgeFailure> {
        let safe_args = credential_safe_args(&request);
        let request_id = request.request_id.clone();
        let operation_id = request.operation_id.clone();
        let timeout_ms = request.timeout_ms;
        let response: CredentialResponse =
            self.round_trip("credentials/request", &request_id, timeout_ms, request)?;
        match &response {
            CredentialResponse::Provide {
                request_id: response_request_id,
                operation_id: response_operation_id,
                ..
            } if response_request_id == &request_id && response_operation_id == &operation_id => {
                Ok(response)
            }
            CredentialResponse::Cancel {
                request_id: response_request_id,
                operation_id: response_operation_id,
                error,
            } if response_request_id == &request_id && response_operation_id == &operation_id => {
                match credential_error_to_bridge(error, safe_args) {
                    Some(failure) => Err(failure),
                    None => Err(auth_response_invalid("credentials/request")),
                }
            }
            _ => Err(auth_response_invalid("credentials/request")),
        }
    }

    fn settle_credential(
        &mut self,
        request: CredentialSettlementRequest,
    ) -> Result<CredentialSettlementAck, BridgeFailure> {
        let request_id = request.request_id.clone();
        let operation_id = request.operation_id.clone();
        let lease_id = request.lease_id.clone();
        let outcome = request.outcome;
        let timeout_ms = request.timeout_ms;
        let response: CredentialSettlementAck =
            self.round_trip("credentials/settle", &request_id, timeout_ms, request)?;
        if response.request_id == request_id
            && response.operation_id == operation_id
            && response.lease_id == lease_id
            && response.outcome == outcome
        {
            Ok(response)
        } else {
            Err(auth_response_invalid("credentials/settle"))
        }
    }

    fn request_certificate_trust(
        &mut self,
        request: CertificateTrustRequest,
    ) -> Result<CertificateTrustResponse, BridgeFailure> {
        if !request.interactive || request.origin != "foreground" {
            return Err(auth_certificate_non_interactive());
        }
        let safe_args = certificate_safe_args(&request);
        let request_id = request.request_id.clone();
        let fingerprint = request.fingerprint.clone();
        let fingerprint_algorithm = request.fingerprint_algorithm.clone();
        let timeout_ms = request.timeout_ms;
        let response: CertificateTrustResponse =
            self.round_trip("certificate/request", &request_id, timeout_ms, request)?;
        match &response {
            CertificateTrustResponse::Trust {
                request_id: response_request_id,
                fingerprint: response_fingerprint,
                fingerprint_algorithm: response_fingerprint_algorithm,
                ..
            } if response_request_id == &request_id
                && response_fingerprint == &fingerprint
                && response_fingerprint_algorithm == &fingerprint_algorithm =>
            {
                Ok(response)
            }
            CertificateTrustResponse::Reject {
                request_id: response_request_id,
                error,
            } if response_request_id == &request_id => {
                match certificate_error_to_bridge(error, safe_args) {
                    Some(failure) => Err(failure),
                    None => Err(auth_response_invalid("certificate/request")),
                }
            }
            _ => Err(auth_response_invalid("certificate/request")),
        }
    }
}

impl<W> StdioAuthRequestBroker<'_, W>
where
    W: Write,
{
    fn round_trip<TRequest, TResponse>(
        &mut self,
        auth_method: &str,
        request_id: &str,
        timeout_ms: u64,
        request: TRequest,
    ) -> Result<TResponse, BridgeFailure>
    where
        TRequest: serde::Serialize,
        TResponse: DeserializeOwned,
    {
        let message = json!({
            "jsonrpc": "2.0",
            "id": request_id,
            "method": auth_method,
            "params": request,
        });
        write_content_length_frame(self.writer, &message)
            .and_then(|()| self.writer.flush())
            .map_err(|_| auth_request_failed(auth_method))?;

        let deadline = auth_deadline(timeout_ms, auth_method)?;
        let mut inbound_messages = 0usize;
        loop {
            if self.operation_cancellation.was_explicitly_cancelled() {
                self.frames.retire_auth_request_id(request_id);
                return Err(auth_cancelled(auth_method));
            }
            if auth_deadline_expired(deadline) {
                self.frames.retire_auth_request_id(request_id);
                return Err(auth_timeout(auth_method));
            }
            let wait_deadline = deadline.min(Instant::now() + Duration::from_millis(5));
            let payload = match self.frames.recv_until(wait_deadline) {
                Ok(TimedStdioFrame::Payload(payload)) => payload,
                Ok(TimedStdioFrame::Timeout) => {
                    continue;
                }
                Ok(TimedStdioFrame::Eof) => {
                    return Err(if self.operation_cancellation.was_explicitly_cancelled() {
                        auth_cancelled(auth_method)
                    } else {
                        auth_response_unavailable(auth_method)
                    });
                }
                Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => {
                    return Err(auth_response_unavailable(auth_method));
                }
                Err(_) => return Err(auth_response_invalid(auth_method)),
            };
            if auth_deadline_expired(deadline) {
                self.frames.retire_auth_request_id(request_id);
                return Err(auth_timeout(auth_method));
            }
            let response: Value =
                serde_json::from_slice(&payload).map_err(|_| auth_response_invalid(auth_method))?;
            let Some(object) = response.as_object() else {
                return Err(auth_response_invalid(auth_method));
            };
            if object.get("jsonrpc") != Some(&Value::String("2.0".to_string())) {
                return Err(auth_response_invalid(auth_method));
            }

            if let Some(inbound_method) = object.get("method") {
                inbound_messages += 1;
                if inbound_messages > MAX_AUTH_WAIT_INBOUND_MESSAGES {
                    self.frames.retire_auth_request_id(request_id);
                    return Err(auth_request_flood(auth_method));
                }
                self.handle_auth_wait_request(
                    auth_method,
                    request_id,
                    inbound_method,
                    object.get("id"),
                    object.get("params"),
                )?;
                continue;
            }

            if object.get("id") != Some(&Value::String(request_id.to_string())) {
                return Err(auth_response_invalid(auth_method));
            }
            let has_result = object.contains_key("result");
            let has_error = object.contains_key("error");
            match (has_result, has_error) {
                (true, false) => {
                    let result = object
                        .get("result")
                        .expect("contains_key verified result presence");
                    return serde_json::from_value(result.clone())
                        .map_err(|_| auth_response_invalid(auth_method));
                }
                (false, true) => {
                    let error = object
                        .get("error")
                        .expect("contains_key verified error presence");
                    match parse_auth_json_rpc_error(error, auth_method) {
                        Some(AuthJsonRpcErrorKind::Cancelled) => {
                            return Err(auth_cancelled(auth_method));
                        }
                        Some(AuthJsonRpcErrorKind::Rejected) => {
                            return Err(auth_response_rejected(auth_method));
                        }
                        Some(AuthJsonRpcErrorKind::Structured(failure)) => {
                            return Err(failure);
                        }
                        None => return Err(auth_response_invalid(auth_method)),
                    }
                }
                _ => return Err(auth_response_invalid(auth_method)),
            }
        }
    }

    fn handle_auth_wait_request(
        &mut self,
        auth_method: &str,
        request_id: &str,
        inbound_method: &Value,
        inbound_id: Option<&Value>,
        params: Option<&Value>,
    ) -> Result<(), BridgeFailure> {
        let Some(method) = inbound_method.as_str() else {
            return Err(auth_response_invalid(auth_method));
        };
        if method == "$/cancelRequest" && inbound_id.is_none() {
            if cancel_notification_matches(params, request_id) {
                self.frames.retire_auth_request_id(request_id);
                return Err(auth_cancelled(auth_method));
            }
            return Ok(());
        }

        let Some(id) = inbound_id else {
            return Ok(());
        };
        write_auth_request_pending_response(self.writer, id, auth_method)
            .and_then(|()| self.writer.flush())
            .map_err(|_| auth_request_failed(auth_method))
    }
}

fn auth_request_failed(method: &str) -> BridgeFailure {
    BridgeFailure::new(
        "SUBVERSIONR_AUTH_REQUEST_FAILED",
        "auth",
        "error.auth.requestFailed",
        json!({ "method": method }),
        false,
    )
}

fn auth_certificate_non_interactive() -> BridgeFailure {
    BridgeFailure::new(
        "SUBVERSIONR_CERTIFICATE_NON_INTERACTIVE",
        "auth",
        "error.auth.certificateNonInteractive",
        json!({ "method": "certificate/request" }),
        false,
    )
}

fn auth_cancelled(method: &str) -> BridgeFailure {
    BridgeFailure::new(
        "SUBVERSIONR_AUTH_CANCELLED",
        "cancelled",
        "error.auth.cancelled",
        json!({ "method": method }),
        false,
    )
}

fn auth_timeout(method: &str) -> BridgeFailure {
    BridgeFailure::new(
        "SUBVERSIONR_AUTH_TIMEOUT",
        "auth",
        "error.auth.timeout",
        json!({ "method": method }),
        false,
    )
}

fn auth_request_flood(method: &str) -> BridgeFailure {
    BridgeFailure::new(
        "SUBVERSIONR_AUTH_REQUEST_FLOOD",
        "auth",
        "error.auth.requestFlood",
        json!({ "method": method }),
        false,
    )
}

fn auth_response_invalid(method: &str) -> BridgeFailure {
    BridgeFailure::new(
        "SUBVERSIONR_AUTH_RESPONSE_INVALID",
        "auth",
        "error.auth.responseInvalid",
        json!({ "method": method }),
        false,
    )
}

fn auth_deadline(timeout_ms: u64, method: &str) -> Result<Instant, BridgeFailure> {
    Instant::now()
        .checked_add(Duration::from_millis(timeout_ms))
        .ok_or_else(|| auth_response_invalid(method))
}

fn auth_deadline_expired(deadline: Instant) -> bool {
    Instant::now() >= deadline
}

fn auth_response_unavailable(method: &str) -> BridgeFailure {
    BridgeFailure::new(
        "SUBVERSIONR_AUTH_RESPONSE_UNAVAILABLE",
        "auth",
        "error.auth.responseUnavailable",
        json!({ "method": method }),
        false,
    )
}

fn auth_response_rejected(method: &str) -> BridgeFailure {
    BridgeFailure::new(
        "SUBVERSIONR_AUTH_RESPONSE_REJECTED",
        "auth",
        "error.auth.responseRejected",
        json!({ "method": method }),
        false,
    )
}

fn credential_error_to_bridge(error: &CredentialError, safe_args: Value) -> Option<BridgeFailure> {
    if !credential_error_contract_is_allowed(error) {
        return None;
    }
    Some(BridgeFailure::new(
        error.code.clone(),
        error.category.clone(),
        error.message_key.clone(),
        safe_args,
        false,
    ))
}

fn certificate_error_to_bridge(
    error: &CertificateTrustError,
    safe_args: Value,
) -> Option<BridgeFailure> {
    if !certificate_error_contract_is_allowed(error) {
        return None;
    }
    Some(BridgeFailure::new(
        error.code.clone(),
        error.category.clone(),
        error.message_key.clone(),
        safe_args,
        false,
    ))
}

fn credential_error_contract_is_allowed(error: &CredentialError) -> bool {
    !error.retryable
        && matches!(
            (
                error.code.as_str(),
                error.category.as_str(),
                error.message_key.as_str(),
            ),
            (
                "SUBVERSIONR_CREDENTIAL_UNTRUSTED_WORKSPACE",
                "lifecycle",
                "error.auth.credentialUntrustedWorkspace"
            ) | (
                "SUBVERSIONR_CREDENTIAL_NON_INTERACTIVE",
                "auth",
                "error.auth.credentialNonInteractive"
            ) | (
                "SUBVERSIONR_CREDENTIAL_TIMEOUT",
                "auth",
                "error.auth.credentialTimeout"
            ) | (
                "SUBVERSIONR_CREDENTIAL_CANCELLED",
                "auth",
                "error.auth.credentialCancelled"
            ) | (
                "SUBVERSIONR_CREDENTIAL_LEGACY_BLOCKED",
                "auth",
                "error.auth.credentialLegacyBlocked"
            ) | (
                "SUBVERSIONR_CREDENTIAL_LEGACY_CLEAR_DECLINED",
                "auth",
                "error.auth.credentialLegacyClearDeclined"
            ) | (
                "SUBVERSIONR_CREDENTIAL_ACCOUNT_UNAVAILABLE",
                "auth",
                "error.auth.credentialAccountUnavailable"
            ) | (
                "SUBVERSIONR_CREDENTIAL_RETRY_INVALID",
                "auth",
                "error.auth.credentialRetryInvalid"
            ) | (
                "SUBVERSIONR_CREDENTIAL_STORAGE_INTEGRITY",
                "auth",
                "error.auth.credentialStorageIntegrity"
            ) | (
                "SUBVERSIONR_CREDENTIAL_SECRET_INVALID",
                "auth",
                "error.auth.credentialSecretInvalid"
            ) | (
                "SUBVERSIONR_CREDENTIAL_LEASE_UNKNOWN",
                "auth",
                "error.auth.credentialLeaseUnknown"
            ) | (
                "SUBVERSIONR_CREDENTIAL_LEASE_FOREIGN",
                "auth",
                "error.auth.credentialLeaseForeign"
            ) | (
                "SUBVERSIONR_CREDENTIAL_LEASE_EXPIRED",
                "auth",
                "error.auth.credentialLeaseExpired"
            ) | (
                "SUBVERSIONR_CREDENTIAL_SETTLEMENT_CONFLICT",
                "auth",
                "error.auth.credentialSettlementConflict"
            )
        )
}

fn certificate_error_contract_is_allowed(error: &CertificateTrustError) -> bool {
    !error.retryable
        && matches!(
            (
                error.code.as_str(),
                error.category.as_str(),
                error.message_key.as_str(),
            ),
            (
                "SUBVERSIONR_CERTIFICATE_UNTRUSTED_WORKSPACE",
                "lifecycle",
                "error.auth.certificateUntrustedWorkspace"
            ) | (
                "SUBVERSIONR_CERTIFICATE_REALM_REQUIRED",
                "auth",
                "error.auth.certificateRealmRequired"
            ) | (
                "SUBVERSIONR_CERTIFICATE_FINGERPRINT_ALGORITHM_UNSUPPORTED",
                "auth",
                "error.auth.certificateFingerprintAlgorithmUnsupported"
            ) | (
                "SUBVERSIONR_CERTIFICATE_CHANGED",
                "auth",
                "error.auth.certificateChanged"
            ) | (
                "SUBVERSIONR_CERTIFICATE_NON_INTERACTIVE",
                "auth",
                "error.auth.certificateNonInteractive"
            ) | (
                "SUBVERSIONR_CERTIFICATE_TIMEOUT",
                "auth",
                "error.auth.certificateTimeout"
            ) | (
                "SUBVERSIONR_CERTIFICATE_CANCELLED",
                "auth",
                "error.auth.certificateCancelled"
            ) | (
                "SUBVERSIONR_CERTIFICATE_REJECTED",
                "auth",
                "error.auth.certificateRejected"
            ) | (
                "SUBVERSIONR_CERTIFICATE_PERSISTENCE_DISALLOWED",
                "auth",
                "error.auth.certificatePersistenceDisallowed"
            ) | (
                "SUBVERSIONR_CERTIFICATE_STORE_INVALID",
                "auth",
                "error.auth.certificateStoreInvalid"
            )
        )
}

fn credential_safe_args(request: &CredentialRequest) -> Value {
    json!({
        "authorityHash": credential_authority_hash(request),
        "authKind": request.auth_kind,
        "attempt": request.attempt,
        "origin": request.origin,
    })
}

fn credential_authority_hash(request: &CredentialRequest) -> String {
    let mut hasher = Sha256::new();
    hasher.update(serde_json::to_vec(&request.endpoint).expect("endpoint serialization"));
    hasher.update([0]);
    hasher.update(serde_json::to_vec(&request.auth_kind).expect("auth kind serialization"));
    hasher.update([0]);
    hasher.update(request.realm.as_bytes());
    hex_digest(hasher.finalize())
}

fn hex_digest(digest: impl AsRef<[u8]>) -> String {
    digest
        .as_ref()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn certificate_safe_args(request: &CertificateTrustRequest) -> Value {
    json!({
        "realmHash": auth_realm_hash("certificate", &request.realm),
        "fingerprint": request.fingerprint,
        "fingerprintAlgorithm": request.fingerprint_algorithm,
        "failureCount": request.failures.len(),
        "origin": request.origin,
    })
}

fn auth_realm_hash(kind: &str, realm: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(kind.as_bytes());
    hasher.update([0]);
    hasher.update(realm.as_bytes());
    hex_digest(hasher.finalize())
}

fn cancel_notification_matches(params: Option<&Value>, request_id: &str) -> bool {
    params.and_then(|value| value.get("id")) == Some(&Value::String(request_id.to_string()))
}

enum AuthJsonRpcErrorKind {
    Cancelled,
    Rejected,
    Structured(BridgeFailure),
}

fn parse_auth_json_rpc_error(error: &Value, method: &str) -> Option<AuthJsonRpcErrorKind> {
    let object = error.as_object()?;
    if let Some(code) = object.get("code").and_then(Value::as_i64) {
        object.get("message")?.as_str()?;
        return Some(if code == -32800 {
            AuthJsonRpcErrorKind::Cancelled
        } else {
            AuthJsonRpcErrorKind::Rejected
        });
    }
    if object.len() != 6
        || object.get("retryable") != Some(&Value::Bool(false))
        || object.get("diagnostics") != Some(&Value::Null)
    {
        return None;
    }
    let code = object.get("code")?.as_str()?;
    let category = object.get("category")?.as_str()?;
    let message_key = object.get("messageKey")?.as_str()?;
    let args = object.get("args")?.as_object()?.clone();
    let credential_error = CredentialError {
        code: code.to_string(),
        category: category.to_string(),
        message_key: message_key.to_string(),
        args: Value::Object(args.clone()),
        retryable: false,
    };
    let safe_args = match method {
        "credentials/request"
            if !credential_settlement_error_code(code)
                && credential_error_contract_is_allowed(&credential_error)
                && args.is_empty() =>
        {
            json!({})
        }
        "credentials/settle"
            if credential_settlement_error_code(code)
                && credential_error_contract_is_allowed(&credential_error) =>
        {
            strict_credential_settlement_error_args(code, &args)?
        }
        _ => return None,
    };
    Some(AuthJsonRpcErrorKind::Structured(BridgeFailure::new(
        code,
        category,
        message_key,
        safe_args,
        false,
    )))
}

fn credential_settlement_error_code(code: &str) -> bool {
    matches!(
        code,
        "SUBVERSIONR_CREDENTIAL_UNTRUSTED_WORKSPACE"
            | "SUBVERSIONR_CREDENTIAL_TIMEOUT"
            | "SUBVERSIONR_CREDENTIAL_LEASE_UNKNOWN"
            | "SUBVERSIONR_CREDENTIAL_LEASE_FOREIGN"
            | "SUBVERSIONR_CREDENTIAL_LEASE_EXPIRED"
            | "SUBVERSIONR_CREDENTIAL_SETTLEMENT_CONFLICT"
    )
}

fn strict_credential_settlement_error_args(
    code: &str,
    args: &serde_json::Map<String, Value>,
) -> Option<Value> {
    let operation_hash = args.get("operationHash")?.as_str()?;
    let lease_hash = args.get("leaseHash")?.as_str()?;
    if !is_lowercase_sha256(operation_hash) || !is_lowercase_sha256(lease_hash) {
        return None;
    }
    if code == "SUBVERSIONR_CREDENTIAL_UNTRUSTED_WORKSPACE" {
        return (args.len() == 2).then(|| {
            json!({
                "operationHash": operation_hash,
                "leaseHash": lease_hash,
            })
        });
    }
    if args.len() != 3 {
        return None;
    }
    let outcome = args.get("outcome")?.as_str()?;
    matches!(
        outcome,
        "accepted" | "rejected" | "unused" | "cancelled" | "timedOut"
    )
    .then(|| {
        json!({
            "operationHash": operation_hash,
            "leaseHash": lease_hash,
            "outcome": outcome,
        })
    })
}

fn is_lowercase_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn write_auth_request_pending_response<W>(
    writer: &mut W,
    id: &Value,
    pending_method: &str,
) -> io::Result<()>
where
    W: Write,
{
    let response = json!({
        "jsonrpc": "2.0",
        "id": id,
        "error": rpc_error(
            "SUBVERSIONR_AUTH_REQUEST_PENDING",
            "auth",
            "error.auth.requestPending",
            json!({ "pendingMethod": pending_method }),
            false,
        ),
    });
    write_content_length_frame(writer, &response)
}

fn read_content_length_frame<R>(reader: &mut R) -> io::Result<Option<Vec<u8>>>
where
    R: BufRead,
{
    let mut content_length = None;
    let mut read_any_header = false;
    let mut total_header_bytes = 0usize;
    let mut header_error = None;

    loop {
        let line = read_bounded_header_line(reader)?;
        let bytes_read = line.len();
        if bytes_read == 0 {
            if read_any_header {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "unexpected EOF inside Content-Length header",
                ));
            }
            return Ok(None);
        }

        read_any_header = true;
        total_header_bytes += bytes_read;
        if total_header_bytes > MAX_JSON_RPC_HEADER_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "JSON-RPC frame header is too large",
            ));
        }
        let line = String::from_utf8(line)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
        let header = line.trim_end_matches(['\r', '\n']);
        if header.is_empty() {
            break;
        }
        if header_error.is_some() {
            continue;
        }
        if content_length.is_some() {
            header_error = Some(io::Error::new(
                io::ErrorKind::InvalidData,
                "duplicate Content-Length JSON-RPC frame header",
            ));
            continue;
        }

        let Some(length_text) = header.strip_prefix("Content-Length: ") else {
            header_error = Some(io::Error::new(
                io::ErrorKind::InvalidData,
                "unsupported JSON-RPC frame header",
            ));
            continue;
        };
        let length = match length_text.parse::<usize>() {
            Ok(length) => length,
            Err(error) => {
                header_error = Some(io::Error::new(io::ErrorKind::InvalidData, error));
                continue;
            }
        };
        if length > MAX_JSON_RPC_FRAME_BYTES {
            header_error = Some(io::Error::new(
                io::ErrorKind::InvalidData,
                "JSON-RPC frame payload is too large",
            ));
            continue;
        }
        content_length = Some(length);
    }

    if let Some(error) = header_error {
        return Err(error);
    }

    let length = content_length.ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "missing Content-Length JSON-RPC frame header",
        )
    })?;
    let mut payload = vec![0; length];
    reader.read_exact(&mut payload)?;
    Ok(Some(payload))
}

fn read_bounded_header_line<R>(reader: &mut R) -> io::Result<Vec<u8>>
where
    R: BufRead,
{
    let mut line = Vec::new();
    loop {
        let available = reader.fill_buf()?;
        if available.is_empty() {
            return Ok(line);
        }

        let newline_index = available.iter().position(|byte| *byte == b'\n');
        let bytes_to_take = newline_index.map_or(available.len(), |index| index + 1);
        if line.len() + bytes_to_take > MAX_JSON_RPC_HEADER_LINE_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "JSON-RPC frame header line is too large",
            ));
        }

        line.extend_from_slice(&available[..bytes_to_take]);
        reader.consume(bytes_to_take);
        if newline_index.is_some() {
            return Ok(line);
        }
    }
}

fn write_content_length_frame<W>(writer: &mut W, response: &serde_json::Value) -> io::Result<()>
where
    W: Write,
{
    let payload = serde_json::to_vec(response)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    write!(writer, "Content-Length: {}\r\n\r\n", payload.len())?;
    writer.write_all(&payload)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn disconnected_frame_receiver_is_not_eof() {
        let (_sender, receiver) = mpsc::sync_channel(1);
        drop(_sender);
        let mut frames = StdioFrameReceiver {
            receiver,
            reader_thread: None,
            terminal_consumed: false,
            retired_auth_request_ids: RetiredAuthRequestIds::new(),
            active_cancellation: ActiveStdioRequestCancellation::new(),
            connection_terminal: Arc::new(AtomicBool::new(false)),
        };

        let error = frames
            .recv()
            .expect_err("implicit reader disconnect should surface as an IO error");

        assert_eq!(error.kind(), io::ErrorKind::Other);

        let (_sender, receiver) = mpsc::sync_channel(1);
        drop(_sender);
        let mut frames = StdioFrameReceiver {
            receiver,
            reader_thread: None,
            terminal_consumed: false,
            retired_auth_request_ids: RetiredAuthRequestIds::new(),
            active_cancellation: ActiveStdioRequestCancellation::new(),
            connection_terminal: Arc::new(AtomicBool::new(false)),
        };

        let error = match frames.recv_until(Instant::now() + Duration::from_millis(1)) {
            Err(error) => error,
            Ok(_) => panic!("timed reader receive should not classify disconnect as EOF"),
        };

        assert_eq!(error.kind(), io::ErrorKind::Other);
    }

    #[test]
    fn retired_auth_request_ids_are_bounded_and_evict_oldest_entries() {
        let (_sender, receiver) = mpsc::sync_channel(1);
        drop(_sender);
        let mut frames = StdioFrameReceiver {
            receiver,
            reader_thread: None,
            terminal_consumed: false,
            retired_auth_request_ids: RetiredAuthRequestIds::new(),
            active_cancellation: ActiveStdioRequestCancellation::new(),
            connection_terminal: Arc::new(AtomicBool::new(false)),
        };

        for index in 0..=MAX_RETIRED_AUTH_REQUEST_IDS {
            frames.retire_auth_request_id(&format!("retired-{index}"));
        }

        assert_eq!(
            frames.retired_auth_request_ids.len(),
            MAX_RETIRED_AUTH_REQUEST_IDS
        );
        assert!(!frames.retired_auth_request_ids.contains("retired-0"));
        assert!(frames.retired_auth_request_ids.contains("retired-1"));
        assert!(
            frames
                .retired_auth_request_ids
                .contains(&format!("retired-{MAX_RETIRED_AUTH_REQUEST_IDS}"))
        );
    }
}
