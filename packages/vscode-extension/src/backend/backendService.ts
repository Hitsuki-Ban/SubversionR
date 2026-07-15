import type {
  BackendConnection,
  BackendConnectionTermination,
  BackendConnectionTerminationSubscription,
  BackendLaunchConfig,
} from "./backendProcess";

export type BackendStarter = (config: BackendLaunchConfig) => Promise<BackendConnection>;

export interface BackendLifecycleTimer {
  dispose(): void;
}

export interface BackendLifecycleClock {
  now(): number;
  sleep(ms: number): Promise<void>;
  setTimeout(callback: () => void, ms: number): BackendLifecycleTimer;
}

export interface BackendRestartPolicy {
  initialBackoffMs: number;
  maxBackoffMs: number;
}

export type BackendHeartbeatPolicy =
  | {
      kind: "disabled";
    }
  | {
      kind: "enabled";
      intervalMs: number;
      timeoutMs: number;
    };

export interface BackendServiceOptions {
  readConfig(): BackendLaunchConfig;
  start: BackendStarter;
  lifecycleClock: BackendLifecycleClock;
  heartbeatPolicy: BackendHeartbeatPolicy;
  restartPolicy: BackendRestartPolicy;
}

export interface BackendServiceTerminationSubscription {
  dispose(): void;
}

export type BackendLifecycleState =
  | {
      status: "idle";
    }
  | {
      status: "ready";
      since: number;
    }
  | {
      status: "degraded";
      reason: BackendDegradedReason;
      since: number;
      consecutiveFailures: number;
      restartAfter: number;
      lastErrorCode: string;
    };

export type BackendDegradedReason = "startupFailed" | "terminated" | "heartbeatFailed" | "protocolFault";

export type BackendLifecycleEvent =
  | BackendLifecycleState
  | {
      status: "recovered";
      since: number;
      recoveredFrom: BackendDegradedReason;
      consecutiveFailures: number;
    };

export interface BackendServiceLifecycleSubscription {
  dispose(): void;
}

export class BackendService {
  private startup: Promise<BackendConnection> | undefined;
  private startupCancellation: BackendStartupCancellation | undefined;
  private connection: BackendConnection | undefined;
  private connectionTerminationSubscription: BackendConnectionTerminationSubscription | undefined;
  private shutdownPromise: Promise<void> | undefined;
  private disposed = false;
  private readonly terminationListeners = new Set<(event: BackendConnectionTermination) => void>();
  private readonly lifecycleListeners = new Set<(event: BackendLifecycleEvent) => void>();
  private lifecycleState: BackendLifecycleState = { status: "idle" };
  private consecutiveFailures = 0;
  private heartbeatTimer: BackendLifecycleTimer | undefined;
  private heartbeatToken = 0;

  public constructor(private readonly options: BackendServiceOptions) {
    validateHeartbeatPolicy(options.heartbeatPolicy);
  }

  public onDidTerminate(
    listener: (event: BackendConnectionTermination) => void,
  ): BackendServiceTerminationSubscription {
    this.terminationListeners.add(listener);
    return {
      dispose: () => {
        this.terminationListeners.delete(listener);
      },
    };
  }

  public onDidChangeLifecycleState(
    listener: (event: BackendLifecycleEvent) => void,
  ): BackendServiceLifecycleSubscription {
    this.lifecycleListeners.add(listener);
    return {
      dispose: () => {
        this.lifecycleListeners.delete(listener);
      },
    };
  }

  public getLifecycleState(): BackendLifecycleState {
    return cloneLifecycleState(this.lifecycleState);
  }

  public initialize(): Promise<BackendConnection> {
    if (this.disposed) {
      return Promise.reject(new Error("backend service disposed"));
    }
    if (this.connection) {
      return Promise.resolve(this.connection);
    }
    if (this.startup) {
      return this.startup;
    }

    const startupAttempt = this.initializeConnection();
    const startupCancellation = createBackendStartupCancellation();
    this.startupCancellation = startupCancellation;
    void startupAttempt.then(
      (connection) => {
        if (startupCancellation.cancelled) {
          connection.dispose();
        }
      },
      () => undefined,
    );
    const startup = Promise.race([startupAttempt, startupCancellation.promise])
      .then((connection) => {
        if (this.disposed || startupCancellation.cancelled) {
          connection.dispose();
          throw new BackendStartupCancellationError(
            this.disposed ? "backend service disposed" : "backend service startup cancelled",
          );
        }
        if (this.startupCancellation === startupCancellation) {
          this.startupCancellation = undefined;
        }
        this.connection = connection;
        this.connectionTerminationSubscription = connection.onDidTerminate((event) => {
          if (this.connection !== connection) {
            return;
          }
          this.stopHeartbeat();
          this.clearConnectionTerminationSubscription();
          this.connection = undefined;
          this.startup = undefined;
          this.shutdownPromise = undefined;
          const degradation = degradationFromTermination(event);
          this.markDegraded(degradation.reason, degradation.lastErrorCode);
          this.fireTerminate(event);
        });
        this.startHeartbeat(connection);
        this.markReady();
        return connection;
      })
      .catch((error: unknown) => {
        if (this.startup === startup) {
          this.startup = undefined;
        }
        if (this.startupCancellation === startupCancellation) {
          this.startupCancellation = undefined;
        }
        if (!this.disposed && !(error instanceof BackendStartupCancellationError)) {
          this.markDegraded("startupFailed", errorCode(error, "SUBVERSIONR_BACKEND_STARTUP_FAILED"));
        }
        throw error;
      });
    this.startup = startup;

    return this.startup;
  }

  public async shutdown(): Promise<void> {
    if (this.shutdownPromise) {
      return this.shutdownPromise;
    }
    if (!this.connection && this.startup) {
      const pendingStartup = this.startup;
      this.startupCancellation?.cancel("backend service shutdown during startup");
      this.startupCancellation = undefined;
      this.startup = undefined;
      this.lifecycleState = { status: "idle" };
      void pendingStartup.catch(() => undefined);
      return;
    }
    if (!this.connection && !this.startup) {
      return;
    }

    this.shutdownPromise = this.shutdownInitializedConnection();
    return this.shutdownPromise;
  }

  public dispose(): void {
    this.disposed = true;
    this.startupCancellation?.cancel("backend service disposed");
    this.startupCancellation = undefined;
    this.stopHeartbeat();
    this.clearConnectionTerminationSubscription();
    this.connection?.dispose();
    this.connection = undefined;
    this.startup = undefined;
    this.shutdownPromise = undefined;
  }

  private async shutdownInitializedConnection(): Promise<void> {
    let connection: BackendConnection | undefined;
    try {
      connection = this.connection ?? (await this.startup);
      if (!connection) {
        return;
      }
      this.stopHeartbeat();
      this.clearConnectionTerminationSubscription();
      await connection.shutdown();
    } finally {
      connection?.dispose();
      this.connection = undefined;
      this.startup = undefined;
      this.shutdownPromise = undefined;
      this.lifecycleState = { status: "idle" };
    }
  }

  private async initializeConnection(): Promise<BackendConnection> {
    const delayMs = this.restartBackoffDelayMs();
    if (delayMs > 0) {
      await this.options.lifecycleClock.sleep(delayMs);
    }
    return await this.startConnection();
  }

  private startConnection(): Promise<BackendConnection> {
    if (this.disposed) {
      return Promise.reject(new Error("backend service disposed"));
    }
    return this.options.start(this.options.readConfig());
  }

  private restartBackoffDelayMs(): number {
    if (this.lifecycleState.status !== "degraded") {
      return 0;
    }
    return Math.max(0, this.lifecycleState.restartAfter - this.options.lifecycleClock.now());
  }

  private clearConnectionTerminationSubscription(): void {
    this.connectionTerminationSubscription?.dispose();
    this.connectionTerminationSubscription = undefined;
  }

  private startHeartbeat(connection: BackendConnection): void {
    this.stopHeartbeat();
    if (this.options.heartbeatPolicy.kind !== "enabled") {
      return;
    }
    const token = this.heartbeatToken;
    this.scheduleHeartbeat(connection, token);
  }

  private stopHeartbeat(): void {
    this.heartbeatToken += 1;
    this.heartbeatTimer?.dispose();
    this.heartbeatTimer = undefined;
  }

  private scheduleHeartbeat(connection: BackendConnection, token: number): void {
    if (!this.isHeartbeatCurrent(connection, token) || this.options.heartbeatPolicy.kind !== "enabled") {
      return;
    }

    this.heartbeatTimer = this.options.lifecycleClock.setTimeout(() => {
      this.heartbeatTimer = undefined;
      void this.runHeartbeat(connection, token);
    }, this.options.heartbeatPolicy.intervalMs);
  }

  private async runHeartbeat(connection: BackendConnection, token: number): Promise<void> {
    if (!this.isHeartbeatCurrent(connection, token) || this.options.heartbeatPolicy.kind !== "enabled") {
      return;
    }

    try {
      await this.withHeartbeatTimeout(
        connection.sendRequest<unknown>("diagnostics/get", {}),
        this.options.heartbeatPolicy.timeoutMs,
      );
    } catch (error) {
      this.handleHeartbeatFailure(connection, error);
      return;
    }

    this.scheduleHeartbeat(connection, token);
  }

  private async withHeartbeatTimeout<T>(operation: Promise<T>, timeoutMs: number): Promise<T> {
    let timeout: BackendLifecycleTimer | undefined;
    const timeoutPromise = new Promise<T>((_, reject) => {
      timeout = this.options.lifecycleClock.setTimeout(() => {
        reject(new BackendHeartbeatTimeoutError(timeoutMs));
      }, timeoutMs);
    });

    try {
      return await Promise.race([operation, timeoutPromise]);
    } finally {
      timeout?.dispose();
    }
  }

  private handleHeartbeatFailure(connection: BackendConnection, error: unknown): void {
    if (this.connection !== connection || this.disposed) {
      return;
    }

    this.stopHeartbeat();
    this.clearConnectionTerminationSubscription();
    this.connection = undefined;
    this.startup = undefined;
    this.shutdownPromise = undefined;
    const lastErrorCode = errorCode(error, "SUBVERSIONR_BACKEND_HEARTBEAT_FAILED");
    this.markDegraded("heartbeatFailed", lastErrorCode);
    connection.dispose();
    this.fireTerminate({
      reason: "heartbeatFailed",
      message: lastErrorCode,
    });
  }

  private isHeartbeatCurrent(connection: BackendConnection, token: number): boolean {
    return !this.disposed && this.connection === connection && this.heartbeatToken === token;
  }

  private fireTerminate(event: BackendConnectionTermination): void {
    for (const listener of this.terminationListeners) {
      listener(event);
    }
  }

  private fireLifecycle(event: BackendLifecycleEvent): void {
    for (const listener of this.lifecycleListeners) {
      listener(event);
    }
  }

  private markReady(): void {
    const previous = this.lifecycleState;
    const now = this.options.lifecycleClock.now();
    this.lifecycleState = {
      status: "ready",
      since: now,
    };
    this.consecutiveFailures = 0;
    if (previous.status === "degraded") {
      this.fireLifecycle({
        status: "recovered",
        since: now,
        recoveredFrom: previous.reason,
        consecutiveFailures: previous.consecutiveFailures,
      });
    } else {
      this.fireLifecycle(this.getLifecycleState());
    }
  }

  private markDegraded(reason: BackendDegradedReason, lastErrorCode: string): void {
    const now = this.options.lifecycleClock.now();
    this.consecutiveFailures += 1;
    const backoffMs = Math.min(
      this.options.restartPolicy.initialBackoffMs * 2 ** (this.consecutiveFailures - 1),
      this.options.restartPolicy.maxBackoffMs,
    );
    this.lifecycleState = {
      status: "degraded",
      reason,
      since: now,
      consecutiveFailures: this.consecutiveFailures,
      restartAfter: now + backoffMs,
      lastErrorCode,
    };
    this.fireLifecycle(this.getLifecycleState());
  }
}

class BackendStartupCancellationError extends Error {
  public constructor(message: string) {
    super(message);
    this.name = "BackendStartupCancellationError";
  }
}

interface BackendStartupCancellation {
  readonly promise: Promise<never>;
  readonly cancelled: boolean;
  cancel(message: string): void;
}

function createBackendStartupCancellation(): BackendStartupCancellation {
  let cancelled = false;
  let rejectCancellation: (error: BackendStartupCancellationError) => void = () => undefined;
  const promise = new Promise<never>((_resolve, reject) => {
    rejectCancellation = reject;
  });
  return {
    promise,
    get cancelled() {
      return cancelled;
    },
    cancel: (message: string) => {
      if (cancelled) {
        return;
      }
      cancelled = true;
      rejectCancellation(new BackendStartupCancellationError(message));
    },
  };
}

function degradationFromTermination(event: BackendConnectionTermination): {
  reason: BackendDegradedReason;
  lastErrorCode: string;
} {
  if (event.reason === "protocolFault") {
    return {
      reason: "protocolFault",
      lastErrorCode:
        typeof event.message === "string" && event.message.trim().length > 0
          ? event.message
          : "SUBVERSIONR_BACKEND_PROTOCOL_FAULT",
    };
  }

  return {
    reason: "terminated",
    lastErrorCode: "SUBVERSIONR_BACKEND_TERMINATED",
  };
}

export function systemBackendLifecycleClock(): BackendLifecycleClock {
  return {
    now: () => Date.now(),
    sleep: async (ms) => {
      await new Promise((resolve) => {
        setTimeout(resolve, ms);
      });
    },
    setTimeout: (callback, ms) => {
      const timeout = setTimeout(callback, ms) as ReturnType<typeof setTimeout> & { unref?: () => void };
      timeout.unref?.();
      return {
        dispose: () => {
          clearTimeout(timeout);
        },
      };
    },
  };
}

function cloneLifecycleState(state: BackendLifecycleState): BackendLifecycleState {
  if (state.status === "ready") {
    return { status: "ready", since: state.since };
  }
  if (state.status === "degraded") {
    return {
      status: "degraded",
      reason: state.reason,
      since: state.since,
      consecutiveFailures: state.consecutiveFailures,
      restartAfter: state.restartAfter,
      lastErrorCode: state.lastErrorCode,
    };
  }
  return { status: "idle" };
}

function errorCode(error: unknown, fallback: string): string {
  if (typeof error === "object" && error !== null && "code" in error) {
    const code = (error as { code?: unknown }).code;
    if (typeof code === "string" && code.trim().length > 0) {
      return code;
    }
  }
  return fallback;
}

function validateHeartbeatPolicy(policy: BackendHeartbeatPolicy): void {
  if (policy.kind === "disabled") {
    return;
  }
  validatePositiveMilliseconds(policy.intervalMs, "heartbeatPolicy.intervalMs");
  validatePositiveMilliseconds(policy.timeoutMs, "heartbeatPolicy.timeoutMs");
}

function validatePositiveMilliseconds(value: number, name: string): void {
  if (!Number.isFinite(value) || value <= 0) {
    throw new Error(`${name} must be greater than 0`);
  }
}

class BackendHeartbeatTimeoutError extends Error {
  public readonly code = "SUBVERSIONR_BACKEND_HEARTBEAT_TIMEOUT";

  public constructor(timeoutMs: number) {
    super(`SUBVERSIONR_BACKEND_HEARTBEAT_TIMEOUT:${timeoutMs}`);
  }
}
