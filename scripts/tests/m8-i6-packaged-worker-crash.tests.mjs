import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const probe = path.join(root, "scripts", "release", "probe-m8-i6-packaged-worker-crash.mjs");
const operationId = "81234567-89ab-4def-8123-456789abcdef";

test("observes exact crash wire/state and proves daemon, lane, working-copy, and cleanup survival", async () => {
  const fixture = await createFixture({});
  try {
    const result = run(fixture.args);
    assert.equal(result.status, 0, result.stderr || result.stdout);
    assert.equal(result.stderr, "");
    const report = JSON.parse(result.stdout);
    assert.deepEqual(report, {
      schema: "subversionr.release.m8-i6-packaged-native-worker-crash.v1",
      status: "passed",
      cell: "workerCrash",
      surface: "packaged-native",
      stableCode: "SUBVERSIONR_REMOTE_WORKER_CRASHED",
      reason: "workerContainmentFailed",
      protocol: { major: 1, minor: 35 },
      settlement: {
        code: "SUBVERSIONR_REMOTE_WORKER_CRASHED", category: "process",
        messageKey: "error.remote.workerCrashed", retryable: false,
        safeArgs: { stage: "workerProcess", remoteFailure: { category: "process", reason: "workerContainmentFailed", cleanupAppropriate: false } },
        diagnostics: null,
      },
      daemonState: { kind: "indeterminate", reason: "workerTerminated", originOperationIdMatched: true, recovery: "notRequired", cleanupAppropriate: false },
      workerCrashSettlement: {
        trigger: "external-worker-termination-after-greeting", terminationExitCode: 1_398_166_083,
        workerIdentityBound: true, workerTerminationObserved: true, wireSettlementObserved: true,
        daemonSurvived: true, nativeLaneReleased: true, localSnapshotAfterCrash: true, workingCopyPreserved: true,
      },
      remoteSvnAnonymous: true,
      credentialRequests: 0,
      credentialSettlements: 0,
      certificateRequests: 0,
      temporaryRootsAfter: 0,
      diagnosticsRedacted: true,
      fixtureCliInvocations: 0,
    });
    for (const secret of [fixture.repositoryUrl, fixture.workingCopyPath, fixture.profileRoot, fixture.fixtureStatePath, operationId]) {
      assert.equal(result.stdout.toLowerCase().includes(secret.toLowerCase()), false);
    }
    const capture = JSON.parse(await readFile(fixture.capturePath, "utf8"));
    assert.deepEqual(capture.methods, ["repository/open", "status/checkRemote", "status/getSnapshot", "diagnostics/get", "repository/close"]);
    assert.equal(capture.shutdown, true);
    assert.equal(capture.remote.operationId, operationId);
    assert.equal(capture.remote.timeoutMs, 30_000);
    assert.equal(capture.remote.profile.profileId, "m8-i6-loopback-anonymous-worker-crash");
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("rejects non-exact wire settlement and daemon state", async () => {
  const cases = [
    [{ code: "SUBVERSIONR_REMOTE_WORKER_PROTOCOL_INVALID" }, "SUBVERSIONR_I6_PACKAGED_WORKER_CRASH_WIRE_INVALID"],
    [{ stage: "supervisor" }, "SUBVERSIONR_I6_PACKAGED_WORKER_CRASH_WIRE_INVALID"],
    [{ failureReason: "unknownRemote" }, "SUBVERSIONR_I6_PACKAGED_WORKER_CRASH_FAILURE_INVALID"],
    [{ recovery: "pending" }, "SUBVERSIONR_I6_PACKAGED_WORKER_CRASH_STATE_TIMEOUT"],
    [{ duplicateTerminal: true }, "SUBVERSIONR_I6_PACKAGED_WORKER_CRASH_STATE_INVALID"],
  ];
  for (const [behavior, expected] of cases) {
    const fixture = await createFixture(behavior);
    try { assertFailure(run(fixture.args), expected, JSON.stringify(behavior)); }
    finally { await rm(fixture.root, { recursive: true, force: true }); }
  }
});

test("rejects non-exact CLI, fresh fixture, local lane, trust, redaction, and working-copy proof", async () => {
  const fixture = await createFixture({});
  try {
    assertFailure(run([...fixture.args, "--extra", "x"]), "SUBVERSIONR_I6_PACKAGED_WORKER_CRASH_ARGUMENT_INVALID");
    assertFailure(run(replace(fixture.args, "--operation-id", "00000000-0000-0000-0000-000000000000")), "SUBVERSIONR_I6_PACKAGED_WORKER_CRASH_ARGUMENT_INVALID");
    assertFailure(run(replace(fixture.args, "--repository-url", "svn://localhost:43690/repo")), "SUBVERSIONR_I6_PACKAGED_WORKER_CRASH_URL_INVALID");
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
  const cases = [
    [{ initialConnections: 1 }, "SUBVERSIONR_I6_PACKAGED_WORKER_CRASH_FIXTURE_STATE_INVALID"],
    [{ snapshotSource: "libsvn-remote" }, "SUBVERSIONR_I6_PACKAGED_WORKER_CRASH_LOCAL_SNAPSHOT_INVALID"],
    [{ trustDrops: true }, "SUBVERSIONR_I6_PACKAGED_WORKER_CRASH_TRUST_INVALID"],
    [{ diagnosticsLeak: true }, "SUBVERSIONR_I6_PACKAGED_WORKER_CRASH_DIAGNOSTICS_LEAK"],
    [{ tamperWc: true }, "SUBVERSIONR_I6_PACKAGED_WORKER_CRASH_WORKING_COPY_INVALID"],
  ];
  for (const [behavior, expected] of cases) {
    const candidate = await createFixture(behavior);
    try { assertFailure(run(candidate.args), expected, JSON.stringify(behavior)); }
    finally { await rm(candidate.root, { recursive: true, force: true }); }
  }
});

async function createFixture(behavior) {
  const fixtureRoot = await mkdtemp(path.join(os.tmpdir(), "subversionr-i6-worker-crash-test-"));
  const tooling = path.join(fixtureRoot, "tooling");
  const backendRoot = path.join(tooling, "dist", "backend");
  const securityRoot = path.join(tooling, "dist", "security");
  const profileRoot = path.join(fixtureRoot, "profile");
  const workingCopyPath = path.join(fixtureRoot, "wc");
  const fixtureStatePath = path.join(fixtureRoot, "fault-state.json");
  const capturePath = path.join(fixtureRoot, "capture.json");
  await mkdir(backendRoot, { recursive: true });
  await mkdir(securityRoot, { recursive: true });
  await mkdir(profileRoot);
  await mkdir(path.join(workingCopyPath, ".svn"), { recursive: true });
  await writeFile(path.join(workingCopyPath, ".svn", "wc.db"), "worker-crash-wc-db", "utf8");
  await writeFile(path.join(workingCopyPath, "tracked.txt"), "preserved\n", "utf8");
  const repositoryUrl = "svn://127.0.0.1:43690/repo";
  await writeFile(fixtureStatePath, JSON.stringify(state({ connections: behavior.initialConnections ?? 0 })), "utf8");
  const daemon = path.join(tooling, "subversionr-daemon.exe");
  const bridge = path.join(tooling, "subversionr-native.dll");
  await writeFile(daemon, "daemon", "utf8");
  await writeFile(bridge, "bridge", "utf8");
  await writeFile(path.join(securityRoot, "remoteAccessProfile.js"), remoteAccessSource(), "utf8");
  await writeFile(path.join(backendRoot, "backendProcess.js"), backendSource({ behavior, fixtureStatePath, capturePath, repositoryUrl, workingCopyPath }), "utf8");
  return {
    root: fixtureRoot, profileRoot, workingCopyPath, fixtureStatePath, capturePath, repositoryUrl,
    args: [
      "--backend-module", path.join(backendRoot, "backendProcess.js"), "--daemon", daemon, "--bridge", bridge,
      "--profile-root", profileRoot, "--working-copy-path", workingCopyPath, "--repository-url", repositoryUrl,
      "--operation-id", operationId, "--fixture-state-path", fixtureStatePath,
    ],
  };
}

function backendSource(input) {
  return `
const fs = require("node:fs");
const behavior = ${JSON.stringify(input.behavior)};
const fixtureStatePath = ${JSON.stringify(input.fixtureStatePath)};
const capturePath = ${JSON.stringify(input.capturePath)};
const repositoryUrl = ${JSON.stringify(input.repositoryUrl)};
const workingCopyPath = ${JSON.stringify(input.workingCopyPath)};
exports.startBackendProcess = async function(config, handlers) {
  const capture = { methods: [], shutdown: false };
  let remoteEnabled = true;
  const connection = {
    initializeResult: { protocol: { major: 1, minor: 35 }, capabilities: { realLibsvnBridge: true, repositoryOpen: true, repositoryClose: true, statusSnapshot: true, statusRemoteCheck: true, remoteOperationEnvelope: true, remoteWorkerIsolation: true, remoteConnectionState: true, remoteSvnAnonymous: true, diagnosticsGet: true }, acknowledgedTrustEpoch: 7 },
    isRemoteSubmissionEnabled: () => remoteEnabled,
    currentRemoteTrustEpoch: () => 7,
    sendRequest: async (method, params) => {
      capture.methods.push(method);
      if (method === "repository/open") return { repositoryId: "repo-worker-crash", epoch: 7, identity: { workingCopyRoot: workingCopyPath, repositoryRootUrl: repositoryUrl } };
      if (method === "status/checkRemote") {
        capture.remote = params.remote;
        fs.writeFileSync(fixtureStatePath, JSON.stringify((${state.toString()})({ connections: 1, greetingSent: 1, clientResponseReceived: 1 })));
        handlers.notificationHandler("remoteConnection/state", { repositoryId: "repo-worker-crash", epoch: 7, state: { kind: "checking", operationId: params.remote.operationId, startedAt: "2026-07-20T00:00:00Z" } });
        const terminal = { kind: "indeterminate", reason: "workerTerminated", originOperationId: params.remote.operationId, recovery: behavior.recovery || "notRequired", cleanupAppropriate: false };
        handlers.notificationHandler("remoteConnection/state", { repositoryId: "repo-worker-crash", epoch: 7, state: terminal });
        if (behavior.duplicateTerminal) handlers.notificationHandler("remoteConnection/state", { repositoryId: "repo-worker-crash", epoch: 7, state: terminal });
        const safeArgs = { stage: behavior.stage || "workerProcess", remoteFailure: { category: "process", reason: behavior.failureReason || "workerContainmentFailed", cleanupAppropriate: false } };
        const error = { name: "JsonRpcStreamError", code: behavior.code || "SUBVERSIONR_REMOTE_WORKER_CRASHED", category: "process", messageKey: "error.remote.workerCrashed", retryable: false, diagnostics: null, safeArgs };
        throw error;
      }
      if (method === "status/getSnapshot") {
        if (behavior.trustDrops) remoteEnabled = false;
        if (behavior.tamperWc) fs.writeFileSync(require("node:path").join(workingCopyPath, ".svn", "wc.db"), "worker-crash-wc-dX");
        return { repositoryId: "repo-worker-crash", epoch: 7, source: behavior.snapshotSource || "libsvn-local", completeness: "complete" };
      }
      if (method === "diagnostics/get") return { source: "subversionr-daemon", protocol: { major: 1, minor: 35 }, capabilities: { remoteSvnAnonymous: true, statusRemoteCheck: true, statusSnapshot: true }, ...(behavior.diagnosticsLeak ? { leak: workingCopyPath } : {}) };
      if (method === "repository/close") return { repositoryId: "repo-worker-crash", epoch: 7, closed: true };
      throw new Error("unexpected method");
    },
    shutdown: async () => { capture.shutdown = true; fs.writeFileSync(capturePath, JSON.stringify(capture)); },
    dispose: () => fs.writeFileSync(capturePath, JSON.stringify(capture)),
  };
  return connection;
};`;
}

function remoteAccessSource() {
  return `
exports.canonicalEndpointFromRepositoryUrl = (value) => { const url = new URL(value); return { scheme: "svn", canonicalHost: url.hostname, effectivePort: Number(url.port || 3690) }; };
exports.RemoteOperationEnvelopeFactory = class { constructor(options) { this.options = options; } createAnonymousSvn(input) { return { version: 1, operationId: input.operationId, intent: input.intent, interaction: input.interaction, timeoutMs: input.timeoutMs, workspaceTrust: "trusted", trustEpoch: this.options.currentRemoteTrustEpoch(), profile: input.profile, expectedOrigin: input.expectedOrigin }; } };`;
}

function state(overrides = {}) {
  return { schema: "subversionr.release.m8-i6-ra-svn-fault-fixture.v1", pid: 1234, port: 43690, suppliedAuthorityPort: 0, scenario: "greeting-stall", status: "ready", connections: 0, suppliedAuthorityConnections: 0, greetingSent: 0, clientResponseReceived: 0, authRequestSent: 0, reposInfoSent: 0, commandsReceived: 0, followupContacts: 0, ...overrides };
}

function run(args) { return spawnSync(process.execPath, [probe, ...args], { encoding: "utf8", timeout: 15_000 }); }
function assertFailure(result, expected, label = "") { assert.notEqual(result.status, 0, label); const report = JSON.parse(result.stdout); assert.equal(report.status, "failed", label); assert.equal(report.error.code, expected, `${label}\n${result.stdout}\n${result.stderr}`); }
function replace(args, name, value) { const copy = [...args]; copy[copy.indexOf(name) + 1] = value; return copy; }
