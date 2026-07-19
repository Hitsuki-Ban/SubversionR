import { createHash, randomUUID } from "node:crypto";
import { mkdir, readdir, readFile, stat } from "node:fs/promises";
import { createRequire } from "node:module";
import path from "node:path";

const SCHEMA = "subversionr.release.m8-i6-packaged-native-recovery-blocked.v1";
const PROTOCOL = { major: 1, minor: 35 };
const JOURNAL_FILE = "subversionr-remote-checkout-mutations-v1.json";
let connection;

try {
  const options = parseOptions(process.argv.slice(2));
  const faultEndpoint = parseRepositoryUrl(options.faultRepositoryUrl);
  const healthyEndpoint = parseRepositoryUrl(options.healthyRepositoryUrl);
  const remoteAccessModule = path.resolve(
    path.dirname(options.backendModule),
    "..",
    "security",
    "remoteAccessProfile.js",
  );
  await requireFilesystemContract(options);
  await requireFile(remoteAccessModule);

  const require = createRequire(import.meta.url);
  const { startBackendProcess } = require(options.backendModule);
  const { RemoteOperationEnvelopeFactory, canonicalEndpointFromRepositoryUrl } = require(remoteAccessModule);
  if (
    typeof startBackendProcess !== "function" ||
    typeof RemoteOperationEnvelopeFactory !== "function" ||
    typeof canonicalEndpointFromRepositoryUrl !== "function" ||
    !sameEndpoint(canonicalEndpointFromRepositoryUrl(options.faultRepositoryUrl), faultEndpoint) ||
    !sameEndpoint(canonicalEndpointFromRepositoryUrl(options.healthyRepositoryUrl), healthyEndpoint)
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_MODULE_INVALID");
  }

  const remoteStateRoot = path.join(options.profileRoot, "remote-state");
  await mkdir(remoteStateRoot);
  const inboundMethods = [];
  const startConnection = async (phase) => await startBackendProcess(
      {
        executablePath: options.daemon,
        bridgeDllPath: options.bridge,
        cacheRoot: path.join(options.profileRoot, "cache"),
        remoteStateRoot,
        clientName: `subversionr-m8-i6-packaged-recovery-blocked-${phase}`,
        clientVersion: "1",
        locale: "en",
        workspaceTrust: "trusted",
        baseEnv: isolatedEnvironment(options.profileRoot),
      },
      {
        requestHandler: async (method) => {
          inboundMethods.push(method);
          throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_CREDENTIAL_HANDLER_FORBIDDEN");
        },
        notificationHandler: () => undefined,
      },
    );

  connection = await startConnection("origin");
  let trustEpoch = requireCapabilities(connection);
  let envelopeFactory = createEnvelopeFactory(RemoteOperationEnvelopeFactory, connection);
  let context = { options, faultEndpoint, healthyEndpoint, remoteStateRoot, inboundMethods, trustEpoch, envelopeFactory };
  const originObservation = await runOriginPhase(context);
  requireNoCredentialsAndStableTrust(context);
  const diagnostics = await connection.sendRequest("diagnostics/get", {});
  requireDiagnostics(diagnostics, options);
  requireNoCredentialsAndStableTrust(context);
  await requireNoTemporaryRoots(options.profileRoot);
  await connection.shutdown();
  connection = undefined;
  await requireNoTemporaryRoots(options.profileRoot);

  connection = await startConnection("restart");
  trustEpoch = requireCapabilities(connection);
  envelopeFactory = createEnvelopeFactory(RemoteOperationEnvelopeFactory, connection);
  context = { options, faultEndpoint, healthyEndpoint, remoteStateRoot, inboundMethods, trustEpoch, envelopeFactory };
  const recoveryObservation = await runRecoveryPhase(context);
  requireNoCredentialsAndStableTrust(context);
  const restartDiagnostics = await connection.sendRequest("diagnostics/get", {});
  requireDiagnostics(restartDiagnostics, options);
  requireNoCredentialsAndStableTrust(context);
  await requireNoTemporaryRoots(options.profileRoot);
  await connection.shutdown();
  connection = undefined;
  await requireNoTemporaryRoots(options.profileRoot);

  process.stdout.write(`${JSON.stringify({
    schema: SCHEMA,
    status: "passed",
    cell: "recoveryBlocked",
    protocol: PROTOCOL,
    remoteSvnAnonymous: true,
    ...originObservation,
    ...recoveryObservation,
    daemonRestarts: 1,
    credentialRequests: 0,
    credentialSettlements: 0,
    temporaryRootsAfter: 0,
    diagnosticsRedacted: true,
    fixtureCliInvocations: 0,
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

async function runOriginPhase(context) {
  const { options, faultEndpoint, trustEpoch, envelopeFactory, remoteStateRoot } = context;
  const pendingCheckout = connection.sendRequest("repository/checkout", checkoutRequest(
      options,
      options.faultRepositoryUrl,
      remoteEnvelope(envelopeFactory, faultEndpoint, trustEpoch, options.originOperationId, options.originTimeoutMs),
    )).then(
      (value) => ({ status: "fulfilled", value }),
      (error) => ({ status: "rejected", error }),
    );
  const targetSha256 = hashTarget(options.checkoutTarget);
  const originOperationIdSha256 = hashText(options.originOperationId);
  await waitForCommandBarrierAndArmedJournal(remoteStateRoot, options, targetSha256);
  const checkoutOutcome = await pendingCheckout;
  const observedError = checkoutOutcome.status === "rejected" ? checkoutOutcome.error : undefined;
  requireOriginSettlement(observedError);
  requireRedacted(observedError, options);
  await requireAbsent(options.checkoutTarget, "CHECKOUT_TARGET_UNEXPECTEDLY_PRESENT");

  const listed = await connection.sendRequest("remote/listCheckoutTargetRecoveries", {});
  requireBlockedList(listed, options, targetSha256);
  await requireBlockedJournal(remoteStateRoot, options, targetSha256);
  requireNoCredentialsAndStableTrust(context);

  return {
    originCode: "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT",
    originReason: "operationDeadlineExceeded",
    settlementCode: "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED",
    settlementReason: "remoteRecoveryBlocked",
    journalState: "blocked",
    commandBarrierObserved: true,
    journalArmedObserved: true,
    armedWindowObserved: true,
    targetAttributionHashed: true,
    armedTargetPathSha256: targetSha256,
    armedOriginOperationIdSha256: originOperationIdSha256,
    partialTargetObserved: false,
    daemonRestartRequired: true,
  };
}

async function runRecoveryPhase(context) {
  const { options, faultEndpoint, healthyEndpoint, trustEpoch, envelopeFactory, remoteStateRoot } = context;
  const targetSha256 = hashTarget(options.checkoutTarget);
  const originOperationIdSha256 = hashText(options.originOperationId);
  const firstList = await connection.sendRequest("remote/listCheckoutTargetRecoveries", {});
  requireBlockedList(firstList, options, targetSha256);
  await requireBlockedJournal(remoteStateRoot, options, targetSha256);
  await requireAbsent(options.checkoutTarget, "CHECKOUT_TARGET_UNEXPECTEDLY_PRESENT");
  const fixtureBeforeBlockedRetry = await readExactCommandBarrierState(options.faultStatePath);

  let blockedError;
  try {
    await connection.sendRequest("repository/checkout", checkoutRequest(
      options,
      options.faultRepositoryUrl,
      remoteEnvelope(envelopeFactory, faultEndpoint, trustEpoch, randomUUID(), options.healthyTimeoutMs),
    ));
  } catch (error) {
    blockedError = error;
  }
  requireSameTargetBlocked(blockedError);
  requireRedacted(blockedError, options);
  const fixtureAfterBlockedRetry = await readExactCommandBarrierState(options.faultStatePath);
  if (JSON.stringify(fixtureAfterBlockedRetry) !== JSON.stringify(fixtureBeforeBlockedRetry)) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_FIXTURE_CONTACTED_ON_RETRY");
  }
  await requireAbsent(options.checkoutTarget, "CHECKOUT_TARGET_UNEXPECTEDLY_PRESENT");
  const secondList = await connection.sendRequest("remote/listCheckoutTargetRecoveries", {});
  requireBlockedList(secondList, options, targetSha256);
  await requireBlockedJournal(remoteStateRoot, options, targetSha256);

  await requireAbsent(options.checkoutTarget, "CHECKOUT_TARGET_UNEXPECTEDLY_PRESENT");

  const confirmation = await connection.sendRequest("remote/confirmCheckoutTargetDisposition", {
    targetPath: path.resolve(options.checkoutTarget),
    targetSha256,
    originOperationId: options.originOperationId,
    confirmation: "reviewedAndResolved",
  });
  requireConfirmation(confirmation, options, targetSha256);
  await requireEmptyRecoveryState(remoteStateRoot);

  const checkout = await connection.sendRequest("repository/checkout", checkoutRequest(
    options,
    options.healthyRepositoryUrl,
    remoteEnvelope(envelopeFactory, healthyEndpoint, trustEpoch, randomUUID(), options.healthyTimeoutMs),
  ));
  requireFreshCheckout(checkout, options);
  await requireFile(path.join(options.checkoutTarget, ".svn", "wc.db"));
  await requireEmptyRecoveryState(remoteStateRoot);
  requireNoCredentialsAndStableTrust(context);

  return {
    restartListExact: true,
    journalStateBeforeConfirmation: "blocked",
    automaticCleanupBeforeConfirmation: false,
    sameTargetFailClosed: true,
    fixtureCountersUnchangedOnBlockedRetry: true,
    blockedCode: "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED",
    blockedReason: "remoteRecoveryBlocked",
    confirmation: "reviewedAndResolved",
    confirmationAttributionHashed: true,
    confirmedTargetPathSha256: targetSha256,
    confirmedOriginOperationIdSha256: originOperationIdSha256,
    journalEntriesAfter: 0,
    operatorDisposition: "confirmedAbsent",
    targetAbsentBeforeConfirmation: true,
    freshCheckout: true,
    freshCheckoutRevision: checkout.revision,
    targetDisposition: "confirmedAbsent",
    blocked: {
      outcome: "Blocked",
      stableCode: "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED",
      reason: "remoteRecoveryBlocked",
      restartRestoredBlocked: true,
      automaticClear: false,
      requiredConfirmation: "reviewedAndResolved",
      armedTargetPathSha256: targetSha256,
      confirmedTargetPathSha256: targetSha256,
      armedOriginOperationIdSha256: originOperationIdSha256,
      confirmedOriginOperationIdSha256: originOperationIdSha256,
      confirmedEntryRemoved: true,
      subsequentCheckoutPassed: true,
    },
  };
}

function checkoutRequest(options, repositoryUrl, remote) {
  return {
    url: repositoryUrl,
    targetPath: options.checkoutTarget,
    revision: options.checkoutRevision,
    depth: "infinity",
    ignoreExternals: true,
    remote,
  };
}

function createEnvelopeFactory(Factory, activeConnection) {
  return new Factory({
    remoteSvnAnonymous: activeConnection.initializeResult.capabilities.remoteSvnAnonymous,
    isRemoteSubmissionEnabled: () => activeConnection.isRemoteSubmissionEnabled(),
    currentRemoteTrustEpoch: () => activeConnection.currentRemoteTrustEpoch(),
  });
}

function remoteEnvelope(factory, endpoint, trustEpoch, operationId, timeoutMs) {
  const envelope = factory.createAnonymousSvn({
    operationId,
    intent: "foreground",
    interaction: "forbidden",
    timeoutMs,
    profile: {
      schema: "subversionr.remote-profile.v1",
      profileId: "m8-i6-loopback-anonymous-recovery-blocked",
      authority: endpoint,
      serverAuth: "anonymous",
      serverAccount: "none",
      serverCredentialPersistence: "secretStorage",
      proxy: "none",
      ssh: "none",
      redirectPolicy: "rejectAll",
    },
    expectedOrigin: endpoint,
  });
  if (
    envelope.operationId !== operationId ||
    envelope.timeoutMs !== timeoutMs ||
    envelope.trustEpoch !== trustEpoch ||
    !sameEndpoint(envelope.expectedOrigin, endpoint)
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_ENVELOPE_INVALID");
  }
  return envelope;
}

function requireOriginSettlement(error) {
  if (
    !isRecord(error) ||
    error.code !== "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED" ||
    error.category !== "state" ||
    error.messageKey !== "error.remote.recoveryBlocked" ||
    error.retryable !== false ||
    error.diagnostics !== null ||
    !isRecord(error.safeArgs) ||
    exactKeys(error.safeArgs) !== "originFailureCode,remoteFailure" ||
    error.safeArgs.originFailureCode !== "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT"
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_ORIGIN_SETTLEMENT_INVALID");
  }
  const failure = error.safeArgs.remoteFailure;
  if (
    !isRecord(failure) ||
    exactKeys(failure) !== "category,cleanupAppropriate,reason" ||
    failure.category !== "recovery" ||
    failure.reason !== "remoteRecoveryBlocked" ||
    failure.cleanupAppropriate !== false
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_ORIGIN_FAILURE_INVALID");
  }
}

function requireSameTargetBlocked(error) {
  if (
    !isRecord(error) ||
    error.code !== "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED" ||
    error.category !== "state" ||
    error.messageKey !== "error.remote.recoveryBlocked" ||
    error.retryable !== false ||
    error.diagnostics !== null ||
    !isRecord(error.safeArgs) ||
    exactKeys(error.safeArgs) !== ""
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_FAIL_CLOSED_INVALID");
  }
}

function requireBlockedList(value, options, targetSha256) {
  if (!isRecord(value) || exactKeys(value) !== "entries" || !Array.isArray(value.entries) || value.entries.length !== 1) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_LIST_INVALID");
  }
  const entry = value.entries[0];
  if (
    !isRecord(entry) ||
    exactKeys(entry) !== "originOperationId,state,targetPath,targetSha256" ||
    path.resolve(entry.targetPath) !== path.resolve(options.checkoutTarget) ||
    entry.targetSha256 !== targetSha256 ||
    entry.originOperationId !== options.originOperationId ||
    entry.state !== "blocked"
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_LIST_INVALID");
  }
}

async function requireBlockedJournal(remoteStateRoot, options, targetSha256) {
  const journal = await readJournal(remoteStateRoot);
  if (
    !isRecord(journal) ||
    exactKeys(journal) !== "entries,schemaVersion" ||
    journal.schemaVersion !== 1 ||
    !Array.isArray(journal.entries) ||
    journal.entries.length !== 1
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_JOURNAL_INVALID");
  }
  const entry = journal.entries[0];
  if (
    !isRecord(entry) ||
    exactKeys(entry) !== "effect,originOperationId,state,targetPath,targetSha256" ||
    entry.effect !== "checkoutTarget" ||
    entry.state !== "blocked" ||
    path.resolve(entry.targetPath) !== path.resolve(options.checkoutTarget) ||
    entry.targetSha256 !== targetSha256 ||
    entry.originOperationId !== options.originOperationId
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_JOURNAL_INVALID");
  }
}

async function waitForCommandBarrierAndArmedJournal(remoteStateRoot, options, targetSha256) {
  const deadline = Date.now() + Math.min(options.originTimeoutMs - 250, 10_000);
  for (;;) {
    const fixture = await readJsonFile(options.faultStatePath, "FAULT_STATE_INVALID");
    const journal = await readJournal(remoteStateRoot);
    const commandBarrier =
      isRecord(fixture) &&
      fixture.schema === "subversionr.release.m8-i6-ra-svn-fault-fixture.v1" &&
      fixture.scenario === "command-stall" &&
      fixture.connections === 1 &&
      fixture.greetingSent === 1 &&
      fixture.clientResponseReceived === 1 &&
      fixture.authRequestSent === 1 &&
      fixture.reposInfoSent === 1 &&
      fixture.commandsReceived === 1 &&
      fixture.followupContacts === 0;
    if (!isRecord(journal) || exactKeys(journal) !== "entries,schemaVersion" || journal.schemaVersion !== 1 || !Array.isArray(journal.entries)) {
      throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_JOURNAL_INVALID");
    }
    if (journal.entries.length === 1 && journal.entries[0]?.state === "blocked") {
      throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_ARMED_WINDOW_MISSED");
    }
    if (commandBarrier && journal.entries.length === 1) {
      const entry = journal.entries[0];
      if (
        !isRecord(entry) ||
        exactKeys(entry) !== "effect,originOperationId,state,targetPath,targetSha256" ||
        entry.effect !== "checkoutTarget" ||
        entry.state !== "armed" ||
        path.resolve(entry.targetPath) !== path.resolve(options.checkoutTarget) ||
        entry.targetSha256 !== targetSha256 ||
        entry.originOperationId !== options.originOperationId
      ) {
        throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_ARMED_JOURNAL_INVALID");
      }
      return;
    }
    if (journal.entries.length > 1 || Date.now() >= deadline) {
      throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_ARMED_WINDOW_NOT_OBSERVED");
    }
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

async function readExactCommandBarrierState(faultStatePath) {
  const fixture = await readJsonFile(faultStatePath, "FAULT_STATE_INVALID");
  if (
    !isRecord(fixture) ||
    fixture.schema !== "subversionr.release.m8-i6-ra-svn-fault-fixture.v1" ||
    fixture.scenario !== "command-stall" ||
    fixture.connections !== 1 ||
    fixture.greetingSent !== 1 ||
    fixture.clientResponseReceived !== 1 ||
    fixture.authRequestSent !== 1 ||
    fixture.reposInfoSent !== 1 ||
    fixture.commandsReceived !== 1 ||
    fixture.followupContacts !== 0
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_FAULT_STATE_INVALID");
  }
  return fixture;
}

function requireConfirmation(value, options, targetSha256) {
  if (
    !isRecord(value) ||
    exactKeys(value) !== "originOperationId,released,targetSha256" ||
    value.released !== true ||
    value.targetSha256 !== targetSha256 ||
    value.originOperationId !== options.originOperationId
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_CONFIRMATION_INVALID");
  }
}

async function requireEmptyRecoveryState(remoteStateRoot) {
  const listed = await connection.sendRequest("remote/listCheckoutTargetRecoveries", {});
  if (!isRecord(listed) || exactKeys(listed) !== "entries" || !Array.isArray(listed.entries) || listed.entries.length !== 0) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_LIST_NOT_EMPTY");
  }
  const journal = await readJournal(remoteStateRoot);
  if (
    !isRecord(journal) ||
    exactKeys(journal) !== "entries,schemaVersion" ||
    journal.schemaVersion !== 1 ||
    !Array.isArray(journal.entries) ||
    journal.entries.length !== 0
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_JOURNAL_NOT_EMPTY");
  }
}

function requireFreshCheckout(value, options) {
  if (
    !isRecord(value) ||
    exactKeys(value) !== "revision,workingCopyPath" ||
    path.resolve(value.workingCopyPath) !== path.resolve(options.checkoutTarget) ||
    value.revision !== options.checkoutRevision
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_FRESH_CHECKOUT_INVALID");
  }
}

function requireCapabilities(activeConnection) {
  const initialize = activeConnection.initializeResult;
  if (
    !isRecord(initialize) ||
    initialize.protocol?.major !== PROTOCOL.major ||
    initialize.protocol?.minor !== PROTOCOL.minor ||
    initialize.capabilities?.realLibsvnBridge !== true ||
    initialize.capabilities?.repositoryCheckout !== true ||
    initialize.capabilities?.remoteOperationEnvelope !== true ||
    initialize.capabilities?.remoteWorkerIsolation !== true ||
    initialize.capabilities?.remoteSvnAnonymous !== true ||
    !Number.isSafeInteger(initialize.acknowledgedTrustEpoch) ||
    initialize.acknowledgedTrustEpoch < 1 ||
    activeConnection.isRemoteSubmissionEnabled() !== true ||
    activeConnection.currentRemoteTrustEpoch() !== initialize.acknowledgedTrustEpoch
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_CAPABILITY_INVALID");
  }
  return initialize.acknowledgedTrustEpoch;
}

function requireNoCredentialsAndStableTrust(context) {
  if (
    context.inboundMethods.length !== 0 ||
    !connection.isRemoteSubmissionEnabled() ||
    connection.currentRemoteTrustEpoch() !== context.trustEpoch
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_SECURITY_STATE_INVALID");
  }
}

function requireDiagnostics(value, options) {
  if (
    !isRecord(value) ||
    value.source !== "subversionr-daemon" ||
    value.protocol?.major !== PROTOCOL.major ||
    value.protocol?.minor !== PROTOCOL.minor ||
    value.capabilities?.remoteSvnAnonymous !== true
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_DIAGNOSTICS_INVALID");
  }
  requireRedacted(value, options);
}

function requireRedacted(value, options) {
  let serialized;
  try {
    serialized = JSON.stringify(value);
  } catch {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_DIAGNOSTICS_INVALID");
  }
  if (typeof serialized !== "string" || Buffer.byteLength(serialized, "utf8") > 32_768) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_DIAGNOSTICS_INVALID");
  }
  const sensitive = [
    options.faultRepositoryUrl,
    options.healthyRepositoryUrl,
    options.faultStatePath,
    options.checkoutTarget,
    options.checkoutTarget.replaceAll("\\", "/"),
    options.profileRoot,
    options.profileRoot.replaceAll("\\", "/"),
    options.originOperationId,
  ].map((entry) => entry.toLowerCase());
  if (containsSensitiveString(value, sensitive, new Set())) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_DIAGNOSTICS_LEAK");
  }
}

function containsSensitiveString(value, sensitive, seen) {
  if (typeof value === "string") {
    const candidate = value.toLowerCase();
    return sensitive.some((entry) => entry.length !== 0 && candidate.includes(entry));
  }
  if (!value || typeof value !== "object") return false;
  if (seen.has(value)) throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_DIAGNOSTICS_INVALID");
  seen.add(value);
  const found = Object.entries(value).some(
    ([key, entry]) => containsSensitiveString(key, sensitive, seen) || containsSensitiveString(entry, sensitive, seen),
  );
  seen.delete(value);
  return found;
}

function parseOptions(args) {
  const names = [
    "backend-module",
    "daemon",
    "bridge",
    "profile-root",
    "checkout-target",
    "fault-repository-url",
    "healthy-repository-url",
    "fault-state-path",
    "origin-operation-id",
    "origin-timeout-ms",
    "healthy-timeout-ms",
    "checkout-revision",
  ];
  if (args.length !== names.length * 2) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_ARGUMENT_INVALID");
  }
  const parsed = {};
  for (let index = 0; index < args.length; index += 2) {
    const flag = args[index];
    const value = args[index + 1];
    if (typeof flag !== "string" || !flag.startsWith("--") || typeof value !== "string") {
      throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_ARGUMENT_INVALID");
    }
    const name = flag.slice(2);
    if (!names.includes(name) || name in parsed) {
      throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_ARGUMENT_INVALID");
    }
    parsed[name] = value;
  }
  const originTimeoutMs = strictPositiveInteger(parsed["origin-timeout-ms"], 300_000);
  const healthyTimeoutMs = strictPositiveInteger(parsed["healthy-timeout-ms"], 300_000);
  const checkoutRevision = strictPositiveInteger(parsed["checkout-revision"], Number.MAX_SAFE_INTEGER);
  if (
    names.some((name) => !(name in parsed)) ||
    !isCanonicalUuid(parsed["origin-operation-id"])
    || originTimeoutMs < 1_000
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_ARGUMENT_INVALID");
  }
  return {
    backendModule: requireAbsolute(parsed["backend-module"]),
    daemon: requireAbsolute(parsed.daemon),
    bridge: requireAbsolute(parsed.bridge),
    profileRoot: requireAbsolute(parsed["profile-root"]),
    checkoutTarget: requireAbsolute(parsed["checkout-target"]),
    faultRepositoryUrl: parsed["fault-repository-url"],
    healthyRepositoryUrl: parsed["healthy-repository-url"],
    faultStatePath: requireAbsolute(parsed["fault-state-path"]),
    originOperationId: parsed["origin-operation-id"],
    originTimeoutMs,
    healthyTimeoutMs,
    checkoutRevision,
  };
}

async function requireFilesystemContract(options) {
  for (const file of [options.backendModule, options.daemon, options.bridge]) await requireFile(file);
  await requireFile(options.faultStatePath);
  const profile = await stat(options.profileRoot);
  const parent = await stat(path.dirname(options.checkoutTarget));
  if (!profile.isDirectory() || !parent.isDirectory()) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_FILESYSTEM_INVALID");
  }
  if ((await readdir(options.profileRoot)).length !== 0) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_PROFILE_NOT_EMPTY");
  }
  await requireAbsent(options.checkoutTarget, "CHECKOUT_TARGET_PRESENT");
}

function parseRepositoryUrl(value) {
  let url;
  try {
    url = new URL(value);
  } catch {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_URL_INVALID");
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
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_URL_INVALID");
  }
  const port = Number.parseInt(url.port, 10);
  if (!Number.isInteger(port) || port < 1 || port > 65_535) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_URL_INVALID");
  }
  return { scheme: "svn", canonicalHost: "127.0.0.1", effectivePort: port };
}

function strictPositiveInteger(value, maximum) {
  const parsed = Number.parseInt(value, 10);
  if (!Number.isSafeInteger(parsed) || parsed < 1 || parsed > maximum || `${parsed}` !== value) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_ARGUMENT_INVALID");
  }
  return parsed;
}

function requireAbsolute(value) {
  if (!path.isAbsolute(value)) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_ARGUMENT_INVALID");
  }
  return path.resolve(value);
}

function hashTarget(target) {
  return hashText(path.resolve(target));
}

function hashText(value) {
  return createHash("sha256").update(value, "utf8").digest("hex");
}

async function readJournal(remoteStateRoot) {
  return await readJsonFile(path.join(remoteStateRoot, JOURNAL_FILE), "JOURNAL_INVALID");
}

async function readJsonFile(file, suffix) {
  try {
    const bytes = await readFile(file, "utf8");
    return JSON.parse(bytes);
  } catch {
    throw new Error(`SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_${suffix}`);
  }
}

async function requireFile(file) {
  let metadata;
  try {
    metadata = await stat(file);
  } catch {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_FILE_INVALID");
  }
  if (!metadata.isFile()) throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_FILE_INVALID");
}

async function requireDirectory(directory, suffix) {
  let metadata;
  try {
    metadata = await stat(directory);
  } catch {
    throw new Error(`SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_${suffix}`);
  }
  if (!metadata.isDirectory()) throw new Error(`SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_${suffix}`);
}

async function requireAbsent(target, suffix) {
  try {
    await stat(target);
  } catch (error) {
    if (isRecord(error) && error.code === "ENOENT") return;
    throw error;
  }
  throw new Error(`SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_${suffix}`);
}

async function requireNoTemporaryRoots(profileRoot) {
  const roots = await readDirectoryIfPresent(path.join(profileRoot, "SubversionR", "remote-workers"));
  if (roots.length !== 0) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_WORKER_TEMP_RESIDUE");
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

function sameEndpoint(left, right) {
  return left?.scheme === right.scheme &&
    left?.canonicalHost === right.canonicalHost &&
    left?.effectivePort === right.effectivePort;
}

function exactKeys(value) {
  return Object.keys(value).sort().join(",");
}

function isCanonicalUuid(value) {
  return typeof value === "string" &&
    value !== "00000000-0000-0000-0000-000000000000" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u.test(value);
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
  return "SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_PROBE_FAILED";
}
