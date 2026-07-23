import { createHash } from "node:crypto";
import { mkdir, readFile, readdir, stat } from "node:fs/promises";
import { createRequire } from "node:module";
import path from "node:path";

const SCHEMA = "subversionr.release.m8-i6-packaged-native-trust-revoked.v1";
const FIXTURE_SCHEMA = "subversionr.release.m8-i6-ra-svn-fault-fixture.v1";
const PROTOCOL = { major: 1, minor: 35 };
const OPERATION_TIMEOUT_MS = 30_000;
let connection;
let opened;

try {
  const options = parseOptions(process.argv.slice(2));
  const endpoint = parseRepositoryUrl(options.repositoryUrl);
  const fixtureBefore = await requireFilesystemContract(options, endpoint);
  const workingCopyIntegrity = await captureWorkingCopyIntegrity(options.workingCopyPath);
  const remoteAccessModule = path.resolve(path.dirname(options.backendModule), "..", "security", "remoteAccessProfile.js");
  await requireFile(remoteAccessModule);

  const require = createRequire(import.meta.url);
  const { startBackendProcess } = require(options.backendModule);
  const { RemoteOperationEnvelopeFactory, canonicalEndpointFromRepositoryUrl } = require(remoteAccessModule);
  if (
    typeof startBackendProcess !== "function" ||
    typeof RemoteOperationEnvelopeFactory !== "function" ||
    typeof canonicalEndpointFromRepositoryUrl !== "function"
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_MODULE_INVALID");
  }
  if (!sameEndpoint(canonicalEndpointFromRepositoryUrl(options.repositoryUrl), endpoint)) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_ORIGIN_INVALID");
  }

  const remoteStateRoot = path.join(options.profileRoot, "remote-state");
  await mkdir(remoteStateRoot);
  const inboundMethods = [];
  connection = await startBackendProcess(
    {
      executablePath: options.daemon,
      bridgeDllPath: options.bridge,
      cacheRoot: path.join(options.profileRoot, "cache"),
      remoteStateRoot,
      clientName: "subversionr-m8-i6-packaged-trust-revoked-evidence",
      clientVersion: "1",
      locale: "en",
      workspaceTrust: "trusted",
      baseEnv: isolatedEnvironment(options.profileRoot),
    },
    {
      requestHandler: async (method) => {
        inboundMethods.push(method);
        throw new Error("SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_CREDENTIAL_HANDLER_FORBIDDEN");
      },
      notificationHandler: () => undefined,
    },
  );

  const epoch1 = requireCapabilities(connection);
  const envelopeFactory = new RemoteOperationEnvelopeFactory({
    remoteSvnAnonymous: connection.initializeResult.capabilities.remoteSvnAnonymous,
    isRemoteSubmissionEnabled: () => connection.isRemoteSubmissionEnabled(),
    currentRemoteTrustEpoch: () => connection.currentRemoteTrustEpoch(),
  });
  const staleRemote = envelopeFactory.createAnonymousSvn({
    operationId: options.operationId,
    intent: "foreground",
    interaction: "allowed",
    timeoutMs: OPERATION_TIMEOUT_MS,
    profile: anonymousProfile(endpoint),
    expectedOrigin: endpoint,
  });
  requireEnvelope(staleRemote, options, endpoint, epoch1);

  opened = await connection.sendRequest("repository/open", { path: options.workingCopyPath });
  requireOpenResponse(opened, options.workingCopyPath, endpoint);
  await requireFixtureUnchanged(options.fixtureStatePath, endpoint.effectivePort, fixtureBefore);

  const epoch2 = await connection.updateWorkspaceTrust(false);
  requireRevokedTrust(connection, epoch1, epoch2, inboundMethods);
  await requireFixtureUnchanged(options.fixtureStatePath, endpoint.effectivePort, fixtureBefore);

  let observedError;
  try {
    await connection.sendRequest("status/checkRemote", {
      repositoryId: opened.repositoryId,
      epoch: opened.epoch,
      remote: staleRemote,
    });
  } catch (error) {
    observedError = error;
  }
  requireExpectedFailure(observedError);
  requireRedacted(observedError, options);
  requireRevokedTrust(connection, epoch1, epoch2, inboundMethods);
  await requireFixtureUnchanged(options.fixtureStatePath, endpoint.effectivePort, fixtureBefore);
  await requireWorkingCopyPreserved(options.workingCopyPath, workingCopyIntegrity);

  const snapshot = await connection.sendRequest("status/getSnapshot", {
    repositoryId: opened.repositoryId,
    epoch: opened.epoch,
  });
  requireLocalSnapshot(snapshot, opened);
  requireRevokedTrust(connection, epoch1, epoch2, inboundMethods);
  await requireFixtureUnchanged(options.fixtureStatePath, endpoint.effectivePort, fixtureBefore);

  const diagnostics = await connection.sendRequest("diagnostics/get", {});
  requireDiagnosticsRedacted(diagnostics, options);
  requireRevokedTrust(connection, epoch1, epoch2, inboundMethods);
  await requireFixtureUnchanged(options.fixtureStatePath, endpoint.effectivePort, fixtureBefore);

  const closed = await connection.sendRequest("repository/close", {
    repositoryId: opened.repositoryId,
    epoch: opened.epoch,
  });
  requireCloseResponse(closed, opened);
  opened = undefined;
  await requireWorkingCopyPreserved(options.workingCopyPath, workingCopyIntegrity);
  await requireFixtureUnchanged(options.fixtureStatePath, endpoint.effectivePort, fixtureBefore);

  const temporaryRoots = await readTemporaryRoots(options.profileRoot);
  const credentialRoots = await readCredentialRoots(options.profileRoot);
  if (temporaryRoots.length !== 0) throw new Error("SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_WORKER_TEMP_RESIDUE");
  if (credentialRoots.length !== 0) throw new Error("SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_CREDENTIAL_RESIDUE");
  await connection.shutdown();
  connection = undefined;
  const temporaryRootsAfterShutdown = await readTemporaryRoots(options.profileRoot);
  const credentialRootsAfterShutdown = await readCredentialRoots(options.profileRoot);
  if (temporaryRootsAfterShutdown.length !== 0) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_WORKER_TEMP_RESIDUE");
  }
  if (credentialRootsAfterShutdown.length !== 0) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_CREDENTIAL_RESIDUE");
  }
  await requireFixtureUnchanged(options.fixtureStatePath, endpoint.effectivePort, fixtureBefore);

  process.stdout.write(`${JSON.stringify({
    schema: SCHEMA,
    status: "passed",
    cell: "trustRevoked",
    stableCode: "SUBVERSIONR_REMOTE_TRUST_EPOCH_MISMATCH",
    reason: "remoteConfigurationInvalid",
    protocol: PROTOCOL,
    trustTransition: {
      fromEpoch: epoch1,
      toEpoch: epoch2,
      staleEnvelopeEpoch: epoch1,
      remoteSubmissionEnabledAfter: false,
    },
    remoteSvnAnonymous: true,
    nativeLaneReleased: true,
    localSnapshotAfterTrustRevocation: true,
    workingCopyPreserved: true,
    networkAttempts: 0,
    temporaryRootsAfter: temporaryRootsAfterShutdown.length,
    credentialRootsAfter: credentialRootsAfterShutdown.length,
    credentialRequests: 0,
    credentialSettlements: 0,
    diagnosticsRedacted: true,
    fixtureCliInvocations: 0,
  })}\n`);
} catch (error) {
  if (opened && connection) {
    try {
      await connection.sendRequest("repository/close", { repositoryId: opened.repositoryId, epoch: opened.epoch });
    } catch {
      // Preserve the primary fail-closed result.
    }
  }
  connection?.dispose();
  process.stdout.write(`${JSON.stringify({ schema: SCHEMA, status: "failed", error: { code: safeErrorCode(error) } })}\n`);
  process.exitCode = 1;
}

function requireExpectedFailure(error) {
  if (
    !isRecord(error) ||
    error.name !== "JsonRpcStreamError" ||
    error.code !== "SUBVERSIONR_REMOTE_TRUST_EPOCH_MISMATCH" ||
    error.category !== "state" ||
    error.messageKey !== "error.remote.trustEpochMismatch" ||
    error.retryable !== false ||
    error.diagnostics !== null ||
    !isRecord(error.safeArgs) ||
    Object.keys(error.safeArgs).sort().join(",") !== "remoteFailure"
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_ERROR_INVALID");
  }
  const failure = error.safeArgs.remoteFailure;
  if (
    !isRecord(failure) ||
    Object.keys(failure).sort().join(",") !== "category,cleanupAppropriate,reason" ||
    failure.category !== "configuration" ||
    failure.reason !== "remoteConfigurationInvalid" ||
    failure.cleanupAppropriate !== false
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_FAILURE_INVALID");
  }
}

function requireLocalSnapshot(value, session) {
  if (!isRecord(value) || value.repositoryId !== session.repositoryId || value.epoch !== session.epoch || value.source !== "libsvn-local") {
    throw new Error("SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_LOCAL_SNAPSHOT_INVALID");
  }
}

function requireDiagnosticsRedacted(value, options) {
  if (
    !isRecord(value) ||
    value.source !== "subversionr-daemon" ||
    value.protocol?.major !== PROTOCOL.major ||
    value.protocol?.minor !== PROTOCOL.minor ||
    value.capabilities?.remoteSvnAnonymous !== true ||
    value.capabilities?.statusRemoteCheck !== true ||
    value.capabilities?.statusSnapshot !== true
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_DIAGNOSTICS_INVALID");
  }
  requireRedacted(value, options);
}

function requireRedacted(value, options) {
  let serialized;
  try {
    serialized = JSON.stringify(value);
  } catch {
    throw new Error("SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_DIAGNOSTICS_INVALID");
  }
  if (typeof serialized !== "string" || Buffer.byteLength(serialized, "utf8") > 32_768) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_DIAGNOSTICS_INVALID");
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
    options.operationId,
  ]) {
    const escaped = JSON.stringify(sensitive).slice(1, -1).toLowerCase();
    if (lowered.includes(escaped)) throw new Error("SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_DIAGNOSTICS_LEAK");
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
    initialize.capabilities?.statusRemoteCheck !== true ||
    initialize.capabilities?.remoteOperationEnvelope !== true ||
    initialize.capabilities?.remoteWorkerIsolation !== true ||
    initialize.capabilities?.remoteConnectionState !== true ||
    initialize.capabilities?.remoteSvnAnonymous !== true ||
    !Number.isSafeInteger(initialize.acknowledgedTrustEpoch) ||
    initialize.acknowledgedTrustEpoch < 1 ||
    activeConnection.isRemoteSubmissionEnabled() !== true ||
    activeConnection.currentRemoteTrustEpoch() !== initialize.acknowledgedTrustEpoch ||
    typeof activeConnection.updateWorkspaceTrust !== "function"
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_CAPABILITY_INVALID");
  }
  return initialize.acknowledgedTrustEpoch;
}

function requireRevokedTrust(activeConnection, epoch1, epoch2, inboundMethods) {
  if (
    !Number.isSafeInteger(epoch2) ||
    epoch2 !== epoch1 + 1 ||
    activeConnection.currentRemoteTrustEpoch() !== epoch2 ||
    activeConnection.isRemoteSubmissionEnabled() !== false
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_TRUST_INVALID");
  }
  if (inboundMethods.length !== 0) throw new Error("SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_CREDENTIAL_HANDLER_INVOKED");
}

function requireOpenResponse(value, workingCopyPath, endpoint) {
  if (
    !isRecord(value) ||
    typeof value.repositoryId !== "string" || value.repositoryId.length === 0 ||
    !Number.isSafeInteger(value.epoch) || value.epoch < 1 ||
    !isRecord(value.identity) ||
    path.resolve(value.identity.workingCopyRoot) !== path.resolve(workingCopyPath) ||
    typeof value.identity.repositoryRootUrl !== "string"
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_OPEN_INVALID");
  }
  let repositoryRoot;
  try {
    repositoryRoot = new URL(value.identity.repositoryRootUrl);
  } catch {
    throw new Error("SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_OPEN_INVALID");
  }
  if (
    repositoryRoot.protocol !== "svn:" ||
    repositoryRoot.hostname !== endpoint.canonicalHost ||
    Number.parseInt(repositoryRoot.port || "3690", 10) !== endpoint.effectivePort
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_OPEN_INVALID");
  }
}

function requireEnvelope(envelope, options, endpoint, trustEpoch) {
  if (
    !isRecord(envelope) ||
    Object.keys(envelope).sort().join(",") !== "expectedOrigin,intent,interaction,operationId,profile,timeoutMs,trustEpoch,version,workspaceTrust" ||
    envelope.version !== 1 ||
    envelope.operationId !== options.operationId ||
    envelope.trustEpoch !== trustEpoch ||
    envelope.workspaceTrust !== "trusted" ||
    envelope.intent !== "foreground" ||
    envelope.interaction !== "allowed" ||
    envelope.timeoutMs !== OPERATION_TIMEOUT_MS ||
    !sameEndpoint(envelope.expectedOrigin, endpoint) ||
    !isRecord(envelope.profile) ||
    Object.keys(envelope.profile).sort().join(",") !== "authority,profileId,proxy,redirectPolicy,schema,serverAccount,serverAuth,serverCredentialPersistence,ssh" ||
    envelope.profile.schema !== "subversionr.remote-profile.v1" ||
    envelope.profile.profileId !== "m8-i6-loopback-anonymous-trust-revoked" ||
    !sameEndpoint(envelope.profile.authority, endpoint) ||
    envelope.profile.serverAuth !== "anonymous" ||
    envelope.profile.serverAccount !== "none" ||
    envelope.profile.serverCredentialPersistence !== "secretStorage" ||
    envelope.profile.proxy !== "none" ||
    envelope.profile.ssh !== "none" ||
    envelope.profile.redirectPolicy !== "rejectAll"
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_ENVELOPE_INVALID");
  }
}

function requireCloseResponse(value, session) {
  if (
    !isRecord(value) ||
    Object.keys(value).sort().join(",") !== "closed,epoch,repositoryId" ||
    value.repositoryId !== session.repositoryId ||
    value.epoch !== session.epoch ||
    value.closed !== true
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_CLOSE_INVALID");
  }
}

function anonymousProfile(endpoint) {
  return {
    schema: "subversionr.remote-profile.v1",
    profileId: "m8-i6-loopback-anonymous-trust-revoked",
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
    throw new Error("SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_URL_INVALID");
  }
  if (
    url.protocol !== "svn:" || url.hostname !== "127.0.0.1" || url.port.length === 0 ||
    url.username.length !== 0 || url.password.length !== 0 || url.search.length !== 0 ||
    url.hash.length !== 0 || url.pathname.length < 2
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_URL_INVALID");
  }
  const port = Number.parseInt(url.port, 10);
  if (!Number.isInteger(port) || port < 1 || port > 65_535) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_URL_INVALID");
  }
  return { scheme: "svn", canonicalHost: "127.0.0.1", effectivePort: port };
}

function parseOptions(args) {
  const names = ["backend-module", "daemon", "bridge", "profile-root", "working-copy-path", "repository-url", "operation-id", "fixture-state-path"];
  if (args.length !== names.length * 2) throw new Error("SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_ARGUMENT_INVALID");
  const parsed = {};
  for (let index = 0; index < args.length; index += 2) {
    const rawName = args[index];
    const rawValue = args[index + 1];
    if (typeof rawName !== "string" || !rawName.startsWith("--") || typeof rawValue !== "string") {
      throw new Error("SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_ARGUMENT_INVALID");
    }
    const name = rawName.slice(2);
    if (!names.includes(name) || name in parsed) throw new Error("SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_ARGUMENT_INVALID");
    parsed[name] = rawValue;
  }
  if (names.some((name) => !(name in parsed)) || !isCanonicalUuid(parsed["operation-id"])) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_ARGUMENT_INVALID");
  }
  return {
    backendModule: requireAbsolute(parsed["backend-module"]),
    daemon: requireAbsolute(parsed.daemon),
    bridge: requireAbsolute(parsed.bridge),
    profileRoot: requireAbsolute(parsed["profile-root"]),
    workingCopyPath: requireAbsolute(parsed["working-copy-path"]),
    repositoryUrl: parsed["repository-url"],
    operationId: parsed["operation-id"],
    fixtureStatePath: requireAbsolute(parsed["fixture-state-path"]),
  };
}

async function requireFilesystemContract(options, endpoint) {
  for (const file of [options.backendModule, options.daemon, options.bridge, options.fixtureStatePath]) await requireFile(file);
  let profile;
  let workingCopy;
  try {
    profile = await stat(options.profileRoot);
    workingCopy = await stat(options.workingCopyPath);
  } catch {
    throw new Error("SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_FILESYSTEM_INVALID");
  }
  if (!profile.isDirectory() || (await readdir(options.profileRoot)).length !== 0 || !workingCopy.isDirectory()) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_FILESYSTEM_INVALID");
  }
  return await requireZeroFixtureState(options.fixtureStatePath, endpoint.effectivePort);
}

async function requireFixtureUnchanged(fixtureStatePath, expectedPort, expected) {
  const observed = await requireZeroFixtureState(fixtureStatePath, expectedPort);
  if (JSON.stringify(observed) !== JSON.stringify(expected)) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_FIXTURE_STATE_INVALID");
  }
}

async function requireZeroFixtureState(fixtureStatePath, expectedPort) {
  let value;
  try {
    value = JSON.parse(await readFile(fixtureStatePath, "utf8"));
  } catch {
    throw new Error("SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_FIXTURE_STATE_INVALID");
  }
  const exactKeys = [
    "authRequestSent", "clientResponseReceived", "commandsReceived", "connections",
    "followupContacts", "greetingSent", "pid", "port", "reposInfoSent", "scenario",
    "schema", "status", "suppliedAuthorityConnections", "suppliedAuthorityPort",
  ];
  const counterKeys = [
    "connections", "suppliedAuthorityConnections", "greetingSent", "clientResponseReceived",
    "authRequestSent", "reposInfoSent", "commandsReceived", "followupContacts",
  ];
  if (
    !isRecord(value) ||
    Object.keys(value).sort().join(",") !== exactKeys.sort().join(",") ||
    value.schema !== FIXTURE_SCHEMA ||
    !Number.isSafeInteger(value.pid) || value.pid < 1 ||
    value.port !== expectedPort ||
    value.suppliedAuthorityPort !== 0 ||
    value.scenario !== "greeting-stall" ||
    value.status !== "ready" ||
    !counterKeys.every((key) => value[key] === 0)
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_FIXTURE_STATE_INVALID");
  }
  return value;
}

async function requireWorkingCopyPreserved(workingCopyPath, expected) {
  const observed = await captureWorkingCopyIntegrity(workingCopyPath);
  if (
    observed.wcDatabaseSize !== expected.wcDatabaseSize ||
    observed.wcDatabaseSha256 !== expected.wcDatabaseSha256 ||
    JSON.stringify(observed.userContent) !== JSON.stringify(expected.userContent)
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_WORKING_COPY_INVALID");
  }
}

async function captureWorkingCopyIntegrity(workingCopyPath) {
  let workingCopy;
  let wcDatabase;
  try {
    workingCopy = await stat(workingCopyPath);
    wcDatabase = await stat(path.join(workingCopyPath, ".svn", "wc.db"));
  } catch {
    throw new Error("SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_WORKING_COPY_INVALID");
  }
  if (!workingCopy.isDirectory() || !wcDatabase.isFile() || wcDatabase.size < 1) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_WORKING_COPY_INVALID");
  }
  const wcDatabaseContent = await readFile(path.join(workingCopyPath, ".svn", "wc.db"));
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
  children.sort((left, right) => left.name < right.name ? -1 : left.name > right.name ? 1 : 0);
  for (const child of children) {
    if (child.name === ".svn") continue;
    const relativePath = relativeDirectory.length === 0 ? child.name : path.join(relativeDirectory, child.name);
    const canonicalPath = relativePath.replaceAll("\\", "/");
    if (child.isDirectory()) {
      entries.push({ path: canonicalPath, kind: "directory" });
      await captureUserContent(workingCopyPath, relativePath, entries);
      continue;
    }
    if (!child.isFile()) throw new Error("SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_WORKING_COPY_INVALID");
    const content = await readFile(path.join(workingCopyPath, relativePath));
    entries.push({
      path: canonicalPath,
      kind: "file",
      bytes: content.byteLength,
      sha256: createHash("sha256").update(content).digest("hex"),
    });
  }
}

async function requireFile(file) {
  try {
    if ((await stat(file)).isFile()) return;
  } catch {
    // Report the exact evidence-contract failure below.
  }
  throw new Error("SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_FILE_INVALID");
}

async function readTemporaryRoots(profileRoot) {
  return await readDirectoryIfPresent(path.join(profileRoot, "SubversionR", "remote-workers"));
}

async function readCredentialRoots(profileRoot) {
  const candidates = [
    path.join(profileRoot, "credentials"),
    path.join(profileRoot, "SubversionR", "credentials"),
    path.join(profileRoot, "remote-state", "credentials"),
  ];
  const present = [];
  for (const candidate of candidates) {
    try {
      await stat(candidate);
      present.push(candidate);
    } catch (error) {
      if (!isRecord(error) || error.code !== "ENOENT") throw error;
    }
  }
  return present;
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
  if (!path.isAbsolute(value)) throw new Error("SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_ARGUMENT_INVALID");
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
  return isRecord(left) && isRecord(right) &&
    left.scheme === right.scheme &&
    left.canonicalHost === right.canonicalHost &&
    left.effectivePort === right.effectivePort;
}

function isRecord(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function safeErrorCode(error) {
  return isRecord(error) && typeof error.message === "string" && /^[A-Z0-9_]+$/u.test(error.message)
    ? error.message
    : "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_FAILED";
}
