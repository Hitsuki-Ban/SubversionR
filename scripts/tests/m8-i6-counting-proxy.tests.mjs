import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { setTimeout as delay } from "node:timers/promises";
import test from "node:test";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const PROXY = path.join(ROOT, "scripts/release/serve-m8-i6-counting-proxy.mjs");
const STATE_KEYS = [
  "schema", "pid", "listenHost", "port", "upstreamHost", "upstreamPort", "acceptedConnections",
  "upstreamAttempts", "upstreamConnections", "clientToUpstreamBytes", "upstreamToClientBytes", "activeConnections",
  "upstreamConnectFailures", "status",
].sort();

test("forwards bytes and atomically counts the exact loopback traffic", async () => {
  const upstream = net.createServer((socket) => socket.pipe(socket));
  await listen(upstream);
  const upstreamPort = upstream.address().port;
  const fixture = await startProxy(upstreamPort);
  try {
    const response = await roundTrip(fixture.port, Buffer.from("counted-proxy-payload", "utf8"));
    assert.equal(response.toString("utf8"), "counted-proxy-payload");
    const state = await fixture.waitFor((value) =>
      value.acceptedConnections === 1 && value.upstreamAttempts === 1 && value.upstreamConnections === 1 &&
      value.activeConnections === 0 && value.clientToUpstreamBytes === 21 && value.upstreamToClientBytes === 21);
    assert.deepEqual(Object.keys(state).sort(), STATE_KEYS);
    assert.equal(state.upstreamConnectFailures, 0);
    assert.equal(state.listenHost, "127.0.0.1");
    assert.equal(state.upstreamHost, "127.0.0.1");
    assert.equal(state.upstreamPort, upstreamPort);
  } finally {
    const finalState = await fixture.stop();
    assert.equal(finalState.acceptedConnections, 1);
    assert.equal(finalState.upstreamAttempts, 1);
    assert.equal(finalState.upstreamConnections, 1);
    assert.equal(finalState.clientToUpstreamBytes, 21);
    assert.equal(finalState.upstreamToClientBytes, 21);
    await new Promise((resolve) => upstream.close(resolve));
  }
});

test("flushes queued traffic counters into the stopped-state barrier", async () => {
  let releaseResponse;
  const responseGate = new Promise((resolve) => { releaseResponse = resolve; });
  let receivedPayload;
  const received = new Promise((resolve) => { receivedPayload = resolve; });
  const upstream = net.createServer((socket) => {
    socket.on("data", (chunk) => {
      receivedPayload(chunk);
      void responseGate.then(() => socket.end(chunk));
    });
  });
  await listen(upstream);
  const fixture = await startProxy(upstream.address().port);
  const socket = net.createConnection({ host: "127.0.0.1", port: fixture.port });
  try {
    await new Promise((resolve, reject) => {
      socket.once("connect", resolve);
      socket.once("error", reject);
    });
    socket.write(Buffer.from("queued-before-stop", "utf8"));
    const payload = await received;
    assert.equal(payload.toString("utf8"), "queued-before-stop");
    const finalState = await fixture.stop();
    assert.equal(finalState.status, "stopped");
    assert.equal(finalState.acceptedConnections, 1);
    assert.equal(finalState.upstreamAttempts, 1);
    assert.equal(finalState.upstreamConnections, 1);
    assert.equal(finalState.clientToUpstreamBytes, 18);
    assert.equal(finalState.activeConnections, 0);
  } finally {
    releaseResponse();
    socket.destroy();
    await new Promise((resolve) => upstream.close(resolve));
  }
});

test("rejects non-exact arguments and an existing state path", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "subversionr-i6-counting-proxy-invalid-"));
  const statePath = path.join(root, "state.json");
  try {
    for (const args of [
      [],
      ["--listen-host", "0.0.0.0", "--port", "0", "--upstream-host", "127.0.0.1", "--upstream-port", "3690", "--state-path", statePath],
      ["--listen-host", "127.0.0.1", "--port", "0", "--upstream-host", "127.0.0.1", "--upstream-port", "0", "--state-path", statePath],
      ["--listen-host", "127.0.0.1", "--port", "0", "--upstream-host", "127.0.0.1", "--upstream-port", "3690", "--state-path", "relative.json"],
    ]) {
      const result = spawnSync(process.execPath, [PROXY, ...args], { encoding: "utf8" });
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /SUBVERSIONR_M8_I6_COUNTING_PROXY_ARGUMENT_INVALID/u);
      assert.equal(result.stdout, "");
    }
    await import("node:fs/promises").then(({ writeFile }) => writeFile(statePath, "{}", "utf8"));
    const result = spawnSync(process.execPath, [
      PROXY,
      "--listen-host", "127.0.0.1",
      "--port", "0",
      "--upstream-host", "127.0.0.1",
      "--upstream-port", "3690",
      "--state-path", statePath,
    ], { encoding: "utf8" });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /SUBVERSIONR_M8_I6_COUNTING_PROXY_STATE_EXISTS/u);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

async function startProxy(upstreamPort) {
  const root = await mkdtemp(path.join(os.tmpdir(), "subversionr-i6-counting-proxy-"));
  const statePath = path.join(root, "state.json");
  const child = spawn(process.execPath, [
    PROXY,
    "--listen-host", "127.0.0.1",
    "--port", "0",
    "--upstream-host", "127.0.0.1",
    "--upstream-port", String(upstreamPort),
    "--state-path", statePath,
  ], { stdio: ["pipe", "pipe", "pipe"] });
  let stderr = "";
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk) => { stderr += chunk; });
  const waitFor = async (predicate) => {
    const deadline = Date.now() + 5_000;
    while (Date.now() < deadline) {
      if (child.exitCode !== null) throw new Error(`proxy exited early: ${stderr}`);
      try {
        const state = JSON.parse(await readFile(statePath, "utf8"));
        if (predicate(state)) return state;
      } catch (error) {
        if (error?.code !== "ENOENT" && !(error instanceof SyntaxError)) throw error;
      }
      await delay(10);
    }
    throw new Error(`proxy state deadline expired: ${stderr}`);
  };
  const ready = await waitFor((state) => state.status === "ready" && state.port > 0);
  assert.equal(ready.schema, "subversionr.release.m8-i6-counting-proxy.v1");
  assert.equal(ready.pid, child.pid);
  assert.deepEqual(Object.keys(ready).sort(), STATE_KEYS);
  return {
    port: ready.port,
    waitFor,
    async stop() {
      if (child.exitCode === null) child.stdin.end("stop\n");
      await Promise.race([
        new Promise((resolve) => child.once("exit", resolve)),
        delay(5_000).then(() => { throw new Error(`proxy did not stop: ${stderr}`); }),
      ]);
      assert.equal(child.exitCode, 0, stderr);
      assert.equal(child.stdout.read() ?? "", "");
      const finalState = JSON.parse(await readFile(statePath, "utf8"));
      assert.equal(finalState.status, "stopped");
      assert.equal(finalState.activeConnections, 0);
      await rm(root, { recursive: true, force: true });
      return finalState;
    },
  };
}

function listen(server) {
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen({ host: "127.0.0.1", port: 0, exclusive: true }, resolve);
  });
}

function roundTrip(port, payload) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    const socket = net.createConnection({ host: "127.0.0.1", port });
    socket.once("error", reject);
    socket.on("data", (chunk) => chunks.push(chunk));
    socket.once("connect", () => socket.end(payload));
    socket.once("end", () => resolve(Buffer.concat(chunks)));
  });
}
