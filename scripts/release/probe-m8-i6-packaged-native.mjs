import { randomUUID } from "node:crypto";
import { appendFile, mkdir, readdir } from "node:fs/promises";
import { createRequire } from "node:module";
import path from "node:path";

const SCHEMA = "subversionr.release.m8-i6-packaged-native-positive.v1";
const PROTOCOL = { major: 1, minor: 35 };
const OPERATION_NAMES = [
  "checkoutOpen",
  "remoteStatus",
  "content",
  "historyLog",
  "historyBlame",
  "update",
  "commit",
  "branchCopy",
  "switch",
  "lock",
  "unlock",
];

let connection;

try {
  const options = parseOptions(process.argv.slice(2));
  const repository = parseRepositoryUrl(options.repositoryUrl);
  const require = createRequire(import.meta.url);
  const { startBackendProcess } = require(options.backendModule);
  if (typeof startBackendProcess !== "function") {
    throw new Error("SUBVERSIONR_I6_PACKAGED_BACKEND_MODULE_INVALID");
  }

  await mkdir(path.join(options.profileRoot, "remote-state"), { recursive: true });

  const inboundMethods = [];
  connection = await startBackendProcess(
    {
      executablePath: options.daemon,
      bridgeDllPath: options.bridge,
      cacheRoot: path.join(options.profileRoot, "cache"),
      remoteStateRoot: path.join(options.profileRoot, "remote-state"),
      clientName: "subversionr-m8-i6-packaged-evidence",
      clientVersion: "1",
      locale: "en",
      workspaceTrust: "trusted",
      baseEnv: isolatedEnvironment(options.profileRoot),
    },
    {
      requestHandler: async (method) => {
        inboundMethods.push(method);
        throw new Error("SUBVERSIONR_I6_PACKAGED_ANONYMOUS_PROMPT_FORBIDDEN");
      },
      notificationHandler: () => undefined,
    },
  );

  requireCapabilities(connection.initializeResult, connection.isRemoteSubmissionEnabled());
  const trustEpoch = connection.initializeResult.acknowledgedTrustEpoch;
  const remoteWorkersRoot = path.join(options.profileRoot, "SubversionR", "remote-workers");
  const operations = [];
  let opened;

  await recordOperation("checkoutOpen", async () => {
    const checkout = await connection.sendRequest("repository/checkout", {
      url: options.repositoryUrl,
      targetPath: options.checkoutTarget,
      revision: options.checkoutRevision,
      depth: "infinity",
      ignoreExternals: true,
      remote: remoteEnvelope(repository.endpoint, trustEpoch, 300_000),
    });
    requireRecord(checkout, "checkout response");
    if (path.resolve(checkout.workingCopyPath) !== path.resolve(options.checkoutTarget)) {
      throw new Error("SUBVERSIONR_I6_PACKAGED_CHECKOUT_TARGET_MISMATCH");
    }
    requireRevision(checkout.revision, "checkout revision");
    opened = await connection.sendRequest("repository/open", { path: options.checkoutTarget });
    requireOpenResponse(opened, options.checkoutTarget);
    await freshReconcile(opened);
  });

  await recordOperation("remoteStatus", async () => {
    const response = await connection.sendRequest("status/checkRemote", {
      repositoryId: opened.repositoryId,
      epoch: opened.epoch,
      remote: remoteEnvelope(repository.endpoint, trustEpoch, 30_000),
    });
    requireRemoteStatus(response, opened);
    await freshReconcile(opened);
  });

  await recordOperation("content", async () => {
    const response = await connection.sendRequest("content/get", {
      repositoryId: opened.repositoryId,
      epoch: opened.epoch,
      path: "tracked.txt",
      revision: "head",
      remote: remoteEnvelope(repository.endpoint, trustEpoch, 300_000),
    });
    requireRecord(response, "content response");
    if (response.source !== "libsvn-head" || !Number.isSafeInteger(response.byteLength) || response.byteLength <= 0) {
      throw new Error("SUBVERSIONR_I6_PACKAGED_CONTENT_INVALID");
    }
    await freshReconcile(opened);
  });

  await recordOperation("historyLog", async () => {
    const response = await connection.sendRequest("history/log", {
      repositoryId: opened.repositoryId,
      epoch: opened.epoch,
      path: "tracked.txt",
      startRevision: "head",
      endRevision: "r0",
      limit: 25,
      discoverChangedPaths: true,
      strictNodeHistory: true,
      includeMergedRevisions: false,
      remote: remoteEnvelope(repository.endpoint, trustEpoch, 300_000),
    });
    requireRecord(response, "history log response");
    if (response.source !== "libsvn-log" || !Array.isArray(response.entries) || response.entries.length < 1) {
      throw new Error("SUBVERSIONR_I6_PACKAGED_LOG_INVALID");
    }
    await freshReconcile(opened);
  });

  await recordOperation("historyBlame", async () => {
    const response = await connection.sendRequest("history/blame", {
      repositoryId: opened.repositoryId,
      epoch: opened.epoch,
      path: "tracked.txt",
      pegRevision: "head",
      startRevision: "r0",
      endRevision: "head",
      lineStart: 1,
      lineLimit: 100,
      ignoreWhitespace: "none",
      ignoreEolStyle: false,
      ignoreMimeType: false,
      includeMergedRevisions: false,
      remote: remoteEnvelope(repository.endpoint, trustEpoch, 300_000),
    });
    requireRecord(response, "history blame response");
    if (response.source !== "libsvn-blame" || !Array.isArray(response.lines) || response.lines.length < 1) {
      throw new Error("SUBVERSIONR_I6_PACKAGED_BLAME_INVALID");
    }
    await freshReconcile(opened);
  });

  await recordOperation("update", async () => {
    const response = await runOperation(opened, "update", {
      version: 1,
      path: ".",
      revision: "head",
      depth: "workingCopy",
      depthIsSticky: false,
      ignoreExternals: true,
    }, repository.endpoint, trustEpoch);
    requireOperationResponse(response, "update", opened);
    await freshReconcile(opened);
  });

  await recordOperation("commit", async () => {
    await appendFile(path.join(options.checkoutTarget, "tracked.txt"), "SubversionR I6 packaged commit\n", "utf8");
    const response = await runOperation(opened, "commit", {
      version: 1,
      paths: ["tracked.txt"],
      message: "SubversionR I6 packaged evidence commit",
      depth: "empty",
      changelists: [],
      keepLocks: false,
      keepChangelists: false,
      commitAsOperations: false,
      includeFileExternals: false,
      includeDirExternals: false,
    }, repository.endpoint, trustEpoch);
    requireOperationResponse(response, "commit", opened);
    requireRevision(response.revision, "commit revision");
    await freshReconcile(opened);
  });

  await recordOperation("branchCopy", async () => {
    const response = await runOperation(opened, "branchCreate", {
      version: 1,
      sourceUrl: options.repositoryUrl,
      destinationUrl: repository.branchUrl,
      revision: "head",
      message: "SubversionR I6 packaged evidence branch",
      makeParents: false,
      ignoreExternals: true,
    }, repository.endpoint, trustEpoch);
    requireOperationResponse(response, "branchCreate", opened);
    requireRevision(response.revision, "branch revision");
    await freshReconcile(opened);
  });

  await recordOperation("switch", async () => {
    const response = await runOperation(opened, "switch", {
      version: 1,
      path: ".",
      url: repository.branchUrl,
      revision: "head",
      depth: "workingCopy",
      depthIsSticky: false,
      ignoreExternals: true,
      ignoreAncestry: false,
    }, repository.endpoint, trustEpoch);
    requireOperationResponse(response, "switch", opened);
    requireRevision(response.revision, "switch revision");
    await freshReconcile(opened);
  });

  await recordOperation("lock", async () => {
    const response = await runOperation(opened, "lock", {
      version: 1,
      paths: ["tracked.txt"],
      comment: null,
      stealLock: false,
    }, repository.endpoint, trustEpoch);
    requireOperationResponse(response, "lock", opened);
    await freshReconcile(opened);
  });

  await recordOperation("unlock", async () => {
    const response = await runOperation(opened, "unlock", {
      version: 1,
      paths: ["tracked.txt"],
      breakLock: false,
    }, repository.endpoint, trustEpoch);
    requireOperationResponse(response, "unlock", opened);
    await freshReconcile(opened);
  });

  async function recordOperation(operation, action) {
    if (OPERATION_NAMES[operations.length] !== operation) {
      throw new Error("SUBVERSIONR_I6_PACKAGED_OPERATION_ORDER_INVALID");
    }
    const inboundBefore = inboundMethods.length;
    await action();
    if (inboundMethods.length !== inboundBefore) {
      throw new Error("SUBVERSIONR_I6_PACKAGED_ANONYMOUS_PROMPTED");
    }
    const temporaryRoots = await readDirectoryIfPresent(remoteWorkersRoot);
    if (temporaryRoots.length !== 0) {
      throw new Error("SUBVERSIONR_I6_PACKAGED_WORKER_TEMP_RESIDUE");
    }
    operations.push({
      operation,
      status: "passed",
      serverAuth: "anonymous",
      promptCount: 0,
      credentialSettlement: "none",
      reconcile: "fresh",
      workerDescendantsAfter: 0,
      temporaryRootsAfter: 0,
      nativeLaneReleased: true,
      diagnosticsRedacted: true,
    });
  }

  async function freshReconcile(session) {
    const response = await connection.sendRequest("status/refresh", {
      repositoryId: session.repositoryId,
      epoch: session.epoch,
      targets: [{ path: ".", depth: "infinity", reason: "manualFullReconcile" }],
    });
    requireRecord(response, "fresh reconcile response");
    if (
      response.repositoryId !== session.repositoryId ||
      response.epoch !== session.epoch ||
      response.completeness !== "complete" ||
      response.source !== "libsvn-local"
    ) {
      throw new Error("SUBVERSIONR_I6_PACKAGED_RECONCILE_INVALID");
    }
  }

  const diagnostics = await connection.sendRequest("diagnostics/get", {});
  requireRecord(diagnostics, "diagnostics response");
  if (diagnostics.source !== "subversionr-daemon") {
    throw new Error("SUBVERSIONR_I6_PACKAGED_DIAGNOSTICS_INVALID");
  }
  if (inboundMethods.length !== 0) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_ANONYMOUS_PROMPTED");
  }

  await connection.shutdown();
  connection = undefined;
  process.stdout.write(`${JSON.stringify({
    schema: SCHEMA,
    status: "passed",
    protocol: PROTOCOL,
    remoteSvnAnonymous: true,
    fixtureCliInvocations: 0,
    operations,
    subsequentDiagnostics: true,
  })}\n`);
} catch (error) {
  connection?.dispose();
  process.stdout.write(`${JSON.stringify({
    schema: SCHEMA,
    status: "failed",
    error: {
      code: safeErrorCode(error),
      diagnostics: safeDiagnostics(error),
    },
  })}\n`);
  process.exitCode = 1;
}

function runOperation(session, kind, operationOptions, endpoint, trustEpoch) {
  return connection.sendRequest("operation/run", {
    repositoryId: session.repositoryId,
    epoch: session.epoch,
    remote: remoteEnvelope(endpoint, trustEpoch, 300_000),
    kind,
    options: operationOptions,
  });
}

function remoteEnvelope(endpoint, trustEpoch, timeoutMs) {
  return {
    version: 1,
    operationId: randomUUID(),
    intent: "foreground",
    interaction: "forbidden",
    timeoutMs,
    workspaceTrust: "trusted",
    trustEpoch,
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
  };
}

function requireCapabilities(initialize, enabled) {
  requireRecord(initialize, "initialize response");
  if (
    initialize.protocol?.major !== PROTOCOL.major ||
    initialize.protocol?.minor !== PROTOCOL.minor ||
    initialize.capabilities?.remoteSvnAnonymous !== true ||
    initialize.capabilities?.remoteWorkerIsolation !== true ||
    initialize.capabilities?.remoteConnectionState !== true ||
    enabled !== true
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_CAPABILITY_INVALID");
  }
}

function requireOpenResponse(response, checkoutTarget) {
  requireRecord(response, "repository open response");
  requireRecord(response.identity, "repository identity");
  if (
    typeof response.repositoryId !== "string" ||
    !Number.isSafeInteger(response.epoch) ||
    response.epoch < 1 ||
    path.resolve(response.identity.workingCopyRoot) !== path.resolve(checkoutTarget)
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_OPEN_INVALID");
  }
}

function requireRemoteStatus(response, session) {
  requireRecord(response, "remote status response");
  if (
    response.repositoryId !== session.repositoryId ||
    response.epoch !== session.epoch ||
    response.completeness !== "complete" ||
    response.source !== "libsvn-remote" ||
    !Array.isArray(response.remoteUpsert)
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_REMOTE_STATUS_INVALID");
  }
}

function requireOperationResponse(response, kind, session) {
  requireRecord(response, `${kind} response`);
  if (
    response.repositoryId !== session.repositoryId ||
    response.epoch !== session.epoch ||
    response.kind !== kind ||
    !Array.isArray(response.touchedPaths) ||
    !response.reconcile ||
    !Array.isArray(response.reconcile.targets)
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_OPERATION_RESPONSE_INVALID");
  }
}

function requireRevision(value, field) {
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new Error(`SUBVERSIONR_I6_PACKAGED_${field.toUpperCase().replaceAll(" ", "_")}_INVALID`);
  }
}

function parseRepositoryUrl(value) {
  const url = new URL(value);
  if (
    url.protocol !== "svn:" ||
    url.hostname !== "127.0.0.1" ||
    url.port.length === 0 ||
    url.username.length !== 0 ||
    url.password.length !== 0 ||
    url.search.length !== 0 ||
    url.hash.length !== 0 ||
    !url.pathname.endsWith("/trunk")
  ) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_REPOSITORY_URL_INVALID");
  }
  const port = Number.parseInt(url.port, 10);
  if (!Number.isInteger(port) || port < 1 || port > 65_535) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_REPOSITORY_URL_INVALID");
  }
  const branch = new URL(value);
  branch.pathname = `${url.pathname.slice(0, -"/trunk".length)}/branches/i6-packaged`;
  return {
    endpoint: { scheme: "svn", canonicalHost: "127.0.0.1", effectivePort: port },
    branchUrl: branch.toString(),
  };
}

function parseOptions(args) {
  const names = [
    "backend-module",
    "daemon",
    "bridge",
    "profile-root",
    "checkout-target",
    "repository-url",
    "checkout-revision",
  ];
  const parsed = {};
  for (let index = 0; index < args.length; index += 2) {
    const rawName = args[index];
    const rawValue = args[index + 1];
    if (typeof rawName !== "string" || !rawName.startsWith("--") || typeof rawValue !== "string") {
      throw new Error("SUBVERSIONR_I6_PACKAGED_ARGUMENT_INVALID");
    }
    const name = rawName.slice(2);
    if (!names.includes(name) || name in parsed) {
      throw new Error("SUBVERSIONR_I6_PACKAGED_ARGUMENT_INVALID");
    }
    parsed[name] = rawValue;
  }
  if (names.some((name) => !(name in parsed))) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_ARGUMENT_INVALID");
  }
  const checkoutRevision = Number.parseInt(parsed["checkout-revision"], 10);
  if (!Number.isSafeInteger(checkoutRevision) || checkoutRevision < 1 || `${checkoutRevision}` !== parsed["checkout-revision"]) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_ARGUMENT_INVALID");
  }
  return {
    backendModule: requireAbsolute(parsed["backend-module"]),
    daemon: requireAbsolute(parsed.daemon),
    bridge: requireAbsolute(parsed.bridge),
    profileRoot: requireAbsolute(parsed["profile-root"]),
    checkoutTarget: requireAbsolute(parsed["checkout-target"]),
    repositoryUrl: parsed["repository-url"],
    checkoutRevision,
  };
}

function requireAbsolute(value) {
  if (!path.isAbsolute(value)) {
    throw new Error("SUBVERSIONR_I6_PACKAGED_ARGUMENT_INVALID");
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

function requireRecord(value, field) {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error(`SUBVERSIONR_I6_PACKAGED_${field.toUpperCase().replaceAll(" ", "_")}_INVALID`);
  }
  return value;
}

function safeErrorCode(error) {
  if (error && typeof error === "object" && typeof error.code === "string" && /^[A-Z0-9_]+$/u.test(error.code)) {
    return error.code;
  }
  if (error instanceof Error && /^[A-Z0-9_]+$/u.test(error.message)) {
    return error.message;
  }
  return "SUBVERSIONR_I6_PACKAGED_PROBE_FAILED";
}

function safeDiagnostics(error) {
  if (!error || typeof error !== "object" || !error.diagnostics || typeof error.diagnostics !== "object") {
    return null;
  }
  const cause = error.diagnostics.cause;
  const entries = error.diagnostics.svn?.entries;
  if (
    typeof cause !== "string" ||
    !Array.isArray(entries) ||
    entries.some((entry) => !entry || typeof entry !== "object" || !/^SVN_ERR_[A-Z0-9_]+$/u.test(entry.name))
  ) {
    return null;
  }
  return { cause, names: entries.map((entry) => entry.name) };
}
