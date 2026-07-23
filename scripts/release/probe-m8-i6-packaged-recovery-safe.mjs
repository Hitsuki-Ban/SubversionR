import { createHash } from "node:crypto";
import { lstat, mkdir, readFile, readdir, readlink, stat } from "node:fs/promises";
import { createRequire } from "node:module";
import path from "node:path";

const SCHEMA = "subversionr.release.m8-i6-packaged-native-recovery-safe.v1";
const PROTOCOL = { major: 1, minor: 35 };
const ORIGIN_TIMEOUT_MS = 500;
const RECOVERY_TIMEOUT_MS = 300_000;
const JOURNAL_FILE = "subversionr-remote-checkout-mutations-v1.json";
const JOURNAL_TEMP_FILE = ".subversionr-remote-checkout-mutations-v1.tmp";
let connection;
let opened;

try {
  const options = parseOptions(process.argv.slice(2));
  const endpoint = parseRepositoryUrl(options.repositoryUrl);
  await requireFilesystemContract(options);
  const initialUserContent = await snapshotUserContent(options.workingCopyPath);
  await requireNonemptyWorkingCopyDatabase(options.workingCopyPath);
  const fixtureBefore = await readFixtureState(options.fixtureStatePath, endpoint.effectivePort, "initial");
  const remoteAccessModule = path.resolve(
    path.dirname(options.backendModule),
    "..",
    "security",
    "remoteAccessProfile.js",
  );
  await requireFile(remoteAccessModule);

  const require = createRequire(import.meta.url);
  const { startBackendProcess } = require(options.backendModule);
  const { RemoteOperationEnvelopeFactory, canonicalEndpointFromRepositoryUrl } = require(remoteAccessModule);
  if (
    typeof startBackendProcess !== "function" ||
    typeof RemoteOperationEnvelopeFactory !== "function" ||
    typeof canonicalEndpointFromRepositoryUrl !== "function"
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_MODULE_INVALID");
  }
  if (!sameEndpoint(canonicalEndpointFromRepositoryUrl(options.repositoryUrl), endpoint)) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_ORIGIN_INVALID");
  }

  const inboundMethods = [];
  const notifications = [];
  const remoteStateRoot = path.join(options.profileRoot, "remote-state");
  await mkdir(remoteStateRoot);
  connection = await startBackendProcess(
    {
      executablePath: options.daemon,
      bridgeDllPath: options.bridge,
      cacheRoot: path.join(options.profileRoot, "cache"),
      remoteStateRoot,
      clientName: "subversionr-m8-i6-packaged-recovery-safe-evidence",
      clientVersion: "1",
      locale: "en",
      workspaceTrust: "trusted",
      baseEnv: isolatedEnvironment(options.profileRoot),
    },
    {
      requestHandler: async (method) => {
        inboundMethods.push(method);
        throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_CREDENTIAL_HANDLER_FORBIDDEN");
      },
      notificationHandler: (method, params) => notifications.push({ method, params }),
    },
  );

  const trustEpoch = requireCapabilities(connection);
  const envelopeFactory = new RemoteOperationEnvelopeFactory({
    remoteSvnAnonymous: connection.initializeResult.capabilities.remoteSvnAnonymous,
    isRemoteSubmissionEnabled: () => connection.isRemoteSubmissionEnabled(),
    currentRemoteTrustEpoch: () => connection.currentRemoteTrustEpoch(),
  });
  opened = await connection.sendRequest("repository/open", { path: options.workingCopyPath });
  requireOpenResponse(opened, options.workingCopyPath, endpoint);
  const baseline = await connection.sendRequest("status/getSnapshot", {
    repositoryId: opened.repositoryId,
    epoch: opened.epoch,
  });
  requireBaselineStatus(baseline, opened);

  const originRemote = envelopeFactory.createAnonymousSvn({
    operationId: options.originOperationId,
    intent: "foreground",
    interaction: "allowed",
    timeoutMs: options.originTimeoutMs,
    profile: anonymousProfile(endpoint),
    expectedOrigin: endpoint,
  });
  requireEnvelope(originRemote, options.originOperationId, options.originTimeoutMs, endpoint, trustEpoch);

  let originError;
  try {
    await connection.sendRequest("operation/run", {
      repositoryId: opened.repositoryId,
      epoch: opened.epoch,
      kind: "update",
      options: {
        version: 1,
        path: ".",
        revision: "head",
        depth: "infinity",
        depthIsSticky: false,
        ignoreExternals: true,
      },
      remote: originRemote,
    });
  } catch (error) {
    originError = error;
  }
  requireOriginTimeout(originError);
  requireRedacted(originError, options);
  requireStableTrustAndNoCredentials(connection, trustEpoch, inboundMethods);
  const fixtureAfterOrigin = await readFixtureState(options.fixtureStatePath, endpoint.effectivePort, "command");
  await waitForNotification(
    notifications,
    (notification) => isPendingRecoveryNotification(notification, opened, options.originOperationId),
    options.originTimeoutMs,
  );
  requirePendingRecoveryNotification(notifications, opened, options.originOperationId);
  await requireEmptyCheckoutJournal(remoteStateRoot);
  await requireNoTemporaryRoots(options.profileRoot);

  const recovery = await connection.sendRequest("remote/recoverWorkingCopy", {
    repositoryId: opened.repositoryId,
    epoch: opened.epoch,
    originOperationId: options.originOperationId,
    operationId: options.recoveryOperationId,
    timeoutMs: options.recoveryTimeoutMs,
  });
  requireSafeRecovery(recovery, options.recoveryOperationId);
  await requireUserContentPreserved(options.workingCopyPath, initialUserContent);
  await requireNonemptyWorkingCopyDatabase(options.workingCopyPath);
  await waitForNotification(
    notifications,
    (notification) => isSafeStaleNotification(notification, opened),
    options.originTimeoutMs,
  );
  await waitForNotification(
    notifications,
    (notification) => isUncheckedNotification(notification, opened),
    options.originTimeoutMs,
    "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_LANE_RELEASE_INVALID",
  );
  requireSafeNotifications(notifications, opened);
  requireStableTrustAndNoCredentials(connection, trustEpoch, inboundMethods);

  const reconcile = await connection.sendRequest("status/refresh", {
    repositoryId: opened.repositoryId,
    epoch: opened.epoch,
    targets: [{ path: ".", depth: "infinity", reason: "manualFullReconcile" }],
  });
  requireFreshReconcile(reconcile, opened, baseline.generation);
  const subsequent = await connection.sendRequest("status/getSnapshot", {
    repositoryId: opened.repositoryId,
    epoch: opened.epoch,
  });
  requireLocalStatus(subsequent, opened, reconcile.generation);
  await requireUserContentPreserved(options.workingCopyPath, initialUserContent);
  await requireNonemptyWorkingCopyDatabase(options.workingCopyPath);

  const diagnostics = await connection.sendRequest("diagnostics/get", {});
  requireDiagnostics(diagnostics);
  requireRedacted(diagnostics, options);
  requireStableTrustAndNoCredentials(connection, trustEpoch, inboundMethods);
  const fixtureAfterLocalRecovery = await readFixtureState(
    options.fixtureStatePath,
    endpoint.effectivePort,
    "after",
  );
  if (JSON.stringify(fixtureAfterLocalRecovery) !== JSON.stringify(fixtureAfterOrigin)) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_FOLLOWUP_NETWORK_CONTACT");
  }
  await requireEmptyCheckoutJournal(remoteStateRoot);
  await requireNoTemporaryRoots(options.profileRoot);

  const closed = await connection.sendRequest("repository/close", {
    repositoryId: opened.repositoryId,
    epoch: opened.epoch,
  });
  requireCloseResponse(closed, opened);
  opened = undefined;
  await connection.shutdown();
  connection = undefined;
  await requireUserContentPreserved(options.workingCopyPath, initialUserContent);
  const workingCopyDatabaseBytes = await requireNonemptyWorkingCopyDatabase(options.workingCopyPath);
  await requireEmptyCheckoutJournal(remoteStateRoot);
  await requireNoTemporaryRoots(options.profileRoot);
  const fixtureAfterShutdown = await readFixtureState(options.fixtureStatePath, endpoint.effectivePort, "after");
  if (JSON.stringify(fixtureAfterShutdown) !== JSON.stringify(fixtureAfterOrigin)) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_FOLLOWUP_NETWORK_CONTACT");
  }

  process.stdout.write(`${JSON.stringify({
    schema: SCHEMA,
    status: "passed",
    cell: "recoverySafe",
    surface: "packaged-native",
    stableCode: "none",
    reason: "none",
    settlementCode: "none",
    settlementReason: "none",
    protocol: PROTOCOL,
    remoteSvnAnonymous: true,
    prerequisite: {
      code: "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT",
      reason: "operationDeadlineExceeded",
      recovery: "pending",
    },
    transitions: ["pending", "safe", "unchecked"],
    statusStaleReason: "remoteRecoverySafeRequiresFullReconcile",
    fixtureCountersUnchangedAfterPrerequisite: true,
    safe: {
      outcome: "Safe",
      freshReconcile: true,
      nativeLaneReleased: true,
      subsequentRequestPassed: true,
    },
    networkProgress: "command",
    networkAttempts: 1,
    networkConnections: 1,
    followupNetworkContacts: 0,
    fixtureCliInvocations: 0,
    credentialRequests: 0,
    credentialSettlements: 0,
    certificateRequests: 0,
    temporaryRootsAfter: 0,
    journalEntriesAfter: 0,
    journalTemporaryFilesAfter: 0,
    workingCopyContentPreserved: true,
    workingCopyDatabaseBytes,
    diagnosticsRedacted: true,
  })}\n`);
} catch (error) {
  connection?.dispose();
  process.stdout.write(`${JSON.stringify({
    schema: SCHEMA,
    status: "failed",
    error: { code: safeErrorCode(error) },
  })}\n`);
  process.exitCode = 1;
}

function requireOriginTimeout(error) {
  if (
    !isRecord(error) ||
    error.code !== "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT" ||
    error.category !== "timeout" ||
    error.messageKey !== "error.remote.workerTimedOut" ||
    error.retryable !== false ||
    error.diagnostics !== null ||
    !isRecord(error.safeArgs) ||
    exactKeys(error.safeArgs) !== "remoteFailure"
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_ORIGIN_INVALID");
  }
  const failure = error.safeArgs.remoteFailure;
  if (
    !isRecord(failure) ||
    exactKeys(failure) !== "category,cleanupAppropriate,reason" ||
    failure.category !== "deadline" ||
    failure.reason !== "operationDeadlineExceeded" ||
    failure.cleanupAppropriate !== false
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_ORIGIN_FAILURE_INVALID");
  }
}

function requireSafeRecovery(value, operationId) {
  if (
    !isRecord(value) ||
    exactKeys(value) !== "completedAt,operationId,outcome" ||
    value.outcome !== "safe" ||
    value.operationId !== operationId ||
    typeof value.completedAt !== "string" ||
    value.completedAt.length === 0 ||
    value.completedAt.length > 64 ||
    Number.isNaN(Date.parse(value.completedAt))
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_SETTLEMENT_INVALID");
  }
}

function requirePendingRecoveryNotification(notifications, session, operationId) {
  const matches = notifications.filter((notification) =>
    isPendingRecoveryNotification(notification, session, operationId));
  if (matches.length !== 1) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_PENDING_INVALID");
  }
  const state = matches[0].params.state;
  if (
    exactKeys(state) !== "cleanupAppropriate,kind,originOperationId,reason,recovery" ||
    state.kind !== "indeterminate" ||
    state.reason !== "workerTerminated" ||
    state.originOperationId !== operationId ||
    state.recovery !== "pending" ||
    state.cleanupAppropriate !== false
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_PENDING_INVALID");
  }
}

function isPendingRecoveryNotification(notification, session, operationId) {
  return notification?.method === "remoteConnection/state" &&
    notification.params?.repositoryId === session?.repositoryId &&
    notification.params?.epoch === session?.epoch &&
    notification.params?.state?.kind === "indeterminate" &&
    notification.params?.state?.originOperationId === operationId &&
    notification.params?.state?.recovery === "pending";
}

function requireSafeNotifications(notifications, session) {
  const stale = notifications.filter((notification) => isSafeStaleNotification(notification, session));
  if (stale.length !== 1) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_STALE_INVALID");
  }
  const params = stale[0].params;
  if (
    exactKeys(params) !== "epoch,reason,repositoryId,source,timestamp" ||
    params.reason !== "remoteRecoverySafeRequiresFullReconcile" ||
    params.source !== "subversionr-daemon" ||
    typeof params.timestamp !== "string" ||
    params.timestamp.length === 0 ||
    params.timestamp.length > 64 ||
    Number.isNaN(Date.parse(params.timestamp))
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_STALE_INVALID");
  }
  const unchecked = notifications.filter((notification) =>
    isUncheckedNotification(notification, session));
  if (
    unchecked.length !== 1 ||
    exactKeys(unchecked[0].params) !== "epoch,repositoryId,state" ||
    !isRecord(unchecked[0].params.state) ||
    exactKeys(unchecked[0].params.state) !== "kind"
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_LANE_RELEASE_INVALID");
  }
}

function isUncheckedNotification(notification, session) {
  return notification?.method === "remoteConnection/state" &&
    notification.params?.repositoryId === session?.repositoryId &&
    notification.params?.epoch === session?.epoch &&
    notification.params?.state?.kind === "unchecked";
}

function isSafeStaleNotification(notification, session) {
  return notification?.method === "status/stale" &&
    notification.params?.repositoryId === session?.repositoryId &&
    notification.params?.epoch === session?.epoch &&
    notification.params?.reason === "remoteRecoverySafeRequiresFullReconcile";
}

async function waitForNotification(
  notifications,
  predicate,
  timeoutMs,
  timeoutCode = "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_NOTIFICATION_TIMEOUT",
) {
  const deadline = Date.now() + timeoutMs;
  while (!notifications.some(predicate)) {
    if (Date.now() >= deadline) {
      throw new Error(timeoutCode);
    }
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

function requireBaselineStatus(value, session) {
  if (
    !isRecord(value) ||
    value.repositoryId !== session.repositoryId ||
    value.epoch !== session.epoch ||
    value.completeness !== "complete" ||
    value.source !== "libsvn-local" ||
    !Number.isSafeInteger(value.generation) ||
    value.generation < 0
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_BASELINE_STATUS_INVALID");
  }
}

function requireFreshReconcile(value, session, baselineGeneration) {
  if (
    !isRecord(value) ||
    value.repositoryId !== session.repositoryId ||
    value.epoch !== session.epoch ||
    value.completeness !== "complete" ||
    value.source !== "libsvn-local" ||
    !Number.isSafeInteger(value.generation) ||
    value.generation <= baselineGeneration
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_RECONCILE_INVALID");
  }
}

function requireLocalStatus(value, session, reconcileGeneration) {
  if (
    !isRecord(value) ||
    value.repositoryId !== session.repositoryId ||
    value.epoch !== session.epoch ||
    value.completeness !== "complete" ||
    value.source !== "libsvn-local" ||
    !Number.isSafeInteger(value.generation) ||
    value.generation !== reconcileGeneration + 1
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_SUBSEQUENT_STATUS_INVALID");
  }
}

function requireDiagnostics(value) {
  if (
    !isRecord(value) ||
    value.source !== "subversionr-daemon" ||
    value.protocol?.major !== PROTOCOL.major ||
    value.protocol?.minor !== PROTOCOL.minor ||
    value.capabilities?.remoteSvnAnonymous !== true ||
    value.capabilities?.statusRefresh !== true ||
    value.capabilities?.statusSnapshot !== true
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_DIAGNOSTICS_INVALID");
  }
}

function requireRedacted(value, options) {
  let serialized;
  try {
    serialized = JSON.stringify(value);
  } catch {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_DIAGNOSTICS_INVALID");
  }
  if (typeof serialized !== "string" || Buffer.byteLength(serialized, "utf8") > 32_768) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_DIAGNOSTICS_INVALID");
  }
  const lowered = serialized.toLowerCase();
  for (const sensitive of [
    options.repositoryUrl,
    options.workingCopyPath,
    options.workingCopyPath.replaceAll("\\", "/"),
    options.profileRoot,
    options.profileRoot.replaceAll("\\", "/"),
    options.fixtureStatePath,
    options.fixtureStatePath.replaceAll("\\", "/"),
    options.originOperationId,
    options.recoveryOperationId,
  ]) {
    if (lowered.includes(sensitive.toLowerCase())) {
      throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_DIAGNOSTICS_LEAK");
    }
  }
}

function requireCapabilities(activeConnection) {
  const initialize = activeConnection.initializeResult;
  if (
    !isRecord(initialize) ||
    initialize.protocol?.major !== PROTOCOL.major ||
    initialize.protocol?.minor !== PROTOCOL.minor ||
    initialize.capabilities?.realLibsvnBridge !== true ||
    initialize.capabilities?.repositoryOpen !== true ||
    initialize.capabilities?.repositoryClose !== true ||
    initialize.capabilities?.statusSnapshot !== true ||
    initialize.capabilities?.statusRefresh !== true ||
    initialize.capabilities?.statusStaleNotification !== true ||
    initialize.capabilities?.operationRun !== true ||
    initialize.capabilities?.operationRunUpdate !== true ||
    initialize.capabilities?.remoteOperationEnvelope !== true ||
    initialize.capabilities?.remoteWorkerIsolation !== true ||
    initialize.capabilities?.remoteConnectionState !== true ||
    initialize.capabilities?.remoteSvnAnonymous !== true ||
    !Number.isSafeInteger(initialize.acknowledgedTrustEpoch) ||
    initialize.acknowledgedTrustEpoch < 1 ||
    activeConnection.isRemoteSubmissionEnabled() !== true ||
    activeConnection.currentRemoteTrustEpoch() !== initialize.acknowledgedTrustEpoch
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_CAPABILITY_INVALID");
  }
  return initialize.acknowledgedTrustEpoch;
}

function requireStableTrustAndNoCredentials(activeConnection, trustEpoch, inboundMethods) {
  if (!activeConnection.isRemoteSubmissionEnabled() || activeConnection.currentRemoteTrustEpoch() !== trustEpoch) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_TRUST_INVALID");
  }
  if (inboundMethods.length !== 0) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_CREDENTIAL_HANDLER_INVOKED");
  }
}

function requireOpenResponse(value, workingCopyPath, endpoint) {
  if (
    !isRecord(value) ||
    typeof value.repositoryId !== "string" ||
    value.repositoryId.length === 0 ||
    !Number.isSafeInteger(value.epoch) ||
    value.epoch < 1 ||
    !isRecord(value.identity) ||
    path.resolve(value.identity.workingCopyRoot) !== path.resolve(workingCopyPath) ||
    typeof value.identity.repositoryRootUrl !== "string"
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_OPEN_INVALID");
  }
  let repositoryRoot;
  try {
    repositoryRoot = new URL(value.identity.repositoryRootUrl);
  } catch {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_OPEN_INVALID");
  }
  if (
    repositoryRoot.protocol !== "svn:" ||
    repositoryRoot.hostname !== endpoint.canonicalHost ||
    Number.parseInt(repositoryRoot.port || "3690", 10) !== endpoint.effectivePort ||
    repositoryRoot.pathname !== "/repo"
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_OPEN_INVALID");
  }
}

function requireEnvelope(envelope, operationId, timeoutMs, endpoint, trustEpoch) {
  if (
    !isRecord(envelope) ||
    exactKeys(envelope) !==
      "expectedOrigin,intent,interaction,operationId,profile,timeoutMs,trustEpoch,version,workspaceTrust" ||
    envelope.version !== 1 ||
    envelope.operationId !== operationId ||
    envelope.trustEpoch !== trustEpoch ||
    envelope.workspaceTrust !== "trusted" ||
    envelope.intent !== "foreground" ||
    envelope.interaction !== "allowed" ||
    envelope.timeoutMs !== timeoutMs ||
    !sameEndpoint(envelope.expectedOrigin, endpoint) ||
    !isRecord(envelope.profile) ||
    exactKeys(envelope.profile) !==
      "authority,profileId,proxy,redirectPolicy,schema,serverAccount,serverAuth,serverCredentialPersistence,ssh" ||
    envelope.profile.schema !== "subversionr.remote-profile.v1" ||
    envelope.profile.profileId !== "m8-i6-loopback-anonymous-recovery-safe" ||
    !sameEndpoint(envelope.profile.authority, endpoint) ||
    envelope.profile.serverAuth !== "anonymous" ||
    envelope.profile.serverAccount !== "none" ||
    envelope.profile.serverCredentialPersistence !== "secretStorage" ||
    envelope.profile.proxy !== "none" ||
    envelope.profile.ssh !== "none" ||
    envelope.profile.redirectPolicy !== "rejectAll"
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_ENVELOPE_INVALID");
  }
}

function requireCloseResponse(value, session) {
  if (
    !isRecord(value) ||
    exactKeys(value) !== "closed,epoch,repositoryId" ||
    value.repositoryId !== session.repositoryId ||
    value.epoch !== session.epoch ||
    value.closed !== true
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_CLOSE_INVALID");
  }
}

function anonymousProfile(endpoint) {
  return {
    schema: "subversionr.remote-profile.v1",
    profileId: "m8-i6-loopback-anonymous-recovery-safe",
    authority: endpoint,
    serverAuth: "anonymous",
    serverAccount: "none",
    serverCredentialPersistence: "secretStorage",
    proxy: "none",
    ssh: "none",
    redirectPolicy: "rejectAll",
  };
}

function parseRepositoryUrl(value) {
  let url;
  try {
    url = new URL(value);
  } catch {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_URL_INVALID");
  }
  if (
    url.protocol !== "svn:" ||
    url.hostname !== "127.0.0.1" ||
    url.port.length === 0 ||
    url.username.length !== 0 ||
    url.password.length !== 0 ||
    url.search.length !== 0 ||
    url.hash.length !== 0 ||
    url.pathname !== "/repo/trunk"
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_URL_INVALID");
  }
  const port = Number.parseInt(url.port, 10);
  if (!Number.isInteger(port) || port < 1 || port > 65_535) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_URL_INVALID");
  }
  return { scheme: "svn", canonicalHost: "127.0.0.1", effectivePort: port };
}

function parseOptions(args) {
  const names = [
    "backend-module",
    "daemon",
    "bridge",
    "profile-root",
    "working-copy-path",
    "repository-url",
    "fixture-state-path",
    "origin-operation-id",
    "recovery-operation-id",
    "origin-timeout-ms",
    "recovery-timeout-ms",
  ];
  if (args.length !== names.length * 2) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_ARGUMENT_INVALID");
  }
  const parsed = {};
  for (let index = 0; index < args.length; index += 2) {
    const rawName = args[index];
    const rawValue = args[index + 1];
    if (typeof rawName !== "string" || !rawName.startsWith("--") || typeof rawValue !== "string") {
      throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_ARGUMENT_INVALID");
    }
    const name = rawName.slice(2);
    if (!names.includes(name) || name in parsed) {
      throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_ARGUMENT_INVALID");
    }
    parsed[name] = rawValue;
  }
  if (names.some((name) => !(name in parsed))) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_ARGUMENT_INVALID");
  }
  const originTimeoutMs = parseExactInteger(parsed["origin-timeout-ms"]);
  const recoveryTimeoutMs = parseExactInteger(parsed["recovery-timeout-ms"]);
  const originOperationId = parsed["origin-operation-id"];
  const recoveryOperationId = parsed["recovery-operation-id"];
  if (
    originTimeoutMs !== ORIGIN_TIMEOUT_MS ||
    recoveryTimeoutMs !== RECOVERY_TIMEOUT_MS ||
    !isCanonicalUuid(originOperationId) ||
    !isCanonicalUuid(recoveryOperationId) ||
    originOperationId === recoveryOperationId
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_ARGUMENT_INVALID");
  }
  return {
    backendModule: requireAbsolute(parsed["backend-module"]),
    daemon: requireAbsolute(parsed.daemon),
    bridge: requireAbsolute(parsed.bridge),
    profileRoot: requireAbsolute(parsed["profile-root"]),
    workingCopyPath: requireAbsolute(parsed["working-copy-path"]),
    repositoryUrl: parsed["repository-url"],
    fixtureStatePath: requireAbsolute(parsed["fixture-state-path"]),
    originOperationId,
    recoveryOperationId,
    originTimeoutMs,
    recoveryTimeoutMs,
  };
}

function parseExactInteger(value) {
  const parsed = Number.parseInt(value, 10);
  return Number.isSafeInteger(parsed) && `${parsed}` === value ? parsed : Number.NaN;
}

async function requireFilesystemContract(options) {
  for (const file of [options.backendModule, options.daemon, options.bridge, options.fixtureStatePath]) {
    await requireFile(file);
  }
  const profile = await stat(options.profileRoot);
  const workingCopy = await stat(options.workingCopyPath);
  const wcDatabase = await stat(path.join(options.workingCopyPath, ".svn", "wc.db"));
  if (
    !profile.isDirectory() ||
    (await readdir(options.profileRoot)).length !== 0 ||
    !workingCopy.isDirectory() ||
    !wcDatabase.isFile() ||
    wcDatabase.size < 1
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_FILESYSTEM_INVALID");
  }
}

async function snapshotUserContent(workingCopyPath) {
  const snapshot = [];
  const visit = async (directory, relativeDirectory) => {
    let entries;
    try {
      entries = await readdir(directory, { withFileTypes: true });
    } catch {
      throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_FILESYSTEM_INVALID");
    }
    entries.sort((left, right) => left.name < right.name ? -1 : left.name > right.name ? 1 : 0);
    for (const entry of entries) {
      if (entry.name === ".svn") continue;
      const relativePath = relativeDirectory === "" ? entry.name : `${relativeDirectory}/${entry.name}`;
      const absolutePath = path.join(directory, entry.name);
      let entryStat;
      try {
        entryStat = await lstat(absolutePath);
      } catch {
        throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_FILESYSTEM_INVALID");
      }
      if (entryStat.isDirectory()) {
        snapshot.push({ kind: "directory", path: relativePath });
        await visit(absolutePath, relativePath);
      } else if (entryStat.isFile()) {
        let content;
        try {
          content = await readFile(absolutePath);
        } catch {
          throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_FILESYSTEM_INVALID");
        }
        snapshot.push({
          kind: "file",
          path: relativePath,
          bytes: content.byteLength,
          sha256: createHash("sha256").update(content).digest("hex"),
        });
      } else if (entryStat.isSymbolicLink()) {
        let target;
        try {
          target = await readlink(absolutePath);
        } catch {
          throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_FILESYSTEM_INVALID");
        }
        snapshot.push({ kind: "symbolicLink", path: relativePath, target });
      } else {
        throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_FILESYSTEM_INVALID");
      }
    }
  };
  await visit(workingCopyPath, "");
  return JSON.stringify(snapshot);
}

async function requireUserContentPreserved(workingCopyPath, expectedSnapshot) {
  let currentSnapshot;
  try {
    currentSnapshot = await snapshotUserContent(workingCopyPath);
  } catch {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_USER_CONTENT_CHANGED");
  }
  if (currentSnapshot !== expectedSnapshot) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_USER_CONTENT_CHANGED");
  }
}

async function requireNonemptyWorkingCopyDatabase(workingCopyPath) {
  let wcDatabase;
  try {
    wcDatabase = await stat(path.join(workingCopyPath, ".svn", "wc.db"));
  } catch {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_WC_DATABASE_INVALID");
  }
  if (!wcDatabase.isFile() || wcDatabase.size < 1) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_WC_DATABASE_INVALID");
  }
  return wcDatabase.size;
}

async function readFixtureState(statePath, expectedPort, phase) {
  let value;
  try {
    value = JSON.parse(await readFile(statePath, "utf8"));
  } catch {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_FIXTURE_STATE_INVALID");
  }
  if (
    !isRecord(value) ||
    exactKeys(value) !==
      "authRequestSent,clientResponseReceived,commandsReceived,connections,followupContacts,greetingSent,pid,port,reposInfoSent,scenario,schema,status,suppliedAuthorityConnections,suppliedAuthorityPort" ||
    value.schema !== "subversionr.release.m8-i6-ra-svn-fault-fixture.v1" ||
    !Number.isSafeInteger(value.pid) ||
    value.pid < 1 ||
    value.port !== expectedPort ||
    value.suppliedAuthorityPort !== 0 ||
    value.scenario !== "command-stall" ||
    value.status !== "ready" ||
    !Number.isSafeInteger(value.suppliedAuthorityConnections) ||
    value.suppliedAuthorityConnections < 0 ||
    !Number.isSafeInteger(value.followupContacts) ||
    value.followupContacts < 0
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_FIXTURE_STATE_INVALID");
  }
  if (phase !== "after") {
    const expected = phase === "initial"
      ? { connections: 0, greetingSent: 0, clientResponseReceived: 0, authRequestSent: 0, reposInfoSent: 0, commandsReceived: 0, suppliedAuthorityConnections: 0, followupContacts: 0 }
      : { connections: 1, greetingSent: 1, clientResponseReceived: 1, authRequestSent: 1, reposInfoSent: 1, commandsReceived: 1, suppliedAuthorityConnections: 0, followupContacts: 0 };
    for (const [name, count] of Object.entries(expected)) {
      if (value[name] !== count) {
        throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_FIXTURE_STATE_INVALID");
      }
    }
  }
  return value;
}

async function requireEmptyCheckoutJournal(remoteStateRoot) {
  const temporaryPath = path.join(remoteStateRoot, JOURNAL_TEMP_FILE);
  if (await pathExists(temporaryPath)) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_JOURNAL_RESIDUE");
  }
  let journal;
  try {
    journal = JSON.parse(await readFile(path.join(remoteStateRoot, JOURNAL_FILE), "utf8"));
  } catch {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_JOURNAL_INVALID");
  }
  if (
    !isRecord(journal) ||
    exactKeys(journal) !== "entries,schemaVersion" ||
    journal.schemaVersion !== 1 ||
    !Array.isArray(journal.entries) ||
    journal.entries.length !== 0
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_JOURNAL_INVALID");
  }
}

async function requireNoTemporaryRoots(profileRoot) {
  const roots = await readDirectoryIfPresent(path.join(profileRoot, "SubversionR", "remote-workers"));
  if (roots.length !== 0) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_WORKER_TEMP_RESIDUE");
  }
}

async function requireFile(file) {
  let fileStat;
  try {
    fileStat = await stat(file);
  } catch {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_FILE_INVALID");
  }
  if (!fileStat.isFile()) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_FILE_INVALID");
  }
}

async function pathExists(value) {
  try {
    await stat(value);
    return true;
  } catch (error) {
    if (isRecord(error) && error.code === "ENOENT") return false;
    throw error;
  }
}

async function readDirectoryIfPresent(directory) {
  try {
    return await readdir(directory);
  } catch (error) {
    if (isRecord(error) && error.code === "ENOENT") return [];
    throw error;
  }
}

function requireAbsolute(value) {
  if (!path.isAbsolute(value)) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_ARGUMENT_INVALID");
  }
  return path.resolve(value);
}

function isolatedEnvironment(profileRoot) {
  return {
    ...process.env,
    APPDATA: profileRoot,
    LOCALAPPDATA: profileRoot,
    USERPROFILE: profileRoot,
    HOME: profileRoot,
    TEMP: profileRoot,
    TMP: profileRoot,
  };
}

function isCanonicalUuid(value) {
  return typeof value === "string" &&
    value !== "00000000-0000-0000-0000-000000000000" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u.test(value);
}

function sameEndpoint(left, right) {
  return left?.scheme === right.scheme &&
    left?.canonicalHost === right.canonicalHost &&
    left?.effectivePort === right.effectivePort;
}

function exactKeys(value) {
  return Object.keys(value).sort().join(",");
}

function isRecord(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function safeErrorCode(error) {
  if (isRecord(error) && typeof error.code === "string" && /^SUBVERSIONR_[A-Z0-9_]+$/u.test(error.code)) {
    return error.code;
  }
  if (error instanceof Error && /^SUBVERSIONR_[A-Z0-9_]+$/u.test(error.message)) {
    return error.message;
  }
  return "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_PROBE_FAILED";
}
