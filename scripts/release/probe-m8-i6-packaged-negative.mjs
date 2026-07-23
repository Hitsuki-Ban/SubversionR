import { randomUUID } from "node:crypto";
import { mkdir, readdir, stat } from "node:fs/promises";
import { createRequire } from "node:module";
import path from "node:path";

const SCHEMA = "subversionr.release.m8-i6-packaged-native-negative.v1";
const PROTOCOL = { major: 1, minor: 35 };
const SCENARIOS = Object.freeze({
  "malicious-root": {
    code: "SUBVERSIONR_REMOTE_ORIGIN_MISMATCH",
    reason: "crossAuthorityRejected",
    settlementCode: "SUBVERSIONR_REMOTE_ORIGIN_MISMATCH",
    settlementCategory: "policy",
    settlementReason: "crossAuthorityRejected",
  },
  "sasl-only": {
    code: "SUBVERSIONR_REMOTE_AUTH_UNSUPPORTED",
    reason: "remoteCapabilityUnsupported",
    settlementCode: "SUBVERSIONR_REMOTE_AUTH_UNSUPPORTED",
    settlementCategory: "capability",
    settlementReason: "remoteCapabilityUnsupported",
  },
  "greeting-stall": {
    code: "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT",
    reason: "operationDeadlineExceeded",
    settlementCode: "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED",
    settlementCategory: "recovery",
    settlementReason: "remoteRecoveryBlocked",
  },
  "connected-stall": {
    code: "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT",
    reason: "operationDeadlineExceeded",
    settlementCode: "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED",
    settlementCategory: "recovery",
    settlementReason: "remoteRecoveryBlocked",
  },
});

let connection;

try {
  const options = parseOptions(process.argv.slice(2));
  const remoteAccessModule = path.resolve(
    path.dirname(options.backendModule),
    "..",
    "security",
    "remoteAccessProfile.js",
  );
  const endpoint = parseRepositoryUrl(options.repositoryUrl);
  await requireFilesystemContract(options);
  await requireFile(remoteAccessModule);

  const require = createRequire(import.meta.url);
  const { startBackendProcess } = require(options.backendModule);
  const { RemoteOperationEnvelopeFactory, canonicalEndpointFromRepositoryUrl } = require(remoteAccessModule);
  if (typeof startBackendProcess !== "function") {
    throw new Error("SUBVERSIONR_I6_PACKAGED_NEGATIVE_BACKEND_MODULE_INVALID");
  }
  if (
    typeof RemoteOperationEnvelopeFactory !== "function" ||
    typeof canonicalEndpointFromRepositoryUrl !== "function" ||
    !sameEndpoint(canonicalEndpointFromRepositoryUrl(options.repositoryUrl), endpoint)
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_NEGATIVE_REMOTE_PROFILE_MODULE_INVALID");
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
      clientName: "subversionr-m8-i6-packaged-negative-evidence",
      clientVersion: "1",
      locale: "en",
      workspaceTrust: "trusted",
      baseEnv: isolatedEnvironment(options.profileRoot),
    },
    {
      requestHandler: async (method) => {
        inboundMethods.push(method);
        throw new Error("SUBVERSIONR_I6_PACKAGED_NEGATIVE_CREDENTIAL_HANDLER_FORBIDDEN");
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
  const expected = SCENARIOS[options.scenario];
  let observedError;
  try {
    await connection.sendRequest("repository/checkout", {
      url: options.repositoryUrl,
      targetPath: options.checkoutTarget,
      revision: "head",
      depth: "infinity",
      ignoreExternals: true,
      remote: remoteEnvelope(envelopeFactory, endpoint, trustEpoch, options.timeoutMs),
    });
  } catch (error) {
    observedError = error;
  }
  if (observedError === undefined) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_NEGATIVE_UNEXPECTED_SUCCESS");
  }

  requireExpectedFailure(observedError, expected);
  requireRedacted(observedError, options);
  if (!connection.isRemoteSubmissionEnabled() || connection.currentRemoteTrustEpoch() !== trustEpoch) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_NEGATIVE_TRUST_EPOCH_INVALID");
  }
  if (inboundMethods.length !== 0) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_NEGATIVE_CREDENTIAL_HANDLER_INVOKED");
  }

  const remoteWorkersRoot = path.join(options.profileRoot, "SubversionR", "remote-workers");
  const temporaryRoots = await readDirectoryIfPresent(remoteWorkersRoot);
  if (temporaryRoots.length !== 0) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_NEGATIVE_WORKER_TEMP_RESIDUE");
  }

  const diagnostics = await connection.sendRequest("diagnostics/get", {});
  requireRecord(diagnostics, "diagnostics");
  if (diagnostics.source !== "subversionr-daemon") {
    throw new Error("SUBVERSIONR_I6_PACKAGED_NEGATIVE_DIAGNOSTICS_INVALID");
  }
  requireRedacted(diagnostics, options);
  if (inboundMethods.length !== 0) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_NEGATIVE_CREDENTIAL_HANDLER_INVOKED");
  }

  await connection.shutdown();
  connection = undefined;
  process.stdout.write(`${JSON.stringify({
    schema: SCHEMA,
    status: "passed",
    scenario: options.scenario,
    code: expected.code,
    reason: expected.reason,
    settlementCode: expected.settlementCode,
    settlementReason: expected.settlementReason,
    protocol: PROTOCOL,
    remoteSvnAnonymous: true,
    temporaryRootsAfter: temporaryRoots.length,
    credentialRequests: 0,
    credentialSettlements: 0,
    diagnosticsRedacted: true,
    fixtureCliInvocations: 0,
  })}\n`);
} catch (error) {
  connection?.dispose();
  process.stdout.write(`${JSON.stringify({
    schema: SCHEMA,
    status: "failed",
    error: {
      code: safeErrorCode(error),
    },
  })}\n`);
  process.exitCode = 1;
}

function remoteEnvelope(envelopeFactory, endpoint, trustEpoch, timeoutMs) {
  const envelope = envelopeFactory.createAnonymousSvn({
    operationId: randomUUID(),
    intent: "foreground",
    interaction: "forbidden",
    timeoutMs,
    profile: {
      schema: "subversionr.remote-profile.v1",
      profileId: "m8-i6-loopback-anonymous",
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
  if (envelope.trustEpoch !== trustEpoch || !sameEndpoint(envelope.expectedOrigin, endpoint)) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_NEGATIVE_ENVELOPE_INVALID");
  }
  return envelope;
}

function requireCapabilities(activeConnection) {
  const initialize = activeConnection.initializeResult;
  requireRecord(initialize, "initialize");
  if (
    initialize.protocol?.major !== PROTOCOL.major ||
    initialize.protocol?.minor !== PROTOCOL.minor ||
    initialize.capabilities?.realLibsvnBridge !== true ||
    initialize.capabilities?.repositoryCheckout !== true ||
    initialize.capabilities?.remoteOperationEnvelope !== true ||
    initialize.capabilities?.remoteWorkerIsolation !== true ||
    initialize.capabilities?.remoteSvnAnonymous !== true ||
    !Number.isSafeInteger(initialize.acknowledgedTrustEpoch) ||
    initialize.acknowledgedTrustEpoch < 1 ||
    typeof activeConnection.currentRemoteTrustEpoch !== "function" ||
    activeConnection.currentRemoteTrustEpoch() !== initialize.acknowledgedTrustEpoch ||
    activeConnection.isRemoteSubmissionEnabled() !== true
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_NEGATIVE_CAPABILITY_INVALID");
  }
  return initialize.acknowledgedTrustEpoch;
}

function sameEndpoint(left, right) {
  return left?.scheme === right.scheme &&
    left?.canonicalHost === right.canonicalHost &&
    left?.effectivePort === right.effectivePort;
}

function requireExpectedFailure(error, expected) {
  if (!isRecord(error) || error.code !== expected.settlementCode || !isRecord(error.safeArgs)) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_NEGATIVE_ERROR_CODE_INVALID");
  }
  const failure = error.safeArgs.remoteFailure;
  if (
    !isRecord(failure) ||
    Object.keys(failure).length !== 3 ||
    failure.category !== expected.settlementCategory ||
    failure.reason !== expected.settlementReason ||
    failure.cleanupAppropriate !== false
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_NEGATIVE_REMOTE_FAILURE_INVALID");
  }
  if (
    expected.settlementCode !== expected.code &&
    error.safeArgs.originFailureCode !== expected.code
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_NEGATIVE_ORIGIN_FAILURE_INVALID");
  }
}

function requireRedacted(value, options) {
  let serialized;
  try {
    serialized = JSON.stringify(value);
  } catch {
    throw new Error("SUBVERSIONR_I6_PACKAGED_NEGATIVE_DIAGNOSTICS_INVALID");
  }
  if (typeof serialized !== "string" || Buffer.byteLength(serialized, "utf8") > 32_768) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_NEGATIVE_DIAGNOSTICS_INVALID");
  }
  const sensitive = [
    options.repositoryUrl,
    options.checkoutTarget,
    options.checkoutTarget.replaceAll("\\", "/"),
    options.profileRoot,
    options.profileRoot.replaceAll("\\", "/"),
  ].map((entry) => entry.toLowerCase());
  if (containsSensitiveString(value, sensitive, new Set())) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_NEGATIVE_DIAGNOSTICS_LEAK");
  }
}

function containsSensitiveString(value, sensitive, seen) {
  if (typeof value === "string") {
    const candidate = value.toLowerCase();
    return sensitive.some((entry) => entry.length !== 0 && candidate.includes(entry));
  }
  if (!value || typeof value !== "object") {
    return false;
  }
  if (seen.has(value)) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_NEGATIVE_DIAGNOSTICS_INVALID");
  }
  seen.add(value);
  const found = Object.entries(value).some(
    ([key, entry]) => containsSensitiveString(key, sensitive, seen) || containsSensitiveString(entry, sensitive, seen),
  );
  seen.delete(value);
  return found;
}

function parseRepositoryUrl(value) {
  let url;
  try {
    url = new URL(value);
  } catch {
    throw new Error("SUBVERSIONR_I6_PACKAGED_NEGATIVE_REPOSITORY_URL_INVALID");
  }
  if (
    url.protocol !== "svn:" ||
    url.hostname !== "127.0.0.1" ||
    url.port.length === 0 ||
    url.username.length !== 0 ||
    url.password.length !== 0 ||
    url.search.length !== 0 ||
    url.hash.length !== 0 ||
    url.pathname.length <= 1
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_NEGATIVE_REPOSITORY_URL_INVALID");
  }
  const port = Number.parseInt(url.port, 10);
  if (!Number.isInteger(port) || port < 1 || port > 65_535) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_NEGATIVE_REPOSITORY_URL_INVALID");
  }
  return { scheme: "svn", canonicalHost: "127.0.0.1", effectivePort: port };
}

function parseOptions(args) {
  const names = [
    "backend-module",
    "daemon",
    "bridge",
    "profile-root",
    "checkout-target",
    "repository-url",
    "scenario",
    "timeout-ms",
  ];
  if (args.length !== names.length * 2) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_NEGATIVE_ARGUMENT_INVALID");
  }
  const parsed = {};
  for (let index = 0; index < args.length; index += 2) {
    const rawName = args[index];
    const rawValue = args[index + 1];
    if (typeof rawName !== "string" || !rawName.startsWith("--") || typeof rawValue !== "string") {
      throw new Error("SUBVERSIONR_I6_PACKAGED_NEGATIVE_ARGUMENT_INVALID");
    }
    const name = rawName.slice(2);
    if (!names.includes(name) || name in parsed) {
      throw new Error("SUBVERSIONR_I6_PACKAGED_NEGATIVE_ARGUMENT_INVALID");
    }
    parsed[name] = rawValue;
  }
  if (names.some((name) => !(name in parsed)) || !(parsed.scenario in SCENARIOS)) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_NEGATIVE_ARGUMENT_INVALID");
  }
  const timeoutMs = Number.parseInt(parsed["timeout-ms"], 10);
  if (
    !Number.isSafeInteger(timeoutMs) ||
    timeoutMs < 1 ||
    timeoutMs > 300_000 ||
    `${timeoutMs}` !== parsed["timeout-ms"]
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_NEGATIVE_ARGUMENT_INVALID");
  }
  return {
    backendModule: requireAbsolute(parsed["backend-module"]),
    daemon: requireAbsolute(parsed.daemon),
    bridge: requireAbsolute(parsed.bridge),
    profileRoot: requireAbsolute(parsed["profile-root"]),
    checkoutTarget: requireAbsolute(parsed["checkout-target"]),
    repositoryUrl: parsed["repository-url"],
    scenario: parsed.scenario,
    timeoutMs,
  };
}

async function requireFilesystemContract(options) {
  for (const file of [options.backendModule, options.daemon, options.bridge]) {
    const metadata = await stat(file);
    if (!metadata.isFile()) {
      throw new Error("SUBVERSIONR_I6_PACKAGED_NEGATIVE_FILE_INVALID");
    }
  }
  const profile = await stat(options.profileRoot);
  if (!profile.isDirectory() || (await readdir(options.profileRoot)).length !== 0) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_NEGATIVE_PROFILE_ROOT_INVALID");
  }
  const checkoutParent = await stat(path.dirname(options.checkoutTarget));
  if (!checkoutParent.isDirectory()) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_NEGATIVE_CHECKOUT_TARGET_INVALID");
  }
  try {
    await stat(options.checkoutTarget);
  } catch (error) {
    if (isRecord(error) && error.code === "ENOENT") {
      return;
    }
    throw error;
  }
  throw new Error("SUBVERSIONR_I6_PACKAGED_NEGATIVE_CHECKOUT_TARGET_INVALID");
}

async function requireFile(file) {
  const metadata = await stat(file);
  if (!metadata.isFile()) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_NEGATIVE_FILE_INVALID");
  }
}

async function readDirectoryIfPresent(directory) {
  try {
    return await readdir(directory);
  } catch (error) {
    if (isRecord(error) && error.code === "ENOENT") {
      return [];
    }
    throw error;
  }
}

function requireAbsolute(value) {
  if (!path.isAbsolute(value)) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_NEGATIVE_ARGUMENT_INVALID");
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

function requireRecord(value, field) {
  if (!isRecord(value)) {
    throw new Error(`SUBVERSIONR_I6_PACKAGED_NEGATIVE_${field.toUpperCase()}_INVALID`);
  }
  return value;
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
  return "SUBVERSIONR_I6_PACKAGED_NEGATIVE_PROBE_FAILED";
}
