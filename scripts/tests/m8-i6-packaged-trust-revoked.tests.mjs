import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const probe = path.join(repositoryRoot, "scripts", "release", "probe-m8-i6-packaged-trust-revoked.mjs");
const schema = "subversionr.release.m8-i6-packaged-native-trust-revoked.v1";
const fixtureSchema = "subversionr.release.m8-i6-ra-svn-fault-fixture.v1";
const operationId = "98765432-1234-4abc-8def-ba0987654321";

test("revokes trust through the production connection and rejects the prebuilt epoch-1 envelope without network access", async () => {
  const fixture = await createFixture({});
  try {
    const result = runProbe(fixture.args);
    assert.equal(result.status, 0, result.stderr || result.stdout);
    assert.equal(result.stderr, "");
    assert.deepEqual(JSON.parse(result.stdout), {
      schema,
      status: "passed",
      cell: "trustRevoked",
      stableCode: "SUBVERSIONR_REMOTE_TRUST_EPOCH_MISMATCH",
      reason: "remoteConfigurationInvalid",
      protocol: { major: 1, minor: 35 },
      trustTransition: {
        fromEpoch: 11,
        toEpoch: 12,
        staleEnvelopeEpoch: 11,
        remoteSubmissionEnabledAfter: false,
      },
      remoteSvnAnonymous: true,
      nativeLaneReleased: true,
      localSnapshotAfterTrustRevocation: true,
      workingCopyPreserved: true,
      networkAttempts: 0,
      temporaryRootsAfter: 0,
      credentialRootsAfter: 0,
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
    assert.deepEqual(capture.order, [
      "backend/start",
      "envelope/create",
      "repository/open",
      "workspaceTrust/update",
      "status/checkRemote",
      "status/getSnapshot",
      "diagnostics/get",
      "repository/close",
      "shutdown",
    ]);
    assert.deepEqual(capture.updateCalls, [{ trusted: false }]);
    assert.equal(capture.requests[0].method, "repository/open");
    assert.equal(capture.requests[1].method, "status/checkRemote");
    assert.equal(capture.requests[1].params.remote.trustEpoch, 11);
    assert.equal(capture.requests[1].params.remote.workspaceTrust, "trusted");
    assert.equal(capture.requests[1].params.remote.operationId, operationId);
    assert.equal(capture.shutdown, true);
    assert.deepEqual(capture.config, {
      clientName: "subversionr-m8-i6-packaged-trust-revoked-evidence",
      workspaceTrust: "trusted",
      appdata: fixture.profileRoot,
      temp: fixture.profileRoot,
    });
    assert.deepEqual(JSON.parse(await readFile(fixture.fixtureStatePath, "utf8")), fixture.initialState);
    assert.equal(await readFile(path.join(fixture.workingCopyPath, "tracked.txt"), "utf8"), "controlled trust-revoked content\n");
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("rejects wrong trust acknowledgement, epoch state, submission state, and missing update API", async () => {
  const cases = [
    [{ omitUpdate: true }, "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_CAPABILITY_INVALID"],
    [{ returnedEpoch: 13 }, "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_TRUST_INVALID"],
    [{ currentEpochAfter: 13 }, "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_TRUST_INVALID"],
    [{ submissionEnabledAfter: true }, "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_TRUST_INVALID"],
    [{ protocolMinor: 34 }, "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_CAPABILITY_INVALID"],
    [{ remoteSvnAnonymous: false }, "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_CAPABILITY_INVALID"],
  ];
  for (const [behavior, code] of cases) {
    const fixture = await createFixture(behavior);
    try {
      assertProbeFails(fixture.args, code, JSON.stringify(behavior));
    } finally {
      await rm(fixture.root, { recursive: true, force: true });
    }
  }
});

test("rejects every non-exact trust-epoch mismatch wire error and remote-failure taxonomy", async () => {
  const cases = [
    [{ errorResolves: true }, "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_ERROR_INVALID"],
    [{ errorName: "Error" }, "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_ERROR_INVALID"],
    [{ errorCode: "SUBVERSIONR_REMOTE_CONTRACT_INVALID" }, "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_ERROR_INVALID"],
    [{ errorCategory: "configuration" }, "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_ERROR_INVALID"],
    [{ errorMessageKey: "error.remote.contractInvalid" }, "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_ERROR_INVALID"],
    [{ retryable: true }, "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_ERROR_INVALID"],
    [{ diagnostics: {} }, "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_ERROR_INVALID"],
    [{ safeArgsExtra: true }, "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_ERROR_INVALID"],
    [{ failureCategory: "state" }, "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_FAILURE_INVALID"],
    [{ failureReason: "unknownRemote" }, "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_FAILURE_INVALID"],
    [{ cleanupAppropriate: true }, "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_FAILURE_INVALID"],
    [{ failureExtra: true }, "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_FAILURE_INVALID"],
  ];
  for (const [behavior, code] of cases) {
    const fixture = await createFixture(behavior);
    try {
      assertProbeFails(fixture.args, code, JSON.stringify(behavior));
    } finally {
      await rm(fixture.root, { recursive: true, force: true });
    }
  }
});

test("rejects unexpected network activity, credential interaction, and temporary or credential residue", async () => {
  const cases = [
    [{ unexpectedNetwork: "connections" }, "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_FIXTURE_STATE_INVALID"],
    [{ unexpectedNetwork: "authRequestSent" }, "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_FIXTURE_STATE_INVALID"],
    [{ credentialRequest: true }, "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_CREDENTIAL_HANDLER_INVOKED"],
    [{ workerResidue: true }, "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_WORKER_TEMP_RESIDUE"],
    [{ credentialResidue: true }, "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_CREDENTIAL_RESIDUE"],
  ];
  for (const [behavior, code] of cases) {
    const fixture = await createFixture(behavior);
    try {
      assertProbeFails(fixture.args, code, JSON.stringify(behavior));
    } finally {
      await rm(fixture.root, { recursive: true, force: true });
    }
  }
});

test("rejects local-lane, close, working-copy, diagnostics, and redaction tampering", async () => {
  const cases = [
    [{ snapshotSource: "remote" }, "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_LOCAL_SNAPSHOT_INVALID"],
    [{ snapshotEpoch: 99 }, "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_LOCAL_SNAPSHOT_INVALID"],
    [{ closeFalse: true }, "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_CLOSE_INVALID"],
    [{ tamperUserContent: true }, "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_WORKING_COPY_INVALID"],
    [{ removeEmptyDirectory: true }, "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_WORKING_COPY_INVALID"],
    [{ tamperWcDatabaseSameSize: true }, "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_WORKING_COPY_INVALID"],
    [{ diagnosticsLeak: "repository" }, "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_DIAGNOSTICS_LEAK"],
    [{ diagnosticsLeak: "fixture" }, "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_DIAGNOSTICS_LEAK"],
    [{ diagnosticsLeak: "operation" }, "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_DIAGNOSTICS_LEAK"],
    [{ errorLeak: true }, "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_ERROR_INVALID"],
  ];
  for (const [behavior, code] of cases) {
    const fixture = await createFixture(behavior);
    try {
      assertProbeFails(fixture.args, code, JSON.stringify(behavior));
    } finally {
      await rm(fixture.root, { recursive: true, force: true });
    }
  }
});

test("rejects malformed envelopes, origin binding, local repository identity, and fixture state", async () => {
  const cases = [
    [{ envelopeEpoch: 10 }, "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_ENVELOPE_INVALID"],
    [{ envelopeWorkspaceTrust: "untrusted" }, "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_ENVELOPE_INVALID"],
    [{ envelopeTimeout: 29_999 }, "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_ENVELOPE_INVALID"],
    [{ canonicalHost: "localhost" }, "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_ORIGIN_INVALID"],
    [{ workingCopyRepositoryUrl: "svn://127.0.0.1:43691/repo" }, "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_OPEN_INVALID"],
    [{ fixtureScenario: "connected-stall" }, "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_FIXTURE_STATE_INVALID"],
    [{ fixturePort: 43691 }, "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_FIXTURE_STATE_INVALID"],
    [{ fixtureInitialConnections: 1 }, "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_FIXTURE_STATE_INVALID"],
    [{ fixtureExtra: true }, "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_FIXTURE_STATE_INVALID"],
  ];
  for (const [behavior, code] of cases) {
    const fixture = await createFixture(behavior);
    try {
      assertProbeFails(fixture.args, code, JSON.stringify(behavior));
    } finally {
      await rm(fixture.root, { recursive: true, force: true });
    }
  }
});

test("rejects non-exact CLI, non-loopback URL, noncanonical operation IDs, and dirty profile roots", async () => {
  const fixture = await createFixture({});
  try {
    const cases = [
      [[...fixture.args, "--extra", "value"], "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_ARGUMENT_INVALID"],
      [[...fixture.args, "--timeout-ms", "30000"], "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_ARGUMENT_INVALID"],
      [replaceValue(fixture.args, "--operation-id", "98765432-1234-4ABC-8def-ba0987654321"), "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_ARGUMENT_INVALID"],
      [replaceValue(fixture.args, "--operation-id", "00000000-0000-0000-0000-000000000000"), "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_ARGUMENT_INVALID"],
      [replaceValue(fixture.args, "--repository-url", "svn://localhost:43690/repo"), "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_URL_INVALID"],
      [replaceValue(fixture.args, "--repository-url", "svn://127.0.0.1/repo"), "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_URL_INVALID"],
      [replaceValue(fixture.args, "--repository-url", "svn://user@127.0.0.1:43690/repo"), "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_URL_INVALID"],
      [replaceValue(fixture.args, "--fixture-state-path", "relative.json"), "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_ARGUMENT_INVALID"],
      [replaceValue(fixture.args, "--working-copy-path", "relative-wc"), "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_ARGUMENT_INVALID"],
    ];
    for (const [args, code] of cases) assertProbeFails(args, code);
    await writeFile(path.join(fixture.profileRoot, "not-empty"), "x", "utf8");
    assertProbeFails(fixture.args, "SUBVERSIONR_I6_PACKAGED_TRUST_REVOKED_FILESYSTEM_INVALID");
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

async function createFixture(behavior) {
  const root = await mkdtemp(path.join(os.tmpdir(), "subversionr-i6-packaged-trust-revoked-test-"));
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
  await writeFile(path.join(workingCopyPath, ".svn", "wc.db"), "controlled-trust-revoked-wc-db", "utf8");
  await writeFile(path.join(workingCopyPath, "tracked.txt"), "controlled trust-revoked content\n", "utf8");
  const backendModule = path.join(backendRoot, "backendProcess.js");
  const remoteAccessModule = path.join(securityRoot, "remoteAccessProfile.js");
  const daemon = path.join(tooling, "subversionr-daemon.exe");
  const bridge = path.join(tooling, "subversionr-native.dll");
  const repositoryUrl = "svn://127.0.0.1:43690/repo";
  const initialState = faultState({
    scenario: behavior.fixtureScenario ?? "greeting-stall",
    port: behavior.fixturePort ?? 43690,
    connections: behavior.fixtureInitialConnections ?? 0,
    ...(behavior.fixtureExtra === true ? { unexpected: true } : {}),
  });
  await writeFile(fixtureStatePath, JSON.stringify(initialState), "utf8");
  await writeFile(backendModule, fakeBackendSource(behavior, workingCopyPath, repositoryUrl, operationId, fixtureStatePath), "utf8");
  await writeFile(remoteAccessModule, fakeRemoteAccessProfileSource(behavior), "utf8");
  await writeFile(daemon, "fake-daemon", "utf8");
  await writeFile(bridge, "fake-bridge", "utf8");
  return {
    root,
    profileRoot,
    workingCopyPath,
    fixtureStatePath,
    initialState,
    repositoryUrl,
    capturePath: path.join(profileRoot, "remote-state", "capture.json"),
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
  globalThis.__SUBVERSIONR_I6_TRUST_ORDER = ["backend/start"];
  const capturePath = path.join(config.remoteStateRoot, "capture.json");
  const workerRoot = path.join(config.baseEnv.TEMP, "SubversionR", "remote-workers");
  fs.mkdirSync(workerRoot, { recursive: true });
  let currentEpoch = 11;
  let submissionEnabled = true;
  const capture = {
    order: globalThis.__SUBVERSIONR_I6_TRUST_ORDER, requests: [], updateCalls: [], shutdown: false,
    config: { clientName: config.clientName, workspaceTrust: config.workspaceTrust, appdata: config.baseEnv.APPDATA, temp: config.baseEnv.TEMP },
  };
  const save = () => fs.writeFileSync(capturePath, JSON.stringify(capture));
  const record = (method, params) => {
    capture.order.push(method); capture.requests.push({ method, params }); save();
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
    isRemoteSubmissionEnabled() { return submissionEnabled; },
    currentRemoteTrustEpoch() { return currentEpoch; },
    async updateWorkspaceTrust(trusted) {
      capture.order.push("workspaceTrust/update"); capture.updateCalls.push({ trusted });
      currentEpoch = behavior.currentEpochAfter ?? 12;
      submissionEnabled = behavior.submissionEnabledAfter ?? false;
      save();
      return behavior.returnedEpoch ?? 12;
    },
    async sendRequest(method, params) {
      record(method, params);
      if (method === "repository/open") return {
        repositoryId: "repo-trust", epoch: 17,
        identity: { workingCopyRoot: workingCopyPath, repositoryRootUrl: behavior.workingCopyRepositoryUrl ?? repositoryUrl },
      };
      if (method === "status/checkRemote") {
        if (behavior.unexpectedNetwork) {
          const state = JSON.parse(fs.readFileSync(fixtureStatePath, "utf8"));
          state[behavior.unexpectedNetwork] = 1;
          fs.writeFileSync(fixtureStatePath, JSON.stringify(state));
        }
        if (behavior.credentialRequest === true) {
          try { await handlers.requestHandler("credentials/request", {}); } catch {}
        }
        if (behavior.workerResidue === true) fs.mkdirSync(path.join(workerRoot, "residue"));
        if (behavior.credentialResidue === true) fs.mkdirSync(path.join(config.remoteStateRoot, "credentials"));
        if (behavior.tamperUserContent === true) fs.writeFileSync(path.join(workingCopyPath, "tracked.txt"), "tampered\\n");
        if (behavior.removeEmptyDirectory === true) fs.rmdirSync(path.join(workingCopyPath, "empty-directory"));
        if (behavior.tamperWcDatabaseSameSize === true) {
          const wcDatabasePath = path.join(workingCopyPath, ".svn", "wc.db");
          const bytes = fs.readFileSync(wcDatabasePath); bytes[0] ^= 0xff; fs.writeFileSync(wcDatabasePath, bytes);
        }
        if (behavior.errorResolves === true) return { unexpected: true };
        const error = new Error(behavior.errorCode ?? "SUBVERSIONR_REMOTE_TRUST_EPOCH_MISMATCH");
        error.name = behavior.errorName ?? "JsonRpcStreamError";
        error.code = behavior.errorCode ?? "SUBVERSIONR_REMOTE_TRUST_EPOCH_MISMATCH";
        error.category = behavior.errorCategory ?? "state";
        error.messageKey = behavior.errorMessageKey ?? "error.remote.trustEpochMismatch";
        error.retryable = behavior.retryable ?? false;
        error.diagnostics = Object.hasOwn(behavior, "diagnostics") ? behavior.diagnostics : null;
        error.safeArgs = {
          remoteFailure: {
            category: behavior.failureCategory ?? "configuration",
            reason: behavior.failureReason ?? "remoteConfigurationInvalid",
            cleanupAppropriate: behavior.cleanupAppropriate ?? false,
            ...(behavior.failureExtra === true ? { extra: true } : {}),
          },
          ...(behavior.safeArgsExtra === true ? { extra: true } : {}),
          ...(behavior.errorLeak === true ? { leaked: repositoryUrl } : {}),
        };
        throw error;
      }
      if (method === "status/getSnapshot") return {
        repositoryId: "repo-trust", epoch: behavior.snapshotEpoch ?? 17,
        source: behavior.snapshotSource ?? "libsvn-local",
      };
      if (method === "diagnostics/get") return {
        source: "subversionr-daemon",
        protocol: { major: 1, minor: 35 },
        capabilities: { remoteSvnAnonymous: true, statusRemoteCheck: true, statusSnapshot: true },
        entries: [],
        ...(behavior.diagnosticsLeak === "repository" ? { leaked: repositoryUrl } : {}),
        ...(behavior.diagnosticsLeak === "fixture" ? { leaked: fixtureStatePath } : {}),
        ...(behavior.diagnosticsLeak === "operation" ? { leaked: externalOperationId } : {}),
      };
      if (method === "repository/close") return { repositoryId: "repo-trust", epoch: 17, closed: behavior.closeFalse !== true };
      throw new Error("UNEXPECTED_METHOD");
    },
    async shutdown() { capture.order.push("shutdown"); capture.shutdown = true; save(); },
    dispose() { capture.disposed = true; save(); },
  };
  if (behavior.omitUpdate === true) delete result.updateWorkspaceTrust;
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
    globalThis.__SUBVERSIONR_I6_TRUST_ORDER.push("envelope/create");
    return {
      version: 1, operationId: input.operationId, intent: input.intent,
      interaction: input.interaction, timeoutMs: behavior.envelopeTimeout ?? input.timeoutMs,
      workspaceTrust: behavior.envelopeWorkspaceTrust ?? "trusted",
      trustEpoch: behavior.envelopeEpoch ?? this.admission.currentRemoteTrustEpoch(),
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
