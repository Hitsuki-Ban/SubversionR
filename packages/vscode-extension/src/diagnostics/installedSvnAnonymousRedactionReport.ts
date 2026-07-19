import { Buffer } from "node:buffer";
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
import type { OperationDiagnostics } from "./operationDiagnostics";

const EXPECTED_PROTOCOL_MAJOR = 1;
const EXPECTED_PROTOCOL_MINOR = 35;
const CHECKOUT_TIMEOUT_MS = 300_000;
const MAX_SVN_REVNUM = 2_147_483_647;
const MAX_DIAGNOSTIC_VALUE_BYTES = 32_768;
const REPORT_SCHEMA = "subversionr.release.m8-i6-installed-vsix-redaction.v1";
const REPORT_KIND = "subversionr.installedSvnAnonymousRedactionReport";
const DIRECT_REPOSITORY_URL_PATTERN = /^svn:\/\/127\.0\.0\.1:([1-9][0-9]{0,4})\/repo\/trunk$/u;
const URL_MARKER_PATTERN = /\[REDACTED:url:[0-9a-f]{8}\]/gu;
const PATH_MARKER_PATTERN = /\[REDACTED:path:[0-9a-f]{8}\]/gu;
const SECRET_MARKER_PATTERN = /\[REDACTED:secret\]/gu;

type InstalledSvnAnonymousRedactionConnection = Pick<
  BackendConnection,
  "initializeResult" | "isRemoteSubmissionEnabled" | "currentRemoteTrustEpoch" | "sendRequest"
>;

interface InstalledSvnAnonymousRedactionDiagnosticInput {
  repositoryUrl: string;
  targetPath: string;
  secretToken: string;
}

export interface InstalledSvnAnonymousRedactionReportOptions {
  expectedToken: string | undefined;
  request: unknown;
  initialize(): Promise<InstalledSvnAnonymousRedactionConnection>;
  authActivity(): InstalledSvnAnonymousAuthActivity;
  operationDiagnostics: Pick<OperationDiagnostics, "recordRpcFailure" | "snapshot">;
  collectDiagnosticsComposite(
    diagnosticInput: Readonly<InstalledSvnAnonymousRedactionDiagnosticInput>,
  ): Promise<unknown>;
}

interface InstalledSvnAnonymousRedactionRequest {
  token: string;
  repositoryUrl: string;
  targetPath: string;
  operationId: string;
  timeoutMs: number;
  secretToken: string;
  expectedRevision: number;
}

interface InstalledSvnAnonymousRedactionDiagnosticsComposite {
  diagnosticsBundle: Record<string, unknown>;
  redactedCanary: unknown;
}

interface SerializedDiagnosticValue {
  text: string;
  bytes: number;
}

export async function collectInstalledSvnAnonymousRedactionReport(
  options: InstalledSvnAnonymousRedactionReportOptions,
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
    interaction: "forbidden",
    timeoutMs: request.timeoutMs,
    profile: anonymousLoopbackProfile(endpoint),
    expectedOrigin: endpoint,
  });
  if (
    remote.operationId !== request.operationId ||
    remote.timeoutMs !== CHECKOUT_TIMEOUT_MS ||
    remote.trustEpoch !== trustEpoch ||
    !sameEndpoint(remote.expectedOrigin, endpoint)
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_ENVELOPE_INVALID");
  }

  let checkout;
  try {
    checkout = await new RepositoryCheckoutRpcClient(connection).checkout({
      url: request.repositoryUrl,
      targetPath: request.targetPath,
      revision: "head",
      depth: "infinity",
      ignoreExternals: true,
      remote,
    });
  } catch {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_CHECKOUT_INVALID");
  }
  if (
    normalizeAbsolutePath(checkout.workingCopyPath) !== normalizeAbsolutePath(request.targetPath) ||
    checkout.revision !== request.expectedRevision
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_CHECKOUT_INVALID");
  }
  requireStableTrust(connection, trustEpoch);

  const diagnosticInput: InstalledSvnAnonymousRedactionDiagnosticInput = {
    repositoryUrl: request.repositoryUrl,
    targetPath: request.targetPath,
    secretToken: request.secretToken,
  };
  let operationSnapshot: readonly string[];
  try {
    options.operationDiagnostics.recordRpcFailure("repository/checkout", {
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_PROBE",
      category: "diagnostic",
      messageKey: "error.diagnostics.installedSvnAnonymousRedactionProbe",
      safeArgs: diagnosticInput,
      retryable: false,
      diagnostics: diagnosticInput,
    });
    operationSnapshot = options.operationDiagnostics.snapshot();
  } catch {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_DIAGNOSTICS_INVALID");
  }
  if (!Array.isArray(operationSnapshot) || operationSnapshot.length === 0) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_DIAGNOSTICS_INVALID");
  }
  let diagnosticsComposite: InstalledSvnAnonymousRedactionDiagnosticsComposite;
  try {
    diagnosticsComposite = requireDiagnosticsComposite(
      await options.collectDiagnosticsComposite(diagnosticInput),
    );
  } catch {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_DIAGNOSTICS_INVALID");
  }
  requireStableTrust(connection, trustEpoch);

  const inputContainedRawUrl = inputContainsRawValue(diagnosticInput, request.repositoryUrl);
  const inputContainedRawPath = inputContainsRawValue(diagnosticInput, request.targetPath);
  const inputContainedRawToken = inputContainsRawValue(diagnosticInput, request.secretToken);
  if (!inputContainedRawUrl || !inputContainedRawPath || !inputContainedRawToken) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_INPUT_INVALID");
  }

  const canarySerialized = serializeDiagnosticValue(diagnosticsComposite.redactedCanary);
  const operationSerialized = operationSnapshot.map((line) => requireSerializedDiagnosticLine(line));
  const bundleSerialized = serializeDiagnosticValue(diagnosticsComposite.diagnosticsBundle);
  requireRedactedCanary(canarySerialized, request);
  requireAllMarkers(operationSerialized[operationSerialized.length - 1]!.text, request);
  const serializedValues = [bundleSerialized, canarySerialized, ...operationSerialized];
  const rawUrlCount = countRawOccurrences(serializedValues, [request.repositoryUrl]);
  const rawPathCount = countRawOccurrences(serializedValues, pathVariants(request.targetPath));
  const secretTokenCount = countRawOccurrences(serializedValues, [request.secretToken]);
  if (rawUrlCount !== 0 || rawPathCount !== 0 || secretTokenCount !== 0) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_DIAGNOSTICS_LEAK");
  }
  const urlMarkerCount = countPatternOccurrences(serializedValues, URL_MARKER_PATTERN);
  const pathMarkerCount = countPatternOccurrences(serializedValues, PATH_MARKER_PATTERN);
  const secretMarkerCount = countPatternOccurrences(serializedValues, SECRET_MARKER_PATTERN);
  if (urlMarkerCount < 1 || pathMarkerCount < 1 || secretMarkerCount < 1) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_MARKERS_INVALID");
  }
  const maxDiagnosticBytes = Math.max(...serializedValues.map((value) => value.bytes));
  if (maxDiagnosticBytes > MAX_DIAGNOSTIC_VALUE_BYTES) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_BOUNDS_INVALID");
  }

  const authActivity = subtractAuthActivity(requireAuthActivity(options.authActivity()), authBefore);
  if (
    authActivity.credentialRequests !== 0 ||
    authActivity.credentialSettlements !== 0 ||
    authActivity.certificateRequests !== 0
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_AUTH_ACTIVITY_INVALID");
  }

  return {
    schema: REPORT_SCHEMA,
    schemaVersion: 1,
    kind: REPORT_KIND,
    status: "passed",
    cell: "redaction",
    surface: "installed-vsix-extension-host",
    checkoutRevision: checkout.revision,
    targetPathSha256: createHash("sha256").update(request.targetPath, "utf8").digest("hex"),
    inputContainedRawUrl,
    inputContainedRawPath,
    inputContainedRawToken,
    rawUrlCount,
    rawPathCount,
    secretTokenCount,
    urlMarkerCount,
    pathMarkerCount,
    secretMarkerCount,
    diagnosticValueCount: serializedValues.length,
    maxDiagnosticBytes,
    boundedDiagnostics: true,
    protocol: { major: EXPECTED_PROTOCOL_MAJOR, minor: EXPECTED_PROTOCOL_MINOR },
    trust: { remoteSubmissionEnabled: true, epoch: trustEpoch },
    authActivity,
    redaction: { paths: "redacted", urls: "redacted", secrets: "redacted" },
    diagnosticsRedacted: true,
  };
}

function parseRequest(
  value: unknown,
  expectedToken: string | undefined,
): InstalledSvnAnonymousRedactionRequest {
  if (typeof expectedToken !== "string" || expectedToken.length === 0 || !isRecord(value)) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_FORBIDDEN");
  }
  if (value.token !== expectedToken) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_FORBIDDEN");
  }
  requireExactKeys(value, [
    "token", "repositoryUrl", "targetPath", "operationId", "timeoutMs", "secretToken", "expectedRevision",
  ]);
  if (
    typeof value.repositoryUrl !== "string" ||
    typeof value.targetPath !== "string" ||
    value.targetPath.length === 0 ||
    !isAbsolutePath(value.targetPath) ||
    /[\0\r\n]/u.test(value.targetPath) ||
    typeof value.operationId !== "string" ||
    !isCanonicalOperationId(value.operationId) ||
    value.timeoutMs !== CHECKOUT_TIMEOUT_MS ||
    typeof value.secretToken !== "string" ||
    !/^[0-9a-f]{64}$/u.test(value.secretToken) ||
    value.secretToken === value.token ||
    value.secretToken === value.operationId ||
    typeof value.expectedRevision !== "number" ||
    !Number.isSafeInteger(value.expectedRevision) ||
    value.expectedRevision < 1 ||
    value.expectedRevision > MAX_SVN_REVNUM
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_REQUEST_INVALID");
  }
  return {
    token: value.token,
    repositoryUrl: value.repositoryUrl,
    targetPath: value.targetPath,
    operationId: value.operationId,
    timeoutMs: value.timeoutMs,
    secretToken: value.secretToken,
    expectedRevision: value.expectedRevision,
  };
}

function requireLoopbackSvnOrigin(repositoryUrl: string): CanonicalEndpoint {
  const match = DIRECT_REPOSITORY_URL_PATTERN.exec(repositoryUrl);
  if (match === null || Number(match[1]) > 65_535) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_ORIGIN_INVALID");
  }
  try {
    return canonicalEndpointFromRepositoryUrl(repositoryUrl);
  } catch {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_ORIGIN_INVALID");
  }
}

function requireCandidateCapabilities(connection: InstalledSvnAnonymousRedactionConnection): number {
  const initialize = connection.initializeResult;
  if (
    initialize.protocol.major !== EXPECTED_PROTOCOL_MAJOR ||
    initialize.protocol.minor !== EXPECTED_PROTOCOL_MINOR ||
    !initialize.capabilities.realLibsvnBridge ||
    !initialize.capabilities.repositoryCheckout ||
    !initialize.capabilities.diagnosticsGet ||
    !initialize.capabilities.remoteOperationEnvelope ||
    !initialize.capabilities.remoteWorkerIsolation ||
    !initialize.capabilities.remoteSvnAnonymous ||
    !connection.isRemoteSubmissionEnabled()
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_CAPABILITY_UNAVAILABLE");
  }
  const trustEpoch = initialize.acknowledgedTrustEpoch;
  if (
    !Number.isSafeInteger(trustEpoch) ||
    trustEpoch < 1 ||
    connection.currentRemoteTrustEpoch() !== trustEpoch
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_TRUST_EPOCH_INVALID");
  }
  return trustEpoch;
}

function requireStableTrust(connection: InstalledSvnAnonymousRedactionConnection, trustEpoch: number): void {
  if (!connection.isRemoteSubmissionEnabled() || connection.currentRemoteTrustEpoch() !== trustEpoch) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_TRUST_EPOCH_INVALID");
  }
}

function anonymousLoopbackProfile(endpoint: CanonicalEndpoint): RemoteAccessProfileSnapshot {
  return {
    schema: "subversionr.remote-profile.v1",
    profileId: "installed-i6-svn-anonymous-redaction",
    authority: endpoint,
    serverAuth: "anonymous",
    serverAccount: "none",
    serverCredentialPersistence: "secretStorage",
    proxy: "none",
    ssh: "none",
    redirectPolicy: "rejectAll",
  };
}

function requireDiagnosticsComposite(value: unknown): InstalledSvnAnonymousRedactionDiagnosticsComposite {
  if (
    !isRecord(value) ||
    Object.keys(value).sort().join(",") !== "diagnosticsBundle,redactedCanary"
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_DIAGNOSTICS_INVALID");
  }
  requireDiagnosticsBundle(value.diagnosticsBundle);
  return {
    diagnosticsBundle: value.diagnosticsBundle,
    redactedCanary: value.redactedCanary,
  };
}

function requireDiagnosticsBundle(value: unknown): asserts value is Record<string, unknown> {
  if (
    !isRecord(value) ||
    value.kind !== "subversionr.diagnosticsBundle" ||
    !isRecord(value.redaction) ||
    Object.keys(value.redaction).sort().join(",") !== "mode,paths,repositoryLogs,secrets,sourceContent,urls" ||
    value.redaction.mode !== "default" ||
    value.redaction.paths !== "redacted" ||
    value.redaction.urls !== "redacted" ||
    value.redaction.secrets !== "redacted" ||
    value.redaction.repositoryLogs !== "omitted" ||
    value.redaction.sourceContent !== "omitted"
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_DIAGNOSTICS_INVALID");
  }
}

function requireRedactedCanary(
  value: SerializedDiagnosticValue,
  request: InstalledSvnAnonymousRedactionRequest,
): void {
  requireAllMarkers(value.text, request);
  if (
    countRawOccurrences([value], [request.repositoryUrl]) !== 0 ||
    countRawOccurrences([value], pathVariants(request.targetPath)) !== 0 ||
    countRawOccurrences([value], [request.secretToken]) !== 0
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_DIAGNOSTICS_LEAK");
  }
  if (value.bytes > MAX_DIAGNOSTIC_VALUE_BYTES) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_BOUNDS_INVALID");
  }
}

function inputContainsRawValue(input: InstalledSvnAnonymousRedactionDiagnosticInput, rawValue: string): boolean {
  return Object.values(input).some((value) => value === rawValue);
}

function serializeDiagnosticValue(value: unknown): SerializedDiagnosticValue {
  let text: string;
  try {
    const candidate = JSON.stringify(value);
    if (typeof candidate !== "string") {
      throw new Error("diagnostic value is not serializable");
    }
    text = candidate;
  } catch {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_DIAGNOSTICS_INVALID");
  }
  return { text, bytes: Buffer.byteLength(text, "utf8") };
}

function requireSerializedDiagnosticLine(value: unknown): SerializedDiagnosticValue {
  if (typeof value !== "string" || value.length === 0) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_DIAGNOSTICS_INVALID");
  }
  try {
    JSON.parse(value);
  } catch {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_DIAGNOSTICS_INVALID");
  }
  return { text: value, bytes: Buffer.byteLength(value, "utf8") };
}

function requireAllMarkers(serialized: string, request: InstalledSvnAnonymousRedactionRequest): void {
  if (
    !serialized.includes(`[REDACTED:url:${fnv1a(request.repositoryUrl)}]`) ||
    !serialized.includes(`[REDACTED:path:${fnv1a(request.targetPath)}]`) ||
    !serialized.includes("[REDACTED:secret]")
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_MARKERS_INVALID");
  }
}

function fnv1a(value: string): string {
  let hash = 0x811c9dc5;
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193);
  }
  return (hash >>> 0).toString(16).padStart(8, "0");
}

function countRawOccurrences(values: readonly SerializedDiagnosticValue[], rawValues: readonly string[]): number {
  const needles = new Set<string>();
  for (const rawValue of rawValues) {
    if (rawValue.length === 0) {
      continue;
    }
    needles.add(rawValue);
    const encoded = JSON.stringify(rawValue).slice(1, -1);
    needles.add(encoded);
  }
  let count = 0;
  for (const value of values) {
    for (const needle of needles) {
      count += countSubstring(value.text, needle);
    }
  }
  return count;
}

function countPatternOccurrences(values: readonly SerializedDiagnosticValue[], pattern: RegExp): number {
  let count = 0;
  for (const value of values) {
    count += value.text.match(pattern)?.length ?? 0;
  }
  return count;
}

function countSubstring(value: string, needle: string): number {
  let count = 0;
  let offset = 0;
  while (offset <= value.length - needle.length) {
    const index = value.indexOf(needle, offset);
    if (index < 0) {
      break;
    }
    count += 1;
    offset = index + needle.length;
  }
  return count;
}

function pathVariants(value: string): string[] {
  return [...new Set([value, value.replaceAll("\\", "/"), value.replaceAll("/", "\\")])];
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
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_AUTH_ACTIVITY_INVALID");
  }
  return { ...value };
}

function isAbsolutePath(value: string): boolean {
  return nodePath.isAbsolute(value) || nodePath.win32.isAbsolute(value) || nodePath.posix.isAbsolute(value);
}

function normalizeAbsolutePath(value: string): string {
  return nodePath.resolve(value).replace(/[\\/]+$/u, "").toLowerCase();
}

function isCanonicalOperationId(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u.test(value) &&
    value !== "00000000-0000-0000-0000-000000000000";
}

function requireExactKeys(value: Record<string, unknown>, keys: readonly string[]): void {
  if (Object.keys(value).sort().join(",") !== [...keys].sort().join(",")) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REDACTION_REQUEST_INVALID");
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

export class InstalledSvnAnonymousRedactionReportError extends Error {
  public readonly messageKey = "error.diagnostics.installedSvnAnonymousRedactionReportInvalid";

  public constructor(public readonly code: string) {
    super(code);
    this.name = "InstalledSvnAnonymousRedactionReportError";
  }
}

function reportError(code: string): InstalledSvnAnonymousRedactionReportError {
  return new InstalledSvnAnonymousRedactionReportError(code);
}
