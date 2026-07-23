import { Buffer } from "node:buffer";
import { createHash } from "node:crypto";
import { lstat, mkdir, readFile, readdir } from "node:fs/promises";
import { createRequire } from "node:module";
import path from "node:path";

const SCHEMA = "subversionr.release.m8-i6-packaged-redaction.v1";
const PROTOCOL = Object.freeze({ major: 1, minor: 35 });
const MAX_DIAGNOSTIC_BYTES = 32_768;
const MAX_SVN_REVISION = 2_147_483_647;
const REQUIRED_ARGUMENTS = Object.freeze([
  "daemon-path",
  "bridge-path",
  "profile-root",
  "repository-url",
  "checkout-target",
  "diagnostic-token",
  "expected-product-version",
  "expected-revision",
]);

class ProbeFailure extends Error {
  constructor(code) {
    super(code);
    this.code = code;
  }
}

let connection;

try {
  const options = parseOptions(process.argv.slice(2));
  const endpoint = parseRepositoryUrl(options.repositoryUrl);
  const candidate = await requireCandidate(options);
  await requireNewIsolatedPaths(options, candidate.packageRoot);

  const require = createRequire(import.meta.url);
  const { startBackendProcess } = require(candidate.backendModule);
  const { redactDiagnosticValue } = require(candidate.redactionModule);
  const { OperationDiagnostics } = require(candidate.operationDiagnosticsModule);
  if (
    typeof startBackendProcess !== "function" ||
    typeof redactDiagnosticValue !== "function" ||
    typeof OperationDiagnostics !== "function"
  ) {
    fail("SUBVERSIONR_I6_PACKAGED_REDACTION_CANDIDATE_INVALID");
  }

  await mkdir(path.join(options.profileRoot, "remote-state"), { recursive: true });
  const inboundMethods = [];
  connection = await startBackendProcess(
    {
      executablePath: options.daemonPath,
      bridgeDllPath: options.bridgePath,
      cacheRoot: path.join(options.profileRoot, "cache"),
      remoteStateRoot: path.join(options.profileRoot, "remote-state"),
      clientName: "subversionr-m8-i6-packaged-redaction",
      clientVersion: options.expectedProductVersion,
      locale: "en",
      workspaceTrust: "trusted",
      baseEnv: isolatedEnvironment(options.profileRoot),
    },
    {
      requestHandler: async (method) => {
        inboundMethods.push(method);
        fail("SUBVERSIONR_I6_PACKAGED_REDACTION_AUTH_ACTIVITY_INVALID");
      },
      notificationHandler: () => undefined,
    },
  );

  requireCapabilities(connection, options.expectedProductVersion);
  const trustEpoch = connection.initializeResult.acknowledgedTrustEpoch;
  const checkoutRequest = {
    url: options.repositoryUrl,
    targetPath: options.checkoutTarget,
    revision: options.expectedRevision,
    depth: "infinity",
    ignoreExternals: true,
    remote: {
      version: 1,
      operationId: options.diagnosticToken,
      intent: "foreground",
      interaction: "forbidden",
      timeoutMs: 300_000,
      workspaceTrust: "trusted",
      trustEpoch,
      profile: {
        schema: "subversionr.remote-profile.v1",
        profileId: "m8-i6-packaged-redaction",
        authority: endpoint,
        serverAuth: "anonymous",
        serverAccount: "none",
        serverCredentialPersistence: "secretStorage",
        proxy: "none",
        ssh: "none",
        redirectPolicy: "rejectAll",
      },
      expectedOrigin: endpoint,
    },
  };
  const checkout = await connection.sendRequest("repository/checkout", checkoutRequest);
  requireCheckout(checkout, options.checkoutTarget, options.expectedRevision);
  await requireDirectory(options.checkoutTarget);
  if (inboundMethods.length !== 0 || connection.currentRemoteTrustEpoch() !== trustEpoch) {
    fail("SUBVERSIONR_I6_PACKAGED_REDACTION_AUTH_ACTIVITY_INVALID");
  }

  const daemonDiagnostics = await connection.sendRequest("diagnostics/get", {});
  requireRecord(daemonDiagnostics, "SUBVERSIONR_I6_PACKAGED_REDACTION_DIAGNOSTICS_INVALID");
  if (daemonDiagnostics.source !== "subversionr-daemon" || inboundMethods.length !== 0) {
    fail("SUBVERSIONR_I6_PACKAGED_REDACTION_DIAGNOSTICS_INVALID");
  }

  const diagnosticInput = {
    code: "SUBVERSIONR_I6_PACKAGED_REDACTION_OBSERVATION",
    category: "diagnostics",
    messageKey: "error.release.packagedRedactionObservation",
    safeArgs: {
      repositoryUrl: checkoutRequest.url,
      targetPath: checkoutRequest.targetPath,
      diagnosticToken: checkoutRequest.remote.operationId,
    },
    retryable: false,
    diagnostics: daemonDiagnostics,
  };
  requireRawDiagnosticInputs(diagnosticInput, options);

  const directlyRedacted = redactDiagnosticValue(diagnosticInput);
  const directlyRedactedSerialized = serializeDiagnosticValue(directlyRedacted);
  const directRedaction = requireRedactedEvidence(directlyRedactedSerialized, options);

  const channelLines = [];
  const diagnostics = new OperationDiagnostics({
    clear: () => channelLines.splice(0, channelLines.length),
    error: (line) => channelLines.push(line),
    show: () => undefined,
  });
  if (typeof diagnostics.recordFailure !== "function" || typeof diagnostics.snapshot !== "function") {
    fail("SUBVERSIONR_I6_PACKAGED_REDACTION_CANDIDATE_INVALID");
  }
  diagnostics.recordFailure("repository/checkout", diagnosticInput);
  requireRawDiagnosticInputs(diagnosticInput, options);
  const snapshot = diagnostics.snapshot();
  if (
    !Array.isArray(snapshot) ||
    snapshot.length !== 1 ||
    snapshot.some((line) => typeof line !== "string") ||
    channelLines.length !== snapshot.length ||
    snapshot.some((line, index) => line !== channelLines[index])
  ) {
    fail("SUBVERSIONR_I6_PACKAGED_REDACTION_DIAGNOSTICS_INVALID");
  }

  const operationRedactions = snapshot.map((line) => requireRedactedEvidence(line, options));
  const redaction = aggregateRedactionEvidence([directRedaction, ...operationRedactions]);
  const serializedValues = [directlyRedactedSerialized, ...snapshot];
  const diagnosticBytes = serializedValues.map((value) => Buffer.byteLength(value, "utf8"));
  const maxDiagnosticBytes = Math.max(...diagnosticBytes);
  if (diagnosticBytes.some((bytes) => bytes > MAX_DIAGNOSTIC_BYTES)) {
    fail("SUBVERSIONR_I6_PACKAGED_REDACTION_DIAGNOSTICS_OVERSIZED");
  }

  await connection.shutdown();
  connection = undefined;
  const temporaryRootsAfter = await readDirectoryIfPresent(
    path.join(options.profileRoot, "SubversionR", "remote-workers"),
  );
  if (temporaryRootsAfter.length !== 0) {
    fail("SUBVERSIONR_I6_PACKAGED_REDACTION_WORKER_TEMP_RESIDUE");
  }

  process.stdout.write(`${JSON.stringify({
    schema: SCHEMA,
    status: "passed",
    cell: "redaction",
    surface: "packaged-native",
    protocol: PROTOCOL,
    remoteSvnAnonymous: true,
    checkoutRevision: checkout.revision,
    targetPathSha256: sha256(options.checkoutTarget),
    inputContainedRawUrl: true,
    inputContainedRawPath: true,
    inputContainedRawToken: true,
    rawUrlCount: redaction.rawUrlCount,
    rawPathCount: redaction.rawPathCount,
    secretTokenCount: redaction.secretTokenCount,
    urlMarkerCount: redaction.urlMarkerCount,
    pathMarkerCount: redaction.pathMarkerCount,
    secretMarkerCount: redaction.secretMarkerCount,
    maxDiagnosticBytes,
    boundedDiagnostics: true,
    credentialRequests: 0,
    credentialSettlements: 0,
    certificateRequests: 0,
    temporaryRootsAfter: 0,
    diagnosticsRedacted: true,
  })}\n`);
} catch (error) {
  connection?.dispose();
  process.stdout.write(`${JSON.stringify({
    schema: SCHEMA,
    status: "failed",
    code: safeErrorCode(error),
  })}\n`);
  process.exitCode = 1;
}

function parseOptions(args) {
  if (args.length !== REQUIRED_ARGUMENTS.length * 2) {
    fail("SUBVERSIONR_I6_PACKAGED_REDACTION_ARGUMENT_INVALID");
  }
  const parsed = Object.create(null);
  for (let index = 0; index < args.length; index += 2) {
    const rawName = args[index];
    const rawValue = args[index + 1];
    if (
      typeof rawName !== "string" ||
      !rawName.startsWith("--") ||
      typeof rawValue !== "string" ||
      rawValue.length === 0
    ) {
      fail("SUBVERSIONR_I6_PACKAGED_REDACTION_ARGUMENT_INVALID");
    }
    const name = rawName.slice(2);
    if (!REQUIRED_ARGUMENTS.includes(name) || Object.hasOwn(parsed, name)) {
      fail("SUBVERSIONR_I6_PACKAGED_REDACTION_ARGUMENT_INVALID");
    }
    parsed[name] = rawValue;
  }
  if (REQUIRED_ARGUMENTS.some((name) => !Object.hasOwn(parsed, name))) {
    fail("SUBVERSIONR_I6_PACKAGED_REDACTION_ARGUMENT_INVALID");
  }
  if (!/^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$/u.test(parsed["expected-product-version"])) {
    fail("SUBVERSIONR_I6_PACKAGED_REDACTION_ARGUMENT_INVALID");
  }
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u.test(parsed["diagnostic-token"])) {
    fail("SUBVERSIONR_I6_PACKAGED_REDACTION_ARGUMENT_INVALID");
  }
  if (!/^[1-9][0-9]*$/u.test(parsed["expected-revision"])) {
    fail("SUBVERSIONR_I6_PACKAGED_REDACTION_ARGUMENT_INVALID");
  }
  const expectedRevision = Number.parseInt(parsed["expected-revision"], 10);
  if (!Number.isSafeInteger(expectedRevision) || expectedRevision > MAX_SVN_REVISION) {
    fail("SUBVERSIONR_I6_PACKAGED_REDACTION_ARGUMENT_INVALID");
  }
  return {
    daemonPath: requireCanonicalAbsolute(parsed["daemon-path"]),
    bridgePath: requireCanonicalAbsolute(parsed["bridge-path"]),
    profileRoot: requireCanonicalAbsolute(parsed["profile-root"]),
    repositoryUrl: parsed["repository-url"],
    checkoutTarget: requireCanonicalAbsolute(parsed["checkout-target"]),
    diagnosticToken: parsed["diagnostic-token"],
    expectedProductVersion: parsed["expected-product-version"],
    expectedRevision,
  };
}

function requireCanonicalAbsolute(value) {
  if (!path.isAbsolute(value) || path.resolve(value) !== value) {
    fail("SUBVERSIONR_I6_PACKAGED_REDACTION_ARGUMENT_INVALID");
  }
  return value;
}

function parseRepositoryUrl(value) {
  let url;
  try {
    url = new URL(value);
  } catch {
    fail("SUBVERSIONR_I6_PACKAGED_REDACTION_ORIGIN_INVALID");
  }
  if (
    url.protocol !== "svn:" ||
    url.hostname !== "127.0.0.1" ||
    url.port.length === 0 ||
    url.username.length !== 0 ||
    url.password.length !== 0 ||
    url.pathname !== "/repo/trunk" ||
    url.search.length !== 0 ||
    url.hash.length !== 0
  ) {
    fail("SUBVERSIONR_I6_PACKAGED_REDACTION_ORIGIN_INVALID");
  }
  const port = Number.parseInt(url.port, 10);
  if (!Number.isInteger(port) || port < 1 || port > 65_535 || value !== `svn://127.0.0.1:${port}/repo/trunk`) {
    fail("SUBVERSIONR_I6_PACKAGED_REDACTION_ORIGIN_INVALID");
  }
  return { scheme: "svn", canonicalHost: "127.0.0.1", effectivePort: port };
}

async function requireCandidate(options) {
  if (
    path.basename(options.daemonPath) !== "subversionr-daemon.exe" ||
    path.basename(options.bridgePath) !== "subversionr_svn_bridge.dll" ||
    path.dirname(options.daemonPath) !== path.dirname(options.bridgePath)
  ) {
    fail("SUBVERSIONR_I6_PACKAGED_REDACTION_CANDIDATE_INVALID");
  }
  const nativeRoot = path.dirname(options.daemonPath);
  if (path.basename(path.dirname(nativeRoot)) !== "backend" || path.basename(path.dirname(path.dirname(nativeRoot))) !== "resources") {
    fail("SUBVERSIONR_I6_PACKAGED_REDACTION_CANDIDATE_INVALID");
  }
  const packageRoot = path.resolve(nativeRoot, "..", "..", "..");
  const packageJsonPath = path.join(packageRoot, "package.json");
  const backendModule = path.join(packageRoot, "dist", "backend", "backendProcess.js");
  const redactionModule = path.join(packageRoot, "dist", "diagnostics", "diagnosticsRedaction.js");
  const operationDiagnosticsModule = path.join(packageRoot, "dist", "diagnostics", "operationDiagnostics.js");
  await Promise.all([
    requireFile(options.daemonPath),
    requireFile(options.bridgePath),
    requireFile(packageJsonPath),
    requireFile(backendModule),
    requireFile(redactionModule),
    requireFile(operationDiagnosticsModule),
  ]);
  let packageJson;
  try {
    packageJson = JSON.parse(await readFile(packageJsonPath, "utf8"));
  } catch {
    fail("SUBVERSIONR_I6_PACKAGED_REDACTION_CANDIDATE_INVALID");
  }
  if (
    !isRecord(packageJson) ||
    packageJson.name !== "subversionr" ||
    packageJson.publisher !== "hitsuki-ban" ||
    packageJson.main !== "./dist/extension.js" ||
    packageJson.version !== options.expectedProductVersion
  ) {
    fail("SUBVERSIONR_I6_PACKAGED_REDACTION_CANDIDATE_INVALID");
  }
  return { packageRoot, backendModule, redactionModule, operationDiagnosticsModule };
}

async function requireFile(filePath) {
  try {
    const metadata = await lstat(filePath);
    if (!metadata.isFile()) {
      fail("SUBVERSIONR_I6_PACKAGED_REDACTION_CANDIDATE_INVALID");
    }
  } catch (error) {
    if (error instanceof ProbeFailure) {
      throw error;
    }
    fail("SUBVERSIONR_I6_PACKAGED_REDACTION_CANDIDATE_INVALID");
  }
}

async function requireDirectory(directoryPath) {
  try {
    const metadata = await lstat(directoryPath);
    if (!metadata.isDirectory()) {
      fail("SUBVERSIONR_I6_PACKAGED_REDACTION_CHECKOUT_INVALID");
    }
  } catch (error) {
    if (error instanceof ProbeFailure) {
      throw error;
    }
    fail("SUBVERSIONR_I6_PACKAGED_REDACTION_CHECKOUT_INVALID");
  }
}

async function requireNewIsolatedPaths(options, packageRoot) {
  if (
    pathsEqual(options.daemonPath, options.bridgePath) ||
    pathsOverlap(options.profileRoot, options.checkoutTarget) ||
    pathsOverlap(options.profileRoot, packageRoot) ||
    pathsOverlap(options.checkoutTarget, packageRoot)
  ) {
    fail("SUBVERSIONR_I6_PACKAGED_REDACTION_PATH_REUSED");
  }
  for (const directory of [options.profileRoot, options.checkoutTarget]) {
    try {
      await lstat(directory);
      fail("SUBVERSIONR_I6_PACKAGED_REDACTION_PATH_REUSED");
    } catch (error) {
      if (error instanceof ProbeFailure) {
        throw error;
      }
      if (!error || typeof error !== "object" || error.code !== "ENOENT") {
        fail("SUBVERSIONR_I6_PACKAGED_REDACTION_PATH_INVALID");
      }
    }
  }
}

function requireCapabilities(activeConnection, expectedProductVersion) {
  const initialize = requireRecord(
    activeConnection?.initializeResult,
    "SUBVERSIONR_I6_PACKAGED_REDACTION_CAPABILITY_INVALID",
  );
  if (
    initialize.protocol?.major !== PROTOCOL.major ||
    initialize.protocol?.minor !== PROTOCOL.minor ||
    initialize.backendVersion !== expectedProductVersion ||
    initialize.capabilities?.realLibsvnBridge !== true ||
    initialize.capabilities?.repositoryCheckout !== true ||
    initialize.capabilities?.diagnosticsGet !== true ||
    initialize.capabilities?.remoteOperationEnvelope !== true ||
    initialize.capabilities?.remoteWorkerIsolation !== true ||
    initialize.capabilities?.remoteSvnAnonymous !== true ||
    !Number.isSafeInteger(initialize.acknowledgedTrustEpoch) ||
    initialize.acknowledgedTrustEpoch < 1 ||
    typeof activeConnection.isRemoteSubmissionEnabled !== "function" ||
    activeConnection.isRemoteSubmissionEnabled() !== true ||
    typeof activeConnection.currentRemoteTrustEpoch !== "function" ||
    activeConnection.currentRemoteTrustEpoch() !== initialize.acknowledgedTrustEpoch
  ) {
    fail("SUBVERSIONR_I6_PACKAGED_REDACTION_CAPABILITY_INVALID");
  }
}

function requireCheckout(value, checkoutTarget, expectedRevision) {
  requireRecord(value, "SUBVERSIONR_I6_PACKAGED_REDACTION_CHECKOUT_INVALID");
  if (
    !hasExactKeys(value, ["revision", "workingCopyPath"]) ||
    typeof value.workingCopyPath !== "string" ||
    !path.isAbsolute(value.workingCopyPath) ||
    normalizeAbsolutePath(value.workingCopyPath) !== normalizeAbsolutePath(checkoutTarget) ||
    !Number.isSafeInteger(value.revision) ||
    value.revision !== expectedRevision
  ) {
    fail("SUBVERSIONR_I6_PACKAGED_REDACTION_CHECKOUT_INVALID");
  }
}

function serializeDiagnosticValue(value) {
  let serialized;
  try {
    serialized = JSON.stringify(value);
  } catch {
    fail("SUBVERSIONR_I6_PACKAGED_REDACTION_DIAGNOSTICS_INVALID");
  }
  if (typeof serialized !== "string") {
    fail("SUBVERSIONR_I6_PACKAGED_REDACTION_DIAGNOSTICS_INVALID");
  }
  return serialized;
}

function normalizeAbsolutePath(value) {
  return path.resolve(value).replace(/[\\/]+$/u, "").toLowerCase();
}

function requireRawDiagnosticInputs(value, options) {
  if (
    value.safeArgs?.repositoryUrl !== options.repositoryUrl ||
    value.safeArgs?.targetPath !== options.checkoutTarget ||
    value.safeArgs?.diagnosticToken !== options.diagnosticToken
  ) {
    fail("SUBVERSIONR_I6_PACKAGED_REDACTION_INPUT_INVALID");
  }
}

function requireRedactedEvidence(serialized, options) {
  const rawUrlCount = countSerializedOccurrences(serialized, options.repositoryUrl);
  const rawPathCount = pathVariants(options.checkoutTarget)
    .map((variant) => countSerializedOccurrences(serialized, variant))
    .reduce((sum, count) => sum + count, 0);
  const secretTokenCount = countSerializedOccurrences(serialized, options.diagnosticToken);
  if (rawUrlCount !== 0 || rawPathCount !== 0 || secretTokenCount !== 0) {
    fail("SUBVERSIONR_I6_PACKAGED_REDACTION_OUTPUT_LEAK");
  }
  const urlMarkers = serialized.match(/\[REDACTED:url:[0-9a-f]{8}\]/gu) ?? [];
  const pathMarkers = serialized.match(/\[REDACTED:path:[0-9a-f]{8}\]/gu) ?? [];
  const secretMarkers = serialized.match(/\[REDACTED:secret\]/gu) ?? [];
  if (
    !urlMarkers.includes(`[REDACTED:url:${fnv1a(options.repositoryUrl)}]`) ||
    !pathMarkers.includes(`[REDACTED:path:${fnv1a(options.checkoutTarget)}]`) ||
    secretMarkers.length < 1
  ) {
    fail("SUBVERSIONR_I6_PACKAGED_REDACTION_MARKERS_INVALID");
  }
  return {
    rawUrlCount,
    rawPathCount,
    secretTokenCount,
    urlMarkerCount: urlMarkers.length,
    pathMarkerCount: pathMarkers.length,
    secretMarkerCount: secretMarkers.length,
  };
}

function aggregateRedactionEvidence(values) {
  return values.reduce((aggregate, value) => ({
    rawUrlCount: aggregate.rawUrlCount + value.rawUrlCount,
    rawPathCount: aggregate.rawPathCount + value.rawPathCount,
    secretTokenCount: aggregate.secretTokenCount + value.secretTokenCount,
    urlMarkerCount: aggregate.urlMarkerCount + value.urlMarkerCount,
    pathMarkerCount: aggregate.pathMarkerCount + value.pathMarkerCount,
    secretMarkerCount: aggregate.secretMarkerCount + value.secretMarkerCount,
  }), {
    rawUrlCount: 0,
    rawPathCount: 0,
    secretTokenCount: 0,
    urlMarkerCount: 0,
    pathMarkerCount: 0,
    secretMarkerCount: 0,
  });
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

async function readDirectoryIfPresent(directory) {
  try {
    return await readdir(directory);
  } catch (error) {
    if (error && typeof error === "object" && error.code === "ENOENT") {
      return [];
    }
    throw error;
  }
}

function hasExactKeys(value, keys) {
  return Object.keys(value).sort().join("\u0000") === [...keys].sort().join("\u0000");
}

function pathsEqual(left, right) {
  return normalizedPath(left) === normalizedPath(right);
}

function pathsOverlap(left, right) {
  const normalizedLeft = normalizedPath(left);
  const normalizedRight = normalizedPath(right);
  return (
    normalizedLeft === normalizedRight ||
    normalizedLeft.startsWith(`${normalizedRight}${path.sep}`) ||
    normalizedRight.startsWith(`${normalizedLeft}${path.sep}`)
  );
}

function normalizedPath(value) {
  const resolved = path.resolve(value);
  return process.platform === "win32" ? resolved.toLowerCase() : resolved;
}

function countOccurrences(value, needle) {
  if (needle.length === 0) {
    return 0;
  }
  let count = 0;
  let offset = 0;
  while ((offset = value.indexOf(needle, offset)) !== -1) {
    count += 1;
    offset += needle.length;
  }
  return count;
}

function countSerializedOccurrences(value, needle) {
  const encodedNeedle = JSON.stringify(needle).slice(1, -1);
  if (encodedNeedle === needle) {
    return countOccurrences(value, needle);
  }
  return countOccurrences(value, needle) + countOccurrences(value, encodedNeedle);
}

function pathVariants(value) {
  return [...new Set([value, value.replaceAll("\\", "/"), value.replaceAll("/", "\\")])];
}

function sha256(value) {
  return createHash("sha256").update(value, "utf8").digest("hex");
}

function fnv1a(value) {
  let hash = 0x811c9dc5;
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193);
  }
  return (hash >>> 0).toString(16).padStart(8, "0");
}

function requireRecord(value, code) {
  if (!isRecord(value) || Array.isArray(value)) {
    fail(code);
  }
  return value;
}

function isRecord(value) {
  return typeof value === "object" && value !== null;
}

function fail(code) {
  throw new ProbeFailure(code);
}

function safeErrorCode(error) {
  if (error instanceof ProbeFailure && /^[A-Z0-9_]+$/u.test(error.code)) {
    return error.code;
  }
  if (error instanceof Error && /^[A-Z0-9_]+$/u.test(error.message)) {
    return error.message;
  }
  return "SUBVERSIONR_I6_PACKAGED_REDACTION_PROBE_FAILED";
}
