import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const probe = path.join(repositoryRoot, "scripts", "release", "probe-m8-i6-packaged-recovery-indeterminate.mjs");
const schema = "subversionr.release.m8-i6-packaged-native-recovery-indeterminate.v1";
const originOperationId = "12345678-1234-4abc-8def-1234567890ab";
const recoveryOperationId = "22345678-1234-4abc-8def-1234567890ab";

test("proves timeout-pending to Indeterminate recovery and a durably gated local lane", async () => {
  const fixture = await createFixture({ delayedSecondPending: true });
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
      "status/getSnapshot",
      "diagnostics/get",
    ]);
    assert.equal(capture.shutdown, true);
    assert.deepEqual(capture.requests[1], {
      method: "status/getSnapshot",
      params: { repositoryId: fixture.repositoryId, epoch: 7 },
    });
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
      method: "status/getSnapshot",
      params: { repositoryId: fixture.repositoryId, epoch: 7 },
    });
    const origin = capture.requests[2].params;
    assert.equal(origin.kind, "update");
    assert.deepEqual(origin.options, {
      version: 1,
      path: ".",
      revision: "head",
      depth: "infinity",
      depthIsSticky: false,
      ignoreExternals: true,
    });
    assertEnvelope(origin.remote, fixture.endpoint);
    assert.deepEqual(JSON.parse(await readFile(fixture.fixtureStatePath, "utf8")), commandFixtureState());
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("rejects non-exact timeout origin and pending recovery state", async () => {
  const cases = [
    [{ originCode: "SUBVERSIONR_REMOTE_WORKER_CANCELLED" }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_ORIGIN_INVALID"],
    [{ originCategory: "cancelled" }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_ORIGIN_INVALID"],
    [{ originRetryable: true }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_ORIGIN_INVALID"],
    [{ originFailureReason: "operationCancelled" }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_ORIGIN_FAILURE_INVALID"],
    [{ pendingReason: "cancelledAfterMutation" }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_PENDING_INVALID"],
    [{ pendingCleanupAppropriate: true }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_PENDING_INVALID"],
    [{ pendingExtra: true }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_PENDING_INVALID"],
  ];
  for (const [behavior, code] of cases) await expectFailure(behavior, code);
});

test("rejects non-exact Indeterminate recovery shape and second pending transition", async () => {
  const cases = [
    [{ recoveryOutcome: "safe" }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_SETTLEMENT_INVALID"],
    [{ recoveryOperationId: originOperationId }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_SETTLEMENT_INVALID"],
    [{ recoveryExtra: true }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_SETTLEMENT_INVALID"],
    [{ recoveryFailureCategory: "recovery" }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_SETTLEMENT_INVALID"],
    [{ recoveryFailureReason: "remoteOperationIndeterminate" }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_SETTLEMENT_INVALID"],
    [{ recoveryCleanupAppropriate: true }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_SETTLEMENT_INVALID"],
    [{ omitSecondPending: true }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_NOTIFICATION_TIMEOUT"],
    [{ secondPendingReason: "cancelledAfterMutation" }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_PENDING_INVALID"],
    [{ secondPendingExtra: true }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_PENDING_INVALID"],
  ];
  for (const [behavior, code] of cases) await expectFailure(behavior, code);
});

test("rejects false or mistyped same-lane Indeterminate gates", async () => {
  const cases = [
    [{ laneFulfilled: true }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_LANE_INVALID"],
    [{ laneCode: "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED" }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_LANE_INVALID"],
    [{ laneCategory: "recovery" }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_LANE_INVALID"],
    [{ laneMessageKey: "error.remote.recoveryBlocked" }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_LANE_INVALID"],
    [{ laneRetryable: true }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_LANE_INVALID"],
    [{ laneDiagnostics: {} }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_LANE_INVALID"],
    [{ laneSafeArgExtra: true }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_LANE_INVALID"],
    [{ laneFailureCategory: "unknown" }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_LANE_FAILURE_INVALID"],
    [{ laneFailureReason: "unknownRemote" }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_LANE_FAILURE_INVALID"],
    [{ laneCleanupAppropriate: true }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_LANE_FAILURE_INVALID"],
  ];
  for (const [behavior, code] of cases) await expectFailure(behavior, code);
});

test("rejects baseline, trust, auth, diagnostics, residue, redaction, and network tampering", async () => {
  const cases = [
    [{ baselineGeneration: -1 }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_BASELINE_INVALID"],
    [{ baselineCompleteness: "targeted" }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_BASELINE_INVALID"],
    [{ baselineSource: "remote-worker" }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_BASELINE_INVALID"],
    [{ credentialRequest: true }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_CREDENTIAL_HANDLER_INVOKED"],
    [{ trustEpochAfterOrigin: 8 }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_TRUST_INVALID"],
    [{ workerResidue: true }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_WORKER_TEMP_RESIDUE"],
    [{ journalEntry: true }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_JOURNAL_INVALID"],
    [{ journalTemp: true }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_JOURNAL_RESIDUE"],
    [{ userContentMutation: true }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_USER_CONTENT_CHANGED"],
    [{ diagnosticsLeak: "repository" }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_DIAGNOSTICS_LEAK"],
    [{ diagnosticsLeak: "operation" }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_DIAGNOSTICS_LEAK"],
    [{ followupNetworkContact: true }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_FOLLOWUP_NETWORK_CONTACT"],
    [{ protocolMinor: 34 }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_CAPABILITY_INVALID"],
  ];
  for (const [behavior, code] of cases) await expectFailure(behavior, code);
});

test("rejects non-exact fixture, CLI, timeout, UUID, URL, and filesystem inputs", async () => {
  for (const [behavior, code] of [
    [{ initialConnections: 1 }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_FIXTURE_STATE_INVALID"],
    [{ commandCount: 2 }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_FIXTURE_STATE_INVALID"],
    [{ commandAuthRequestSent: 0 }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_FIXTURE_STATE_INVALID"],
    [{ fixtureExtra: true }, "SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_FIXTURE_STATE_INVALID"],
  ]) await expectFailure(behavior, code);

  const fixture = await createFixture({});
  try {
    for (const args of [
      [...fixture.args, "--extra", "value"],
      replaceValue(fixture.args, "--origin-timeout-ms", "5001"),
      replaceValue(fixture.args, "--recovery-timeout-ms", "299999"),
      replaceValue(fixture.args, "--origin-operation-id", recoveryOperationId),
      replaceValue(fixture.args, "--origin-operation-id", "12345678-1234-4ABC-8def-1234567890ab"),
      replaceValue(fixture.args, "--repository-url", "svn://localhost:43690/repo/trunk"),
      replaceValue(fixture.args, "--repository-url", "svn://127.0.0.1:43690/repo"),
      replaceValue(fixture.args, "--profile-root", "relative-profile"),
    ]) {
      const result = runProbe(args);
      assert.equal(result.status, 1);
      assert.equal(JSON.parse(result.stdout).status, "failed");
      assert.equal(result.stderr, "");
    }
    await writeFile(path.join(fixture.profileRoot, "not-empty"), "x", "utf8");
    const nonEmpty = runProbe(fixture.args);
    assert.deepEqual(JSON.parse(nonEmpty.stdout), failed("SUBVERSIONR_I6_PACKAGED_RECOVERY_INDETERMINATE_FILESYSTEM_INVALID"));
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

async function expectFailure(behavior, code) {
  const fixture = await createFixture(behavior);
  try {
    const result = runProbe(fixture.args);
    assert.equal(result.status, 1, result.stdout);
    assert.equal(result.stderr, "");
    assert.deepEqual(JSON.parse(result.stdout), failed(code));
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
}

async function createFixture(behavior) {
  const root = await mkdtemp(path.join(os.tmpdir(), "subversionr-i6-packaged-recovery-indeterminate-test-"));
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
  await writeFile(fixtureStatePath, JSON.stringify(initialFixtureState(behavior)), "utf8");
  const backendModule = path.join(backendRoot, "backendProcess.js");
  const remoteAccessModule = path.join(securityRoot, "remoteAccessProfile.js");
  const daemon = path.join(tooling, "subversionr-daemon.exe");
  const bridge = path.join(tooling, "subversionr-native.dll");
  await writeFile(backendModule, fakeBackendSource(behavior, profileRoot, workingCopyPath, repositoryUrl, fixtureStatePath), "utf8");
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
      "--origin-timeout-ms", "5000",
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
exports.startBackendProcess = async function startBackendProcess(config, handlers) {
  fs.mkdirSync(config.remoteStateRoot, { recursive: true });
  const capturePath = path.join(config.remoteStateRoot, "capture.json");
  const journalPath = path.join(config.remoteStateRoot, "subversionr-remote-checkout-mutations-v1.json");
  const journalTempPath = path.join(config.remoteStateRoot, ".subversionr-remote-checkout-mutations-v1.tmp");
  const workerRoot = path.join(profileRoot, "SubversionR", "remote-workers");
  fs.writeFileSync(journalPath, JSON.stringify({ schemaVersion: 1, entries: behavior.journalEntry === true ? [{ state: "blocked" }] : [] }));
  if (behavior.journalTemp === true) fs.writeFileSync(journalTempPath, "orphan");
  if (behavior.workerResidue === true) fs.mkdirSync(path.join(workerRoot, "residue"), { recursive: true });
  const capture = {
    methods: [], requests: [], shutdown: false,
    config: { clientName: config.clientName, workspaceTrust: config.workspaceTrust, appdata: config.baseEnv.APPDATA, temp: config.baseEnv.TEMP },
  };
  const save = () => fs.writeFileSync(capturePath, JSON.stringify(capture));
  const record = (method, params) => { capture.methods.push(method); capture.requests.push({ method, params }); save(); };
  const notify = (method, params) => handlers.notificationHandler(method, params);
  const pendingState = (reason, extra) => ({
    kind: "indeterminate",
    reason,
    originOperationId,
    recovery: "pending",
    cleanupAppropriate: behavior.pendingCleanupAppropriate ?? false,
    ...(extra ? { raw: workingCopyPath } : {}),
  });
  save();
  return {
    initializeResult: {
      protocol: { major: 1, minor: behavior.protocolMinor ?? 35 },
      capabilities: {
        realLibsvnBridge: true, repositoryOpen: true, statusSnapshot: true,
        operationRun: true, operationRunUpdate: true, remoteOperationEnvelope: true,
        remoteWorkerIsolation: true, remoteConnectionState: true, remoteSvnAnonymous: true,
      },
      acknowledgedTrustEpoch: 7,
    },
    isRemoteSubmissionEnabled() { return true; },
    currentRemoteTrustEpoch() {
      return behavior.trustEpochAfterOrigin !== undefined && capture.methods.includes("operation/run")
        ? behavior.trustEpochAfterOrigin : 7;
    },
    async sendRequest(method, params) {
      record(method, params);
      if (method === "repository/open") return {
        repositoryId, epoch: 7,
        identity: { workingCopyRoot: workingCopyPath, repositoryRootUrl: "svn://127.0.0.1:43690/repo" },
      };
      if (method === "status/getSnapshot") {
        const count = capture.methods.filter((entry) => entry === "status/getSnapshot").length;
        if (count === 1) return {
          repositoryId, epoch: 7,
          generation: behavior.baselineGeneration ?? 1,
          completeness: behavior.baselineCompleteness ?? "complete",
          source: behavior.baselineSource ?? "libsvn-local",
        };
        if (behavior.laneFulfilled === true) return {
          repositoryId, epoch: 7, generation: 2, completeness: "complete", source: "libsvn-local",
        };
        const error = new Error(behavior.laneCode ?? "SUBVERSIONR_REMOTE_OPERATION_INDETERMINATE");
        error.code = behavior.laneCode ?? "SUBVERSIONR_REMOTE_OPERATION_INDETERMINATE";
        error.category = behavior.laneCategory ?? "state";
        error.messageKey = behavior.laneMessageKey ?? "error.remote.operationIndeterminate";
        error.retryable = behavior.laneRetryable ?? false;
        error.diagnostics = Object.hasOwn(behavior, "laneDiagnostics") ? behavior.laneDiagnostics : null;
        error.safeArgs = {
          remoteFailure: {
            category: behavior.laneFailureCategory ?? "recovery",
            reason: behavior.laneFailureReason ?? "remoteOperationIndeterminate",
            cleanupAppropriate: behavior.laneCleanupAppropriate ?? false,
          },
          ...(behavior.laneSafeArgExtra === true ? { raw: repositoryUrl } : {}),
        };
        throw error;
      }
      if (method === "operation/run") {
        const current = JSON.parse(fs.readFileSync(fixtureStatePath, "utf8"));
        Object.assign(current, {
          connections: 1, greetingSent: 1, clientResponseReceived: 1,
          authRequestSent: behavior.commandAuthRequestSent ?? 1,
          reposInfoSent: 1, commandsReceived: behavior.commandCount ?? 1,
        });
        fs.writeFileSync(fixtureStatePath, JSON.stringify(current));
        if (behavior.credentialRequest === true) { try { await handlers.requestHandler("credentials/request", {}); } catch {} }
        notify("remoteConnection/state", {
          repositoryId, epoch: 7,
          state: pendingState(behavior.pendingReason ?? "workerTerminated", behavior.pendingExtra === true),
        });
        const error = new Error(behavior.originCode ?? "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT");
        error.code = behavior.originCode ?? "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT";
        error.category = behavior.originCategory ?? "timeout";
        error.messageKey = "error.remote.workerTimedOut";
        error.retryable = behavior.originRetryable ?? false;
        error.diagnostics = null;
        error.safeArgs = { remoteFailure: {
          category: "deadline",
          reason: behavior.originFailureReason ?? "operationDeadlineExceeded",
          cleanupAppropriate: false,
        } };
        throw error;
      }
      if (method === "remote/recoverWorkingCopy") {
        if (behavior.userContentMutation === true) {
          fs.writeFileSync(path.join(workingCopyPath, "tracked.txt"), "changed content\\n");
        }
        if (behavior.followupNetworkContact === true) {
          const current = JSON.parse(fs.readFileSync(fixtureStatePath, "utf8"));
          current.connections += 1; current.followupContacts += 1;
          fs.writeFileSync(fixtureStatePath, JSON.stringify(current));
        }
        if (behavior.omitSecondPending !== true) {
          const emit = () => notify("remoteConnection/state", {
            repositoryId, epoch: 7,
            state: {
              ...pendingState(behavior.secondPendingReason ?? "workerTerminated", behavior.secondPendingExtra === true),
              cleanupAppropriate: false,
            },
          });
          if (behavior.delayedSecondPending === true) setTimeout(emit, 25); else emit();
        }
        return {
          outcome: behavior.recoveryOutcome ?? "indeterminate",
          operationId: behavior.recoveryOperationId ?? recoveryOperationId,
          failure: {
            category: behavior.recoveryFailureCategory ?? "unknown",
            reason: behavior.recoveryFailureReason ?? "unknownRemote",
            cleanupAppropriate: behavior.recoveryCleanupAppropriate ?? false,
          },
          ...(behavior.recoveryExtra === true ? { raw: workingCopyPath } : {}),
        };
      }
      if (method === "diagnostics/get") return {
        source: "subversionr-daemon", protocol: { major: 1, minor: 35 },
        capabilities: { remoteSvnAnonymous: true, statusSnapshot: true, remoteConnectionState: true },
        ...(behavior.diagnosticsLeak === "repository" ? { leaked: repositoryUrl } : {}),
        ...(behavior.diagnosticsLeak === "operation" ? { leaked: originOperationId } : {}),
      };
      throw new Error("UNEXPECTED_METHOD");
    },
    async shutdown() { capture.shutdown = true; save(); },
    dispose() { capture.disposed = true; save(); },
  };
};
`;
}

function fakeRemoteAccessSource() {
  return `
exports.canonicalEndpointFromRepositoryUrl = function canonicalEndpointFromRepositoryUrl(repositoryUrl) {
  const url = new URL(repositoryUrl);
  return {
    scheme: "svn",
    canonicalHost: url.hostname,
    effectivePort: Number(url.port),
  };
};
exports.RemoteOperationEnvelopeFactory = class RemoteOperationEnvelopeFactory {
  constructor(admission) {
    this.admission = admission;
  }
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
    suppliedAuthorityConnections: 0,
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
    schema: "subversionr.release.m8-i6-packaged-native-recovery-indeterminate.v1",
    status: "passed",
    cell: "recoveryIndeterminate",
    surface: "packaged-native",
    stableCode: "SUBVERSIONR_REMOTE_OPERATION_INDETERMINATE",
    reason: "remoteOperationIndeterminate",
    originCode: "SUBVERSIONR_REMOTE_OPERATION_INDETERMINATE",
    originReason: "remoteOperationIndeterminate",
    settlementCode: "SUBVERSIONR_REMOTE_OPERATION_INDETERMINATE",
    settlementReason: "remoteOperationIndeterminate",
    protocol: { major: 1, minor: 35 },
    remoteSvnAnonymous: true,
    prerequisite: {
      code: "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT",
      reason: "operationDeadlineExceeded",
      recovery: "pending",
    },
    indeterminate: {
      outcome: "Indeterminate",
      stableCode: "SUBVERSIONR_REMOTE_OPERATION_INDETERMINATE",
      reason: "remoteOperationIndeterminate",
      nativeLaneBlocked: true,
      explicitRecoveryRequired: true,
    },
    baselineGenerationObserved: true,
    recoveryNotificationsObserved: 2,
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
    diagnosticsRedacted: true,
  };
}

function assertEnvelope(envelope, endpoint) {
  assert.deepEqual(envelope, {
    version: 1,
    operationId: originOperationId,
    intent: "foreground",
    interaction: "allowed",
    timeoutMs: 5_000,
    workspaceTrust: "trusted",
    trustEpoch: 7,
    profile: {
      schema: "subversionr.remote-profile.v1",
      profileId: "m8-i6-loopback-anonymous-recovery-indeterminate",
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
  const next = [...args];
  const index = next.indexOf(name);
  assert.notEqual(index, -1, `missing argument ${name}`);
  next[index + 1] = value;
  return next;
}

function failed(code) {
  return {
    schema: "subversionr.release.m8-i6-packaged-native-recovery-indeterminate.v1",
    status: "failed",
    error: { code },
  };
}
