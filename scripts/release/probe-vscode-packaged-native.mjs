import { createRequire } from "node:module";
import path from "node:path";

const PROBE_SCHEMA = "subversionr.release.packaged-native-compatibility.v1";

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
      },
    },
    {
      notificationHandler: () => undefined,
    },
  );

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

  const initializeResult = connection.initializeResult;
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
