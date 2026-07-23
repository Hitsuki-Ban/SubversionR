import { createHash } from "node:crypto";
import * as nodePath from "node:path";
import type { BackendConnection } from "../backend/backendProcess";
import type { RepositorySession } from "../repository/repositorySessionService";
import {
  RemoteOperationEnvelopeFactory,
  canonicalEndpointFromRepositoryUrl,
  type CanonicalEndpoint,
  type RemoteAccessProfileSnapshot,
} from "../security/remoteAccessProfile";
import type { RemoteConnectionNotification } from "../status/remoteConnectionNotificationHandler";
import type { RemoteConnectionState } from "../status/remoteConnectionStateStore";
import { StatusRemoteCheckRpcClient } from "../status/statusRemoteCheckRpcClient";
import { StatusSnapshotRpcClient } from "../status/statusSnapshotRpcClient";
import { JsonRpcStreamError } from "../transport/jsonRpcStreamClient";
import type { InstalledSvnAnonymousAuthActivity } from "./installedSvnAnonymousReport";

const EXPECTED_PROTOCOL_MAJOR = 1;
const EXPECTED_PROTOCOL_MINOR = 35;
const REPORT_SCHEMA = "subversionr.release.m8-i6-installed-vsix-blackhole-connect.v1";
const REPORT_KIND = "subversionr.installedSvnAnonymousBlackholeConnectReport";
const CLEANUP_SLACK_MS = 5_000;
const OBSERVATION_TIMEOUT_MS = 30_000;
const MAX_REDACTION_VALUE_BYTES = 32_768;

type BlackholeConnectConnection = Pick<
  BackendConnection,
  "initializeResult" | "isRemoteSubmissionEnabled" | "currentRemoteTrustEpoch" | "sendRequest"
>;

export interface InstalledSvnAnonymousBlackholeConnectReportOptions {
  expectedToken: string | undefined;
  request: unknown;
  initialize(): Promise<BlackholeConnectConnection>;
  openWorkingCopy(path: string): Promise<RepositorySession>;
  closeRepository(repositoryId: string): Promise<void>;
  onDaemonRemoteStateChange(listener: (state: RemoteConnectionNotification) => void): { dispose(): void };
  getRemoteState(repositoryId: string): RemoteConnectionState | undefined;
  authActivity(): InstalledSvnAnonymousAuthActivity;
  monotonicNowMs(): number;
}

interface InstalledSvnAnonymousBlackholeConnectRequest {
  token: string;
  repositoryUrl: string;
  workingCopyPath: string;
  operationId: string;
  timeoutMs: number;
}

export async function collectInstalledSvnAnonymousBlackholeConnectReport(
  options: InstalledSvnAnonymousBlackholeConnectReportOptions,
): Promise<Record<string, unknown>> {
  const request = parseRequest(options.request, options.expectedToken);
  const endpoint = requireLoopbackSvnOrigin(request.repositoryUrl);
  const authBefore = requireAuthActivity(options.authActivity());
  const connection = await options.initialize();
  const trustEpoch = requireCandidateCapabilities(connection);
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
  if (
    remote.operationId !== request.operationId ||
    remote.timeoutMs !== request.timeoutMs ||
    remote.trustEpoch !== trustEpoch ||
    !sameEndpoint(remote.expectedOrigin, endpoint)
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_BLACKHOLE_CONNECT_ENVELOPE_INVALID");
  }

  let session: RepositorySession | undefined;
  let expectedFailureObserved = false;
  let localSnapshotAfterTimeout = false;
  let elapsedMs: number | undefined;
  let daemonState: Record<string, unknown> | undefined;
  let stateSubscription: { dispose(): void } | undefined;
  let disposeObservation: (() => void) | undefined;
  try {
    session = await options.openWorkingCopy(request.workingCopyPath);
    requireOpenedSession(session, request.workingCopyPath, endpoint);
    const observation = createDaemonStateObservation(session, request.operationId);
    disposeObservation = observation.dispose;
    stateSubscription = options.onDaemonRemoteStateChange(observation.onState);

    const startedAtMs = readMonotonicNow(options.monotonicNowMs);
    let observedError: unknown;
    try {
      await new StatusRemoteCheckRpcClient(connection).checkRemoteStatus({
        repositoryId: session.repositoryId,
        epoch: session.epoch,
        remote,
      });
    } catch (error) {
      observedError = error;
    }
    const completedAtMs = readMonotonicNow(options.monotonicNowMs);
    elapsedMs = completedAtMs - startedAtMs;
    requireBlackholeConnectTiming(elapsedMs, request.timeoutMs);
    if (observedError === undefined) {
      throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_BLACKHOLE_CONNECT_UNEXPECTED_SUCCESS");
    }
    requireExpectedFailure(observedError);
    requireRedacted(observedError.error, request);
    expectedFailureObserved = true;
    daemonState = await observation.complete();
    requireStoredState(options.getRemoteState(session.repositoryId), session);
    requireStableTrust(connection, trustEpoch);

    const snapshot = await new StatusSnapshotRpcClient(connection).getSnapshot({
      repositoryId: session.repositoryId,
      epoch: session.epoch,
    });
    if (
      snapshot.repositoryId !== session.repositoryId ||
      snapshot.epoch !== session.epoch ||
      snapshot.source !== "libsvn-local"
    ) {
      throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_BLACKHOLE_CONNECT_LOCAL_SNAPSHOT_INVALID");
    }
    localSnapshotAfterTimeout = true;
    requireStableTrust(connection, trustEpoch);

    let diagnostics: unknown;
    try {
      diagnostics = await connection.sendRequest<unknown>("diagnostics/get", {});
    } catch {
      throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_BLACKHOLE_CONNECT_DIAGNOSTICS_INVALID");
    }
    requireCurrentRedactedDiagnostics(diagnostics, request);
    requireStableTrust(connection, trustEpoch);
  } finally {
    disposeObservation?.();
    stateSubscription?.dispose();
    if (session !== undefined) {
      await options.closeRepository(session.repositoryId);
    }
  }

  requireStableTrust(connection, trustEpoch);
  const authActivity = subtractAuthActivity(requireAuthActivity(options.authActivity()), authBefore);
  if (
    authActivity.credentialRequests !== 0 ||
    authActivity.credentialSettlements !== 0 ||
    authActivity.certificateRequests !== 0
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_BLACKHOLE_CONNECT_AUTH_ACTIVITY_INVALID");
  }
  if (!expectedFailureObserved || !localSnapshotAfterTimeout || elapsedMs === undefined || daemonState === undefined) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_BLACKHOLE_CONNECT_SETTLEMENT_INVALID");
  }

  return {
    schema: REPORT_SCHEMA,
    schemaVersion: 1,
    kind: REPORT_KIND,
    scenario: "blackholeConnect",
    settlement: {
      code: "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT",
      category: "timeout",
      messageKey: "error.remote.workerTimedOut",
      retryable: false,
      remoteFailure: {
        category: "deadline",
        reason: "operationDeadlineExceeded",
        cleanupAppropriate: false,
      },
    },
    daemonState,
    recovery: {
      required: false,
      storedKind: "notRequired",
      indeterminateObserved: false,
    },
    blackholeSettlement: {
      operationIdSha256: createHash("sha256").update(request.operationId, "utf8").digest("hex"),
      effectivePort: endpoint.effectivePort,
      wireSettlementObserved: true,
      daemonTerminalStateObserved: true,
    },
    timing: {
      clock: "monotonic",
      timeoutMs: request.timeoutMs,
      elapsedMs,
      cleanupSlackMs: CLEANUP_SLACK_MS,
    },
    diagnostics: null,
    nativeLaneReleased: true,
    localSnapshotAfterTimeout: true,
    protocol: { major: EXPECTED_PROTOCOL_MAJOR, minor: EXPECTED_PROTOCOL_MINOR },
    trust: { acknowledgedEpoch: trustEpoch, consistent: true },
    authActivity,
    repositorySession: { opened: true, closed: true },
    diagnosticsRedacted: true,
    redaction: { rawUrls: false, rawPaths: false, rawContent: false },
  };
}

function createDaemonStateObservation(session: RepositorySession, operationId: string) {
  let transition = 0;
  let terminal: RemoteConnectionNotification | undefined;
  let settled = false;
  let resolveObserved!: () => void;
  let rejectObserved!: (error: unknown) => void;
  const observed = new Promise<void>((resolve, reject) => {
    resolveObserved = resolve;
    rejectObserved = reject;
  });
  const fail = () => {
    if (settled) return;
    settled = true;
    clearTimeout(timer);
    rejectObserved(reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_BLACKHOLE_CONNECT_STATE_INVALID"));
  };
  const timer = setTimeout(() => {
    if (settled) return;
    settled = true;
    rejectObserved(reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_BLACKHOLE_CONNECT_STATE_TIMEOUT"));
  }, OBSERVATION_TIMEOUT_MS);
  return {
    onState: (notification: RemoteConnectionNotification) => {
      if (
        settled || notification.repositoryId !== session.repositoryId || notification.epoch !== session.epoch
      ) {
        fail();
        return;
      }
      if (
        transition === 0 && notification.state.kind === "checking" &&
        notification.state.operationId === operationId
      ) {
        transition = 1;
        return;
      }
      if (
        transition === 1 && notification.state.kind === "unreachable" &&
        notification.state.reason === "timeout"
      ) {
        transition = 2;
        terminal = notification;
        settled = true;
        clearTimeout(timer);
        resolveObserved();
        return;
      }
      fail();
    },
    complete: async (): Promise<Record<string, unknown>> => {
      await observed;
      if (transition !== 2 || terminal?.state.kind !== "unreachable") {
        throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_BLACKHOLE_CONNECT_STATE_INVALID");
      }
      return {
        transitions: ["checking", "unreachable"],
        checkingOperationIdMatched: true,
        terminalKind: terminal.state.kind,
        terminalReason: terminal.state.reason,
        terminalRecoveryFieldPresent: false,
        repositoryIdMatched: true,
        epochMatched: true,
      };
    },
    dispose: () => clearTimeout(timer),
  };
}

function requireStoredState(state: RemoteConnectionState | undefined, session: RepositorySession): void {
  if (
    state?.repositoryId !== session.repositoryId || state.epoch !== session.epoch ||
    state.kind !== "unreachable" || state.reason !== "timeout" ||
    state.recovery.kind !== "notRequired" || state.incoming.kind !== "stale"
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_BLACKHOLE_CONNECT_STORED_STATE_INVALID");
  }
}

function parseRequest(
  value: unknown,
  expectedToken: string | undefined,
): InstalledSvnAnonymousBlackholeConnectRequest {
  if (typeof expectedToken !== "string" || !/^[0-9a-f]{32}$/u.test(expectedToken) || !isRecord(value)) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_BLACKHOLE_CONNECT_FORBIDDEN");
  }
  if (value.token !== expectedToken) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_BLACKHOLE_CONNECT_FORBIDDEN");
  }
  requireExactKeys(value, ["token", "repositoryUrl", "workingCopyPath", "operationId", "timeoutMs"]);
  if (
    typeof value.repositoryUrl !== "string" ||
    value.repositoryUrl.length === 0 ||
    /[\0\r\n]/.test(value.repositoryUrl) ||
    typeof value.workingCopyPath !== "string" ||
    value.workingCopyPath.length === 0 ||
    !isAbsolutePath(value.workingCopyPath) ||
    /[\0\r\n]/.test(value.workingCopyPath) ||
    typeof value.operationId !== "string" ||
    !isCanonicalOperationId(value.operationId) ||
    typeof value.timeoutMs !== "number" ||
    value.timeoutMs !== 5_000
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_BLACKHOLE_CONNECT_REQUEST_INVALID");
  }
  return {
    token: value.token,
    repositoryUrl: value.repositoryUrl,
    workingCopyPath: value.workingCopyPath,
    operationId: value.operationId,
    timeoutMs: value.timeoutMs,
  };
}

function requireLoopbackSvnOrigin(repositoryUrl: string): CanonicalEndpoint {
  let parsed: URL;
  let endpoint: CanonicalEndpoint;
  try {
    parsed = new URL(repositoryUrl);
    endpoint = canonicalEndpointFromRepositoryUrl(repositoryUrl);
  } catch {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_BLACKHOLE_CONNECT_ORIGIN_INVALID");
  }
  if (
    endpoint.scheme !== "svn" ||
    (endpoint.canonicalHost !== "127.0.0.1" && endpoint.canonicalHost !== "::1") ||
    parsed.username.length !== 0 ||
    parsed.password.length !== 0 ||
    parsed.search.length !== 0 ||
    parsed.hash.length !== 0 ||
    parsed.pathname !== "/repo/trunk"
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_BLACKHOLE_CONNECT_ORIGIN_INVALID");
  }
  return endpoint;
}

function requireCandidateCapabilities(connection: BlackholeConnectConnection): number {
  const initialize = connection.initializeResult;
  const capabilities = initialize.capabilities;
  if (
    initialize.protocol.major !== EXPECTED_PROTOCOL_MAJOR ||
    initialize.protocol.minor !== EXPECTED_PROTOCOL_MINOR ||
    !capabilities.realLibsvnBridge ||
    !capabilities.repositoryOpen ||
    !capabilities.statusSnapshot ||
    !capabilities.statusRemoteCheck ||
    !capabilities.remoteOperationEnvelope ||
    !capabilities.remoteWorkerIsolation ||
    !capabilities.remoteConnectionState ||
    !capabilities.remoteSvnAnonymous ||
    !connection.isRemoteSubmissionEnabled()
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_BLACKHOLE_CONNECT_CAPABILITY_UNAVAILABLE");
  }
  const trustEpoch = initialize.acknowledgedTrustEpoch;
  if (
    !Number.isSafeInteger(trustEpoch) ||
    trustEpoch < 1 ||
    connection.currentRemoteTrustEpoch() !== trustEpoch
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_BLACKHOLE_CONNECT_TRUST_EPOCH_INVALID");
  }
  return trustEpoch;
}

function requireOpenedSession(
  session: RepositorySession,
  workingCopyPath: string,
  endpoint: CanonicalEndpoint,
): void {
  if (
    !isRecord(session) ||
    typeof session.repositoryId !== "string" ||
    session.repositoryId.length === 0 ||
    !Number.isSafeInteger(session.epoch) ||
    session.epoch < 1 ||
    !isRecord(session.identity) ||
    typeof session.identity.workingCopyRoot !== "string" ||
    normalizeAbsolutePath(session.identity.workingCopyRoot) !== normalizeAbsolutePath(workingCopyPath) ||
    typeof session.identity.repositoryRootUrl !== "string"
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_BLACKHOLE_CONNECT_OPEN_INVALID");
  }
  let actualEndpoint: CanonicalEndpoint;
  try {
    actualEndpoint = canonicalEndpointFromRepositoryUrl(session.identity.repositoryRootUrl);
  } catch {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_BLACKHOLE_CONNECT_OPEN_INVALID");
  }
  if (!sameEndpoint(actualEndpoint, endpoint)) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_BLACKHOLE_CONNECT_OPEN_INVALID");
  }
}

function requireExpectedFailure(error: unknown): asserts error is JsonRpcStreamError {
  if (
    !(error instanceof JsonRpcStreamError) ||
    error.code !== "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT" ||
    error.category !== "timeout" ||
    error.messageKey !== "error.remote.workerTimedOut" ||
    error.retryable !== false ||
    error.diagnostics !== null ||
    Object.keys(error.safeArgs).sort().join(",") !== "remoteFailure"
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_BLACKHOLE_CONNECT_SETTLEMENT_INVALID");
  }
  const remoteFailure = error.safeArgs.remoteFailure;
  if (
    !isRecord(remoteFailure) ||
    Object.keys(remoteFailure).sort().join(",") !== "category,cleanupAppropriate,reason" ||
    remoteFailure.category !== "deadline" ||
    remoteFailure.reason !== "operationDeadlineExceeded" ||
    remoteFailure.cleanupAppropriate !== false
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_BLACKHOLE_CONNECT_SETTLEMENT_INVALID");
  }
}

function requireBlackholeConnectTiming(elapsedMs: number, timeoutMs: number): void {
  if (
    !Number.isFinite(elapsedMs) ||
    elapsedMs < timeoutMs ||
    elapsedMs > timeoutMs + CLEANUP_SLACK_MS
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_BLACKHOLE_CONNECT_TIMING_INVALID");
  }
}

function readMonotonicNow(monotonicNowMs: () => number): number {
  const value = monotonicNowMs();
  if (!Number.isFinite(value) || value < 0) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_BLACKHOLE_CONNECT_TIMING_INVALID");
  }
  return value;
}

function requireCurrentRedactedDiagnostics(
  value: unknown,
  request: InstalledSvnAnonymousBlackholeConnectRequest,
): void {
  if (!isRecord(value) || value.source !== "subversionr-daemon" || !isRecord(value.protocol)) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_BLACKHOLE_CONNECT_DIAGNOSTICS_INVALID");
  }
  if (
    value.protocol.major !== EXPECTED_PROTOCOL_MAJOR ||
    value.protocol.minor !== EXPECTED_PROTOCOL_MINOR ||
    !isRecord(value.capabilities) ||
    value.capabilities.remoteSvnAnonymous !== true ||
    value.capabilities.statusRemoteCheck !== true ||
    value.capabilities.statusSnapshot !== true
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_BLACKHOLE_CONNECT_DIAGNOSTICS_INVALID");
  }
  requireRedacted(value, request);
}

function requireRedacted(value: unknown, request: InstalledSvnAnonymousBlackholeConnectRequest): void {
  let serialized: string;
  try {
    const candidate = JSON.stringify(value);
    if (typeof candidate !== "string") {
      throw new Error("invalid serialization");
    }
    serialized = candidate;
  } catch {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_BLACKHOLE_CONNECT_DIAGNOSTICS_INVALID");
  }
  if (Buffer.byteLength(serialized, "utf8") > MAX_REDACTION_VALUE_BYTES) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_BLACKHOLE_CONNECT_DIAGNOSTICS_INVALID");
  }
  const sensitive = [
    request.token,
    request.repositoryUrl,
    request.workingCopyPath,
    request.workingCopyPath.replaceAll("\\", "/"),
    request.operationId,
  ].map((entry) => entry.toLowerCase());
  const normalized = serialized.toLowerCase();
  if (sensitive.some((entry) => normalized.includes(entry))) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_BLACKHOLE_CONNECT_DIAGNOSTICS_LEAK");
  }
}

function anonymousLoopbackProfile(endpoint: CanonicalEndpoint): RemoteAccessProfileSnapshot {
  return {
    schema: "subversionr.remote-profile.v1",
    profileId: "installed-i6-svn-anonymous-blackhole-connect",
    authority: endpoint,
    serverAuth: "anonymous",
    serverAccount: "none",
    serverCredentialPersistence: "secretStorage",
    proxy: "none",
    ssh: "none",
    redirectPolicy: "rejectAll",
  };
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
    !isRecord(value) ||
    !Number.isSafeInteger(value.credentialRequests) ||
    value.credentialRequests < 0 ||
    !Number.isSafeInteger(value.credentialSettlements) ||
    value.credentialSettlements < 0 ||
    !Number.isSafeInteger(value.certificateRequests) ||
    value.certificateRequests < 0
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_BLACKHOLE_CONNECT_AUTH_ACTIVITY_INVALID");
  }
  return { ...value };
}

function requireStableTrust(connection: BlackholeConnectConnection, trustEpoch: number): void {
  if (!connection.isRemoteSubmissionEnabled() || connection.currentRemoteTrustEpoch() !== trustEpoch) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_BLACKHOLE_CONNECT_TRUST_EPOCH_INVALID");
  }
}

function isAbsolutePath(value: string): boolean {
  return nodePath.isAbsolute(value) || nodePath.win32.isAbsolute(value) || nodePath.posix.isAbsolute(value);
}

function normalizeAbsolutePath(value: string): string {
  return nodePath.resolve(value).replace(/[\\/]+$/, "").toLowerCase();
}

function isCanonicalOperationId(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value) &&
    value !== "00000000-0000-0000-0000-000000000000";
}

function requireExactKeys(value: Record<string, unknown>, keys: readonly string[]): void {
  if (Object.keys(value).sort().join(",") !== [...keys].sort().join(",")) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_BLACKHOLE_CONNECT_REQUEST_INVALID");
  }
}

function sameEndpoint(left: CanonicalEndpoint, right: CanonicalEndpoint): boolean {
  return left.scheme === right.scheme &&
    left.canonicalHost === right.canonicalHost &&
    left.effectivePort === right.effectivePort;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export class InstalledSvnAnonymousBlackholeConnectReportError extends Error {
  public readonly messageKey = "error.diagnostics.installedSvnAnonymousBlackholeConnectReportInvalid";

  public constructor(public readonly code: string) {
    super(code);
    this.name = "InstalledSvnAnonymousBlackholeConnectReportError";
  }
}

function reportError(code: string): InstalledSvnAnonymousBlackholeConnectReportError {
  return new InstalledSvnAnonymousBlackholeConnectReportError(code);
}
