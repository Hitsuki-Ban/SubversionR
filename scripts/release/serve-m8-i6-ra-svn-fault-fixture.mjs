import { access, rename, writeFile } from "node:fs/promises";
import net from "node:net";
import path from "node:path";
import { setTimeout as delay } from "node:timers/promises";

const STATE_SCHEMA = "subversionr.release.m8-i6-ra-svn-fault-fixture.v1";
const MAX_PROTOCOL_ITEM_BYTES = 1024 * 1024;
const SCENARIOS = new Set([
  "malicious-root",
  "sasl-only",
  "greeting-stall",
  "command-stall",
  "connected-stall",
  "counting-listener",
]);

let statePath;
let temporaryStatePath;
let stateWrite = Promise.resolve();
let server;
let suppliedAuthorityServer;
let stopping = false;
const sockets = new Set();
let releaseStop;
const stopped = new Promise((resolve) => {
  releaseStop = resolve;
});

async function main() {
  try {
    const options = await parseOptions(process.argv.slice(2));
    statePath = options.statePath;
    temporaryStatePath = `${statePath}.tmp`;
    const state = {
      schema: STATE_SCHEMA,
      pid: process.pid,
      port: 0,
      suppliedAuthorityPort: 0,
      scenario: options.scenario,
      connections: 0,
      suppliedAuthorityConnections: 0,
      greetingSent: 0,
      clientResponseReceived: 0,
      authRequestSent: 0,
      reposInfoSent: 0,
      commandsReceived: 0,
      followupContacts: 0,
      status: "starting",
    };

    const persist = async (patch = {}) => {
      Object.assign(state, patch);
      const snapshot = `${JSON.stringify(state)}\n`;
      stateWrite = stateWrite.then(async () => {
        await writeFile(temporaryStatePath, snapshot, { encoding: "utf8", flag: "wx" });
        await atomicRenameState(temporaryStatePath, statePath);
      });
      await stateWrite;
    };

    server = net.createServer((socket) => {
      sockets.add(socket);
      socket.setNoDelay(true);
      socket.on("close", () => sockets.delete(socket));
      socket.on("error", () => undefined);
      const connectionNumber = state.connections + 1;
      void persist({
        connections: connectionNumber,
        followupContacts: state.followupContacts + (connectionNumber > 1 ? 1 : 0),
      })
        .then(() => handleConnection(
          socket,
          options.scenario,
          options.scenario === "malicious-root" ? state.suppliedAuthorityPort : state.port,
          persist,
          stopped,
          state,
        ))
        .catch(() => shutdown(1, persist, state, "failed"));
    });
    server.on("error", () => {
      void shutdown(1, persist, state, "failed");
    });

    if (options.scenario === "malicious-root") {
      suppliedAuthorityServer = net.createServer((socket) => {
        sockets.add(socket);
        socket.on("close", () => sockets.delete(socket));
        socket.on("error", () => undefined);
        void persist({
          suppliedAuthorityConnections: state.suppliedAuthorityConnections + 1,
          followupContacts: state.followupContacts + 1,
        })
          .then(() => socket.destroy())
          .catch(() => shutdown(1, persist, state, "failed"));
      });
      suppliedAuthorityServer.on("error", () => {
        void shutdown(1, persist, state, "failed");
      });
      await listenLoopback(suppliedAuthorityServer, options.listenHost, 0);
      state.suppliedAuthorityPort = requireLoopbackAddress(suppliedAuthorityServer, options.listenHost).port;
    }

    process.once("SIGINT", () => void shutdown(0, persist, state, "stopped"));
    process.once("SIGTERM", () => void shutdown(0, persist, state, "stopped"));
    installStdinStopControl((valid) => void shutdown(valid ? 0 : 1, persist, state, valid ? "stopped" : "failed"));

    await listenLoopback(server, options.listenHost, options.port);
    const address = requireLoopbackAddress(server, options.listenHost);
    await persist({ port: address.port, status: "ready" });
    await stopped;
  } catch (error) {
    const code = safeErrorCode(error);
    process.stderr.write(`${code}\n`);
    process.exitCode = 1;
    if (!stopping) {
      for (const socket of sockets) socket.destroy();
      if (server?.listening) server.close();
      if (suppliedAuthorityServer?.listening) suppliedAuthorityServer.close();
    }
  }
}

async function handleConnection(socket, scenario, port, persist, stopSignal, state) {
  if (scenario === "connected-stall" || scenario === "counting-listener") {
    await stopSignal;
    return;
  }

  const reader = new ProtocolItemReader(socket);
  socket.write(serverGreeting());
  await persist({ greetingSent: state.greetingSent + 1 });

  let clientResponse;
  try {
    clientResponse = await reader.readItem();
  } catch {
    return;
  }
  if (!isClientGreetingResponse(clientResponse)) {
    socket.destroy();
    return;
  }
  await persist({ clientResponseReceived: state.clientResponseReceived + 1 });

  if (scenario === "greeting-stall") {
    await stopSignal;
    return;
  }

  if (scenario === "sasl-only") {
    socket.write(saslOnlyAuthRequest());
    await persist({ authRequestSent: state.authRequestSent + 1 });
    try {
      await reader.readItem();
      await persist({ followupContacts: state.followupContacts + 1 });
    } catch {
      // The expected anonymous client closes instead of selecting a mechanism.
    }
    await stopSignal;
    return;
  }

  socket.write(noAuthRequest());
  await persist({ authRequestSent: state.authRequestSent + 1 });
  socket.write(repositoryInfo(port, scenario));
  await persist({ reposInfoSent: state.reposInfoSent + 1 });

  if (scenario === "command-stall") {
    try {
      await reader.readItem();
    } catch {
      return;
    }
    await persist({ commandsReceived: state.commandsReceived + 1 });
    await stopSignal;
    return;
  }

  while (!stopping && !socket.destroyed) {
    try {
      await reader.readItem();
    } catch {
      return;
    }
    await persist({
      commandsReceived: state.commandsReceived + 1,
      followupContacts: state.followupContacts + 1,
    });
  }
}

async function shutdown(exitCode, persist, state, status) {
  if (stopping) return;
  stopping = true;
  releaseStop();
  for (const socket of sockets) socket.destroy();
  if (server?.listening) {
    await new Promise((resolve) => server.close(resolve));
  }
  if (suppliedAuthorityServer?.listening) {
    await new Promise((resolve) => suppliedAuthorityServer.close(resolve));
  }
  await persist({ status });
  process.exitCode = exitCode;
}

function installStdinStopControl(stop) {
  let input = "";
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (chunk) => {
    input += chunk;
    if (input.length > 5 || input.includes("\n")) {
      stop(input === "stop\n");
    }
  });
}

function listenLoopback(listener, host, port) {
  return new Promise((resolve, reject) => {
    listener.once("error", reject);
    listener.listen({ host, port, exclusive: true }, resolve);
  });
}

function requireLoopbackAddress(listener, host) {
  const address = listener.address();
  if (!address || typeof address === "string" || address.address !== host) {
    throw fixtureError("SUBVERSIONR_M8_I6_FAULT_FIXTURE_LISTEN_INVALID");
  }
  return address;
}

async function parseOptions(args) {
  const expected = ["scenario", "listen-host", "port", "state-path"];
  if (args.length !== expected.length * 2) {
    throw fixtureError("SUBVERSIONR_M8_I6_FAULT_FIXTURE_ARGUMENT_INVALID");
  }
  const values = new Map();
  for (let index = 0; index < args.length; index += 2) {
    const flag = args[index];
    const value = args[index + 1];
    if (typeof flag !== "string" || !flag.startsWith("--") || typeof value !== "string") {
      throw fixtureError("SUBVERSIONR_M8_I6_FAULT_FIXTURE_ARGUMENT_INVALID");
    }
    const name = flag.slice(2);
    if (!expected.includes(name) || values.has(name)) {
      throw fixtureError("SUBVERSIONR_M8_I6_FAULT_FIXTURE_ARGUMENT_INVALID");
    }
    values.set(name, value);
  }
  if (expected.some((name) => !values.has(name))) {
    throw fixtureError("SUBVERSIONR_M8_I6_FAULT_FIXTURE_ARGUMENT_INVALID");
  }

  const scenario = values.get("scenario");
  const listenHost = values.get("listen-host");
  const portText = values.get("port");
  const requestedStatePath = values.get("state-path");
  if (!SCENARIOS.has(scenario) || listenHost !== "127.0.0.1") {
    throw fixtureError("SUBVERSIONR_M8_I6_FAULT_FIXTURE_ARGUMENT_INVALID");
  }
  if (!/^(?:0|[1-9][0-9]{0,4})$/u.test(portText)) {
    throw fixtureError("SUBVERSIONR_M8_I6_FAULT_FIXTURE_ARGUMENT_INVALID");
  }
  const port = Number(portText);
  if (!Number.isSafeInteger(port) || port < 0 || port > 65_535) {
    throw fixtureError("SUBVERSIONR_M8_I6_FAULT_FIXTURE_ARGUMENT_INVALID");
  }
  if (!path.isAbsolute(requestedStatePath) || /[\0\r\n]/u.test(requestedStatePath)) {
    throw fixtureError("SUBVERSIONR_M8_I6_FAULT_FIXTURE_ARGUMENT_INVALID");
  }
  const resolvedStatePath = path.resolve(requestedStatePath);
  await requireExistingDirectory(path.dirname(resolvedStatePath));
  await requireAbsent(resolvedStatePath);
  await requireAbsent(`${resolvedStatePath}.tmp`);
  return { scenario, listenHost, port, statePath: resolvedStatePath };
}

async function requireExistingDirectory(directory) {
  try {
    await access(directory);
  } catch {
    throw fixtureError("SUBVERSIONR_M8_I6_FAULT_FIXTURE_ARGUMENT_INVALID");
  }
}

async function requireAbsent(file) {
  try {
    await access(file);
  } catch {
    return;
  }
  throw fixtureError("SUBVERSIONR_M8_I6_FAULT_FIXTURE_ARGUMENT_INVALID");
}

async function atomicRenameState(source, destination) {
  for (let attempt = 0; attempt < 200; attempt += 1) {
    try {
      await rename(source, destination);
      return;
    } catch (error) {
      if (!error || typeof error !== "object" || (error.code !== "EPERM" && error.code !== "EBUSY")) {
        throw error;
      }
      await delay(5);
    }
  }
  throw fixtureError("SUBVERSIONR_M8_I6_FAULT_FIXTURE_STATE_REPLACE_FAILED");
}

class ProtocolItemReader {
  #buffer = Buffer.alloc(0);
  #ended = false;
  #error;
  #waiters = [];

  constructor(socket) {
    socket.on("data", (chunk) => {
      if (this.#buffer.length + chunk.length > MAX_PROTOCOL_ITEM_BYTES) {
        this.#error = fixtureError("SUBVERSIONR_M8_I6_FAULT_FIXTURE_PROTOCOL_INVALID");
        socket.destroy();
      } else {
        this.#buffer = Buffer.concat([this.#buffer, chunk]);
      }
      this.#wake();
    });
    socket.on("end", () => {
      this.#ended = true;
      this.#wake();
    });
    socket.on("close", () => {
      this.#ended = true;
      this.#wake();
    });
    socket.on("error", (error) => {
      this.#error = error;
      this.#wake();
    });
  }

  async readItem() {
    for (;;) {
      const end = protocolItemEnd(this.#buffer);
      if (end !== undefined) {
        const item = this.#buffer.subarray(0, end);
        this.#buffer = this.#buffer.subarray(end);
        return item;
      }
      if (this.#error) throw this.#error;
      if (this.#ended) throw fixtureError("SUBVERSIONR_M8_I6_FAULT_FIXTURE_PROTOCOL_EOF");
      await new Promise((resolve) => this.#waiters.push(resolve));
    }
  }

  #wake() {
    for (const resolve of this.#waiters.splice(0)) resolve();
  }
}

function protocolItemEnd(buffer) {
  let index = 0;
  while (index < buffer.length && isSpace(buffer[index])) index += 1;
  if (index === buffer.length) return undefined;
  if (buffer[index] !== 0x28) throw fixtureError("SUBVERSIONR_M8_I6_FAULT_FIXTURE_PROTOCOL_INVALID");
  let depth = 0;
  while (index < buffer.length) {
    const byte = buffer[index];
    if (byte === 0x28) {
      depth += 1;
      index += 1;
      continue;
    }
    if (byte === 0x29) {
      depth -= 1;
      if (depth < 0) throw fixtureError("SUBVERSIONR_M8_I6_FAULT_FIXTURE_PROTOCOL_INVALID");
      index += 1;
      if (depth === 0) {
        if (index === buffer.length) return undefined;
        if (!isSpace(buffer[index])) throw fixtureError("SUBVERSIONR_M8_I6_FAULT_FIXTURE_PROTOCOL_INVALID");
        while (index < buffer.length && isSpace(buffer[index])) index += 1;
        return index;
      }
      continue;
    }
    if (byte >= 0x30 && byte <= 0x39) {
      const start = index;
      while (index < buffer.length && buffer[index] >= 0x30 && buffer[index] <= 0x39) index += 1;
      if (index === buffer.length) return undefined;
      if (buffer[index] === 0x3a) {
        const length = Number(buffer.subarray(start, index).toString("ascii"));
        if (!Number.isSafeInteger(length) || length > MAX_PROTOCOL_ITEM_BYTES) {
          throw fixtureError("SUBVERSIONR_M8_I6_FAULT_FIXTURE_PROTOCOL_INVALID");
        }
        index += 1;
        if (index + length >= buffer.length) return undefined;
        index += length;
        if (!isSpace(buffer[index])) throw fixtureError("SUBVERSIONR_M8_I6_FAULT_FIXTURE_PROTOCOL_INVALID");
        continue;
      }
      if (!isSpace(buffer[index])) throw fixtureError("SUBVERSIONR_M8_I6_FAULT_FIXTURE_PROTOCOL_INVALID");
      continue;
    }
    index += 1;
  }
  return undefined;
}

function isClientGreetingResponse(item) {
  const text = item.toString("utf8").trimStart();
  return /^\(\s*2\s/u.test(text);
}

function isSpace(byte) {
  return byte === 0x20 || byte === 0x0a;
}

function serverGreeting() {
  return "( success ( 2 2 ( ) ( edit-pipeline svndiff1 accepts-svndiff2 absent-entries commit-revprops depth log-revprops atomic-revprops partial-replay inherited-props ephemeral-txnprops file-revs-reverse list ) ) ) ";
}

function noAuthRequest() {
  return `( success ( ( ) ${protocolString("SubversionR M8 I6 controlled fault fixture")} ) ) `;
}

function saslOnlyAuthRequest() {
  return `( success ( ( CRAM-MD5 ) ${protocolString("SubversionR M8 I6 controlled SASL-only fixture")} ) ) `;
}

function repositoryInfo(port, scenario) {
  if (!Number.isSafeInteger(port) || port <= 0 || port > 65_535) {
    throw fixtureError("SUBVERSIONR_M8_I6_FAULT_FIXTURE_LISTEN_INVALID");
  }
  const repositoryRoot = scenario === "command-stall"
    ? `svn://127.0.0.1:${port}/repo`
    : `svn://127.0.0.1:${port}/controlled-root`;
  return `( success ( ${protocolString("12345678-1234-1234-1234-123456789abc")} ${protocolString(repositoryRoot)} ( mergeinfo depth log-revprops atomic-revprops ) ) ) `;
}

function protocolString(value) {
  return `${Buffer.byteLength(value, "utf8")}:${value} `;
}

function fixtureError(code) {
  const error = new Error(code);
  error.code = code;
  return error;
}

function safeErrorCode(error) {
  if (error && typeof error === "object" && typeof error.code === "string" && /^SUBVERSIONR_[A-Z0-9_]+$/u.test(error.code)) {
    return error.code;
  }
  return "SUBVERSIONR_M8_I6_FAULT_FIXTURE_FAILED";
}

await main();
