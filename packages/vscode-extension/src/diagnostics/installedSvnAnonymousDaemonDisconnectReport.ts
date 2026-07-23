import * as nodePath from "node:path";
import { stat } from "node:fs/promises";
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
import { JsonRpcStreamError } from "../transport/jsonRpcStreamClient";
import type { InstalledSvnAnonymousAuthActivity } from "./installedSvnAnonymousReport";

const EXPECTED_PROTOCOL_MAJOR = 1;
const EXPECTED_PROTOCOL_MINOR = 35;
const OPERATION_TIMEOUT_MS = 30_000;
const OBSERVATION_TIMEOUT_MS = 30_000;
const REPORT_SCHEMA = "subversionr.release.m8-i6-installed-vsix-daemon-disconnect.v1";
const REPORT_KIND = "subversionr.installedSvnAnonymousDaemonDisconnectReport";

type DaemonDisconnectConnection = Pick<
  BackendConnection,
  "initializeResult" | "isRemoteSubmissionEnabled" | "currentRemoteTrustEpoch" | "sendRequest"
>;
interface Subscription { dispose(): void }

export interface InstalledSvnAnonymousDaemonDisconnectReportOptions {
  expectedToken: string | undefined;
  request: unknown;
  initialize(): Promise<DaemonDisconnectConnection>;
  shutdownBackend(): Promise<void>;
  openWorkingCopy(path: string): Promise<RepositorySession>;
  onDaemonRemoteStateChange(listener: (state: RemoteConnectionNotification) => void): Subscription;
  getRemoteState(repositoryId: string): RemoteConnectionState | undefined;
  readFixtureState(path: string): Promise<unknown>;
  authActivity(): InstalledSvnAnonymousAuthActivity;
}

interface DaemonDisconnectRequest {
  token: string;
  repositoryUrl: string;
  workingCopyPath: string;
  operationId: string;
  fixtureStatePath: string;
  shutdownTriggerPath: string;
}

export async function collectInstalledSvnAnonymousDaemonDisconnectReport(
  options: InstalledSvnAnonymousDaemonDisconnectReportOptions,
): Promise<Record<string, unknown>> {
  const request = parseRequest(options.request, options.expectedToken);
  const endpoint = requireLoopbackSvnOrigin(request.repositoryUrl);
  requireFreshFixture(await readFixtureState(options, request.fixtureStatePath), endpoint.effectivePort);
  await requireFreshShutdownTrigger(request.shutdownTriggerPath);
  const authBefore = requireAuthActivity(options.authActivity());
  const connection = await options.initialize();
  const trustEpoch = requireCapabilities(connection);
  const remote = createRemoteEnvelope(connection, request, endpoint, trustEpoch);
  const ordering: string[] = [];
  const observation = createDaemonStateObservation(request.operationId, ordering);
  const subscription = options.onDaemonRemoteStateChange(observation.onState);
  let session: RepositorySession | undefined;
  let shutdownStarted = false;

  try {
    session = await options.openWorkingCopy(request.workingCopyPath);
    requireOpenedSession(session, request.workingCopyPath, endpoint);
    const remoteRequest = new StatusRemoteCheckRpcClient(connection).checkRemoteStatus({
      repositoryId: session.repositoryId,
      epoch: session.epoch,
      remote,
    }).then(
      () => { throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DAEMON_DISCONNECT_RESULT_UNEXPECTED"); },
      (error: unknown) => {
        requireWireDisconnect(error);
        requireRedacted(error, request);
        ordering.push("activeRequestSettlement");
        return error;
      },
    );

    await waitForGreetingBarrier(options, request.fixtureStatePath, endpoint.effectivePort);
    requireStableTrust(connection, trustEpoch);
    await waitForShutdownTrigger(request.shutdownTriggerPath);
    shutdownStarted = true;
    const shutdown = options.shutdownBackend().then(() => ordering.push("shutdownAck"));
    await remoteRequest;
    const daemonState = await observation.complete(session);
    await shutdown;

    if (
      ordering.length !== 3 || ordering[2] !== "shutdownAck" ||
      !ordering.slice(0, 2).includes("activeRequestSettlement") ||
      !ordering.slice(0, 2).includes("daemonState")
    ) throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DAEMON_DISCONNECT_ORDER_INVALID");

    requireStoredState(options.getRemoteState(session.repositoryId), session);
    requireGreetingBarrier(await readFixtureState(options, request.fixtureStatePath), endpoint.effectivePort);
    const authActivity = subtractAuthActivity(requireAuthActivity(options.authActivity()), authBefore);
    if (
      authActivity.credentialRequests !== 0 || authActivity.credentialSettlements !== 0 ||
      authActivity.certificateRequests !== 0
    ) throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DAEMON_DISCONNECT_AUTH_ACTIVITY_INVALID");

    return {
      schema: REPORT_SCHEMA,
      schemaVersion: 1,
      kind: REPORT_KIND,
      scenario: "daemonDisconnect",
      settlement: disconnectedSettlement(),
      daemonState,
      daemonDisconnectSettlement: {
        trigger: "graceful-client-shutdown-after-greeting",
        activeRequestSettlementObserved: true,
        daemonStateObserved: true,
        settlementBeforeShutdownAck: true,
        shutdownAcknowledged: true,
        workingCopyPreserved: true,
      },
      protocol: { major: EXPECTED_PROTOCOL_MAJOR, minor: EXPECTED_PROTOCOL_MINOR },
      trust: { acknowledgedEpoch: trustEpoch, consistentUntilShutdown: true },
      authActivity,
      repositorySession: { opened: true, terminatedByShutdown: true },
      diagnosticsRedacted: true,
      redaction: { rawUrls: false, rawPaths: false, rawContent: false },
    };
  } finally {
    observation.dispose();
    subscription.dispose();
    if (session !== undefined && !shutdownStarted) {
      try { await options.shutdownBackend(); } catch { /* preserve the primary evidence error */ }
    }
  }
}

function disconnectedSettlement() {
  return {
    code: "SUBVERSIONR_REMOTE_WORKER_DISCONNECTED",
    category: "state",
    messageKey: "error.remote.workerDisconnected",
    retryable: false,
    safeArgs: {
      remoteFailure: { category: "process", reason: "workerContainmentFailed", cleanupAppropriate: false },
    },
    diagnostics: null,
  };
}

function requireWireDisconnect(error: unknown): void {
  if (
    !(error instanceof JsonRpcStreamError) || error.code !== "SUBVERSIONR_REMOTE_WORKER_DISCONNECTED" ||
    error.category !== "state" || error.messageKey !== "error.remote.workerDisconnected" ||
    error.retryable !== false || error.diagnostics !== null ||
    Object.keys(error.safeArgs).sort().join(",") !== "remoteFailure"
  ) throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DAEMON_DISCONNECT_WIRE_INVALID");
  const failure = error.safeArgs.remoteFailure;
  if (
    !isRecord(failure) || Object.keys(failure).sort().join(",") !== "category,cleanupAppropriate,reason" ||
    failure.category !== "process" || failure.reason !== "workerContainmentFailed" ||
    failure.cleanupAppropriate !== false
  ) throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DAEMON_DISCONNECT_FAILURE_INVALID");
}

function createDaemonStateObservation(operationId: string, ordering: string[]) {
  let terminal: RemoteConnectionNotification | undefined;
  let invalid = false;
  let resolveObserved!: () => void;
  let rejectObserved!: (error: unknown) => void;
  const observed = new Promise<void>((resolve, reject) => { resolveObserved = resolve; rejectObserved = reject; });
  const timer = setTimeout(() => rejectObserved(reportError(
    "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DAEMON_DISCONNECT_STATE_TIMEOUT",
  )), OBSERVATION_TIMEOUT_MS);
  return {
    onState: (notification: RemoteConnectionNotification) => {
      if (notification.state.kind === "checking") return;
      if (
        terminal !== undefined || notification.state.kind !== "indeterminate" ||
        notification.state.reason !== "workerTerminated" ||
        notification.state.originOperationId !== operationId || notification.state.recovery !== "notRequired" ||
        notification.state.cleanupAppropriate !== false
      ) {
        invalid = true;
        clearTimeout(timer);
        rejectObserved(reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DAEMON_DISCONNECT_STATE_INVALID"));
        return;
      }
      terminal = notification;
      ordering.push("daemonState");
      clearTimeout(timer);
      resolveObserved();
    },
    complete: async (session: RepositorySession): Promise<Record<string, unknown>> => {
      await observed;
      if (
        invalid || terminal === undefined || terminal.repositoryId !== session.repositoryId ||
        terminal.epoch !== session.epoch || terminal.state.kind !== "indeterminate"
      ) throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DAEMON_DISCONNECT_STATE_INVALID");
      return {
        kind: terminal.state.kind,
        reason: terminal.state.reason,
        originOperationIdMatched: terminal.state.originOperationId === operationId,
        recovery: terminal.state.recovery,
        cleanupAppropriate: terminal.state.cleanupAppropriate,
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
    state.kind !== "indeterminate" || state.reason !== "workerTerminated" ||
    state.recovery.kind !== "notRequired" || state.lastFailure?.reason !== "workerContainmentFailed" ||
    state.lastFailure.cleanupAppropriate !== false || state.incoming.kind !== "stale"
  ) throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DAEMON_DISCONNECT_STORED_STATE_INVALID");
}

async function waitForGreetingBarrier(
  options: InstalledSvnAnonymousDaemonDisconnectReportOptions,
  path: string,
  port: number,
): Promise<void> {
  const deadline = Date.now() + OBSERVATION_TIMEOUT_MS;
  do {
    const state = parseFixture(await readFixtureState(options, path), port);
    if (isGreetingBarrier(state)) return;
    if (
      state.connections > 1 || state.greetingSent > 1 || state.clientResponseReceived > 1 ||
      state.authRequestSent !== 0 || state.reposInfoSent !== 0 || state.commandsReceived !== 0 ||
      state.followupContacts !== 0
    ) throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DAEMON_DISCONNECT_FIXTURE_STATE_INVALID");
    await delay(10);
  } while (Date.now() < deadline);
  throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DAEMON_DISCONNECT_GREETING_TIMEOUT");
}

async function requireFreshShutdownTrigger(path: string): Promise<void> {
  try {
    await stat(path);
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DAEMON_DISCONNECT_TRIGGER_INVALID");
  } catch (error) {
    if (!isRecord(error) || error.code !== "ENOENT") throw error;
  }
  try {
    if (!(await stat(nodePath.dirname(path))).isDirectory()) throw new Error();
  } catch {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DAEMON_DISCONNECT_TRIGGER_INVALID");
  }
}

async function waitForShutdownTrigger(path: string): Promise<void> {
  const deadline = Date.now() + OBSERVATION_TIMEOUT_MS;
  do {
    try {
      const value = await stat(path);
      if (!value.isFile() || value.size !== 0) throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DAEMON_DISCONNECT_TRIGGER_INVALID");
      return;
    } catch (error) {
      if (!isRecord(error) || error.code !== "ENOENT") throw error;
    }
    await delay(10);
  } while (Date.now() < deadline);
  throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DAEMON_DISCONNECT_TRIGGER_TIMEOUT");
}

function parseRequest(value: unknown, expectedToken: string | undefined): DaemonDisconnectRequest {
  if (
    typeof expectedToken !== "string" || !/^[0-9a-f]{32}$/u.test(expectedToken) ||
    !isRecord(value) || value.token !== expectedToken
  ) throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DAEMON_DISCONNECT_FORBIDDEN");
  requireExactKeys(value, ["token", "repositoryUrl", "workingCopyPath", "operationId", "fixtureStatePath", "shutdownTriggerPath"]);
  if (
    typeof value.repositoryUrl !== "string" || value.repositoryUrl.length === 0 || /[\0\r\n]/u.test(value.repositoryUrl) ||
    typeof value.workingCopyPath !== "string" || !isAbsolutePath(value.workingCopyPath) || /[\0\r\n]/u.test(value.workingCopyPath) ||
    typeof value.fixtureStatePath !== "string" || !isAbsolutePath(value.fixtureStatePath) || /[\0\r\n]/u.test(value.fixtureStatePath) ||
    typeof value.shutdownTriggerPath !== "string" || !isAbsolutePath(value.shutdownTriggerPath) || /[\0\r\n]/u.test(value.shutdownTriggerPath) ||
    typeof value.operationId !== "string" || !isCanonicalOperationId(value.operationId)
  ) throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DAEMON_DISCONNECT_REQUEST_INVALID");
  return value as unknown as DaemonDisconnectRequest;
}

function createRemoteEnvelope(
  connection: DaemonDisconnectConnection,
  request: DaemonDisconnectRequest,
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
    timeoutMs: OPERATION_TIMEOUT_MS,
    profile: anonymousProfile(endpoint),
    expectedOrigin: endpoint,
  });
  if (remote.operationId !== request.operationId || remote.trustEpoch !== trustEpoch || remote.timeoutMs !== OPERATION_TIMEOUT_MS) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DAEMON_DISCONNECT_ENVELOPE_INVALID");
  }
  return remote;
}

function requireCapabilities(connection: DaemonDisconnectConnection): number {
  const initialize = connection.initializeResult;
  const capabilities = initialize.capabilities;
  if (
    initialize.protocol.major !== EXPECTED_PROTOCOL_MAJOR || initialize.protocol.minor !== EXPECTED_PROTOCOL_MINOR ||
    !capabilities.realLibsvnBridge || !capabilities.repositoryOpen || !capabilities.statusRemoteCheck ||
    !capabilities.remoteOperationEnvelope || !capabilities.remoteWorkerIsolation ||
    !capabilities.remoteConnectionState || !capabilities.remoteSvnAnonymous ||
    !connection.isRemoteSubmissionEnabled()
  ) throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DAEMON_DISCONNECT_CAPABILITY_UNAVAILABLE");
  const trustEpoch = initialize.acknowledgedTrustEpoch;
  if (!Number.isSafeInteger(trustEpoch) || trustEpoch < 1 || connection.currentRemoteTrustEpoch() !== trustEpoch) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DAEMON_DISCONNECT_TRUST_EPOCH_INVALID");
  }
  return trustEpoch;
}

function requireOpenedSession(session: RepositorySession, workingCopyPath: string, endpoint: CanonicalEndpoint): void {
  if (
    typeof session.repositoryId !== "string" || session.repositoryId.length === 0 ||
    !Number.isSafeInteger(session.epoch) || session.epoch < 1 ||
    normalizeAbsolutePath(session.identity.workingCopyRoot) !== normalizeAbsolutePath(workingCopyPath)
  ) throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DAEMON_DISCONNECT_OPEN_INVALID");
  let actual: CanonicalEndpoint;
  try { actual = canonicalEndpointFromRepositoryUrl(session.identity.repositoryRootUrl); }
  catch { throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DAEMON_DISCONNECT_OPEN_INVALID"); }
  if (!sameEndpoint(actual, endpoint)) throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DAEMON_DISCONNECT_OPEN_INVALID");
}

function requireLoopbackSvnOrigin(repositoryUrl: string): CanonicalEndpoint {
  let parsed: URL;
  let endpoint: CanonicalEndpoint;
  try { parsed = new URL(repositoryUrl); endpoint = canonicalEndpointFromRepositoryUrl(repositoryUrl); }
  catch { throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DAEMON_DISCONNECT_ORIGIN_INVALID"); }
  if (
    endpoint.scheme !== "svn" || (endpoint.canonicalHost !== "127.0.0.1" && endpoint.canonicalHost !== "::1") ||
    parsed.username.length !== 0 || parsed.password.length !== 0 || parsed.search.length !== 0 ||
    parsed.hash.length !== 0 || parsed.pathname.length === 0 || parsed.pathname === "/"
  ) throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DAEMON_DISCONNECT_ORIGIN_INVALID");
  return endpoint;
}

function anonymousProfile(endpoint: CanonicalEndpoint): RemoteAccessProfileSnapshot {
  return {
    schema: "subversionr.remote-profile.v1",
    profileId: "installed-i6-svn-anonymous-daemon-disconnect",
    authority: endpoint,
    serverAuth: "anonymous",
    serverAccount: "none",
    serverCredentialPersistence: "secretStorage",
    proxy: "none",
    ssh: "none",
    redirectPolicy: "rejectAll",
  };
}

interface FixtureState {
  connections: number; greetingSent: number; clientResponseReceived: number; authRequestSent: number;
  reposInfoSent: number; commandsReceived: number; followupContacts: number;
}
async function readFixtureState(options: InstalledSvnAnonymousDaemonDisconnectReportOptions, path: string): Promise<unknown> {
  try { return await options.readFixtureState(path); }
  catch { throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DAEMON_DISCONNECT_FIXTURE_STATE_INVALID"); }
}
function parseFixture(value: unknown, expectedPort: number): FixtureState {
  const keys = [
    "authRequestSent", "clientResponseReceived", "commandsReceived", "connections", "followupContacts",
    "greetingSent", "pid", "port", "reposInfoSent", "scenario", "schema", "status",
    "suppliedAuthorityConnections", "suppliedAuthorityPort",
  ];
  if (
    !isRecord(value) || Object.keys(value).sort().join(",") !== keys.sort().join(",") ||
    value.schema !== "subversionr.release.m8-i6-ra-svn-fault-fixture.v1" || value.scenario !== "greeting-stall" ||
    value.status !== "ready" || !Number.isSafeInteger(value.pid) || (value.pid as number) < 1 ||
    value.port !== expectedPort || value.suppliedAuthorityPort !== 0 || value.suppliedAuthorityConnections !== 0
  ) throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DAEMON_DISCONNECT_FIXTURE_STATE_INVALID");
  const counters = ["connections", "greetingSent", "clientResponseReceived", "authRequestSent", "reposInfoSent", "commandsReceived", "followupContacts"];
  if (counters.some((key) => !Number.isSafeInteger(value[key]) || (value[key] as number) < 0)) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DAEMON_DISCONNECT_FIXTURE_STATE_INVALID");
  }
  return value as unknown as FixtureState;
}
function requireFreshFixture(value: unknown, port: number): void {
  const state = parseFixture(value, port);
  if (
    state.connections !== 0 || state.greetingSent !== 0 || state.clientResponseReceived !== 0 ||
    state.authRequestSent !== 0 || state.reposInfoSent !== 0 || state.commandsReceived !== 0 ||
    state.followupContacts !== 0
  ) throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DAEMON_DISCONNECT_FIXTURE_STATE_INVALID");
}
function requireGreetingBarrier(value: unknown, port: number): void {
  if (!isGreetingBarrier(parseFixture(value, port))) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DAEMON_DISCONNECT_FIXTURE_STATE_INVALID");
  }
}
function isGreetingBarrier(state: FixtureState): boolean {
  return state.connections === 1 && state.greetingSent === 1 && state.clientResponseReceived === 1 &&
    state.authRequestSent === 0 && state.reposInfoSent === 0 && state.commandsReceived === 0 &&
    state.followupContacts === 0;
}

function requireRedacted(value: unknown, request: DaemonDisconnectRequest): void {
  let serialized: string;
  try { const candidate = JSON.stringify(value); if (typeof candidate !== "string") throw new Error(); serialized = candidate; }
  catch { throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DAEMON_DISCONNECT_DIAGNOSTICS_INVALID"); }
  if (Buffer.byteLength(serialized, "utf8") > 32_768) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DAEMON_DISCONNECT_DIAGNOSTICS_INVALID");
  }
  const normalized = serialized.toLowerCase();
  for (const sensitive of [
    request.token, request.repositoryUrl, request.workingCopyPath, request.workingCopyPath.replaceAll("\\", "/"),
    request.fixtureStatePath, request.fixtureStatePath.replaceAll("\\", "/"),
    request.shutdownTriggerPath, request.shutdownTriggerPath.replaceAll("\\", "/"), request.operationId,
  ]) if (normalized.includes(sensitive.toLowerCase())) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DAEMON_DISCONNECT_DIAGNOSTICS_LEAK");
  }
}
function requireStableTrust(connection: DaemonDisconnectConnection, trustEpoch: number): void {
  if (!connection.isRemoteSubmissionEnabled() || connection.currentRemoteTrustEpoch() !== trustEpoch) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DAEMON_DISCONNECT_TRUST_EPOCH_INVALID");
  }
}
function subtractAuthActivity(after: InstalledSvnAnonymousAuthActivity, before: InstalledSvnAnonymousAuthActivity) {
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
  ) throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DAEMON_DISCONNECT_AUTH_ACTIVITY_INVALID");
  return { ...value };
}
function requireExactKeys(value: Record<string, unknown>, keys: readonly string[]): void {
  if (Object.keys(value).sort().join(",") !== [...keys].sort().join(",")) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DAEMON_DISCONNECT_REQUEST_INVALID");
  }
}
function isCanonicalOperationId(value: string): boolean {
  return /^(?!00000000-0000-0000-0000-000000000000$)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u.test(value);
}
function isAbsolutePath(value: string): boolean { return nodePath.isAbsolute(value) || nodePath.win32.isAbsolute(value) || nodePath.posix.isAbsolute(value); }
function normalizeAbsolutePath(value: string): string { return nodePath.resolve(value).replace(/[\\/]+$/u, "").toLowerCase(); }
function sameEndpoint(left: CanonicalEndpoint, right: CanonicalEndpoint): boolean { return left.scheme === right.scheme && left.canonicalHost === right.canonicalHost && left.effectivePort === right.effectivePort; }
function isRecord(value: unknown): value is Record<string, unknown> { return typeof value === "object" && value !== null && !Array.isArray(value); }
function delay(milliseconds: number): Promise<void> { return new Promise((resolve) => setTimeout(resolve, milliseconds)); }

export class InstalledSvnAnonymousDaemonDisconnectReportError extends Error {
  public readonly messageKey = "error.diagnostics.installedSvnAnonymousDaemonDisconnectReportInvalid";
  public constructor(public readonly code: string) { super(code); this.name = "InstalledSvnAnonymousDaemonDisconnectReportError"; }
}
function reportError(code: string): InstalledSvnAnonymousDaemonDisconnectReportError {
  return new InstalledSvnAnonymousDaemonDisconnectReportError(code);
}
