import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";

const REPOSITORY_URL = "svn://127.0.0.1:3691/repo/trunk";
const PROBE_PATH = path.resolve("scripts/release/probe-m8-i6-packaged-native.mjs");

test("packaged positive probe reports nine positive operations and two anonymous identity boundaries", async () => {
  const result = await runProbe();
  try {
    assert.equal(result.process.status, 0, result.process.stderr);
    assert.equal(result.report.status, "passed");
    assert.equal(result.report.positiveOperationCount, 9);
    assert.equal(result.report.identityRequiredOperationCount, 2);
    assert.equal(result.report.remoteOperationCount, 11);
    assert.equal(result.report.uniqueOperationIds, true);
    assert.deepEqual(result.report.operations.map((entry) => entry.operation), [
      "checkoutOpen", "remoteStatus", "content", "historyLog", "historyBlame", "update", "commit",
      "branchCopy", "switch",
    ]);
    assert.deepEqual(result.report.anonymousIdentityRequired, {
      lock: identityRequiredEvidence("lock"),
      unlock: identityRequiredEvidence("unlock"),
    });
    assert.equal(result.capture.remoteOperationIds.length, 11);
    assert.equal(new Set(result.capture.remoteOperationIds).size, 11);
    assert.deepEqual(result.capture.operationKinds, ["update", "commit", "branchCreate", "switch", "lock", "unlock"]);
    assert.equal(result.capture.unlockBreakLock, true);
    const lockIndex = result.capture.requests.indexOf("operation/run:lock");
    const unlockIndex = result.capture.requests.indexOf("operation/run:unlock");
    assert.equal(result.capture.requests[lockIndex + 1], "status/refresh");
    assert.equal(result.capture.requests[unlockIndex + 1], "status/refresh");
    const serialized = JSON.stringify(result.report);
    assert.equal(serialized.includes(REPOSITORY_URL), false);
    assert.equal(serialized.includes(result.checkoutTarget), false);
  } finally {
    await rm(result.root, { recursive: true, force: true });
  }
});

test("packaged positive probe rejects a truncated identity-boundary SVN cause chain", async () => {
  const result = await runProbe({ truncatedDiagnostics: true });
  try {
    assert.equal(result.process.status, 1);
    assert.equal(result.report.status, "failed");
    assert.equal(result.report.error.code, "SUBVERSIONR_I6_PACKAGED_IDENTITY_BOUNDARY_INVALID");
  } finally {
    await rm(result.root, { recursive: true, force: true });
  }
});

test("packaged positive probe rejects duplicate identity-boundary SVN cause names", async () => {
  const result = await runProbe({ duplicateDiagnostics: true });
  try {
    assert.equal(result.process.status, 1);
    assert.equal(result.report.status, "failed");
    assert.equal(result.report.error.code, "SUBVERSIONR_I6_PACKAGED_IDENTITY_BOUNDARY_INVALID");
  } finally {
    await rm(result.root, { recursive: true, force: true });
  }
});

test("packaged positive probe rejects an identity boundary without an allowed upstream cause", async () => {
  const result = await runProbe({ noAllowedIdentityCause: true });
  try {
    assert.equal(result.process.status, 1);
    assert.equal(result.report.status, "failed");
    assert.equal(result.report.error.code, "SUBVERSIONR_I6_PACKAGED_IDENTITY_BOUNDARY_INVALID");
  } finally {
    await rm(result.root, { recursive: true, force: true });
  }
});

test("packaged positive probe rejects swapped operation-specific identity causes", async () => {
  const result = await runProbe({ swappedIdentityCause: true });
  try {
    assert.equal(result.process.status, 1);
    assert.equal(result.report.status, "failed");
    assert.equal(result.report.error.code, "SUBVERSIONR_I6_PACKAGED_IDENTITY_BOUNDARY_INVALID");
  } finally {
    await rm(result.root, { recursive: true, force: true });
  }
});

for (const markerMode of ["missing", "false"]) {
  test(`packaged positive probe rejects an identity boundary marker that is ${markerMode}`, async () => {
    const result = await runProbe({ markerMode });
    try {
      assert.equal(result.process.status, 1);
      assert.equal(result.report.status, "failed");
      assert.equal(result.report.error.code, "SUBVERSIONR_I6_PACKAGED_IDENTITY_BOUNDARY_INVALID");
    } finally {
      await rm(result.root, { recursive: true, force: true });
    }
  });
}

async function runProbe({
  truncatedDiagnostics = false,
  duplicateDiagnostics = false,
  noAllowedIdentityCause = false,
  swappedIdentityCause = false,
  markerMode = "true",
} = {}) {
  const root = await mkdtemp(path.join(tmpdir(), "subversionr-i6-packaged-positive-"));
  const profileRoot = path.join(root, "profile");
  const checkoutTarget = path.join(root, "checkout");
  const backendModule = path.join(root, "backend.cjs");
  const capturePath = path.join(root, "capture.json");
  const daemon = path.join(root, "subversionr-daemon.exe");
  const bridge = path.join(root, "subversionr_svn_bridge.dll");
  await mkdir(profileRoot, { recursive: true });
  await writeFile(daemon, "fixture", "utf8");
  await writeFile(bridge, "fixture", "utf8");
  await writeFile(backendModule, backendFixtureSource(), "utf8");

  const probeProcess = spawnSync(process.execPath, [
    PROBE_PATH,
    "--backend-module", backendModule,
    "--daemon", daemon,
    "--bridge", bridge,
    "--profile-root", profileRoot,
    "--checkout-target", checkoutTarget,
    "--repository-url", REPOSITORY_URL,
    "--checkout-revision", "1",
  ], {
    cwd: path.dirname(path.dirname(path.dirname(PROBE_PATH))),
    encoding: "utf8",
    env: {
      ...processEnv(),
      SUBVERSIONR_I6_TEST_CAPTURE_PATH: capturePath,
      SUBVERSIONR_I6_TEST_TRUNCATED_DIAGNOSTICS: truncatedDiagnostics ? "1" : "0",
      SUBVERSIONR_I6_TEST_DUPLICATE_DIAGNOSTICS: duplicateDiagnostics ? "1" : "0",
      SUBVERSIONR_I6_TEST_NO_ALLOWED_IDENTITY_CAUSE: noAllowedIdentityCause ? "1" : "0",
      SUBVERSIONR_I6_TEST_SWAPPED_IDENTITY_CAUSE: swappedIdentityCause ? "1" : "0",
      SUBVERSIONR_I6_TEST_IDENTITY_MARKER_MODE: markerMode,
    },
  });
  const report = JSON.parse(probeProcess.stdout.trim());
  const capture = JSON.parse(await readFile(capturePath, "utf8"));
  return { root, checkoutTarget, process: probeProcess, report, capture };
}

function backendFixtureSource() {
  return String.raw`
const fs = require("node:fs");
const path = require("node:path");

exports.startBackendProcess = async function startBackendProcess(_config, handlers) {
  const capture = { remoteOperationIds: [], operationKinds: [], unlockBreakLock: null, requests: [] };
  const persist = () => fs.writeFileSync(process.env.SUBVERSIONR_I6_TEST_CAPTURE_PATH, JSON.stringify(capture));
  persist();
  const session = { repositoryId: "fixture-repository", epoch: 1 };
  return {
    initializeResult: {
      protocol: { major: 1, minor: 35 },
      acknowledgedTrustEpoch: 7,
      capabilities: {
        remoteSvnAnonymous: true,
        remoteWorkerIsolation: true,
        remoteConnectionState: true,
      },
    },
    isRemoteSubmissionEnabled: () => true,
    currentRemoteTrustEpoch: () => 7,
    sendRequest: async (method, params) => {
      capture.requests.push(method === "operation/run" ? method + ":" + params.kind : method);
      persist();
      if (params && params.remote) {
        capture.remoteOperationIds.push(params.remote.operationId);
        persist();
      }
      if (method === "repository/checkout") {
        fs.mkdirSync(params.targetPath, { recursive: true });
        fs.writeFileSync(path.join(params.targetPath, "tracked.txt"), "fixture\n");
        return { workingCopyPath: params.targetPath, revision: params.revision };
      }
      if (method === "repository/open") {
        return { ...session, identity: { workingCopyRoot: params.path } };
      }
      if (method === "status/refresh") {
        return { ...session, completeness: "complete", source: "libsvn-local" };
      }
      if (method === "status/checkRemote") {
        return { ...session, completeness: "complete", source: "libsvn-remote", remoteUpsert: [] };
      }
      if (method === "content/get") {
        return { source: "libsvn-head", byteLength: 8 };
      }
      if (method === "history/log") {
        return { source: "libsvn-log", entries: [{}] };
      }
      if (method === "history/blame") {
        return { source: "libsvn-blame", lines: [{}] };
      }
      if (method === "diagnostics/get") {
        return { source: "subversionr-daemon" };
      }
      if (method === "operation/run") {
        capture.operationKinds.push(params.kind);
        if (params.kind === "unlock") capture.unlockBreakLock = params.options.breakLock;
        persist();
        if (params.kind === "lock" || params.kind === "unlock") {
          const error = new Error(params.kind);
          error.code = params.kind === "lock" ? "SVN_OPERATION_LOCK_FAILED" : "SVN_OPERATION_UNLOCK_FAILED";
          error.category = "native";
          error.messageKey = params.kind === "lock" ? "error.native.operationLockFailed" : "error.native.operationUnlockFailed";
          error.safeArgs = {
            path: "tracked.txt",
            status: 2,
            ...(process.env.SUBVERSIONR_I6_TEST_IDENTITY_MARKER_MODE === "missing"
              ? {}
              : { anonymousIdentityRequired: process.env.SUBVERSIONR_I6_TEST_IDENTITY_MARKER_MODE !== "false" }),
            mayHaveMutated: false,
            remoteFailure: { category: "authentication", reason: "authenticationRequired", cleanupAppropriate: false },
          };
          error.retryable = false;
          error.diagnostics = {
            cause: "authenticationFailed",
            svn: {
              entries: [
                { code: 170001, name: "SVN_ERR_AUTHN_FAILED" },
                ...(process.env.SUBVERSIONR_I6_TEST_DUPLICATE_DIAGNOSTICS === "1"
                  ? [{ code: 170002, name: "SVN_ERR_AUTHN_FAILED" }]
                  : []),
                { code: 170001, name: process.env.SUBVERSIONR_I6_TEST_NO_ALLOWED_IDENTITY_CAUSE === "1"
                  ? "SVN_ERR_AUTHZ_UNWRITABLE"
                  : process.env.SUBVERSIONR_I6_TEST_SWAPPED_IDENTITY_CAUSE === "1"
                    ? params.kind === "lock" ? "SVN_ERR_FS_NO_USER" : "SVN_ERR_RA_NOT_AUTHORIZED"
                    : params.kind === "lock" ? "SVN_ERR_RA_NOT_AUTHORIZED" : "SVN_ERR_FS_NO_USER" },
              ],
              truncated: process.env.SUBVERSIONR_I6_TEST_TRUNCATED_DIAGNOSTICS === "1",
            },
          };
          throw error;
        }
        const revision = params.kind === "update" ? 2 : params.kind === "commit" ? 3 : 4;
        return {
          ...session,
          kind: params.kind,
          touchedPaths: [],
          revision,
          reconcile: { targets: [] },
        };
      }
      throw new Error("unexpected method: " + method);
    },
    shutdown: async () => undefined,
    dispose: () => undefined,
  };
};
`;
}

function identityRequiredEvidence(operation) {
  return {
    operation,
    anonymousIdentityRequired: true,
    stableCode: operation === "lock" ? "SVN_OPERATION_LOCK_FAILED" : "SVN_OPERATION_UNLOCK_FAILED",
    diagnosticsCause: "authenticationFailed",
    mayHaveMutated: false,
    remoteFailure: { category: "authentication", reason: "authenticationRequired", cleanupAppropriate: false },
    promptCount: 0,
    credentialSettlement: "none",
    temporaryRootsAfter: 0,
    laneReleaseProof: { method: "status/refresh", reconcile: "fresh" },
    nativeLaneReleased: true,
    diagnosticsRedacted: true,
    svnCauseNames: ["SVN_ERR_AUTHN_FAILED", operation === "lock" ? "SVN_ERR_RA_NOT_AUTHORIZED" : "SVN_ERR_FS_NO_USER"],
  };
}

function processEnv() {
  return Object.fromEntries(Object.entries(process.env).filter(([, value]) => value !== undefined));
}
