import type { RemoteScheme } from "../security/remoteAccessProfile";
import type { DaemonRemoteConnectionState } from "./remoteConnectionNotificationHandler";

export type RemoteAttentionReason =
  | "authRequired"
  | "certificateRequired"
  | "hostKeyRequired"
  | "configurationInvalid"
  | "unsupportedCapability";

export type RemoteUnreachableReason = "dns" | "refused" | "proxy" | "timeout" | "tunnel";
export type RemoteIndeterminateReason = "cancelledAfterMutation" | "workerTerminated";

export type NativeRemoteFailureReason =
  | "networkDns"
  | "networkRefused"
  | "networkTimeout"
  | "proxyAuthenticationRequired"
  | "proxyUnreachable"
  | "tlsUntrusted"
  | "tlsChanged"
  | "tlsProtocol"
  | "authenticationRequired"
  | "authorizationDenied"
  | "sshHostKeyRequired"
  | "sshHostKeyChanged"
  | "sshTunnelFailed"
  | "operationCancelled"
  | "operationDeadlineExceeded"
  | "redirectRejected"
  | "crossAuthorityRejected"
  | "credentialRejected"
  | "sshExecutableInvalid"
  | "sshProvenanceInvalid"
  | "sshTunnelCleanupFailed"
  | "workerContainmentFailed"
  | "remoteRecoveryBlocked"
  | "remoteConfigurationInvalid"
  | "remoteCapabilityUnsupported"
  | "remoteOperationIndeterminate"
  | "unknownRemote";

export interface NativeRemoteFailure {
  category: "attention" | "unreachable" | "indeterminate" | "cancelled";
  reason: NativeRemoteFailureReason;
  cleanupAppropriate: boolean;
}

export type WireRemoteFailureCategory =
  | "network" | "proxy" | "tls" | "authentication" | "authorization" | "ssh"
  | "cancellation" | "deadline" | "policy" | "credential" | "process" | "recovery"
  | "configuration" | "capability" | "unknown";

export interface WireRemoteFailure {
  category: WireRemoteFailureCategory;
  reason: NativeRemoteFailureReason;
  cleanupAppropriate: boolean;
}

export type RemoteRecoveryState =
  | { kind: "notRequired" }
  | { kind: "required"; operationId: string; requiredAt: string }
  | { kind: "checking"; operationId: string; originOperationId: string; startedAt: string; deadlineAt: string }
  | { kind: "safe"; operationId: string; completedAt: string }
  | { kind: "blocked"; operationId: string; completedAt: string; reason: "remoteRecoveryBlocked" };

export interface IncomingRemoteFreshness {
  kind: "unchecked" | "fresh" | "stale";
  lastSuccessfulCheckAt?: string;
}

export interface RemoteFailureRecord {
  reason: NativeRemoteFailureReason;
  cleanupAppropriate: boolean;
  occurredAt: string;
}

interface RemoteConnectionStateBase {
  repositoryId: string;
  epoch: number;
  incoming: IncomingRemoteFreshness;
  recovery: RemoteRecoveryState;
  lastFailure?: RemoteFailureRecord;
}

export type RemoteConnectionState =
  | (RemoteConnectionStateBase & { kind: "unchecked" })
  | (RemoteConnectionStateBase & { kind: "checking"; operationId: string; startedAt: string })
  | (RemoteConnectionStateBase & { kind: "online"; transport: RemoteScheme; checkedAt: string })
  | (RemoteConnectionStateBase & { kind: "attention"; reason: RemoteAttentionReason })
  | (RemoteConnectionStateBase & { kind: "unreachable"; reason: RemoteUnreachableReason })
  | (RemoteConnectionStateBase & { kind: "indeterminate"; reason: RemoteIndeterminateReason });

export interface RemoteConnectionRepository {
  repositoryId: string;
  epoch: number;
}

export interface RemoteConnectionStateSubscription {
  dispose(): void;
}

export type RemoteConnectionStateApplyResult =
  | { applied: true; state: RemoteConnectionState }
  | { applied: false; state: RemoteConnectionState | undefined };

export class RemoteConnectionStateStoreError extends Error {
  public constructor(
    public readonly code: string,
    public readonly category: "input" | "lifecycle" | "protocol",
    public readonly messageKey: string,
    public readonly safeArgs: Readonly<Record<string, unknown>> = {},
  ) {
    super(code);
    this.name = "RemoteConnectionStateStoreError";
  }
}

export class RemoteConnectionStateStore {
  private readonly repositories = new Map<string, RemoteConnectionState>();
  private readonly listeners = new Set<(state: RemoteConnectionState) => void>();

  public onDidChange(listener: (state: RemoteConnectionState) => void): RemoteConnectionStateSubscription {
    this.listeners.add(listener);
    return { dispose: () => this.listeners.delete(listener) };
  }

  public registerRepository(repository: RemoteConnectionRepository): RemoteConnectionState {
    validateRepository(repository);
    if (this.repositories.has(repository.repositoryId)) {
      throw lifecycleError("SUBVERSIONR_REMOTE_STATE_REPOSITORY_ALREADY_REGISTERED", repository.repositoryId);
    }
    const state: RemoteConnectionState = {
      kind: "unchecked",
      repositoryId: repository.repositoryId,
      epoch: repository.epoch,
      incoming: { kind: "unchecked" },
      recovery: { kind: "notRequired" },
    };
    this.repositories.set(repository.repositoryId, state);
    this.fire(state);
    return cloneState(state);
  }

  public unregisterRepository(repositoryId: string): void {
    this.repositories.delete(repositoryId);
  }

  public rebindRepository(repository: RemoteConnectionRepository): RemoteConnectionState {
    validateRepository(repository);
    const current = this.repositories.get(repository.repositoryId);
    if (!current) {
      throw lifecycleError("SUBVERSIONR_REMOTE_STATE_REPOSITORY_NOT_REGISTERED", repository.repositoryId);
    }
    if (current.epoch === repository.epoch) {
      throw lifecycleError("SUBVERSIONR_REMOTE_STATE_REPOSITORY_EPOCH_UNCHANGED", repository.repositoryId);
    }
    if (current.kind === "indeterminate" && current.recovery.kind !== "notRequired" && current.recovery.kind !== "safe") {
      const recovery: RemoteRecoveryState = current.recovery.kind === "checking"
        ? {
            kind: "required",
            operationId: current.recovery.originOperationId,
            requiredAt: current.recovery.startedAt,
          }
        : cloneRecovery(current.recovery);
      return this.update({
        ...cloneState(current),
        epoch: repository.epoch,
        incoming: staleIncoming(current.incoming),
        recovery,
      });
    }
    return this.update({
      kind: "unchecked",
      repositoryId: repository.repositoryId,
      epoch: repository.epoch,
      incoming: staleIncoming(current.incoming),
      recovery: { kind: "notRequired" },
      ...(current.lastFailure ? { lastFailure: { ...current.lastFailure } } : {}),
    });
  }

  public beginCheck(input: {
    repositoryId: string;
    epoch: number;
    operationId: string;
    startedAt: string;
  }): RemoteConnectionState {
    validateOperation(input);
    const current = this.requireRepository(input.repositoryId, input.epoch);
    if (current.kind === "checking") {
      throw new RemoteConnectionStateStoreError(
        "SUBVERSIONR_REMOTE_STATE_CHECK_IN_PROGRESS",
        "lifecycle",
        "error.remote.checkInProgress",
        { repositoryId: input.repositoryId },
      );
    }
    if (current.recovery.kind === "required" || current.recovery.kind === "checking" || current.recovery.kind === "blocked") {
      throw new RemoteConnectionStateStoreError(
        "SUBVERSIONR_REMOTE_STATE_RECOVERY_REQUIRED",
        "lifecycle",
        "error.remote.recoveryRequired",
        { repositoryId: input.repositoryId, recovery: current.recovery.kind },
      );
    }
    return this.update({
      kind: "checking",
      repositoryId: input.repositoryId,
      epoch: input.epoch,
      operationId: input.operationId,
      startedAt: input.startedAt,
      incoming: cloneIncoming(current.incoming),
      recovery: cloneRecovery(current.recovery),
      ...(current.lastFailure ? { lastFailure: { ...current.lastFailure } } : {}),
    });
  }

  public completeOnline(input: {
    repositoryId: string;
    epoch: number;
    operationId: string;
    transport: RemoteScheme;
    checkedAt: string;
    incomingApplied: boolean;
  }): RemoteConnectionStateApplyResult {
    validateOperation({ ...input, startedAt: input.checkedAt });
    const transport = validateTransport(input.transport);
    if (typeof input.incomingApplied !== "boolean") {
      throw inputError("incomingApplied");
    }
    const current = this.currentRepository(input.repositoryId, input.epoch);
    if (!current) {
      return { applied: false, state: undefined };
    }
    if (!isCurrentCheck(current, input.operationId)) {
      return { applied: false, state: cloneState(current) };
    }
    const state = this.update({
      kind: "online",
      repositoryId: input.repositoryId,
      epoch: input.epoch,
      transport,
      checkedAt: input.checkedAt,
      incoming: input.incomingApplied
        ? { kind: "fresh", lastSuccessfulCheckAt: input.checkedAt }
        : staleIncoming(current.incoming),
      recovery: { kind: "notRequired" },
    });
    return { applied: true, state };
  }

  public completeFailure(input: {
    repositoryId: string;
    epoch: number;
    operationId: string;
    failedAt: string;
    failure: NativeRemoteFailure;
    workingCopyRecoveryRequired: boolean;
  }): RemoteConnectionStateApplyResult {
    validateOperation({ ...input, startedAt: input.failedAt });
    if (typeof input.workingCopyRecoveryRequired !== "boolean") {
      throw inputError("workingCopyRecoveryRequired");
    }
    const failure = validateNativeRemoteFailure(input.failure);
    const current = this.currentRepository(input.repositoryId, input.epoch);
    if (!current) {
      return { applied: false, state: undefined };
    }
    if (!isCurrentCheck(current, input.operationId)) {
      return { applied: false, state: cloneState(current) };
    }
    const common = {
      repositoryId: input.repositoryId,
      epoch: input.epoch,
      incoming: staleIncoming(current.incoming),
      lastFailure: {
        reason: failure.reason,
        cleanupAppropriate: failure.cleanupAppropriate,
        occurredAt: input.failedAt,
      },
    } as const;
    if (input.workingCopyRecoveryRequired) {
      return {
        applied: true,
        state: this.update({
          ...common,
          kind: "indeterminate",
          reason: failure.reason === "operationCancelled" ? "cancelledAfterMutation" : "workerTerminated",
          recovery: { kind: "required", operationId: input.operationId, requiredAt: input.failedAt },
        }),
      };
    }
    if (failure.category === "cancelled" || failure.reason === "unknownRemote") {
      return {
        applied: true,
        state: this.update({ ...common, kind: "unchecked", recovery: { kind: "notRequired" } }),
      };
    }
    if (failure.category === "attention") {
      return {
        applied: true,
        state: this.update({
          ...common,
          kind: "attention",
          reason: attentionReason(failure.reason),
          recovery: { kind: "notRequired" },
        }),
      };
    }
    if (failure.category === "unreachable") {
      return {
        applied: true,
        state: this.update({
          ...common,
          kind: "unreachable",
          reason: unreachableReason(failure.reason),
          recovery: { kind: "notRequired" },
        }),
      };
    }
    return {
      applied: true,
      state: this.update({
        ...common,
        kind: "indeterminate",
        reason: indeterminateReason(failure.reason),
        recovery: { kind: "notRequired" },
      }),
    };
  }

  public beginRecovery(input: {
    repositoryId: string;
    epoch: number;
    operationId: string;
    startedAt: string;
    deadlineAt: string;
  }): RemoteConnectionState {
    validateOperation(input);
    validateTimestamp(input.deadlineAt, "deadlineAt");
    const current = this.requireRepository(input.repositoryId, input.epoch);
    if (current.kind !== "indeterminate" || current.recovery.kind !== "required") {
      throw lifecycleError("SUBVERSIONR_REMOTE_STATE_RECOVERY_NOT_REQUIRED", input.repositoryId);
    }
    if (current.recovery.operationId === input.operationId) {
      throw new RemoteConnectionStateStoreError(
        "SUBVERSIONR_REMOTE_STATE_RECOVERY_OPERATION_REUSED",
        "input",
        "error.remote.recoveryOperationReused",
        { repositoryId: input.repositoryId },
      );
    }
    return this.update({
      ...cloneState(current),
      recovery: {
        kind: "checking",
        operationId: input.operationId,
        originOperationId: current.recovery.operationId,
        startedAt: input.startedAt,
        deadlineAt: input.deadlineAt,
      },
    });
  }

  public completeRecovery(input: {
    repositoryId: string;
    epoch: number;
    operationId: string;
    completedAt: string;
    result: "safe" | "indeterminate" | "blocked";
    failure?: NativeRemoteFailure;
  }): RemoteConnectionStateApplyResult {
    validateOperation({ ...input, startedAt: input.completedAt });
    if (input.result !== "safe" && input.result !== "indeterminate" && input.result !== "blocked") {
      throw protocolError("recovery.result");
    }
    const failure = input.result === "safe"
      ? undefined
      : input.failure
        ? validateNativeRemoteFailure(input.failure)
        : undefined;
    if (input.result !== "safe" && !failure) {
      throw protocolError("recovery.failure");
    }
    const current = this.currentRepository(input.repositoryId, input.epoch);
    if (!current) {
      return { applied: false, state: undefined };
    }
    if (current.kind !== "indeterminate" || current.recovery.kind !== "checking" || current.recovery.operationId !== input.operationId) {
      return { applied: false, state: cloneState(current) };
    }
    if (input.result === "safe") {
      return {
        applied: true,
        state: this.update({
          kind: "unchecked",
          repositoryId: current.repositoryId,
          epoch: current.epoch,
          incoming: staleIncoming(current.incoming),
          recovery: { kind: "safe", operationId: input.operationId, completedAt: input.completedAt },
          ...(current.lastFailure ? { lastFailure: { ...current.lastFailure } } : {}),
        }),
      };
    }
    const recovery: RemoteRecoveryState = input.result === "blocked"
      ? {
          kind: "blocked",
          operationId: current.recovery.originOperationId,
          completedAt: input.completedAt,
          reason: "remoteRecoveryBlocked",
        }
      : {
          kind: "required",
          operationId: current.recovery.originOperationId,
          requiredAt: input.completedAt,
        };
    return {
      applied: true,
      state: this.update({
        ...cloneState(current),
        recovery,
        lastFailure: {
          reason: failure!.reason,
          cleanupAppropriate: failure!.cleanupAppropriate,
          occurredAt: input.completedAt,
        },
      }),
    };
  }

  public getState(repositoryId: string): RemoteConnectionState | undefined {
    const state = this.repositories.get(repositoryId);
    return state ? cloneState(state) : undefined;
  }

  public applyDaemonState(input: {
    repositoryId: string;
    epoch: number;
    state: DaemonRemoteConnectionState;
    receivedAt: string;
  }): RemoteConnectionStateApplyResult {
    validateTimestamp(input.receivedAt, "receivedAt");
    const current = this.currentRepository(input.repositoryId, input.epoch);
    if (!current) {
      return { applied: false, state: undefined };
    }
    const common = {
      repositoryId: input.repositoryId,
      epoch: input.epoch,
      incoming: cloneIncoming(current.incoming),
    };
    const daemon = input.state;
    if (daemon.kind === "checking") {
      if (current.kind === "checking" && current.operationId !== daemon.operationId && Date.parse(daemon.startedAt) <= Date.parse(current.startedAt)) {
        return { applied: false, state: cloneState(current) };
      }
      return { applied: true, state: this.update({
        ...common, kind: "checking", operationId: daemon.operationId, startedAt: daemon.startedAt,
        recovery: cloneRecovery(current.recovery),
        ...(current.lastFailure ? { lastFailure: { ...current.lastFailure } } : {}),
      }) };
    }
    if (daemon.kind === "online") {
      return { applied: true, state: this.update({
        ...common, kind: "online", transport: daemon.transport, checkedAt: daemon.checkedAt,
        recovery: { kind: "notRequired" },
      }) };
    }
    if (daemon.kind === "attention" || daemon.kind === "unreachable") {
      return { applied: true, state: this.update({
        ...common,
        kind: daemon.kind,
        reason: daemon.reason,
        incoming: staleIncoming(current.incoming),
        recovery: { kind: "notRequired" },
        ...(current.lastFailure ? { lastFailure: { ...current.lastFailure } } : {}),
      } as RemoteConnectionState) };
    }
    if (daemon.kind === "indeterminate") {
      const recovery: RemoteRecoveryState = daemon.recovery === "notRequired"
        ? { kind: "notRequired" }
        : daemon.recovery === "blocked"
        ? { kind: "blocked", operationId: daemon.originOperationId, completedAt: input.receivedAt, reason: "remoteRecoveryBlocked" }
        : current.recovery.kind === "checking"
          ? cloneRecovery(current.recovery)
          : { kind: "required", operationId: daemon.originOperationId, requiredAt: input.receivedAt };
      return { applied: true, state: this.update({
        ...common, kind: "indeterminate", reason: daemon.reason,
        incoming: staleIncoming(current.incoming), recovery,
        lastFailure: {
          reason: daemon.recovery === "blocked" ? "remoteRecoveryBlocked" : daemon.reason === "workerTerminated" ? "workerContainmentFailed" : "remoteOperationIndeterminate",
          cleanupAppropriate: daemon.cleanupAppropriate,
          occurredAt: input.receivedAt,
        },
      }) };
    }
    if (current.recovery.kind === "checking") {
      return { applied: false, state: cloneState(current) };
    }
    return { applied: true, state: this.update({
      ...common, kind: "unchecked", incoming: staleIncoming(current.incoming), recovery: { kind: "notRequired" },
      ...(current.lastFailure ? { lastFailure: { ...current.lastFailure } } : {}),
    }) };
  }

  private requireRepository(repositoryId: string, epoch: number): RemoteConnectionState {
    const state = this.currentRepository(repositoryId, epoch);
    if (!state) {
      throw lifecycleError("SUBVERSIONR_REMOTE_STATE_REPOSITORY_NOT_REGISTERED", repositoryId);
    }
    return state;
  }

  private currentRepository(repositoryId: string, epoch: number): RemoteConnectionState | undefined {
    const state = this.repositories.get(repositoryId);
    return state?.epoch === epoch ? state : undefined;
  }

  private update(state: RemoteConnectionState): RemoteConnectionState {
    const stored = cloneState(state);
    this.repositories.set(state.repositoryId, stored);
    this.fire(stored);
    return cloneState(stored);
  }

  private fire(state: RemoteConnectionState): void {
    for (const listener of this.listeners) {
      listener(cloneState(state));
    }
  }
}

export function parseWireRemoteFailure(value: unknown): NativeRemoteFailure {
  if (!isRecord(value) || Object.keys(value).sort().join(",") !== "category,cleanupAppropriate,reason") {
    throw protocolError("remoteFailure");
  }
  if (typeof value.cleanupAppropriate !== "boolean" || typeof value.category !== "string" || !REMOTE_FAILURE_REASONS.has(value.reason as NativeRemoteFailureReason)) {
    throw protocolError("remoteFailure");
  }
  const reason = value.reason as NativeRemoteFailureReason;
  if (WIRE_CATEGORY_BY_REASON[reason] !== value.category) {
    throw protocolError("remoteFailure.category");
  }
  return {
    category: categoryForReason(reason),
    reason,
    cleanupAppropriate: value.cleanupAppropriate,
  };
}

function validateRepository(repository: RemoteConnectionRepository): void {
  if (typeof repository.repositoryId !== "string" || repository.repositoryId.trim().length === 0) {
    throw inputError("repositoryId");
  }
  if (!Number.isSafeInteger(repository.epoch) || repository.epoch < 0) {
    throw inputError("epoch");
  }
}

function validateOperation(input: { repositoryId: string; epoch: number; operationId: string; startedAt: string }): void {
  validateRepository(input);
  if (!isCanonicalUuid(input.operationId)) {
    throw inputError("operationId");
  }
  validateTimestamp(input.startedAt, "timestamp");
}

function validateTimestamp(value: string, field: string): void {
  if (typeof value !== "string" || value.length > 64 || Number.isNaN(Date.parse(value))) {
    throw inputError(field);
  }
}

function validateTransport(value: RemoteScheme): RemoteScheme {
  if (value !== "http" && value !== "https" && value !== "svn" && value !== "svn+ssh") {
    throw inputError("transport");
  }
  return value;
}

function validateNativeRemoteFailure(value: NativeRemoteFailure): NativeRemoteFailure {
  if (!isRecord(value) || Object.keys(value).sort().join(",") !== "category,cleanupAppropriate,reason") {
    throw protocolError("remoteFailure");
  }
  if (typeof value.cleanupAppropriate !== "boolean" || !REMOTE_FAILURE_REASONS.has(value.reason)) {
    throw protocolError("remoteFailure");
  }
  const category = categoryForReason(value.reason);
  if (value.category !== category) {
    throw protocolError("remoteFailure.category");
  }
  return { category, reason: value.reason, cleanupAppropriate: value.cleanupAppropriate };
}

const REMOTE_FAILURE_REASONS = new Set<NativeRemoteFailureReason>([
  "networkDns", "networkRefused", "networkTimeout", "proxyAuthenticationRequired", "proxyUnreachable",
  "tlsUntrusted", "tlsChanged", "tlsProtocol", "authenticationRequired", "authorizationDenied",
  "sshHostKeyRequired", "sshHostKeyChanged", "sshTunnelFailed", "operationCancelled",
  "operationDeadlineExceeded", "redirectRejected", "crossAuthorityRejected", "credentialRejected",
  "sshExecutableInvalid", "sshProvenanceInvalid", "sshTunnelCleanupFailed", "workerContainmentFailed",
  "remoteRecoveryBlocked", "remoteConfigurationInvalid", "remoteCapabilityUnsupported", "remoteOperationIndeterminate",
  "unknownRemote",
]);

const WIRE_CATEGORY_BY_REASON: Record<NativeRemoteFailureReason, WireRemoteFailureCategory> = {
  networkDns: "network", networkRefused: "network", networkTimeout: "network",
  proxyAuthenticationRequired: "proxy", proxyUnreachable: "proxy",
  tlsUntrusted: "tls", tlsChanged: "tls", tlsProtocol: "tls",
  authenticationRequired: "authentication", authorizationDenied: "authorization",
  sshHostKeyRequired: "ssh", sshHostKeyChanged: "ssh", sshTunnelFailed: "ssh",
  sshExecutableInvalid: "ssh", sshProvenanceInvalid: "ssh", sshTunnelCleanupFailed: "ssh",
  operationCancelled: "cancellation", operationDeadlineExceeded: "deadline",
  redirectRejected: "policy", crossAuthorityRejected: "policy", credentialRejected: "credential",
  workerContainmentFailed: "process", remoteRecoveryBlocked: "recovery",
  remoteOperationIndeterminate: "recovery", remoteConfigurationInvalid: "configuration",
  remoteCapabilityUnsupported: "capability", unknownRemote: "unknown",
};

function categoryForReason(reason: NativeRemoteFailureReason): NativeRemoteFailure["category"] {
  if (reason === "operationCancelled") return "cancelled";
  if (["networkDns", "networkRefused", "networkTimeout", "proxyUnreachable", "sshTunnelFailed", "operationDeadlineExceeded"].includes(reason)) return "unreachable";
  if (["sshTunnelCleanupFailed", "workerContainmentFailed", "remoteRecoveryBlocked", "remoteOperationIndeterminate"].includes(reason)) return "indeterminate";
  return "attention";
}

function attentionReason(reason: NativeRemoteFailureReason): RemoteAttentionReason {
  if (["authenticationRequired", "authorizationDenied", "credentialRejected", "proxyAuthenticationRequired"].includes(reason)) return "authRequired";
  if (["tlsUntrusted", "tlsChanged", "tlsProtocol"].includes(reason)) return "certificateRequired";
  if (["sshHostKeyRequired", "sshHostKeyChanged"].includes(reason)) return "hostKeyRequired";
  if (reason === "remoteCapabilityUnsupported") return "unsupportedCapability";
  return "configurationInvalid";
}

function unreachableReason(reason: NativeRemoteFailureReason): RemoteUnreachableReason {
  if (reason === "networkDns") return "dns";
  if (reason === "networkRefused") return "refused";
  if (reason === "proxyUnreachable") return "proxy";
  if (reason === "sshTunnelFailed") return "tunnel";
  return "timeout";
}

function indeterminateReason(reason: NativeRemoteFailureReason): RemoteIndeterminateReason {
  return reason === "remoteOperationIndeterminate" ? "cancelledAfterMutation" : "workerTerminated";
}

function isCurrentCheck(state: RemoteConnectionState, operationId: string): boolean {
  return state.kind === "checking" && state.operationId === operationId;
}

function staleIncoming(incoming: IncomingRemoteFreshness): IncomingRemoteFreshness {
  return {
    kind: "stale",
    ...(incoming.lastSuccessfulCheckAt ? { lastSuccessfulCheckAt: incoming.lastSuccessfulCheckAt } : {}),
  };
}

function cloneIncoming(incoming: IncomingRemoteFreshness): IncomingRemoteFreshness {
  return { ...incoming };
}

function cloneRecovery(recovery: RemoteRecoveryState): RemoteRecoveryState {
  return { ...recovery };
}

function cloneState(state: RemoteConnectionState): RemoteConnectionState {
  return {
    ...state,
    incoming: cloneIncoming(state.incoming),
    recovery: cloneRecovery(state.recovery),
    ...(state.lastFailure ? { lastFailure: { ...state.lastFailure } } : {}),
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isCanonicalUuid(value: unknown): value is string {
  return typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(value);
}

function inputError(field: string): RemoteConnectionStateStoreError {
  return new RemoteConnectionStateStoreError(
    "SUBVERSIONR_REMOTE_STATE_INPUT_INVALID",
    "input",
    "error.remote.stateInputInvalid",
    { field },
  );
}

function lifecycleError(code: string, repositoryId: string): RemoteConnectionStateStoreError {
  return new RemoteConnectionStateStoreError(code, "lifecycle", "error.remote.stateLifecycleInvalid", { repositoryId });
}

function protocolError(field: string): RemoteConnectionStateStoreError {
  return new RemoteConnectionStateStoreError(
    "SUBVERSIONR_REMOTE_FAILURE_INVALID",
    "protocol",
    "error.remote.failureInvalid",
    { field },
  );
}
