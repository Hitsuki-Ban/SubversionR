import * as nodePath from "node:path";
import type { BackendConnection } from "../backend/backendProcess";
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
const REPORT_SCHEMA = "subversionr.release.m8-i6-installed-svn-anonymous-negative.v1";
const REPORT_KIND = "subversionr.installedSvnAnonymousNegativeReport";
const MAX_REDACTION_VALUE_BYTES = 32_768;

type InstalledSvnAnonymousNegativeScenario =
  | "maliciousRoot"
  | "saslOnly"
  | "greetingStall"
  | "connectedStall";
type InstalledSvnAnonymousNegativeConnection = Pick<
  BackendConnection,
  "initializeResult" | "isRemoteSubmissionEnabled" | "currentRemoteTrustEpoch" | "sendRequest"
>;

interface NegativeScenarioContract {
  originCode: string;
  originReason:
    | "crossAuthorityRejected"
    | "remoteCapabilityUnsupported"
    | "operationDeadlineExceeded";
  settlementCode: string;
  settlementCategory: "policy" | "capability" | "recovery";
  settlementReason:
    | "crossAuthorityRejected"
    | "remoteCapabilityUnsupported"
    | "remoteRecoveryBlocked";
}

const SCENARIO_CONTRACTS: Record<InstalledSvnAnonymousNegativeScenario, NegativeScenarioContract> = {
  maliciousRoot: {
    originCode: "SUBVERSIONR_REMOTE_ORIGIN_MISMATCH",
    originReason: "crossAuthorityRejected",
    settlementCode: "SUBVERSIONR_REMOTE_ORIGIN_MISMATCH",
    settlementCategory: "policy",
    settlementReason: "crossAuthorityRejected",
  },
  saslOnly: {
    originCode: "SUBVERSIONR_REMOTE_AUTH_UNSUPPORTED",
    originReason: "remoteCapabilityUnsupported",
    settlementCode: "SUBVERSIONR_REMOTE_AUTH_UNSUPPORTED",
    settlementCategory: "capability",
    settlementReason: "remoteCapabilityUnsupported",
  },
  greetingStall: {
    originCode: "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT",
    originReason: "operationDeadlineExceeded",
    settlementCode: "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED",
    settlementCategory: "recovery",
    settlementReason: "remoteRecoveryBlocked",
  },
  connectedStall: {
    originCode: "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT",
    originReason: "operationDeadlineExceeded",
    settlementCode: "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED",
    settlementCategory: "recovery",
    settlementReason: "remoteRecoveryBlocked",
  },
};

export interface InstalledSvnAnonymousNegativeReportOptions {
  expectedToken: string | undefined;
  request: unknown;
  initialize(): Promise<InstalledSvnAnonymousNegativeConnection>;
  authActivity(): InstalledSvnAnonymousAuthActivity;
}

interface InstalledSvnAnonymousNegativeRequest {
  token: string;
  scenario: InstalledSvnAnonymousNegativeScenario;
  repositoryUrl: string;
  checkoutPath: string;
  operationId: string;
  timeoutMs: number;
}

export async function collectInstalledSvnAnonymousNegativeReport(
  options: InstalledSvnAnonymousNegativeReportOptions,
): Promise<Record<string, unknown>> {
  const request = parseRequest(options.request, options.expectedToken);
  const endpoint = requireLoopbackSvnOrigin(request.repositoryUrl);
  const contract = SCENARIO_CONTRACTS[request.scenario];
  const authBefore = requireAuthActivity(options.authActivity());
  const connection = await options.initialize();
  const trustEpoch = requireCandidateCapabilities(connection);
  const envelopeFactory = new RemoteOperationEnvelopeFactory({
    remoteSvnAnonymous: connection.initializeResult.capabilities.remoteSvnAnonymous,
    isRemoteSubmissionEnabled: () => connection.isRemoteSubmissionEnabled(),
    currentRemoteTrustEpoch: () => connection.currentRemoteTrustEpoch(),
  });
  const remote = envelopeFactory.createAnonymousSvn({
    operationId: request.operationId,
    intent: "foreground",
    interaction: "forbidden",
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
    throw negativeReportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_NEGATIVE_ENVELOPE_INVALID");
  }

  let observedError: unknown;
  try {
    await new RepositoryCheckoutRpcClient(connection).checkout({
      url: request.repositoryUrl,
      targetPath: request.checkoutPath,
      revision: "head",
      depth: "infinity",
      ignoreExternals: true,
      remote,
    });
  } catch (error) {
    observedError = error;
  }
  if (observedError === undefined) {
    throw negativeReportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_NEGATIVE_UNEXPECTED_SUCCESS");
  }
  requireExpectedFailure(observedError, contract);
  requireRedacted(observedError, request);
  requireStableTrust(connection, trustEpoch);

  let diagnostics: unknown;
  try {
    diagnostics = await connection.sendRequest<unknown>("diagnostics/get", {});
  } catch {
    throw negativeReportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_NEGATIVE_DIAGNOSTICS_INVALID");
  }
  requireCurrentRedactedDiagnostics(diagnostics, request);
  requireStableTrust(connection, trustEpoch);

  const authActivity = subtractAuthActivity(requireAuthActivity(options.authActivity()), authBefore);
  if (
    authActivity.credentialRequests !== 0 ||
    authActivity.credentialSettlements !== 0 ||
    authActivity.certificateRequests !== 0
  ) {
    throw negativeReportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_NEGATIVE_AUTH_ACTIVITY_INVALID");
  }

  return {
    schema: REPORT_SCHEMA,
    schemaVersion: 1,
    kind: REPORT_KIND,
    scenario: request.scenario,
    originCode: contract.originCode,
    originReason: contract.originReason,
    settlementCode: contract.settlementCode,
    settlementReason: contract.settlementReason,
    protocol: { major: EXPECTED_PROTOCOL_MAJOR, minor: EXPECTED_PROTOCOL_MINOR },
    trust: { acknowledgedEpoch: trustEpoch, consistent: true },
    authActivity,
    diagnosticsRedacted: true,
    redaction: { rawUrls: false, rawPaths: false, rawContent: false },
  };
}

function parseRequest(
  value: unknown,
  expectedToken: string | undefined,
): InstalledSvnAnonymousNegativeRequest {
  if (typeof expectedToken !== "string" || expectedToken.length === 0 || !isRecord(value)) {
    throw negativeReportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_NEGATIVE_FORBIDDEN");
  }
  if (value.token !== expectedToken) {
    throw negativeReportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_NEGATIVE_FORBIDDEN");
  }
  requireExactKeys(value, [
    "token",
    "scenario",
    "repositoryUrl",
    "checkoutPath",
    "operationId",
    "timeoutMs",
  ]);
  if (
    (value.scenario !== "maliciousRoot" &&
      value.scenario !== "saslOnly" &&
      value.scenario !== "greetingStall" &&
      value.scenario !== "connectedStall") ||
    typeof value.repositoryUrl !== "string" ||
    value.repositoryUrl.length === 0 ||
    /[\0\r\n]/.test(value.repositoryUrl) ||
    typeof value.checkoutPath !== "string" ||
    value.checkoutPath.length === 0 ||
    !isAbsolutePath(value.checkoutPath) ||
    /[\0\r\n]/.test(value.checkoutPath) ||
    typeof value.operationId !== "string" ||
    !isCanonicalOperationId(value.operationId) ||
    typeof value.timeoutMs !== "number" ||
    !Number.isSafeInteger(value.timeoutMs) ||
    value.timeoutMs < 1 ||
    value.timeoutMs > 300_000
  ) {
    throw negativeReportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_NEGATIVE_REQUEST_INVALID");
  }
  return {
    token: value.token,
    scenario: value.scenario,
    repositoryUrl: value.repositoryUrl,
    checkoutPath: value.checkoutPath,
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
    throw negativeReportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_NEGATIVE_ORIGIN_INVALID");
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
    throw negativeReportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_NEGATIVE_ORIGIN_INVALID");
  }
  return endpoint;
}

function requireCandidateCapabilities(connection: InstalledSvnAnonymousNegativeConnection): number {
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
    throw negativeReportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_NEGATIVE_CAPABILITY_UNAVAILABLE");
  }
  const trustEpoch = initialize.acknowledgedTrustEpoch;
  if (
    !Number.isSafeInteger(trustEpoch) ||
    trustEpoch < 1 ||
    connection.currentRemoteTrustEpoch() !== trustEpoch
  ) {
    throw negativeReportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_NEGATIVE_TRUST_EPOCH_INVALID");
  }
  return trustEpoch;
}

function requireExpectedFailure(error: unknown, contract: NegativeScenarioContract): void {
  if (!(error instanceof JsonRpcStreamError) || error.code !== contract.settlementCode) {
    throw negativeReportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_NEGATIVE_SETTLEMENT_INVALID");
  }
  const remoteFailure = error.safeArgs.remoteFailure;
  if (
    !isRecord(remoteFailure) ||
    Object.keys(remoteFailure).sort().join(",") !== "category,cleanupAppropriate,reason" ||
    remoteFailure.category !== contract.settlementCategory ||
    remoteFailure.reason !== contract.settlementReason ||
    remoteFailure.cleanupAppropriate !== false
  ) {
    throw negativeReportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_NEGATIVE_SETTLEMENT_INVALID");
  }
  if (
    contract.settlementCode !== contract.originCode &&
    error.safeArgs.originFailureCode !== contract.originCode
  ) {
    throw negativeReportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_NEGATIVE_SETTLEMENT_INVALID");
  }
}

function requireCurrentRedactedDiagnostics(
  value: unknown,
  request: InstalledSvnAnonymousNegativeRequest,
): void {
  if (!isRecord(value) || value.source !== "subversionr-daemon" || !isRecord(value.protocol)) {
    throw negativeReportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_NEGATIVE_DIAGNOSTICS_INVALID");
  }
  if (
    value.protocol.major !== EXPECTED_PROTOCOL_MAJOR ||
    value.protocol.minor !== EXPECTED_PROTOCOL_MINOR ||
    !isRecord(value.capabilities) ||
    value.capabilities.remoteSvnAnonymous !== true
  ) {
    throw negativeReportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_NEGATIVE_DIAGNOSTICS_INVALID");
  }
  requireRedacted(value, request);
}

function requireRedacted(value: unknown, request: InstalledSvnAnonymousNegativeRequest): void {
  let serialized: string;
  try {
    const candidate = JSON.stringify(value);
    if (typeof candidate !== "string") {
      throw new Error("invalid serialization");
    }
    serialized = candidate;
  } catch {
    throw negativeReportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_NEGATIVE_DIAGNOSTICS_INVALID");
  }
  if (Buffer.byteLength(serialized, "utf8") > MAX_REDACTION_VALUE_BYTES) {
    throw negativeReportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_NEGATIVE_DIAGNOSTICS_INVALID");
  }
  const sensitive = [
    request.token,
    request.repositoryUrl,
    request.checkoutPath,
    request.checkoutPath.replaceAll("\\", "/"),
    request.operationId,
  ].map((entry) => entry.toLowerCase());
  const normalized = serialized.toLowerCase();
  if (sensitive.some((entry) => entry.length > 0 && normalized.includes(entry))) {
    throw negativeReportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_NEGATIVE_DIAGNOSTICS_LEAK");
  }
}

function requireStableTrust(connection: InstalledSvnAnonymousNegativeConnection, trustEpoch: number): void {
  if (!connection.isRemoteSubmissionEnabled() || connection.currentRemoteTrustEpoch() !== trustEpoch) {
    throw negativeReportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_NEGATIVE_TRUST_EPOCH_INVALID");
  }
}

function anonymousLoopbackProfile(endpoint: CanonicalEndpoint): RemoteAccessProfileSnapshot {
  return {
    schema: "subversionr.remote-profile.v1",
    profileId: "installed-i6-svn-anonymous-negative",
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
    throw negativeReportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_NEGATIVE_AUTH_ACTIVITY_INVALID");
  }
  return { ...value };
}

function isAbsolutePath(value: string): boolean {
  return nodePath.isAbsolute(value) || nodePath.win32.isAbsolute(value) || nodePath.posix.isAbsolute(value);
}

function isCanonicalOperationId(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value) &&
    value !== "00000000-0000-0000-0000-000000000000";
}

function requireExactKeys(value: Record<string, unknown>, keys: readonly string[]): void {
  if (Object.keys(value).sort().join(",") !== [...keys].sort().join(",")) {
    throw negativeReportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_NEGATIVE_REQUEST_INVALID");
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

export class InstalledSvnAnonymousNegativeReportError extends Error {
  public readonly messageKey = "error.diagnostics.installedSvnAnonymousNegativeReportInvalid";

  public constructor(public readonly code: string) {
    super(code);
    this.name = "InstalledSvnAnonymousNegativeReportError";
  }
}

function negativeReportError(code: string): InstalledSvnAnonymousNegativeReportError {
  return new InstalledSvnAnonymousNegativeReportError(code);
}
