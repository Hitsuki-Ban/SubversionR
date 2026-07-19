import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const probe = path.join(repositoryRoot, "scripts", "release", "probe-m8-i6-packaged-cancellation.mjs");
const schema = "subversionr.release.m8-i6-packaged-native-cancellation.v1";
const fixtureSchema = "subversionr.release.m8-i6-ra-svn-fault-fixture.v1";
const operationId = "87654321-4321-4abc-8def-ba0987654321";
const operationTimeoutMs = 30_000;

test("executes real AbortController cancellation and observes the exact daemon wire settlement", async () => {
  const fixture = await createFixture({});
  try {
    const result = runProbe(fixture.args);
    assert.equal(result.status, 0, result.stderr || result.stdout);
    assert.equal(result.stderr, "");
    const report = JSON.parse(result.stdout);
    assert.deepEqual(Object.keys(report), [
      "schema", "status", "cell", "stableCode", "reason", "protocol", "cancellationSettlement",
      "remoteSvnAnonymous", "nativeLaneReleased", "localSnapshotAfterCancellation",
      "workingCopyPreserved", "temporaryRootsAfter", "credentialRequests", "credentialSettlements",
      "diagnosticsRedacted", "fixtureCliInvocations",
    ]);
    assert.deepEqual(report, {
      schema,
      status: "passed",
      cell: "cancellation",
      stableCode: "SUBVERSIONR_REMOTE_WORKER_CANCELLED",
      reason: "operationCancelled",
      protocol: { major: 1, minor: 35 },
      cancellationSettlement: {
        trigger: "abort-signal-after-greeting",
        localCode: "JSON_RPC_REQUEST_CANCELLED",
        wireCode: "SUBVERSIONR_REMOTE_WORKER_CANCELLED",
        wireReason: "operationCancelled",
        wireSettlementObserved: true,
      },
      remoteSvnAnonymous: true,
      nativeLaneReleased: true,
      localSnapshotAfterCancellation: true,
      workingCopyPreserved: true,
      temporaryRootsAfter: 0,
      credentialRequests: 0,
      credentialSettlements: 0,
      diagnosticsRedacted: true,
      fixtureCliInvocations: 0,
    });
    for (const sensitive of [
      fixture.repositoryUrl,
      fixture.workingCopyPath,
      fixture.profileRoot,
      fixture.fixtureStatePath,
      operationId,
    ]) {
      assert.equal(result.stdout.toLowerCase().includes(sensitive.toLowerCase()), false);
    }

    const capture = JSON.parse(await readFile(fixture.capturePath, "utf8"));
    assert.deepEqual(capture.methods, [
      "repository/open",
      "status/checkRemote",
      "status/getSnapshot",
      "diagnostics/get",
      "repository/close",
    ]);
    assert.equal(capture.abortSignalObserved, true);
    assert.deepEqual(capture.wireObservation, { requestId: 41, timeoutMs: 5_500 });
    assert.equal(capture.shutdown, true);
    assert.equal(capture.config.clientName, "subversionr-m8-i6-packaged-cancellation-evidence");
    assert.equal(capture.config.workspaceTrust, "trusted");
    assert.equal(capture.config.appdata, fixture.profileRoot);
    assert.equal(capture.config.temp, fixture.profileRoot);
    const statusRequest = capture.requests[1].params;
    assert.deepEqual(Object.keys(statusRequest), ["repositoryId", "epoch", "remote"]);
    assert.equal(statusRequest.repositoryId, "repo-cancellation");
    assert.equal(statusRequest.epoch, 11);
    assert.equal(statusRequest.remote.operationId, operationId);
    assert.equal(statusRequest.remote.timeoutMs, operationTimeoutMs);
    assert.equal(statusRequest.remote.intent, "foreground");
    assert.equal(statusRequest.remote.interaction, "allowed");
    assert.equal(statusRequest.remote.workspaceTrust, "trusted");
    assert.equal(statusRequest.remote.trustEpoch, 11);
    assert.equal(capture.requests[1].retainCancelledWireSettlementForEvidence, true);
    assert.deepEqual(statusRequest.remote.expectedOrigin, fixture.endpoint);
    assert.deepEqual(statusRequest.remote.profile, {
      schema: "subversionr.remote-profile.v1",
      profileId: "m8-i6-loopback-anonymous-cancellation",
      authority: fixture.endpoint,
      serverAuth: "anonymous",
      serverAccount: "none",
      serverCredentialPersistence: "secretStorage",
      proxy: "none",
      ssh: "none",
      redirectPolicy: "rejectAll",
    });
    assert.deepEqual(capture.requests[2], {
      method: "status/getSnapshot",
      params: { repositoryId: "repo-cancellation", epoch: 11 },
    });
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("rejects non-immediate and non-exact local cancellation settlement", async () => {
  const cases = [
    [{ localName: "AbortError" }, "SUBVERSIONR_I6_PACKAGED_CANCELLATION_LOCAL_SETTLEMENT_INVALID"],
    [{ localCode: "ABORT_ERR" }, "SUBVERSIONR_I6_PACKAGED_CANCELLATION_LOCAL_SETTLEMENT_INVALID"],
    [{ localRequestId: 0 }, "SUBVERSIONR_I6_PACKAGED_CANCELLATION_LOCAL_SETTLEMENT_INVALID"],
    [{ localDelay: true }, "SUBVERSIONR_I6_PACKAGED_CANCELLATION_LOCAL_SETTLEMENT_INVALID"],
    [{ localResolves: true }, "SUBVERSIONR_I6_PACKAGED_CANCELLATION_LOCAL_SETTLEMENT_INVALID"],
    [{ omitWireObserver: true }, "SUBVERSIONR_I6_PACKAGED_CANCELLATION_CAPABILITY_INVALID"],
  ];
  for (const [behavior, expectedCode] of cases) {
    const fixture = await createFixture(behavior);
    try {
      assertProbeFails(fixture.args, expectedCode, JSON.stringify(behavior));
    } finally {
      await rm(fixture.root, { recursive: true, force: true });
    }
  }
});

test("rejects every non-exact daemon wire cancellation settlement", async () => {
  const cases = [
    [{ wireName: "Error" }, "SUBVERSIONR_I6_PACKAGED_CANCELLATION_WIRE_SETTLEMENT_INVALID"],
    [{ wireCode: "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT" }, "SUBVERSIONR_I6_PACKAGED_CANCELLATION_WIRE_SETTLEMENT_INVALID"],
    [{ wireCategory: "timeout" }, "SUBVERSIONR_I6_PACKAGED_CANCELLATION_WIRE_SETTLEMENT_INVALID"],
    [{ wireMessageKey: "error.remote.workerTimedOut" }, "SUBVERSIONR_I6_PACKAGED_CANCELLATION_WIRE_SETTLEMENT_INVALID"],
    [{ wireRetryable: true }, "SUBVERSIONR_I6_PACKAGED_CANCELLATION_WIRE_SETTLEMENT_INVALID"],
    [{ wireDiagnostics: {} }, "SUBVERSIONR_I6_PACKAGED_CANCELLATION_WIRE_SETTLEMENT_INVALID"],
    [{ safeArgsExtra: true }, "SUBVERSIONR_I6_PACKAGED_CANCELLATION_WIRE_SETTLEMENT_INVALID"],
    [{ failureCategory: "cancelled" }, "SUBVERSIONR_I6_PACKAGED_CANCELLATION_FAILURE_INVALID"],
    [{ failureCategory: "deadline" }, "SUBVERSIONR_I6_PACKAGED_CANCELLATION_FAILURE_INVALID"],
    [{ failureReason: "operationDeadlineExceeded" }, "SUBVERSIONR_I6_PACKAGED_CANCELLATION_FAILURE_INVALID"],
    [{ cleanupAppropriate: true }, "SUBVERSIONR_I6_PACKAGED_CANCELLATION_FAILURE_INVALID"],
    [{ wireResolves: true }, "SUBVERSIONR_I6_PACKAGED_CANCELLATION_WIRE_SETTLEMENT_INVALID"],
  ];
  for (const [behavior, expectedCode] of cases) {
    const fixture = await createFixture(behavior);
    try {
      assertProbeFails(fixture.args, expectedCode, JSON.stringify(behavior));
    } finally {
      await rm(fixture.root, { recursive: true, force: true });
    }
  }
});

test("rejects false same-session recovery, integrity, no-auth, cleanup, trust, and redaction evidence", async () => {
  const cases = [
    [{ snapshotRepositoryId: "other" }, "SUBVERSIONR_I6_PACKAGED_CANCELLATION_LOCAL_SNAPSHOT_INVALID"],
    [{ snapshotEpoch: 12 }, "SUBVERSIONR_I6_PACKAGED_CANCELLATION_LOCAL_SNAPSHOT_INVALID"],
    [{ snapshotSource: "remote-worker" }, "SUBVERSIONR_I6_PACKAGED_CANCELLATION_LOCAL_SNAPSHOT_INVALID"],
    [{ credentialRequest: true }, "SUBVERSIONR_I6_PACKAGED_CANCELLATION_CREDENTIAL_HANDLER_INVOKED"],
    [{ residue: true }, "SUBVERSIONR_I6_PACKAGED_CANCELLATION_WORKER_TEMP_RESIDUE"],
    [{ diagnosticsLeak: "repository" }, "SUBVERSIONR_I6_PACKAGED_CANCELLATION_DIAGNOSTICS_LEAK"],
    [{ diagnosticsLeak: "fixture" }, "SUBVERSIONR_I6_PACKAGED_CANCELLATION_DIAGNOSTICS_LEAK"],
    [{ tamperUserContent: true }, "SUBVERSIONR_I6_PACKAGED_CANCELLATION_WORKING_COPY_INVALID"],
    [{ removeEmptyDirectory: true }, "SUBVERSIONR_I6_PACKAGED_CANCELLATION_WORKING_COPY_INVALID"],
    [{ tamperWcDatabaseSameSize: true }, "SUBVERSIONR_I6_PACKAGED_CANCELLATION_WORKING_COPY_INVALID"],
    [{ protocolMinor: 34 }, "SUBVERSIONR_I6_PACKAGED_CANCELLATION_CAPABILITY_INVALID"],
    [{ remoteSvnAnonymous: false }, "SUBVERSIONR_I6_PACKAGED_CANCELLATION_CAPABILITY_INVALID"],
    [{ trustDropsAfterCancellation: true }, "SUBVERSIONR_I6_PACKAGED_CANCELLATION_TRUST_INVALID"],
    [{ closeFalse: true }, "SUBVERSIONR_I6_PACKAGED_CANCELLATION_CLOSE_INVALID"],
  ];
  for (const [behavior, expectedCode] of cases) {
    const fixture = await createFixture(behavior);
    try {
      assertProbeFails(fixture.args, expectedCode, JSON.stringify(behavior));
    } finally {
      await rm(fixture.root, { recursive: true, force: true });
    }
  }
});

test("rejects non-exact CLI, origin, fixture binding, working-copy identity, and profile state", async () => {
  const fixture = await createFixture({});
  try {
    const argumentCases = [
      [...fixture.args, "--extra", "value"],
      [...fixture.args, "--timeout-ms", "30000"],
      replaceValue(fixture.args, "--operation-id", "87654321-4321-4ABC-8def-ba0987654321"),
      replaceValue(fixture.args, "--operation-id", "00000000-0000-0000-0000-000000000000"),
      replaceValue(fixture.args, "--repository-url", "svn://localhost:43690/repo"),
      replaceValue(fixture.args, "--repository-url", "svn://127.0.0.1/repo"),
      replaceValue(fixture.args, "--repository-url", "svn://user@127.0.0.1:43690/repo"),
      replaceValue(fixture.args, "--fixture-state-path", "relative-state.json"),
    ];
    for (const args of argumentCases) {
      assertProbeFails(args, args.includes("relative-state.json")
        ? "SUBVERSIONR_I6_PACKAGED_CANCELLATION_ARGUMENT_INVALID"
        : args.includes("svn://localhost:43690/repo") || args.includes("svn://127.0.0.1/repo") || args.includes("svn://user@127.0.0.1:43690/repo")
          ? "SUBVERSIONR_I6_PACKAGED_CANCELLATION_URL_INVALID"
          : "SUBVERSIONR_I6_PACKAGED_CANCELLATION_ARGUMENT_INVALID");
    }
    await writeFile(path.join(fixture.profileRoot, "not-empty"), "x", "utf8");
    assertProbeFails(fixture.args, "SUBVERSIONR_I6_PACKAGED_CANCELLATION_FILESYSTEM_INVALID");
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }

  for (const behavior of [
    { fixtureScenario: "connected-stall" },
    { fixturePort: 43691 },
    { fixtureInitialConnections: 1 },
  ]) {
    const invalidFixture = await createFixture(behavior);
    try {
      assertProbeFails(invalidFixture.args, "SUBVERSIONR_I6_PACKAGED_CANCELLATION_FIXTURE_STATE_INVALID");
    } finally {
      await rm(invalidFixture.root, { recursive: true, force: true });
    }
  }

  const wrongWorkingCopyEndpoint = await createFixture({ workingCopyRepositoryUrl: "svn://127.0.0.1:43691/repo" });
  try {
    assertProbeFails(wrongWorkingCopyEndpoint.args, "SUBVERSIONR_I6_PACKAGED_CANCELLATION_OPEN_INVALID");
  } finally {
    await rm(wrongWorkingCopyEndpoint.root, { recursive: true, force: true });
  }

  const wrongCanonicalOrigin = await createFixture({ canonicalHost: "localhost" });
  try {
    assertProbeFails(wrongCanonicalOrigin.args, "SUBVERSIONR_I6_PACKAGED_CANCELLATION_ORIGIN_INVALID");
  } finally {
    await rm(wrongCanonicalOrigin.root, { recursive: true, force: true });
  }
});

async function createFixture(behavior) {
  const root = await mkdtemp(path.join(os.tmpdir(), "subversionr-i6-packaged-cancellation-test-"));
  const tooling = path.join(root, "tooling");
  const backendRoot = path.join(tooling, "dist", "backend");
  const securityRoot = path.join(tooling, "dist", "security");
  const profileRoot = path.join(root, "profile");
  const workingCopyPath = path.join(root, "wc");
  const fixtureStatePath = path.join(root, "fault-state.json");
  await mkdir(backendRoot, { recursive: true });
  await mkdir(securityRoot, { recursive: true });
  await mkdir(profileRoot);
  await mkdir(path.join(workingCopyPath, ".svn"), { recursive: true });
  await mkdir(path.join(workingCopyPath, "empty-directory"));
  await writeFile(path.join(workingCopyPath, ".svn", "wc.db"), "controlled-cancellation-wc-db", "utf8");
  await writeFile(path.join(workingCopyPath, "tracked.txt"), "controlled cancellation content\n", "utf8");
  const backendModule = path.join(backendRoot, "backendProcess.js");
  const remoteAccessModule = path.join(securityRoot, "remoteAccessProfile.js");
  const daemon = path.join(tooling, "subversionr-daemon.exe");
  const bridge = path.join(tooling, "subversionr-native.dll");
  const repositoryUrl = "svn://127.0.0.1:43690/repo";
  const initialState = faultState({
    scenario: behavior.fixtureScenario ?? "greeting-stall",
    port: behavior.fixturePort ?? 43690,
    connections: behavior.fixtureInitialConnections ?? 0,
  });
  await writeFile(fixtureStatePath, JSON.stringify(initialState), "utf8");
  await writeFile(
    backendModule,
    fakeBackendSource(behavior, workingCopyPath, repositoryUrl, operationId, fixtureStatePath),
    "utf8",
  );
  await writeFile(remoteAccessModule, fakeRemoteAccessProfileSource(behavior), "utf8");
  await writeFile(daemon, "fake-daemon", "utf8");
  await writeFile(bridge, "fake-bridge", "utf8");
  return {
    root,
    profileRoot,
    workingCopyPath,
    fixtureStatePath,
    repositoryUrl,
    capturePath: path.join(profileRoot, "remote-state", "capture.json"),
    endpoint: { scheme: "svn", canonicalHost: "127.0.0.1", effectivePort: 43690 },
    args: [
      "--backend-module", backendModule,
      "--daemon", daemon,
      "--bridge", bridge,
      "--profile-root", profileRoot,
      "--working-copy-path", workingCopyPath,
      "--repository-url", repositoryUrl,
      "--operation-id", operationId,
      "--fixture-state-path", fixtureStatePath,
    ],
  };
}

function fakeBackendSource(behavior, workingCopyPath, repositoryUrl, externalOperationId, fixtureStatePath) {
  return `
const fs = require("node:fs");
const path = require("node:path");
const behavior = ${JSON.stringify(behavior)};
const workingCopyPath = ${JSON.stringify(workingCopyPath)};
const repositoryUrl = ${JSON.stringify(repositoryUrl)};
const externalOperationId = ${JSON.stringify(externalOperationId)};
const fixtureStatePath = ${JSON.stringify(fixtureStatePath)};
exports.startBackendProcess = async function startBackendProcess(config, handlers) {
  const capturePath = path.join(config.remoteStateRoot, "capture.json");
  const workerRoot = path.join(config.baseEnv.TEMP, "SubversionR", "remote-workers");
  fs.mkdirSync(workerRoot, { recursive: true });
  if (behavior.residue === true) fs.mkdirSync(path.join(workerRoot, "residue"));
  const capture = {
    methods: [], requests: [], shutdown: false, abortSignalObserved: false,
    config: {
      clientName: config.clientName, workspaceTrust: config.workspaceTrust,
      appdata: config.baseEnv.APPDATA, temp: config.baseEnv.TEMP,
    },
  };
  const save = () => fs.writeFileSync(capturePath, JSON.stringify(capture));
  const updateFixture = (patch) => {
    const state = JSON.parse(fs.readFileSync(fixtureStatePath, "utf8"));
    Object.assign(state, patch);
    fs.writeFileSync(fixtureStatePath, JSON.stringify(state));
  };
  const wireObserver = async (requestId, timeoutMs) => {
    capture.wireObservation = { requestId, timeoutMs }; save();
    if (behavior.wireResolves === true) return { unexpected: true };
    const error = new Error(behavior.wireCode ?? "SUBVERSIONR_REMOTE_WORKER_CANCELLED");
    error.name = behavior.wireName ?? "JsonRpcStreamError";
    error.code = behavior.wireCode ?? "SUBVERSIONR_REMOTE_WORKER_CANCELLED";
    error.category = behavior.wireCategory ?? "cancelled";
    error.messageKey = behavior.wireMessageKey ?? "error.remote.workerCancelled";
    error.retryable = behavior.wireRetryable ?? false;
    error.safeArgs = {
      remoteFailure: {
        category: behavior.failureCategory ?? "cancellation",
        reason: behavior.failureReason ?? "operationCancelled",
        cleanupAppropriate: behavior.cleanupAppropriate ?? false,
      },
      ...(behavior.safeArgsExtra === true ? { path: workingCopyPath } : {}),
    };
    error.diagnostics = Object.hasOwn(behavior, "wireDiagnostics") ? behavior.wireDiagnostics : null;
    throw error;
  };
  const result = {
    initializeResult: {
      protocol: { major: 1, minor: behavior.protocolMinor ?? 35 },
      capabilities: {
        realLibsvnBridge: true, repositoryOpen: true, repositoryClose: true,
        statusSnapshot: true, statusRemoteCheck: true, remoteOperationEnvelope: true,
        remoteWorkerIsolation: true, remoteConnectionState: true,
        remoteSvnAnonymous: behavior.remoteSvnAnonymous ?? true,
      },
      acknowledgedTrustEpoch: 11,
    },
    isRemoteSubmissionEnabled() { return true; },
    currentRemoteTrustEpoch() {
      return behavior.trustDropsAfterCancellation === true && capture.abortSignalObserved ? 12 : 11;
    },
    sendRequest(method, params, options) {
      capture.methods.push(method); capture.requests.push({
        method,
        params,
        ...(options?.retainCancelledWireSettlementForEvidence === true
          ? { retainCancelledWireSettlementForEvidence: true }
          : {}),
      }); save();
      if (method === "repository/open") return Promise.resolve({
        repositoryId: "repo-cancellation", epoch: 11,
        identity: {
          workingCopyRoot: workingCopyPath,
          repositoryRootUrl: behavior.workingCopyRepositoryUrl ?? repositoryUrl,
        },
      });
      if (method === "status/checkRemote") {
        updateFixture({ connections: 1, greetingSent: 1, clientResponseReceived: 1 });
        return new Promise((resolve, reject) => {
          const settle = () => {
            capture.abortSignalObserved = true;
            if (behavior.credentialRequest === true) {
              Promise.resolve(handlers.requestHandler("credentials/request", {})).catch(() => undefined);
            }
            if (behavior.tamperUserContent === true) fs.writeFileSync(path.join(workingCopyPath, "tracked.txt"), "tampered\\n");
            if (behavior.removeEmptyDirectory === true) fs.rmdirSync(path.join(workingCopyPath, "empty-directory"));
            if (behavior.tamperWcDatabaseSameSize === true) {
              const wcDatabasePath = path.join(workingCopyPath, ".svn", "wc.db");
              const bytes = fs.readFileSync(wcDatabasePath); bytes[0] ^= 0xff; fs.writeFileSync(wcDatabasePath, bytes);
            }
            save();
            if (behavior.localResolves === true) { resolve({ unexpected: true }); return; }
            const error = new Error("JSON-RPC request cancelled");
            error.name = behavior.localName ?? "JsonRpcRequestCancelledError";
            error.code = behavior.localCode ?? "JSON_RPC_REQUEST_CANCELLED";
            error.requestId = behavior.localRequestId ?? 41;
            reject(error);
          };
          options.signal.addEventListener("abort", () => {
            if (behavior.localDelay === true) setTimeout(settle, 5); else settle();
          }, { once: true });
        });
      }
      if (method === "status/getSnapshot") return Promise.resolve({
        repositoryId: behavior.snapshotRepositoryId ?? "repo-cancellation",
        epoch: behavior.snapshotEpoch ?? 11,
        source: behavior.snapshotSource ?? "libsvn-local",
      });
      if (method === "diagnostics/get") return Promise.resolve({
        source: "subversionr-daemon",
        protocol: { major: 1, minor: 35 },
        capabilities: { remoteSvnAnonymous: true, statusRemoteCheck: true, statusSnapshot: true },
        entries: [],
        ...(behavior.diagnosticsLeak === "repository" ? { leaked: repositoryUrl } : {}),
        ...(behavior.diagnosticsLeak === "fixture" ? { leaked: fixtureStatePath } : {}),
        ...(behavior.diagnosticsLeak === "operation" ? { leaked: externalOperationId } : {}),
      });
      if (method === "repository/close") return Promise.resolve({
        repositoryId: "repo-cancellation", epoch: 11, closed: behavior.closeFalse !== true,
      });
      return Promise.reject(new Error("UNEXPECTED_METHOD"));
    },
    async shutdown() { capture.shutdown = true; save(); },
    dispose() { capture.disposed = true; save(); },
  };
  if (behavior.omitWireObserver !== true) result.waitForCancelledRequestWireSettlement = wireObserver;
  save();
  return result;
};
`;
}

function fakeRemoteAccessProfileSource(behavior) {
  return `
const behavior = ${JSON.stringify(behavior)};
exports.canonicalEndpointFromRepositoryUrl = function(repositoryUrl) {
  const url = new URL(repositoryUrl);
  return { scheme: "svn", canonicalHost: behavior.canonicalHost ?? url.hostname, effectivePort: Number(url.port) };
};
exports.RemoteOperationEnvelopeFactory = class {
  constructor(admission) { this.admission = admission; }
  createAnonymousSvn(input) {
    return {
      version: 1, operationId: input.operationId, intent: input.intent,
      interaction: input.interaction, timeoutMs: input.timeoutMs,
      workspaceTrust: "trusted", trustEpoch: this.admission.currentRemoteTrustEpoch(),
      profile: input.profile, expectedOrigin: input.expectedOrigin,
    };
  }
};
`;
}

function faultState(overrides = {}) {
  return {
    schema: fixtureSchema,
    pid: process.pid,
    port: 43690,
    suppliedAuthorityPort: 0,
    scenario: "greeting-stall",
    connections: 0,
    suppliedAuthorityConnections: 0,
    greetingSent: 0,
    clientResponseReceived: 0,
    authRequestSent: 0,
    reposInfoSent: 0,
    commandsReceived: 0,
    followupContacts: 0,
    status: "ready",
    ...overrides,
  };
}

function runProbe(args) {
  return spawnSync(process.execPath, [probe, ...args], {
    cwd: repositoryRoot,
    encoding: "utf8",
    timeout: 15_000,
    windowsHide: true,
  });
}

function assertProbeFails(args, code, context = "") {
  const result = runProbe(args);
  assert.equal(result.status, 1, `${context}\n${result.stderr || result.stdout}`);
  assert.equal(result.stderr, "");
  assert.deepEqual(JSON.parse(result.stdout), { schema, status: "failed", error: { code } });
}

function replaceValue(args, name, value) {
  const copy = [...args];
  copy[copy.indexOf(name) + 1] = value;
  return copy;
}
