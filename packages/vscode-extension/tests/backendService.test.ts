import { describe, expect, it, vi } from "vitest";
import { BackendService, type BackendStarter } from "../src/backend/backendService";
import type { BackendConnection, BackendLaunchConfig, InitializeResult } from "../src/backend/backendProcess";

describe("BackendService", () => {
  it("coalesces concurrent initialize calls into one sidecar startup", async () => {
    const connection = fakeConnection();
    let resolveStart: (connection: BackendConnection) => void = () => {};
    const start = vi.fn<BackendStarter>(() => {
      return new Promise((resolve) => {
        resolveStart = resolve;
      });
    });
    const service = new BackendService({
      readConfig: () => launchConfig(),
      start,
      ...backendLifecycleDefaults(),
    });

    const first = service.initialize();
    const second = service.initialize();
    expect(start).toHaveBeenCalledTimes(1);

    resolveStart(connection);

    await expect(first).resolves.toBe(connection);
    await expect(second).resolves.toBe(connection);
  });

  it("clears failed startup so explicit retry can launch a new sidecar", async () => {
    const start = vi
      .fn<BackendStarter>()
      .mockRejectedValueOnce(new Error("first startup failed"))
      .mockResolvedValueOnce(fakeConnection());
    const service = new BackendService({
      readConfig: () => launchConfig(),
      start,
      ...backendLifecycleDefaults(),
    });

    await expect(service.initialize()).rejects.toThrow("first startup failed");
    await expect(service.initialize()).resolves.toBeDefined();

    expect(start).toHaveBeenCalledTimes(2);
  });

  it("publishes ready lifecycle state after initial sidecar startup", async () => {
    const clock = fakeLifecycleClock(900);
    const connection = fakeConnection();
    const service = new BackendService({
      readConfig: () => launchConfig(),
      start: vi.fn<BackendStarter>().mockResolvedValue(connection),
      lifecycleClock: clock,
      heartbeatPolicy: { kind: "disabled" },
      restartPolicy: {
        initialBackoffMs: 500,
        maxBackoffMs: 5000,
      },
    });
    const states: unknown[] = [];
    service.onDidChangeLifecycleState((state) => {
      states.push(state);
    });

    await expect(service.initialize()).resolves.toBe(connection);

    expect(states).toEqual([
      {
        status: "ready",
        since: 900,
      },
    ]);
  });

  it("marks startup failure as degraded and waits for restart backoff before retrying", async () => {
    const clock = fakeLifecycleClock(1000);
    const start = vi
      .fn<BackendStarter>()
      .mockRejectedValueOnce(new CodedError("SUBVERSIONR_BACKEND_EXITED"))
      .mockResolvedValueOnce(fakeConnection());
    const service = new BackendService({
      readConfig: () => launchConfig(),
      start,
      lifecycleClock: clock,
      heartbeatPolicy: { kind: "disabled" },
      restartPolicy: {
        initialBackoffMs: 500,
        maxBackoffMs: 5000,
      },
    });
    const states: unknown[] = [];
    service.onDidChangeLifecycleState((state) => {
      states.push(state);
    });

    await expect(service.initialize()).rejects.toThrow("SUBVERSIONR_BACKEND_EXITED");

    expect(service.getLifecycleState()).toEqual({
      status: "degraded",
      reason: "startupFailed",
      since: 1000,
      consecutiveFailures: 1,
      restartAfter: 1500,
      lastErrorCode: "SUBVERSIONR_BACKEND_EXITED",
    });

    const retry = service.initialize();
    expect(start).toHaveBeenCalledTimes(1);
    expect(clock.sleeps).toEqual([500]);

    clock.advanceTo(1500);
    clock.resolveNextSleep();
    await expect(retry).resolves.toBeDefined();

    expect(start).toHaveBeenCalledTimes(2);
    expect(states).toEqual([
      {
        status: "degraded",
        reason: "startupFailed",
        since: 1000,
        consecutiveFailures: 1,
        restartAfter: 1500,
        lastErrorCode: "SUBVERSIONR_BACKEND_EXITED",
      },
      {
        status: "recovered",
        since: 1500,
        recoveredFrom: "startupFailed",
        consecutiveFailures: 1,
      },
    ]);
  });

  it("sends shutdown once for the initialized sidecar", async () => {
    const connection = fakeConnection();
    const service = new BackendService({
      readConfig: () => launchConfig(),
      start: vi.fn<BackendStarter>().mockResolvedValue(connection),
      ...backendLifecycleDefaults(),
    });

    await service.initialize();
    await service.shutdown();
    await service.shutdown();

    expect(connection.shutdown).toHaveBeenCalledTimes(1);
  });

  it("disposes a connection that resolves after the service was disposed", async () => {
    const connection = fakeConnection();
    let resolveStart: (connection: BackendConnection) => void = () => {};
    const service = new BackendService({
      readConfig: () => launchConfig(),
      start: vi.fn<BackendStarter>(() => {
        return new Promise((resolve) => {
          resolveStart = resolve;
        });
      }),
      ...backendLifecycleDefaults(),
    });

    const initialize = service.initialize();
    service.dispose();
    resolveStart(connection);

    await expect(initialize).rejects.toThrow("backend service disposed");
    expect(connection.dispose).toHaveBeenCalledTimes(1);
  });

  it("allows a new sidecar lifecycle after shutdown completes", async () => {
    const firstConnection = fakeConnection();
    const secondConnection = fakeConnection();
    const start = vi
      .fn<BackendStarter>()
      .mockResolvedValueOnce(firstConnection)
      .mockResolvedValueOnce(secondConnection);
    const service = new BackendService({
      readConfig: () => launchConfig(),
      start,
      ...backendLifecycleDefaults(),
    });

    await service.initialize();
    await service.shutdown();
    await service.initialize();
    await service.shutdown();

    expect(firstConnection.shutdown).toHaveBeenCalledTimes(1);
    expect(secondConnection.shutdown).toHaveBeenCalledTimes(1);
  });

  it("clears stale connection state when shutdown rejects", async () => {
    const firstConnection = fakeConnection();
    firstConnection.shutdown = vi.fn().mockRejectedValue(new Error("shutdown failed"));
    const secondConnection = fakeConnection();
    const start = vi
      .fn<BackendStarter>()
      .mockResolvedValueOnce(firstConnection)
      .mockResolvedValueOnce(secondConnection);
    const service = new BackendService({
      readConfig: () => launchConfig(),
      start,
      ...backendLifecycleDefaults(),
    });

    await service.initialize();
    await expect(service.shutdown()).rejects.toThrow("shutdown failed");
    await expect(service.initialize()).resolves.toBe(secondConnection);

    expect(firstConnection.dispose).toHaveBeenCalledTimes(1);
    expect(start).toHaveBeenCalledTimes(2);
  });

  it("clears initialized connection state and notifies when the sidecar terminates", async () => {
    const firstConnection = fakeTerminableConnection();
    const secondConnection = fakeConnection();
    const start = vi
      .fn<BackendStarter>()
      .mockResolvedValueOnce(firstConnection)
      .mockResolvedValueOnce(secondConnection);
    const service = new BackendService({
      readConfig: () => launchConfig(),
      start,
      ...backendLifecycleDefaults(),
    });
    const events: unknown[] = [];

    service.onDidTerminate((event) => {
      events.push(event);
    });

    await expect(service.initialize()).resolves.toBe(firstConnection);
    firstConnection.fireTerminate({
      reason: "processExit",
      exitCode: 1,
      signal: null,
    });
    await expect(service.initialize()).resolves.toBe(secondConnection);

    expect(events).toEqual([
      {
        reason: "processExit",
        exitCode: 1,
        signal: null,
      },
    ]);
    expect(start).toHaveBeenCalledTimes(2);
  });

  it("does not notify termination listeners during explicit shutdown", async () => {
    const connection = fakeTerminableConnection();
    connection.shutdown = vi.fn(async () => {
      connection.fireTerminate({
        reason: "processExit",
        exitCode: 0,
        signal: null,
      });
    });
    const service = new BackendService({
      readConfig: () => launchConfig(),
      start: vi.fn<BackendStarter>().mockResolvedValue(connection),
      ...backendLifecycleDefaults(),
    });
    const events: unknown[] = [];

    service.onDidTerminate((event) => {
      events.push(event);
    });

    await service.initialize();
    await service.shutdown();

    expect(events).toEqual([]);
  });

  it("marks unexpected termination as degraded and waits for restart backoff before replacing the sidecar", async () => {
    const clock = fakeLifecycleClock(2000);
    const firstConnection = fakeTerminableConnection();
    const secondConnection = fakeConnection();
    const start = vi
      .fn<BackendStarter>()
      .mockResolvedValueOnce(firstConnection)
      .mockResolvedValueOnce(secondConnection);
    const service = new BackendService({
      readConfig: () => launchConfig(),
      start,
      lifecycleClock: clock,
      heartbeatPolicy: { kind: "disabled" },
      restartPolicy: {
        initialBackoffMs: 250,
        maxBackoffMs: 1000,
      },
    });

    await expect(service.initialize()).resolves.toBe(firstConnection);
    firstConnection.fireTerminate({
      reason: "processExit",
      exitCode: 1,
      signal: null,
    });

    expect(service.getLifecycleState()).toEqual({
      status: "degraded",
      reason: "terminated",
      since: 2000,
      consecutiveFailures: 1,
      restartAfter: 2250,
      lastErrorCode: "SUBVERSIONR_BACKEND_TERMINATED",
    });

    const retry = service.initialize();
    expect(start).toHaveBeenCalledTimes(1);
    expect(clock.sleeps).toEqual([250]);

    clock.advanceTo(2250);
    clock.resolveNextSleep();
    await expect(retry).resolves.toBe(secondConnection);
    expect(start).toHaveBeenCalledTimes(2);
    expect(service.getLifecycleState()).toEqual({
      status: "ready",
      since: 2250,
    });
  });

  it("preserves daemon protocol fault termination as a distinct degraded reason", async () => {
    const clock = fakeLifecycleClock(2300);
    const firstConnection = fakeTerminableConnection();
    const secondConnection = fakeConnection();
    const start = vi
      .fn<BackendStarter>()
      .mockResolvedValueOnce(firstConnection)
      .mockResolvedValueOnce(secondConnection);
    const service = new BackendService({
      readConfig: () => launchConfig(),
      start,
      lifecycleClock: clock,
      heartbeatPolicy: { kind: "disabled" },
      restartPolicy: {
        initialBackoffMs: 250,
        maxBackoffMs: 1000,
      },
    });
    const lifecycleEvents: unknown[] = [];
    service.onDidChangeLifecycleState((event) => {
      lifecycleEvents.push(event);
    });

    await expect(service.initialize()).resolves.toBe(firstConnection);
    firstConnection.fireTerminate({
      reason: "protocolFault",
      message: "SUBVERSIONR_STATUS_STALE_NOTIFICATION_INVALID",
    });

    expect(service.getLifecycleState()).toEqual({
      status: "degraded",
      reason: "protocolFault",
      since: 2300,
      consecutiveFailures: 1,
      restartAfter: 2550,
      lastErrorCode: "SUBVERSIONR_STATUS_STALE_NOTIFICATION_INVALID",
    });

    const retry = service.initialize();
    expect(start).toHaveBeenCalledTimes(1);
    expect(clock.sleeps).toEqual([250]);

    clock.advanceTo(2550);
    clock.resolveNextSleep();
    await expect(retry).resolves.toBe(secondConnection);

    expect(lifecycleEvents).toEqual([
      {
        status: "ready",
        since: 2300,
      },
      {
        status: "degraded",
        reason: "protocolFault",
        since: 2300,
        consecutiveFailures: 1,
        restartAfter: 2550,
        lastErrorCode: "SUBVERSIONR_STATUS_STALE_NOTIFICATION_INVALID",
      },
      {
        status: "recovered",
        since: 2550,
        recoveredFrom: "protocolFault",
        consecutiveFailures: 1,
      },
    ]);
  });

  it("probes the initialized sidecar with diagnostics heartbeat", async () => {
    const clock = fakeLifecycleClock(3000);
    const connection = fakeConnection();
    const service = new BackendService({
      readConfig: () => launchConfig(),
      start: vi.fn<BackendStarter>().mockResolvedValue(connection),
      lifecycleClock: clock,
      heartbeatPolicy: {
        kind: "enabled",
        intervalMs: 1000,
        timeoutMs: 250,
      },
      restartPolicy: {
        initialBackoffMs: 0,
        maxBackoffMs: 0,
      },
    });

    await expect(service.initialize()).resolves.toBe(connection);
    expect(clock.pendingTimerDelays()).toEqual([1000]);

    clock.runNextTimer();
    await flushMicrotasks();

    expect(connection.sendRequest).toHaveBeenCalledWith("diagnostics/get", {});
    expect(clock.pendingTimerDelays()).toEqual([1000]);
  });

  it("marks heartbeat failure as degraded and waits for restart backoff before replacing the sidecar", async () => {
    const clock = fakeLifecycleClock(4000);
    const firstConnection = fakeConnection();
    firstConnection.sendRequest = vi.fn().mockRejectedValue(new CodedError("SUBVERSIONR_BACKEND_HEARTBEAT_RPC_FAILED"));
    const secondConnection = fakeConnection();
    const start = vi
      .fn<BackendStarter>()
      .mockResolvedValueOnce(firstConnection)
      .mockResolvedValueOnce(secondConnection);
    const service = new BackendService({
      readConfig: () => launchConfig(),
      start,
      lifecycleClock: clock,
      heartbeatPolicy: {
        kind: "enabled",
        intervalMs: 1000,
        timeoutMs: 250,
      },
      restartPolicy: {
        initialBackoffMs: 200,
        maxBackoffMs: 1000,
      },
    });
    const terminationEvents: unknown[] = [];
    const lifecycleEvents: unknown[] = [];
    service.onDidTerminate((event) => {
      terminationEvents.push(event);
    });
    service.onDidChangeLifecycleState((event) => {
      lifecycleEvents.push(event);
    });

    await expect(service.initialize()).resolves.toBe(firstConnection);
    clock.runNextTimer();
    await flushMicrotasks();

    expect(firstConnection.dispose).toHaveBeenCalledTimes(1);
    expect(terminationEvents).toEqual([
      {
        reason: "heartbeatFailed",
        message: "SUBVERSIONR_BACKEND_HEARTBEAT_RPC_FAILED",
      },
    ]);
    expect(service.getLifecycleState()).toEqual({
      status: "degraded",
      reason: "heartbeatFailed",
      since: 4000,
      consecutiveFailures: 1,
      restartAfter: 4200,
      lastErrorCode: "SUBVERSIONR_BACKEND_HEARTBEAT_RPC_FAILED",
    });

    const retry = service.initialize();
    expect(start).toHaveBeenCalledTimes(1);
    expect(clock.sleeps).toEqual([200]);

    clock.advanceTo(4200);
    clock.resolveNextSleep();
    await expect(retry).resolves.toBe(secondConnection);

    expect(start).toHaveBeenCalledTimes(2);
    expect(lifecycleEvents).toEqual([
      {
        status: "ready",
        since: 4000,
      },
      {
        status: "degraded",
        reason: "heartbeatFailed",
        since: 4000,
        consecutiveFailures: 1,
        restartAfter: 4200,
        lastErrorCode: "SUBVERSIONR_BACKEND_HEARTBEAT_RPC_FAILED",
      },
      {
        status: "recovered",
        since: 4200,
        recoveredFrom: "heartbeatFailed",
        consecutiveFailures: 1,
      },
    ]);
  });

  it("marks a hanging heartbeat as a timeout failure", async () => {
    const clock = fakeLifecycleClock(5000);
    const connection = fakeConnection();
    connection.sendRequest = <T>() =>
      new Promise<T>(() => {
        // Keep the heartbeat pending until the timeout timer fires.
      });
    const service = new BackendService({
      readConfig: () => launchConfig(),
      start: vi.fn<BackendStarter>().mockResolvedValue(connection),
      lifecycleClock: clock,
      heartbeatPolicy: {
        kind: "enabled",
        intervalMs: 1000,
        timeoutMs: 250,
      },
      restartPolicy: {
        initialBackoffMs: 200,
        maxBackoffMs: 1000,
      },
    });
    const terminationEvents: unknown[] = [];
    service.onDidTerminate((event) => {
      terminationEvents.push(event);
    });

    await expect(service.initialize()).resolves.toBe(connection);
    clock.runNextTimer();
    expect(clock.pendingTimerDelays()).toEqual([250]);

    clock.runNextTimer();
    await flushMicrotasks();

    expect(connection.dispose).toHaveBeenCalledTimes(1);
    expect(terminationEvents).toEqual([
      {
        reason: "heartbeatFailed",
        message: "SUBVERSIONR_BACKEND_HEARTBEAT_TIMEOUT",
      },
    ]);
    expect(service.getLifecycleState()).toEqual({
      status: "degraded",
      reason: "heartbeatFailed",
      since: 5000,
      consecutiveFailures: 1,
      restartAfter: 5200,
      lastErrorCode: "SUBVERSIONR_BACKEND_HEARTBEAT_TIMEOUT",
    });
  });
});

function launchConfig(): BackendLaunchConfig {
  return {
    executablePath: "C:\\SubversionR\\subversionr-daemon.exe",
    bridgeDllPath: "C:\\SubversionR\\subversionr_svn_bridge.dll",
    cacheRoot: "C:\\SubversionR\\cache",
    clientName: "SubversionR",
    clientVersion: "0.1.0",
    locale: "en",
    workspaceTrust: "trusted",
    baseEnv: {
      Path: "C:\\Windows\\System32",
    },
  };
}

function fakeConnection(): BackendConnection {
  return {
    initializeResult: initializeResult(),
    sendRequest: vi.fn().mockResolvedValue({}),
    onDidTerminate: vi.fn(() => ({ dispose: vi.fn() })),
    shutdown: vi.fn().mockResolvedValue(undefined),
    dispose: vi.fn(),
  };
}

type FakeTerminationEvent =
  | {
      reason: "processExit";
      exitCode: number | null;
      signal: NodeJS.Signals | null;
    }
  | {
      reason: "protocolFault";
      message: string;
    };

function fakeTerminableConnection(): BackendConnection & {
  fireTerminate(event: FakeTerminationEvent): void;
  onDidTerminate(listener: (event: FakeTerminationEvent) => void): { dispose(): void };
} {
  const listeners = new Set<(event: FakeTerminationEvent) => void>();
  return {
    ...fakeConnection(),
    onDidTerminate: (listener: (event: FakeTerminationEvent) => void): { dispose(): void } => {
      listeners.add(listener);
      return {
        dispose: () => {
          listeners.delete(listener);
        },
      };
    },
    fireTerminate: (event: FakeTerminationEvent): void => {
      for (const listener of listeners) {
        listener(event);
      }
    },
  };
}

function fakeLifecycleClock(initialNow: number): {
  now(): number;
  sleep(ms: number): Promise<void>;
  setTimeout(callback: () => void, ms: number): { dispose(): void };
  advanceTo(nextNow: number): void;
  resolveNextSleep(): void;
  runNextTimer(): void;
  pendingTimerDelays(): number[];
  sleeps: number[];
} {
  const sleeps: number[] = [];
  const pendingSleeps: Array<() => void> = [];
  const timers: Array<{ callback: () => void; disposed: boolean; ms: number }> = [];
  let currentNow = initialNow;
  return {
    now: () => currentNow,
    sleep: (ms) => {
      sleeps.push(ms);
      return new Promise((resolve) => {
        pendingSleeps.push(resolve);
      });
    },
    advanceTo: (nextNow) => {
      currentNow = nextNow;
    },
    resolveNextSleep: () => {
      const resolve = pendingSleeps.shift();
      if (!resolve) {
        throw new Error("no pending lifecycle sleep");
      }
      resolve();
    },
    setTimeout: (callback, ms) => {
      const timer = { callback, disposed: false, ms };
      timers.push(timer);
      return {
        dispose: () => {
          timer.disposed = true;
        },
      };
    },
    runNextTimer: () => {
      const timer = timers.find((candidate) => !candidate.disposed);
      if (!timer) {
        throw new Error("no pending lifecycle timer");
      }
      timer.disposed = true;
      timer.callback();
    },
    pendingTimerDelays: () => {
      return timers.filter((timer) => !timer.disposed).map((timer) => timer.ms);
    },
    sleeps,
  };
}

function backendLifecycleDefaults(): {
  lifecycleClock: {
    now(): number;
    sleep(ms: number): Promise<void>;
    setTimeout(callback: () => void, ms: number): { dispose(): void };
  };
  heartbeatPolicy: { kind: "disabled" };
  restartPolicy: {
    initialBackoffMs: number;
    maxBackoffMs: number;
  };
} {
  return {
    lifecycleClock: {
      now: () => 0,
      sleep: async () => undefined,
      setTimeout: () => ({ dispose: () => {} }),
    },
    heartbeatPolicy: { kind: "disabled" },
    restartPolicy: {
      initialBackoffMs: 0,
      maxBackoffMs: 0,
    },
  };
}

async function flushMicrotasks(): Promise<void> {
  await Promise.resolve();
  await Promise.resolve();
}

class CodedError extends Error {
  public constructor(public readonly code: string) {
    super(code);
  }
}

function initializeResult(): InitializeResult {
  return {
    protocol: { major: 1, minor: 27 },
    backendVersion: "0.1.0",
    bridgeVersion: "subversionr-svn-bridge/0.1.0",
    libsvnVersion: "1.14.5",
    platform: { os: "windows", arch: "x86_64" },
    cacheSchema: {
      schemaId: "subversionr.cache.v1",
      version: 1,
      rollback: "delete-and-reconcile",
    },
    capabilities: {
      contentLengthFraming: true,
      realLibsvnBridge: true,
      repositoryDiscover: true,
      repositoryOpen: true,
      repositoryClose: true,
      repositoryCheckout: true,
      statusSnapshot: true,
      statusRefresh: true,
      statusStaleNotification: true,
      contentGet: true,
      contentGetRevision: true,
      historyLog: true,
      historyBlame: true,
      operationRun: true,
      operationRunAdd: true,
      operationRunRemove: true,
      operationRunMove: true,
      operationRunCleanup: true,
      operationRunResolve: true,
      operationRunUpdate: true,
      operationRunUpdateSelectedPath: true,
      operationRunUpdateToRevision: true,
      operationRunUpdateDepth: true,
      operationRunUpdateExternalsPolicy: true,
      propertiesList: true,
      operationRunPropertySet: true,
      operationRunPropertyDelete: true,
      ignore: true,
      operationRunChangelistSet: true,
      operationRunChangelistClear: true,
      operationRunLock: true,
      operationRunUnlock: true,
      operationRunBranchCreate: true,
      operationRunSwitch: true,
      operationRunCommit: true,
      operationRunCommitMultiPath: true,
      diagnosticsGet: true,
      credentialRequest: true,
      certificateRequest: true,
    },
  };
}
