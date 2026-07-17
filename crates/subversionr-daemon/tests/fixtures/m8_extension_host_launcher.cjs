"use strict";

const { spawn } = require("node:child_process");

const OUTPUT_LIMIT_BYTES = 64 * 1024;
const TIMEOUT_MS = 30_000;
const SUCCESS_MARKER = "SUBVERSIONR_M8_NODE_HOST_OK";

if (process.argv.length !== 4) {
  throw new Error("expected the exact probe executable and test filter");
}

const probeExecutable = process.argv[2];
const testFilter = process.argv[3];
if (!probeExecutable || !testFilter) {
  throw new Error("probe executable and test filter must be non-empty");
}

const requiredEnvironment = ["SystemRoot", "WINDIR", "TEMP", "TMP"];
const environment = {};
for (const name of requiredEnvironment) {
  const value = process.env[name];
  if (typeof value !== "string" || value.length === 0) {
    throw new Error(`required environment variable ${name} is missing`);
  }
  environment[name] = value;
}
environment.SUBVERSIONR_M8_NODE_HOST_MODE = "1";

const child = spawn(
  probeExecutable,
  ["--exact", testFilter, "--nocapture", "--test-threads=1"],
  {
    env: environment,
    shell: false,
    stdio: ["ignore", "pipe", "pipe"],
    windowsHide: true,
  },
);

let stdout = Buffer.alloc(0);
let stderr = Buffer.alloc(0);
let outputExceeded = false;

function appendBounded(current, chunk) {
  const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
  if (current.length + bytes.length > OUTPUT_LIMIT_BYTES) {
    outputExceeded = true;
    child.kill();
    return current;
  }
  return Buffer.concat([current, bytes]);
}

child.stdout.on("data", (chunk) => {
  stdout = appendBounded(stdout, chunk);
});
child.stderr.on("data", (chunk) => {
  stderr = appendBounded(stderr, chunk);
});

const timer = setTimeout(() => {
  child.kill();
  process.exitCode = 124;
}, TIMEOUT_MS);

child.once("error", (error) => {
  clearTimeout(timer);
  process.stderr.write(`probe spawn failed: ${error.message}\n`);
  process.exitCode = 125;
});

child.once("close", (code, signal) => {
  clearTimeout(timer);
  if (process.exitCode === 124) {
    return;
  }
  if (outputExceeded) {
    process.stderr.write("probe output exceeded the bounded capture limit\n");
    process.exitCode = 126;
    return;
  }
  if (code !== 0 || signal !== null) {
    process.stderr.write(stderr);
    process.exitCode = typeof code === "number" ? code : 127;
    return;
  }
  if (!stdout.toString("utf8").includes(SUCCESS_MARKER)) {
    process.stderr.write("probe success marker was not emitted\n");
    process.exitCode = 128;
    return;
  }
  process.stdout.write(`${SUCCESS_MARKER}\n`);
});
