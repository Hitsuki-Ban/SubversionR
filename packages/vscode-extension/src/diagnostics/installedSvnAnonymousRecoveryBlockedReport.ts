import { createHash } from "node:crypto";
import * as nodePath from "node:path";
import type { BackendConnection } from "../backend/backendProcess";
import {
  CheckoutTargetRecoveryRpcClient,
  type CheckoutTargetRecoveryEntry,
} from "../repository/checkoutTargetRecoveryRpcClient";
import { RepositoryCheckoutRpcClient } from "../repository/repositoryCheckoutRpcClient";
import {
  RemoteOperationEnvelopeFactory,
  canonicalEndpointFromRepositoryUrl,
  type CanonicalEndpoint,
  type RemoteAccessProfileSnapshot,
} from "../security/remoteAccessProfile";
import { JsonRpcStreamError } from "../transport/jsonRpcStreamClient";
import type { InstalledSvnAnonymousAuthActivity } from "./installedSvnAnonymousReport";

const EXPECTED_PROTOCOL_MAJOR = 1;
const EXPECTED_PROTOCOL_MINOR = 35;
const REPORT_SCHEMA = "subversionr.release.m8-i6-installed-vsix-recovery-blocked.v1";
const REPORT_KIND = "subversionr.installedSvnAnonymousRecoveryBlockedReport";
const OPERATION_TIMEOUT_MS = 5_000;
const FRESH_CHECKOUT_TIMEOUT_MS = 300_000;
const MAX_REDACTION_VALUE_BYTES = 32_768;

type RecoveryBlockedConnection = Pick<
  BackendConnection,
  "initializeResult" | "isRemoteSubmissionEnabled" | "currentRemoteTrustEpoch" | "sendRequest"
>;

export interface InstalledSvnAnonymousRecoveryBlockedReportOptions {
  expectedToken: string | undefined;
  request: unknown;
  initialize(): Promise<RecoveryBlockedConnection>;
  authActivity(): InstalledSvnAnonymousAuthActivity;
  readFixtureState(path: string): Promise<unknown>;
  targetPathExists(path: string): boolean;
}

type RecoveryBlockedRequest = ArmRequest | RecoverRequest;

interface CommonRequest {
  token: string;
  phase: "arm" | "recover";
  targetPath: string;
  operationId: string;
}

interface ArmRequest extends CommonRequest {
  phase: "arm";
  repositoryUrl: string;
  timeoutMs: 5_000;
}

interface RecoverRequest extends CommonRequest {
  phase: "recover";
  faultRepositoryUrl: string;
  healthyRepositoryUrl: string;
  retryOperationId: string;
  freshOperationId: string;
  fixtureStatePath: string;
  timeoutMs: 300_000;
}

export async function collectInstalledSvnAnonymousRecoveryBlockedReport(
  options: InstalledSvnAnonymousRecoveryBlockedReportOptions,
): Promise<Record<string, unknown>> {
  const request = parseRequest(options.request, options.expectedToken);
  const authBefore = requireAuthActivity(options.authActivity());
  const connection = await options.initialize();
  const trustEpoch = requireCandidateCapabilities(connection);
  const recovery = new CheckoutTargetRecoveryRpcClient(connection);

  let phaseReport: Record<string, unknown>;
  if (request.phase === "arm") {
    phaseReport = await armBlockedCheckout(connection, recovery, request, trustEpoch);
  } else {
    phaseReport = await recoverBlockedCheckout(
      connection,
      recovery,
      request,
      trustEpoch,
      options.readFixtureState,
      options.targetPathExists,
    );
  }
  requireStableTrust(connection, trustEpoch);
  const authActivity = subtractAuthActivity(requireAuthActivity(options.authActivity()), authBefore);
  if (
    authActivity.credentialRequests !== 0 ||
    authActivity.credentialSettlements !== 0 ||
    authActivity.certificateRequests !== 0
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_BLOCKED_AUTH_ACTIVITY_INVALID");
  }
  requireRedacted(phaseReport, request);
  return {
    schema: REPORT_SCHEMA,
    schemaVersion: 1,
    kind: REPORT_KIND,
    phase: request.phase,
    ...phaseReport,
    protocol: { major: EXPECTED_PROTOCOL_MAJOR, minor: EXPECTED_PROTOCOL_MINOR },
    trust: { acknowledgedEpoch: trustEpoch, consistent: true },
    authActivity,
    diagnosticsRedacted: true,
    redaction: { rawUrls: false, rawPaths: false, rawContent: false },
  };
}

async function armBlockedCheckout(
  connection: RecoveryBlockedConnection,
  recovery: CheckoutTargetRecoveryRpcClient,
  request: ArmRequest,
  trustEpoch: number,
): Promise<Record<string, unknown>> {
  const endpoint = requireLoopbackSvnOrigin(request.repositoryUrl);
  const remote = createRemoteEnvelope(
    connection,
    request.operationId,
    endpoint,
    trustEpoch,
    OPERATION_TIMEOUT_MS,
  );
  let observedError: unknown;
  try {
    await new RepositoryCheckoutRpcClient(connection).checkout({
      url: request.repositoryUrl,
      targetPath: request.targetPath,
      revision: "head",
      depth: "infinity",
      ignoreExternals: true,
      remote,
    });
  } catch (error) {
    observedError = error;
  }
  if (observedError === undefined) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_BLOCKED_UNEXPECTED_SUCCESS");
  }
  requireBlockedSettlement(observedError);
  requireRedacted(observedError, request);
  requireStableTrust(connection, trustEpoch);
  const entry = requireOnlyBlockedEntry(await recovery.list(), request);
  return {
    originCode: "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT",
    originReason: "operationDeadlineExceeded",
    settlementCode: "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED",
    settlementReason: "remoteRecoveryBlocked",
    blockedEntryCount: 1,
    blockedEntryState: "blocked",
    blockedTargetPathSha256: sha256(entry.targetPath),
    blockedOriginOperationIdSha256: sha256(entry.originOperationId),
  };
}

async function recoverBlockedCheckout(
  connection: RecoveryBlockedConnection,
  recovery: CheckoutTargetRecoveryRpcClient,
  request: RecoverRequest,
  trustEpoch: number,
  readFixtureState: (path: string) => Promise<unknown>,
  targetPathExists: (path: string) => boolean,
): Promise<Record<string, unknown>> {
  const before = await recovery.list();
  const entry = requireOnlyBlockedEntry(before, request);
  const faultEndpoint = requireLoopbackSvnOrigin(request.faultRepositoryUrl);
  const beforeFixture = requireCommandStallFixtureState(
    await readFixtureState(request.fixtureStatePath),
  );
  const retryRemote = createRemoteEnvelope(
    connection,
    request.retryOperationId,
    faultEndpoint,
    trustEpoch,
    FRESH_CHECKOUT_TIMEOUT_MS,
  );
  let retryError: unknown;
  try {
    await new RepositoryCheckoutRpcClient(connection).checkout({
      url: request.faultRepositoryUrl,
      targetPath: request.targetPath,
      revision: "head",
      depth: "infinity",
      ignoreExternals: true,
      remote: retryRemote,
    });
  } catch (error) {
    retryError = error;
  }
  requireLocalBlockedRetry(retryError);
  requireRedacted(retryError, request);
  const afterFixture = requireCommandStallFixtureState(
    await readFixtureState(request.fixtureStatePath),
  );
  if (JSON.stringify(afterFixture) !== JSON.stringify(beforeFixture)) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_BLOCKED_NETWORK_PROGRESS_INVALID");
  }
  if ((await recovery.list()).length !== 1) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_BLOCKED_AUTOMATIC_CLEAR");
  }
  if (targetPathExists(request.targetPath)) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_BLOCKED_TARGET_DISPOSITION_INVALID");
  }
  const confirmed = await recovery.confirm({
    targetPath: entry.targetPath,
    targetSha256: entry.targetSha256,
    originOperationId: entry.originOperationId,
    confirmation: "reviewedAndResolved",
  });
  if (
    confirmed.released !== true ||
    confirmed.targetSha256 !== entry.targetSha256 ||
    confirmed.originOperationId !== entry.originOperationId
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_BLOCKED_CONFIRMATION_INVALID");
  }
  if ((await recovery.list()).length !== 0) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_BLOCKED_ENTRY_RETAINED");
  }
  const healthyEndpoint = requireLoopbackSvnOrigin(request.healthyRepositoryUrl);
  const freshRemote = createRemoteEnvelope(
    connection,
    request.freshOperationId,
    healthyEndpoint,
    trustEpoch,
    FRESH_CHECKOUT_TIMEOUT_MS,
  );
  const checkout = await new RepositoryCheckoutRpcClient(connection).checkout({
    url: request.healthyRepositoryUrl,
    targetPath: request.targetPath,
    revision: "head",
    depth: "infinity",
    ignoreExternals: true,
    remote: freshRemote,
  });
  if (
    normalizeAbsolutePath(checkout.workingCopyPath) !== normalizeAbsolutePath(request.targetPath) ||
    !Number.isSafeInteger(checkout.revision) ||
    checkout.revision < 0 ||
    (await recovery.list()).length !== 0
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_BLOCKED_FRESH_CHECKOUT_INVALID");
  }
  return {
    outcome: "Blocked",
    stableCode: "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED",
    reason: "remoteRecoveryBlocked",
    restartRestoredBlocked: true,
    automaticClear: false,
    requiredConfirmation: "reviewedAndResolved",
    armedTargetPathSha256: sha256(entry.targetPath),
    confirmedTargetPathSha256: sha256(entry.targetPath),
    armedOriginOperationIdSha256: sha256(entry.originOperationId),
    confirmedOriginOperationIdSha256: sha256(entry.originOperationId),
    confirmedEntryRemoved: true,
    fixtureCountersUnchangedOnBlockedRetry: true,
    targetDisposition: "confirmedAbsent",
    subsequentCheckoutPassed: true,
    checkoutRevision: checkout.revision,
  };
}

function createRemoteEnvelope(
  connection: RecoveryBlockedConnection,
  operationId: string,
  endpoint: CanonicalEndpoint,
  trustEpoch: number,
  timeoutMs: number,
) {
  const remote = new RemoteOperationEnvelopeFactory({
    remoteSvnAnonymous: connection.initializeResult.capabilities.remoteSvnAnonymous,
    isRemoteSubmissionEnabled: () => connection.isRemoteSubmissionEnabled(),
    currentRemoteTrustEpoch: () => connection.currentRemoteTrustEpoch(),
  }).createAnonymousSvn({
    operationId,
    intent: "foreground",
    interaction: "forbidden",
    timeoutMs,
    profile: anonymousLoopbackProfile(endpoint),
    expectedOrigin: endpoint,
  });
  if (
    remote.operationId !== operationId ||
    remote.timeoutMs !== timeoutMs ||
    remote.trustEpoch !== trustEpoch ||
    !sameEndpoint(remote.expectedOrigin, endpoint)
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_BLOCKED_ENVELOPE_INVALID");
  }
  return remote;
}

function requireLocalBlockedRetry(error: unknown): void {
  if (
    !(error instanceof JsonRpcStreamError) ||
    error.code !== "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED" ||
    error.category !== "state" ||
    error.messageKey !== "error.remote.recoveryBlocked" ||
    error.retryable !== false ||
    error.diagnostics !== null ||
    Object.keys(error.safeArgs).length !== 0
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_BLOCKED_RETRY_INVALID");
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
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_BLOCKED_FIXTURE_STATE_INVALID");
  }
  const fields = [
    "connections",
    "suppliedAuthorityConnections",
    "greetingSent",
    "clientResponseReceived",
    "authRequestSent",
    "reposInfoSent",
    "commandsReceived",
    "followupContacts",
  ] as const;
  const result = {} as Record<(typeof fields)[number], number>;
  for (const field of fields) {
    const candidate = value[field];
    if (!Number.isSafeInteger(candidate) || (candidate as number) < 0) {
      throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_BLOCKED_FIXTURE_STATE_INVALID");
    }
    result[field] = candidate as number;
  }
  return result;
}

function requireBlockedSettlement(error: unknown): void {
  if (
    !(error instanceof JsonRpcStreamError) ||
    error.code !== "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED" ||
    error.category !== "state" ||
    error.messageKey !== "error.remote.recoveryBlocked" ||
    error.retryable !== false ||
    error.diagnostics !== null ||
    Object.keys(error.safeArgs).sort().join(",") !== "originFailureCode,remoteFailure" ||
    error.safeArgs.originFailureCode !== "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT"
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_BLOCKED_SETTLEMENT_INVALID");
  }
  const remoteFailure = error.safeArgs.remoteFailure;
  if (
    !isRecord(remoteFailure) ||
    Object.keys(remoteFailure).sort().join(",") !== "category,cleanupAppropriate,reason" ||
    remoteFailure.category !== "recovery" ||
    remoteFailure.reason !== "remoteRecoveryBlocked" ||
    remoteFailure.cleanupAppropriate !== false
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_BLOCKED_SETTLEMENT_INVALID");
  }
}

function requireOnlyBlockedEntry(
  entries: readonly CheckoutTargetRecoveryEntry[],
  request: Pick<CommonRequest, "targetPath" | "operationId">,
): CheckoutTargetRecoveryEntry {
  if (entries.length !== 1) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_BLOCKED_ENTRY_INVALID");
  }
  const entry = entries[0];
  if (
    entry.state !== "blocked" ||
    normalizeAbsolutePath(entry.targetPath) !== normalizeAbsolutePath(request.targetPath) ||
    entry.originOperationId !== request.operationId
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_BLOCKED_ENTRY_INVALID");
  }
  return entry;
}

function parseRequest(value: unknown, expectedToken: string | undefined): RecoveryBlockedRequest {
  if (typeof expectedToken !== "string" || expectedToken.length === 0 || !isRecord(value)) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_BLOCKED_FORBIDDEN");
  }
  if (value.token !== expectedToken) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_BLOCKED_FORBIDDEN");
  }
  if (value.phase !== "arm" && value.phase !== "recover") {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_BLOCKED_REQUEST_INVALID");
  }
  if (value.phase === "recover") {
    requireExactKeys(value, [
      "token", "phase", "faultRepositoryUrl", "healthyRepositoryUrl", "targetPath", "operationId",
      "retryOperationId", "freshOperationId", "fixtureStatePath", "timeoutMs",
    ]);
    if (
      typeof value.faultRepositoryUrl !== "string" || value.faultRepositoryUrl.length === 0 || /[\0\r\n]/u.test(value.faultRepositoryUrl) ||
      typeof value.healthyRepositoryUrl !== "string" || value.healthyRepositoryUrl.length === 0 || /[\0\r\n]/u.test(value.healthyRepositoryUrl) ||
      typeof value.fixtureStatePath !== "string" || value.fixtureStatePath.length === 0 || !isAbsolutePath(value.fixtureStatePath) || /[\0\r\n]/u.test(value.fixtureStatePath) ||
      value.timeoutMs !== FRESH_CHECKOUT_TIMEOUT_MS
    ) {
      throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_BLOCKED_REQUEST_INVALID");
    }
    const operationId = requireOperationId(value.operationId);
    const retryOperationId = requireOperationId(value.retryOperationId);
    const freshOperationId = requireOperationId(value.freshOperationId);
    if (new Set([operationId, retryOperationId, freshOperationId]).size !== 3) {
      throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_BLOCKED_REQUEST_INVALID");
    }
    return {
      token: expectedToken,
      phase: "recover",
      faultRepositoryUrl: value.faultRepositoryUrl,
      healthyRepositoryUrl: value.healthyRepositoryUrl,
      targetPath: requireTargetPath(value.targetPath),
      operationId,
      retryOperationId,
      freshOperationId,
      fixtureStatePath: value.fixtureStatePath,
      timeoutMs: FRESH_CHECKOUT_TIMEOUT_MS,
    };
  }
  requireExactKeys(value, ["token", "phase", "repositoryUrl", "targetPath", "operationId", "timeoutMs"]);
  if (
    typeof value.repositoryUrl !== "string" ||
    value.repositoryUrl.length === 0 ||
    /[\0\r\n]/u.test(value.repositoryUrl) ||
    value.timeoutMs !== OPERATION_TIMEOUT_MS
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_BLOCKED_REQUEST_INVALID");
  }
  return {
    token: expectedToken,
    phase: "arm",
    repositoryUrl: value.repositoryUrl,
    targetPath: requireTargetPath(value.targetPath),
    operationId: requireOperationId(value.operationId),
    timeoutMs: OPERATION_TIMEOUT_MS,
  };
}

function requireTargetPath(value: unknown): string {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    value.length > 32 * 1024 ||
    !isAbsolutePath(value) ||
    /[\0\r\n]/u.test(value)
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_BLOCKED_REQUEST_INVALID");
  }
  return value;
}

function requireOperationId(value: unknown): string {
  if (
    typeof value !== "string" ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u.test(value) ||
    value === "00000000-0000-0000-0000-000000000000"
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_BLOCKED_REQUEST_INVALID");
  }
  return value;
}

function requireCandidateCapabilities(connection: RecoveryBlockedConnection): number {
  const initialize = connection.initializeResult;
  if (
    initialize.protocol.major !== EXPECTED_PROTOCOL_MAJOR ||
    initialize.protocol.minor !== EXPECTED_PROTOCOL_MINOR ||
    !initialize.capabilities.realLibsvnBridge ||
    !initialize.capabilities.repositoryCheckout ||
    !initialize.capabilities.remoteOperationEnvelope ||
    !initialize.capabilities.remoteWorkerIsolation ||
    !initialize.capabilities.remoteSvnAnonymous ||
    !connection.isRemoteSubmissionEnabled()
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_BLOCKED_CAPABILITY_UNAVAILABLE");
  }
  const trustEpoch = initialize.acknowledgedTrustEpoch;
  if (
    !Number.isSafeInteger(trustEpoch) ||
    trustEpoch < 1 ||
    connection.currentRemoteTrustEpoch() !== trustEpoch
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_BLOCKED_TRUST_EPOCH_INVALID");
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
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_BLOCKED_ORIGIN_INVALID");
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
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_BLOCKED_ORIGIN_INVALID");
  }
  return endpoint;
}

function anonymousLoopbackProfile(endpoint: CanonicalEndpoint): RemoteAccessProfileSnapshot {
  return {
    schema: "subversionr.remote-profile.v1",
    profileId: "installed-i6-svn-anonymous-recovery-blocked",
    authority: endpoint,
    serverAuth: "anonymous",
    serverAccount: "none",
    serverCredentialPersistence: "secretStorage",
    proxy: "none",
    ssh: "none",
    redirectPolicy: "rejectAll",
  };
}

function requireRedacted(value: unknown, request: RecoveryBlockedRequest): void {
  let serialized: string;
  try {
    const candidate = JSON.stringify(value);
    if (typeof candidate !== "string") throw new Error("invalid serialization");
    serialized = candidate;
  } catch {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_BLOCKED_DIAGNOSTICS_INVALID");
  }
  if (Buffer.byteLength(serialized, "utf8") > MAX_REDACTION_VALUE_BYTES) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_BLOCKED_DIAGNOSTICS_INVALID");
  }
  const sensitive = [
    request.token,
    request.targetPath,
    request.targetPath.replaceAll("\\", "/"),
    JSON.stringify(request.targetPath).slice(1, -1),
    request.operationId,
    ...(request.phase === "arm"
      ? [request.repositoryUrl]
      : [
          request.faultRepositoryUrl,
          request.healthyRepositoryUrl,
          request.retryOperationId,
          request.freshOperationId,
          request.fixtureStatePath,
          request.fixtureStatePath.replaceAll("\\", "/"),
          JSON.stringify(request.fixtureStatePath).slice(1, -1),
        ]),
  ].map((entry) => entry.toLowerCase());
  const normalized = serialized.toLowerCase();
  if (sensitive.some((entry) => entry.length > 0 && normalized.includes(entry))) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_BLOCKED_DIAGNOSTICS_LEAK");
  }
}

function requireStableTrust(connection: RecoveryBlockedConnection, trustEpoch: number): void {
  if (!connection.isRemoteSubmissionEnabled() || connection.currentRemoteTrustEpoch() !== trustEpoch) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_BLOCKED_TRUST_EPOCH_INVALID");
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
    !Number.isSafeInteger(value.credentialRequests) || value.credentialRequests < 0 ||
    !Number.isSafeInteger(value.credentialSettlements) || value.credentialSettlements < 0 ||
    !Number.isSafeInteger(value.certificateRequests) || value.certificateRequests < 0
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_BLOCKED_AUTH_ACTIVITY_INVALID");
  }
  return { ...value };
}

function sha256(value: string): string {
  return createHash("sha256").update(value, "utf8").digest("hex");
}

function normalizeAbsolutePath(value: string): string {
  return nodePath.resolve(value).replace(/[\\/]+$/u, "").toLowerCase();
}

function isAbsolutePath(value: string): boolean {
  return nodePath.isAbsolute(value) || nodePath.win32.isAbsolute(value) || nodePath.posix.isAbsolute(value);
}

function sameEndpoint(left: CanonicalEndpoint, right: CanonicalEndpoint): boolean {
  return left.scheme === right.scheme &&
    left.canonicalHost === right.canonicalHost &&
    left.effectivePort === right.effectivePort;
}

function requireExactKeys(value: Record<string, unknown>, keys: readonly string[]): void {
  if (Object.keys(value).sort().join(",") !== [...keys].sort().join(",")) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_BLOCKED_REQUEST_INVALID");
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export class InstalledSvnAnonymousRecoveryBlockedReportError extends Error {
  public readonly messageKey = "error.diagnostics.installedSvnAnonymousRecoveryBlockedReportInvalid";

  public constructor(public readonly code: string) {
    super(code);
    this.name = "InstalledSvnAnonymousRecoveryBlockedReportError";
  }
}

function reportError(code: string): InstalledSvnAnonymousRecoveryBlockedReportError {
  return new InstalledSvnAnonymousRecoveryBlockedReportError(code);
}
