import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const probe = path.join(repositoryRoot, "scripts", "release", "probe-m8-i6-packaged-recovery-safe.mjs");
const schema = "subversionr.release.m8-i6-packaged-native-recovery-safe.v1";
const originOperationId = "12345678-1234-4abc-8def-1234567890ab";
const recoveryOperationId = "22345678-1234-4abc-8def-1234567890ab";

test("proves timeout-pending to local Safe recovery without a second network contact", async () => {
  const fixture = await createFixture({ delayedUnchecked: true });
  try {
    const result = runProbe(fixture.args);
    assert.equal(result.status, 0, result.stderr || result.stdout);
    assert.equal(result.stderr, "");
    assert.deepEqual(JSON.parse(result.stdout), passed());
    for (const sensitive of [
      fixture.repositoryUrl,
      fixture.workingCopyPath,
      fixture.profileRoot,
      fixture.fixtureStatePath,
      originOperationId,
      recoveryOperationId,
    ]) {
      assert.equal(result.stdout.toLowerCase().includes(sensitive.toLowerCase()), false);
    }

    const capture = JSON.parse(await readFile(fixture.capturePath, "utf8"));
    assert.deepEqual(capture.methods, [
      "repository/open",
      "status/getSnapshot",
      "operation/run",
      "remote/recoverWorkingCopy",
      "status/refresh",
      "status/getSnapshot",
      "diagnostics/get",
      "repository/close",
    ]);
    assert.equal(capture.shutdown, true);
    assert.equal(capture.config.clientName, "subversionr-m8-i6-packaged-recovery-safe-evidence");
    assert.equal(capture.config.workspaceTrust, "trusted");
    assert.equal(capture.config.appdata, fixture.profileRoot);
    assert.equal(capture.config.temp, fixture.profileRoot);
    assert.deepEqual(capture.requests[1], {
      method: "status/getSnapshot",
      params: { repositoryId: fixture.repositoryId, epoch: 7 },
    });
    const origin = capture.requests[2].params;
    assert.deepEqual(Object.keys(origin), ["repositoryId", "epoch", "kind", "options", "remote"]);
    assert.equal(origin.kind, "update");
    assert.deepEqual(origin.options, {
      version: 1,
      path: ".",
      revision: "head",
      depth: "infinity",
      depthIsSticky: false,
      ignoreExternals: true,
    });
    assertEnvelope(origin.remote, fixture.endpoint, originOperationId, 500);
    assert.deepEqual(capture.requests[3], {
      method: "remote/recoverWorkingCopy",
      params: {
        repositoryId: fixture.repositoryId,
        epoch: 7,
        originOperationId,
        operationId: recoveryOperationId,
        timeoutMs: 300_000,
      },
    });
    assert.deepEqual(capture.requests[4], {
      method: "status/refresh",
      params: {
        repositoryId: fixture.repositoryId,
        epoch: 7,
        targets: [{ path: ".", depth: "infinity", reason: "manualFullReconcile" }],
      },
    });
    assert.deepEqual(capture.requests[5], {
      method: "status/getSnapshot",
      params: { repositoryId: fixture.repositoryId, epoch: 7 },
    });
    assert.deepEqual(JSON.parse(await readFile(fixture.fixtureStatePath, "utf8")), commandFixtureState());
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("rejects non-exact timeout errors and remote-failure attribution", async () => {
  const cases = [
    [{ originCode: "SUBVERSIONR_REMOTE_WORKER_CANCELLED" }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_ORIGIN_INVALID"],
    [{ originCategory: "cancelled" }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_ORIGIN_INVALID"],
    [{ originMessageKey: "error.remote.workerCancelled" }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_ORIGIN_INVALID"],
    [{ originRetryable: true }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_ORIGIN_INVALID"],
    [{ originDiagnostics: {} }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_ORIGIN_INVALID"],
    [{ originSafeArgExtra: true }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_ORIGIN_INVALID"],
    [{ originFailureCategory: "cancellation" }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_ORIGIN_FAILURE_INVALID"],
    [{ originFailureReason: "operationCancelled" }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_ORIGIN_FAILURE_INVALID"],
    [{ originCleanupAppropriate: true }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_ORIGIN_FAILURE_INVALID"],
  ];
  for (const [behavior, code] of cases) {
    await expectFailure(behavior, code);
  }
});

test("rejects missing or cross-attributed pending and Safe notifications", async () => {
  const cases = [
    [{ omitPending: true }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_NOTIFICATION_TIMEOUT"],
    [{ pendingOriginOperationId: recoveryOperationId }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_NOTIFICATION_TIMEOUT"],
    [{ pendingReason: "cancelledAfterMutation" }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_PENDING_INVALID"],
    [{ pendingCleanupAppropriate: true }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_PENDING_INVALID"],
    [{ pendingExtra: true }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_PENDING_INVALID"],
    [{ safeOutcome: "indeterminate" }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_SETTLEMENT_INVALID"],
    [{ safeOperationId: originOperationId }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_SETTLEMENT_INVALID"],
    [{ safeCompletedAt: "not-a-timestamp" }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_SETTLEMENT_INVALID"],
    [{ safeExtra: true }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_SETTLEMENT_INVALID"],
    [{ staleReason: "operationUpdateFailed" }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_NOTIFICATION_TIMEOUT"],
    [{ staleSource: "remote-worker" }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_STALE_INVALID"],
    [{ staleExtra: true }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_STALE_INVALID"],
    [{ omitUnchecked: true }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_LANE_RELEASE_INVALID"],
    [{ uncheckedExtra: true }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_LANE_RELEASE_INVALID"],
  ];
  for (const [behavior, code] of cases) {
    await expectFailure(behavior, code);
  }
});

test("rejects non-fresh local status, auth activity, residue, diagnostics leaks, and follow-up network contact", async () => {
  const cases = [
    [{ baselineCompleteness: "targeted" }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_BASELINE_STATUS_INVALID"],
    [{ baselineSource: "remote-worker" }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_BASELINE_STATUS_INVALID"],
    [{ reconcileCompleteness: "targeted" }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_RECONCILE_INVALID"],
    [{ reconcileSource: "remote-worker" }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_RECONCILE_INVALID"],
    [{ snapshotCompleteness: "targeted" }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_SUBSEQUENT_STATUS_INVALID"],
    [{ snapshotSource: "remote-worker" }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_SUBSEQUENT_STATUS_INVALID"],
    [{ credentialRequest: true }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_CREDENTIAL_HANDLER_INVOKED"],
    [{ trustEpochAfterOrigin: 8 }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_TRUST_INVALID"],
    [{ workerResidue: true }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_WORKER_TEMP_RESIDUE"],
    [{ journalEntry: true }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_JOURNAL_INVALID"],
    [{ journalTemp: true }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_JOURNAL_RESIDUE"],
    [{ diagnosticsLeak: "repository" }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_DIAGNOSTICS_LEAK"],
    [{ diagnosticsLeak: "operation" }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_DIAGNOSTICS_LEAK"],
    [{ followupNetworkContact: true }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_FOLLOWUP_NETWORK_CONTACT"],
    [{ closeFalse: true }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_CLOSE_INVALID"],
    [{ protocolMinor: 34 }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_CAPABILITY_INVALID"],
    [{ operationRunUpdate: false }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_CAPABILITY_INVALID"],
  ];
  for (const [behavior, code] of cases) {
    await expectFailure(behavior, code);
  }
});

test("rejects no-advance reconcile, stale snapshot, and reconcile generation mismatch", async () => {
  const cases = [
    [{ reconcileGeneration: 1 }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_RECONCILE_INVALID"],
    [{ snapshotGeneration: 1 }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_SUBSEQUENT_STATUS_INVALID"],
    [{ snapshotGeneration: 4 }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_SUBSEQUENT_STATUS_INVALID"],
  ];
  for (const [behavior, code] of cases) {
    await expectFailure(behavior, code);
  }
});

test("fails closed when user content or the working-copy database changes at any recovery boundary", async () => {
  const cases = [
    [{ modifyUserContentAt: "recovery" }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_USER_CONTENT_CHANGED"],
    [{ deleteUserContentAt: "local" }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_USER_CONTENT_CHANGED"],
    [{ modifyUserContentAt: "shutdown" }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_USER_CONTENT_CHANGED"],
    [{ deleteWcDatabaseAt: "recovery" }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_WC_DATABASE_INVALID"],
    [{ emptyWcDatabaseAt: "local" }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_WC_DATABASE_INVALID"],
    [{ deleteWcDatabaseAt: "shutdown" }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_WC_DATABASE_INVALID"],
  ];
  for (const [behavior, code] of cases) {
    await expectFailure(behavior, code);
  }
});

test("rejects non-exact fixture input and command-stage state", async () => {
  const cases = [
    [{ initialConnections: 1 }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_FIXTURE_STATE_INVALID"],
    [{ commandAuthRequestSent: 0 }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_FIXTURE_STATE_INVALID"],
    [{ commandCount: 2 }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_FIXTURE_STATE_INVALID"],
    [{ suppliedAuthorityConnections: 1 }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_FIXTURE_STATE_INVALID"],
    [{ fixtureExtra: true }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_FIXTURE_STATE_INVALID"],
  ];
  for (const [behavior, code] of cases) {
    await expectFailure(behavior, code);
  }
});

test("rejects non-exact CLI, fixed timeout violations, unsafe IDs, URLs, and filesystem inputs", async () => {
  const fixture = await createFixture({});
  try {
    const argumentCases = [
      [...fixture.args, "--extra", "value"],
      replaceValue(fixture.args, "--origin-timeout-ms", "0500"),
      replaceValue(fixture.args, "--origin-timeout-ms", "501"),
      replaceValue(fixture.args, "--recovery-timeout-ms", "299999"),
      replaceValue(fixture.args, "--origin-operation-id", recoveryOperationId),
      replaceValue(fixture.args, "--origin-operation-id", "12345678-1234-4ABC-8def-1234567890ab"),
      replaceValue(fixture.args, "--origin-operation-id", "00000000-0000-0000-0000-000000000000"),
      replaceValue(fixture.args, "--repository-url", "svn://localhost:43690/repo/trunk"),
      replaceValue(fixture.args, "--repository-url", "svn://127.0.0.1:43690/repo"),
      replaceValue(fixture.args, "--repository-url", "svn://user@127.0.0.1:43690/repo/trunk"),
      replaceValue(fixture.args, "--profile-root", "relative-profile"),
    ];
    for (const args of argumentCases) {
      const result = runProbe(args);
      assert.equal(result.status, 1);
      assert.equal(JSON.parse(result.stdout).status, "failed");
      assert.equal(result.stderr, "");
    }
    await writeFile(path.join(fixture.profileRoot, "not-empty"), "x", "utf8");
    const nonEmpty = runProbe(fixture.args);
    assert.equal(nonEmpty.status, 1);
    assert.deepEqual(JSON.parse(nonEmpty.stdout), failed("SUBVERSIONR_I6_PACKAGED_RECOVERY_SAFE_FILESYSTEM_INVALID"));
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

async function expectFailure(behavior, code) {
  const fixture = await createFixture(behavior);
  try {
    const result = runProbe(fixture.args);
    assert.equal(result.status, 1, result.stdout);
    assert.deepEqual(JSON.parse(result.stdout), failed(code));
    assert.equal(result.stderr, "");
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
}

async function createFixture(behavior) {
  const root = await mkdtemp(path.join(os.tmpdir(), "subversionr-i6-packaged-recovery-safe-test-"));
  const tooling = path.join(root, "tooling");
  const backendRoot = path.join(tooling, "dist", "backend");
  const securityRoot = path.join(tooling, "dist", "security");
  const profileRoot = path.join(root, "profile");
  const workingCopyPath = path.join(root, "wc");
  const fixtureStatePath = path.join(root, "fault-state.json");
  const repositoryUrl = "svn://127.0.0.1:43690/repo/trunk";
  await mkdir(backendRoot, { recursive: true });
  await mkdir(securityRoot, { recursive: true });
  await mkdir(profileRoot);
  await mkdir(path.join(workingCopyPath, ".svn"), { recursive: true });
  await writeFile(path.join(workingCopyPath, ".svn", "wc.db"), "controlled-wc-database", "utf8");
  await writeFile(path.join(workingCopyPath, "tracked.txt"), "controlled content\n", "utf8");
  const initialState = initialFixtureState(behavior);
  await writeFile(fixtureStatePath, JSON.stringify(initialState), "utf8");
  const backendModule = path.join(backendRoot, "backendProcess.js");
  const remoteAccessModule = path.join(securityRoot, "remoteAccessProfile.js");
  const daemon = path.join(tooling, "subversionr-daemon.exe");
  const bridge = path.join(tooling, "subversionr-native.dll");
  await writeFile(
    backendModule,
    fakeBackendSource(behavior, profileRoot, workingCopyPath, repositoryUrl, fixtureStatePath),
    "utf8",
  );
  await writeFile(remoteAccessModule, fakeRemoteAccessSource(), "utf8");
  await writeFile(daemon, "fake-daemon", "utf8");
  await writeFile(bridge, "fake-bridge", "utf8");
  return {
    root,
    profileRoot,
    workingCopyPath,
    repositoryId: `12345678-1234-1234-1234-123456789abc:${workingCopyPath}`,
    fixtureStatePath,
    repositoryUrl,
    endpoint: { scheme: "svn", canonicalHost: "127.0.0.1", effectivePort: 43690 },
    capturePath: path.join(profileRoot, "remote-state", "capture.json"),
    args: [
      "--backend-module", backendModule,
      "--daemon", daemon,
      "--bridge", bridge,
      "--profile-root", profileRoot,
      "--working-copy-path", workingCopyPath,
      "--repository-url", repositoryUrl,
      "--fixture-state-path", fixtureStatePath,
      "--origin-operation-id", originOperationId,
      "--recovery-operation-id", recoveryOperationId,
      "--origin-timeout-ms", "500",
      "--recovery-timeout-ms", "300000",
    ],
  };
}

function fakeBackendSource(behavior, profileRoot, workingCopyPath, repositoryUrl, fixtureStatePath) {
  return `
const fs = require("node:fs");
const path = require("node:path");
const behavior = ${JSON.stringify(behavior)};
const profileRoot = ${JSON.stringify(profileRoot)};
const workingCopyPath = ${JSON.stringify(workingCopyPath)};
const repositoryUrl = ${JSON.stringify(repositoryUrl)};
const fixtureStatePath = ${JSON.stringify(fixtureStatePath)};
const originOperationId = ${JSON.stringify(originOperationId)};
const recoveryOperationId = ${JSON.stringify(recoveryOperationId)};
const repositoryId = "12345678-1234-1234-1234-123456789abc:" + workingCopyPath;
const trackedPath = path.join(workingCopyPath, "tracked.txt");
const wcDatabasePath = path.join(workingCopyPath, ".svn", "wc.db");
exports.startBackendProcess = async function startBackendProcess(config, handlers) {
  fs.mkdirSync(config.remoteStateRoot, { recursive: true });
  const capturePath = path.join(config.remoteStateRoot, "capture.json");
  const journalPath = path.join(config.remoteStateRoot, "subversionr-remote-checkout-mutations-v1.json");
  const journalTempPath = path.join(config.remoteStateRoot, ".subversionr-remote-checkout-mutations-v1.tmp");
  const workerRoot = path.join(profileRoot, "SubversionR", "remote-workers");
  fs.writeFileSync(journalPath, JSON.stringify({
    schemaVersion: 1,
    entries: behavior.journalEntry === true ? [{ state: "blocked" }] : [],
  }));
  if (behavior.journalTemp === true) fs.writeFileSync(journalTempPath, "orphan");
  if (behavior.workerResidue === true) fs.mkdirSync(path.join(workerRoot, "residue"), { recursive: true });
  const capture = {
    methods: [], requests: [], shutdown: false,
    config: {
      clientName: config.clientName,
      workspaceTrust: config.workspaceTrust,
      appdata: config.baseEnv.APPDATA,
      temp: config.baseEnv.TEMP,
    },
  };
  const save = () => fs.writeFileSync(capturePath, JSON.stringify(capture));
  const record = (method, params) => { capture.methods.push(method); capture.requests.push({ method, params }); save(); };
  const notify = (method, params) => handlers.notificationHandler(method, params);
  const mutateWorkingCopy = (phase) => {
    if (behavior.modifyUserContentAt === phase) fs.writeFileSync(trackedPath, "changed at " + phase + "\\n");
    if (behavior.deleteUserContentAt === phase) fs.rmSync(trackedPath);
    if (behavior.deleteWcDatabaseAt === phase) fs.rmSync(wcDatabasePath);
    if (behavior.emptyWcDatabaseAt === phase) fs.writeFileSync(wcDatabasePath, "");
  };
  save();
  return {
    initializeResult: {
      protocol: { major: 1, minor: behavior.protocolMinor ?? 35 },
      capabilities: {
        realLibsvnBridge: true,
        repositoryOpen: true,
        repositoryClose: true,
        statusSnapshot: true,
        statusRefresh: true,
        statusStaleNotification: true,
        operationRun: true,
        operationRunUpdate: behavior.operationRunUpdate ?? true,
        remoteOperationEnvelope: true,
        remoteWorkerIsolation: true,
        remoteConnectionState: true,
        remoteSvnAnonymous: true,
      },
      acknowledgedTrustEpoch: 7,
    },
    isRemoteSubmissionEnabled() { return true; },
    currentRemoteTrustEpoch() {
      return behavior.trustEpochAfterOrigin !== undefined && capture.methods.includes("operation/run")
        ? behavior.trustEpochAfterOrigin
        : 7;
    },
    async sendRequest(method, params) {
      record(method, params);
      if (method === "repository/open") return {
        repositoryId,
        epoch: 7,
        identity: { workingCopyRoot: workingCopyPath, repositoryRootUrl: "svn://127.0.0.1:43690/repo" },
      };
      if (method === "operation/run") {
        const current = JSON.parse(fs.readFileSync(fixtureStatePath, "utf8"));
        Object.assign(current, {
          connections: 1,
          greetingSent: 1,
          clientResponseReceived: 1,
          authRequestSent: behavior.commandAuthRequestSent ?? 1,
          reposInfoSent: 1,
          commandsReceived: behavior.commandCount ?? 1,
          suppliedAuthorityConnections: behavior.suppliedAuthorityConnections ?? 0,
        });
        fs.writeFileSync(fixtureStatePath, JSON.stringify(current));
        if (behavior.credentialRequest === true) {
          try { await handlers.requestHandler("credentials/request", {}); } catch {}
        }
        if (behavior.omitPending !== true) {
          const state = {
            kind: "indeterminate",
            reason: behavior.pendingReason ?? "workerTerminated",
            originOperationId: behavior.pendingOriginOperationId ?? originOperationId,
            recovery: "pending",
            cleanupAppropriate: behavior.pendingCleanupAppropriate ?? false,
            ...(behavior.pendingExtra === true ? { raw: workingCopyPath } : {}),
          };
          notify("remoteConnection/state", { repositoryId, epoch: 7, state });
        }
        const error = new Error(behavior.originCode ?? "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT");
        error.code = behavior.originCode ?? "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT";
        error.category = behavior.originCategory ?? "timeout";
        error.messageKey = behavior.originMessageKey ?? "error.remote.workerTimedOut";
        error.retryable = behavior.originRetryable ?? false;
        error.diagnostics = Object.hasOwn(behavior, "originDiagnostics") ? behavior.originDiagnostics : null;
        error.safeArgs = {
          remoteFailure: {
            category: behavior.originFailureCategory ?? "deadline",
            reason: behavior.originFailureReason ?? "operationDeadlineExceeded",
            cleanupAppropriate: behavior.originCleanupAppropriate ?? false,
          },
          ...(behavior.originSafeArgExtra === true ? { raw: repositoryUrl } : {}),
        };
        throw error;
      }
      if (behavior.followupNetworkContact === true && method === "remote/recoverWorkingCopy") {
        const current = JSON.parse(fs.readFileSync(fixtureStatePath, "utf8"));
        current.connections += 1; current.followupContacts += 1;
        fs.writeFileSync(fixtureStatePath, JSON.stringify(current));
      }
      if (method === "remote/recoverWorkingCopy") {
        notify("status/stale", {
          repositoryId,
          epoch: 7,
          reason: behavior.staleReason ?? "remoteRecoverySafeRequiresFullReconcile",
          timestamp: "2026-07-20T00:00:00.000Z",
          source: behavior.staleSource ?? "subversionr-daemon",
          ...(behavior.staleExtra === true ? { raw: repositoryUrl } : {}),
        });
        if (behavior.omitUnchecked !== true) {
          const emitUnchecked = () => notify("remoteConnection/state", {
              repositoryId,
              epoch: 7,
              state: { kind: "unchecked", ...(behavior.uncheckedExtra === true ? { raw: workingCopyPath } : {}) },
            });
          if (behavior.delayedUnchecked === true) setTimeout(emitUnchecked, 25);
          else emitUnchecked();
        }
        mutateWorkingCopy("recovery");
        return {
          outcome: behavior.safeOutcome ?? "safe",
          operationId: behavior.safeOperationId ?? recoveryOperationId,
          completedAt: behavior.safeCompletedAt ?? "2026-07-20T00:00:00.000Z",
          ...(behavior.safeExtra === true ? { raw: workingCopyPath } : {}),
        };
      }
      if (method === "status/refresh") return {
        repositoryId, epoch: 7, generation: behavior.reconcileGeneration ?? 2,
        completeness: behavior.reconcileCompleteness ?? "complete",
        source: behavior.reconcileSource ?? "libsvn-local",
      };
      if (method === "status/getSnapshot") {
        const snapshotRequestCount = capture.methods.filter((entry) => entry === "status/getSnapshot").length;
        if (snapshotRequestCount === 1) return {
          repositoryId, epoch: 7, generation: behavior.baselineGeneration ?? 1,
          completeness: behavior.baselineCompleteness ?? "complete",
          source: behavior.baselineSource ?? "libsvn-local",
        };
        mutateWorkingCopy("local");
        return {
          repositoryId, epoch: 7, generation: behavior.snapshotGeneration ?? 3,
          completeness: behavior.snapshotCompleteness ?? "complete",
          source: behavior.snapshotSource ?? "libsvn-local",
        };
      }
      if (method === "diagnostics/get") return {
        source: "subversionr-daemon",
        protocol: { major: 1, minor: 35 },
        capabilities: { remoteSvnAnonymous: true, statusRefresh: true, statusSnapshot: true },
        entries: [],
        ...(behavior.diagnosticsLeak === "repository" ? { leaked: repositoryUrl } : {}),
        ...(behavior.diagnosticsLeak === "operation" ? { leaked: originOperationId } : {}),
      };
      if (method === "repository/close") return {
        repositoryId, epoch: 7, closed: behavior.closeFalse !== true,
      };
      throw new Error("UNEXPECTED_METHOD");
    },
    async shutdown() { mutateWorkingCopy("shutdown"); capture.shutdown = true; save(); },
    dispose() { capture.disposed = true; save(); },
  };
};
`;
}

function fakeRemoteAccessSource() {
  return `
exports.canonicalEndpointFromRepositoryUrl = function(repositoryUrl) {
  const url = new URL(repositoryUrl);
  return { scheme: "svn", canonicalHost: url.hostname, effectivePort: Number(url.port) };
};
exports.RemoteOperationEnvelopeFactory = class {
  constructor(admission) { this.admission = admission; }
  createAnonymousSvn(input) {
    return {
      version: 1,
      operationId: input.operationId,
      intent: input.intent,
      interaction: input.interaction,
      timeoutMs: input.timeoutMs,
      workspaceTrust: "trusted",
      trustEpoch: this.admission.currentRemoteTrustEpoch(),
      profile: input.profile,
      expectedOrigin: input.expectedOrigin,
    };
  }
};
`;
}

function initialFixtureState(behavior = {}) {
  return {
    schema: "subversionr.release.m8-i6-ra-svn-fault-fixture.v1",
    pid: process.pid,
    port: 43690,
    suppliedAuthorityPort: 0,
    scenario: "command-stall",
    status: "ready",
    connections: behavior.initialConnections ?? 0,
    suppliedAuthorityConnections: behavior.suppliedAuthorityConnections ?? 0,
    greetingSent: 0,
    clientResponseReceived: 0,
    authRequestSent: 0,
    reposInfoSent: 0,
    commandsReceived: 0,
    followupContacts: 0,
    ...(behavior.fixtureExtra === true ? { raw: "unexpected" } : {}),
  };
}

function commandFixtureState() {
  return {
    ...initialFixtureState(),
    connections: 1,
    greetingSent: 1,
    clientResponseReceived: 1,
    authRequestSent: 1,
    reposInfoSent: 1,
    commandsReceived: 1,
  };
}

function passed() {
  return {
    schema,
    status: "passed",
    cell: "recoverySafe",
    surface: "packaged-native",
    stableCode: "none",
    reason: "none",
    settlementCode: "none",
    settlementReason: "none",
    protocol: { major: 1, minor: 35 },
    remoteSvnAnonymous: true,
    prerequisite: {
      code: "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT",
      reason: "operationDeadlineExceeded",
      recovery: "pending",
    },
    transitions: ["pending", "safe", "unchecked"],
    statusStaleReason: "remoteRecoverySafeRequiresFullReconcile",
    fixtureCountersUnchangedAfterPrerequisite: true,
    safe: {
      outcome: "Safe",
      freshReconcile: true,
      nativeLaneReleased: true,
      subsequentRequestPassed: true,
    },
    networkProgress: "command",
    networkAttempts: 1,
    networkConnections: 1,
    followupNetworkContacts: 0,
    fixtureCliInvocations: 0,
    credentialRequests: 0,
    credentialSettlements: 0,
    certificateRequests: 0,
    temporaryRootsAfter: 0,
    journalEntriesAfter: 0,
    journalTemporaryFilesAfter: 0,
    workingCopyContentPreserved: true,
    workingCopyDatabaseBytes: Buffer.byteLength("controlled-wc-database"),
    diagnosticsRedacted: true,
  };
}

function assertEnvelope(envelope, endpoint, operationId, timeoutMs) {
  assert.equal(envelope.operationId, operationId);
  assert.equal(envelope.timeoutMs, timeoutMs);
  assert.equal(envelope.interaction, "allowed");
  assert.equal(envelope.trustEpoch, 7);
  assert.deepEqual(envelope.expectedOrigin, endpoint);
  assert.deepEqual(envelope.profile, {
    schema: "subversionr.remote-profile.v1",
    profileId: "m8-i6-loopback-anonymous-recovery-safe",
    authority: endpoint,
    serverAuth: "anonymous",
    serverAccount: "none",
    serverCredentialPersistence: "secretStorage",
    proxy: "none",
    ssh: "none",
    redirectPolicy: "rejectAll",
  });
}

function runProbe(args) {
  return spawnSync(process.execPath, [probe, ...args], {
    cwd: repositoryRoot,
    encoding: "utf8",
    timeout: 15_000,
    windowsHide: true,
  });
}

function replaceValue(args, name, value) {
  const copy = [...args];
  copy[copy.indexOf(name) + 1] = value;
  return copy;
}

function failed(code) {
  return { schema, status: "failed", error: { code } };
}
