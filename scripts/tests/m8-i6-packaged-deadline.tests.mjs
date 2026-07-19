import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const probe = path.join(repositoryRoot, "scripts", "release", "probe-m8-i6-packaged-deadline.mjs");
const schema = "subversionr.release.m8-i6-packaged-native-deadline.v1";
const operationId = "87654321-4321-4abc-8def-ba0987654321";
const timeoutMs = 500;

test("executes an independent absolute-deadline cell with bounded monotonic timing and same-session local proof", async () => {
  const fixture = await createFixture({});
  try {
    const result = runProbe(fixture.args);
    assert.equal(result.status, 0, result.stderr || result.stdout);
    assert.equal(result.stderr, "");
    const report = JSON.parse(result.stdout);
    assert.deepEqual(Object.keys(report), [
      "schema", "status", "cell", "stableCode", "reason", "protocol", "timing",
      "remoteSvnAnonymous", "nativeLaneReleased", "localSnapshotAfterTimeout",
      "workingCopyPreserved", "temporaryRootsAfter", "credentialRequests",
      "credentialSettlements", "diagnosticsRedacted", "fixtureCliInvocations",
    ]);
    assert.deepEqual({ ...report, timing: undefined }, {
      schema,
      status: "passed",
      cell: "deadline",
      stableCode: "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT",
      reason: "operationDeadlineExceeded",
      protocol: { major: 1, minor: 35 },
      timing: undefined,
      remoteSvnAnonymous: true,
      nativeLaneReleased: true,
      localSnapshotAfterTimeout: true,
      workingCopyPreserved: true,
      temporaryRootsAfter: 0,
      credentialRequests: 0,
      credentialSettlements: 0,
      diagnosticsRedacted: true,
      fixtureCliInvocations: 0,
    });
    assert.deepEqual(Object.keys(report.timing), ["clock", "timeoutMs", "elapsedMs", "cleanupSlackMs"]);
    assert.equal(report.timing.clock, "monotonic");
    assert.equal(report.timing.timeoutMs, timeoutMs);
    assert.equal(report.timing.cleanupSlackMs, 5_000);
    assert.equal(Number.isFinite(report.timing.elapsedMs), true);
    assert.ok(report.timing.elapsedMs >= timeoutMs, JSON.stringify(report.timing));
    assert.ok(report.timing.elapsedMs <= timeoutMs + 5_000, JSON.stringify(report.timing));
    for (const sensitive of [fixture.repositoryUrl, fixture.workingCopyPath, fixture.profileRoot, operationId]) {
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
    assert.equal(capture.shutdown, true);
    assert.equal(capture.config.clientName, "subversionr-m8-i6-packaged-deadline-evidence");
    assert.equal(capture.config.workspaceTrust, "trusted");
    assert.equal(capture.config.appdata, fixture.profileRoot);
    assert.equal(capture.config.temp, fixture.profileRoot);
    const statusRequest = capture.requests[1].params;
    assert.deepEqual(Object.keys(statusRequest), ["repositoryId", "epoch", "remote"]);
    assert.equal(statusRequest.repositoryId, "repo-deadline");
    assert.equal(statusRequest.epoch, 11);
    assert.equal(statusRequest.remote.operationId, operationId);
    assert.equal(statusRequest.remote.timeoutMs, timeoutMs);
    assert.equal(statusRequest.remote.intent, "foreground");
    assert.equal(statusRequest.remote.interaction, "allowed");
    assert.equal(statusRequest.remote.workspaceTrust, "trusted");
    assert.equal(statusRequest.remote.trustEpoch, 11);
    assert.deepEqual(statusRequest.remote.expectedOrigin, fixture.endpoint);
    assert.deepEqual(statusRequest.remote.profile, {
      schema: "subversionr.remote-profile.v1",
      profileId: "m8-i6-loopback-anonymous-deadline",
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
      params: { repositoryId: "repo-deadline", epoch: 11 },
    });
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("rejects deadline settlement before the requested absolute timeout", async () => {
  const fixture = await createFixture({ settlementDelayMs: 0 });
  try {
    const result = runProbe(fixture.args);
    assert.equal(result.status, 1, result.stdout);
    assert.deepEqual(JSON.parse(result.stdout), failed("SUBVERSIONR_I6_PACKAGED_DEADLINE_TIMING_INVALID"));
    assert.equal(result.stderr, "");
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("rejects deadline settlement after the reviewed cleanup supervision bound", { timeout: 15_000 }, async () => {
  const fixture = await createFixture({ settlementDelayMs: timeoutMs + 5_100 });
  try {
    const result = runProbe(fixture.args);
    assert.equal(result.status, 1, result.stdout);
    assert.deepEqual(JSON.parse(result.stdout), failed("SUBVERSIONR_I6_PACKAGED_DEADLINE_TIMING_INVALID"));
    assert.equal(result.stderr, "");
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("rejects every non-exact deadline wire settlement", async () => {
  const cases = [
    [{ code: "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED" }, "SUBVERSIONR_I6_PACKAGED_DEADLINE_ERROR_INVALID"],
    [{ category: "recovery" }, "SUBVERSIONR_I6_PACKAGED_DEADLINE_ERROR_INVALID"],
    [{ messageKey: "error.remote.recoveryBlocked" }, "SUBVERSIONR_I6_PACKAGED_DEADLINE_ERROR_INVALID"],
    [{ retryable: true }, "SUBVERSIONR_I6_PACKAGED_DEADLINE_ERROR_INVALID"],
    [{ safeArgsExtra: true }, "SUBVERSIONR_I6_PACKAGED_DEADLINE_ERROR_INVALID"],
    [{ failureCategory: "timeout" }, "SUBVERSIONR_I6_PACKAGED_DEADLINE_FAILURE_INVALID"],
    [{ failureReason: "remoteRecoveryBlocked" }, "SUBVERSIONR_I6_PACKAGED_DEADLINE_FAILURE_INVALID"],
    [{ cleanupAppropriate: true }, "SUBVERSIONR_I6_PACKAGED_DEADLINE_FAILURE_INVALID"],
    [{ errorDiagnostics: {} }, "SUBVERSIONR_I6_PACKAGED_DEADLINE_ERROR_INVALID"],
  ];
  for (const [behavior, expectedCode] of cases) {
    const fixture = await createFixture(behavior);
    try {
      const result = runProbe(fixture.args);
      assert.equal(result.status, 1, result.stdout);
      assert.deepEqual(JSON.parse(result.stdout), failed(expectedCode));
      assert.equal(result.stderr, "");
    } finally {
      await rm(fixture.root, { recursive: true, force: true });
    }
  }
});

test("rejects false lane, integrity, no-auth, cleanup, trust, and redaction evidence", async () => {
  const cases = [
    [{ snapshotRepositoryId: "other" }, "SUBVERSIONR_I6_PACKAGED_DEADLINE_LOCAL_SNAPSHOT_INVALID"],
    [{ snapshotEpoch: 12 }, "SUBVERSIONR_I6_PACKAGED_DEADLINE_LOCAL_SNAPSHOT_INVALID"],
    [{ snapshotSource: "remote-worker" }, "SUBVERSIONR_I6_PACKAGED_DEADLINE_LOCAL_SNAPSHOT_INVALID"],
    [{ credentialRequest: true }, "SUBVERSIONR_I6_PACKAGED_DEADLINE_CREDENTIAL_HANDLER_INVOKED"],
    [{ residue: true }, "SUBVERSIONR_I6_PACKAGED_DEADLINE_WORKER_TEMP_RESIDUE"],
    [{ diagnosticsLeak: "repository" }, "SUBVERSIONR_I6_PACKAGED_DEADLINE_DIAGNOSTICS_LEAK"],
    [{ diagnosticsLeak: "operation" }, "SUBVERSIONR_I6_PACKAGED_DEADLINE_DIAGNOSTICS_LEAK"],
    [{ tamperUserContent: true }, "SUBVERSIONR_I6_PACKAGED_DEADLINE_WORKING_COPY_INVALID"],
    [{ tamperWcDatabaseSameSize: true }, "SUBVERSIONR_I6_PACKAGED_DEADLINE_WORKING_COPY_INVALID"],
    [{ protocolMinor: 34 }, "SUBVERSIONR_I6_PACKAGED_DEADLINE_CAPABILITY_INVALID"],
    [{ remoteSvnAnonymous: false }, "SUBVERSIONR_I6_PACKAGED_DEADLINE_CAPABILITY_INVALID"],
    [{ trustDropsAfterTimeout: true }, "SUBVERSIONR_I6_PACKAGED_DEADLINE_TRUST_INVALID"],
    [{ closeFalse: true }, "SUBVERSIONR_I6_PACKAGED_DEADLINE_CLOSE_INVALID"],
  ];
  for (const [behavior, expectedCode] of cases) {
    const fixture = await createFixture(behavior);
    try {
      const result = runProbe(fixture.args);
      assert.equal(result.status, 1, result.stdout);
      assert.deepEqual(JSON.parse(result.stdout), failed(expectedCode));
      assert.equal(result.stderr, "");
    } finally {
      await rm(fixture.root, { recursive: true, force: true });
    }
  }
});

test("rejects non-exact CLI input, origins, working-copy identity, and profile state", async () => {
  const fixture = await createFixture({});
  try {
    const argumentCases = [
      [[...fixture.args, "--extra", "value"], "SUBVERSIONR_I6_PACKAGED_DEADLINE_ARGUMENT_INVALID"],
      [replaceValue(fixture.args, "--timeout-ms", "0500"), "SUBVERSIONR_I6_PACKAGED_DEADLINE_ARGUMENT_INVALID"],
      [replaceValue(fixture.args, "--timeout-ms", "499"), "SUBVERSIONR_I6_PACKAGED_DEADLINE_ARGUMENT_INVALID"],
      [replaceValue(fixture.args, "--timeout-ms", "501"), "SUBVERSIONR_I6_PACKAGED_DEADLINE_ARGUMENT_INVALID"],
      [replaceValue(fixture.args, "--operation-id", "87654321-4321-4ABC-8def-ba0987654321"), "SUBVERSIONR_I6_PACKAGED_DEADLINE_ARGUMENT_INVALID"],
      [replaceValue(fixture.args, "--operation-id", "00000000-0000-0000-0000-000000000000"), "SUBVERSIONR_I6_PACKAGED_DEADLINE_ARGUMENT_INVALID"],
      [replaceValue(fixture.args, "--repository-url", "svn://localhost:43690/repo"), "SUBVERSIONR_I6_PACKAGED_DEADLINE_URL_INVALID"],
      [replaceValue(fixture.args, "--repository-url", "svn://127.0.0.1/repo"), "SUBVERSIONR_I6_PACKAGED_DEADLINE_URL_INVALID"],
      [replaceValue(fixture.args, "--repository-url", "svn://user@127.0.0.1:43690/repo"), "SUBVERSIONR_I6_PACKAGED_DEADLINE_URL_INVALID"],
    ];
    for (const [args, expectedCode] of argumentCases) {
      const result = runProbe(args);
      assert.equal(result.status, 1);
      assert.deepEqual(JSON.parse(result.stdout), failed(expectedCode));
      assert.equal(result.stderr, "");
    }
    await writeFile(path.join(fixture.profileRoot, "not-empty"), "x", "utf8");
    const nonEmpty = runProbe(fixture.args);
    assert.equal(nonEmpty.status, 1);
    assert.deepEqual(JSON.parse(nonEmpty.stdout), failed("SUBVERSIONR_I6_PACKAGED_DEADLINE_FILESYSTEM_INVALID"));
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }

  const wrongWorkingCopyEndpoint = await createFixture({ workingCopyRepositoryUrl: "svn://127.0.0.1:43691/repo" });
  try {
    const result = runProbe(wrongWorkingCopyEndpoint.args);
    assert.equal(result.status, 1);
    assert.deepEqual(JSON.parse(result.stdout), failed("SUBVERSIONR_I6_PACKAGED_DEADLINE_OPEN_INVALID"));
  } finally {
    await rm(wrongWorkingCopyEndpoint.root, { recursive: true, force: true });
  }

  const wrongCanonicalOrigin = await createFixture({ canonicalHost: "localhost" });
  try {
    const result = runProbe(wrongCanonicalOrigin.args);
    assert.equal(result.status, 1);
    assert.deepEqual(JSON.parse(result.stdout), failed("SUBVERSIONR_I6_PACKAGED_DEADLINE_ORIGIN_INVALID"));
  } finally {
    await rm(wrongCanonicalOrigin.root, { recursive: true, force: true });
  }
});

async function createFixture(behavior) {
  const root = await mkdtemp(path.join(os.tmpdir(), "subversionr-i6-packaged-deadline-test-"));
  const tooling = path.join(root, "tooling");
  const backendRoot = path.join(tooling, "dist", "backend");
  const securityRoot = path.join(tooling, "dist", "security");
  const profileRoot = path.join(root, "profile");
  const workingCopyPath = path.join(root, "wc");
  await mkdir(backendRoot, { recursive: true });
  await mkdir(securityRoot, { recursive: true });
  await mkdir(profileRoot);
  await mkdir(path.join(workingCopyPath, ".svn"), { recursive: true });
  await mkdir(path.join(workingCopyPath, "empty-directory"));
  await writeFile(path.join(workingCopyPath, ".svn", "wc.db"), "controlled-deadline-wc-db", "utf8");
  await writeFile(path.join(workingCopyPath, "tracked.txt"), "controlled deadline content\n", "utf8");
  const backendModule = path.join(backendRoot, "backendProcess.js");
  const remoteAccessModule = path.join(securityRoot, "remoteAccessProfile.js");
  const daemon = path.join(tooling, "subversionr-daemon.exe");
  const bridge = path.join(tooling, "subversionr-native.dll");
  const repositoryUrl = "svn://127.0.0.1:43690/repo";
  await writeFile(backendModule, fakeBackendSource(behavior, workingCopyPath, repositoryUrl, operationId, timeoutMs), "utf8");
  await writeFile(remoteAccessModule, fakeRemoteAccessProfileSource(behavior), "utf8");
  await writeFile(daemon, "fake-daemon", "utf8");
  await writeFile(bridge, "fake-bridge", "utf8");
  return {
    root,
    profileRoot,
    workingCopyPath,
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
      "--timeout-ms", `${timeoutMs}`,
    ],
  };
}

function fakeBackendSource(behavior, workingCopyPath, repositoryUrl, externalOperationId, operationTimeoutMs) {
  return `
const fs = require("node:fs");
const path = require("node:path");
const behavior = ${JSON.stringify(behavior)};
const workingCopyPath = ${JSON.stringify(workingCopyPath)};
const repositoryUrl = ${JSON.stringify(repositoryUrl)};
const externalOperationId = ${JSON.stringify(externalOperationId)};
const operationTimeoutMs = ${JSON.stringify(operationTimeoutMs)};
exports.startBackendProcess = async function startBackendProcess(config, handlers) {
  const capturePath = path.join(config.remoteStateRoot, "capture.json");
  const workerRoot = path.join(config.baseEnv.TEMP, "SubversionR", "remote-workers");
  fs.mkdirSync(workerRoot, { recursive: true });
  if (behavior.residue === true) fs.mkdirSync(path.join(workerRoot, "residue"));
  const capture = {
    methods: [], requests: [], shutdown: false,
    config: {
      clientName: config.clientName, workspaceTrust: config.workspaceTrust,
      appdata: config.baseEnv.APPDATA, temp: config.baseEnv.TEMP,
    },
  };
  const save = () => fs.writeFileSync(capturePath, JSON.stringify(capture));
  save();
  return {
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
      return behavior.trustDropsAfterTimeout === true && capture.methods.includes("status/checkRemote") ? 12 : 11;
    },
    async sendRequest(method, params) {
      capture.methods.push(method); capture.requests.push({ method, params }); save();
      if (method === "repository/open") return {
        repositoryId: "repo-deadline", epoch: 11,
        identity: {
          workingCopyRoot: workingCopyPath,
          repositoryRootUrl: behavior.workingCopyRepositoryUrl ?? repositoryUrl,
        },
      };
      if (method === "status/checkRemote") {
        const delayMs = Object.hasOwn(behavior, "settlementDelayMs")
          ? behavior.settlementDelayMs
          : operationTimeoutMs + 10;
        if (delayMs > 0) await new Promise((resolve) => setTimeout(resolve, delayMs));
        if (behavior.credentialRequest === true) {
          try { await handlers.requestHandler("credentials/request", {}); } catch {}
        }
        const error = new Error(behavior.code ?? "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT");
        error.code = behavior.code ?? "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT";
        error.category = behavior.category ?? "timeout";
        error.messageKey = behavior.messageKey ?? "error.remote.workerTimedOut";
        error.retryable = behavior.retryable ?? false;
        error.safeArgs = {
          remoteFailure: {
            category: behavior.failureCategory ?? "deadline",
            reason: behavior.failureReason ?? "operationDeadlineExceeded",
            cleanupAppropriate: behavior.cleanupAppropriate ?? false,
          },
          ...(behavior.safeArgsExtra === true ? { path: workingCopyPath } : {}),
        };
        error.diagnostics = Object.hasOwn(behavior, "errorDiagnostics") ? behavior.errorDiagnostics : null;
        if (behavior.tamperUserContent === true) fs.writeFileSync(path.join(workingCopyPath, "tracked.txt"), "tampered\\n");
        if (behavior.tamperWcDatabaseSameSize === true) {
          const wcDatabasePath = path.join(workingCopyPath, ".svn", "wc.db");
          const bytes = fs.readFileSync(wcDatabasePath); bytes[0] ^= 0xff; fs.writeFileSync(wcDatabasePath, bytes);
        }
        throw error;
      }
      if (method === "status/getSnapshot") return {
        repositoryId: behavior.snapshotRepositoryId ?? "repo-deadline",
        epoch: behavior.snapshotEpoch ?? 11,
        source: behavior.snapshotSource ?? "libsvn-local",
      };
      if (method === "diagnostics/get") return {
        source: "subversionr-daemon",
        protocol: { major: 1, minor: 35 },
        capabilities: { remoteSvnAnonymous: true, statusRemoteCheck: true, statusSnapshot: true },
        entries: [],
        ...(behavior.diagnosticsLeak === "repository" ? { leaked: repositoryUrl } : {}),
        ...(behavior.diagnosticsLeak === "operation" ? { leaked: externalOperationId } : {}),
      };
      if (method === "repository/close") return {
        repositoryId: "repo-deadline", epoch: 11, closed: behavior.closeFalse !== true,
      };
      throw new Error("UNEXPECTED_METHOD");
    },
    async shutdown() { capture.shutdown = true; save(); },
    dispose() { capture.disposed = true; save(); },
  };
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

function runProbe(args) {
  return spawnSync(process.execPath, [probe, ...args], {
    cwd: repositoryRoot,
    encoding: "utf8",
    timeout: 12_000,
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
