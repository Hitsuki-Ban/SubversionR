import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const FIXTURE = path.join(REPO_ROOT, "scripts/release/serve-m8-i6-ra-svn-fault-fixture.mjs");

test("malicious-root emits protocol-v2 greeting, anonymous auth, mismatched repos-info, and counts forbidden follow-up", async () => {
  const fixture = await startFixture("malicious-root");
  try {
    const socket = await connect(fixture.port);
    const reader = new ItemReader(socket);
    assert.match((await reader.read()).toString("utf8"), /^\( success \( 2 2 /u);
    socket.write(clientGreeting(fixture.port));
    assert.match((await reader.read()).toString("utf8"), /^\( success \( \( \) /u);
    const repositoryInfo = (await reader.read()).toString("utf8");
    const suppliedAuthority = /svn:\/\/127\.0\.0\.1:([0-9]+)\/controlled-root/u.exec(repositoryInfo);
    assert.ok(suppliedAuthority);
    const suppliedAuthorityPort = Number(suppliedAuthority[1]);
    assert.equal(suppliedAuthorityPort, fixture.suppliedAuthorityPort);
    assert.notEqual(suppliedAuthorityPort, fixture.port);
    await fixture.waitFor((state) => state.reposInfoSent === 1);

    socket.write("( get-latest-rev ( ) ) ");
    const commandState = await fixture.waitFor((state) => state.commandsReceived === 1 && state.followupContacts === 1);
    assert.doesNotMatch(JSON.stringify(commandState), /svn:|token/iu);
    const forbidden = await connect(suppliedAuthorityPort);
    await fixture.waitFor((state) => state.suppliedAuthorityConnections === 1 && state.followupContacts === 2);
    forbidden.destroy();
    socket.destroy();
  } finally {
    await fixture.stop();
  }
});

test("sasl-only advertises only CRAM-MD5 and never emits repository info", async () => {
  const fixture = await startFixture("sasl-only");
  try {
    const socket = await connect(fixture.port);
    const reader = new ItemReader(socket);
    await reader.read();
    socket.write(clientGreeting(fixture.port));
    const auth = (await reader.read()).toString("utf8");
    assert.match(auth, /\( CRAM-MD5 \)/u);
    assert.doesNotMatch(auth, /ANONYMOUS/u);
    const state = await fixture.waitFor((value) => value.authRequestSent === 1);
    assert.equal(state.reposInfoSent, 0);
    socket.destroy();
  } finally {
    await fixture.stop();
  }
});

test("greeting-stall records the client greeting response then sends no auth request", async () => {
  const fixture = await startFixture("greeting-stall");
  try {
    const socket = await connect(fixture.port);
    const reader = new ItemReader(socket);
    await reader.read();
    socket.write(clientGreeting(fixture.port));
    const state = await fixture.waitFor((value) => value.clientResponseReceived === 1);
    assert.equal(state.authRequestSent, 0);
    assert.equal(await receivesData(socket, 100), false);
    socket.destroy();
  } finally {
    await fixture.stop();
  }
});

test("connected-stall accepts TCP without sending protocol bytes", async () => {
  const fixture = await startFixture("connected-stall");
  try {
    const socket = await connect(fixture.port);
    const state = await fixture.waitFor((value) => value.connections === 1);
    assert.equal(state.greetingSent, 0);
    assert.equal(state.clientResponseReceived, 0);
    assert.equal(await receivesData(socket, 100), false);
    socket.destroy();
  } finally {
    await fixture.stop();
  }
});

test("counting-listener atomically counts connections and follow-up contacts", async () => {
  const fixture = await startFixture("counting-listener");
  try {
    const first = await connect(fixture.port);
    const second = await connect(fixture.port);
    const state = await fixture.waitFor((value) => value.connections === 2);
    assert.equal(state.followupContacts, 1);
    assert.equal(state.greetingSent, 0);
    assert.deepEqual(Object.keys(state).sort(), [
      "authRequestSent",
      "clientResponseReceived",
      "commandsReceived",
      "connections",
      "followupContacts",
      "greetingSent",
      "pid",
      "port",
      "reposInfoSent",
      "scenario",
      "schema",
      "status",
      "suppliedAuthorityConnections",
      "suppliedAuthorityPort",
    ]);
    first.destroy();
    second.destroy();
  } finally {
    await fixture.stop();
  }
});

test("strict CLI rejects extra fields, non-loopback listeners, and duplicate parameters", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "subversionr-i6-fixture-args-"));
  try {
    const base = [
      FIXTURE,
      "--scenario", "connected-stall",
      "--listen-host", "127.0.0.1",
      "--port", "0",
      "--state-path", path.join(root, "state.json"),
    ];
    const cases = [
      [...base, "--extra", "value"],
      base.map((value) => value === "127.0.0.1" ? "0.0.0.0" : value),
      [FIXTURE, "--port", "1", ...base.slice(3)],
    ];
    for (const args of cases) {
      const result = spawnSync(process.execPath, args, { encoding: "utf8" });
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /SUBVERSIONR_M8_I6_FAULT_FIXTURE_ARGUMENT_INVALID/u);
      assert.equal(result.stdout, "");
    }
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

async function startFixture(scenario) {
  const root = await mkdtemp(path.join(os.tmpdir(), `subversionr-i6-${scenario}-`));
  const statePath = path.join(root, "state.json");
  const child = spawn(process.execPath, [
    FIXTURE,
    "--scenario", scenario,
    "--listen-host", "127.0.0.1",
    "--port", "0",
    "--state-path", statePath,
  ], { stdio: ["pipe", "pipe", "pipe"] });
  let stderr = "";
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk) => { stderr += chunk; });

  const waitFor = async (predicate) => {
    const deadline = Date.now() + 5_000;
    while (Date.now() < deadline) {
      if (child.exitCode !== null) throw new Error(`fixture exited early: ${stderr}`);
      try {
        const state = JSON.parse(await readFile(statePath, "utf8"));
        if (predicate(state)) return state;
      } catch (error) {
        if (error?.code !== "ENOENT" && !(error instanceof SyntaxError)) throw error;
      }
      await delay(10);
    }
    throw new Error(`fixture state deadline expired: ${stderr}`);
  };
  const ready = await waitFor((state) => state.status === "ready" && state.port > 0);
  assert.equal(ready.pid, child.pid);
  assert.equal(ready.scenario, scenario);
  assert.equal(ready.schema, "subversionr.release.m8-i6-ra-svn-fault-fixture.v1");
  if (scenario === "malicious-root") {
    assert.ok(ready.suppliedAuthorityPort > 0);
    assert.notEqual(ready.suppliedAuthorityPort, ready.port);
  } else {
    assert.equal(ready.suppliedAuthorityPort, 0);
  }
  return {
    port: ready.port,
    suppliedAuthorityPort: ready.suppliedAuthorityPort,
    waitFor,
    async stop() {
      if (child.exitCode === null) child.stdin.end("stop\n");
      await Promise.race([
        new Promise((resolve) => child.once("exit", resolve)),
        delay(5_000).then(() => { throw new Error(`fixture did not stop: ${stderr}`); }),
      ]);
      assert.equal(child.exitCode, 0, stderr);
      assert.equal(child.stdout.read() ?? "", "");
      const finalState = JSON.parse(await readFile(statePath, "utf8"));
      assert.equal(finalState.status, "stopped");
      await rm(root, { recursive: true, force: true });
    },
  };
}

function connect(port) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({ host: "127.0.0.1", port });
    socket.once("connect", () => resolve(socket));
    socket.once("error", reject);
  });
}

function clientGreeting(port) {
  const url = `svn://127.0.0.1:${port}/repo/trunk`;
  return `( 2 ( edit-pipeline svndiff1 ) ${Buffer.byteLength(url)}:${url} 8:SVN/1.14 ) `;
}

class ItemReader {
  #buffer = Buffer.alloc(0);
  #waiters = [];

  constructor(socket) {
    socket.on("data", (chunk) => {
      this.#buffer = Buffer.concat([this.#buffer, chunk]);
      for (const resolve of this.#waiters.splice(0)) resolve();
    });
  }

  async read() {
    const deadline = Date.now() + 2_000;
    for (;;) {
      const end = itemEnd(this.#buffer);
      if (end !== undefined) {
        const item = this.#buffer.subarray(0, end);
        this.#buffer = this.#buffer.subarray(end);
        return item;
      }
      if (Date.now() >= deadline) throw new Error("protocol item deadline expired");
      await Promise.race([new Promise((resolve) => this.#waiters.push(resolve)), delay(25)]);
    }
  }
}

function itemEnd(buffer) {
  let depth = 0;
  let started = false;
  for (let index = 0; index < buffer.length; index += 1) {
    if (buffer[index] === 0x28) {
      started = true;
      depth += 1;
    } else if (buffer[index] === 0x29) {
      depth -= 1;
      if (started && depth === 0) {
        if (index + 1 >= buffer.length) return undefined;
        return index + 2;
      }
    }
  }
  return undefined;
}

function receivesData(socket, milliseconds) {
  return new Promise((resolve) => {
    const onData = () => {
      clearTimeout(timer);
      resolve(true);
    };
    const timer = setTimeout(() => {
      socket.off("data", onData);
      resolve(false);
    }, milliseconds);
    socket.once("data", onData);
  });
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
