import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const probe = path.join(repositoryRoot, "scripts", "release", "probe-m8-i6-packaged-authz-denied.mjs");
const schema = "subversionr.release.m8-i6-packaged-native-authz-denied.v1";

test("executes the exact repository/open to status/checkRemote authz-denied path", async () => {
  const fixture = await createFixture({});
  try {
    const result = runProbe(fixture.args);
    assert.equal(result.status, 0, result.stderr || result.stdout);
    assert.equal(result.stderr, "");
    assert.deepEqual(JSON.parse(result.stdout), {
      schema,
      status: "passed",
      cell: "authzDenied",
      stableCode: "SVN_REMOTE_STATUS_AUTH_FAILED",
      reason: "authorizationDenied",
      protocol: { major: 1, minor: 35 },
      remoteSvnAnonymous: true,
      temporaryRootsAfter: 0,
      credentialRequests: 0,
      credentialSettlements: 0,
      diagnosticsRedacted: true,
    });
    assert.equal(result.stdout.includes(fixture.repositoryUrl), false);
    assert.equal(result.stdout.includes(fixture.workingCopyPath), false);
    const capture = JSON.parse(await readFile(fixture.capturePath, "utf8"));
    assert.deepEqual(capture.methods, ["repository/open", "status/checkRemote", "diagnostics/get", "repository/close"]);
    assert.equal(capture.shutdown, true);
    const statusRequest = capture.requests[1].params;
    assert.equal(statusRequest.repositoryId, "repo-id");
    assert.equal(statusRequest.epoch, 7);
    assert.equal(statusRequest.remote.intent, "foreground");
    assert.equal(statusRequest.remote.interaction, "allowed");
    assert.equal(statusRequest.remote.timeoutMs, 30_000);
    assert.deepEqual(statusRequest.remote.expectedOrigin, {
      scheme: "svn", canonicalHost: "127.0.0.1", effectivePort: 43690,
    });
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("rejects wrong authz taxonomy, native status, residue, and redaction leaks", async () => {
  const cases = [
    [{ code: "SVN_REMOTE_STATUS_FAILED" }, "SUBVERSIONR_I6_PACKAGED_AUTHZ_ERROR_INVALID"],
    [{ failureReason: "authenticationRequired" }, "SUBVERSIONR_I6_PACKAGED_AUTHZ_FAILURE_INVALID"],
    [{ status: 2 }, "SUBVERSIONR_I6_PACKAGED_AUTHZ_ERROR_INVALID"],
    [{ residue: true }, "SUBVERSIONR_I6_PACKAGED_AUTHZ_WORKER_TEMP_RESIDUE"],
    [{ diagnosticsLeak: true }, "SUBVERSIONR_I6_PACKAGED_AUTHZ_DIAGNOSTICS_LEAK"],
    [{ closeFalse: true }, "SUBVERSIONR_I6_PACKAGED_AUTHZ_CLOSE_INVALID"],
  ];
  for (const [behavior, expectedCode] of cases) {
    const fixture = await createFixture(behavior);
    try {
      const result = runProbe(fixture.args);
      assert.equal(result.status, 1);
      assert.deepEqual(JSON.parse(result.stdout), failed(expectedCode));
      assert.equal(result.stderr, "");
    } finally {
      await rm(fixture.root, { recursive: true, force: true });
    }
  }
});

test("rejects non-exact arguments and any origin outside the controlled denied URL", async () => {
  const fixture = await createFixture({});
  try {
    for (const args of [
      [...fixture.args, "--extra", "value"],
      replaceValue(fixture.args, "--timeout-ms", "030000"),
      replaceValue(fixture.args, "--repository-url", "svn://localhost:43690/repo/denied"),
      replaceValue(fixture.args, "--repository-url", "svn://127.0.0.1:43690/repo/trunk"),
    ]) {
      const result = runProbe(args);
      assert.equal(result.status, 1);
      assert.equal(JSON.parse(result.stdout).status, "failed");
      assert.equal(result.stderr, "");
    }
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

async function createFixture(behavior) {
  const root = await mkdtemp(path.join(os.tmpdir(), "subversionr-i6-packaged-authz-test-"));
  const tooling = path.join(root, "tooling");
  const backendRoot = path.join(tooling, "dist", "backend");
  const securityRoot = path.join(tooling, "dist", "security");
  const profileRoot = path.join(root, "profile");
  const workingCopyPath = path.join(root, "denied-wc");
  await mkdir(backendRoot, { recursive: true });
  await mkdir(securityRoot, { recursive: true });
  await mkdir(profileRoot);
  await mkdir(workingCopyPath);
  const backendModule = path.join(backendRoot, "backendProcess.js");
  const remoteAccessModule = path.join(securityRoot, "remoteAccessProfile.js");
  const daemon = path.join(tooling, "subversionr-daemon.exe");
  const bridge = path.join(tooling, "subversionr-native.dll");
  const repositoryUrl = "svn://127.0.0.1:43690/repo/denied";
  await writeFile(backendModule, fakeBackendSource(behavior, workingCopyPath, repositoryUrl), "utf8");
  await writeFile(remoteAccessModule, fakeRemoteAccessProfileSource(), "utf8");
  await writeFile(daemon, "fake-daemon", "utf8");
  await writeFile(bridge, "fake-bridge", "utf8");
  return {
    root, profileRoot, workingCopyPath, repositoryUrl,
    capturePath: path.join(profileRoot, "remote-state", "capture.json"),
    args: [
      "--backend-module", backendModule,
      "--daemon", daemon,
      "--bridge", bridge,
      "--profile-root", profileRoot,
      "--working-copy-path", workingCopyPath,
      "--repository-url", repositoryUrl,
      "--timeout-ms", "30000",
    ],
  };
}

function fakeBackendSource(behavior, workingCopyPath, repositoryUrl) {
  return `
const fs = require("node:fs");
const path = require("node:path");
const behavior = ${JSON.stringify(behavior)};
const workingCopyPath = ${JSON.stringify(workingCopyPath)};
const repositoryUrl = ${JSON.stringify(repositoryUrl)};
exports.startBackendProcess = async function startBackendProcess(config) {
  const capturePath = path.join(config.remoteStateRoot, "capture.json");
  const workerRoot = path.join(config.baseEnv.TEMP, "SubversionR", "remote-workers");
  fs.mkdirSync(workerRoot, { recursive: true });
  if (behavior.residue === true) fs.mkdirSync(path.join(workerRoot, "residue"));
  const capture = { methods: [], requests: [], shutdown: false };
  const save = () => fs.writeFileSync(capturePath, JSON.stringify(capture));
  save();
  return {
    initializeResult: {
      protocol: { major: 1, minor: 35 },
      capabilities: {
        realLibsvnBridge: true, remoteOperationEnvelope: true, remoteWorkerIsolation: true,
        remoteSvnAnonymous: true,
      },
      acknowledgedTrustEpoch: 7,
    },
    isRemoteSubmissionEnabled() { return true; },
    currentRemoteTrustEpoch() { return 7; },
    async sendRequest(method, params) {
      capture.methods.push(method); capture.requests.push({ method, params }); save();
      if (method === "repository/open") return {
        repositoryId: "repo-id", epoch: 7,
        identity: { workingCopyRoot: workingCopyPath, repositoryRootUrl: repositoryUrl },
      };
      if (method === "status/checkRemote") {
        const error = new Error(behavior.code ?? "SVN_REMOTE_STATUS_AUTH_FAILED");
        error.code = behavior.code ?? "SVN_REMOTE_STATUS_AUTH_FAILED";
        error.category = "auth";
        error.messageKey = "error.native.remoteStatusAuthFailed";
        error.retryable = false;
        error.safeArgs = {
          path: workingCopyPath,
          status: behavior.status ?? 12,
          remoteFailure: {
            category: "authorization",
            reason: behavior.failureReason ?? "authorizationDenied",
            cleanupAppropriate: false,
          },
        };
        error.diagnostics = {
          cause: "authorizationDenied",
          svn: { entries: [{ code: 170001, name: "SVN_ERR_AUTHZ_UNREADABLE" }], truncated: false },
        };
        throw error;
      }
      if (method === "diagnostics/get") return {
        source: "subversionr-daemon", entries: [],
        ...(behavior.diagnosticsLeak === true ? { leaked: repositoryUrl } : {}),
      };
      if (method === "repository/close") return { repositoryId: "repo-id", epoch: 7, closed: behavior.closeFalse !== true };
      throw new Error("UNEXPECTED_METHOD");
    },
    async shutdown() { capture.shutdown = true; save(); },
    dispose() { capture.disposed = true; save(); },
  };
};
`;
}

function fakeRemoteAccessProfileSource() {
  return `
exports.canonicalEndpointFromRepositoryUrl = function(repositoryUrl) {
  const url = new URL(repositoryUrl);
  return { scheme: "svn", canonicalHost: url.hostname, effectivePort: Number(url.port || 3690) };
};
exports.RemoteOperationEnvelopeFactory = class {
  constructor(admission) { this.admission = admission; }
  createAnonymousSvn(input) {
    return {
      version: 1, operationId: input.operationId, intent: input.intent, interaction: input.interaction,
      timeoutMs: input.timeoutMs, workspaceTrust: "trusted",
      trustEpoch: this.admission.currentRemoteTrustEpoch(), profile: input.profile,
      expectedOrigin: input.expectedOrigin,
    };
  }
};
`;
}

function runProbe(args) {
  return spawnSync(process.execPath, [probe, ...args], {
    cwd: repositoryRoot, encoding: "utf8", timeout: 10_000, windowsHide: true,
  });
}

function replaceValue(args, name, value) {
  const copy = [...args]; copy[copy.indexOf(name) + 1] = value; return copy;
}

function failed(code) {
  return { schema, status: "failed", error: { code } };
}
