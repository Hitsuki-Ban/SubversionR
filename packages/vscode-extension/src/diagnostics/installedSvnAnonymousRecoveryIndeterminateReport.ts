import * as nodePath from "node:path";
import type { BackendConnection } from "../backend/backendProcess";
import { OperationRunRpcClient } from "../operations/operationRunRpcClient";
import type { RepositorySession } from "../repository/repositorySessionService";
import type { ScmRepositoryProjection } from "../scm/sourceControlResourceStore";
import {
  RemoteOperationEnvelopeFactory,
  canonicalEndpointFromRepositoryUrl,
  type CanonicalEndpoint,
  type RemoteAccessProfileSnapshot,
} from "../security/remoteAccessProfile";
import type { RemoteConnectionState } from "../status/remoteConnectionStateStore";
import type { StoredStatusSnapshot } from "../status/statusSnapshotStore";
import { StatusSnapshotRpcClient } from "../status/statusSnapshotRpcClient";
import { JsonRpcStreamError } from "../transport/jsonRpcStreamClient";
import type { InstalledSvnAnonymousAuthActivity } from "./installedSvnAnonymousReport";

const EXPECTED_PROTOCOL_MAJOR = 1;
const EXPECTED_PROTOCOL_MINOR = 35;
const OPERATION_TIMEOUT_MS = 5_000;
const OBSERVATION_TIMEOUT_MS = 30_000;
const MAX_REDACTION_VALUE_BYTES = 32_768;
const REPORT_SCHEMA = "subversionr.release.m8-i6-installed-vsix-recovery-indeterminate.v1";
const REPORT_KIND = "subversionr.installedSvnAnonymousRecoveryIndeterminateReport";
const INDETERMINATE_CODE = "SUBVERSIONR_REMOTE_OPERATION_INDETERMINATE";
const INDETERMINATE_REASON = "remoteOperationIndeterminate";

type RecoveryIndeterminateConnection = Pick<
  BackendConnection,
  "initializeResult" | "isRemoteSubmissionEnabled" | "currentRemoteTrustEpoch" | "sendRequest"
>;

interface Subscription {
  dispose(): void;
}

export interface InstalledSvnAnonymousRecoveryIndeterminateReportOptions {
  expectedToken: string | undefined;
  request: unknown;
  initialize(): Promise<RecoveryIndeterminateConnection>;
  openWorkingCopy(path: string): Promise<RepositorySession>;
  closeRepository(repositoryId: string): Promise<void>;
  onRemoteStateChange(listener: (state: RemoteConnectionState) => void): Subscription;
  getRemoteState(repositoryId: string): RemoteConnectionState | undefined;
  getStatusSnapshot(repositoryId: string): StoredStatusSnapshot | undefined;
  getProjection(repositoryId: string): ScmRepositoryProjection | undefined;
  readFixtureState(path: string): Promise<unknown>;
  authActivity(): InstalledSvnAnonymousAuthActivity;
}

interface RecoveryIndeterminateRequest {
  token: string;
  repositoryUrl: string;
  workingCopyPath: string;
  operationId: string;
  fixtureStatePath: string;
  timeoutMs: 5000;
}

type ObservedTransition = "required" | "checking";

export async function collectInstalledSvnAnonymousRecoveryIndeterminateReport(
  options: InstalledSvnAnonymousRecoveryIndeterminateReportOptions,
): Promise<Record<string, unknown>> {
  const request = parseRequest(options.request, options.expectedToken);
  const endpoint = requireLoopbackSvnOrigin(request.repositoryUrl);
  const authBefore = requireAuthActivity(options.authActivity());
  const connection = await options.initialize();
  const trustEpoch = requireCandidateCapabilities(connection);
  const remote = createRemoteEnvelope(connection, request, endpoint, trustEpoch);

  let session: RepositorySession | undefined;
  let stateSubscription: Subscription | undefined;
  let disposeObservation: (() => void) | undefined;
  let report: Record<string, unknown> | undefined;
  let closeBlockedByIndeterminate = false;
  try {
    session = await options.openWorkingCopy(request.workingCopyPath);
    requireOpenedSession(session, request.workingCopyPath, endpoint);
    const initialSnapshot = requireFreshSnapshot(options.getStatusSnapshot(session.repositoryId), session);
    requireFreshProjection(options.getProjection(session.repositoryId), session, initialSnapshot.generation);

    const observation = createRecoveryObservation(session, request.operationId);
    disposeObservation = observation.dispose;
    stateSubscription = options.onRemoteStateChange(observation.onState);

    let prerequisiteError: unknown;
    try {
      await new OperationRunRpcClient(connection).update({
        repositoryId: session.repositoryId,
        epoch: session.epoch,
        path: ".",
        revision: "head",
        depth: "infinity",
        depthIsSticky: false,
        ignoreExternals: true,
        remote,
      });
    } catch (error) {
      prerequisiteError = error;
    }
    requirePrerequisiteTimeout(prerequisiteError);
    requireRedacted(prerequisiteError, request, undefined);
    const fixtureAfterPrerequisite = requireCommandStallFixtureState(
      await options.readFixtureState(request.fixtureStatePath),
    );
    requireCommandProgress(fixtureAfterPrerequisite);

    await observation.completed;
    const recoveryOperationId = observation.requireComplete();
    const fixtureAfterRecovery = requireCommandStallFixtureState(
      await options.readFixtureState(request.fixtureStatePath),
    );
    requireNoFixtureProgress(fixtureAfterPrerequisite, fixtureAfterRecovery);

    const recoveredState = options.getRemoteState(session.repositoryId);
    if (
      recoveredState?.epoch !== session.epoch || recoveredState.kind !== "indeterminate" ||
      recoveredState.reason !== "workerTerminated" || recoveredState.recovery.kind !== "required" ||
      recoveredState.recovery.operationId !== request.operationId || recoveredState.incoming.kind !== "stale" ||
      recoveredState.lastFailure?.reason !== "unknownRemote" || recoveredState.lastFailure.cleanupAppropriate !== false
    ) {
      throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_INDETERMINATE_STATE_INVALID");
    }

    let laneError: unknown;
    try {
      await new StatusSnapshotRpcClient(connection).getSnapshot({
        repositoryId: session.repositoryId,
        epoch: session.epoch,
      });
    } catch (error) {
      laneError = error;
    }
    requireIndeterminateLaneError(laneError);
    requireRedacted(laneError, request, recoveryOperationId);
    const fixtureAfterLaneProof = requireCommandStallFixtureState(
      await options.readFixtureState(request.fixtureStatePath),
    );
    requireNoFixtureProgress(fixtureAfterPrerequisite, fixtureAfterLaneProof);
    requireStableTrust(connection, trustEpoch);

    let diagnostics: unknown;
    try {
      diagnostics = await connection.sendRequest<unknown>("diagnostics/get", {});
    } catch {
      throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_INDETERMINATE_DIAGNOSTICS_INVALID");
    }
    if (
      !isRecord(diagnostics) || diagnostics.source !== "subversionr-daemon" ||
      !isRecord(diagnostics.protocol) || diagnostics.protocol.major !== EXPECTED_PROTOCOL_MAJOR ||
      diagnostics.protocol.minor !== EXPECTED_PROTOCOL_MINOR
    ) {
      throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_INDETERMINATE_DIAGNOSTICS_INVALID");
    }
    requireRedacted(diagnostics, request, recoveryOperationId);

    const authActivity = subtractAuthActivity(requireAuthActivity(options.authActivity()), authBefore);
    if (
      authActivity.credentialRequests !== 0 || authActivity.credentialSettlements !== 0 ||
      authActivity.certificateRequests !== 0
    ) {
      throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_INDETERMINATE_AUTH_ACTIVITY_INVALID");
    }

    report = {
      schema: REPORT_SCHEMA,
      schemaVersion: 1,
      kind: REPORT_KIND,
      status: "passed",
      cell: "recoveryIndeterminate",
      surface: "installed-vsix-extension-host",
      stableCode: INDETERMINATE_CODE,
      reason: INDETERMINATE_REASON,
      originCode: INDETERMINATE_CODE,
      originReason: INDETERMINATE_REASON,
      settlementCode: INDETERMINATE_CODE,
      settlementReason: INDETERMINATE_REASON,
      prerequisite: {
        code: "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT",
        reason: "operationDeadlineExceeded",
        recovery: "pending",
      },
      transitions: observation.transitions(),
      fixtureCountersUnchangedAfterPrerequisite: true,
      indeterminate: {
        outcome: "Indeterminate",
        stableCode: INDETERMINATE_CODE,
        reason: INDETERMINATE_REASON,
        nativeLaneBlocked: true,
        explicitRecoveryRequired: true,
      },
      networkProgress: "command",
      networkAttempts: 1,
      networkConnections: 1,
      followupNetworkContacts: 0,
      protocol: { major: EXPECTED_PROTOCOL_MAJOR, minor: EXPECTED_PROTOCOL_MINOR },
      trust: { acknowledgedEpoch: trustEpoch, consistent: true },
      authActivity,
      diagnosticsRedacted: true,
      redaction: { rawUrls: false, rawPaths: false, rawContent: false },
    };
  } finally {
    disposeObservation?.();
    stateSubscription?.dispose();
    if (session !== undefined) {
      let closeError: unknown;
      try {
        await options.closeRepository(session.repositoryId);
      } catch (error) {
        closeError = error;
      }
      requireIndeterminateLaneError(closeError);
      requireRedacted(closeError, request, undefined);
      closeBlockedByIndeterminate = true;
    }
  }
  if (report === undefined || !closeBlockedByIndeterminate) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_INDETERMINATE_CLOSE_INVALID");
  }
  return {
    ...report,
    repositorySession: { opened: true, closeBlockedByIndeterminate: true },
  };
}

function createRecoveryObservation(session: RepositorySession, originOperationId: string) {
  const observed: ObservedTransition[] = [];
  let recoveryOperationId: string | undefined;
  let duplicateCheckingObserved = false;
  let settled = false;
  let resolveCompleted!: () => void;
  let rejectCompleted!: (error: unknown) => void;
  const completed = new Promise<void>((resolve, reject) => {
    resolveCompleted = resolve;
    rejectCompleted = reject;
  });
  const timer = setTimeout(() => {
    rejectCompleted(reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_INDETERMINATE_OBSERVATION_TIMED_OUT"));
  }, OBSERVATION_TIMEOUT_MS);
  const finish = () => {
    if (!settled && duplicateCheckingObserved && observed.join(",") === "required,checking,required") {
      settled = true;
      clearTimeout(timer);
      resolveCompleted();
    }
  };
  const fail = () => {
    if (!settled) {
      settled = true;
      clearTimeout(timer);
      rejectCompleted(reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_INDETERMINATE_TRANSITION_INVALID"));
    }
  };
  return {
    completed,
    onState: (state: RemoteConnectionState) => {
      if (state.repositoryId !== session.repositoryId || state.epoch !== session.epoch) return;
      const next = observed.length;
      if (
        next === 0 && state.kind === "checking" && state.operationId === originOperationId &&
        state.recovery.kind === "notRequired"
      ) {
        return;
      }
      if (
        next === 0 && isOriginPendingState(state, originOperationId)
      ) {
        observed.push("required");
      } else if (
        next === 1 && state.kind === "indeterminate" && state.reason === "workerTerminated" &&
        state.recovery.kind === "checking" && state.recovery.originOperationId === originOperationId &&
        isCanonicalOperationId(state.recovery.operationId) && state.recovery.operationId !== originOperationId &&
        state.lastFailure?.reason === "workerContainmentFailed" && state.lastFailure.cleanupAppropriate === false
      ) {
        recoveryOperationId = state.recovery.operationId;
        observed.push("checking");
      } else if (
        next === 2 && recoveryOperationId !== undefined && state.kind === "indeterminate" &&
        state.reason === "workerTerminated" && state.recovery.kind === "checking" &&
        state.recovery.operationId === recoveryOperationId && state.recovery.originOperationId === originOperationId &&
        state.lastFailure?.reason === "workerContainmentFailed" && state.lastFailure.cleanupAppropriate === false &&
        state.incoming.kind === "stale"
      ) {
        // The daemon's exact pending notification is applied while the automatic recovery RPC is still checking.
        // It is the same recovery operation, not another transition or retry, and must occur exactly once.
        if (duplicateCheckingObserved) {
          fail();
          return;
        }
        duplicateCheckingObserved = true;
        return;
      } else if (
        next === 2 && state.kind === "indeterminate" && state.reason === "workerTerminated" &&
        state.recovery.kind === "required" && state.recovery.operationId === originOperationId &&
        state.lastFailure?.reason === "unknownRemote" && state.lastFailure.cleanupAppropriate === false &&
        state.incoming.kind === "stale"
      ) {
        observed.push("required");
      } else {
        fail();
      }
      finish();
    },
    transitions: (): ObservedTransition[] => [...observed],
    requireComplete: (): string => {
      if (
        !duplicateCheckingObserved || observed.join(",") !== "required,checking,required" || recoveryOperationId === undefined ||
        !isCanonicalOperationId(recoveryOperationId) || recoveryOperationId === originOperationId
      ) {
        throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_INDETERMINATE_TRANSITION_INVALID");
      }
      return recoveryOperationId;
    },
    dispose: () => clearTimeout(timer),
  };
}

function isOriginPendingState(state: RemoteConnectionState, originOperationId: string): boolean {
  return state.kind === "indeterminate" && state.reason === "workerTerminated" &&
    state.recovery.kind === "required" && state.recovery.operationId === originOperationId &&
    state.lastFailure?.reason === "workerContainmentFailed" && state.lastFailure.cleanupAppropriate === false;
}

function parseRequest(value: unknown, expectedToken: string | undefined): RecoveryIndeterminateRequest {
  if (
    typeof expectedToken !== "string" || !/^[0-9a-f]{32}$/u.test(expectedToken) ||
    !isRecord(value) || value.token !== expectedToken
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_INDETERMINATE_FORBIDDEN");
  }
  requireExactKeys(value, ["token", "repositoryUrl", "workingCopyPath", "operationId", "fixtureStatePath", "timeoutMs"]);
  if (
    typeof value.repositoryUrl !== "string" || value.repositoryUrl.length === 0 || /[\0\r\n]/u.test(value.repositoryUrl) ||
    typeof value.workingCopyPath !== "string" || !isAbsolutePath(value.workingCopyPath) || /[\0\r\n]/u.test(value.workingCopyPath) ||
    typeof value.fixtureStatePath !== "string" || !isAbsolutePath(value.fixtureStatePath) || /[\0\r\n]/u.test(value.fixtureStatePath) ||
    typeof value.operationId !== "string" || !isCanonicalOperationId(value.operationId) ||
    value.timeoutMs !== OPERATION_TIMEOUT_MS
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_INDETERMINATE_REQUEST_INVALID");
  }
  return value as unknown as RecoveryIndeterminateRequest;
}

function createRemoteEnvelope(
  connection: RecoveryIndeterminateConnection,
  request: RecoveryIndeterminateRequest,
  endpoint: CanonicalEndpoint,
  trustEpoch: number,
) {
  const remote = new RemoteOperationEnvelopeFactory({
    remoteSvnAnonymous: connection.initializeResult.capabilities.remoteSvnAnonymous,
    isRemoteSubmissionEnabled: () => connection.isRemoteSubmissionEnabled(),
    currentRemoteTrustEpoch: () => connection.currentRemoteTrustEpoch(),
  }).createAnonymousSvn({
    operationId: request.operationId,
    intent: "foreground",
    interaction: "allowed",
    timeoutMs: request.timeoutMs,
    profile: anonymousLoopbackProfile(endpoint),
    expectedOrigin: endpoint,
  });
  if (remote.trustEpoch !== trustEpoch || remote.operationId !== request.operationId || remote.timeoutMs !== OPERATION_TIMEOUT_MS) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_INDETERMINATE_ENVELOPE_INVALID");
  }
  return remote;
}

function requirePrerequisiteTimeout(error: unknown): void {
  if (
    !(error instanceof JsonRpcStreamError) || error.code !== "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT" ||
    error.category !== "timeout" || error.messageKey !== "error.remote.workerTimedOut" ||
    error.retryable !== false || error.diagnostics !== null || Object.keys(error.safeArgs).join(",") !== "remoteFailure"
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_INDETERMINATE_PREREQUISITE_INVALID");
  }
  const failure = error.safeArgs.remoteFailure;
  if (
    !isRecord(failure) || Object.keys(failure).sort().join(",") !== "category,cleanupAppropriate,reason" ||
    failure.category !== "deadline" || failure.reason !== "operationDeadlineExceeded" || failure.cleanupAppropriate !== false
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_INDETERMINATE_PREREQUISITE_INVALID");
  }
}

function requireIndeterminateLaneError(error: unknown): void {
  if (
    !(error instanceof JsonRpcStreamError) || error.code !== INDETERMINATE_CODE || error.category !== "state" ||
    error.messageKey !== "error.remote.operationIndeterminate" || error.retryable !== false ||
    error.diagnostics !== null || Object.keys(error.safeArgs).join(",") !== "remoteFailure"
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_INDETERMINATE_LANE_INVALID");
  }
  const failure = error.safeArgs.remoteFailure;
  if (
    !isRecord(failure) || Object.keys(failure).sort().join(",") !== "category,cleanupAppropriate,reason" ||
    failure.category !== "recovery" || failure.reason !== INDETERMINATE_REASON || failure.cleanupAppropriate !== false
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_INDETERMINATE_LANE_INVALID");
  }
}

interface CommandStallFixtureState {
  connections: number;
  suppliedAuthorityConnections: number;
  greetingSent: number;
  clientResponseReceived: number;
  authRequestSent: number;
  reposInfoSent: number;
  commandsReceived: number;
  followupContacts: number;
}

function requireCommandStallFixtureState(value: unknown): CommandStallFixtureState {
  if (!isRecord(value) || value.schema !== "subversionr.release.m8-i6-ra-svn-fault-fixture.v1" || value.scenario !== "command-stall") {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_INDETERMINATE_FIXTURE_STATE_INVALID");
  }
  const fields = [
    "connections", "suppliedAuthorityConnections", "greetingSent", "clientResponseReceived",
    "authRequestSent", "reposInfoSent", "commandsReceived", "followupContacts",
  ] as const;
  const result = {} as Record<(typeof fields)[number], number>;
  for (const field of fields) {
    if (!Number.isSafeInteger(value[field]) || (value[field] as number) < 0) {
      throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_INDETERMINATE_FIXTURE_STATE_INVALID");
    }
    result[field] = value[field] as number;
  }
  return result;
}

function requireCommandProgress(state: CommandStallFixtureState): void {
  if (
    state.connections !== 1 || state.suppliedAuthorityConnections !== 0 || state.greetingSent !== 1 ||
    state.clientResponseReceived !== 1 || state.authRequestSent !== 1 || state.reposInfoSent !== 1 ||
    state.commandsReceived !== 1 || state.followupContacts !== 0
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_INDETERMINATE_FIXTURE_PROGRESS_INVALID");
  }
}

function requireNoFixtureProgress(expected: CommandStallFixtureState, actual: CommandStallFixtureState): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_INDETERMINATE_NETWORK_PROGRESS_INVALID");
  }
}

function requireFreshSnapshot(value: StoredStatusSnapshot | undefined, session: RepositorySession): StoredStatusSnapshot {
  if (
    value?.repositoryId !== session.repositoryId || value.epoch !== session.epoch ||
    value.completeness !== "complete" || value.source !== "libsvn-local"
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_INDETERMINATE_BASELINE_INVALID");
  }
  return value;
}

function requireFreshProjection(
  value: ScmRepositoryProjection | undefined,
  session: RepositorySession,
  generation: number,
): void {
  if (
    value?.repositoryId !== session.repositoryId || value.epoch !== session.epoch || value.generation !== generation ||
    value.freshness.repositoryCompleteness !== "complete" ||
    value.freshness.lastRefreshCompleteness !== "complete" || value.freshness.lastRefreshKind === "stale"
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_INDETERMINATE_BASELINE_INVALID");
  }
}

function requireOpenedSession(session: RepositorySession, workingCopyPath: string, endpoint: CanonicalEndpoint): void {
  if (
    typeof session.repositoryId !== "string" || session.repositoryId.length === 0 ||
    !Number.isSafeInteger(session.epoch) || session.epoch < 1 ||
    normalizeAbsolutePath(session.identity.workingCopyRoot) !== normalizeAbsolutePath(workingCopyPath)
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_INDETERMINATE_OPEN_INVALID");
  }
  let actual: CanonicalEndpoint;
  try {
    actual = canonicalEndpointFromRepositoryUrl(session.identity.repositoryRootUrl);
  } catch {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_INDETERMINATE_OPEN_INVALID");
  }
  if (!sameEndpoint(actual, endpoint)) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_INDETERMINATE_OPEN_INVALID");
  }
}

function requireCandidateCapabilities(connection: RecoveryIndeterminateConnection): number {
  const initialize = connection.initializeResult;
  const capabilities = initialize.capabilities;
  if (
    initialize.protocol.major !== EXPECTED_PROTOCOL_MAJOR || initialize.protocol.minor !== EXPECTED_PROTOCOL_MINOR ||
    !capabilities.realLibsvnBridge || !capabilities.repositoryOpen || !capabilities.statusSnapshot ||
    !capabilities.operationRun || !capabilities.operationRunUpdate || !capabilities.remoteOperationEnvelope ||
    !capabilities.remoteWorkerIsolation || !capabilities.remoteConnectionState ||
    !capabilities.remoteSvnAnonymous || !connection.isRemoteSubmissionEnabled()
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_INDETERMINATE_CAPABILITY_UNAVAILABLE");
  }
  const trustEpoch = initialize.acknowledgedTrustEpoch;
  if (!Number.isSafeInteger(trustEpoch) || trustEpoch < 1 || connection.currentRemoteTrustEpoch() !== trustEpoch) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_INDETERMINATE_TRUST_EPOCH_INVALID");
  }
  return trustEpoch;
}

function requireLoopbackSvnOrigin(repositoryUrl: string): CanonicalEndpoint {
  let parsed: URL;
  let endpoint: CanonicalEndpoint;
  try {
    parsed = new URL(repositoryUrl);
    endpoint = canonicalEndpointFromRepositoryUrl(repositoryUrl);
  } catch {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_INDETERMINATE_ORIGIN_INVALID");
  }
  if (
    endpoint.scheme !== "svn" || (endpoint.canonicalHost !== "127.0.0.1" && endpoint.canonicalHost !== "::1") ||
    parsed.username.length !== 0 || parsed.password.length !== 0 || parsed.search.length !== 0 ||
    parsed.hash.length !== 0 || parsed.pathname.length === 0 || parsed.pathname === "/"
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_INDETERMINATE_ORIGIN_INVALID");
  }
  return endpoint;
}

function anonymousLoopbackProfile(endpoint: CanonicalEndpoint): RemoteAccessProfileSnapshot {
  return {
    schema: "subversionr.remote-profile.v1",
    profileId: "installed-i6-svn-anonymous-recovery-indeterminate",
    authority: endpoint,
    serverAuth: "anonymous",
    serverAccount: "none",
    serverCredentialPersistence: "secretStorage",
    proxy: "none",
    ssh: "none",
    redirectPolicy: "rejectAll",
  };
}

function requireRedacted(
  value: unknown,
  request: RecoveryIndeterminateRequest,
  recoveryOperationId: string | undefined,
): void {
  let serialized: string;
  try {
    const candidate = JSON.stringify(value);
    if (typeof candidate !== "string") throw new Error("invalid serialization");
    serialized = candidate;
  } catch {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_INDETERMINATE_DIAGNOSTICS_INVALID");
  }
  if (Buffer.byteLength(serialized, "utf8") > MAX_REDACTION_VALUE_BYTES) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_INDETERMINATE_DIAGNOSTICS_INVALID");
  }
  const sensitive = [
    request.token, request.repositoryUrl, request.workingCopyPath, request.workingCopyPath.replaceAll("\\", "/"),
    request.operationId, request.fixtureStatePath, request.fixtureStatePath.replaceAll("\\", "/"),
    ...(recoveryOperationId === undefined ? [] : [recoveryOperationId]),
  ].map((entry) => entry.toLowerCase());
  const normalized = serialized.toLowerCase();
  if (sensitive.some((entry) => normalized.includes(entry))) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_INDETERMINATE_DIAGNOSTICS_LEAK");
  }
}

function requireStableTrust(connection: RecoveryIndeterminateConnection, trustEpoch: number): void {
  if (!connection.isRemoteSubmissionEnabled() || connection.currentRemoteTrustEpoch() !== trustEpoch) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_INDETERMINATE_TRUST_EPOCH_INVALID");
  }
}

function subtractAuthActivity(
  after: InstalledSvnAnonymousAuthActivity,
  before: InstalledSvnAnonymousAuthActivity,
): InstalledSvnAnonymousAuthActivity {
  return requireAuthActivity({
    credentialRequests: after.credentialRequests - before.credentialRequests,
    credentialSettlements: after.credentialSettlements - before.credentialSettlements,
    certificateRequests: after.certificateRequests - before.certificateRequests,
  });
}

function requireAuthActivity(value: InstalledSvnAnonymousAuthActivity): InstalledSvnAnonymousAuthActivity {
  if (
    !isRecord(value) || !Number.isSafeInteger(value.credentialRequests) || value.credentialRequests < 0 ||
    !Number.isSafeInteger(value.credentialSettlements) || value.credentialSettlements < 0 ||
    !Number.isSafeInteger(value.certificateRequests) || value.certificateRequests < 0
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_INDETERMINATE_AUTH_ACTIVITY_INVALID");
  }
  return { ...value };
}

function requireExactKeys(value: Record<string, unknown>, expected: readonly string[]): void {
  if (Object.keys(value).sort().join(",") !== [...expected].sort().join(",")) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_INDETERMINATE_REQUEST_INVALID");
  }
}

function isCanonicalOperationId(value: string): boolean {
  return /^(?!00000000-0000-0000-0000-000000000000$)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u.test(value);
}

function isAbsolutePath(value: string): boolean {
  return nodePath.isAbsolute(value) || nodePath.win32.isAbsolute(value) || nodePath.posix.isAbsolute(value);
}

function normalizeAbsolutePath(value: string): string {
  return nodePath.resolve(value).replace(/[\\/]+$/u, "").toLowerCase();
}

function sameEndpoint(left: CanonicalEndpoint, right: CanonicalEndpoint): boolean {
  return left.scheme === right.scheme && left.canonicalHost === right.canonicalHost && left.effectivePort === right.effectivePort;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export class InstalledSvnAnonymousRecoveryIndeterminateReportError extends Error {
  public readonly messageKey = "error.diagnostics.installedSvnAnonymousRecoveryIndeterminateReportInvalid";

  public constructor(public readonly code: string) {
    super(code);
    this.name = "InstalledSvnAnonymousRecoveryIndeterminateReportError";
  }
}

function reportError(code: string): InstalledSvnAnonymousRecoveryIndeterminateReportError {
  return new InstalledSvnAnonymousRecoveryIndeterminateReportError(code);
}
