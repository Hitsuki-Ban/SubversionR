import { DirtyPathSet, type DirtyPathSetOptions } from "./dirtyPathSet";
import type { SourceControlProjectionService } from "../scm/sourceControlProjectionService";
import type { StatusCoverageScope, StatusDelta } from "./statusRefreshRpcClient";
import type { StatusSnapshotStore, StatusStaleMark } from "./statusSnapshotStore";
import type {
  DirtyFileEvent,
  RepositoryWatchScope,
  StatusRefreshClient,
  StatusRefreshRequest,
  StatusRefreshTarget,
} from "./types";

export type StatusRefreshSchedulerErrorCategory = "input" | "protocol" | "lifecycle";

export interface StatusRefreshSchedulerOptions extends DirtyPathSetOptions {
  debounceMs?: number;
  fullReconcileIntervalMs?: number;
  coverageRecorder?: StatusRefreshCoverageRecorder;
}

export interface CompletedStatusRefreshCoverage {
  repositoryId: string;
  epoch: number;
  generation: number;
  targets: StatusRefreshTarget[];
  coverage: StatusCoverageScope[];
  completeness: StatusDelta["completeness"];
  timestamp: string;
  source: string;
}

export interface StatusRefreshCoverageRecorder {
  recordCompletedStatusRefreshCoverage(record: CompletedStatusRefreshCoverage): void;
}

export interface FullReconcileRequest {
  repositoryId: string;
  epoch: number;
}

export interface ResourceRefreshRequest {
  repositoryId: string;
  epoch: number;
  path: string;
}

export interface TargetRefreshRequest {
  repositoryId: string;
  epoch: number;
  targets: StatusRefreshTarget[];
}

export interface StatusRefreshRunOptions {
  signal?: AbortSignal;
}

interface RepositoryState {
  scope: RepositoryWatchScope;
  dirtyPaths: DirtyPathSet;
  timer: ReturnType<typeof setTimeout> | undefined;
  fullReconcileTimer: ReturnType<typeof setTimeout> | undefined;
  flushing: Promise<void> | undefined;
  currentRefresh: CurrentRefresh | undefined;
  overflowStaleMarked: boolean;
  overflowStaleTimestamp: number | undefined;
}

interface CurrentRefresh {
  controller: AbortController;
  targets: StatusRefreshTarget[];
  cancelReason: "dirtyGenerationSuperseded" | "userCancelled" | undefined;
  disposeCallerCancellation: (() => void) | undefined;
}

type StatusRefreshStatusStore = Pick<StatusSnapshotStore, "applyDelta" | "getSnapshot" | "markStale">;
type StatusRefreshSourceControlProjection = Pick<
  SourceControlProjectionService,
  "applyDelta" | "getProjection" | "markStale" | "replaceSnapshot"
>;

const DEFAULT_DEBOUNCE_MS = 250;
const MANUAL_FULL_RECONCILE_REASON = "manualFullReconcile";
const SCHEDULED_FULL_RECONCILE_REASON = "scheduledFullReconcile";
const RESOURCE_REFRESH_REASON = "resourceRefresh";
const REFRESH_CANCELLED_REASON = "refreshCancelled";
const REFRESH_CANCELLED_SOURCE = "vscode-status-scheduler";

export class StatusRefreshSchedulerError extends Error {
  public constructor(
    public readonly code: string,
    public readonly category: StatusRefreshSchedulerErrorCategory,
    public readonly messageKey: string,
    public readonly safeArgs: Record<string, unknown> = {},
  ) {
    super(code);
    this.name = "StatusRefreshSchedulerError";
  }
}

export class StatusRefreshScheduler {
  private readonly repositories = new Map<string, RepositoryState>();
  private readonly debounceMs: number;
  private readonly fullReconcileIntervalMs: number | undefined;

  public constructor(
    private readonly client: StatusRefreshClient,
    private readonly statusSnapshotStore: StatusRefreshStatusStore,
    private readonly sourceControlProjection: StatusRefreshSourceControlProjection,
    private readonly options: StatusRefreshSchedulerOptions = {},
  ) {
    this.debounceMs = options.debounceMs ?? DEFAULT_DEBOUNCE_MS;
    this.fullReconcileIntervalMs = validateOptionalPositiveInteger(
      options.fullReconcileIntervalMs,
      "fullReconcileIntervalMs",
    );
  }

  public registerRepository(scope: RepositoryWatchScope): void {
    const existing = this.repositories.get(scope.repositoryId);
    if (existing) {
      this.clearRepositoryTimers(existing);
    }
    const state: RepositoryState = {
      scope,
      dirtyPaths: new DirtyPathSet(scope, this.options),
      timer: undefined,
      fullReconcileTimer: undefined,
      flushing: undefined,
      currentRefresh: undefined,
      overflowStaleMarked: false,
      overflowStaleTimestamp: undefined,
    };
    this.repositories.set(scope.repositoryId, state);
    this.scheduleFullReconcile(scope.repositoryId, state);
  }

  public unregisterRepository(repositoryId: string): void {
    const state = this.repositories.get(repositoryId);
    if (state) {
      this.clearRepositoryTimers(state);
    }
    this.repositories.delete(repositoryId);
  }

  public recordFileEvent(repositoryId: string, event: DirtyFileEvent): boolean {
    const state = this.repositories.get(repositoryId);
    if (!state) {
      throw new Error(`Repository is not registered: ${repositoryId}`);
    }

    const wasOverflowed = state.dirtyPaths.isOverflowed;
    const accepted = state.dirtyPaths.record(event);
    if (accepted) {
      if (!wasOverflowed && state.dirtyPaths.isOverflowed) {
        state.overflowStaleTimestamp = state.dirtyPaths.overflowTimestamp ?? event.timestamp;
      }
      this.markOverflowStaleIfInitialized(state);
      this.cancelInFlightRefreshForDirtyGeneration(state, event.timestamp);
      this.scheduleFlush(repositoryId, state);
    }
    return accepted;
  }

  public async flushRepository(repositoryId: string, options?: StatusRefreshRunOptions): Promise<void> {
    const state = this.repositories.get(repositoryId);
    if (!state) {
      throw new Error(`Repository is not registered: ${repositoryId}`);
    }

    if (state.flushing) {
      await state.flushing.catch(() => undefined);
      return this.flushRepository(repositoryId, options);
    }
    if (state.timer) {
      clearTimeout(state.timer);
      state.timer = undefined;
    }

    this.markOverflowStaleIfInitialized(state);
    const targets = state.dirtyPaths.drainToRefreshTargets();
    if (targets.length === 0) {
      return;
    }

    const request: StatusRefreshRequest = {
      repositoryId: state.scope.repositoryId,
      epoch: state.scope.epoch,
      targets,
    };

    const refresh = this.beginRefresh(state, targets, options);
    state.flushing = this.client
      .refreshStatus(request, { signal: refresh.controller.signal })
      .then((delta) => {
        this.requireRefreshCurrent(state, refresh);
        this.statusSnapshotStore.applyDelta(delta);
        return delta;
      })
      .catch((error: unknown) => {
        state.dirtyPaths.mergeTargets(targets);
        if (refresh.cancelReason) {
          throw refreshCancelled(state, refresh.cancelReason);
        }
        throw error;
      })
      .then((delta) => {
        this.requireRefreshCurrent(state, refresh);
        this.publishProjectionDelta(delta);
        this.recordCompletedRefreshCoverage(refresh, delta);
      })
      .finally(() => {
        this.finishRefresh(state, refresh);
        state.flushing = undefined;
        if (!state.dirtyPaths.isOverflowed) {
          state.overflowStaleMarked = false;
          state.overflowStaleTimestamp = undefined;
        }
      });
    return state.flushing;
  }

  public async fullReconcileRepository(
    request: FullReconcileRequest,
    options?: StatusRefreshRunOptions,
  ): Promise<void> {
    const state = this.repositories.get(request.repositoryId);
    if (!state) {
      throw new Error(`Repository is not registered: ${request.repositoryId}`);
    }
    if (state.scope.epoch !== request.epoch) {
      throw new StatusRefreshSchedulerError(
        "SUBVERSIONR_STATUS_FULL_RECONCILE_EPOCH_MISMATCH",
        "lifecycle",
        "error.status.fullReconcileEpochMismatch",
        {
          repositoryId: request.repositoryId,
          expected: state.scope.epoch,
          actual: request.epoch,
        },
      );
    }

    return this.runFullReconcile(
      state,
      MANUAL_FULL_RECONCILE_REASON,
      () => this.fullReconcileRepository(request, options),
      options,
    );
  }

  public async refreshResource(request: ResourceRefreshRequest): Promise<void> {
    const state = this.repositories.get(request.repositoryId);
    if (!state) {
      throw new Error(`Repository is not registered: ${request.repositoryId}`);
    }
    if (state.scope.epoch !== request.epoch) {
      throw new StatusRefreshSchedulerError(
        "SUBVERSIONR_STATUS_RESOURCE_REFRESH_EPOCH_MISMATCH",
        "lifecycle",
        "error.status.resourceRefreshEpochMismatch",
        {
          repositoryId: request.repositoryId,
          expected: state.scope.epoch,
          actual: request.epoch,
        },
      );
    }
    if (!isRepositoryRelativeRefreshPath(request.path)) {
      throw new StatusRefreshSchedulerError(
        "SUBVERSIONR_STATUS_RESOURCE_REFRESH_PATH_INVALID",
        "input",
        "error.status.resourceRefreshPathInvalid",
        { path: request.path },
      );
    }

    return this.runRefreshTargets(state, [
      {
        path: request.path,
        depth: "empty",
        reason: RESOURCE_REFRESH_REASON,
      },
    ], () => this.refreshResource(request));
  }

  public async refreshTargets(
    request: TargetRefreshRequest,
    options?: StatusRefreshRunOptions,
  ): Promise<void> {
    const state = this.repositories.get(request.repositoryId);
    if (!state) {
      throw new Error(`Repository is not registered: ${request.repositoryId}`);
    }
    if (state.scope.epoch !== request.epoch) {
      throw new StatusRefreshSchedulerError(
        "SUBVERSIONR_STATUS_TARGET_REFRESH_EPOCH_MISMATCH",
        "lifecycle",
        "error.status.targetRefreshEpochMismatch",
        {
          repositoryId: request.repositoryId,
          expected: state.scope.epoch,
          actual: request.epoch,
        },
      );
    }
    const targets = validateRefreshTargets(request.targets);
    return this.runRefreshTargets(state, targets, () => this.refreshTargets(request, options), options);
  }

  private async runRefreshTargets(
    state: RepositoryState,
    targets: StatusRefreshTarget[],
    retry: () => Promise<void>,
    options?: StatusRefreshRunOptions,
  ): Promise<void> {
    if (state.flushing) {
      await state.flushing.catch(() => undefined);
      return retry();
    }

    const refresh = this.beginRefresh(state, targets, options);
    state.flushing = this.client
      .refreshStatus({
        repositoryId: state.scope.repositoryId,
        epoch: state.scope.epoch,
        targets,
      }, { signal: refresh.controller.signal })
      .then((delta) => {
        this.requireRefreshCurrent(state, refresh);
        this.statusSnapshotStore.applyDelta(delta);
        return delta;
      })
      .catch((error: unknown) => {
        state.dirtyPaths.mergeTargets(targets);
        if (refresh.cancelReason) {
          throw refreshCancelled(state, refresh.cancelReason);
        }
        throw error;
      })
      .then((delta) => {
        this.requireRefreshCurrent(state, refresh);
        this.publishProjectionDelta(delta);
        this.recordCompletedRefreshCoverage(refresh, delta);
      })
      .finally(() => {
        this.finishRefresh(state, refresh);
        state.flushing = undefined;
        if (!state.dirtyPaths.isOverflowed) {
          state.overflowStaleMarked = false;
          state.overflowStaleTimestamp = undefined;
        }
      });
    return state.flushing;
  }

  private async runScheduledFullReconcile(repositoryId: string, state: RepositoryState): Promise<void> {
    if (this.repositories.get(repositoryId) !== state) {
      return;
    }
    return this.runFullReconcile(state, SCHEDULED_FULL_RECONCILE_REASON, () =>
      this.runScheduledFullReconcile(repositoryId, state),
    );
  }

  private async runFullReconcile(
    state: RepositoryState,
    reason: typeof MANUAL_FULL_RECONCILE_REASON | typeof SCHEDULED_FULL_RECONCILE_REASON,
    retry: () => Promise<void>,
    options?: StatusRefreshRunOptions,
  ): Promise<void> {
    if (state.flushing) {
      await state.flushing.catch(() => undefined);
      return retry();
    }
    this.clearRepositoryTimers(state);
    const pendingTargets = state.dirtyPaths.drainToRefreshTargets();
    const target = fullReconcileTarget(reason);

    const refresh = this.beginRefresh(state, [target], options);
    state.flushing = this.client
      .refreshStatus({
        repositoryId: state.scope.repositoryId,
        epoch: state.scope.epoch,
        targets: [target],
      }, { signal: refresh.controller.signal })
      .then((delta) => {
        this.requireRefreshCurrent(state, refresh);
        requireFullReconcileDelta(delta, reason);
        this.statusSnapshotStore.applyDelta(delta);
        return delta;
      })
      .catch((error: unknown) => {
        state.dirtyPaths.mergeTargets(refresh.cancelReason ? [target, ...pendingTargets] : pendingTargets);
        if (refresh.cancelReason) {
          throw refreshCancelled(state, refresh.cancelReason);
        }
        throw error;
      })
      .then((delta) => {
        this.requireRefreshCurrent(state, refresh);
        this.publishProjectionDelta(delta);
        this.recordCompletedRefreshCoverage(refresh, delta);
      })
      .finally(() => {
        this.finishRefresh(state, refresh);
        state.flushing = undefined;
        if (!state.dirtyPaths.isOverflowed) {
          state.overflowStaleMarked = false;
          state.overflowStaleTimestamp = undefined;
        }
        if (this.repositories.get(state.scope.repositoryId) === state) {
          this.scheduleFullReconcile(state.scope.repositoryId, state);
        }
      });
    return state.flushing;
  }

  private markOverflowStaleIfInitialized(state: RepositoryState): void {
    if (!state.dirtyPaths.isOverflowed || state.overflowStaleMarked) {
      return;
    }
    const timestamp = state.overflowStaleTimestamp ?? state.dirtyPaths.overflowTimestamp;
    if (timestamp === undefined) {
      return;
    }
    const marked = this.markStaleIfInitialized(state, {
      repositoryId: state.scope.repositoryId,
      epoch: state.scope.epoch,
      reason: "watcherOverflow",
      timestamp: new Date(timestamp).toISOString(),
      source: "vscode-watcher",
    });
    if (marked) {
      state.overflowStaleMarked = true;
      state.overflowStaleTimestamp = timestamp;
    }
  }

  private cancelInFlightRefreshForDirtyGeneration(state: RepositoryState, timestamp: number): void {
    const refresh = state.currentRefresh;
    if (!refresh || refresh.controller.signal.aborted) {
      return;
    }
    this.markStaleIfInitialized(state, {
      repositoryId: state.scope.repositoryId,
      epoch: state.scope.epoch,
      reason: REFRESH_CANCELLED_REASON,
      timestamp: new Date(timestamp).toISOString(),
      source: REFRESH_CANCELLED_SOURCE,
    });
    refresh.cancelReason = "dirtyGenerationSuperseded";
    refresh.controller.abort();
  }

  private beginRefresh(
    state: RepositoryState,
    targets: StatusRefreshTarget[],
    options?: StatusRefreshRunOptions,
  ): CurrentRefresh {
    const refresh: CurrentRefresh = {
      controller: new AbortController(),
      targets,
      cancelReason: undefined,
      disposeCallerCancellation: undefined,
    };
    const callerSignal = options?.signal;
    if (callerSignal) {
      const cancelFromCaller = (): void => {
        if (!refresh.controller.signal.aborted) {
          refresh.cancelReason = "userCancelled";
          refresh.controller.abort();
        }
      };
      if (callerSignal.aborted) {
        cancelFromCaller();
      } else {
        callerSignal.addEventListener("abort", cancelFromCaller, { once: true });
        refresh.disposeCallerCancellation = () => callerSignal.removeEventListener("abort", cancelFromCaller);
      }
    }
    state.currentRefresh = refresh;
    return refresh;
  }

  private recordCompletedRefreshCoverage(refresh: CurrentRefresh, delta: StatusDelta): void {
    this.options.coverageRecorder?.recordCompletedStatusRefreshCoverage({
      repositoryId: delta.repositoryId,
      epoch: delta.epoch,
      generation: delta.generation,
      targets: refresh.targets.map(cloneRefreshTarget),
      coverage: delta.coverage.map(cloneCoverageScope),
      completeness: delta.completeness,
      timestamp: delta.timestamp,
      source: delta.source,
    });
  }

  private finishRefresh(state: RepositoryState, refresh: CurrentRefresh): void {
    refresh.disposeCallerCancellation?.();
    if (state.currentRefresh === refresh) {
      state.currentRefresh = undefined;
    }
  }

  private requireRefreshCurrent(state: RepositoryState, refresh: CurrentRefresh): void {
    if (state.currentRefresh !== refresh || refresh.cancelReason) {
      throw refreshCancelled(state, refresh.cancelReason ?? "dirtyGenerationSuperseded");
    }
  }

  private markStaleIfInitialized(state: RepositoryState, mark: StatusStaleMark): boolean {
    const snapshot = this.statusSnapshotStore.getSnapshot(mark.repositoryId);
    const projection = this.sourceControlProjection.getProjection(mark.repositoryId);
    if (!snapshot && !projection) {
      return false;
    }
    if (!snapshot || snapshot.epoch !== state.scope.epoch) {
      throw staleStateUnavailable(mark.repositoryId, "status");
    }
    if (!projection || projection.epoch !== state.scope.epoch) {
      throw staleStateUnavailable(mark.repositoryId, "projection");
    }
    this.statusSnapshotStore.markStale(mark);
    this.publishProjectionStale(mark);
    return true;
  }

  private publishProjectionDelta(delta: StatusDelta): void {
    try {
      this.sourceControlProjection.applyDelta(delta);
    } catch (error) {
      this.replaceProjectionFromCanonicalSnapshot(delta.repositoryId, delta.epoch, delta.generation);
      throw error;
    }
  }

  private publishProjectionStale(mark: StatusStaleMark): void {
    try {
      this.sourceControlProjection.markStale(mark);
    } catch (error) {
      this.replaceProjectionFromCanonicalSnapshot(mark.repositoryId, mark.epoch);
      throw error;
    }
  }

  private replaceProjectionFromCanonicalSnapshot(
    repositoryId: string,
    epoch: number,
    expectedGeneration?: number,
  ): void {
    const snapshot = this.statusSnapshotStore.getSnapshot(repositoryId);
    if (!snapshot || snapshot.epoch !== epoch) {
      throw staleStateUnavailable(repositoryId, "status");
    }
    if (expectedGeneration !== undefined && snapshot.generation !== expectedGeneration) {
      throw staleStateUnavailable(repositoryId, "status");
    }
    this.sourceControlProjection.replaceSnapshot(snapshot);
  }

  private scheduleFlush(repositoryId: string, state: RepositoryState): void {
    if (state.timer) {
      clearTimeout(state.timer);
    }
    state.timer = setTimeout(() => {
      state.timer = undefined;
      void this.flushRepository(repositoryId).catch(() => undefined);
    }, this.debounceMs);
  }

  private scheduleFullReconcile(repositoryId: string, state: RepositoryState): void {
    if (this.fullReconcileIntervalMs === undefined) {
      return;
    }
    if (state.fullReconcileTimer) {
      clearTimeout(state.fullReconcileTimer);
    }
    state.fullReconcileTimer = setTimeout(() => {
      state.fullReconcileTimer = undefined;
      void this.runScheduledFullReconcile(repositoryId, state).catch(() => undefined);
    }, this.fullReconcileIntervalMs);
  }

  private clearRepositoryTimers(state: RepositoryState): void {
    if (state.timer) {
      clearTimeout(state.timer);
      state.timer = undefined;
    }
    if (state.fullReconcileTimer) {
      clearTimeout(state.fullReconcileTimer);
      state.fullReconcileTimer = undefined;
    }
  }
}

function fullReconcileTarget(
  reason: typeof MANUAL_FULL_RECONCILE_REASON | typeof SCHEDULED_FULL_RECONCILE_REASON,
): StatusRefreshTarget {
  return { path: ".", depth: "infinity", reason };
}

function requireFullReconcileDelta(
  delta: Awaited<ReturnType<StatusRefreshClient["refreshStatus"]>>,
  reason: typeof MANUAL_FULL_RECONCILE_REASON | typeof SCHEDULED_FULL_RECONCILE_REASON,
): void {
  if (delta.completeness !== "complete") {
    throw fullReconcileResponseError("completeness");
  }
  if (delta.coverage.length !== 1) {
    throw fullReconcileResponseError("coverage");
  }
  const [coverage] = delta.coverage;
  const target = fullReconcileTarget(reason);
  if (
    coverage.path !== target.path ||
    coverage.depth !== target.depth ||
    coverage.reason !== target.reason ||
    coverage.generation !== delta.generation
  ) {
    throw fullReconcileResponseError("coverage.0");
  }
}

function validateOptionalPositiveInteger(value: unknown, field: string): number | undefined {
  if (value === undefined) {
    return undefined;
  }
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value <= 0) {
    throw new StatusRefreshSchedulerError(
      "SUBVERSIONR_STATUS_SCHEDULER_OPTION_INVALID",
      "input",
      "error.status.schedulerOptionInvalid",
      { field },
    );
  }
  return value;
}

function fullReconcileResponseError(field: string): StatusRefreshSchedulerError {
  return new StatusRefreshSchedulerError(
    "SUBVERSIONR_STATUS_FULL_RECONCILE_RESPONSE_INVALID",
    "protocol",
    "error.status.fullReconcileResponseInvalid",
    { field },
  );
}

function staleStateUnavailable(repositoryId: string, state: "status" | "projection"): StatusRefreshSchedulerError {
  return new StatusRefreshSchedulerError(
    "SUBVERSIONR_STATUS_NOTIFICATION_STATE_UNAVAILABLE",
    "lifecycle",
    "error.status.notificationStateUnavailable",
    { repositoryId, state },
  );
}

function refreshCancelled(
  state: RepositoryState,
  reason: NonNullable<CurrentRefresh["cancelReason"]>,
): StatusRefreshSchedulerError {
  return new StatusRefreshSchedulerError(
    "SUBVERSIONR_STATUS_REFRESH_CANCELLED",
    "lifecycle",
    "error.status.refreshCancelled",
    {
      repositoryId: state.scope.repositoryId,
      reason,
    },
  );
}

function isRepositoryRelativeRefreshPath(path: string): boolean {
  if (typeof path !== "string" || path.trim().length === 0) {
    return false;
  }
  if (path.includes("\\") || path.startsWith("/") || path.endsWith("/")) {
    return false;
  }
  return path.split("/").every((segment) => segment.length > 0 && segment !== "." && segment !== "..") || path === ".";
}

function validateRefreshTargets(targets: StatusRefreshTarget[]): StatusRefreshTarget[] {
  if (!Array.isArray(targets) || targets.length === 0) {
    throw invalidTargetRefreshTarget("targets");
  }
  return targets.map((target, index) => validateRefreshTarget(target, `targets.${index}`));
}

function validateRefreshTarget(target: StatusRefreshTarget, field: string): StatusRefreshTarget {
  if (typeof target !== "object" || target === null) {
    throw invalidTargetRefreshTarget(field);
  }
  if (!isRepositoryRelativeRefreshPath(target.path)) {
    throw invalidTargetRefreshTarget(`${field}.path`);
  }
  if (!isStatusRefreshDepth(target.depth)) {
    throw invalidTargetRefreshTarget(`${field}.depth`);
  }
  if (typeof target.reason !== "string" || target.reason.trim().length === 0) {
    throw invalidTargetRefreshTarget(`${field}.reason`);
  }
  return {
    path: target.path,
    depth: target.depth,
    reason: target.reason,
  };
}

function cloneRefreshTarget(target: StatusRefreshTarget): StatusRefreshTarget {
  return {
    path: target.path,
    depth: target.depth,
    reason: target.reason,
  };
}

function cloneCoverageScope(scope: StatusCoverageScope): StatusCoverageScope {
  return {
    path: scope.path,
    depth: scope.depth,
    generation: scope.generation,
    reason: scope.reason,
  };
}

function isStatusRefreshDepth(depth: string): depth is StatusRefreshTarget["depth"] {
  return depth === "empty" || depth === "files" || depth === "immediates" || depth === "infinity";
}

function invalidTargetRefreshTarget(field: string): StatusRefreshSchedulerError {
  return new StatusRefreshSchedulerError(
    "SUBVERSIONR_STATUS_TARGET_REFRESH_TARGET_INVALID",
    "input",
    "error.status.targetRefreshTargetInvalid",
    { field },
  );
}
