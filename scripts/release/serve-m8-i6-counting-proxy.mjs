import { access, rename, writeFile } from "node:fs/promises";
import net from "node:net";
import path from "node:path";
import { setTimeout as delay } from "node:timers/promises";

const STATE_SCHEMA = "subversionr.release.m8-i6-counting-proxy.v1";

let listener;
let stopping = false;
const clientSockets = new Set();
const upstreamSockets = new Set();
let statePath;
let temporaryStatePath;
let stateWrite = Promise.resolve();

await main();

async function main() {
  try {
    const options = await parseOptions(process.argv.slice(2));
    statePath = options.statePath;
    temporaryStatePath = `${statePath}.tmp`;
    const state = {
      schema: STATE_SCHEMA,
      pid: process.pid,
      listenHost: options.listenHost,
      port: 0,
      upstreamHost: options.upstreamHost,
      upstreamPort: options.upstreamPort,
      acceptedConnections: 0,
      upstreamAttempts: 0,
      upstreamConnections: 0,
      clientToUpstreamBytes: 0,
      upstreamToClientBytes: 0,
      activeConnections: 0,
      upstreamConnectFailures: 0,
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

    listener = net.createServer({ allowHalfOpen: true }, (client) => {
      void proxyConnection(client, options, state, persist).catch(() => shutdown(1, state, persist, "failed"));
    });
    listener.on("error", () => void shutdown(1, state, persist, "failed"));
    process.once("SIGINT", () => void shutdown(0, state, persist, "stopped"));
    process.once("SIGTERM", () => void shutdown(0, state, persist, "stopped"));
    installStdinStopControl((valid) =>
      void shutdown(valid ? 0 : 1, state, persist, valid ? "stopped" : "failed"));

    await listenLoopback(listener, options.listenHost, options.port);
    const address = requireLoopbackAddress(listener, options.listenHost);
    await persist({ port: address.port, status: "ready" });
  } catch (error) {
    process.stderr.write(`${safeErrorCode(error)}\n`);
    process.exitCode = 1;
    closeSockets();
    if (listener?.listening) listener.close();
  }
}

async function proxyConnection(client, options, state, persist) {
  clientSockets.add(client);
  client.setNoDelay(true);
  client.on("error", () => undefined);
  const upstream = net.createConnection({ host: options.upstreamHost, port: options.upstreamPort, allowHalfOpen: true });
  upstreamSockets.add(upstream);
  upstream.setNoDelay(true);
  upstream.on("error", () => undefined);
  const upstreamConnected = new Promise((resolve, reject) => {
    upstream.once("connect", resolve);
    upstream.once("error", reject);
  });
  let settled = false;
  const settle = () => {
    if (settled) return;
    settled = true;
    clientSockets.delete(client);
    upstreamSockets.delete(upstream);
    client.destroy();
    upstream.destroy();
    void persist({ activeConnections: Math.max(0, state.activeConnections - 1) });
  };
  client.on("close", settle);
  upstream.on("close", settle);

  await persist({
    acceptedConnections: state.acceptedConnections + 1,
    upstreamAttempts: state.upstreamAttempts + 1,
    activeConnections: state.activeConnections + 1,
  });
  try {
    await upstreamConnected;
  } catch {
    await persist({ upstreamConnectFailures: state.upstreamConnectFailures + 1 });
    settle();
    return;
  }
  await persist({ upstreamConnections: state.upstreamConnections + 1 });

  client.on("data", (chunk) => {
    upstream.write(chunk);
    void persist({ clientToUpstreamBytes: state.clientToUpstreamBytes + chunk.length })
      .catch(() => shutdown(1, state, persist, "failed"));
  });
  upstream.on("data", (chunk) => {
    client.write(chunk);
    void persist({ upstreamToClientBytes: state.upstreamToClientBytes + chunk.length })
      .catch(() => shutdown(1, state, persist, "failed"));
  });
  client.on("end", () => upstream.end());
  upstream.on("end", () => client.end());
}

async function shutdown(exitCode, state, persist, status) {
  if (stopping) return;
  stopping = true;
  closeSockets();
  if (listener?.listening) {
    await new Promise((resolve) => listener.close(resolve));
  }
  await persist({ activeConnections: 0, status });
  process.exitCode = exitCode;
}

function closeSockets() {
  for (const socket of clientSockets) socket.destroy();
  for (const socket of upstreamSockets) socket.destroy();
  clientSockets.clear();
  upstreamSockets.clear();
}

function installStdinStopControl(stop) {
  let input = "";
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (chunk) => {
    input += chunk;
    if (input.length > 5 || input.includes("\n")) stop(input === "stop\n");
  });
}

async function parseOptions(args) {
  const expected = ["listen-host", "port", "upstream-host", "upstream-port", "state-path"];
  if (args.length !== expected.length * 2) throw proxyError("SUBVERSIONR_M8_I6_COUNTING_PROXY_ARGUMENT_INVALID");
  const values = new Map();
  for (let index = 0; index < args.length; index += 2) {
    const name = args[index]?.replace(/^--/u, "");
    const value = args[index + 1];
    if (!expected.includes(name) || values.has(name) || typeof value !== "string" || value.length === 0) {
      throw proxyError("SUBVERSIONR_M8_I6_COUNTING_PROXY_ARGUMENT_INVALID");
    }
    values.set(name, value);
  }
  if (expected.some((name) => !values.has(name))) {
    throw proxyError("SUBVERSIONR_M8_I6_COUNTING_PROXY_ARGUMENT_INVALID");
  }
  const listenHost = values.get("listen-host");
  const upstreamHost = values.get("upstream-host");
  const port = parsePort(values.get("port"), true);
  const upstreamPort = parsePort(values.get("upstream-port"), false);
  const requestedStatePath = values.get("state-path");
  if (
    listenHost !== "127.0.0.1" || upstreamHost !== "127.0.0.1" ||
    !path.isAbsolute(requestedStatePath) || path.extname(requestedStatePath) !== ".json"
  ) {
    throw proxyError("SUBVERSIONR_M8_I6_COUNTING_PROXY_ARGUMENT_INVALID");
  }
  const resolvedStatePath = path.resolve(requestedStatePath);
  try {
    await access(resolvedStatePath);
    throw proxyError("SUBVERSIONR_M8_I6_COUNTING_PROXY_STATE_EXISTS");
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  }
  return { listenHost, port, upstreamHost, upstreamPort, statePath: resolvedStatePath };
}

function parsePort(value, allowZero) {
  if (!/^(?:0|[1-9]\d{0,4})$/u.test(value)) {
    throw proxyError("SUBVERSIONR_M8_I6_COUNTING_PROXY_ARGUMENT_INVALID");
  }
  const port = Number.parseInt(value, 10);
  if (port > 65535 || (!allowZero && port === 0)) {
    throw proxyError("SUBVERSIONR_M8_I6_COUNTING_PROXY_ARGUMENT_INVALID");
  }
  return port;
}

function listenLoopback(server, host, port) {
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen({ host, port, exclusive: true }, resolve);
  });
}

function requireLoopbackAddress(server, host) {
  const address = server.address();
  if (!address || typeof address === "string" || address.address !== host) {
    throw proxyError("SUBVERSIONR_M8_I6_COUNTING_PROXY_LISTEN_INVALID");
  }
  return address;
}

async function atomicRenameState(source, destination) {
  for (let attempt = 0; attempt < 200; attempt += 1) {
    try {
      await rename(source, destination);
      return;
    } catch (error) {
      if (!error || typeof error !== "object" || (error.code !== "EPERM" && error.code !== "EBUSY")) throw error;
      await delay(5);
    }
  }
  throw proxyError("SUBVERSIONR_M8_I6_COUNTING_PROXY_STATE_REPLACE_FAILED");
}

function proxyError(code) {
  const error = new Error(code);
  error.code = code;
  return error;
}

function safeErrorCode(error) {
  if (error && typeof error === "object" && typeof error.code === "string" && /^SUBVERSIONR_[A-Z0-9_]+$/u.test(error.code)) {
    return error.code;
  }
  return "SUBVERSIONR_M8_I6_COUNTING_PROXY_FAILED";
}
