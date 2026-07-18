import { createHash } from "node:crypto";
import * as nodePath from "node:path";
import type { BackendConnection } from "../backend/backendProcess";
import { RepositoryCheckoutRpcClient } from "../repository/repositoryCheckoutRpcClient";
import {
  RemoteOperationEnvelopeFactory,
  canonicalEndpointFromRepositoryUrl,
  type CanonicalEndpoint,
  type RemoteAccessProfileSnapshot,
} from "../security/remoteAccessProfile";
import type { InstalledSvnAnonymousAuthActivity } from "./installedSvnAnonymousReport";

const EXPECTED_PROTOCOL_MAJOR = 1;
const EXPECTED_PROTOCOL_MINOR = 35;
const MAX_SVN_REVNUM = 2_147_483_647;
const CHECKOUT_TIMEOUT_MS = 300_000;
const REPORT_SCHEMA = "subversionr.release.m8-i6-installed-svn-anonymous-stress-checkout.v1";
const REPORT_KIND = "subversionr.installedSvnAnonymousStressCheckout";

type InstalledSvnAnonymousStressConnection = Pick<
  BackendConnection,
  "initializeResult" | "isRemoteSubmissionEnabled" | "currentRemoteTrustEpoch" | "sendRequest"
>;

export interface InstalledSvnAnonymousStressCheckoutOptions {
  expectedToken: string | undefined;
  request: unknown;
  extensionHostSessionSha256: string;
  initialize(): Promise<InstalledSvnAnonymousStressConnection>;
  authActivity(): InstalledSvnAnonymousAuthActivity;
}

interface InstalledSvnAnonymousStressCheckoutRequest {
  token: string;
  repositoryUrl: string;
  checkoutPath: string;
  checkoutRevision: number;
  operationId: string;
}

export async function collectInstalledSvnAnonymousStressCheckout(
  options: InstalledSvnAnonymousStressCheckoutOptions,
): Promise<Record<string, unknown>> {
  const request = parseRequest(options.request, options.expectedToken);
  const extensionHostSessionSha256 = requireSha256(options.extensionHostSessionSha256);
  const endpoint = requireLoopbackSvnOrigin(request.repositoryUrl);
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
    timeoutMs: CHECKOUT_TIMEOUT_MS,
    profile: anonymousLoopbackProfile(endpoint),
    expectedOrigin: endpoint,
  });
  if (
    remote.operationId !== request.operationId ||
    remote.trustEpoch !== trustEpoch ||
    !sameEndpoint(remote.expectedOrigin, endpoint)
  ) {
    throw stressError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_STRESS_ENVELOPE_INVALID");
  }

  const checkout = await new RepositoryCheckoutRpcClient(connection).checkout({
    url: request.repositoryUrl,
    targetPath: request.checkoutPath,
    revision: request.checkoutRevision,
    depth: "infinity",
    ignoreExternals: true,
    remote,
  });
  if (
    normalizeAbsolutePath(checkout.workingCopyPath) !== normalizeAbsolutePath(request.checkoutPath) ||
    checkout.revision !== request.checkoutRevision
  ) {
    throw stressError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_STRESS_CHECKOUT_INVALID");
  }
  if (
    !connection.isRemoteSubmissionEnabled() ||
    connection.currentRemoteTrustEpoch() !== trustEpoch
  ) {
    throw stressError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_STRESS_TRUST_EPOCH_INVALID");
  }

  const authActivity = subtractAuthActivity(requireAuthActivity(options.authActivity()), authBefore);
  if (
    authActivity.credentialRequests !== 0 ||
    authActivity.credentialSettlements !== 0 ||
    authActivity.certificateRequests !== 0
  ) {
    throw stressError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_STRESS_AUTH_ACTIVITY_INVALID");
  }

  return {
    schema: REPORT_SCHEMA,
    schemaVersion: 1,
    kind: REPORT_KIND,
    operationId: request.operationId,
    extensionHostSessionSha256,
    revision: checkout.revision,
    protocol: { major: EXPECTED_PROTOCOL_MAJOR, minor: EXPECTED_PROTOCOL_MINOR },
    trust: { acknowledgedEpoch: trustEpoch, consistent: true },
    authActivity,
    redaction: { rawUrls: false, rawPaths: false, rawContent: false },
  };
}

export function createInstalledSvnAnonymousStressSessionSha256(token: string): string {
  if (token.length === 0) {
    throw stressError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_STRESS_SESSION_INVALID");
  }
  return createHash("sha256").update(`${token}:${process.pid}`, "utf8").digest("hex");
}

function parseRequest(
  value: unknown,
  expectedToken: string | undefined,
): InstalledSvnAnonymousStressCheckoutRequest {
  if (typeof expectedToken !== "string" || expectedToken.length === 0 || !isRecord(value)) {
    throw stressError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_STRESS_FORBIDDEN");
  }
  if (value.token !== expectedToken) {
    throw stressError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_STRESS_FORBIDDEN");
  }
  requireExactKeys(value, ["token", "repositoryUrl", "checkoutPath", "checkoutRevision", "operationId"]);
  if (
    typeof value.repositoryUrl !== "string" ||
    value.repositoryUrl.length === 0 ||
    /[\0\r\n]/.test(value.repositoryUrl) ||
    typeof value.checkoutPath !== "string" ||
    value.checkoutPath.length === 0 ||
    !isAbsolutePath(value.checkoutPath) ||
    /[\0\r\n]/.test(value.checkoutPath) ||
    typeof value.checkoutRevision !== "number" ||
    !Number.isSafeInteger(value.checkoutRevision) ||
    value.checkoutRevision < 0 ||
    value.checkoutRevision > MAX_SVN_REVNUM ||
    typeof value.operationId !== "string" ||
    !isCanonicalOperationId(value.operationId)
  ) {
    throw stressError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_STRESS_REQUEST_INVALID");
  }
  return {
    token: value.token,
    repositoryUrl: value.repositoryUrl,
    checkoutPath: value.checkoutPath,
    checkoutRevision: value.checkoutRevision,
    operationId: value.operationId,
  };
}

function requireLoopbackSvnOrigin(repositoryUrl: string): CanonicalEndpoint {
  let parsed: URL;
  let endpoint: CanonicalEndpoint;
  try {
    parsed = new URL(repositoryUrl);
    endpoint = canonicalEndpointFromRepositoryUrl(repositoryUrl);
  } catch {
    throw stressError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_STRESS_ORIGIN_INVALID");
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
    throw stressError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_STRESS_ORIGIN_INVALID");
  }
  return endpoint;
}

function requireCandidateCapabilities(connection: InstalledSvnAnonymousStressConnection): number {
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
    throw stressError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_STRESS_CAPABILITY_UNAVAILABLE");
  }
  const trustEpoch = initialize.acknowledgedTrustEpoch;
  if (
    !Number.isSafeInteger(trustEpoch) ||
    trustEpoch < 1 ||
    connection.currentRemoteTrustEpoch() !== trustEpoch
  ) {
    throw stressError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_STRESS_TRUST_EPOCH_INVALID");
  }
  return trustEpoch;
}

function anonymousLoopbackProfile(endpoint: CanonicalEndpoint): RemoteAccessProfileSnapshot {
  return {
    schema: "subversionr.remote-profile.v1",
    profileId: "installed-i6-svn-anonymous-stress",
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
    throw stressError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_STRESS_AUTH_ACTIVITY_INVALID");
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

function requireSha256(value: string): string {
  if (!/^[0-9a-f]{64}$/.test(value)) {
    throw stressError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_STRESS_SESSION_INVALID");
  }
  return value;
}

function requireExactKeys(value: Record<string, unknown>, keys: readonly string[]): void {
  if (Object.keys(value).sort().join(",") !== [...keys].sort().join(",")) {
    throw stressError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_STRESS_REQUEST_INVALID");
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

export class InstalledSvnAnonymousStressCheckoutError extends Error {
  public readonly messageKey = "error.diagnostics.installedSvnAnonymousStressCheckoutInvalid";

  public constructor(public readonly code: string) {
    super(code);
    this.name = "InstalledSvnAnonymousStressCheckoutError";
  }
}

function stressError(code: string): InstalledSvnAnonymousStressCheckoutError {
  return new InstalledSvnAnonymousStressCheckoutError(code);
}
