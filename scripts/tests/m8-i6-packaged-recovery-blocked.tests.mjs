import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const PROBE = path.join(REPO_ROOT, "scripts/release/probe-m8-i6-packaged-recovery-blocked.mjs");
const SCHEMA = "subversionr.release.m8-i6-packaged-native-recovery-blocked.v1";
const ORIGIN_ID = "12345678-1234-4234-8234-123456789abc";

test("proves blocked restart isolation through an unrelated HEAD checkout, exact disposition, and healthy fresh checkout", async () => {
  const fixture = await createFixture();
  try {
    const targetSha256 = sha256(path.resolve(fixture.checkoutTarget));
    const unrelatedTargetSha256 = sha256(path.resolve(fixture.unrelatedCheckoutTarget));
    const originSha256 = sha256(ORIGIN_ID);
    const blockedJournalSha256 = sha256(JSON.stringify({
      schemaVersion: 1,
      entries: [{
        targetPath: path.resolve(fixture.checkoutTarget),
        targetSha256,
        originOperationId: ORIGIN_ID,
        effect: "checkoutTarget",
        state: "blocked",
      }],
    }));
    const result = runProbe(fixture.args);
    assert.equal(result.status, 0, result.stderr || result.stdout);
    assert.equal(result.stderr, "");
    assert.deepEqual(JSON.parse(result.stdout), {
      schema: SCHEMA,
      status: "passed",
      cell: "recoveryBlocked",
      protocol: { major: 1, minor: 35 },
      remoteSvnAnonymous: true,
      originCode: "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT",
      originReason: "operationDeadlineExceeded",
      settlementCode: "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED",
      settlementReason: "remoteRecoveryBlocked",
      journalState: "blocked",
      commandBarrierObserved: true,
      journalArmedObserved: true,
      armedWindowObserved: true,
      targetAttributionHashed: true,
      armedTargetPathSha256: targetSha256,
      armedOriginOperationIdSha256: originSha256,
      partialTargetObserved: false,
      daemonRestartRequired: true,
      restartListExact: true,
      unrelatedRepositoryServed: true,
      blockedEntryUnchangedAfterUnrelated: true,
      blockedJournalUnchangedAfterUnrelated: true,
      blockedJournalBytesSha256BeforeUnrelated: blockedJournalSha256,
      blockedJournalBytesSha256AfterUnrelated: blockedJournalSha256,
      unrelatedCheckoutRevision: 2,
      unrelatedTargetPathSha256: unrelatedTargetSha256,
      journalStateBeforeConfirmation: "blocked",
      automaticCleanupBeforeConfirmation: false,
      sameTargetFailClosed: true,
      fixtureCountersUnchangedOnBlockedRetry: true,
      blockedCode: "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED",
      blockedReason: "remoteRecoveryBlocked",
      confirmation: "reviewedAndResolved",
      confirmationAttributionHashed: true,
      confirmedTargetPathSha256: targetSha256,
      confirmedOriginOperationIdSha256: originSha256,
      journalEntriesAfter: 0,
      operatorDisposition: "confirmedAbsent",
      targetAbsentBeforeConfirmation: true,
      freshCheckout: true,
      freshCheckoutRevision: 7,
      targetDisposition: "confirmedAbsent",
      blocked: {
        outcome: "Blocked",
        stableCode: "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED",
        reason: "remoteRecoveryBlocked",
        restartRestoredBlocked: true,
        automaticClear: false,
        requiredConfirmation: "reviewedAndResolved",
        armedTargetPathSha256: targetSha256,
        confirmedTargetPathSha256: targetSha256,
        armedOriginOperationIdSha256: originSha256,
        confirmedOriginOperationIdSha256: originSha256,
        confirmedEntryRemoved: true,
        subsequentCheckoutPassed: true,
      },
      daemonRestarts: 1,
      credentialRequests: 0,
      credentialSettlements: 0,
      temporaryRootsAfter: 0,
      diagnosticsRedacted: true,
      fixtureCliInvocations: 0,
    });
    for (const sensitive of [
      fixture.faultUrl,
      fixture.healthyUrl,
      fixture.unrelatedUrl,
      fixture.checkoutTarget,
      fixture.unrelatedCheckoutTarget,
      fixture.profileRoot,
      fixture.faultStatePath,
      ORIGIN_ID,
    ]) {
      assert.equal(result.stdout.toLowerCase().includes(sensitive.toLowerCase()), false);
      assert.equal(result.stdout.toLowerCase().includes(JSON.stringify(sensitive).slice(1, -1).toLowerCase()), false);
    }

    const journal = JSON.parse(await readFile(path.join(fixture.profileRoot, "remote-state", "subversionr-remote-checkout-mutations-v1.json"), "utf8"));
    assert.deepEqual(journal, { schemaVersion: 1, entries: [] });
    const capture = JSON.parse(await readFile(path.join(fixture.profileRoot, "remote-state", "capture.json"), "utf8"));
    assert.equal(capture.starts, 2);
    assert.deepEqual(capture.clients, [
      "subversionr-m8-i6-packaged-recovery-blocked-origin",
      "subversionr-m8-i6-packaged-recovery-blocked-restart",
    ]);
    assert.deepEqual(capture.methods, [
      "repository/checkout",
      "remote/listCheckoutTargetRecoveries",
      "diagnostics/get",
      "remote/listCheckoutTargetRecoveries",
      "repository/checkout",
      "remote/listCheckoutTargetRecoveries",
      "repository/checkout",
      "remote/listCheckoutTargetRecoveries",
      "remote/confirmCheckoutTargetDisposition",
      "remote/listCheckoutTargetRecoveries",
      "repository/checkout",
      "remote/listCheckoutTargetRecoveries",
      "diagnostics/get",
    ]);
    assert.equal(capture.shutdowns, 2);
    assert.equal(capture.sameTargetBlockedBeforeNetwork, true);
    assert.equal(capture.unrelatedWorkerLikeRequests, 1);
    assert.equal(path.resolve(capture.unrelatedTargetPath), path.resolve(fixture.unrelatedCheckoutTarget));
    assert.equal(capture.unrelatedRepositoryUrl, fixture.unrelatedUrl);
    assert.notEqual(capture.unrelatedOperationId, ORIGIN_ID);
    assert.equal(capture.unrelatedRequestedRevision, "head");
    assert.equal(capture.confirmation, "reviewedAndResolved");
    assert.equal(capture.requestHandlerType, "function");
    assert.equal(capture.notificationHandlerType, "function");
    assert.equal((await readFile(path.join(fixture.unrelatedCheckoutTarget, ".svn", "wc.db"))).byteLength > 0, true);
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("rejects a non-exact command barrier instead of inferring the armed window", async () => {
  const fixture = await createFixture({ followupContacts: 1 }, { originSettlementDelayMs: 3000 });
  try {
    const result = runProbe(fixture.args);
    assert.equal(result.status, 1);
    assert.deepEqual(JSON.parse(result.stdout), failed("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_ARMED_WINDOW_NOT_OBSERVED"));
    assert.equal(result.stderr, "");
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("rejects restart list attribution tampering", async () => {
  const fixture = await createFixture({}, { tamperRestartList: true });
  try {
    const result = runProbe(fixture.args);
    assert.equal(result.status, 1);
    assert.deepEqual(JSON.parse(result.stdout), failed("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_LIST_INVALID"));
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("rejects blocked-entry serialization tampering immediately after the unrelated checkout", async () => {
  const fixture = await createFixture({}, { tamperListAfterUnrelated: true });
  try {
    const result = runProbe(fixture.args);
    assert.equal(result.status, 1);
    assert.deepEqual(JSON.parse(result.stdout), failed("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_ENTRY_CHANGED_AFTER_UNRELATED"));
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("rejects raw blocked-journal byte changes after the unrelated checkout", async () => {
  const fixture = await createFixture({}, { mutateJournalAfterUnrelated: true });
  try {
    const result = runProbe(fixture.args);
    assert.equal(result.status, 1);
    assert.deepEqual(JSON.parse(result.stdout), failed("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_JOURNAL_CHANGED_AFTER_UNRELATED"));
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("rejects an unrelated checkout failure", async () => {
  const fixture = await createFixture({}, { unrelatedCheckoutFailure: true });
  try {
    const result = runProbe(fixture.args);
    assert.equal(result.status, 1);
    assert.deepEqual(JSON.parse(result.stdout), failed("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_UNRELATED_CHECKOUT_FAILED"));
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("rejects an unrelated checkout response path mismatch", async () => {
  const fixture = await createFixture({}, { unrelatedCheckoutPathMismatch: true });
  try {
    const result = runProbe(fixture.args);
    assert.equal(result.status, 1);
    assert.deepEqual(JSON.parse(result.stdout), failed("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_UNRELATED_CHECKOUT_INVALID"));
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("rejects an unrelated checkout response outside the deterministic r2 fixture", async () => {
  const fixture = await createFixture({}, { unrelatedCheckoutRevision: 3 });
  try {
    const result = runProbe(fixture.args);
    assert.equal(result.status, 1);
    assert.deepEqual(JSON.parse(result.stdout), failed("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_UNRELATED_CHECKOUT_INVALID"));
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("rejects an empty unrelated working-copy database", async () => {
  const fixture = await createFixture({}, { unrelatedEmptyWcDb: true });
  try {
    const result = runProbe(fixture.args);
    assert.equal(result.status, 1);
    assert.deepEqual(JSON.parse(result.stdout), failed("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_UNRELATED_WC_DB_INVALID"));
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("rejects any fault-fixture state change during the fail-closed retry", async () => {
  const fixture = await createFixture({}, { mutateFaultStateOnRetry: true });
  try {
    const result = runProbe(fixture.args);
    assert.equal(result.status, 1);
    assert.deepEqual(JSON.parse(result.stdout), failed("SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_FIXTURE_CONTACTED_ON_RETRY"));
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("strict CLI rejects aliases, missing values, short origin deadlines, and non-loopback URLs", async () => {
  const fixture = await createFixture();
  try {
    const cases = [
      [[...fixture.args, "--extra", "value"], "SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_ARGUMENT_INVALID"],
      [fixture.args.slice(0, -2), "SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_ARGUMENT_INVALID"],
      [removeOption(fixture.args, "--unrelated-repository-url"), "SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_ARGUMENT_INVALID"],
      [removeOption(fixture.args, "--unrelated-checkout-target"), "SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_ARGUMENT_INVALID"],
      [replaceValue(fixture.args, "--origin-timeout-ms", "999"), "SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_ARGUMENT_INVALID"],
      [replaceValue(fixture.args, "--healthy-repository-url", "svn://localhost:3690/repo/trunk"), "SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_URL_INVALID"],
      [replaceValue(fixture.args, "--unrelated-repository-url", "svn://localhost:3690/repo/trunk"), "SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_URL_INVALID"],
      [replaceValue(fixture.args, "--unrelated-repository-url", "svn://127.0.0.1:43114/repo/trunk"), "SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_URL_INVALID"],
      [replaceValue(fixture.args, "--unrelated-repository-url", fixture.healthyUrl), "SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_URL_INVALID"],
      [replaceValue(fixture.args, "--unrelated-checkout-target", fixture.checkoutTarget), "SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_ARGUMENT_INVALID"],
      [replaceValue(fixture.args, "--fault-repository-url", "svn://127.0.0.1:3690/other"), "SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_URL_INVALID"],
      [replaceValue(fixture.args, "--origin-operation-id", "NOT-A-UUID"), "SUBVERSIONR_I6_PACKAGED_RECOVERY_BLOCKED_ARGUMENT_INVALID"],
    ];
    for (const [args, expectedCode] of cases) {
      const result = runProbe(args);
      assert.equal(result.status, 1);
      assert.deepEqual(JSON.parse(result.stdout), failed(expectedCode));
      assert.equal(result.stderr, "");
    }
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

async function createFixture(fixturePatch = {}, behavior = {}) {
  const root = await mkdtemp(path.join(os.tmpdir(), "subversionr-i6-recovery-blocked-test-"));
  const tooling = path.join(root, "tooling");
  const backendRoot = path.join(tooling, "dist", "backend");
  const securityRoot = path.join(tooling, "dist", "security");
  const profileRoot = path.join(root, "profile");
  const workspace = path.join(root, "workspace");
  await mkdir(backendRoot, { recursive: true });
  await mkdir(securityRoot, { recursive: true });
  await mkdir(profileRoot);
  await mkdir(workspace);
  const backendModule = path.join(backendRoot, "backendProcess.js");
  const remoteAccessModule = path.join(securityRoot, "remoteAccessProfile.js");
  const daemon = path.join(tooling, "subversionr-daemon.exe");
  const bridge = path.join(tooling, "subversionr-native.dll");
  const faultStatePath = path.join(root, "fault-state.json");
  const checkoutTarget = path.join(workspace, "checkout");
  const unrelatedCheckoutTarget = path.join(workspace, "unrelated-checkout");
  const faultUrl = "svn://127.0.0.1:43111/repo/trunk";
  const healthyUrl = "svn://127.0.0.1:43112/repo/trunk";
  const unrelatedUrl = "svn://127.0.0.1:43113/unrelated/trunk";
  await writeFile(backendModule, fakeBackendSource(behavior), "utf8");
  await writeFile(remoteAccessModule, fakeRemoteAccessSource(), "utf8");
  await writeFile(daemon, "daemon", "utf8");
  await writeFile(bridge, "bridge", "utf8");
  await writeFile(faultStatePath, JSON.stringify({
    schema: "subversionr.release.m8-i6-ra-svn-fault-fixture.v1",
    scenario: "command-stall",
    connections: 1,
    greetingSent: 1,
    clientResponseReceived: 1,
    authRequestSent: 1,
    reposInfoSent: 1,
    commandsReceived: 1,
    followupContacts: 0,
    ...fixturePatch,
  }), "utf8");
  return {
    root,
    profileRoot,
    checkoutTarget,
    unrelatedCheckoutTarget,
    faultStatePath,
    faultUrl,
    healthyUrl,
    unrelatedUrl,
    args: [
      "--backend-module", backendModule,
      "--daemon", daemon,
      "--bridge", bridge,
      "--profile-root", profileRoot,
      "--checkout-target", checkoutTarget,
      "--fault-repository-url", faultUrl,
      "--healthy-repository-url", healthyUrl,
      "--unrelated-repository-url", unrelatedUrl,
      "--unrelated-checkout-target", unrelatedCheckoutTarget,
      "--fault-state-path", faultStatePath,
      "--origin-operation-id", ORIGIN_ID,
      "--origin-timeout-ms", "1100",
      "--healthy-timeout-ms", "30000",
      "--checkout-revision", "7",
    ],
  };
}

function fakeBackendSource(behavior) {
  return `
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const behavior = ${JSON.stringify(behavior)};

exports.startBackendProcess = async function(config, handlers) {
  const journalPath = path.join(config.remoteStateRoot, "subversionr-remote-checkout-mutations-v1.json");
  const capturePath = path.join(config.remoteStateRoot, "capture.json");
  const readCapture = () => fs.existsSync(capturePath) ? JSON.parse(fs.readFileSync(capturePath, "utf8")) : {
    starts: 0, clients: [], methods: [], shutdowns: 0, sameTargetBlockedBeforeNetwork: false,
    restartLists: 0, unrelatedWorkerLikeRequests: 0, unrelatedTargetPath: null, unrelatedOperationId: null,
    unrelatedRepositoryUrl: null, unrelatedRequestedRevision: null,
    confirmation: null, requestHandlerType: null, notificationHandlerType: null,
  };
  const writeCapture = (capture) => fs.writeFileSync(capturePath, JSON.stringify(capture));
  const capture = readCapture();
  capture.starts += 1;
  capture.clients.push(config.clientName);
  capture.requestHandlerType = typeof handlers.requestHandler;
  capture.notificationHandlerType = typeof handlers.notificationHandler;
  writeCapture(capture);
  if (!fs.existsSync(journalPath)) fs.writeFileSync(journalPath, JSON.stringify({ schemaVersion: 1, entries: [] }));
  const start = capture.starts;
  let trustEpoch = 1;
  const connection = {
    initializeResult: {
      protocol: { major: 1, minor: 35 },
      acknowledgedTrustEpoch: 1,
      capabilities: {
        realLibsvnBridge: true, repositoryCheckout: true, remoteOperationEnvelope: true,
        remoteWorkerIsolation: true, remoteSvnAnonymous: true,
      },
    },
    isRemoteSubmissionEnabled: () => true,
    currentRemoteTrustEpoch: () => trustEpoch,
    sendRequest: async (method, params) => {
      const current = readCapture();
      current.methods.push(method);
      writeCapture(current);
      if (method === "diagnostics/get") return {
        source: "subversionr-daemon", protocol: { major: 1, minor: 35 }, capabilities: { remoteSvnAnonymous: true },
      };
      if (method === "remote/listCheckoutTargetRecoveries") {
        const observed = readCapture();
        if (start === 2) observed.restartLists += 1;
        writeCapture(observed);
        const journal = JSON.parse(fs.readFileSync(journalPath, "utf8"));
        const entries = journal.entries.map(({ targetPath, targetSha256, originOperationId, state }) => {
          const effectiveOriginOperationId = behavior.tamperRestartList === true && start === 2 && observed.restartLists === 1
            ? "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
            : originOperationId;
          if (behavior.tamperListAfterUnrelated === true && start === 2 && observed.restartLists === 2) {
            return { state, originOperationId: effectiveOriginOperationId, targetSha256, targetPath };
          }
          return { targetPath, targetSha256, originOperationId: effectiveOriginOperationId, state };
        });
        return { entries };
      }
      if (method === "remote/confirmCheckoutTargetDisposition") {
        const journal = JSON.parse(fs.readFileSync(journalPath, "utf8"));
        const entry = journal.entries[0];
        if (!entry || params.confirmation !== "reviewedAndResolved" || params.targetPath !== entry.targetPath ||
            params.targetSha256 !== entry.targetSha256 || params.originOperationId !== entry.originOperationId) {
          throw new Error("confirmation mismatch");
        }
        fs.writeFileSync(journalPath, JSON.stringify({ schemaVersion: 1, entries: [] }));
        const updated = readCapture();
        updated.confirmation = params.confirmation;
        writeCapture(updated);
        return { released: true, targetSha256: entry.targetSha256, originOperationId: entry.originOperationId };
      }
      if (method === "repository/checkout" && start === 1) {
        const targetPath = path.resolve(params.targetPath);
        const targetSha256 = crypto.createHash("sha256").update(targetPath, "utf8").digest("hex");
        fs.writeFileSync(journalPath, JSON.stringify({ schemaVersion: 1, entries: [{
          targetPath, targetSha256, originOperationId: params.remote.operationId,
          effect: "checkoutTarget", state: "armed",
        }] }));
        await new Promise((resolve) => setTimeout(resolve, behavior.originSettlementDelayMs ?? 1050));
        const journal = JSON.parse(fs.readFileSync(journalPath, "utf8"));
        journal.entries[0].state = "blocked";
        fs.writeFileSync(journalPath, JSON.stringify(journal));
        throw recoveryBlocked(true);
      }
      if (method === "repository/checkout") {
        const journal = JSON.parse(fs.readFileSync(journalPath, "utf8"));
        if (journal.entries.length === 1 && path.resolve(params.targetPath) === path.resolve(journal.entries[0].targetPath)) {
          const updated = readCapture();
          updated.sameTargetBlockedBeforeNetwork = true;
          writeCapture(updated);
          if (behavior.mutateFaultStateOnRetry === true) {
            const faultStatePath = path.resolve(config.remoteStateRoot, "..", "..", "fault-state.json");
            const faultState = JSON.parse(fs.readFileSync(faultStatePath, "utf8"));
            faultState.probeMutation = 1;
            fs.writeFileSync(faultStatePath, JSON.stringify(faultState));
          }
          throw recoveryBlocked(false);
        }
        if (journal.entries.length === 1) {
          const updated = readCapture();
          updated.unrelatedWorkerLikeRequests += 1;
          updated.unrelatedTargetPath = params.targetPath;
          updated.unrelatedRepositoryUrl = params.url;
          updated.unrelatedOperationId = params.remote.operationId;
          updated.unrelatedRequestedRevision = params.revision;
          writeCapture(updated);
          if (behavior.unrelatedCheckoutFailure === true) throw new Error("unrelated checkout failed");
          fs.mkdirSync(path.join(params.targetPath, ".svn"), { recursive: true });
          fs.writeFileSync(path.join(params.targetPath, ".svn", "wc.db"), behavior.unrelatedEmptyWcDb === true ? "" : "unrelated-wc");
          if (behavior.mutateJournalAfterUnrelated === true) fs.appendFileSync(journalPath, "\\n");
          return {
            workingCopyPath: behavior.unrelatedCheckoutPathMismatch === true
              ? path.join(params.targetPath, "mismatch")
              : params.targetPath,
            revision: behavior.unrelatedCheckoutRevision ?? 2,
          };
        }
        fs.mkdirSync(path.join(params.targetPath, ".svn"), { recursive: true });
        fs.writeFileSync(path.join(params.targetPath, ".svn", "wc.db"), "wc");
        return { workingCopyPath: params.targetPath, revision: params.revision };
      }
      throw new Error("unexpected method " + method);
    },
    shutdown: async () => {
      const updated = readCapture();
      updated.shutdowns += 1;
      writeCapture(updated);
    },
    dispose: () => undefined,
  };
  return connection;
};

function recoveryBlocked(origin) {
  return {
    code: "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED", category: "state",
    messageKey: "error.remote.recoveryBlocked", retryable: false, diagnostics: null,
    safeArgs: origin ? {
      originFailureCode: "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT",
      remoteFailure: { category: "recovery", reason: "remoteRecoveryBlocked", cleanupAppropriate: false },
    } : {},
  };
}
`;
}

function fakeRemoteAccessSource() {
  return `
exports.canonicalEndpointFromRepositoryUrl = function(value) {
  const url = new URL(value);
  return { scheme: "svn", canonicalHost: url.hostname, effectivePort: Number(url.port) };
};
exports.RemoteOperationEnvelopeFactory = class {
  constructor(state) { this.state = state; }
  createAnonymousSvn(input) {
    if (!this.state.remoteSvnAnonymous || !this.state.isRemoteSubmissionEnabled()) throw new Error("disabled");
    return { version: 1, ...input, workspaceTrust: "trusted", trustEpoch: this.state.currentRemoteTrustEpoch() };
  }
};
`;
}

function runProbe(args) {
  return spawnSync(process.execPath, [PROBE, ...args], { encoding: "utf8", timeout: 10_000 });
}

function replaceValue(args, flag, value) {
  const copy = [...args];
  copy[copy.indexOf(flag) + 1] = value;
  return copy;
}

function removeOption(args, flag) {
  const copy = [...args];
  copy.splice(copy.indexOf(flag), 2);
  return copy;
}

function failed(code) {
  return { schema: SCHEMA, status: "failed", error: { code } };
}

function sha256(value) {
  return createHash("sha256").update(value, "utf8").digest("hex");
}
