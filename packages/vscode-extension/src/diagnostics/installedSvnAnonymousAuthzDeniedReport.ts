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
import { JsonRpcStreamError } from "../transport/jsonRpcStreamClient";
import type { InstalledSvnAnonymousAuthActivity } from "./installedSvnAnonymousReport";

const EXPECTED_PROTOCOL_MAJOR = 1;
const EXPECTED_PROTOCOL_MINOR = 35;
const REPORT_SCHEMA = "subversionr.release.m8-i6-installed-svn-anonymous-authz-denied.v1";
const REPORT_KIND = "subversionr.installedSvnAnonymousAuthzDeniedReport";
const MAX_REDACTION_VALUE_BYTES = 32_768;

type AuthzDeniedConnection = Pick<
  BackendConnection,
  "initializeResult" | "isRemoteSubmissionEnabled" | "currentRemoteTrustEpoch" | "sendRequest"
>;

export interface InstalledSvnAnonymousAuthzDeniedReportOptions {
  expectedToken: string | undefined;
  request: unknown;
  initialize(): Promise<AuthzDeniedConnection>;
  openWorkingCopy(path: string): Promise<RepositorySession>;
  closeRepository(repositoryId: string): Promise<void>;
  authActivity(): InstalledSvnAnonymousAuthActivity;
}

interface InstalledSvnAnonymousAuthzDeniedRequest {
  token: string;
  repositoryUrl: string;
  workingCopyPath: string;
  operationId: string;
  timeoutMs: number;
}

interface AuthzDeniedDiagnostics {
  cause: "authorizationDenied";
  svnErrorNames: string[];
  truncated: boolean;
}

export async function collectInstalledSvnAnonymousAuthzDeniedReport(
  options: InstalledSvnAnonymousAuthzDeniedReportOptions,
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
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_AUTHZ_DENIED_ENVELOPE_INVALID");
  }

  let session: RepositorySession | undefined;
  let failureDiagnostics: AuthzDeniedDiagnostics | undefined;
  try {
    session = await options.openWorkingCopy(request.workingCopyPath);
    requireOpenedSession(session, request.workingCopyPath, endpoint);

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
    if (observedError === undefined) {
      throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_AUTHZ_DENIED_UNEXPECTED_SUCCESS");
    }
    failureDiagnostics = requireExpectedFailure(observedError, request.workingCopyPath);
    requireStableTrust(connection, trustEpoch);

    let diagnostics: unknown;
    try {
      diagnostics = await connection.sendRequest<unknown>("diagnostics/get", {});
    } catch {
      throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_AUTHZ_DENIED_DIAGNOSTICS_INVALID");
    }
    requireCurrentRedactedDiagnostics(diagnostics, request);
    requireStableTrust(connection, trustEpoch);
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
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_AUTHZ_DENIED_AUTH_ACTIVITY_INVALID");
  }
  if (failureDiagnostics === undefined) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_AUTHZ_DENIED_SETTLEMENT_INVALID");
  }

  return {
    schema: REPORT_SCHEMA,
    schemaVersion: 1,
    kind: REPORT_KIND,
    settlement: {
      code: "SVN_REMOTE_STATUS_AUTH_FAILED",
      category: "auth",
      messageKey: "error.native.remoteStatusAuthFailed",
      retryable: false,
      remoteFailure: {
        category: "authorization",
        reason: "authorizationDenied",
        cleanupAppropriate: false,
      },
    },
    diagnostics: failureDiagnostics,
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
): InstalledSvnAnonymousAuthzDeniedRequest {
  if (typeof expectedToken !== "string" || expectedToken.length === 0 || !isRecord(value)) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_AUTHZ_DENIED_FORBIDDEN");
  }
  if (value.token !== expectedToken) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_AUTHZ_DENIED_FORBIDDEN");
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
    !Number.isSafeInteger(value.timeoutMs) ||
    value.timeoutMs < 1 ||
    value.timeoutMs > 300_000
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_AUTHZ_DENIED_REQUEST_INVALID");
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
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_AUTHZ_DENIED_ORIGIN_INVALID");
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
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_AUTHZ_DENIED_ORIGIN_INVALID");
  }
  return endpoint;
}

function requireCandidateCapabilities(connection: AuthzDeniedConnection): number {
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
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_AUTHZ_DENIED_CAPABILITY_UNAVAILABLE");
  }
  const trustEpoch = initialize.acknowledgedTrustEpoch;
  if (
    !Number.isSafeInteger(trustEpoch) ||
    trustEpoch < 1 ||
    connection.currentRemoteTrustEpoch() !== trustEpoch
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_AUTHZ_DENIED_TRUST_EPOCH_INVALID");
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
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_AUTHZ_DENIED_OPEN_INVALID");
  }
  let actualEndpoint: CanonicalEndpoint;
  try {
    actualEndpoint = canonicalEndpointFromRepositoryUrl(session.identity.repositoryRootUrl);
  } catch {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_AUTHZ_DENIED_OPEN_INVALID");
  }
  if (!sameEndpoint(actualEndpoint, endpoint)) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_AUTHZ_DENIED_OPEN_INVALID");
  }
}

function requireExpectedFailure(error: unknown, workingCopyPath: string): AuthzDeniedDiagnostics {
  if (
    !(error instanceof JsonRpcStreamError) ||
    error.code !== "SVN_REMOTE_STATUS_AUTH_FAILED" ||
    error.category !== "auth" ||
    error.messageKey !== "error.native.remoteStatusAuthFailed" ||
    error.retryable !== false ||
    Object.keys(error.safeArgs).sort().join(",") !== "path,remoteFailure,status" ||
    typeof error.safeArgs.path !== "string" ||
    normalizeAbsolutePath(error.safeArgs.path) !== normalizeAbsolutePath(workingCopyPath) ||
    error.safeArgs.status !== 12
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_AUTHZ_DENIED_SETTLEMENT_INVALID");
  }
  const remoteFailure = error.safeArgs.remoteFailure;
  if (
    !isRecord(remoteFailure) ||
    Object.keys(remoteFailure).sort().join(",") !== "category,cleanupAppropriate,reason" ||
    remoteFailure.category !== "authorization" ||
    remoteFailure.reason !== "authorizationDenied" ||
    remoteFailure.cleanupAppropriate !== false
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_AUTHZ_DENIED_SETTLEMENT_INVALID");
  }
  if (error.diagnostics === null || error.diagnostics.cause !== "authorizationDenied") {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_AUTHZ_DENIED_SETTLEMENT_INVALID");
  }
  const names = error.diagnostics.svn.entries.map((entry) => entry.name);
  if (names.length === 0 || names.length > 8 || names.some((name) => !/^SVN_ERR_[A-Z0-9_]+$/u.test(name))) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_AUTHZ_DENIED_SETTLEMENT_INVALID");
  }
  return {
    cause: "authorizationDenied",
    svnErrorNames: names,
    truncated: error.diagnostics.svn.truncated,
  };
}

function requireCurrentRedactedDiagnostics(
  value: unknown,
  request: InstalledSvnAnonymousAuthzDeniedRequest,
): void {
  if (!isRecord(value) || value.source !== "subversionr-daemon" || !isRecord(value.protocol)) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_AUTHZ_DENIED_DIAGNOSTICS_INVALID");
  }
  if (
    value.protocol.major !== EXPECTED_PROTOCOL_MAJOR ||
    value.protocol.minor !== EXPECTED_PROTOCOL_MINOR ||
    !isRecord(value.capabilities) ||
    value.capabilities.remoteSvnAnonymous !== true ||
    value.capabilities.statusRemoteCheck !== true
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_AUTHZ_DENIED_DIAGNOSTICS_INVALID");
  }
  requireRedacted(value, request);
}

function requireRedacted(value: unknown, request: InstalledSvnAnonymousAuthzDeniedRequest): void {
  let serialized: string;
  try {
    const candidate = JSON.stringify(value);
    if (typeof candidate !== "string") {
      throw new Error("invalid serialization");
    }
    serialized = candidate;
  } catch {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_AUTHZ_DENIED_DIAGNOSTICS_INVALID");
  }
  if (Buffer.byteLength(serialized, "utf8") > MAX_REDACTION_VALUE_BYTES) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_AUTHZ_DENIED_DIAGNOSTICS_INVALID");
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
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_AUTHZ_DENIED_DIAGNOSTICS_LEAK");
  }
}

function anonymousLoopbackProfile(endpoint: CanonicalEndpoint): RemoteAccessProfileSnapshot {
  return {
    schema: "subversionr.remote-profile.v1",
    profileId: "installed-i6-svn-anonymous-authz-denied",
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
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_AUTHZ_DENIED_AUTH_ACTIVITY_INVALID");
  }
  return { ...value };
}

function requireStableTrust(connection: AuthzDeniedConnection, trustEpoch: number): void {
  if (!connection.isRemoteSubmissionEnabled() || connection.currentRemoteTrustEpoch() !== trustEpoch) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_AUTHZ_DENIED_TRUST_EPOCH_INVALID");
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
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_AUTHZ_DENIED_REQUEST_INVALID");
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

export class InstalledSvnAnonymousAuthzDeniedReportError extends Error {
  public readonly messageKey = "error.diagnostics.installedSvnAnonymousAuthzDeniedReportInvalid";

  public constructor(public readonly code: string) {
    super(code);
    this.name = "InstalledSvnAnonymousAuthzDeniedReportError";
  }
}

function reportError(code: string): InstalledSvnAnonymousAuthzDeniedReportError {
  return new InstalledSvnAnonymousAuthzDeniedReportError(code);
}
