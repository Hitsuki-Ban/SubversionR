import { createHash } from "node:crypto";
import { mkdir, readFile, readdir, stat } from "node:fs/promises";
import { createRequire } from "node:module";
import path from "node:path";

const SCHEMA = "subversionr.release.m8-i6-packaged-native-daemon-disconnect.v1";
const FIXTURE_SCHEMA = "subversionr.release.m8-i6-ra-svn-fault-fixture.v1";
const PROTOCOL = { major: 1, minor: 35 };
const OPERATION_TIMEOUT_MS = 30_000;
const OBSERVATION_TIMEOUT_MS = 30_000;
let connection;
let remoteRequest;
let observation;

try {
  const options = parseOptions(process.argv.slice(2));
  const endpoint = parseRepositoryUrl(options.repositoryUrl);
  await requireFilesystemContract(options, endpoint);
  const workingCopyIntegrity = await captureWorkingCopyIntegrity(options.workingCopyPath);
  const remoteAccessModule = path.resolve(path.dirname(options.backendModule), "..", "security", "remoteAccessProfile.js");
  await requireFile(remoteAccessModule);

  const require = createRequire(import.meta.url);
  const { startBackendProcess } = require(options.backendModule);
  const { RemoteOperationEnvelopeFactory, canonicalEndpointFromRepositoryUrl } = require(remoteAccessModule);
  if (
    typeof startBackendProcess !== "function" || typeof RemoteOperationEnvelopeFactory !== "function" ||
    typeof canonicalEndpointFromRepositoryUrl !== "function" ||
    !sameEndpoint(canonicalEndpointFromRepositoryUrl(options.repositoryUrl), endpoint)
  ) throw new Error("SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_MODULE_INVALID");

  const remoteStateRoot = path.join(options.profileRoot, "remote-state");
  await mkdir(remoteStateRoot);
  const inboundMethods = [];
  const ordering = [];
  observation = createDaemonStateObservation(options.operationId, ordering);
  connection = await startBackendProcess({
    executablePath: options.daemon,
    bridgeDllPath: options.bridge,
    cacheRoot: path.join(options.profileRoot, "cache"),
    remoteStateRoot,
    clientName: "subversionr-m8-i6-packaged-daemon-disconnect-evidence",
    clientVersion: "1",
    locale: "en",
    workspaceTrust: "trusted",
    baseEnv: isolatedEnvironment(options.profileRoot),
  }, {
    requestHandler: async (method) => {
      inboundMethods.push(method);
      throw new Error("SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_AUTH_HANDLER_FORBIDDEN");
    },
    notificationHandler: observation.onNotification,
  });

  const trustEpoch = requireCapabilities(connection);
  const opened = await connection.sendRequest("repository/open", { path: options.workingCopyPath });
  requireOpenResponse(opened, options.workingCopyPath, endpoint);
  const remote = new RemoteOperationEnvelopeFactory({
    remoteSvnAnonymous: connection.initializeResult.capabilities.remoteSvnAnonymous,
    isRemoteSubmissionEnabled: () => connection.isRemoteSubmissionEnabled(),
    currentRemoteTrustEpoch: () => connection.currentRemoteTrustEpoch(),
  }).createAnonymousSvn({
    operationId: options.operationId,
    intent: "foreground",
    interaction: "allowed",
    timeoutMs: OPERATION_TIMEOUT_MS,
    profile: anonymousProfile(endpoint),
    expectedOrigin: endpoint,
  });
  requireEnvelope(remote, options.operationId, endpoint, trustEpoch);

  remoteRequest = connection.sendRequest("status/checkRemote", {
    repositoryId: opened.repositoryId,
    epoch: opened.epoch,
    remote,
  }).then(
    () => { throw new Error("SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_RESULT_UNEXPECTED"); },
    (error) => {
      requireWireDisconnect(error);
      requireRedacted(error, options);
      ordering.push("activeRequestSettlement");
      return error;
    },
  );

  await waitForGreetingBarrier(options.fixtureStatePath, endpoint.effectivePort);
  requireStableTrustAndNoAuth(connection, trustEpoch, inboundMethods);
  await waitForShutdownTrigger(options.shutdownTriggerPath);

  const shutdown = connection.shutdown().then(() => ordering.push("shutdownAck"));
  await remoteRequest;
  remoteRequest = undefined;
  const daemonState = await observation.complete(opened);
  await shutdown;
  connection = undefined;
  observation.dispose();
  observation = undefined;

  if (
    ordering.length !== 3 || ordering[2] !== "shutdownAck" ||
    !ordering.slice(0, 2).includes("activeRequestSettlement") ||
    !ordering.slice(0, 2).includes("daemonState")
  ) throw new Error("SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_ORDER_INVALID");

  requireGreetingBarrier(await readFixtureState(options.fixtureStatePath, endpoint.effectivePort));
  await requireWorkingCopyPreserved(options.workingCopyPath, workingCopyIntegrity);
  await requireNoTemporaryRoots(options.profileRoot);
  if (inboundMethods.length !== 0) throw new Error("SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_AUTH_ACTIVITY_INVALID");

  process.stdout.write(`${JSON.stringify({
    schema: SCHEMA,
    status: "passed",
    cell: "daemonDisconnect",
    surface: "packaged-native",
    stableCode: "SUBVERSIONR_REMOTE_WORKER_DISCONNECTED",
    reason: "workerContainmentFailed",
    protocol: PROTOCOL,
    settlement: disconnectedSettlement(),
    daemonState,
    daemonDisconnectSettlement: {
      trigger: "graceful-client-shutdown-after-greeting",
      activeRequestSettlementObserved: true,
      daemonStateObserved: true,
      settlementBeforeShutdownAck: true,
      shutdownAcknowledged: true,
      workingCopyPreserved: true,
    },
    remoteSvnAnonymous: true,
    credentialRequests: 0,
    credentialSettlements: 0,
    certificateRequests: 0,
    temporaryRootsAfter: 0,
    diagnosticsRedacted: true,
    fixtureCliInvocations: 0,
  })}\n`);
} catch (error) {
  if (remoteRequest) void remoteRequest.catch(() => undefined);
  observation?.dispose();
  connection?.dispose();
  process.stdout.write(`${JSON.stringify({ schema: SCHEMA, status: "failed", error: { code: safeErrorCode(error) } })}\n`);
  process.exitCode = 1;
}

function disconnectedSettlement() {
  return {
    code: "SUBVERSIONR_REMOTE_WORKER_DISCONNECTED",
    category: "state",
    messageKey: "error.remote.workerDisconnected",
    retryable: false,
    safeArgs: { remoteFailure: { category: "process", reason: "workerContainmentFailed", cleanupAppropriate: false } },
    diagnostics: null,
  };
}

function requireWireDisconnect(error) {
  if (
    !isRecord(error) || error.name !== "JsonRpcStreamError" ||
    error.code !== "SUBVERSIONR_REMOTE_WORKER_DISCONNECTED" || error.category !== "state" ||
    error.messageKey !== "error.remote.workerDisconnected" || error.retryable !== false ||
    error.diagnostics !== null || !isRecord(error.safeArgs) || exactKeys(error.safeArgs) !== "remoteFailure"
  ) throw new Error("SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_WIRE_INVALID");
  const failure = error.safeArgs.remoteFailure;
  if (
    !isRecord(failure) || exactKeys(failure) !== "category,cleanupAppropriate,reason" ||
    failure.category !== "process" || failure.reason !== "workerContainmentFailed" ||
    failure.cleanupAppropriate !== false
  ) throw new Error("SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_FAILURE_INVALID");
}

function createDaemonStateObservation(operationId, ordering) {
  let terminal;
  let invalid = false;
  let resolveObserved;
  let rejectObserved;
  const observed = new Promise((resolve, reject) => { resolveObserved = resolve; rejectObserved = reject; });
  const timer = setTimeout(
    () => rejectObserved(new Error("SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_STATE_TIMEOUT")),
    OBSERVATION_TIMEOUT_MS,
  );
  return {
    onNotification: (method, params) => {
      if (method !== "remoteConnection/state") return;
      const state = params?.state;
      if (state?.kind === "checking") return;
      if (
        terminal !== undefined || !isRecord(params) || !isRecord(state) ||
        state.kind !== "indeterminate" || state.reason !== "workerTerminated" ||
        state.originOperationId !== operationId || state.recovery !== "notRequired" ||
        state.cleanupAppropriate !== false
      ) {
        invalid = true;
        clearTimeout(timer);
        rejectObserved(new Error("SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_STATE_INVALID"));
        return;
      }
      terminal = params;
      ordering.push("daemonState");
      clearTimeout(timer);
      resolveObserved();
    },
    complete: async (session) => {
      await observed;
      if (
        invalid || !terminal || terminal.repositoryId !== session.repositoryId || terminal.epoch !== session.epoch
      ) throw new Error("SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_STATE_INVALID");
      return {
        kind: terminal.state.kind,
        reason: terminal.state.reason,
        originOperationIdMatched: true,
        recovery: terminal.state.recovery,
        cleanupAppropriate: terminal.state.cleanupAppropriate,
      };
    },
    dispose: () => clearTimeout(timer),
  };
}

async function waitForGreetingBarrier(file, port) {
  const deadline = Date.now() + OBSERVATION_TIMEOUT_MS;
  do {
    const state = await readFixtureState(file, port);
    if (isGreetingBarrier(state)) return;
    if (
      state.connections > 1 || state.greetingSent > 1 || state.clientResponseReceived > 1 ||
      state.authRequestSent !== 0 || state.reposInfoSent !== 0 || state.commandsReceived !== 0 ||
      state.followupContacts !== 0
    ) throw new Error("SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_FIXTURE_STATE_INVALID");
    await delay(10);
  } while (Date.now() < deadline);
  throw new Error("SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_GREETING_TIMEOUT");
}

async function waitForShutdownTrigger(file) {
  const deadline = Date.now() + OBSERVATION_TIMEOUT_MS;
  do {
    try {
      const value = await stat(file);
      if (!value.isFile() || value.size !== 0) throw new Error("SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_TRIGGER_INVALID");
      return;
    } catch (error) {
      if (!isRecord(error) || error.code !== "ENOENT") throw error;
    }
    await delay(10);
  } while (Date.now() < deadline);
  throw new Error("SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_TRIGGER_TIMEOUT");
}

function requireGreetingBarrier(state) {
  if (!isGreetingBarrier(state)) throw new Error("SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_FIXTURE_STATE_INVALID");
}
function isGreetingBarrier(state) {
  return state.connections === 1 && state.greetingSent === 1 && state.clientResponseReceived === 1 &&
    state.authRequestSent === 0 && state.reposInfoSent === 0 && state.commandsReceived === 0 &&
    state.followupContacts === 0;
}

function requireCapabilities(activeConnection) {
  const initialize = activeConnection.initializeResult;
  if (
    !isRecord(initialize) || initialize.protocol?.major !== PROTOCOL.major || initialize.protocol?.minor !== PROTOCOL.minor ||
    initialize.capabilities?.realLibsvnBridge !== true || initialize.capabilities?.repositoryOpen !== true ||
    initialize.capabilities?.statusRemoteCheck !== true || initialize.capabilities?.remoteOperationEnvelope !== true ||
    initialize.capabilities?.remoteWorkerIsolation !== true || initialize.capabilities?.remoteConnectionState !== true ||
    initialize.capabilities?.remoteSvnAnonymous !== true ||
    !Number.isSafeInteger(initialize.acknowledgedTrustEpoch) || initialize.acknowledgedTrustEpoch < 1 ||
    activeConnection.isRemoteSubmissionEnabled() !== true ||
    activeConnection.currentRemoteTrustEpoch() !== initialize.acknowledgedTrustEpoch
  ) throw new Error("SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_CAPABILITY_INVALID");
  return initialize.acknowledgedTrustEpoch;
}

function requireStableTrustAndNoAuth(activeConnection, trustEpoch, inboundMethods) {
  if (!activeConnection.isRemoteSubmissionEnabled() || activeConnection.currentRemoteTrustEpoch() !== trustEpoch) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_TRUST_INVALID");
  }
  if (inboundMethods.length !== 0) throw new Error("SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_AUTH_ACTIVITY_INVALID");
}

function requireOpenResponse(value, workingCopyPath, endpoint) {
  if (
    !isRecord(value) || typeof value.repositoryId !== "string" || value.repositoryId.length === 0 ||
    !Number.isSafeInteger(value.epoch) || value.epoch < 1 || !isRecord(value.identity) ||
    path.resolve(value.identity.workingCopyRoot) !== path.resolve(workingCopyPath) ||
    typeof value.identity.repositoryRootUrl !== "string"
  ) throw new Error("SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_OPEN_INVALID");
  let actual;
  try { actual = parseRepositoryUrl(value.identity.repositoryRootUrl); }
  catch { throw new Error("SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_OPEN_INVALID"); }
  if (!sameEndpoint(actual, endpoint)) throw new Error("SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_OPEN_INVALID");
}

function requireEnvelope(envelope, operationId, endpoint, trustEpoch) {
  if (
    !isRecord(envelope) || exactKeys(envelope) !== "expectedOrigin,intent,interaction,operationId,profile,timeoutMs,trustEpoch,version,workspaceTrust" ||
    envelope.version !== 1 || envelope.operationId !== operationId || envelope.intent !== "foreground" ||
    envelope.interaction !== "allowed" || envelope.timeoutMs !== OPERATION_TIMEOUT_MS ||
    envelope.workspaceTrust !== "trusted" || envelope.trustEpoch !== trustEpoch ||
    !sameEndpoint(envelope.expectedOrigin, endpoint) || !isRecord(envelope.profile) ||
    envelope.profile.profileId !== "m8-i6-loopback-anonymous-daemon-disconnect" ||
    !sameEndpoint(envelope.profile.authority, endpoint) || envelope.profile.serverAuth !== "anonymous"
  ) throw new Error("SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_ENVELOPE_INVALID");
}

function anonymousProfile(endpoint) {
  return {
    schema: "subversionr.remote-profile.v1",
    profileId: "m8-i6-loopback-anonymous-daemon-disconnect",
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
  try { url = new URL(value); } catch { throw new Error("SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_URL_INVALID"); }
  if (
    url.protocol !== "svn:" || url.hostname !== "127.0.0.1" || url.port.length === 0 ||
    url.username.length !== 0 || url.password.length !== 0 || url.search.length !== 0 ||
    url.hash.length !== 0 || url.pathname.length < 2
  ) throw new Error("SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_URL_INVALID");
  const port = Number.parseInt(url.port, 10);
  if (!Number.isInteger(port) || port < 1 || port > 65_535) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_URL_INVALID");
  }
  return { scheme: "svn", canonicalHost: "127.0.0.1", effectivePort: port };
}

function parseOptions(args) {
  const names = [
    "backend-module", "daemon", "bridge", "profile-root", "working-copy-path", "repository-url",
    "operation-id", "fixture-state-path", "shutdown-trigger-path",
  ];
  if (args.length !== names.length * 2) throw new Error("SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_ARGUMENT_INVALID");
  const parsed = Object.create(null);
  for (let index = 0; index < args.length; index += 2) {
    const rawName = args[index];
    const rawValue = args[index + 1];
    if (typeof rawName !== "string" || !rawName.startsWith("--") || typeof rawValue !== "string") {
      throw new Error("SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_ARGUMENT_INVALID");
    }
    const name = rawName.slice(2);
    if (!names.includes(name) || name in parsed) throw new Error("SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_ARGUMENT_INVALID");
    parsed[name] = rawValue;
  }
  if (names.some((name) => !(name in parsed)) || !isCanonicalUuid(parsed["operation-id"])) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_ARGUMENT_INVALID");
  }
  return {
    backendModule: requireAbsolute(parsed["backend-module"]), daemon: requireAbsolute(parsed.daemon),
    bridge: requireAbsolute(parsed.bridge), profileRoot: requireAbsolute(parsed["profile-root"]),
    workingCopyPath: requireAbsolute(parsed["working-copy-path"]), repositoryUrl: parsed["repository-url"],
    operationId: parsed["operation-id"], fixtureStatePath: requireAbsolute(parsed["fixture-state-path"]),
    shutdownTriggerPath: requireAbsolute(parsed["shutdown-trigger-path"]),
  };
}

async function requireFilesystemContract(options, endpoint) {
  for (const file of [options.backendModule, options.daemon, options.bridge, options.fixtureStatePath]) await requireFile(file);
  const profile = await stat(options.profileRoot);
  const workingCopy = await stat(options.workingCopyPath);
  const triggerParent = await stat(path.dirname(options.shutdownTriggerPath));
  if (!profile.isDirectory() || (await readdir(options.profileRoot)).length !== 0 || !workingCopy.isDirectory() || !triggerParent.isDirectory()) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_FILESYSTEM_INVALID");
  }
  try {
    await stat(options.shutdownTriggerPath);
    throw new Error("SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_TRIGGER_INVALID");
  } catch (error) {
    if (!isRecord(error) || error.code !== "ENOENT") throw error;
  }
  const state = await readFixtureState(options.fixtureStatePath, endpoint.effectivePort);
  if (
    state.connections !== 0 || state.greetingSent !== 0 || state.clientResponseReceived !== 0 ||
    state.authRequestSent !== 0 || state.reposInfoSent !== 0 || state.commandsReceived !== 0 ||
    state.followupContacts !== 0
  ) throw new Error("SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_FIXTURE_STATE_INVALID");
}

async function readFixtureState(file, expectedPort) {
  let value;
  try { value = JSON.parse(await readFile(file, "utf8")); }
  catch { throw new Error("SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_FIXTURE_STATE_INVALID"); }
  const keys = [
    "authRequestSent", "clientResponseReceived", "commandsReceived", "connections", "followupContacts",
    "greetingSent", "pid", "port", "reposInfoSent", "scenario", "schema", "status",
    "suppliedAuthorityConnections", "suppliedAuthorityPort",
  ];
  if (
    !isRecord(value) || exactKeys(value) !== keys.sort().join(",") || value.schema !== FIXTURE_SCHEMA ||
    value.scenario !== "greeting-stall" || value.status !== "ready" ||
    !Number.isSafeInteger(value.pid) || value.pid < 1 || value.port !== expectedPort ||
    value.suppliedAuthorityPort !== 0 || value.suppliedAuthorityConnections !== 0 ||
    !["connections", "greetingSent", "clientResponseReceived", "authRequestSent", "reposInfoSent", "commandsReceived", "followupContacts"]
      .every((key) => Number.isSafeInteger(value[key]) && value[key] >= 0)
  ) throw new Error("SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_FIXTURE_STATE_INVALID");
  return value;
}

async function requireWorkingCopyPreserved(workingCopyPath, expected) {
  const observed = await captureWorkingCopyIntegrity(workingCopyPath);
  if (
    observed.wcDatabaseSize !== expected.wcDatabaseSize || observed.wcDatabaseSha256 !== expected.wcDatabaseSha256 ||
    JSON.stringify(observed.userContent) !== JSON.stringify(expected.userContent)
  ) throw new Error("SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_WORKING_COPY_INVALID");
}

async function captureWorkingCopyIntegrity(workingCopyPath) {
  const wcDatabasePath = path.join(workingCopyPath, ".svn", "wc.db");
  let wcDatabase;
  try { wcDatabase = await stat(wcDatabasePath); }
  catch { throw new Error("SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_WORKING_COPY_INVALID"); }
  if (!wcDatabase.isFile() || wcDatabase.size < 1) throw new Error("SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_WORKING_COPY_INVALID");
  const wcDatabaseContent = await readFile(wcDatabasePath);
  const userContent = [];
  await captureUserContent(workingCopyPath, "", userContent);
  return {
    wcDatabaseSize: wcDatabase.size,
    wcDatabaseSha256: createHash("sha256").update(wcDatabaseContent).digest("hex"),
    userContent,
  };
}

async function captureUserContent(workingCopyPath, relativeDirectory, entries) {
  const children = await readdir(path.join(workingCopyPath, relativeDirectory), { withFileTypes: true });
  children.sort((left, right) => left.name.localeCompare(right.name));
  for (const child of children) {
    if (child.name === ".svn") continue;
    const relativePath = relativeDirectory.length === 0 ? child.name : path.join(relativeDirectory, child.name);
    const canonicalPath = relativePath.replaceAll("\\", "/");
    if (child.isDirectory()) {
      entries.push({ path: canonicalPath, kind: "directory" });
      await captureUserContent(workingCopyPath, relativePath, entries);
    } else if (child.isFile()) {
      const content = await readFile(path.join(workingCopyPath, relativePath));
      entries.push({ path: canonicalPath, kind: "file", bytes: content.byteLength, sha256: createHash("sha256").update(content).digest("hex") });
    } else throw new Error("SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_WORKING_COPY_INVALID");
  }
}

async function requireNoTemporaryRoots(profileRoot) {
  let entries;
  try { entries = await readdir(path.join(profileRoot, "SubversionR", "remote-workers")); }
  catch (error) {
    if (isRecord(error) && error.code === "ENOENT") return;
    throw error;
  }
  if (entries.length !== 0) throw new Error("SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_WORKER_TEMP_RESIDUE");
}

async function requireFile(file) {
  try { if ((await stat(file)).isFile()) return; } catch { /* exact error below */ }
  throw new Error("SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_FILE_INVALID");
}
function isolatedEnvironment(profileRoot) {
  return { ...process.env, APPDATA: profileRoot, LOCALAPPDATA: profileRoot, USERPROFILE: profileRoot, HOME: profileRoot, TEMP: profileRoot, TMP: profileRoot };
}
function requireRedacted(value, options) {
  const serialized = JSON.stringify(value).toLowerCase();
  if (Buffer.byteLength(serialized, "utf8") > 32_768) throw new Error("SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_DIAGNOSTICS_INVALID");
  for (const sensitive of [
    options.repositoryUrl, options.workingCopyPath, options.workingCopyPath.replaceAll("\\", "/"),
    options.profileRoot, options.profileRoot.replaceAll("\\", "/"), options.fixtureStatePath,
    options.fixtureStatePath.replaceAll("\\", "/"), options.shutdownTriggerPath,
    options.shutdownTriggerPath.replaceAll("\\", "/"), options.operationId,
  ]) if (serialized.includes(sensitive.toLowerCase())) throw new Error("SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_DIAGNOSTICS_LEAK");
}
function requireAbsolute(value) {
  if (!path.isAbsolute(value)) throw new Error("SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_ARGUMENT_INVALID");
  return path.resolve(value);
}
function isCanonicalUuid(value) {
  return typeof value === "string" && /^(?!00000000-0000-0000-0000-000000000000$)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u.test(value);
}
function sameEndpoint(left, right) {
  return isRecord(left) && isRecord(right) && left.scheme === right.scheme && left.canonicalHost === right.canonicalHost && left.effectivePort === right.effectivePort;
}
function exactKeys(value) { return Object.keys(value).sort().join(","); }
function isRecord(value) { return typeof value === "object" && value !== null && !Array.isArray(value); }
function delay(milliseconds) { return new Promise((resolve) => setTimeout(resolve, milliseconds)); }
function safeErrorCode(error) {
  const candidate = isRecord(error) && typeof error.code === "string" ? error.code : error instanceof Error ? error.message : undefined;
  return typeof candidate === "string" && /^SUBVERSIONR_[A-Z0-9_]+$/u.test(candidate)
    ? candidate : "SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_UNKNOWN";
}
