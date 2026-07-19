import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const probe = path.join(repositoryRoot, "scripts", "release", "probe-m8-i6-packaged-redaction.mjs");
const schema = "subversionr.release.m8-i6-packaged-redaction.v1";
const productVersion = "0.2.5";
const repositoryUrl = "svn://127.0.0.1:43690/repo/trunk";
const diagnosticToken = "a0000000-0000-4000-8000-00000000000b";
const expectedRevision = 7;

test("executes the exact packaged checkout and emits only bounded hashed redaction evidence", async () => {
  const fixture = await createFixture({ checkout: { slashNormalized: true } });
  try {
    const result = runProbe(fixture.args);
    assert.equal(result.status, 0, result.stderr || result.stdout);
    assert.equal(result.stderr, "");
    const report = JSON.parse(result.stdout);
    assert.deepEqual(report, {
      schema,
      status: "passed",
      cell: "redaction",
      surface: "packaged-native",
      protocol: { major: 1, minor: 35 },
      remoteSvnAnonymous: true,
      checkoutRevision: 7,
      targetPathSha256: sha256(fixture.checkoutTarget),
      inputContainedRawUrl: true,
      inputContainedRawPath: true,
      inputContainedRawToken: true,
      rawUrlCount: 0,
      rawPathCount: 0,
      secretTokenCount: 0,
      urlMarkerCount: 2,
      pathMarkerCount: 2,
      secretMarkerCount: 2,
      maxDiagnosticBytes: report.maxDiagnosticBytes,
      boundedDiagnostics: true,
      credentialRequests: 0,
      credentialSettlements: 0,
      certificateRequests: 0,
      temporaryRootsAfter: 0,
      diagnosticsRedacted: true,
    });
    assert.ok(report.maxDiagnosticBytes > 0 && report.maxDiagnosticBytes <= 32_768);
    assert.equal(result.stdout.includes(repositoryUrl), false);
    assert.equal(result.stdout.includes(fixture.checkoutTarget), false);
    assert.equal(result.stdout.includes(diagnosticToken), false);

    const capture = JSON.parse(await readFile(fixture.capturePath, "utf8"));
    assert.deepEqual(capture.methods, ["repository/checkout", "diagnostics/get"]);
    assert.equal(capture.shutdown, true);
    assert.deepEqual(capture.checkout, {
      url: repositoryUrl,
      targetPath: fixture.checkoutTarget,
      revision: expectedRevision,
      depth: "infinity",
      ignoreExternals: true,
      remote: {
        version: 1,
        operationId: diagnosticToken,
        intent: "foreground",
        interaction: "forbidden",
        timeoutMs: 300_000,
        workspaceTrust: "trusted",
        trustEpoch: 7,
        profile: {
          schema: "subversionr.remote-profile.v1",
          profileId: "m8-i6-packaged-redaction",
          authority: { scheme: "svn", canonicalHost: "127.0.0.1", effectivePort: 43690 },
          serverAuth: "anonymous",
          serverAccount: "none",
          serverCredentialPersistence: "secretStorage",
          proxy: "none",
          ssh: "none",
          redirectPolicy: "rejectAll",
        },
        expectedOrigin: { scheme: "svn", canonicalHost: "127.0.0.1", effectivePort: 43690 },
      },
    });
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("rejects synthetic markers that are not derived from the exact raw diagnostic inputs", async () => {
  const fixture = await createFixture({ redaction: { syntheticWithoutRaw: true } });
  try {
    assertFailed(runProbe(fixture.args), "SUBVERSIONR_I6_PACKAGED_REDACTION_MARKERS_INVALID");
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("rejects synthetic evidence when the production path removes a proven raw input", async () => {
  const fixture = await createFixture({ redaction: { removeRawInput: true } });
  try {
    assertFailed(runProbe(fixture.args), "SUBVERSIONR_I6_PACKAGED_REDACTION_INPUT_INVALID");
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("rejects every raw leak, missing marker, and oversized OperationDiagnostics line", async () => {
  const cases = [
    [{ leak: "url" }, "SUBVERSIONR_I6_PACKAGED_REDACTION_OUTPUT_LEAK"],
    [{ leak: "path" }, "SUBVERSIONR_I6_PACKAGED_REDACTION_OUTPUT_LEAK"],
    [{ leak: "pathSlash" }, "SUBVERSIONR_I6_PACKAGED_REDACTION_OUTPUT_LEAK"],
    [{ leak: "secret" }, "SUBVERSIONR_I6_PACKAGED_REDACTION_OUTPUT_LEAK"],
    [{ omitMarker: "url" }, "SUBVERSIONR_I6_PACKAGED_REDACTION_MARKERS_INVALID"],
    [{ omitMarker: "path" }, "SUBVERSIONR_I6_PACKAGED_REDACTION_MARKERS_INVALID"],
    [{ omitMarker: "secret" }, "SUBVERSIONR_I6_PACKAGED_REDACTION_MARKERS_INVALID"],
    [{ oversized: true }, "SUBVERSIONR_I6_PACKAGED_REDACTION_DIAGNOSTICS_OVERSIZED"],
  ];
  for (const [redaction, code] of cases) {
    const fixture = await createFixture({ redaction });
    try {
      assertFailed(runProbe(fixture.args), code);
    } finally {
      await rm(fixture.root, { recursive: true, force: true });
    }
  }
});

test("rejects an oversized direct redactDiagnosticValue output independently of OperationDiagnostics", async () => {
  const fixture = await createFixture({ redaction: { directOversized: true } });
  try {
    assertFailed(runProbe(fixture.args), "SUBVERSIONR_I6_PACKAGED_REDACTION_DIAGNOSTICS_OVERSIZED");
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("rejects checkout target, path materialization, revision, and response-shape errors", async () => {
  const cases = [
    [{ checkout: { wrongTarget: true } }, "SUBVERSIONR_I6_PACKAGED_REDACTION_CHECKOUT_INVALID"],
    [{ checkout: { relativeEquivalentTarget: true } }, "SUBVERSIONR_I6_PACKAGED_REDACTION_CHECKOUT_INVALID"],
    [{ checkout: { revision: expectedRevision + 1 } }, "SUBVERSIONR_I6_PACKAGED_REDACTION_CHECKOUT_INVALID"],
    [{ checkout: { revision: -1 } }, "SUBVERSIONR_I6_PACKAGED_REDACTION_CHECKOUT_INVALID"],
    [{ checkout: { revision: "7" } }, "SUBVERSIONR_I6_PACKAGED_REDACTION_CHECKOUT_INVALID"],
    [{ checkout: { revision: 2_147_483_648 } }, "SUBVERSIONR_I6_PACKAGED_REDACTION_CHECKOUT_INVALID"],
    [{ checkout: { revision: Number.MAX_SAFE_INTEGER + 1 } }, "SUBVERSIONR_I6_PACKAGED_REDACTION_CHECKOUT_INVALID"],
    [{ checkout: { extraField: true } }, "SUBVERSIONR_I6_PACKAGED_REDACTION_CHECKOUT_INVALID"],
    [{ checkout: { skipTargetCreation: true } }, "SUBVERSIONR_I6_PACKAGED_REDACTION_CHECKOUT_INVALID"],
  ];
  for (const [behavior, code] of cases) {
    const fixture = await createFixture(behavior);
    try {
      assertFailed(runProbe(fixture.args), code);
    } finally {
      await rm(fixture.root, { recursive: true, force: true });
    }
  }
});

test("fails fast for aliases, extra or duplicate fields, non-loopback origins, and invalid tokens", async () => {
  const fixture = await createFixture({});
  try {
    const invalid = [
      [[...fixture.args, "--extra", "value"], "SUBVERSIONR_I6_PACKAGED_REDACTION_ARGUMENT_INVALID"],
      [replaceName(fixture.args, "--daemon-path", "--daemon"), "SUBVERSIONR_I6_PACKAGED_REDACTION_ARGUMENT_INVALID"],
      [[...fixture.args.slice(0, -2), "--daemon-path", fixture.daemonPath], "SUBVERSIONR_I6_PACKAGED_REDACTION_ARGUMENT_INVALID"],
      [replaceValue(fixture.args, "--repository-url", "svn://localhost:43690/repo/trunk"), "SUBVERSIONR_I6_PACKAGED_REDACTION_ORIGIN_INVALID"],
      [replaceValue(fixture.args, "--repository-url", "svn://127.0.0.1:43690/repo/trunk?x=1"), "SUBVERSIONR_I6_PACKAGED_REDACTION_ORIGIN_INVALID"],
      [replaceValue(fixture.args, "--diagnostic-token", diagnosticToken.toUpperCase()), "SUBVERSIONR_I6_PACKAGED_REDACTION_ARGUMENT_INVALID"],
      [replaceValue(fixture.args, "--diagnostic-token", "a".repeat(64)), "SUBVERSIONR_I6_PACKAGED_REDACTION_ARGUMENT_INVALID"],
      [replaceValue(fixture.args, "--expected-product-version", "v0.2.5"), "SUBVERSIONR_I6_PACKAGED_REDACTION_ARGUMENT_INVALID"],
      [replaceValue(fixture.args, "--expected-revision", "0"), "SUBVERSIONR_I6_PACKAGED_REDACTION_ARGUMENT_INVALID"],
      [replaceValue(fixture.args, "--expected-revision", "07"), "SUBVERSIONR_I6_PACKAGED_REDACTION_ARGUMENT_INVALID"],
      [replaceValue(fixture.args, "--expected-revision", "2147483648"), "SUBVERSIONR_I6_PACKAGED_REDACTION_ARGUMENT_INVALID"],
    ];
    for (const [args, code] of invalid) {
      assertFailed(runProbe(args), code);
    }
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("fails fast when new isolated profile and checkout paths are reused or nested", async () => {
  const cases = [
    async (fixture) => replaceValue(fixture.args, "--checkout-target", fixture.profileRoot),
    async (fixture) => replaceValue(fixture.args, "--checkout-target", path.join(fixture.profileRoot, "nested")),
    async (fixture) => {
      await mkdir(fixture.profileRoot);
      return fixture.args;
    },
    async (fixture) => {
      await mkdir(fixture.checkoutTarget);
      return fixture.args;
    },
  ];
  for (const mutate of cases) {
    const fixture = await createFixture({});
    try {
      const args = await mutate(fixture);
      assertFailed(runProbe(args), "SUBVERSIONR_I6_PACKAGED_REDACTION_PATH_REUSED");
    } finally {
      await rm(fixture.root, { recursive: true, force: true });
    }
  }
});

test("rejects authentication callbacks and remote-worker residue", async () => {
  for (const [behavior, code] of [
    [{ authCallback: true }, "SUBVERSIONR_I6_PACKAGED_REDACTION_AUTH_ACTIVITY_INVALID"],
    [{ residue: true }, "SUBVERSIONR_I6_PACKAGED_REDACTION_WORKER_TEMP_RESIDUE"],
  ]) {
    const fixture = await createFixture(behavior);
    try {
      assertFailed(runProbe(fixture.args), code);
    } finally {
      await rm(fixture.root, { recursive: true, force: true });
    }
  }
});

async function createFixture(behavior) {
  const temporaryBase = behavior.checkout?.relativeEquivalentTarget === true
    ? path.join(repositoryRoot, "target", "tests")
    : os.tmpdir();
  const root = await mkdtemp(path.join(temporaryBase, "subversionr-i6-packaged-redaction-test-"));
  const packageRoot = path.join(root, "candidate");
  const backendRoot = path.join(packageRoot, "dist", "backend");
  const diagnosticsRoot = path.join(packageRoot, "dist", "diagnostics");
  const nativeRoot = path.join(packageRoot, "resources", "backend", "win32-x64");
  const workRoot = path.join(root, "work");
  const profileRoot = path.join(workRoot, "profile");
  const checkoutTarget = path.join(workRoot, "checkout");
  await Promise.all([
    mkdir(backendRoot, { recursive: true }),
    mkdir(diagnosticsRoot, { recursive: true }),
    mkdir(nativeRoot, { recursive: true }),
    mkdir(workRoot, { recursive: true }),
  ]);

  const daemonPath = path.join(nativeRoot, "subversionr-daemon.exe");
  const bridgePath = path.join(nativeRoot, "subversionr_svn_bridge.dll");
  await Promise.all([
    writeFile(path.join(packageRoot, "package.json"), JSON.stringify({
      name: "subversionr",
      publisher: "hitsuki-ban",
      version: productVersion,
      main: "./dist/extension.js",
    }), "utf8"),
    writeFile(path.join(backendRoot, "backendProcess.js"), fakeBackendSource(behavior), "utf8"),
    writeFile(path.join(diagnosticsRoot, "diagnosticsRedaction.js"), fakeRedactionSource(behavior.redaction ?? {}), "utf8"),
    writeFile(path.join(diagnosticsRoot, "operationDiagnostics.js"), fakeOperationDiagnosticsSource(behavior.redaction ?? {}), "utf8"),
    writeFile(daemonPath, "fake-daemon", "utf8"),
    writeFile(bridgePath, "fake-bridge", "utf8"),
  ]);
  return {
    root,
    packageRoot,
    daemonPath,
    bridgePath,
    profileRoot,
    checkoutTarget,
    capturePath: path.join(profileRoot, "remote-state", "capture.json"),
    args: [
      "--daemon-path", daemonPath,
      "--bridge-path", bridgePath,
      "--profile-root", profileRoot,
      "--repository-url", repositoryUrl,
      "--checkout-target", checkoutTarget,
      "--diagnostic-token", diagnosticToken,
      "--expected-product-version", productVersion,
      "--expected-revision", `${expectedRevision}`,
    ],
  };
}

function fakeBackendSource(behavior) {
  return `
const fs = require("node:fs");
const path = require("node:path");
const behavior = ${JSON.stringify(behavior)};
exports.startBackendProcess = async function startBackendProcess(config, handlers) {
  const capturePath = path.join(config.remoteStateRoot, "capture.json");
  const capture = { methods: [], shutdown: false };
  const save = () => fs.writeFileSync(capturePath, JSON.stringify(capture));
  save();
  return {
    initializeResult: {
      protocol: { major: 1, minor: 35 },
      backendVersion: ${JSON.stringify(productVersion)},
      acknowledgedTrustEpoch: 7,
      capabilities: {
        realLibsvnBridge: true,
        repositoryCheckout: true,
        diagnosticsGet: true,
        remoteOperationEnvelope: true,
        remoteWorkerIsolation: true,
        remoteSvnAnonymous: true,
      },
    },
    isRemoteSubmissionEnabled() { return true; },
    currentRemoteTrustEpoch() { return 7; },
    async sendRequest(method, params) {
      capture.methods.push(method);
      if (method === "repository/checkout") {
        capture.checkout = params;
        if (behavior.authCallback === true) await handlers.requestHandler("credential/request", {});
        if (behavior.checkout?.skipTargetCreation !== true) fs.mkdirSync(params.targetPath, { recursive: true });
        const response = {
          workingCopyPath: behavior.checkout?.wrongTarget === true
            ? path.join(path.dirname(params.targetPath), "other")
            : behavior.checkout?.relativeEquivalentTarget === true
              ? path.relative(process.cwd(), params.targetPath)
            : behavior.checkout?.slashNormalized === true
              ? params.targetPath.replaceAll(String.fromCharCode(92), "/")
              : params.targetPath,
          revision: Object.prototype.hasOwnProperty.call(behavior.checkout ?? {}, "revision") ? behavior.checkout.revision : 7,
        };
        if (behavior.checkout?.extraField === true) response.extra = true;
        save();
        return response;
      }
      if (method === "diagnostics/get") {
        save();
        return { source: "subversionr-daemon", padding: "x".repeat(2048) };
      }
      throw new Error("UNEXPECTED_METHOD");
    },
    async shutdown() {
      if (behavior.residue === true) {
        fs.mkdirSync(path.join(config.baseEnv.TEMP, "SubversionR", "remote-workers", "residue"), { recursive: true });
      }
      capture.shutdown = true; save();
    },
    dispose() { capture.disposed = true; save(); },
  };
};
`;
}

function fakeRedactionSource(behavior) {
  return `
const behavior = ${JSON.stringify(behavior)};
function hashToken(value) {
  let hash = 0x811c9dc5;
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193);
  }
  return (hash >>> 0).toString(16).padStart(8, "0");
}
function redact(value, key = "") {
  if (behavior.syntheticWithoutRaw === true) {
    return {
      url: "[REDACTED:url:00000000]",
      path: "[REDACTED:path:00000000]",
      secret: "[REDACTED:secret]",
    };
  }
  if (typeof value === "string") {
    if (key === "diagnosticToken") {
      if (behavior.leak === "secret") return value;
      return behavior.omitMarker === "secret" ? "omitted" : "[REDACTED:secret]";
    }
    if (value.startsWith("svn://")) {
      if (behavior.leak === "url") return value;
      return behavior.omitMarker === "url" ? "omitted" : \`[REDACTED:url:\${hashToken(value)}]\`;
    }
    if (value.startsWith("/") || (value.length > 2 && value[1] === ":" && (value.charCodeAt(2) === 47 || value.charCodeAt(2) === 92))) {
      if (behavior.leak === "path") return value;
      if (behavior.leak === "pathSlash") return value.replaceAll(String.fromCharCode(92), "/");
      return behavior.omitMarker === "path" ? "omitted" : \`[REDACTED:path:\${hashToken(value)}]\`;
    }
    return value;
  }
  if (Array.isArray(value)) return value.map((item) => redact(item, key));
  if (value && typeof value === "object") {
    const result = {};
    for (const [entryKey, entryValue] of Object.entries(value)) result[entryKey] = redact(entryValue, entryKey);
    return result;
  }
  return value;
}
exports.redactDiagnosticValue = (value) => {
  const result = redact(value);
  if (behavior.directOversized === true && value && typeof value === "object" && Object.prototype.hasOwnProperty.call(value, "safeArgs")) {
    result.padding = "x".repeat(33000);
  }
  return result;
};
`;
}

function fakeOperationDiagnosticsSource(behavior) {
  return `
const { redactDiagnosticValue } = require("./diagnosticsRedaction");
const behavior = ${JSON.stringify(behavior)};
exports.OperationDiagnostics = class OperationDiagnostics {
  constructor(channel) { this.channel = channel; this.lines = []; }
  recordFailure(operation, error) {
    let line = JSON.stringify(redactDiagnosticValue({
      operation,
      code: error.code,
      category: error.category,
      messageKey: error.messageKey,
      retryable: error.retryable,
      args: error.safeArgs,
      diagnostics: error.diagnostics,
    }));
    if (behavior.oversized === true) line += "x".repeat(33000);
    if (behavior.removeRawInput === true) delete error.safeArgs.repositoryUrl;
    this.lines.push(line);
    this.channel.error(line);
  }
  snapshot() { return [...this.lines]; }
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

function replaceValue(args, name, value) {
  const copy = [...args];
  copy[copy.indexOf(name) + 1] = value;
  return copy;
}

function replaceName(args, name, replacement) {
  const copy = [...args];
  copy[copy.indexOf(name)] = replacement;
  return copy;
}

function assertFailed(result, code) {
  assert.equal(result.status, 1, result.stderr || result.stdout);
  assert.equal(result.stderr, "");
  assert.deepEqual(JSON.parse(result.stdout), { schema, status: "failed", code });
}

function sha256(value) {
  return createHash("sha256").update(value, "utf8").digest("hex");
}
