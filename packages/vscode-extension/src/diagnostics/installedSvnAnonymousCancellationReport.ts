import * as nodePath from "node:path";
import type { BackendConnection } from "../backend/backendProcess";
import type { RepositorySession } from "../repository/repositorySessionService";
import {
  RemoteOperationEnvelopeFactory,
  canonicalEndpointFromRepositoryUrl,
  type CanonicalEndpoint,
  type RemoteAccessProfileSnapshot,
} from "../security/remoteAccessProfile";
import { StatusRemoteCheckRpcClient } from "../status/statusRemoteCheckRpcClient";
import { StatusSnapshotRpcClient } from "../status/statusSnapshotRpcClient";
import {
  JsonRpcRequestCancelledError,
  JsonRpcStreamError,
} from "../transport/jsonRpcStreamClient";
import type { InstalledSvnAnonymousAuthActivity } from "./installedSvnAnonymousReport";

const EXPECTED_PROTOCOL_MAJOR = 1;
const EXPECTED_PROTOCOL_MINOR = 35;
const REPORT_SCHEMA = "subversionr.release.m8-i6-installed-vsix-cancellation.v1";
const REPORT_KIND = "subversionr.installedSvnAnonymousCancellationReport";
const OPERATION_TIMEOUT_MS = 30_000;
const WIRE_SETTLEMENT_TIMEOUT_MS = 5_500;
const GREETING_OBSERVATION_TIMEOUT_MS = 10_000;
const FIXTURE_POLL_INTERVAL_MS = 20;
const FIXTURE_SCHEMA = "subversionr.release.m8-i6-ra-svn-fault-fixture.v1";
const MAX_REDACTION_VALUE_BYTES = 32_768;

type CancellationConnection = Pick<
  BackendConnection,
  | "initializeResult"
  | "isRemoteSubmissionEnabled"
  | "currentRemoteTrustEpoch"
  | "sendRequest"
  | "waitForCancelledRequestWireSettlement"
>;

export interface InstalledSvnAnonymousCancellationReportOptions {
  expectedToken: string | undefined;
  request: unknown;
  initialize(): Promise<CancellationConnection>;
  openWorkingCopy(path: string): Promise<RepositorySession>;
  closeRepository(repositoryId: string): Promise<void>;
  authActivity(): InstalledSvnAnonymousAuthActivity;
  monotonicNowMs(): number;
  readFixtureState(path: string): Promise<unknown>;
}

interface InstalledSvnAnonymousCancellationRequest {
  token: string;
  repositoryUrl: string;
  workingCopyPath: string;
  operationId: string;
  fixtureStatePath: string;
}

export async function collectInstalledSvnAnonymousCancellationReport(
  options: InstalledSvnAnonymousCancellationReportOptions,
): Promise<Record<string, unknown>> {
  const request = parseRequest(options.request, options.expectedToken);
  const endpoint = requireLoopbackSvnOrigin(request.repositoryUrl);
  requireFixtureInitialState(await readFixtureStateValue(options, request.fixtureStatePath), endpoint.effectivePort);
  const authBefore = requireAuthActivity(options.authActivity());
  const connection = await options.initialize();
  const trustEpoch = requireCandidateCapabilities(connection);
  const waitForWireSettlement = connection.waitForCancelledRequestWireSettlement;
  if (typeof waitForWireSettlement !== "function") {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CANCELLATION_CAPABILITY_UNAVAILABLE");
  }
  const remote = new RemoteOperationEnvelopeFactory({
    remoteSvnAnonymous: connection.initializeResult.capabilities.remoteSvnAnonymous,
    isRemoteSubmissionEnabled: () => connection.isRemoteSubmissionEnabled(),
    currentRemoteTrustEpoch: () => connection.currentRemoteTrustEpoch(),
  }).createAnonymousSvn({
    operationId: request.operationId,
    intent: "foreground",
    interaction: "allowed",
    timeoutMs: OPERATION_TIMEOUT_MS,
    profile: anonymousLoopbackProfile(endpoint),
    expectedOrigin: endpoint,
  });
  if (
    remote.operationId !== request.operationId ||
    remote.timeoutMs !== OPERATION_TIMEOUT_MS ||
    remote.trustEpoch !== trustEpoch ||
    !sameEndpoint(remote.expectedOrigin, endpoint)
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CANCELLATION_ENVELOPE_INVALID");
  }

  let session: RepositorySession | undefined;
  let localCancellationObserved = false;
  let wireCancellationObserved = false;
  let localSnapshotAfterCancellation = false;
  try {
    session = await options.openWorkingCopy(request.workingCopyPath);
    requireOpenedSession(session, request.workingCopyPath, endpoint);

    const controller = new AbortController();
    const remoteRequest = new StatusRemoteCheckRpcClient(connection).checkRemoteStatus(
      {
        repositoryId: session.repositoryId,
        epoch: session.epoch,
        remote,
      },
      {
        signal: controller.signal,
        retainCancelledWireSettlementForEvidence: true,
      },
    );
    await waitForGreetingStall(options, request.fixtureStatePath, endpoint.effectivePort);
    controller.abort();
    const localError = await captureImmediateRejection(remoteRequest);
    const requestId = requireLocalCancellation(localError);
    localCancellationObserved = true;

    let wireError: unknown;
    try {
      await waitForWireSettlement.call(connection, requestId, WIRE_SETTLEMENT_TIMEOUT_MS);
    } catch (error) {
      wireError = error;
    }
    requireWireCancellation(wireError);
    requireRedacted(wireError, request);
    wireCancellationObserved = true;
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
      throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CANCELLATION_LOCAL_SNAPSHOT_INVALID");
    }
    localSnapshotAfterCancellation = true;
    requireStableTrust(connection, trustEpoch);

    let diagnostics: unknown;
    try {
      diagnostics = await connection.sendRequest<unknown>("diagnostics/get", {});
    } catch {
      throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CANCELLATION_DIAGNOSTICS_INVALID");
    }
    requireCurrentRedactedDiagnostics(diagnostics, request);
    requireStableTrust(connection, trustEpoch);
    requireFixtureGreetingState(
      await readFixtureStateValue(options, request.fixtureStatePath),
      endpoint.effectivePort,
    );
  } finally {
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
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CANCELLATION_AUTH_ACTIVITY_INVALID");
  }
  if (!localCancellationObserved || !wireCancellationObserved || !localSnapshotAfterCancellation) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CANCELLATION_SETTLEMENT_INVALID");
  }

  return {
    schema: REPORT_SCHEMA,
    schemaVersion: 1,
    kind: REPORT_KIND,
    scenario: "cancellation",
    settlement: {
      code: "SUBVERSIONR_REMOTE_WORKER_CANCELLED",
      category: "cancelled",
      messageKey: "error.remote.workerCancelled",
      retryable: false,
      remoteFailure: {
        category: "cancellation",
        reason: "operationCancelled",
        cleanupAppropriate: false,
      },
    },
    cancellationSettlement: {
      trigger: "abort-signal-after-greeting",
      localCode: "JSON_RPC_REQUEST_CANCELLED",
      wireCode: "SUBVERSIONR_REMOTE_WORKER_CANCELLED",
      wireReason: "operationCancelled",
      wireSettlementObserved: true,
    },
    diagnostics: null,
    nativeLaneReleased: true,
    localSnapshotAfterCancellation: true,
    protocol: { major: EXPECTED_PROTOCOL_MAJOR, minor: EXPECTED_PROTOCOL_MINOR },
    trust: { acknowledgedEpoch: trustEpoch, consistent: true },
    authActivity,
    repositorySession: { opened: true, closed: true },
    diagnosticsRedacted: true,
    redaction: { rawUrls: false, rawPaths: false, rawContent: false },
  };
}

function parseRequest(
  value: unknown,
  expectedToken: string | undefined,
): InstalledSvnAnonymousCancellationRequest {
  if (typeof expectedToken !== "string" || expectedToken.length === 0 || !isRecord(value)) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CANCELLATION_FORBIDDEN");
  }
  if (value.token !== expectedToken) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CANCELLATION_FORBIDDEN");
  }
  requireExactKeys(value, [
    "token",
    "repositoryUrl",
    "workingCopyPath",
    "operationId",
    "fixtureStatePath",
  ]);
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
    typeof value.fixtureStatePath !== "string" ||
    value.fixtureStatePath.length === 0 ||
    !isAbsolutePath(value.fixtureStatePath) ||
    /[\0\r\n]/.test(value.fixtureStatePath)
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CANCELLATION_REQUEST_INVALID");
  }
  return {
    token: value.token,
    repositoryUrl: value.repositoryUrl,
    workingCopyPath: value.workingCopyPath,
    operationId: value.operationId,
    fixtureStatePath: value.fixtureStatePath,
  };
}

function requireLoopbackSvnOrigin(repositoryUrl: string): CanonicalEndpoint {
  let parsed: URL;
  let endpoint: CanonicalEndpoint;
  try {
    parsed = new URL(repositoryUrl);
    endpoint = canonicalEndpointFromRepositoryUrl(repositoryUrl);
  } catch {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CANCELLATION_ORIGIN_INVALID");
  }
  if (
    endpoint.scheme !== "svn" ||
    (endpoint.canonicalHost !== "127.0.0.1" && endpoint.canonicalHost !== "::1") ||
    parsed.username.length !== 0 ||
    parsed.password.length !== 0 ||
    parsed.search.length !== 0 ||
    parsed.hash.length !== 0 ||
    parsed.pathname === "/" ||
    parsed.pathname.length === 0
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CANCELLATION_ORIGIN_INVALID");
  }
  return endpoint;
}

function requireCandidateCapabilities(connection: CancellationConnection): number {
  const initialize = connection.initializeResult;
  const capabilities = initialize.capabilities;
  if (
    initialize.protocol.major !== EXPECTED_PROTOCOL_MAJOR ||
    initialize.protocol.minor !== EXPECTED_PROTOCOL_MINOR ||
    !capabilities.realLibsvnBridge ||
    !capabilities.repositoryOpen ||
    !capabilities.repositoryClose ||
    !capabilities.statusSnapshot ||
    !capabilities.statusRemoteCheck ||
    !capabilities.remoteOperationEnvelope ||
    !capabilities.remoteWorkerIsolation ||
    !capabilities.remoteConnectionState ||
    !capabilities.remoteSvnAnonymous ||
    !capabilities.diagnosticsGet ||
    typeof connection.waitForCancelledRequestWireSettlement !== "function" ||
    !connection.isRemoteSubmissionEnabled()
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CANCELLATION_CAPABILITY_UNAVAILABLE");
  }
  const trustEpoch = initialize.acknowledgedTrustEpoch;
  if (
    !Number.isSafeInteger(trustEpoch) ||
    trustEpoch < 1 ||
    connection.currentRemoteTrustEpoch() !== trustEpoch
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CANCELLATION_TRUST_EPOCH_INVALID");
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
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CANCELLATION_OPEN_INVALID");
  }
  let actualEndpoint: CanonicalEndpoint;
  try {
    actualEndpoint = canonicalEndpointFromRepositoryUrl(session.identity.repositoryRootUrl);
  } catch {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CANCELLATION_OPEN_INVALID");
  }
  if (!sameEndpoint(actualEndpoint, endpoint)) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CANCELLATION_OPEN_INVALID");
  }
}

async function captureImmediateRejection(request: Promise<unknown>): Promise<unknown> {
  const observed = await Promise.race([
    request.then(
      () => ({ state: "resolved" as const }),
      (error: unknown) => ({ state: "rejected" as const, error }),
    ),
    new Promise<{ state: "pending" }>((resolve) => {
      setImmediate(() => resolve({ state: "pending" }));
    }),
  ]);
  if (observed.state !== "rejected") {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CANCELLATION_LOCAL_SETTLEMENT_INVALID");
  }
  return observed.error;
}

function requireLocalCancellation(error: unknown): number {
  if (
    !(error instanceof JsonRpcRequestCancelledError) ||
    error.code !== "JSON_RPC_REQUEST_CANCELLED" ||
    !Number.isSafeInteger(error.requestId) ||
    error.requestId < 1
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CANCELLATION_LOCAL_SETTLEMENT_INVALID");
  }
  return error.requestId;
}

function requireWireCancellation(error: unknown): void {
  if (
    !(error instanceof JsonRpcStreamError) ||
    error.code !== "SUBVERSIONR_REMOTE_WORKER_CANCELLED" ||
    error.category !== "cancelled" ||
    error.messageKey !== "error.remote.workerCancelled" ||
    error.retryable !== false ||
    error.diagnostics !== null ||
    Object.keys(error.safeArgs).sort().join(",") !== "remoteFailure"
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CANCELLATION_SETTLEMENT_INVALID");
  }
  const remoteFailure = error.safeArgs.remoteFailure;
  if (
    !isRecord(remoteFailure) ||
    Object.keys(remoteFailure).sort().join(",") !== "category,cleanupAppropriate,reason" ||
    remoteFailure.category !== "cancellation" ||
    remoteFailure.reason !== "operationCancelled" ||
    remoteFailure.cleanupAppropriate !== false
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CANCELLATION_SETTLEMENT_INVALID");
  }
}

async function waitForGreetingStall(
  options: InstalledSvnAnonymousCancellationReportOptions,
  fixtureStatePath: string,
  expectedPort: number,
): Promise<void> {
  const deadline = readMonotonicNow(options.monotonicNowMs) + GREETING_OBSERVATION_TIMEOUT_MS;
  while (readMonotonicNow(options.monotonicNowMs) <= deadline) {
    const state = requireFixtureState(await readFixtureStateValue(options, fixtureStatePath), expectedPort);
    if (isGreetingBarrier(state)) {
      return;
    }
    if (
      state.connections > 1 ||
      state.greetingSent > 1 ||
      state.clientResponseReceived > 1 ||
      state.authRequestSent !== 0 ||
      state.reposInfoSent !== 0 ||
      state.commandsReceived !== 0 ||
      state.followupContacts !== 0
    ) {
      throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CANCELLATION_FIXTURE_STATE_INVALID");
    }
    await new Promise<void>((resolve) => setTimeout(resolve, FIXTURE_POLL_INTERVAL_MS));
  }
  throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CANCELLATION_GREETING_NOT_OBSERVED");
}

async function readFixtureStateValue(
  options: InstalledSvnAnonymousCancellationReportOptions,
  fixtureStatePath: string,
): Promise<unknown> {
  try {
    return await options.readFixtureState(fixtureStatePath);
  } catch {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CANCELLATION_FIXTURE_STATE_INVALID");
  }
}

function readMonotonicNow(monotonicNowMs: () => number): number {
  const value = monotonicNowMs();
  if (!Number.isFinite(value) || value < 0) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CANCELLATION_FIXTURE_STATE_INVALID");
  }
  return value;
}

interface FixtureState {
  connections: number;
  greetingSent: number;
  clientResponseReceived: number;
  authRequestSent: number;
  reposInfoSent: number;
  commandsReceived: number;
  followupContacts: number;
}

function requireFixtureInitialState(value: unknown, expectedPort: number): void {
  const state = requireFixtureState(value, expectedPort);
  if (
    state.connections !== 0 ||
    state.greetingSent !== 0 ||
    state.clientResponseReceived !== 0 ||
    state.authRequestSent !== 0 ||
    state.reposInfoSent !== 0 ||
    state.commandsReceived !== 0 ||
    state.followupContacts !== 0
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CANCELLATION_FIXTURE_STATE_INVALID");
  }
}

function requireFixtureGreetingState(value: unknown, expectedPort: number): void {
  if (!isGreetingBarrier(requireFixtureState(value, expectedPort))) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CANCELLATION_FIXTURE_STATE_INVALID");
  }
}

function isGreetingBarrier(state: FixtureState): boolean {
  return state.connections === 1 &&
    state.greetingSent === 1 &&
    state.clientResponseReceived === 1 &&
    state.authRequestSent === 0 &&
    state.reposInfoSent === 0 &&
    state.commandsReceived === 0 &&
    state.followupContacts === 0;
}

function requireFixtureState(value: unknown, expectedPort: number): FixtureState {
  const exactKeys = [
    "authRequestSent", "clientResponseReceived", "commandsReceived", "connections",
    "followupContacts", "greetingSent", "pid", "port", "reposInfoSent", "scenario",
    "schema", "status", "suppliedAuthorityConnections", "suppliedAuthorityPort",
  ];
  if (
    !isRecord(value) ||
    Object.keys(value).sort().join(",") !== exactKeys.sort().join(",") ||
    value.schema !== FIXTURE_SCHEMA ||
    value.scenario !== "greeting-stall" ||
    value.status !== "ready" ||
    !Number.isSafeInteger(value.pid) ||
    (value.pid as number) < 1 ||
    value.port !== expectedPort ||
    value.suppliedAuthorityPort !== 0 ||
    value.suppliedAuthorityConnections !== 0
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CANCELLATION_FIXTURE_STATE_INVALID");
  }
  const counterKeys = [
    "connections", "greetingSent", "clientResponseReceived", "authRequestSent",
    "reposInfoSent", "commandsReceived", "followupContacts",
  ] as const;
  if (counterKeys.some((key) => !Number.isSafeInteger(value[key]) || (value[key] as number) < 0)) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CANCELLATION_FIXTURE_STATE_INVALID");
  }
  if (
    (value.clientResponseReceived as number) > (value.greetingSent as number) ||
    (value.greetingSent as number) > (value.connections as number)
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CANCELLATION_FIXTURE_STATE_INVALID");
  }
  return value as unknown as FixtureState;
}

function requireCurrentRedactedDiagnostics(
  value: unknown,
  request: InstalledSvnAnonymousCancellationRequest,
): void {
  if (!isRecord(value) || value.source !== "subversionr-daemon" || !isRecord(value.protocol)) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CANCELLATION_DIAGNOSTICS_INVALID");
  }
  if (
    value.protocol.major !== EXPECTED_PROTOCOL_MAJOR ||
    value.protocol.minor !== EXPECTED_PROTOCOL_MINOR ||
    !isRecord(value.capabilities) ||
    value.capabilities.remoteSvnAnonymous !== true ||
    value.capabilities.statusRemoteCheck !== true ||
    value.capabilities.statusSnapshot !== true
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CANCELLATION_DIAGNOSTICS_INVALID");
  }
  requireRedacted(value, request);
}

function requireRedacted(value: unknown, request: InstalledSvnAnonymousCancellationRequest): void {
  let serialized: string;
  try {
    const candidate = JSON.stringify(value);
    if (typeof candidate !== "string") {
      throw new Error("invalid serialization");
    }
    serialized = candidate;
  } catch {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CANCELLATION_DIAGNOSTICS_INVALID");
  }
  if (Buffer.byteLength(serialized, "utf8") > MAX_REDACTION_VALUE_BYTES) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CANCELLATION_DIAGNOSTICS_INVALID");
  }
  const sensitive = [
    request.token,
    request.repositoryUrl,
    request.workingCopyPath,
    request.workingCopyPath.replaceAll("\\", "/"),
    request.fixtureStatePath,
    request.fixtureStatePath.replaceAll("\\", "/"),
    request.operationId,
  ].map((entry) => entry.toLowerCase());
  const normalized = serialized.toLowerCase();
  if (sensitive.some((entry) => normalized.includes(entry))) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CANCELLATION_DIAGNOSTICS_LEAK");
  }
}

function anonymousLoopbackProfile(endpoint: CanonicalEndpoint): RemoteAccessProfileSnapshot {
  return {
    schema: "subversionr.remote-profile.v1",
    profileId: "installed-i6-svn-anonymous-cancellation",
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
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CANCELLATION_AUTH_ACTIVITY_INVALID");
  }
  return { ...value };
}

function requireStableTrust(connection: CancellationConnection, trustEpoch: number): void {
  if (!connection.isRemoteSubmissionEnabled() || connection.currentRemoteTrustEpoch() !== trustEpoch) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CANCELLATION_TRUST_EPOCH_INVALID");
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
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CANCELLATION_REQUEST_INVALID");
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

export class InstalledSvnAnonymousCancellationReportError extends Error {
  public readonly messageKey = "error.diagnostics.installedSvnAnonymousCancellationReportInvalid";

  public constructor(public readonly code: string) {
    super(code);
    this.name = "InstalledSvnAnonymousCancellationReportError";
  }
}

function reportError(code: string): InstalledSvnAnonymousCancellationReportError {
  return new InstalledSvnAnonymousCancellationReportError(code);
}
