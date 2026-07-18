import { createRequire } from "node:module";
import { spawn } from "node:child_process";
import { readdir } from "node:fs/promises";
import path from "node:path";

const PROBE_SCHEMA = "subversionr.release.packaged-native-compatibility.v2";
const EXPECTED_PROTOCOL_MAJOR = 1;
const EXPECTED_PROTOCOL_MINOR = 34;
const EXPECTED_REMOTE_RESULT_CODE = "SUBVERSIONR_REMOTE_TRANSPORT_UNSUPPORTED";

class ProbeError extends Error {
  constructor(code, messageKey, safeArgs = {}) {
    super(code);
    this.name = "ProbeError";
    this.code = code;
    this.category = "protocol";
    this.messageKey = messageKey;
    this.safeArgs = safeArgs;
    this.retryable = false;
    this.diagnostics = null;
  }
}

let connection;

try {
  const options = parseOptions(process.argv.slice(2));
  const require = createRequire(import.meta.url);
  const { startBackendProcess } = require(options.backendModule);
  if (typeof startBackendProcess !== "function") {
    throw new ProbeError(
      "SUBVERSIONR_PACKAGED_NATIVE_PROBE_CONTRACT_MISSING",
      "error.release.packagedNativeProbeContractMissing",
    );
  }

  connection = await startBackendProcess(
    {
      executablePath: options.daemon,
      bridgeDllPath: options.bridge,
      cacheRoot: options.cacheRoot,
      clientName: "subversionr-release-probe",
      clientVersion: "1",
      locale: "en",
      workspaceTrust: "trusted",
      baseEnv: {
        ...process.env,
        APPDATA: options.profileRoot,
        LOCALAPPDATA: options.profileRoot,
        USERPROFILE: options.profileRoot,
        HOME: options.profileRoot,
        TEMP: options.profileRoot,
        TMP: options.profileRoot,
      },
    },
    {
      notificationHandler: () => undefined,
    },
  );

  const initializeResult = connection.initializeResult;
  if (
    !isRecord(initializeResult.protocol) ||
    initializeResult.protocol.major !== EXPECTED_PROTOCOL_MAJOR ||
    initializeResult.protocol.minor !== EXPECTED_PROTOCOL_MINOR
  ) {
    throw new ProbeError(
      "SUBVERSIONR_PACKAGED_NATIVE_PROTOCOL_INVALID",
      "error.release.packagedNativeProtocolInvalid",
    );
  }
  if (
    initializeResult.capabilities?.remoteWorkerIsolation !== true ||
    initializeResult.capabilities?.remoteConnectionState !== true ||
    initializeResult.capabilities?.credentialLeaseSettlement !== true
  ) {
    throw new ProbeError(
      "SUBVERSIONR_PACKAGED_NATIVE_REMOTE_WORKER_CAPABILITY_MISSING",
      "error.release.packagedNativeRemoteWorkerCapabilityMissing",
    );
  }

  const discovery = await connection.sendRequest("repository/discover", {
    workspaceRoots: [options.workspaceRoot],
    discoverNested: false,
    discoveryDepth: 0,
    discoveryIgnore: [],
    ignoredRoots: [],
    externalsMode: "off",
  });
  if (
    !isRecord(discovery) ||
    !Array.isArray(discovery.candidates) ||
    discovery.candidates.length !== 0 ||
    !Array.isArray(discovery.fileExternalBoundaries) ||
    discovery.fileExternalBoundaries.length !== 0
  ) {
    throw new ProbeError(
      "SUBVERSIONR_PACKAGED_NATIVE_DISCOVERY_RESPONSE_INVALID",
      "error.release.packagedNativeDiscoveryResponseInvalid",
    );
  }

  const remoteResultCode = await requireRemoteUnsupported(
    connection,
    remoteCheckoutRequest(options.workspaceRoot, "12700000-0000-4000-8000-000000000003"),
  );
  const credentialProviderProbe = await runCredentialProviderProbe(options);
  const workerTempRoot = path.join(options.profileRoot, "SubversionR", "remote-workers");
  const residualWorkerTempEntries = await readDirectoryIfPresent(workerTempRoot);
  if (residualWorkerTempEntries.length !== 0) {
    throw new ProbeError(
      "SUBVERSIONR_PACKAGED_NATIVE_REMOTE_WORKER_CLEANUP_INVALID",
      "error.release.packagedNativeRemoteWorkerCleanupInvalid",
    );
  }
  const sameLaneResultCode = await requireRemoteUnsupported(
    connection,
    remoteCheckoutRequest(options.workspaceRoot, "12700000-0000-4000-8000-000000000004"),
  );

  const diagnostics = await connection.sendRequest("diagnostics/get", {});
  if (
    !isRecord(diagnostics) ||
    !isRecord(diagnostics.protocol) ||
    diagnostics.protocol.major !== EXPECTED_PROTOCOL_MAJOR ||
    diagnostics.protocol.minor !== EXPECTED_PROTOCOL_MINOR ||
    !isRecord(diagnostics.capabilities) ||
    diagnostics.capabilities.remoteWorkerIsolation !== true ||
    diagnostics.capabilities.remoteConnectionState !== true ||
    diagnostics.capabilities.credentialLeaseSettlement !== true ||
    diagnostics.source !== "subversionr-daemon"
  ) {
    throw new ProbeError(
      "SUBVERSIONR_PACKAGED_NATIVE_SUBSEQUENT_DIAGNOSTICS_INVALID",
      "error.release.packagedNativeSubsequentDiagnosticsInvalid",
    );
  }

  await connection.shutdown();
  connection = undefined;
  process.stdout.write(
    `${JSON.stringify({
      schema: PROBE_SCHEMA,
      status: "passed",
      protocol: initializeResult.protocol,
      backendVersion: initializeResult.backendVersion,
      bridgeVersion: initializeResult.bridgeVersion,
      libsvnVersion: initializeResult.libsvnVersion,
      capabilities: {
        remoteWorkerIsolation: true,
        remoteConnectionState: true,
        credentialLeaseSettlement: true,
      },
      localDiscovery: {
        status: "passed",
        candidateCount: discovery.candidates.length,
        fileExternalBoundaryCount: discovery.fileExternalBoundaries.length,
      },
      workerIsolation: {
        operation: "repository/checkout",
        expectedOriginScheme: "https",
        resultCode: remoteResultCode,
        tempRootCleanup: {
          status: "passed",
          residualEntryCount: residualWorkerTempEntries.length,
        },
        sameLaneSubsequent: {
          status: "passed",
          resultCode: sameLaneResultCode,
        },
        subsequentDiagnostics: {
          status: "passed",
          source: diagnostics.source,
          protocol: diagnostics.protocol,
        },
      },
      credentialProviderProbe,
    })}\n`,
  );
} catch (error) {
  connection?.dispose();
  process.stdout.write(
    `${JSON.stringify({
      schema: PROBE_SCHEMA,
      status: "failed",
      error: structuredError(error),
    })}\n`,
  );
  process.exitCode = 1;
}

async function runCredentialProviderProbe(options) {
  const expectedOutcomes = {
    firstSave: ["request:initial", "settle:accepted"],
    firstNextSave: ["request:initial", "settle:rejected", "request:retryAfterRejected", "settle:accepted"],
    unused: ["request:initial", "settle:unused"],
    cancelled: ["request:initial", "settle:cancelled"],
    timedOut: ["request:initial", "settle:timedOut"],
  };
  const result = await runBoundedPrivateProbe(options);
  if (
    result.status !== "passed" ||
    result.schema !== "subversionr.private.credential-provider-probe.v1" ||
    result.networkAccess !== false ||
    !Array.isArray(result.scenarios) ||
    result.scenarios.length !== Object.keys(expectedOutcomes).length
  ) {
    throw new ProbeError(
      "SUBVERSIONR_PACKAGED_NATIVE_CREDENTIAL_PROVIDER_PROBE_INVALID",
      "error.release.packagedNativeCredentialProviderProbeInvalid",
    );
  }
  const expectedEntries = Object.entries(expectedOutcomes);
  for (let index = 0; index < expectedEntries.length; index += 1) {
    const entry = result.scenarios[index];
    const [expectedScenario, expectedEvents] = expectedEntries[index];
    if (
      !isRecord(entry) ||
      entry.scenario !== expectedScenario ||
      JSON.stringify(entry.events) !== JSON.stringify(expectedEvents)
    ) {
      throw new ProbeError(
        "SUBVERSIONR_PACKAGED_NATIVE_CREDENTIAL_PROVIDER_PROBE_INVALID",
        "error.release.packagedNativeCredentialProviderProbeInvalid",
      );
    }
  }
  return result;
}

async function runBoundedPrivateProbe(options) {
  const output = await new Promise((resolve, reject) => {
    const child = spawn(options.daemon, ["--subversionr-private-credential-provider-probe-v1"], {
      env: {
        ...process.env,
        SUBVERSIONR_BRIDGE_DLL: options.bridge,
        APPDATA: options.profileRoot,
        LOCALAPPDATA: options.profileRoot,
        USERPROFILE: options.profileRoot,
        HOME: options.profileRoot,
        TEMP: options.profileRoot,
        TMP: options.profileRoot,
      },
      shell: false,
      windowsHide: true,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => {
      child.kill();
      reject(new Error("private credential provider probe timed out"));
    }, 30_000);
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
      if (stdout.length > 64 * 1024) child.kill();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
      if (stderr.length > 4 * 1024) child.kill();
    });
    child.once("error", reject);
    child.once("close", (code) => {
      clearTimeout(timer);
      if (code !== 0 || stderr.length !== 0 || stdout.length === 0 || stdout.length > 64 * 1024) {
        reject(new Error("private credential provider probe failed"));
        return;
      }
      resolve(stdout);
    });
  });
  const lines = output.trimEnd().split(/\r?\n/u);
  if (lines.length !== 1) {
    throw new ProbeError(
      "SUBVERSIONR_PACKAGED_NATIVE_CREDENTIAL_PROVIDER_PROBE_INVALID",
      "error.release.packagedNativeCredentialProviderProbeInvalid",
    );
  }
  try {
    const result = JSON.parse(lines[0]);
    if (isRecord(result)) return result;
  } catch {}
  throw new ProbeError(
    "SUBVERSIONR_PACKAGED_NATIVE_CREDENTIAL_PROVIDER_PROBE_INVALID",
    "error.release.packagedNativeCredentialProviderProbeInvalid",
  );
}

async function requireRemoteUnsupported(activeConnection, request) {
  try {
    await activeConnection.sendRequest("repository/checkout", request);
    throw new ProbeError(
      "SUBVERSIONR_PACKAGED_NATIVE_REMOTE_WORKER_RESULT_INVALID",
      "error.release.packagedNativeRemoteWorkerResultInvalid",
    );
  } catch (error) {
    if (!isRecord(error) || error.code !== EXPECTED_REMOTE_RESULT_CODE) {
      throw error;
    }
    return error.code;
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

function remoteCheckoutRequest(workspaceRoot, operationId) {
  const endpoint = {
    scheme: "https",
    canonicalHost: "svn.example.invalid",
    effectivePort: 443,
  };
  return {
    url: "https://svn.example.invalid/project/trunk",
    targetPath: path.join(workspaceRoot, "packaged-native-worker-target"),
    revision: "head",
    depth: "infinity",
    ignoreExternals: true,
    remote: {
      version: 1,
      operationId,
      intent: "foreground",
      interaction: "forbidden",
      timeoutMs: 10_000,
      workspaceTrust: "trusted",
      trustEpoch: 1,
      profile: {
        schema: "subversionr.remote-profile.v1",
        profileId: "packaged-native-worker",
        authority: endpoint,
        serverAuth: "anonymous",
        serverAccount: "none",
        serverCredentialPersistence: "secretStorage",
        tls: { trust: "windowsRootsThenBroker" },
        proxy: "none",
        ssh: "none",
        redirectPolicy: "rejectAll",
      },
      expectedOrigin: endpoint,
    },
  };
}

function parseOptions(args) {
  const expectedNames = ["backend-module", "daemon", "bridge", "cache-root", "workspace-root", "profile-root"];
  const parsed = {};
  for (let index = 0; index < args.length; index += 2) {
    const rawName = args[index];
    const value = args[index + 1];
    if (typeof rawName !== "string" || !rawName.startsWith("--") || typeof value !== "string") {
      throw new ProbeError(
        "SUBVERSIONR_PACKAGED_NATIVE_PROBE_ARGUMENT_INVALID",
        "error.release.packagedNativeProbeArgumentInvalid",
      );
    }
    const name = rawName.slice(2);
    if (!expectedNames.includes(name) || name in parsed) {
      throw new ProbeError(
        "SUBVERSIONR_PACKAGED_NATIVE_PROBE_ARGUMENT_INVALID",
        "error.release.packagedNativeProbeArgumentInvalid",
        { name },
      );
    }
    parsed[name] = requireAbsolute(value, name);
  }
  for (const name of expectedNames) {
    if (!(name in parsed)) {
      throw new ProbeError(
        "SUBVERSIONR_PACKAGED_NATIVE_PROBE_ARGUMENT_REQUIRED",
        "error.release.packagedNativeProbeArgumentRequired",
        { name },
      );
    }
  }
  return {
    backendModule: parsed["backend-module"],
    daemon: parsed.daemon,
    bridge: parsed.bridge,
    cacheRoot: parsed["cache-root"],
    workspaceRoot: parsed["workspace-root"],
    profileRoot: parsed["profile-root"],
  };
}

function requireAbsolute(value, name) {
  if (!path.isAbsolute(value)) {
    throw new ProbeError(
      "SUBVERSIONR_PACKAGED_NATIVE_PROBE_PATH_NOT_ABSOLUTE",
      "error.release.packagedNativeProbePathNotAbsolute",
      { name },
    );
  }
  return value;
}

function structuredError(error) {
  if (isRecord(error)) {
    const code = nonEmptyString(error.code);
    const category = nonEmptyString(error.category);
    const messageKey = nonEmptyString(error.messageKey);
    const safeArgs = isRecord(error.safeArgs) ? error.safeArgs : {};
    if (code !== undefined && category !== undefined && messageKey !== undefined) {
      return {
        code,
        category,
        messageKey,
        safeArgs,
        retryable: error.retryable === true,
        diagnostics: null,
      };
    }
  }
  return {
    code: "SUBVERSIONR_PACKAGED_NATIVE_PROBE_FAILED",
    category: "process",
    messageKey: "error.release.packagedNativeProbeFailed",
    safeArgs: {},
    retryable: false,
    diagnostics: null,
  };
}

function nonEmptyString(value) {
  return typeof value === "string" && value.trim().length > 0 ? value : undefined;
}

function isRecord(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
