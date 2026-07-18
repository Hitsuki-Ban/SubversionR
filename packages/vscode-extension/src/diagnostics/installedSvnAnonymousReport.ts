import { randomUUID } from "node:crypto";
import * as nodePath from "node:path";
import type { BackendConnection } from "../backend/backendProcess";
import { ContentGetRpcClient } from "../content/contentGetRpcClient";
import { HistoryBlameRpcClient } from "../history/historyBlameRpcClient";
import { HistoryLogRpcClient } from "../history/historyLogRpcClient";
import { OperationRunRpcClient } from "../operations/operationRunRpcClient";
import type { RepositorySession } from "../repository/repositorySessionService";
import { RepositoryCheckoutRpcClient } from "../repository/repositoryCheckoutRpcClient";
import type { ScmRepositoryProjection } from "../scm/sourceControlResourceStore";
import {
  RemoteOperationEnvelopeFactory,
  canonicalEndpointFromRepositoryUrl,
  type CanonicalEndpoint,
  type RemoteAccessProfileSnapshot,
  type RemoteOperationEnvelope,
} from "../security/remoteAccessProfile";
import { StatusRemoteCheckRpcClient } from "../status/statusRemoteCheckRpcClient";
import type { StatusDelta } from "../status/statusRefreshRpcClient";

const EXPECTED_PROTOCOL_MAJOR = 1;
const EXPECTED_PROTOCOL_MINOR = 35;
const MAX_SVN_REVNUM = 2_147_483_647;
const REMOTE_STATUS_TIMEOUT_MS = 30_000;
const REMOTE_OPERATION_TIMEOUT_MS = 300_000;
const EXPECTED_REMOTE_OPERATION_COUNT = 11;

type InstalledSvnAnonymousConnection = Pick<
  BackendConnection,
  "initializeResult" | "isRemoteSubmissionEnabled" | "currentRemoteTrustEpoch" | "sendRequest"
>;

export interface InstalledSvnAnonymousAuthActivity {
  credentialRequests: number;
  credentialSettlements: number;
  certificateRequests: number;
}

export interface InstalledSvnAnonymousReportOptions {
  expectedToken: string | undefined;
  request: unknown;
  initialize(): Promise<InstalledSvnAnonymousConnection>;
  openWorkingCopy(path: string): Promise<RepositorySession>;
  closeRepository(repositoryId: string): Promise<void>;
  applyRemoteStatusDelta(delta: StatusDelta): Promise<void> | void;
  fullReconcile(repositoryId: string, epoch: number): Promise<void>;
  getProjection(repositoryId: string): ScmRepositoryProjection | undefined;
  appendFile(path: string, data: string): Promise<void>;
  authActivity(): InstalledSvnAnonymousAuthActivity;
  createOperationId?(): string;
}

interface InstalledSvnAnonymousRequest {
  token: string;
  repositoryUrl: string;
  checkoutPath: string;
  checkoutRevision: number;
  filePath: string;
}

export async function collectInstalledSvnAnonymousReport(
  options: InstalledSvnAnonymousReportOptions,
): Promise<Record<string, unknown>> {
  const request = parseRequest(options.request, options.expectedToken);
  const endpoint = requireLoopbackSvnOrigin(request.repositoryUrl);
  const authBefore = requireAuthActivity(options.authActivity());
  const connection = await options.initialize();
  requireCandidateCapabilities(connection);
  const trustEpoch = connection.initializeResult.acknowledgedTrustEpoch;
  if (connection.currentRemoteTrustEpoch() !== trustEpoch) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_TRUST_EPOCH_INVALID");
  }

  const operationIds = new Set<string>();
  const createOperationId = options.createOperationId ?? randomUUID;
  const profile = anonymousLoopbackProfile(endpoint);
  const envelopeFactory = new RemoteOperationEnvelopeFactory({
    remoteSvnAnonymous: connection.initializeResult.capabilities.remoteSvnAnonymous,
    isRemoteSubmissionEnabled: () => connection.isRemoteSubmissionEnabled(),
    currentRemoteTrustEpoch: () => connection.currentRemoteTrustEpoch(),
  });
  const nextEnvelope = (timeoutMs: number): RemoteOperationEnvelope => {
    const operationId = createOperationId();
    if (!isCanonicalOperationId(operationId) || operationIds.has(operationId)) {
      throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_OPERATION_ID_INVALID");
    }
    operationIds.add(operationId);
    const envelope = envelopeFactory.createAnonymousSvn({
      operationId,
      intent: "foreground",
      interaction: "allowed",
      timeoutMs,
      profile,
      expectedOrigin: endpoint,
    });
    if (envelope.trustEpoch !== trustEpoch || !sameEndpoint(envelope.expectedOrigin, endpoint)) {
      throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_ENVELOPE_INVALID");
    }
    return envelope;
  };

  const checkout = await new RepositoryCheckoutRpcClient(connection).checkout({
    url: request.repositoryUrl,
    targetPath: request.checkoutPath,
    revision: request.checkoutRevision,
    depth: "infinity",
    ignoreExternals: true,
    remote: nextEnvelope(REMOTE_OPERATION_TIMEOUT_MS),
  });
  if (
    normalizeAbsolutePath(checkout.workingCopyPath) !== normalizeAbsolutePath(request.checkoutPath) ||
    checkout.revision !== request.checkoutRevision
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CHECKOUT_INVALID");
  }

  let session: RepositorySession | undefined;
  try {
    session = await options.openWorkingCopy(request.checkoutPath);
    requireOpenedSession(session, request.checkoutPath, endpoint);
    let generation = requireFreshProjection(options.getProjection(session.repositoryId), session, undefined);
    const target = { repositoryId: session.repositoryId, epoch: session.epoch };
    const operationClient = new OperationRunRpcClient(connection);

    const remoteDelta = await new StatusRemoteCheckRpcClient(connection).checkRemoteStatus({
      ...target,
      remote: nextEnvelope(REMOTE_STATUS_TIMEOUT_MS),
    });
    if (remoteDelta.remoteUpsert.length === 0 || remoteDelta.summaryDelta.remoteChanges < 1) {
      throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REMOTE_STATUS_INVALID");
    }
    await options.applyRemoteStatusDelta(remoteDelta);
    generation = requireFreshProjection(options.getProjection(session.repositoryId), session, generation);

    const content = await new ContentGetRpcClient(connection).getContent({
      ...target,
      path: request.filePath,
      revision: "head",
      remote: nextEnvelope(REMOTE_OPERATION_TIMEOUT_MS),
    });
    if (content.byteLength === 0 || content.bytes.byteLength !== content.byteLength || content.source !== "libsvn-head") {
      throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CONTENT_INVALID");
    }
    await options.fullReconcile(session.repositoryId, session.epoch);
    generation = requireFreshProjection(options.getProjection(session.repositoryId), session, generation);

    const log = await new HistoryLogRpcClient(connection).getLog({
      ...target,
      path: request.filePath,
      startRevision: "head",
      endRevision: "r0",
      limit: 32,
      discoverChangedPaths: true,
      strictNodeHistory: true,
      includeMergedRevisions: false,
      remote: nextEnvelope(REMOTE_OPERATION_TIMEOUT_MS),
    });
    if (log.entries.length === 0 || log.source !== "libsvn-log") {
      throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_LOG_INVALID");
    }
    await options.fullReconcile(session.repositoryId, session.epoch);
    generation = requireFreshProjection(options.getProjection(session.repositoryId), session, generation);

    const blame = await new HistoryBlameRpcClient(connection).getBlame({
      ...target,
      path: request.filePath,
      pegRevision: "head",
      startRevision: "r0",
      endRevision: "head",
      lineStart: 1,
      lineLimit: 5_000,
      ignoreWhitespace: "none",
      ignoreEolStyle: false,
      ignoreMimeType: false,
      includeMergedRevisions: false,
      remote: nextEnvelope(REMOTE_OPERATION_TIMEOUT_MS),
    });
    if (blame.lines.length === 0 || blame.source !== "libsvn-blame") {
      throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_BLAME_INVALID");
    }
    await options.fullReconcile(session.repositoryId, session.epoch);
    generation = requireFreshProjection(options.getProjection(session.repositoryId), session, generation);

    const update = await operationClient.update({
      ...target,
      path: ".",
      revision: "head",
      depth: "infinity",
      depthIsSticky: false,
      ignoreExternals: true,
      remote: nextEnvelope(REMOTE_OPERATION_TIMEOUT_MS),
    });
    if (update.revision === null || update.revision <= checkout.revision) {
      throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_UPDATE_INVALID");
    }
    await options.fullReconcile(session.repositoryId, session.epoch);
    generation = requireFreshProjection(options.getProjection(session.repositoryId), session, generation);

    await options.appendFile(
      localPathForRepositoryFile(request.checkoutPath, request.filePath),
      "\nSubversionR installed I6 anonymous evidence mutation.\n",
    );
    const commit = await operationClient.commit({
      ...target,
      paths: [request.filePath],
      message: "SubversionR installed I6 anonymous evidence commit",
      depth: "empty",
      changelists: [],
      keepLocks: false,
      keepChangelists: false,
      commitAsOperations: false,
      includeFileExternals: false,
      includeDirExternals: false,
      remote: nextEnvelope(REMOTE_OPERATION_TIMEOUT_MS),
    });
    if (commit.revision === null || commit.revision <= update.revision) {
      throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_COMMIT_INVALID");
    }
    await options.fullReconcile(session.repositoryId, session.epoch);
    generation = requireFreshProjection(options.getProjection(session.repositoryId), session, generation);

    const repositoryRootUrl = session.identity.repositoryRootUrl.replace(/\/+$/, "");
    const branchUrl = `${repositoryRootUrl}/branches/i6`;
    requireSameOriginUrl(branchUrl, endpoint);
    const branch = await operationClient.branchCreate({
      ...target,
      sourceUrl: request.repositoryUrl,
      destinationUrl: branchUrl,
      revision: "head",
      message: "SubversionR installed I6 anonymous evidence branch",
      makeParents: false,
      ignoreExternals: true,
      remote: nextEnvelope(REMOTE_OPERATION_TIMEOUT_MS),
    });
    if (branch.revision === null || branch.revision <= commit.revision) {
      throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_BRANCH_INVALID");
    }
    await options.fullReconcile(session.repositoryId, session.epoch);
    generation = requireFreshProjection(options.getProjection(session.repositoryId), session, generation);

    const switched = await operationClient.switch({
      ...target,
      path: ".",
      url: branchUrl,
      revision: "head",
      depth: "infinity",
      depthIsSticky: false,
      ignoreExternals: true,
      ignoreAncestry: false,
      remote: nextEnvelope(REMOTE_OPERATION_TIMEOUT_MS),
    });
    if (switched.revision !== branch.revision) {
      throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_SWITCH_INVALID");
    }
    await options.fullReconcile(session.repositoryId, session.epoch);
    generation = requireFreshProjection(options.getProjection(session.repositoryId), session, generation);

    const locked = await operationClient.lock({
      ...target,
      paths: [request.filePath],
      comment: "SubversionR installed I6 anonymous evidence lock",
      stealLock: false,
      remote: nextEnvelope(REMOTE_OPERATION_TIMEOUT_MS),
    });
    requireSinglePathOperation(locked.touchedPaths, locked.summary.affectedPaths, locked.summary.skippedPaths, request.filePath);
    await options.fullReconcile(session.repositoryId, session.epoch);
    generation = requireFreshProjection(options.getProjection(session.repositoryId), session, generation);

    const unlocked = await operationClient.unlock({
      ...target,
      paths: [request.filePath],
      breakLock: false,
      remote: nextEnvelope(REMOTE_OPERATION_TIMEOUT_MS),
    });
    requireSinglePathOperation(unlocked.touchedPaths, unlocked.summary.affectedPaths, unlocked.summary.skippedPaths, request.filePath);
    await options.fullReconcile(session.repositoryId, session.epoch);
    generation = requireFreshProjection(options.getProjection(session.repositoryId), session, generation);

    if (operationIds.size !== EXPECTED_REMOTE_OPERATION_COUNT) {
      throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_OPERATION_COUNT_INVALID");
    }
    const authAfter = requireAuthActivity(options.authActivity());
    const authDelta = subtractAuthActivity(authAfter, authBefore);
    if (
      authDelta.credentialRequests !== 0 ||
      authDelta.credentialSettlements !== 0 ||
      authDelta.certificateRequests !== 0
    ) {
      throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_AUTH_ACTIVITY_INVALID");
    }

    return {
      schemaVersion: 1,
      kind: "subversionr.installedSvnAnonymousReport",
      protocol: { major: EXPECTED_PROTOCOL_MAJOR, minor: EXPECTED_PROTOCOL_MINOR },
      origin: { scheme: "svn", loopback: true, consistent: true },
      trust: { acknowledgedEpoch: trustEpoch, consistent: true },
      operations: [
        "checkoutOpen",
        "remoteStatus",
        "content",
        "historyLog",
        "historyBlame",
        "update",
        "commit",
        "branchCopy",
        "switch",
        "lock",
        "unlock",
      ],
      remoteOperationCount: operationIds.size,
      uniqueOperationIds: true,
      semanticValidation: {
        checkoutRevision: checkout.revision,
        updateRevision: update.revision,
        commitRevision: commit.revision,
        branchRevision: branch.revision,
        switchRevision: switched.revision,
        finalProjectionGeneration: generation,
        freshReconcile: true,
      },
      authActivity: authDelta,
      redaction: { rawUrls: false, rawPaths: false, rawContent: false },
    };
  } finally {
    if (session !== undefined) {
      await options.closeRepository(session.repositoryId);
    }
  }
}

function parseRequest(value: unknown, expectedToken: string | undefined): InstalledSvnAnonymousRequest {
  if (typeof expectedToken !== "string" || expectedToken.length === 0 || !isRecord(value)) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REPORT_FORBIDDEN");
  }
  if (value.token !== expectedToken) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REPORT_FORBIDDEN");
  }
  requireExactKeys(value, ["token", "repositoryUrl", "checkoutPath", "checkoutRevision", "filePath"]);
  if (typeof value.repositoryUrl !== "string" || typeof value.checkoutPath !== "string") {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REQUEST_INVALID");
  }
  if (!isAbsolutePath(value.checkoutPath) || /[\0\r\n]/.test(value.checkoutPath)) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REQUEST_INVALID");
  }
  if (
    typeof value.checkoutRevision !== "number" ||
    !Number.isSafeInteger(value.checkoutRevision) ||
    value.checkoutRevision < 0 ||
    value.checkoutRevision > MAX_SVN_REVNUM
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REQUEST_INVALID");
  }
  if (typeof value.filePath !== "string" || !isRepositoryFilePath(value.filePath)) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REQUEST_INVALID");
  }
  return {
    token: value.token,
    repositoryUrl: value.repositoryUrl,
    checkoutPath: value.checkoutPath,
    checkoutRevision: value.checkoutRevision,
    filePath: value.filePath,
  };
}

function requireCandidateCapabilities(connection: InstalledSvnAnonymousConnection): void {
  const initialize = connection.initializeResult;
  const capabilities = initialize.capabilities;
  if (
    initialize.protocol.major !== EXPECTED_PROTOCOL_MAJOR ||
    initialize.protocol.minor !== EXPECTED_PROTOCOL_MINOR ||
    initialize.acknowledgedTrustEpoch < 1 ||
    !Number.isSafeInteger(initialize.acknowledgedTrustEpoch) ||
    !connection.isRemoteSubmissionEnabled() ||
    !capabilities.realLibsvnBridge ||
    !capabilities.repositoryCheckout ||
    !capabilities.repositoryOpen ||
    !capabilities.statusSnapshot ||
    !capabilities.statusRefresh ||
    !capabilities.statusRemoteCheck ||
    !capabilities.contentGet ||
    !capabilities.contentGetRevision ||
    !capabilities.historyLog ||
    !capabilities.historyBlame ||
    !capabilities.operationRun ||
    !capabilities.operationRunUpdate ||
    !capabilities.operationRunCommit ||
    !capabilities.operationRunBranchCreate ||
    !capabilities.operationRunSwitch ||
    !capabilities.operationRunLock ||
    !capabilities.operationRunUnlock ||
    !capabilities.remoteOperationEnvelope ||
    !capabilities.remoteWorkerIsolation ||
    !capabilities.remoteConnectionState ||
    !capabilities.remoteSvnAnonymous
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CAPABILITY_UNAVAILABLE");
  }
}

function requireLoopbackSvnOrigin(repositoryUrl: string): CanonicalEndpoint {
  let parsed: URL;
  try {
    parsed = new URL(repositoryUrl);
  } catch {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_ORIGIN_INVALID");
  }
  const endpoint = canonicalEndpointFromRepositoryUrl(repositoryUrl);
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
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_ORIGIN_INVALID");
  }
  return endpoint;
}

function anonymousLoopbackProfile(endpoint: CanonicalEndpoint): RemoteAccessProfileSnapshot {
  return {
    schema: "subversionr.remote-profile.v1",
    profileId: "installed-i6-svn-anonymous",
    authority: endpoint,
    serverAuth: "anonymous",
    serverAccount: "none",
    serverCredentialPersistence: "secretStorage",
    proxy: "none",
    ssh: "none",
    redirectPolicy: "rejectAll",
  };
}

function requireOpenedSession(session: RepositorySession, checkoutPath: string, endpoint: CanonicalEndpoint): void {
  if (
    !isRecord(session) ||
    typeof session.repositoryId !== "string" ||
    session.repositoryId.length === 0 ||
    !Number.isSafeInteger(session.epoch) ||
    session.epoch < 1 ||
    normalizeAbsolutePath(session.identity.workingCopyRoot) !== normalizeAbsolutePath(checkoutPath)
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_OPEN_INVALID");
  }
  requireSameOriginUrl(session.identity.repositoryRootUrl, endpoint);
}

function requireFreshProjection(
  projection: ScmRepositoryProjection | undefined,
  session: RepositorySession,
  previousGeneration: number | undefined,
): number {
  if (
    projection === undefined ||
    projection.repositoryId !== session.repositoryId ||
    projection.epoch !== session.epoch ||
    !Number.isSafeInteger(projection.generation) ||
    (previousGeneration !== undefined && projection.generation <= previousGeneration) ||
    projection.freshness.repositoryCompleteness !== "complete" ||
    projection.freshness.lastRefreshCompleteness !== "complete" ||
    projection.freshness.lastRefreshKind === "stale"
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECONCILE_INVALID");
  }
  return projection.generation;
}

function requireSameOriginUrl(url: string, endpoint: CanonicalEndpoint): void {
  let actual: CanonicalEndpoint;
  try {
    actual = canonicalEndpointFromRepositoryUrl(url);
  } catch {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_ORIGIN_INVALID");
  }
  if (!sameEndpoint(actual, endpoint)) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_ORIGIN_INVALID");
  }
}

function requireSinglePathOperation(
  touchedPaths: readonly string[],
  affectedPaths: number,
  skippedPaths: number,
  expectedPath: string,
): void {
  if (touchedPaths.length !== 1 || touchedPaths[0] !== expectedPath || affectedPaths !== 1 || skippedPaths !== 0) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_OPERATION_RESULT_INVALID");
  }
}

function sameEndpoint(left: CanonicalEndpoint, right: CanonicalEndpoint): boolean {
  return left.scheme === right.scheme && left.canonicalHost === right.canonicalHost && left.effectivePort === right.effectivePort;
}

function localPathForRepositoryFile(checkoutPath: string, filePath: string): string {
  const absolute = nodePath.resolve(checkoutPath, ...filePath.split("/"));
  const relative = nodePath.relative(nodePath.resolve(checkoutPath), absolute);
  if (relative.length === 0 || relative.startsWith("..") || nodePath.isAbsolute(relative)) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REQUEST_INVALID");
  }
  return absolute;
}

function subtractAuthActivity(
  after: InstalledSvnAnonymousAuthActivity,
  before: InstalledSvnAnonymousAuthActivity,
): InstalledSvnAnonymousAuthActivity {
  const result = {
    credentialRequests: after.credentialRequests - before.credentialRequests,
    credentialSettlements: after.credentialSettlements - before.credentialSettlements,
    certificateRequests: after.certificateRequests - before.certificateRequests,
  };
  return requireAuthActivity(result);
}

function requireAuthActivity(value: InstalledSvnAnonymousAuthActivity): InstalledSvnAnonymousAuthActivity {
  if (
    !isRecord(value) ||
    !Number.isSafeInteger(value.credentialRequests) || value.credentialRequests < 0 ||
    !Number.isSafeInteger(value.credentialSettlements) || value.credentialSettlements < 0 ||
    !Number.isSafeInteger(value.certificateRequests) || value.certificateRequests < 0
  ) {
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_AUTH_ACTIVITY_INVALID");
  }
  return { ...value };
}

function isRepositoryFilePath(value: string): boolean {
  return value.length > 0 && value.length <= 4_096 && !/[\\\0\r\n]/.test(value) &&
    !value.startsWith("/") && !value.endsWith("/") &&
    value.split("/").every((segment) => segment.length > 0 && segment !== "." && segment !== "..");
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
    throw reportError("SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_REQUEST_INVALID");
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export class InstalledSvnAnonymousReportError extends Error {
  public readonly messageKey = "error.diagnostics.installedSvnAnonymousReportInvalid";

  public constructor(public readonly code: string) {
    super(code);
    this.name = "InstalledSvnAnonymousReportError";
  }
}

function reportError(code: string): InstalledSvnAnonymousReportError {
  return new InstalledSvnAnonymousReportError(code);
}
