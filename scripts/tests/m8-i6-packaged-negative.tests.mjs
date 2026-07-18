import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const probe = path.join(repositoryRoot, "scripts", "release", "probe-m8-i6-packaged-negative.mjs");
const schema = "subversionr.release.m8-i6-packaged-native-negative.v1";
const scenarios = {
  "malicious-root": {
    code: "SUBVERSIONR_REMOTE_ORIGIN_MISMATCH",
    reason: "crossAuthorityRejected",
    settlementCode: "SUBVERSIONR_REMOTE_ORIGIN_MISMATCH",
    settlementCategory: "policy",
    settlementReason: "crossAuthorityRejected",
  },
  "sasl-only": {
    code: "SUBVERSIONR_REMOTE_AUTH_UNSUPPORTED",
    reason: "remoteCapabilityUnsupported",
    settlementCode: "SUBVERSIONR_REMOTE_AUTH_UNSUPPORTED",
    settlementCategory: "capability",
    settlementReason: "remoteCapabilityUnsupported",
  },
  "greeting-stall": {
    code: "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT",
    reason: "operationDeadlineExceeded",
    settlementCode: "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED",
    settlementCategory: "recovery",
    settlementReason: "remoteRecoveryBlocked",
  },
  "connected-stall": {
    code: "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT",
    reason: "operationDeadlineExceeded",
    settlementCode: "SUBVERSIONR_REMOTE_RECOVERY_BLOCKED",
    settlementCategory: "recovery",
    settlementReason: "remoteRecoveryBlocked",
  },
};

for (const [scenario, expected] of Object.entries(scenarios)) {
  test(`accepts the exact ${scenario} packaged failure observation`, async () => {
    const fixture = await createFixture(scenario, expected);
    try {
      const result = runProbe(fixture.args);
      assert.equal(result.status, 0, result.stderr || result.stdout);
      assert.equal(result.stderr, "");
      assert.deepEqual(JSON.parse(result.stdout), {
        schema,
        status: "passed",
        scenario,
        code: expected.code,
        reason: expected.reason,
        settlementCode: expected.settlementCode,
        settlementReason: expected.settlementReason,
        protocol: { major: 1, minor: 35 },
        remoteSvnAnonymous: true,
        temporaryRootsAfter: 0,
        credentialRequests: 0,
        credentialSettlements: 0,
        diagnosticsRedacted: true,
        fixtureCliInvocations: 0,
      });
      assert.equal(result.stdout.includes(fixture.repositoryUrl), false);
      assert.equal(result.stdout.includes(fixture.checkoutTarget), false);
      assert.equal(result.stdout.includes(fixture.profileRoot), false);

      const capture = JSON.parse(await readFile(fixture.capturePath, "utf8"));
      assert.equal(capture.shutdown, true);
      assert.equal(capture.requestHandlerType, "function");
      assert.equal(capture.notificationHandlerType, "function");
      assert.deepEqual(capture.methods, ["repository/checkout", "diagnostics/get"]);
      assert.equal(capture.requests.length, 2);
      requireCheckoutShape(capture.requests[0], fixture);
    } finally {
      await rm(fixture.root, { recursive: true, force: true });
    }
  });
}

test("rejects wrong stable codes, taxonomy reasons, and unexpected success", async () => {
  const cases = [
    {
      behavior: { settlementCode: "SUBVERSIONR_REMOTE_WORKER_CRASHED" },
      failureCode: "SUBVERSIONR_I6_PACKAGED_NEGATIVE_ERROR_CODE_INVALID",
    },
    {
      behavior: { settlementReason: "workerContainmentFailed" },
      failureCode: "SUBVERSIONR_I6_PACKAGED_NEGATIVE_REMOTE_FAILURE_INVALID",
    },
    {
      behavior: { success: true },
      failureCode: "SUBVERSIONR_I6_PACKAGED_NEGATIVE_UNEXPECTED_SUCCESS",
    },
  ];
  for (const { behavior, failureCode } of cases) {
    const expected = scenarios["malicious-root"];
    const fixture = await createFixture("malicious-root", { ...expected, ...behavior });
    try {
      const result = runProbe(fixture.args);
      assert.equal(result.status, 1);
      assert.deepEqual(JSON.parse(result.stdout), failed(failureCode));
      assert.equal(result.stderr, "");
    } finally {
      await rm(fixture.root, { recursive: true, force: true });
    }
  }
});

test("rejects a recovery settlement that omits the originating timeout code", async () => {
  const expected = scenarios["greeting-stall"];
  const fixture = await createFixture("greeting-stall", { ...expected, omitOriginFailureCode: true });
  try {
    const result = runProbe(fixture.args);
    assert.equal(result.status, 1);
    assert.deepEqual(JSON.parse(result.stdout), failed("SUBVERSIONR_I6_PACKAGED_NEGATIVE_ORIGIN_FAILURE_INVALID"));
    assert.equal(result.stderr, "");
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("rejects non-exact CLI arguments and non-loopback SVN origins", async () => {
  const fixture = await createFixture("malicious-root", scenarios["malicious-root"]);
  try {
    const cases = [
      [...fixture.args, "--extra", "value"],
      replaceArgumentName(fixture.args, "--scenario", "--daemon"),
      replaceArgumentValue(fixture.args, "--scenario", "unknown"),
      replaceArgumentValue(fixture.args, "--timeout-ms", "0100"),
      replaceArgumentValue(fixture.args, "--repository-url", "svn://localhost:3690/repo"),
      replaceArgumentValue(fixture.args, "--repository-url", "svn://127.0.0.1:3690/repo?secret=value"),
      replaceArgumentValue(fixture.args, "--repository-url", "svn://user@127.0.0.1:3690/repo"),
      replaceArgumentValue(fixture.args, "--repository-url", "http://127.0.0.1:3690/repo"),
    ];
    for (const args of cases) {
      const result = runProbe(args);
      assert.equal(result.status, 1);
      const observation = JSON.parse(result.stdout);
      assert.equal(observation.schema, schema);
      assert.equal(observation.status, "failed");
      assert.match(observation.error.code, /^SUBVERSIONR_I6_PACKAGED_NEGATIVE_/u);
      assert.deepEqual(Object.keys(observation), ["schema", "status", "error"]);
      assert.equal(result.stdout.includes(fixture.checkoutTarget), false);
      assert.equal(result.stdout.includes(fixture.profileRoot), false);
      assert.equal(result.stderr, "");
    }
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("refuses diagnostic data containing repository URLs or local paths", async () => {
  for (const leak of ["repositoryUrl", "checkoutTarget", "profileRoot"]) {
    const fixture = await createFixture("malicious-root", { ...scenarios["malicious-root"], leak });
    try {
      const result = runProbe(fixture.args);
      assert.equal(result.status, 1);
      assert.deepEqual(JSON.parse(result.stdout), failed("SUBVERSIONR_I6_PACKAGED_NEGATIVE_DIAGNOSTICS_LEAK"));
      assert.equal(result.stdout.includes(fixture.repositoryUrl), false);
      assert.equal(result.stdout.includes(fixture.checkoutTarget), false);
      assert.equal(result.stdout.includes(fixture.profileRoot), false);
    } finally {
      await rm(fixture.root, { recursive: true, force: true });
    }
  }
});

test("rejects worker temporary-root residue", async () => {
  const fixture = await createFixture("connected-stall", { ...scenarios["connected-stall"], residue: true });
  try {
    const result = runProbe(fixture.args);
    assert.equal(result.status, 1);
    assert.deepEqual(JSON.parse(result.stdout), failed("SUBVERSIONR_I6_PACKAGED_NEGATIVE_WORKER_TEMP_RESIDUE"));
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("rejects non-exact protocol and anonymous capability state", async () => {
  const cases = [
    { protocolMinor: 36 },
    { realLibsvnBridge: false },
    { remoteSvnAnonymous: false },
    { remoteSubmissionEnabled: false },
    { currentTrustEpoch: 8 },
  ];
  for (const behavior of cases) {
    const fixture = await createFixture("sasl-only", { ...scenarios["sasl-only"], ...behavior });
    try {
      const result = runProbe(fixture.args);
      assert.equal(result.status, 1);
      assert.deepEqual(JSON.parse(result.stdout), failed("SUBVERSIONR_I6_PACKAGED_NEGATIVE_CAPABILITY_INVALID"));
    } finally {
      await rm(fixture.root, { recursive: true, force: true });
    }
  }
});

async function createFixture(scenario, behavior) {
  const root = await mkdtemp(path.join(os.tmpdir(), "subversionr-i6-packaged-negative-test-"));
  const tooling = path.join(root, "tooling");
  const distRoot = path.join(tooling, "dist");
  const backendRoot = path.join(distRoot, "backend");
  const securityRoot = path.join(distRoot, "security");
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
  await writeFile(backendModule, fakeBackendSource(behavior), "utf8");
  await writeFile(remoteAccessModule, fakeRemoteAccessProfileSource(), "utf8");
  await writeFile(daemon, "fake-daemon", "utf8");
  await writeFile(bridge, "fake-bridge", "utf8");

  const checkoutTarget = path.join(workspace, "checkout");
  const repositoryUrl = "svn://127.0.0.1:43690/repo/trunk";
  const timeoutMs = scenario.endsWith("stall") ? "75" : "30000";
  const args = [
    "--backend-module", backendModule,
    "--daemon", daemon,
    "--bridge", bridge,
    "--profile-root", profileRoot,
    "--checkout-target", checkoutTarget,
    "--repository-url", repositoryUrl,
    "--scenario", scenario,
    "--timeout-ms", timeoutMs,
  ];
  return {
    root,
    args,
    profileRoot,
    checkoutTarget,
    repositoryUrl,
    timeoutMs: Number(timeoutMs),
    capturePath: path.join(profileRoot, "remote-state", "capture.json"),
  };
}

function fakeBackendSource(behavior) {
  return `
const fs = require("node:fs");
const path = require("node:path");
const behavior = ${JSON.stringify(behavior)};

exports.startBackendProcess = async function startBackendProcess(config, handlers) {
  const capturePath = path.join(config.remoteStateRoot, "capture.json");
  const workerRoot = path.join(config.baseEnv.TEMP, "SubversionR", "remote-workers");
  fs.mkdirSync(workerRoot, { recursive: true });
  if (behavior.residue === true) {
    fs.mkdirSync(path.join(workerRoot, "residue"));
  }
  const capture = {
    requestHandlerType: typeof handlers.requestHandler,
    notificationHandlerType: typeof handlers.notificationHandler,
    methods: [],
    requests: [],
    shutdown: false,
  };
  const save = () => fs.writeFileSync(capturePath, JSON.stringify(capture));
  save();
  return {
    initializeResult: {
      protocol: { major: 1, minor: behavior.protocolMinor ?? 35 },
      capabilities: {
        repositoryCheckout: true,
        remoteOperationEnvelope: true,
        remoteWorkerIsolation: true,
        realLibsvnBridge: behavior.realLibsvnBridge ?? true,
        remoteSvnAnonymous: behavior.remoteSvnAnonymous ?? true,
      },
      acknowledgedTrustEpoch: 7,
    },
    isRemoteSubmissionEnabled() {
      return behavior.remoteSubmissionEnabled ?? true;
    },
    currentRemoteTrustEpoch() {
      return behavior.currentTrustEpoch ?? 7;
    },
    async sendRequest(method, params) {
      capture.methods.push(method);
      capture.requests.push({ method, params });
      save();
      if (method === "diagnostics/get") {
        return { source: "subversionr-daemon", entries: [] };
      }
      if (method !== "repository/checkout") {
        throw new Error("UNEXPECTED_METHOD");
      }
      if (behavior.success === true) {
        return { workingCopyPath: params.targetPath, revision: 1 };
      }
      const remoteFailure = {
        category: behavior.settlementCategory,
        reason: behavior.settlementReason,
        cleanupAppropriate: false,
      };
      const error = new Error(behavior.settlementCode);
      error.code = behavior.settlementCode;
      error.safeArgs = { remoteFailure };
      if (behavior.settlementCode !== behavior.code && behavior.omitOriginFailureCode !== true) {
        error.safeArgs.originFailureCode = behavior.code;
      }
      const raw = behavior.leak === "repositoryUrl"
        ? params.url
        : behavior.leak === "checkoutTarget"
          ? params.targetPath
          : behavior.leak === "profileRoot"
            ? config.baseEnv.TEMP
            : "bounded";
      error.error = {
        code: behavior.settlementCode,
        category: behavior.settlementCategory,
        messageKey: "error.remote.expected",
        args: { remoteFailure, raw },
        retryable: false,
        diagnostics: null,
      };
      error.diagnostics = null;
      throw error;
    },
    async shutdown() {
      capture.shutdown = true;
      save();
    },
    dispose() {
      capture.disposed = true;
      save();
    },
  };
};
`;
}

function fakeRemoteAccessProfileSource() {
  return `
exports.canonicalEndpointFromRepositoryUrl = function canonicalEndpointFromRepositoryUrl(repositoryUrl) {
  const url = new URL(repositoryUrl);
  return {
    scheme: url.protocol.slice(0, -1),
    canonicalHost: url.hostname,
    effectivePort: Number(url.port || 3690),
  };
};

exports.RemoteOperationEnvelopeFactory = class RemoteOperationEnvelopeFactory {
  constructor(admission) {
    this.admission = admission;
  }

  createAnonymousSvn(input) {
    if (this.admission.remoteSvnAnonymous !== true || this.admission.isRemoteSubmissionEnabled() !== true) {
      throw new Error("REMOTE_ENVELOPE_REJECTED");
    }
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

function runProbe(args) {
  return spawnSync(process.execPath, [probe, ...args], {
    cwd: repositoryRoot,
    encoding: "utf8",
    timeout: 10_000,
    windowsHide: true,
  });
}

function requireCheckoutShape(request, fixture) {
  assert.equal(request.method, "repository/checkout");
  assert.deepEqual(Object.keys(request.params), ["url", "targetPath", "revision", "depth", "ignoreExternals", "remote"]);
  assert.equal(request.params.url, fixture.repositoryUrl);
  assert.equal(request.params.targetPath, fixture.checkoutTarget);
  assert.equal(request.params.revision, "head");
  assert.equal(request.params.depth, "infinity");
  assert.equal(request.params.ignoreExternals, true);

  const remote = request.params.remote;
  assert.deepEqual(Object.keys(remote), [
    "version",
    "operationId",
    "intent",
    "interaction",
    "timeoutMs",
    "workspaceTrust",
    "trustEpoch",
    "profile",
    "expectedOrigin",
  ]);
  assert.equal(remote.version, 1);
  assert.match(remote.operationId, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u);
  assert.equal(remote.intent, "foreground");
  assert.equal(remote.interaction, "forbidden");
  assert.equal(remote.timeoutMs, fixture.timeoutMs);
  assert.equal(remote.workspaceTrust, "trusted");
  assert.equal(remote.trustEpoch, 7);
  const authority = { scheme: "svn", canonicalHost: "127.0.0.1", effectivePort: 43690 };
  assert.deepEqual(remote.expectedOrigin, authority);
  assert.deepEqual(remote.profile, {
    schema: "subversionr.remote-profile.v1",
    profileId: "m8-i6-loopback-anonymous",
    authority,
    serverAuth: "anonymous",
    serverAccount: "none",
    serverCredentialPersistence: "secretStorage",
    proxy: "none",
    ssh: "none",
    redirectPolicy: "rejectAll",
  });
}

function replaceArgumentValue(args, name, value) {
  const copy = [...args];
  copy[copy.indexOf(name) + 1] = value;
  return copy;
}

function replaceArgumentName(args, name, value) {
  const copy = [...args];
  copy[copy.indexOf(name)] = value;
  return copy;
}

function failed(code) {
  return { schema, status: "failed", error: { code } };
}
