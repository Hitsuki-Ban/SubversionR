import { randomUUID } from "node:crypto";
import { mkdir, readdir, stat } from "node:fs/promises";
import { createRequire } from "node:module";
import path from "node:path";

const SCHEMA = "subversionr.release.m8-i6-packaged-native-authz-denied.v1";
const PROTOCOL = { major: 1, minor: 35 };
let connection;
let opened;

try {
  const options = parseOptions(process.argv.slice(2));
  const endpoint = parseRepositoryUrl(options.repositoryUrl);
  await requireFilesystemContract(options);
  const remoteAccessModule = path.resolve(path.dirname(options.backendModule), "..", "security", "remoteAccessProfile.js");
  await requireFile(remoteAccessModule);

  const require = createRequire(import.meta.url);
  const { startBackendProcess } = require(options.backendModule);
  const { RemoteOperationEnvelopeFactory, canonicalEndpointFromRepositoryUrl } = require(remoteAccessModule);
  if (typeof startBackendProcess !== "function" || typeof RemoteOperationEnvelopeFactory !== "function") {
    throw new Error("SUBVERSIONR_I6_PACKAGED_AUTHZ_MODULE_INVALID");
  }
  if (!sameEndpoint(canonicalEndpointFromRepositoryUrl(options.repositoryUrl), endpoint)) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_AUTHZ_ORIGIN_INVALID");
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
      clientName: "subversionr-m8-i6-packaged-authz-denied-evidence",
      clientVersion: "1",
      locale: "en",
      workspaceTrust: "trusted",
      baseEnv: isolatedEnvironment(options.profileRoot),
    },
    {
      requestHandler: async (method) => {
        inboundMethods.push(method);
        throw new Error("SUBVERSIONR_I6_PACKAGED_AUTHZ_CREDENTIAL_HANDLER_FORBIDDEN");
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
    operationId: randomUUID(),
    intent: "foreground",
    interaction: "allowed",
    timeoutMs: options.timeoutMs,
    profile: anonymousProfile(endpoint),
    expectedOrigin: endpoint,
  });
  if (remote.trustEpoch !== trustEpoch || !sameEndpoint(remote.expectedOrigin, endpoint)) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_AUTHZ_ENVELOPE_INVALID");
  }

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
  requireExpectedFailure(observedError, options.workingCopyPath);
  requireStableTrust(connection, trustEpoch);
  if (inboundMethods.length !== 0) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_AUTHZ_CREDENTIAL_HANDLER_INVOKED");
  }

  const diagnostics = await connection.sendRequest("diagnostics/get", {});
  requireDiagnosticsRedacted(diagnostics, options);
  requireStableTrust(connection, trustEpoch);
  if (inboundMethods.length !== 0) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_AUTHZ_CREDENTIAL_HANDLER_INVOKED");
  }

  const closed = await connection.sendRequest("repository/close", {
    repositoryId: opened.repositoryId,
    epoch: opened.epoch,
  });
  requireCloseResponse(closed, opened);
  opened = undefined;
  const temporaryRoots = await readDirectoryIfPresent(path.join(options.profileRoot, "SubversionR", "remote-workers"));
  if (temporaryRoots.length !== 0) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_AUTHZ_WORKER_TEMP_RESIDUE");
  }
  await connection.shutdown();
  connection = undefined;

  process.stdout.write(`${JSON.stringify({
    schema: SCHEMA,
    status: "passed",
    cell: "authzDenied",
    stableCode: "SVN_REMOTE_STATUS_AUTH_FAILED",
    reason: "authorizationDenied",
    protocol: PROTOCOL,
    remoteSvnAnonymous: true,
    temporaryRootsAfter: temporaryRoots.length,
    credentialRequests: 0,
    credentialSettlements: 0,
    diagnosticsRedacted: true,
  })}\n`);
} catch (error) {
  if (opened && connection) {
    try {
      await connection.sendRequest("repository/close", {
        repositoryId: opened.repositoryId,
        epoch: opened.epoch,
      });
    } catch {
      // The primary fail-closed result is reported below.
    }
  }
  connection?.dispose();
  process.stdout.write(`${JSON.stringify({
    schema: SCHEMA,
    status: "failed",
    error: { code: safeErrorCode(error) },
  })}\n`);
  process.exitCode = 1;
}

function requireExpectedFailure(error, workingCopyPath) {
  if (
    !isRecord(error) ||
    error.code !== "SVN_REMOTE_STATUS_AUTH_FAILED" ||
    error.category !== "auth" ||
    error.messageKey !== "error.native.remoteStatusAuthFailed" ||
    error.retryable !== false ||
    !isRecord(error.safeArgs) ||
    Object.keys(error.safeArgs).sort().join(",") !== "path,remoteFailure,status" ||
    path.resolve(error.safeArgs.path) !== path.resolve(workingCopyPath) ||
    error.safeArgs.status !== 12
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_AUTHZ_ERROR_INVALID");
  }
  const failure = error.safeArgs.remoteFailure;
  if (
    !isRecord(failure) ||
    Object.keys(failure).sort().join(",") !== "category,cleanupAppropriate,reason" ||
    failure.category !== "authorization" ||
    failure.reason !== "authorizationDenied" ||
    failure.cleanupAppropriate !== false
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_AUTHZ_FAILURE_INVALID");
  }
  if (
    !isRecord(error.diagnostics) ||
    error.diagnostics.cause !== "authorizationDenied" ||
    !isRecord(error.diagnostics.svn) ||
    !Array.isArray(error.diagnostics.svn.entries) ||
    error.diagnostics.svn.entries.length < 1 ||
    error.diagnostics.svn.entries.length > 8 ||
    error.diagnostics.svn.entries.some((entry) => !isRecord(entry) || !Number.isInteger(entry.code) || !/^SVN_ERR_[A-Z0-9_]+$/u.test(entry.name))
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_AUTHZ_DIAGNOSTICS_INVALID");
  }
}

function requireDiagnosticsRedacted(value, options) {
  if (!isRecord(value) || value.source !== "subversionr-daemon") {
    throw new Error("SUBVERSIONR_I6_PACKAGED_AUTHZ_DIAGNOSTICS_INVALID");
  }
  let serialized;
  try {
    serialized = JSON.stringify(value);
  } catch {
    throw new Error("SUBVERSIONR_I6_PACKAGED_AUTHZ_DIAGNOSTICS_INVALID");
  }
  if (typeof serialized !== "string" || Buffer.byteLength(serialized, "utf8") > 32_768) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_AUTHZ_DIAGNOSTICS_INVALID");
  }
  const lowered = serialized.toLowerCase();
  for (const sensitive of [options.repositoryUrl, options.workingCopyPath, options.profileRoot]) {
    if (lowered.includes(sensitive.toLowerCase()) || lowered.includes(sensitive.replaceAll("\\", "/").toLowerCase())) {
      throw new Error("SUBVERSIONR_I6_PACKAGED_AUTHZ_DIAGNOSTICS_LEAK");
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
    initialize.capabilities?.remoteOperationEnvelope !== true ||
    initialize.capabilities?.remoteWorkerIsolation !== true ||
    initialize.capabilities?.remoteSvnAnonymous !== true ||
    !Number.isSafeInteger(initialize.acknowledgedTrustEpoch) ||
    initialize.acknowledgedTrustEpoch < 1 ||
    activeConnection.isRemoteSubmissionEnabled() !== true ||
    activeConnection.currentRemoteTrustEpoch() !== initialize.acknowledgedTrustEpoch
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_AUTHZ_CAPABILITY_INVALID");
  }
  return initialize.acknowledgedTrustEpoch;
}

function requireStableTrust(activeConnection, trustEpoch) {
  if (!activeConnection.isRemoteSubmissionEnabled() || activeConnection.currentRemoteTrustEpoch() !== trustEpoch) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_AUTHZ_TRUST_INVALID");
  }
}

function requireOpenResponse(value, workingCopyPath, endpoint) {
  if (
    !isRecord(value) ||
    typeof value.repositoryId !== "string" ||
    !Number.isSafeInteger(value.epoch) ||
    value.epoch < 1 ||
    !isRecord(value.identity) ||
    path.resolve(value.identity.workingCopyRoot) !== path.resolve(workingCopyPath) ||
    typeof value.identity.repositoryRootUrl !== "string"
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_AUTHZ_OPEN_INVALID");
  }
  let repositoryRoot;
  try {
    repositoryRoot = new URL(value.identity.repositoryRootUrl);
  } catch {
    throw new Error("SUBVERSIONR_I6_PACKAGED_AUTHZ_OPEN_INVALID");
  }
  if (
    repositoryRoot.protocol !== "svn:" ||
    repositoryRoot.hostname !== endpoint.canonicalHost ||
    Number.parseInt(repositoryRoot.port || "3690", 10) !== endpoint.effectivePort
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_AUTHZ_OPEN_INVALID");
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
    throw new Error("SUBVERSIONR_I6_PACKAGED_AUTHZ_CLOSE_INVALID");
  }
}

function anonymousProfile(endpoint) {
  return {
    schema: "subversionr.remote-profile.v1",
    profileId: "m8-i6-loopback-anonymous-authz-denied",
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
    throw new Error("SUBVERSIONR_I6_PACKAGED_AUTHZ_URL_INVALID");
  }
  if (
    url.protocol !== "svn:" || url.hostname !== "127.0.0.1" || url.port.length === 0 ||
    url.username.length !== 0 || url.password.length !== 0 || url.search.length !== 0 ||
    url.hash.length !== 0 || !url.pathname.endsWith("/denied")
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_AUTHZ_URL_INVALID");
  }
  const port = Number.parseInt(url.port, 10);
  if (!Number.isInteger(port) || port < 1 || port > 65_535) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_AUTHZ_URL_INVALID");
  }
  return { scheme: "svn", canonicalHost: "127.0.0.1", effectivePort: port };
}

function parseOptions(args) {
  const names = ["backend-module", "daemon", "bridge", "profile-root", "working-copy-path", "repository-url", "timeout-ms"];
  if (args.length !== names.length * 2) throw new Error("SUBVERSIONR_I6_PACKAGED_AUTHZ_ARGUMENT_INVALID");
  const parsed = {};
  for (let index = 0; index < args.length; index += 2) {
    const rawName = args[index];
    const rawValue = args[index + 1];
    if (typeof rawName !== "string" || !rawName.startsWith("--") || typeof rawValue !== "string") {
      throw new Error("SUBVERSIONR_I6_PACKAGED_AUTHZ_ARGUMENT_INVALID");
    }
    const name = rawName.slice(2);
    if (!names.includes(name) || name in parsed) throw new Error("SUBVERSIONR_I6_PACKAGED_AUTHZ_ARGUMENT_INVALID");
    parsed[name] = rawValue;
  }
  if (names.some((name) => !(name in parsed))) throw new Error("SUBVERSIONR_I6_PACKAGED_AUTHZ_ARGUMENT_INVALID");
  const timeoutMs = Number.parseInt(parsed["timeout-ms"], 10);
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 300_000 || `${timeoutMs}` !== parsed["timeout-ms"]) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_AUTHZ_ARGUMENT_INVALID");
  }
  return {
    backendModule: requireAbsolute(parsed["backend-module"]), daemon: requireAbsolute(parsed.daemon),
    bridge: requireAbsolute(parsed.bridge), profileRoot: requireAbsolute(parsed["profile-root"]),
    workingCopyPath: requireAbsolute(parsed["working-copy-path"]), repositoryUrl: parsed["repository-url"], timeoutMs,
  };
}

async function requireFilesystemContract(options) {
  for (const file of [options.backendModule, options.daemon, options.bridge]) await requireFile(file);
  const profile = await stat(options.profileRoot);
  const workingCopy = await stat(options.workingCopyPath);
  if (!profile.isDirectory() || (await readdir(options.profileRoot)).length !== 0 || !workingCopy.isDirectory()) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_AUTHZ_FILESYSTEM_INVALID");
  }
}

async function requireFile(file) {
  if (!(await stat(file)).isFile()) throw new Error("SUBVERSIONR_I6_PACKAGED_AUTHZ_FILE_INVALID");
}

async function readDirectoryIfPresent(directory) {
  try { return await readdir(directory); }
  catch (error) { if (isRecord(error) && error.code === "ENOENT") return []; throw error; }
}

function requireAbsolute(value) {
  if (!path.isAbsolute(value)) throw new Error("SUBVERSIONR_I6_PACKAGED_AUTHZ_ARGUMENT_INVALID");
  return path.resolve(value);
}

function isolatedEnvironment(profileRoot) {
  return { ...process.env, APPDATA: profileRoot, LOCALAPPDATA: profileRoot, USERPROFILE: profileRoot, HOME: profileRoot, TEMP: profileRoot, TMP: profileRoot };
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
  return "SUBVERSIONR_I6_PACKAGED_AUTHZ_PROBE_FAILED";
}
