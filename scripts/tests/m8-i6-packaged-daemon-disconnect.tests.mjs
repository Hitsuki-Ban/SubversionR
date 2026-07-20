import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const probe = path.join(root, "scripts", "release", "probe-m8-i6-packaged-daemon-disconnect.mjs");
const operationId = "91234567-89ab-4def-8123-456789abcdef";

test("uses production shutdown after the greeting gate and observes exact settlement/state before ack", async () => {
  const fixture = await createFixture({});
  try {
    const execution = run(fixture.args);
    await waitFor(() => readState(fixture.fixtureStatePath).then((value) => value.clientResponseReceived === 1));
    await writeFile(fixture.shutdownTriggerPath, "", { flag: "wx" });
    const result = await execution;
    assert.equal(result.status, 0, result.stderr || result.stdout);
    assert.equal(result.stderr, "");
    assert.deepEqual(JSON.parse(result.stdout), {
      schema: "subversionr.release.m8-i6-packaged-native-daemon-disconnect.v1",
      status: "passed",
      cell: "daemonDisconnect",
      surface: "packaged-native",
      stableCode: "SUBVERSIONR_REMOTE_WORKER_DISCONNECTED",
      reason: "workerContainmentFailed",
      protocol: { major: 1, minor: 35 },
      settlement: {
        code: "SUBVERSIONR_REMOTE_WORKER_DISCONNECTED", category: "state",
        messageKey: "error.remote.workerDisconnected", retryable: false,
        safeArgs: { remoteFailure: { category: "process", reason: "workerContainmentFailed", cleanupAppropriate: false } },
        diagnostics: null,
      },
      daemonState: { kind: "indeterminate", reason: "workerTerminated", originOperationIdMatched: true, recovery: "notRequired", cleanupAppropriate: false },
      daemonDisconnectSettlement: {
        trigger: "graceful-client-shutdown-after-greeting", activeRequestSettlementObserved: true,
        daemonStateObserved: true, settlementBeforeShutdownAck: true, shutdownAcknowledged: true,
        workingCopyPreserved: true,
      },
      remoteSvnAnonymous: true,
      credentialRequests: 0,
      credentialSettlements: 0,
      certificateRequests: 0,
      temporaryRootsAfter: 0,
      diagnosticsRedacted: true,
      fixtureCliInvocations: 0,
    });
    const capture = JSON.parse(await readFile(fixture.capturePath, "utf8"));
    assert.deepEqual(capture.methods, ["repository/open", "status/checkRemote", "shutdown"]);
    assert.deepEqual(capture.order, ["activeRequestSettlement", "daemonState", "shutdownAck"]);
    assert.equal(capture.shutdown, true);
    assert.equal(capture.remote.operationId, operationId);
  } finally { await rm(fixture.root, { recursive: true, force: true }); }
});

test("rejects shutdown ack before active settlement or daemon state", async () => {
  for (const behavior of [{ ackFirst: true }]) {
    const fixture = await createFixture(behavior);
    try {
      const execution = run(fixture.args);
      await waitFor(() => readState(fixture.fixtureStatePath).then((value) => value.clientResponseReceived === 1));
      await writeFile(fixture.shutdownTriggerPath, "", { flag: "wx" });
      const result = await execution;
      assert.notEqual(result.status, 0, JSON.stringify(behavior));
      const report = JSON.parse(result.stdout);
      assert.equal(report.status, "failed");
      assert.equal(report.error.code, "SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_ORDER_INVALID");
    } finally { await rm(fixture.root, { recursive: true, force: true }); }
  }
});

test("rejects non-exact disconnect and dirty trigger preflight", async () => {
  for (const behavior of [{ code: "SUBVERSIONR_REMOTE_WORKER_CANCELLED" }, { reason: "operationCancelled" }]) {
    const fixture = await createFixture(behavior);
    try {
      const execution = run(fixture.args);
      await waitFor(() => readState(fixture.fixtureStatePath).then((value) => value.clientResponseReceived === 1));
      await writeFile(fixture.shutdownTriggerPath, "", { flag: "wx" });
      const result = await execution;
      assert.notEqual(result.status, 0);
      const code = JSON.parse(result.stdout).error.code;
      assert.equal(code, behavior.code ? "SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_WIRE_INVALID" : "SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_FAILURE_INVALID");
    } finally { await rm(fixture.root, { recursive: true, force: true }); }
  }

  const dirty = await createFixture({});
  try {
    await writeFile(dirty.shutdownTriggerPath, "");
    const result = await run(dirty.args);
    assert.notEqual(result.status, 0);
    assert.equal(JSON.parse(result.stdout).error.code, "SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_TRIGGER_INVALID");
  } finally { await rm(dirty.root, { recursive: true, force: true }); }
});

test("disposes the daemon-state observation when backend startup fails", async () => {
  const fixture = await createFixture({ startFailure: true });
  try {
    const startedAt = Date.now();
    const result = await run(fixture.args);
    assert.notEqual(result.status, 0);
    assert.ok(Date.now() - startedAt < 5_000, "the failed probe retained its 30-second observation timer");
    assert.equal(
      JSON.parse(result.stdout).error.code,
      "SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_START_FAILED",
    );
  } finally { await rm(fixture.root, { recursive: true, force: true }); }
});

async function createFixture(behavior) {
  const fixtureRoot = await mkdtemp(path.join(os.tmpdir(), "subversionr-i6-daemon-disconnect-test-"));
  const tooling = path.join(fixtureRoot, "tooling");
  const backendRoot = path.join(tooling, "dist", "backend");
  const securityRoot = path.join(tooling, "dist", "security");
  const profileRoot = path.join(fixtureRoot, "profile");
  const workingCopyPath = path.join(fixtureRoot, "wc");
  const fixtureStatePath = path.join(fixtureRoot, "fault-state.json");
  const shutdownTriggerPath = path.join(fixtureRoot, "shutdown.trigger");
  const capturePath = path.join(fixtureRoot, "capture.json");
  await mkdir(backendRoot, { recursive: true });
  await mkdir(securityRoot, { recursive: true });
  await mkdir(profileRoot);
  await mkdir(path.join(workingCopyPath, ".svn"), { recursive: true });
  await writeFile(path.join(workingCopyPath, ".svn", "wc.db"), "daemon-disconnect-wc-db");
  await writeFile(path.join(workingCopyPath, "tracked.txt"), "preserved\n");
  const repositoryUrl = "svn://127.0.0.1:43691/repo";
  await writeFile(fixtureStatePath, JSON.stringify(state()));
  const daemon = path.join(tooling, "subversionr-daemon.exe");
  const bridge = path.join(tooling, "subversionr-native.dll");
  await writeFile(daemon, "daemon");
  await writeFile(bridge, "bridge");
  await writeFile(path.join(securityRoot, "remoteAccessProfile.js"), remoteAccessSource());
  await writeFile(path.join(backendRoot, "backendProcess.js"), backendSource({ behavior, fixtureStatePath, capturePath, repositoryUrl, workingCopyPath }));
  return {
    root: fixtureRoot, fixtureStatePath, shutdownTriggerPath, capturePath,
    args: [
      "--backend-module", path.join(backendRoot, "backendProcess.js"), "--daemon", daemon, "--bridge", bridge,
      "--profile-root", profileRoot, "--working-copy-path", workingCopyPath, "--repository-url", repositoryUrl,
      "--operation-id", operationId, "--fixture-state-path", fixtureStatePath,
      "--shutdown-trigger-path", shutdownTriggerPath,
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
  if (behavior.startFailure) throw new Error("SUBVERSIONR_I6_PACKAGED_DAEMON_DISCONNECT_START_FAILED");
  const capture = { methods: [], order: [], shutdown: false };
  let rejectRemote;
  const pendingRemote = new Promise((_, reject) => { rejectRemote = reject; });
  const save = () => fs.writeFileSync(capturePath, JSON.stringify(capture));
  const connection = {
    initializeResult: { protocol: { major: 1, minor: 35 }, capabilities: { realLibsvnBridge: true, repositoryOpen: true, statusRemoteCheck: true, remoteOperationEnvelope: true, remoteWorkerIsolation: true, remoteConnectionState: true, remoteSvnAnonymous: true }, acknowledgedTrustEpoch: 7 },
    isRemoteSubmissionEnabled: () => true,
    currentRemoteTrustEpoch: () => 7,
    sendRequest: async (method, params) => {
      capture.methods.push(method);
      if (method === "repository/open") return { repositoryId: "repo-daemon-disconnect", epoch: 7, identity: { workingCopyRoot: workingCopyPath, repositoryRootUrl: repositoryUrl } };
      if (method === "status/checkRemote") {
        capture.remote = params.remote;
        fs.writeFileSync(fixtureStatePath, JSON.stringify((${state.toString()})({ connections: 1, greetingSent: 1, clientResponseReceived: 1 })));
        handlers.notificationHandler("remoteConnection/state", { repositoryId: "repo-daemon-disconnect", epoch: 7, state: { kind: "checking", operationId: params.remote.operationId, startedAt: "2026-07-20T00:00:00Z" } });
        return pendingRemote;
      }
      throw new Error("unexpected method");
    },
    shutdown: async () => {
      capture.methods.push("shutdown"); capture.shutdown = true;
      const error = { name: "JsonRpcStreamError", code: behavior.code || "SUBVERSIONR_REMOTE_WORKER_DISCONNECTED", category: "state", messageKey: "error.remote.workerDisconnected", retryable: false, diagnostics: null, safeArgs: { remoteFailure: { category: "process", reason: behavior.reason || "workerContainmentFailed", cleanupAppropriate: false } } };
      const stateValue = { kind: "indeterminate", reason: "workerTerminated", originOperationId: capture.remote.operationId, recovery: "notRequired", cleanupAppropriate: false };
      if (behavior.ackFirst) {
        capture.order.push("shutdownAck"); save();
        setTimeout(() => {
          capture.order.push("activeRequestSettlement"); rejectRemote(error);
          capture.order.push("daemonState"); handlers.notificationHandler("remoteConnection/state", { repositoryId: "repo-daemon-disconnect", epoch: 7, state: stateValue }); save();
        }, 5);
        return;
      }
      capture.order.push("activeRequestSettlement"); rejectRemote(error);
      if (!behavior.omitState) { capture.order.push("daemonState"); handlers.notificationHandler("remoteConnection/state", { repositoryId: "repo-daemon-disconnect", epoch: 7, state: stateValue }); }
      await new Promise((resolve) => setImmediate(resolve));
      capture.order.push("shutdownAck"); save();
    },
    dispose: save,
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
  return { schema: "subversionr.release.m8-i6-ra-svn-fault-fixture.v1", pid: 1234, port: 43691, suppliedAuthorityPort: 0, scenario: "greeting-stall", status: "ready", connections: 0, suppliedAuthorityConnections: 0, greetingSent: 0, clientResponseReceived: 0, authRequestSent: 0, reposInfoSent: 0, commandsReceived: 0, followupContacts: 0, ...overrides };
}
async function readState(file) { return JSON.parse(await readFile(file, "utf8")); }
async function waitFor(check) {
  const deadline = Date.now() + 5_000;
  while (!(await check())) { if (Date.now() >= deadline) throw new Error("condition timeout"); await new Promise((resolve) => setTimeout(resolve, 10)); }
}
function run(args) {
  const child = spawn(process.execPath, [probe, ...args], { stdio: ["ignore", "pipe", "pipe"] });
  let stdout = ""; let stderr = "";
  child.stdout.setEncoding("utf8"); child.stderr.setEncoding("utf8");
  child.stdout.on("data", (chunk) => { stdout += chunk; }); child.stderr.on("data", (chunk) => { stderr += chunk; });
  return new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("close", (status, signal) => resolve({ status, signal, stdout, stderr }));
  });
}
