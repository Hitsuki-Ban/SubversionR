import * as nodePath from "node:path";
import type { BackendConnection } from "../backend/backendProcess";
import type { RepositorySession } from "../repository/repositorySessionService";
import {
  RemoteOperationEnvelopeFactory,
  canonicalEndpointFromRepositoryUrl,
  type CanonicalEndpoint,
  type RemoteAccessProfileSnapshot,
  type RemoteOperationEnvelope,
} from "../security/remoteAccessProfile";
import { StatusSnapshotRpcClient } from "../status/statusSnapshotRpcClient";
import { JsonRpcStreamError } from "../transport/jsonRpcStreamClient";
import type { InstalledSvnAnonymousAuthActivity } from "./installedSvnAnonymousReport";

const EXPECTED_PROTOCOL_MAJOR = 1;
const EXPECTED_PROTOCOL_MINOR = 35;
const INITIAL_TRUST_EPOCH = 1;
const REVOKED_TRUST_EPOCH = 2;
const OPERATION_TIMEOUT_MS = 30_000;
const REPORT_SCHEMA = "subversionr.release.m8-i6-installed-vsix-trust-revoked.v1";
const REPORT_KIND = "subversionr.installedSvnAnonymousTrustRevokedReport";
const FIXTURE_SCHEMA = "subversionr.release.m8-i6-ra-svn-fault-fixture.v1";
const MAX_REDACTION_VALUE_BYTES = 32_768;

type TrustRevokedConnection = Pick<
  BackendConnection,
  | "initializeResult"
  | "isRemoteSubmissionEnabled"
  | "currentRemoteTrustEpoch"
  | "updateWorkspaceTrust"
  | "sendRequest"
>;

export interface InstalledSvnAnonymousTrustRevokedReportOptions {
  expectedToken: string | undefined;
  request: unknown;
  initialize(): Promise<TrustRevokedConnection>;
  openWorkingCopy(path: string): Promise<RepositorySession>;
  closeRepository(repositoryId: string): Promise<void>;
  authActivity(): InstalledSvnAnonymousAuthActivity;
  readFixtureState(path: string): Promise<unknown>;
}

interface InstalledSvnAnonymousTrustRevokedRequest {
  token: string;
  repositoryUrl: string;
  workingCopyPath: string;
  operationId: string;
  fixtureStatePath: string;
}

export async function collectInstalledSvnAnonymousTrustRevokedReport(
  options: InstalledSvnAnonymousTrustRevokedReportOptions,
): Promise<Record<string, unknown>> {
  const request = parseRequest(options.request, options.expectedToken);
  const endpoint = requireLoopbackSvnOrigin(request.repositoryUrl);
  requireFixtureZeroState(await readFixtureStateValue(options, request.fixtureStatePath), endpoint.effectivePort);
  const authBefore = requireAuthActivity(options.authActivity());
  const connection = await options.initialize();
  requireCandidateCapabilities(connection);
  const staleRemote = createEpochOneEnvelope(connection, request, endpoint);

  let session: RepositorySession | undefined;
  let staleEnvelopeRejected = false;
  let localSnapshotAfterTrustRevocation = false;
  try {
    session = await options.openWorkingCopy(request.workingCopyPath);
    requireOpenedSession(session, request.workingCopyPath, endpoint);
    requireTrustedEpochOne(connection);

    let acknowledgedTrustEpoch: number;
    try {
      acknowledgedTrustEpoch = await connection.updateWorkspaceTrust(false);
    } catch {
      throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_TRUST_REVOKED_ACK_INVALID");
    }
    if (acknowledgedTrustEpoch !== REVOKED_TRUST_EPOCH) {
      throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_TRUST_REVOKED_ACK_INVALID");
    }
    requireRevokedTrust(connection);

    let staleError: unknown;
    try {
      await connection.sendRequest<unknown>("status/checkRemote", {
        repositoryId: session.repositoryId,
        epoch: session.epoch,
        remote: staleRemote,
      });
    } catch (error) {
      staleError = error;
    }
    requireTrustEpochMismatch(staleError);
    requireRedacted(staleError, request);
    staleEnvelopeRejected = true;
    requireRevokedTrust(connection);

    const snapshot = await new StatusSnapshotRpcClient(connection).getSnapshot({
      repositoryId: session.repositoryId,
      epoch: session.epoch,
    });
    if (
      snapshot.repositoryId !== session.repositoryId ||
      snapshot.epoch !== session.epoch ||
      snapshot.source !== "libsvn-local"
    ) {
      throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_TRUST_REVOKED_LOCAL_SNAPSHOT_INVALID");
    }
    localSnapshotAfterTrustRevocation = true;
    requireRevokedTrust(connection);

    let diagnostics: unknown;
    try {
      diagnostics = await connection.sendRequest<unknown>("diagnostics/get", {});
    } catch {
      throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_TRUST_REVOKED_DIAGNOSTICS_INVALID");
    }
    requireCurrentRedactedDiagnostics(diagnostics, request);
    requireRevokedTrust(connection);
    requireFixtureZeroState(await readFixtureStateValue(options, request.fixtureStatePath), endpoint.effectivePort);
  } finally {
    if (session !== undefined) {
      await options.closeRepository(session.repositoryId);
    }
  }

  requireRevokedTrust(connection);
  const authActivity = subtractAuthActivity(requireAuthActivity(options.authActivity()), authBefore);
  if (
    authActivity.credentialRequests !== 0 ||
    authActivity.credentialSettlements !== 0 ||
    authActivity.certificateRequests !== 0
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_TRUST_REVOKED_AUTH_ACTIVITY_INVALID");
  }
  if (!staleEnvelopeRejected || !localSnapshotAfterTrustRevocation) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_TRUST_REVOKED_SETTLEMENT_INVALID");
  }

  return {
    schema: REPORT_SCHEMA,
    schemaVersion: 1,
    kind: REPORT_KIND,
    scenario: "trustRevoked",
    settlement: {
      code: "SUBVERSIONR_REMOTE_TRUST_EPOCH_MISMATCH",
      category: "state",
      messageKey: "error.remote.trustEpochMismatch",
      retryable: false,
      remoteFailure: {
        category: "configuration",
        reason: "remoteConfigurationInvalid",
        cleanupAppropriate: false,
      },
    },
    diagnostics: null,
    remoteSubmissionDisabled: true,
    localSnapshotAfterTrustRevocation: true,
    protocol: { major: EXPECTED_PROTOCOL_MAJOR, minor: EXPECTED_PROTOCOL_MINOR },
    trust: {
      initialAcknowledgedEpoch: INITIAL_TRUST_EPOCH,
      revokedAcknowledgedEpoch: REVOKED_TRUST_EPOCH,
      submissionEnabled: false,
      consistent: true,
    },
    authActivity,
    repositorySession: { opened: true, closed: true },
    diagnosticsRedacted: true,
    redaction: { rawUrls: false, rawPaths: false, rawContent: false },
  };
}

function parseRequest(
  value: unknown,
  expectedToken: string | undefined,
): InstalledSvnAnonymousTrustRevokedRequest {
  if (typeof expectedToken !== "string" || expectedToken.length === 0 || !isRecord(value)) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_TRUST_REVOKED_FORBIDDEN");
  }
  if (value.token !== expectedToken) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_TRUST_REVOKED_FORBIDDEN");
  }
  requireExactKeys(value, ["token", "repositoryUrl", "workingCopyPath", "operationId", "fixtureStatePath"]);
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
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_TRUST_REVOKED_REQUEST_INVALID");
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
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_TRUST_REVOKED_ORIGIN_INVALID");
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
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_TRUST_REVOKED_ORIGIN_INVALID");
  }
  return endpoint;
}

function requireCandidateCapabilities(connection: TrustRevokedConnection): void {
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
    typeof connection.updateWorkspaceTrust !== "function"
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_TRUST_REVOKED_CAPABILITY_UNAVAILABLE");
  }
  requireTrustedEpochOne(connection);
}

function createEpochOneEnvelope(
  connection: TrustRevokedConnection,
  request: InstalledSvnAnonymousTrustRevokedRequest,
  endpoint: CanonicalEndpoint,
): RemoteOperationEnvelope {
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
    remote.trustEpoch !== INITIAL_TRUST_EPOCH ||
    !sameEndpoint(remote.expectedOrigin, endpoint)
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_TRUST_REVOKED_ENVELOPE_INVALID");
  }
  return remote;
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
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_TRUST_REVOKED_OPEN_INVALID");
  }
  let actualEndpoint: CanonicalEndpoint;
  try {
    actualEndpoint = canonicalEndpointFromRepositoryUrl(session.identity.repositoryRootUrl);
  } catch {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_TRUST_REVOKED_OPEN_INVALID");
  }
  if (!sameEndpoint(actualEndpoint, endpoint)) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_TRUST_REVOKED_OPEN_INVALID");
  }
}

function requireTrustEpochMismatch(error: unknown): void {
  if (
    !(error instanceof JsonRpcStreamError) ||
    error.code !== "SUBVERSIONR_REMOTE_TRUST_EPOCH_MISMATCH" ||
    error.category !== "state" ||
    error.messageKey !== "error.remote.trustEpochMismatch" ||
    error.retryable !== false ||
    error.diagnostics !== null ||
    Object.keys(error.safeArgs).sort().join(",") !== "remoteFailure"
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_TRUST_REVOKED_SETTLEMENT_INVALID");
  }
  const remoteFailure = error.safeArgs.remoteFailure;
  if (
    !isRecord(remoteFailure) ||
    Object.keys(remoteFailure).sort().join(",") !== "category,cleanupAppropriate,reason" ||
    remoteFailure.category !== "configuration" ||
    remoteFailure.reason !== "remoteConfigurationInvalid" ||
    remoteFailure.cleanupAppropriate !== false
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_TRUST_REVOKED_SETTLEMENT_INVALID");
  }
}

async function readFixtureStateValue(
  options: InstalledSvnAnonymousTrustRevokedReportOptions,
  fixtureStatePath: string,
): Promise<unknown> {
  try {
    return await options.readFixtureState(fixtureStatePath);
  } catch {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_TRUST_REVOKED_FIXTURE_STATE_INVALID");
  }
}

function requireFixtureZeroState(value: unknown, expectedPort: number): void {
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
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_TRUST_REVOKED_FIXTURE_STATE_INVALID");
  }
  for (const key of [
    "connections", "greetingSent", "clientResponseReceived", "authRequestSent",
    "reposInfoSent", "commandsReceived", "followupContacts",
  ]) {
    if (value[key] !== 0) {
      throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_TRUST_REVOKED_FIXTURE_STATE_INVALID");
    }
  }
}

function requireCurrentRedactedDiagnostics(
  value: unknown,
  request: InstalledSvnAnonymousTrustRevokedRequest,
): void {
  if (!isRecord(value) || value.source !== "subversionr-daemon" || !isRecord(value.protocol)) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_TRUST_REVOKED_DIAGNOSTICS_INVALID");
  }
  if (
    value.protocol.major !== EXPECTED_PROTOCOL_MAJOR ||
    value.protocol.minor !== EXPECTED_PROTOCOL_MINOR ||
    !isRecord(value.capabilities) ||
    value.capabilities.remoteSvnAnonymous !== true ||
    value.capabilities.statusRemoteCheck !== true ||
    value.capabilities.statusSnapshot !== true
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_TRUST_REVOKED_DIAGNOSTICS_INVALID");
  }
  requireRedacted(value, request);
}

function requireRedacted(value: unknown, request: InstalledSvnAnonymousTrustRevokedRequest): void {
  let serialized: string;
  try {
    const candidate = JSON.stringify(value);
    if (typeof candidate !== "string") {
      throw new Error("invalid serialization");
    }
    serialized = candidate;
  } catch {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_TRUST_REVOKED_DIAGNOSTICS_INVALID");
  }
  if (Buffer.byteLength(serialized, "utf8") > MAX_REDACTION_VALUE_BYTES) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_TRUST_REVOKED_DIAGNOSTICS_INVALID");
  }
  const sensitive = [
    request.token,
    request.repositoryUrl,
    request.workingCopyPath,
    request.workingCopyPath.replaceAll("\\", "/"),
    request.fixtureStatePath,
    request.fixtureStatePath.replaceAll("\\", "/"),
    request.operationId,
  ].flatMap((entry) => [entry, jsonEscapedStringContent(entry)]).map((entry) => entry.toLowerCase());
  const normalized = serialized.toLowerCase();
  if (sensitive.some((entry) => normalized.includes(entry))) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_TRUST_REVOKED_DIAGNOSTICS_LEAK");
  }
}

function jsonEscapedStringContent(value: string): string {
  const serialized = JSON.stringify(value);
  return serialized.slice(1, -1);
}

function anonymousLoopbackProfile(endpoint: CanonicalEndpoint): RemoteAccessProfileSnapshot {
  return {
    schema: "subversionr.remote-profile.v1",
    profileId: "installed-i6-svn-anonymous-trust-revoked",
    authority: endpoint,
    serverAuth: "anonymous",
    serverAccount: "none",
    serverCredentialPersistence: "secretStorage",
    proxy: "none",
    ssh: "none",
    redirectPolicy: "rejectAll",
  };
}

function requireTrustedEpochOne(connection: TrustRevokedConnection): void {
  if (
    connection.initializeResult.acknowledgedTrustEpoch !== INITIAL_TRUST_EPOCH ||
    connection.currentRemoteTrustEpoch() !== INITIAL_TRUST_EPOCH ||
    !connection.isRemoteSubmissionEnabled()
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_TRUST_REVOKED_TRUST_EPOCH_INVALID");
  }
}

function requireRevokedTrust(connection: TrustRevokedConnection): void {
  if (
    connection.currentRemoteTrustEpoch() !== REVOKED_TRUST_EPOCH ||
    connection.isRemoteSubmissionEnabled()
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_TRUST_REVOKED_TRUST_EPOCH_INVALID");
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
    !isRecord(value) ||
    !Number.isSafeInteger(value.credentialRequests) ||
    value.credentialRequests < 0 ||
    !Number.isSafeInteger(value.credentialSettlements) ||
    value.credentialSettlements < 0 ||
    !Number.isSafeInteger(value.certificateRequests) ||
    value.certificateRequests < 0
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_TRUST_REVOKED_AUTH_ACTIVITY_INVALID");
  }
  return { ...value };
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
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_TRUST_REVOKED_REQUEST_INVALID");
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

export class InstalledSvnAnonymousTrustRevokedReportError extends Error {
  public readonly messageKey = "error.diagnostics.installedSvnAnonymousTrustRevokedReportInvalid";

  public constructor(public readonly code: string) {
    super(code);
    this.name = "InstalledSvnAnonymousTrustRevokedReportError";
  }
}

function reportError(code: string): InstalledSvnAnonymousTrustRevokedReportError {
  return new InstalledSvnAnonymousTrustRevokedReportError(code);
}
