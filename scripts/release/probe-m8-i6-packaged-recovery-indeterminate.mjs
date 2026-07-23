import { createHash } from "node:crypto";
import { lstat, mkdir, readFile, readdir, readlink, stat } from "node:fs/promises";
import { createRequire } from "node:module";
import path from "node:path";

const SCHEMA = "subversionr.release.m8-i6-packaged-native-recovery-indeterminate.v1";
const PROTOCOL = { major: 1, minor: 35 };
const ORIGIN_TIMEOUT_MS = 5_000;
const RECOVERY_TIMEOUT_MS = 300_000;
const JOURNAL_FILE = "subversionr-remote-checkout-mutations-v1.json";
const JOURNAL_TEMP_FILE = ".subversionr-remote-checkout-mutations-v1.tmp";
const INDETERMINATE_CODE = "SUBVERSIONR_REMOTE_OPERATION_INDETERMINATE";
const INDETERMINATE_REASON = "remoteOperationIndeterminate";
let connection;

try {
  const options = parseOptions(process.argv.slice(2));
  const endpoint = parseRepositoryUrl(options.repositoryUrl);
  await requireFilesystemContract(options);
  const userContentBefore = await snapshotUserContent(options.workingCopyPath);
  const fixtureBefore = await readFixtureState(options.fixtureStatePath, endpoint.effectivePort, "initial");
  const remoteAccessModule = path.resolve(path.dirname(options.backendModule), "..", "security", "remoteAccessProfile.js");
  await requireFile(remoteAccessModule);

  const require = createRequire(import.meta.url);
  const { startBackendProcess } = require(options.backendModule);
  const { RemoteOperationEnvelopeFactory, canonicalEndpointFromRepositoryUrl } = require(remoteAccessModule);
  if (
    typeof startBackendProcess !== "function" ||
    typeof RemoteOperationEnvelopeFactory !== "function" ||
    typeof canonicalEndpointFromRepositoryUrl !== "function" ||
    !sameEndpoint(canonicalEndpointFromRepositoryUrl(options.repositoryUrl), endpoint)
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_MODULE_INVALID");
  }

  const notifications = [];
  const inboundMethods = [];
  const remoteStateRoot = path.join(options.profileRoot, "remote-state");
  await mkdir(remoteStateRoot);
  connection = await startBackendProcess(
    {
      executablePath: options.daemon,
      bridgeDllPath: options.bridge,
      cacheRoot: path.join(options.profileRoot, "cache"),
      remoteStateRoot,
      clientName: "subversionr-m8-i6-packaged-recovery-indeterminate-evidence",
      clientVersion: "1",
      locale: "en",
      workspaceTrust: "trusted",
      baseEnv: isolatedEnvironment(options.profileRoot),
    },
    {
      requestHandler: async (method) => {
        inboundMethods.push(method);
        throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_CREDENTIAL_HANDLER_FORBIDDEN");
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
  const opened = await connection.sendRequest("repository/open", { path: options.workingCopyPath });
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
  await waitForNotificationCount(
    notifications,
    (notification) => isPendingRecoveryNotification(notification, opened, options.originOperationId),
    1,
    options.originTimeoutMs,
  );
  requirePendingRecoveryNotifications(notifications, opened, options.originOperationId, 1);
  await requireEmptyCheckoutJournal(remoteStateRoot);
  await requireNoTemporaryRoots(options.profileRoot);
  await requireUserContentPreserved(options.workingCopyPath, userContentBefore);

  const recovery = await connection.sendRequest("remote/recoverWorkingCopy", {
    repositoryId: opened.repositoryId,
    epoch: opened.epoch,
    originOperationId: options.originOperationId,
    operationId: options.recoveryOperationId,
    timeoutMs: options.recoveryTimeoutMs,
  });
  requireIndeterminateRecovery(recovery, options.recoveryOperationId);
  await waitForNotificationCount(
    notifications,
    (notification) => isPendingRecoveryNotification(notification, opened, options.originOperationId),
    2,
    options.originTimeoutMs,
  );
  requirePendingRecoveryNotifications(notifications, opened, options.originOperationId, 2);
  requireStableTrustAndNoCredentials(connection, trustEpoch, inboundMethods);
  await requireEmptyCheckoutJournal(remoteStateRoot);
  await requireNoTemporaryRoots(options.profileRoot);
  await requireUserContentPreserved(options.workingCopyPath, userContentBefore);

  let laneError;
  try {
    await connection.sendRequest("status/getSnapshot", {
      repositoryId: opened.repositoryId,
      epoch: opened.epoch,
    });
  } catch (error) {
    laneError = error;
  }
  requireIndeterminateLaneError(laneError);
  requireRedacted(laneError, options);
  requireStableTrustAndNoCredentials(connection, trustEpoch, inboundMethods);

  const diagnostics = await connection.sendRequest("diagnostics/get", {});
  requireDiagnostics(diagnostics);
  requireRedacted(diagnostics, options);
  requireStableTrustAndNoCredentials(connection, trustEpoch, inboundMethods);
  const fixtureAfterLaneProof = await readFixtureState(options.fixtureStatePath, endpoint.effectivePort, "after");
  if (JSON.stringify(fixtureAfterLaneProof) !== JSON.stringify(fixtureAfterOrigin)) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_FOLLOWUP_NETWORK_CONTACT");
  }
  await requireEmptyCheckoutJournal(remoteStateRoot);
  await requireNoTemporaryRoots(options.profileRoot);
  await requireUserContentPreserved(options.workingCopyPath, userContentBefore);

  await connection.shutdown();
  connection = undefined;
  await requireEmptyCheckoutJournal(remoteStateRoot);
  await requireNoTemporaryRoots(options.profileRoot);
  await requireUserContentPreserved(options.workingCopyPath, userContentBefore);
  const fixtureAfterShutdown = await readFixtureState(options.fixtureStatePath, endpoint.effectivePort, "after");
  if (
    JSON.stringify(fixtureAfterShutdown) !== JSON.stringify(fixtureAfterOrigin) ||
    JSON.stringify(fixtureBefore) === JSON.stringify(fixtureAfterOrigin)
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_FOLLOWUP_NETWORK_CONTACT");
  }

  process.stdout.write(`${JSON.stringify({
    schema: SCHEMA,
    status: "passed",
    cell: "recoveryIndeterminate",
    surface: "packaged-native",
    stableCode: INDETERMINATE_CODE,
    reason: INDETERMINATE_REASON,
    originCode: INDETERMINATE_CODE,
    originReason: INDETERMINATE_REASON,
    settlementCode: INDETERMINATE_CODE,
    settlementReason: INDETERMINATE_REASON,
    protocol: PROTOCOL,
    remoteSvnAnonymous: true,
    prerequisite: {
      code: "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT",
      reason: "operationDeadlineExceeded",
      recovery: "pending",
    },
    indeterminate: {
      outcome: "Indeterminate",
      stableCode: INDETERMINATE_CODE,
      reason: INDETERMINATE_REASON,
      nativeLaneBlocked: true,
      explicitRecoveryRequired: true,
    },
    baselineGenerationObserved: true,
    recoveryNotificationsObserved: 2,
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
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_ORIGIN_INVALID");
  }
  const failure = error.safeArgs.remoteFailure;
  if (
    !isRecord(failure) ||
    exactKeys(failure) !== "category,cleanupAppropriate,reason" ||
    failure.category !== "deadline" ||
    failure.reason !== "operationDeadlineExceeded" ||
    failure.cleanupAppropriate !== false
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_ORIGIN_FAILURE_INVALID");
  }
}

function requireIndeterminateRecovery(value, operationId) {
  if (
    !isRecord(value) ||
    exactKeys(value) !== "failure,operationId,outcome" ||
    value.outcome !== "indeterminate" ||
    value.operationId !== operationId ||
    !isRecord(value.failure) ||
    exactKeys(value.failure) !== "category,cleanupAppropriate,reason" ||
    value.failure.category !== "unknown" ||
    value.failure.reason !== "unknownRemote" ||
    value.failure.cleanupAppropriate !== false
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_SETTLEMENT_INVALID");
  }
}

function requireIndeterminateLaneError(error) {
  if (
    !isRecord(error) ||
    error.code !== INDETERMINATE_CODE ||
    error.category !== "state" ||
    error.messageKey !== "error.remote.operationIndeterminate" ||
    error.retryable !== false ||
    error.diagnostics !== null ||
    !isRecord(error.safeArgs) ||
    exactKeys(error.safeArgs) !== "remoteFailure"
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_LANE_INVALID");
  }
  const failure = error.safeArgs.remoteFailure;
  if (
    !isRecord(failure) ||
    exactKeys(failure) !== "category,cleanupAppropriate,reason" ||
    failure.category !== "recovery" ||
    failure.reason !== INDETERMINATE_REASON ||
    failure.cleanupAppropriate !== false
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_LANE_FAILURE_INVALID");
  }
}

function requirePendingRecoveryNotifications(notifications, session, operationId, expectedCount) {
  const matches = notifications.filter((notification) =>
    isPendingRecoveryNotification(notification, session, operationId));
  if (matches.length !== expectedCount) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_PENDING_INVALID");
  }
  for (const match of matches) {
    if (
      exactKeys(match.params) !== "epoch,repositoryId,state" ||
      !isRecord(match.params.state) ||
      exactKeys(match.params.state) !== "cleanupAppropriate,kind,originOperationId,reason,recovery" ||
      match.params.state.kind !== "indeterminate" ||
      match.params.state.reason !== "workerTerminated" ||
      match.params.state.originOperationId !== operationId ||
      match.params.state.recovery !== "pending" ||
      match.params.state.cleanupAppropriate !== false
    ) {
      throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_PENDING_INVALID");
    }
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

async function waitForNotificationCount(notifications, predicate, count, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (notifications.filter(predicate).length < count) {
    if (Date.now() >= deadline) {
      throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_NOTIFICATION_TIMEOUT");
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
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_BASELINE_INVALID");
  }
}

function requireDiagnostics(value) {
  if (
    !isRecord(value) ||
    value.source !== "subversionr-daemon" ||
    value.protocol?.major !== PROTOCOL.major ||
    value.protocol?.minor !== PROTOCOL.minor ||
    value.capabilities?.remoteSvnAnonymous !== true ||
    value.capabilities?.statusSnapshot !== true ||
    value.capabilities?.remoteConnectionState !== true
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_DIAGNOSTICS_INVALID");
  }
}

function requireRedacted(value, options) {
  let serialized;
  try {
    serialized = JSON.stringify(value);
  } catch {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_DIAGNOSTICS_INVALID");
  }
  if (typeof serialized !== "string" || Buffer.byteLength(serialized, "utf8") > 32_768) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_DIAGNOSTICS_INVALID");
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
      throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_DIAGNOSTICS_LEAK");
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
    initialize.capabilities?.statusSnapshot !== true ||
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
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_CAPABILITY_INVALID");
  }
  return initialize.acknowledgedTrustEpoch;
}

function requireStableTrustAndNoCredentials(activeConnection, trustEpoch, inboundMethods) {
  if (!activeConnection.isRemoteSubmissionEnabled() || activeConnection.currentRemoteTrustEpoch() !== trustEpoch) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_TRUST_INVALID");
  }
  if (inboundMethods.length !== 0) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_CREDENTIAL_HANDLER_INVOKED");
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
    path.resolve(value.identity.workingCopyRoot) !== workingCopyPath ||
    value.identity.repositoryRootUrl !== `svn://${endpoint.canonicalHost}:${endpoint.effectivePort}/repo`
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_OPEN_INVALID");
  }
}

function requireEnvelope(envelope, operationId, timeoutMs, endpoint, trustEpoch) {
  if (
    !isRecord(envelope) ||
    exactKeys(envelope) !== "expectedOrigin,intent,interaction,operationId,profile,timeoutMs,trustEpoch,version,workspaceTrust" ||
    envelope.version !== 1 ||
    envelope.operationId !== operationId ||
    envelope.intent !== "foreground" ||
    envelope.interaction !== "allowed" ||
    envelope.timeoutMs !== timeoutMs ||
    envelope.workspaceTrust !== "trusted" ||
    envelope.trustEpoch !== trustEpoch ||
    !sameEndpoint(envelope.expectedOrigin, endpoint) ||
    !isRecord(envelope.profile) ||
    exactKeys(envelope.profile) !==
      "authority,profileId,proxy,redirectPolicy,schema,serverAccount,serverAuth,serverCredentialPersistence,ssh" ||
    envelope.profile.schema !== "subversionr.remote-profile.v1" ||
    envelope.profile.profileId !== "m8-i6-loopback-anonymous-recovery-indeterminate" ||
    envelope.profile.serverAuth !== "anonymous" ||
    envelope.profile.serverAccount !== "none" ||
    envelope.profile.serverCredentialPersistence !== "secretStorage" ||
    envelope.profile.proxy !== "none" ||
    envelope.profile.ssh !== "none" ||
    envelope.profile.redirectPolicy !== "rejectAll" ||
    !sameEndpoint(envelope.profile.authority, endpoint)
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_ENVELOPE_INVALID");
  }
}

function anonymousProfile(endpoint) {
  return {
    schema: "subversionr.remote-profile.v1",
    profileId: "m8-i6-loopback-anonymous-recovery-indeterminate",
    authority: endpoint,
    serverAuth: "anonymous",
    serverAccount: "none",
    serverCredentialPersistence: "secretStorage",
    proxy: "none",
    ssh: "none",
    redirectPolicy: "rejectAll",
  };
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
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_ARGUMENT_INVALID");
  }
  const parsed = Object.create(null);
  for (let index = 0; index < args.length; index += 2) {
    const rawName = args[index];
    const rawValue = args[index + 1];
    if (typeof rawName !== "string" || !rawName.startsWith("--") || typeof rawValue !== "string") {
      throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_ARGUMENT_INVALID");
    }
    const name = rawName.slice(2);
    if (!names.includes(name) || name in parsed) {
      throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_ARGUMENT_INVALID");
    }
    parsed[name] = rawValue;
  }
  if (names.some((name) => !(name in parsed))) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_ARGUMENT_INVALID");
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
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_ARGUMENT_INVALID");
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

function parseRepositoryUrl(value) {
  let parsed;
  try {
    parsed = new URL(value);
  } catch {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_URL_INVALID");
  }
  if (
    parsed.protocol !== "svn:" ||
    parsed.hostname !== "127.0.0.1" ||
    parsed.username !== "" ||
    parsed.password !== "" ||
    parsed.search !== "" ||
    parsed.hash !== "" ||
    parsed.pathname !== "/repo/trunk" ||
    !/^[1-9][0-9]{0,4}$/u.test(parsed.port)
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_URL_INVALID");
  }
  const effectivePort = Number(parsed.port);
  if (!Number.isSafeInteger(effectivePort) || effectivePort > 65_535) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_URL_INVALID");
  }
  return { scheme: "svn", canonicalHost: "127.0.0.1", effectivePort };
}

function parseExactInteger(value) {
  const parsed = Number.parseInt(value, 10);
  return Number.isSafeInteger(parsed) && `${parsed}` === value ? parsed : Number.NaN;
}

async function requireFilesystemContract(options) {
  for (const file of [options.backendModule, options.daemon, options.bridge, options.fixtureStatePath]) {
    await requireFile(file);
  }
  let profile;
  let workingCopy;
  let wcDatabase;
  try {
    profile = await stat(options.profileRoot);
    workingCopy = await stat(options.workingCopyPath);
    wcDatabase = await stat(path.join(options.workingCopyPath, ".svn", "wc.db"));
  } catch {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_FILESYSTEM_INVALID");
  }
  if (
    !profile.isDirectory() ||
    (await readdir(options.profileRoot)).length !== 0 ||
    !workingCopy.isDirectory() ||
    !wcDatabase.isFile() ||
    wcDatabase.size < 1
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_FILESYSTEM_INVALID");
  }
}

async function snapshotUserContent(workingCopyPath) {
  const snapshot = [];
  const visit = async (directory, relativeDirectory) => {
    let entries;
    try {
      entries = await readdir(directory, { withFileTypes: true });
    } catch {
      throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_FILESYSTEM_INVALID");
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
        throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_FILESYSTEM_INVALID");
      }
      if (entryStat.isDirectory()) {
        snapshot.push({ kind: "directory", path: relativePath });
        await visit(absolutePath, relativePath);
      } else if (entryStat.isFile()) {
        let content;
        try {
          content = await readFile(absolutePath);
        } catch {
          throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_FILESYSTEM_INVALID");
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
          throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_FILESYSTEM_INVALID");
        }
        snapshot.push({ kind: "symbolicLink", path: relativePath, target });
      } else {
        throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_FILESYSTEM_INVALID");
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
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_USER_CONTENT_CHANGED");
  }
  if (currentSnapshot !== expectedSnapshot) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_USER_CONTENT_CHANGED");
  }
}

async function readFixtureState(statePath, expectedPort, phase) {
  let value;
  try {
    value = JSON.parse(await readFile(statePath, "utf8"));
  } catch {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_FIXTURE_STATE_INVALID");
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
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_FIXTURE_STATE_INVALID");
  }
  if (phase !== "after") {
    const expected = phase === "initial"
      ? { connections: 0, greetingSent: 0, clientResponseReceived: 0, authRequestSent: 0, reposInfoSent: 0, commandsReceived: 0, suppliedAuthorityConnections: 0, followupContacts: 0 }
      : { connections: 1, greetingSent: 1, clientResponseReceived: 1, authRequestSent: 1, reposInfoSent: 1, commandsReceived: 1, suppliedAuthorityConnections: 0, followupContacts: 0 };
    for (const [name, count] of Object.entries(expected)) {
      if (value[name] !== count) {
        throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_FIXTURE_STATE_INVALID");
      }
    }
  }
  return value;
}

async function requireEmptyCheckoutJournal(remoteStateRoot) {
  if (await pathExists(path.join(remoteStateRoot, JOURNAL_TEMP_FILE))) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_JOURNAL_RESIDUE");
  }
  let journal;
  try {
    journal = JSON.parse(await readFile(path.join(remoteStateRoot, JOURNAL_FILE), "utf8"));
  } catch {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_JOURNAL_INVALID");
  }
  if (
    !isRecord(journal) ||
    exactKeys(journal) !== "entries,schemaVersion" ||
    journal.schemaVersion !== 1 ||
    !Array.isArray(journal.entries) ||
    journal.entries.length !== 0
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_JOURNAL_INVALID");
  }
}

async function requireNoTemporaryRoots(profileRoot) {
  const roots = await readDirectoryIfPresent(path.join(profileRoot, "SubversionR", "remote-workers"));
  if (roots.length !== 0) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_WORKER_TEMP_RESIDUE");
  }
}

async function requireFile(file) {
  let fileStat;
  try {
    fileStat = await stat(file);
  } catch {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_FILE_INVALID");
  }
  if (!fileStat.isFile()) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_FILE_INVALID");
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
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_ARGUMENT_INVALID");
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
  return "SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_PROBE_FAILED";
}
