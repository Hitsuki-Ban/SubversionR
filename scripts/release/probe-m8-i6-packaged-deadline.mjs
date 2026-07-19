import { createHash } from "node:crypto";
import { mkdir, readFile, readdir, stat } from "node:fs/promises";
import { createRequire } from "node:module";
import path from "node:path";
import { performance } from "node:perf_hooks";

const SCHEMA = "subversionr.release.m8-i6-packaged-native-deadline.v1";
const PROTOCOL = { major: 1, minor: 35 };
const OPERATION_TIMEOUT_MS = 500;
// This is the daemon's reviewed hard-stop cleanup supervision budget.
const CLEANUP_SLACK_MS = 5_000;
let connection;
let opened;

try {
  const options = parseOptions(process.argv.slice(2));
  const endpoint = parseRepositoryUrl(options.repositoryUrl);
  await requireFilesystemContract(options);
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
    throw new Error("SUBVERSIONR_I6_PACKAGED_DEADLINE_MODULE_INVALID");
  }
  if (!sameEndpoint(canonicalEndpointFromRepositoryUrl(options.repositoryUrl), endpoint)) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_DEADLINE_ORIGIN_INVALID");
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
      clientName: "subversionr-m8-i6-packaged-deadline-evidence",
      clientVersion: "1",
      locale: "en",
      workspaceTrust: "trusted",
      baseEnv: isolatedEnvironment(options.profileRoot),
    },
    {
      requestHandler: async (method) => {
        inboundMethods.push(method);
        throw new Error("SUBVERSIONR_I6_PACKAGED_DEADLINE_CREDENTIAL_HANDLER_FORBIDDEN");
      },
      notificationHandler: () => undefined,
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

  const remote = envelopeFactory.createAnonymousSvn({
    operationId: options.operationId,
    intent: "foreground",
    interaction: "allowed",
    timeoutMs: options.timeoutMs,
    profile: anonymousProfile(endpoint),
    expectedOrigin: endpoint,
  });
  requireEnvelope(remote, options, endpoint, trustEpoch);

  const startedAt = performance.now();
  let observedError;
  try {
    await connection.sendRequest("status/checkRemote", {
      repositoryId: opened.repositoryId,
      epoch: opened.epoch,
      remote,
    });
  } catch (error) {
    observedError = error;
  }
  const elapsedMs = performance.now() - startedAt;
  requireExpectedFailure(observedError);
  requireDeadlineTiming(elapsedMs, options.timeoutMs);
  requireRedacted(observedError, options);
  requireStableTrustAndNoCredentials(connection, trustEpoch, inboundMethods);
  await requireWorkingCopyPreserved(options.workingCopyPath, workingCopyIntegrity);

  const snapshot = await connection.sendRequest("status/getSnapshot", {
    repositoryId: opened.repositoryId,
    epoch: opened.epoch,
  });
  requireLocalSnapshot(snapshot, opened);
  requireStableTrustAndNoCredentials(connection, trustEpoch, inboundMethods);

  const diagnostics = await connection.sendRequest("diagnostics/get", {});
  requireDiagnosticsRedacted(diagnostics, options);
  requireStableTrustAndNoCredentials(connection, trustEpoch, inboundMethods);

  const closed = await connection.sendRequest("repository/close", {
    repositoryId: opened.repositoryId,
    epoch: opened.epoch,
  });
  requireCloseResponse(closed, opened);
  opened = undefined;
  await requireWorkingCopyPreserved(options.workingCopyPath, workingCopyIntegrity);

  const temporaryRoots = await readTemporaryRoots(options.profileRoot);
  if (temporaryRoots.length !== 0) throw new Error("SUBVERSIONR_I6_PACKAGED_DEADLINE_WORKER_TEMP_RESIDUE");
  await connection.shutdown();
  connection = undefined;
  const temporaryRootsAfterShutdown = await readTemporaryRoots(options.profileRoot);
  if (temporaryRootsAfterShutdown.length !== 0) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_DEADLINE_WORKER_TEMP_RESIDUE");
  }

  process.stdout.write(`${JSON.stringify({
    schema: SCHEMA,
    status: "passed",
    cell: "deadline",
    stableCode: "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT",
    reason: "operationDeadlineExceeded",
    protocol: PROTOCOL,
    timing: {
      clock: "monotonic",
      timeoutMs: options.timeoutMs,
      elapsedMs,
      cleanupSlackMs: CLEANUP_SLACK_MS,
    },
    remoteSvnAnonymous: true,
    nativeLaneReleased: true,
    localSnapshotAfterTimeout: true,
    workingCopyPreserved: true,
    temporaryRootsAfter: temporaryRootsAfterShutdown.length,
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

function requireDeadlineTiming(elapsedMs, timeoutMs) {
  if (
    typeof elapsedMs !== "number" ||
    !Number.isFinite(elapsedMs) ||
    elapsedMs < timeoutMs ||
    elapsedMs > timeoutMs + CLEANUP_SLACK_MS
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_DEADLINE_TIMING_INVALID");
  }
}

function requireExpectedFailure(error) {
  if (
    !isRecord(error) ||
    error.code !== "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT" ||
    error.category !== "timeout" ||
    error.messageKey !== "error.remote.workerTimedOut" ||
    error.retryable !== false ||
    error.diagnostics !== null ||
    !isRecord(error.safeArgs) ||
    Object.keys(error.safeArgs).sort().join(",") !== "remoteFailure"
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_DEADLINE_ERROR_INVALID");
  }
  const failure = error.safeArgs.remoteFailure;
  if (
    !isRecord(failure) ||
    Object.keys(failure).sort().join(",") !== "category,cleanupAppropriate,reason" ||
    failure.category !== "deadline" ||
    failure.reason !== "operationDeadlineExceeded" ||
    failure.cleanupAppropriate !== false
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_DEADLINE_FAILURE_INVALID");
  }
}

function requireLocalSnapshot(value, session) {
  if (!isRecord(value) || value.repositoryId !== session.repositoryId || value.epoch !== session.epoch || value.source !== "libsvn-local") {
    throw new Error("SUBVERSIONR_I6_PACKAGED_DEADLINE_LOCAL_SNAPSHOT_INVALID");
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
    throw new Error("SUBVERSIONR_I6_PACKAGED_DEADLINE_DIAGNOSTICS_INVALID");
  }
  requireRedacted(value, options);
}

function requireRedacted(value, options) {
  let serialized;
  try {
    serialized = JSON.stringify(value);
  } catch {
    throw new Error("SUBVERSIONR_I6_PACKAGED_DEADLINE_DIAGNOSTICS_INVALID");
  }
  if (typeof serialized !== "string" || Buffer.byteLength(serialized, "utf8") > 32_768) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_DEADLINE_DIAGNOSTICS_INVALID");
  }
  const lowered = serialized.toLowerCase();
  for (const sensitive of [
    options.repositoryUrl,
    options.workingCopyPath,
    options.workingCopyPath.replaceAll("\\", "/"),
    options.profileRoot,
    options.profileRoot.replaceAll("\\", "/"),
    options.operationId,
  ]) {
    if (lowered.includes(sensitive.toLowerCase())) throw new Error("SUBVERSIONR_I6_PACKAGED_DEADLINE_DIAGNOSTICS_LEAK");
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
    activeConnection.currentRemoteTrustEpoch() !== initialize.acknowledgedTrustEpoch
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_DEADLINE_CAPABILITY_INVALID");
  }
  return initialize.acknowledgedTrustEpoch;
}

function requireStableTrustAndNoCredentials(activeConnection, trustEpoch, inboundMethods) {
  if (!activeConnection.isRemoteSubmissionEnabled() || activeConnection.currentRemoteTrustEpoch() !== trustEpoch) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_DEADLINE_TRUST_INVALID");
  }
  if (inboundMethods.length !== 0) throw new Error("SUBVERSIONR_I6_PACKAGED_DEADLINE_CREDENTIAL_HANDLER_INVOKED");
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
    throw new Error("SUBVERSIONR_I6_PACKAGED_DEADLINE_OPEN_INVALID");
  }
  let repositoryRoot;
  try {
    repositoryRoot = new URL(value.identity.repositoryRootUrl);
  } catch {
    throw new Error("SUBVERSIONR_I6_PACKAGED_DEADLINE_OPEN_INVALID");
  }
  if (
    repositoryRoot.protocol !== "svn:" ||
    repositoryRoot.hostname !== endpoint.canonicalHost ||
    Number.parseInt(repositoryRoot.port || "3690", 10) !== endpoint.effectivePort
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_DEADLINE_OPEN_INVALID");
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
    envelope.timeoutMs !== options.timeoutMs ||
    !sameEndpoint(envelope.expectedOrigin, endpoint) ||
    !isRecord(envelope.profile) ||
    Object.keys(envelope.profile).sort().join(",") !== "authority,profileId,proxy,redirectPolicy,schema,serverAccount,serverAuth,serverCredentialPersistence,ssh" ||
    envelope.profile.schema !== "subversionr.remote-profile.v1" ||
    envelope.profile.profileId !== "m8-i6-loopback-anonymous-deadline" ||
    !sameEndpoint(envelope.profile.authority, endpoint) ||
    envelope.profile.serverAuth !== "anonymous" ||
    envelope.profile.serverAccount !== "none" ||
    envelope.profile.serverCredentialPersistence !== "secretStorage" ||
    envelope.profile.proxy !== "none" ||
    envelope.profile.ssh !== "none" ||
    envelope.profile.redirectPolicy !== "rejectAll"
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_DEADLINE_ENVELOPE_INVALID");
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
    throw new Error("SUBVERSIONR_I6_PACKAGED_DEADLINE_CLOSE_INVALID");
  }
}

function anonymousProfile(endpoint) {
  return {
    schema: "subversionr.remote-profile.v1",
    profileId: "m8-i6-loopback-anonymous-deadline",
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
    throw new Error("SUBVERSIONR_I6_PACKAGED_DEADLINE_URL_INVALID");
  }
  if (
    url.protocol !== "svn:" ||
    url.hostname !== "127.0.0.1" ||
    url.port.length === 0 ||
    url.username.length !== 0 ||
    url.password.length !== 0 ||
    url.search.length !== 0 ||
    url.hash.length !== 0 ||
    url.pathname.length < 2
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_DEADLINE_URL_INVALID");
  }
  const port = Number.parseInt(url.port, 10);
  if (!Number.isInteger(port) || port < 1 || port > 65_535) throw new Error("SUBVERSIONR_I6_PACKAGED_DEADLINE_URL_INVALID");
  return { scheme: "svn", canonicalHost: "127.0.0.1", effectivePort: port };
}

function parseOptions(args) {
  const names = ["backend-module", "daemon", "bridge", "profile-root", "working-copy-path", "repository-url", "operation-id", "timeout-ms"];
  if (args.length !== names.length * 2) throw new Error("SUBVERSIONR_I6_PACKAGED_DEADLINE_ARGUMENT_INVALID");
  const parsed = {};
  for (let index = 0; index < args.length; index += 2) {
    const rawName = args[index];
    const rawValue = args[index + 1];
    if (typeof rawName !== "string" || !rawName.startsWith("--") || typeof rawValue !== "string") {
      throw new Error("SUBVERSIONR_I6_PACKAGED_DEADLINE_ARGUMENT_INVALID");
    }
    const name = rawName.slice(2);
    if (!names.includes(name) || name in parsed) throw new Error("SUBVERSIONR_I6_PACKAGED_DEADLINE_ARGUMENT_INVALID");
    parsed[name] = rawValue;
  }
  if (names.some((name) => !(name in parsed))) throw new Error("SUBVERSIONR_I6_PACKAGED_DEADLINE_ARGUMENT_INVALID");
  if (
    parsed["timeout-ms"] !== `${OPERATION_TIMEOUT_MS}` ||
    !isCanonicalUuid(parsed["operation-id"])
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_DEADLINE_ARGUMENT_INVALID");
  }
  return {
    backendModule: requireAbsolute(parsed["backend-module"]),
    daemon: requireAbsolute(parsed.daemon),
    bridge: requireAbsolute(parsed.bridge),
    profileRoot: requireAbsolute(parsed["profile-root"]),
    workingCopyPath: requireAbsolute(parsed["working-copy-path"]),
    repositoryUrl: parsed["repository-url"],
    operationId: parsed["operation-id"],
    timeoutMs: OPERATION_TIMEOUT_MS,
  };
}

async function requireFilesystemContract(options) {
  for (const file of [options.backendModule, options.daemon, options.bridge]) await requireFile(file);
  const profile = await stat(options.profileRoot);
  const workingCopy = await stat(options.workingCopyPath);
  if (!profile.isDirectory() || (await readdir(options.profileRoot)).length !== 0 || !workingCopy.isDirectory()) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_DEADLINE_FILESYSTEM_INVALID");
  }
}

async function requireWorkingCopyPreserved(workingCopyPath, expected) {
  const observed = await captureWorkingCopyIntegrity(workingCopyPath);
  if (
    observed.wcDatabaseSize !== expected.wcDatabaseSize ||
    observed.wcDatabaseSha256 !== expected.wcDatabaseSha256 ||
    JSON.stringify(observed.userContent) !== JSON.stringify(expected.userContent)
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_DEADLINE_WORKING_COPY_INVALID");
  }
}

async function captureWorkingCopyIntegrity(workingCopyPath) {
  let workingCopy;
  let wcDatabase;
  try {
    workingCopy = await stat(workingCopyPath);
    wcDatabase = await stat(path.join(workingCopyPath, ".svn", "wc.db"));
  } catch {
    throw new Error("SUBVERSIONR_I6_PACKAGED_DEADLINE_WORKING_COPY_INVALID");
  }
  if (!workingCopy.isDirectory() || !wcDatabase.isFile() || wcDatabase.size < 1) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_DEADLINE_WORKING_COPY_INVALID");
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
    if (!child.isFile()) throw new Error("SUBVERSIONR_I6_PACKAGED_DEADLINE_WORKING_COPY_INVALID");
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
  if (!(await stat(file)).isFile()) throw new Error("SUBVERSIONR_I6_PACKAGED_DEADLINE_FILE_INVALID");
}

async function readTemporaryRoots(profileRoot) {
  return await readDirectoryIfPresent(path.join(profileRoot, "SubversionR", "remote-workers"));
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
  if (!path.isAbsolute(value)) throw new Error("SUBVERSIONR_I6_PACKAGED_DEADLINE_ARGUMENT_INVALID");
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
  return left?.scheme === right.scheme && left?.canonicalHost === right.canonicalHost && left?.effectivePort === right.effectivePort;
}

function isRecord(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function safeErrorCode(error) {
  if (isRecord(error) && typeof error.code === "string" && /^SUBVERSIONR_[A-Z0-9_]+$/u.test(error.code)) return error.code;
  if (error instanceof Error && /^SUBVERSIONR_[A-Z0-9_]+$/u.test(error.message)) return error.message;
  return "SUBVERSIONR_I6_PACKAGED_DEADLINE_PROBE_FAILED";
}
