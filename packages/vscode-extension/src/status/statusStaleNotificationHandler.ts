import type { SourceControlProjectionService } from "../scm/sourceControlProjectionService";
import { parseStatusDelta, type StatusDelta } from "./statusRefreshRpcClient";
import type { StatusSnapshotStore, StatusStaleMark } from "./statusSnapshotStore";
import type { WatcherOverflowDiagnostics } from "./watcherOverflowDiagnostics";

export interface StatusNotificationHandlerOptions {
  statusSnapshotStore: Pick<StatusSnapshotStore, "applyDelta" | "getSnapshot" | "markStale">;
  sourceControlProjection: Pick<SourceControlProjectionService, "applyDelta" | "getProjection" | "markStale" | "replaceSnapshot">;
  watcherOverflowDiagnostics: Pick<WatcherOverflowDiagnostics, "recordOverflow">;
}

export class StatusStaleNotificationError extends Error {
  public constructor(
    public readonly code: string,
    public readonly category: "input" | "unsupported",
    public readonly messageKey: string,
    public readonly safeArgs: Record<string, unknown> = {},
  ) {
    super(code);
    this.name = "StatusStaleNotificationError";
  }
}

const STATUS_STALE_MARK_FIELDS = new Set(["repositoryId", "epoch", "reason", "timestamp", "source"]);
const WATCHER_OVERFLOW_NOTIFICATION_FIELDS = new Set(["repositoryId", "epoch", "timestamp"]);

export function createStatusNotificationHandler(
  options: StatusNotificationHandlerOptions,
): (method: string, params: unknown) => void {
  return (method, params) => {
    if (method === "status/stale") {
      const mark = parseStatusStaleMark(params);
      requireInitializedStaleState(options, mark);
      options.statusSnapshotStore.markStale(mark);
      publishProjectionStale(options, mark);
      return;
    }

    if (method === "status/delta") {
      const delta = parseStatusDelta(params);
      requireInitializedDeltaState(options, delta);
      options.statusSnapshotStore.applyDelta(delta);
      publishProjectionDelta(options, delta);
      return;
    }

    if (method === "watcher/overflow") {
      const mark = parseWatcherOverflowNotification(params);
      requireInitializedStaleState(options, mark);
      options.statusSnapshotStore.markStale(mark);
      publishProjectionStale(options, mark);
      options.watcherOverflowDiagnostics.recordOverflow({
        repositoryId: mark.repositoryId,
        epoch: mark.epoch,
        timestamp: mark.timestamp,
        source: "native-watcher",
      });
      return;
    }

    throw new StatusStaleNotificationError(
      "SUBVERSIONR_BACKEND_NOTIFICATION_UNSUPPORTED",
      "unsupported",
      "error.backend.notificationUnsupported",
      { method },
    );
  };
}

function publishProjectionDelta(options: StatusNotificationHandlerOptions, delta: StatusDelta): void {
  try {
    options.sourceControlProjection.applyDelta(delta);
  } catch (error) {
    replaceProjectionFromCanonicalSnapshot(options, delta.repositoryId, delta.epoch, delta.generation);
    throw error;
  }
}

function publishProjectionStale(options: StatusNotificationHandlerOptions, mark: StatusStaleMark): void {
  try {
    options.sourceControlProjection.markStale(mark);
  } catch (error) {
    replaceProjectionFromCanonicalSnapshot(options, mark.repositoryId, mark.epoch);
    throw error;
  }
}

function replaceProjectionFromCanonicalSnapshot(
  options: StatusNotificationHandlerOptions,
  repositoryId: string,
  epoch: number,
  expectedGeneration?: number,
): void {
  const snapshot = options.statusSnapshotStore.getSnapshot(repositoryId);
  if (!snapshot || snapshot.epoch !== epoch) {
    throw notificationStateUnavailable(repositoryId, "status");
  }
  if (expectedGeneration !== undefined && snapshot.generation !== expectedGeneration) {
    throw notificationStateUnavailable(repositoryId, "status");
  }
  options.sourceControlProjection.replaceSnapshot(snapshot);
}

function parseWatcherOverflowNotification(params: unknown): StatusStaleMark {
  if (!isRecord(params)) {
    throw invalidWatcherOverflowNotification("params");
  }
  requireExactWatcherOverflowNotificationFields(params);
  const repositoryId = requireWatcherOverflowNonEmptyString(params.repositoryId, "repositoryId");
  const epoch = requireWatcherOverflowEpoch(params.epoch);
  const timestamp = requireWatcherOverflowTimestamp(params.timestamp);
  return {
    repositoryId,
    epoch,
    reason: "watcherOverflow",
    timestamp,
    source: "native-watcher",
  };
}

function requireExactWatcherOverflowNotificationFields(params: Record<string, unknown>): void {
  for (const field of Object.keys(params)) {
    if (!WATCHER_OVERFLOW_NOTIFICATION_FIELDS.has(field)) {
      throw invalidWatcherOverflowNotification(field);
    }
  }
  for (const field of WATCHER_OVERFLOW_NOTIFICATION_FIELDS) {
    if (!(field in params)) {
      throw invalidWatcherOverflowNotification(field);
    }
  }
}

function requireWatcherOverflowNonEmptyString(value: unknown, field: string): string {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw invalidWatcherOverflowNotification(field);
  }
  return value;
}

function requireWatcherOverflowEpoch(value: unknown): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
    throw invalidWatcherOverflowNotification("epoch");
  }
  return value;
}

function requireWatcherOverflowTimestamp(value: unknown): string {
  const timestamp = requireWatcherOverflowNonEmptyString(value, "timestamp");
  if (!Number.isFinite(Date.parse(timestamp))) {
    throw invalidWatcherOverflowNotification("timestamp");
  }
  return timestamp;
}

function invalidWatcherOverflowNotification(field: string): StatusStaleNotificationError {
  return new StatusStaleNotificationError(
    "SUBVERSIONR_WATCHER_OVERFLOW_NOTIFICATION_INVALID",
    "input",
    "error.status.watcherOverflowNotificationInvalid",
    { field },
  );
}

function parseStatusStaleMark(params: unknown): StatusStaleMark {
  if (!isRecord(params)) {
    throw invalidStatusStaleNotification("params");
  }
  requireExactStatusStaleMarkFields(params);
  const repositoryId = requireNonEmptyString(params.repositoryId, "repositoryId");
  const epoch = requireEpoch(params.epoch);
  const reason = requireNonEmptyString(params.reason, "reason");
  const timestamp = requireNonEmptyString(params.timestamp, "timestamp");
  const source = requireNonEmptyString(params.source, "source");
  return { repositoryId, epoch, reason, timestamp, source };
}

function requireExactStatusStaleMarkFields(params: Record<string, unknown>): void {
  for (const field of Object.keys(params)) {
    if (!STATUS_STALE_MARK_FIELDS.has(field)) {
      throw invalidStatusStaleNotification(field);
    }
  }
  for (const field of STATUS_STALE_MARK_FIELDS) {
    if (!(field in params)) {
      throw invalidStatusStaleNotification(field);
    }
  }
}

function requireNonEmptyString(value: unknown, field: string): string {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw invalidStatusStaleNotification(field);
  }
  return value;
}

function requireEpoch(value: unknown): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
    throw invalidStatusStaleNotification("epoch");
  }
  return value;
}

function invalidStatusStaleNotification(field: string): StatusStaleNotificationError {
  return new StatusStaleNotificationError(
    "SUBVERSIONR_STATUS_STALE_NOTIFICATION_INVALID",
    "input",
    "error.status.staleNotificationInvalid",
    { field },
  );
}

function requireInitializedStaleState(
  options: StatusNotificationHandlerOptions,
  mark: StatusStaleMark,
): void {
  const snapshot = options.statusSnapshotStore.getSnapshot(mark.repositoryId);
  if (!snapshot || snapshot.epoch !== mark.epoch) {
    throw staleStateUnavailable(mark.repositoryId, "status");
  }
  const projection = options.sourceControlProjection.getProjection(mark.repositoryId);
  if (!projection || projection.epoch !== mark.epoch) {
    throw staleStateUnavailable(mark.repositoryId, "projection");
  }
}

function staleStateUnavailable(repositoryId: string, state: "status" | "projection"): StatusStaleNotificationError {
  return new StatusStaleNotificationError(
    "SUBVERSIONR_STATUS_STALE_NOTIFICATION_STATE_UNAVAILABLE",
    "input",
    "error.status.staleNotificationStateUnavailable",
    { repositoryId, state },
  );
}

function requireInitializedDeltaState(
  options: StatusNotificationHandlerOptions,
  delta: StatusDelta,
): void {
  const snapshot = options.statusSnapshotStore.getSnapshot(delta.repositoryId);
  if (!snapshot || snapshot.epoch !== delta.epoch || delta.generation <= snapshot.generation) {
    throw notificationStateUnavailable(delta.repositoryId, "status");
  }
  const projection = options.sourceControlProjection.getProjection(delta.repositoryId);
  if (!projection || projection.epoch !== delta.epoch || delta.generation <= projection.generation) {
    throw notificationStateUnavailable(delta.repositoryId, "projection");
  }
  if (snapshot.generation !== projection.generation) {
    throw notificationStateDiverged(delta.repositoryId, snapshot.generation, projection.generation);
  }
}

function notificationStateUnavailable(repositoryId: string, state: "status" | "projection"): StatusStaleNotificationError {
  return new StatusStaleNotificationError(
    "SUBVERSIONR_STATUS_NOTIFICATION_STATE_UNAVAILABLE",
    "input",
    "error.status.notificationStateUnavailable",
    { repositoryId, state },
  );
}

function notificationStateDiverged(
  repositoryId: string,
  statusGeneration: number,
  projectionGeneration: number,
): StatusStaleNotificationError {
  return new StatusStaleNotificationError(
    "SUBVERSIONR_STATUS_NOTIFICATION_STATE_DIVERGED",
    "input",
    "error.status.notificationStateDiverged",
    { repositoryId, statusGeneration, projectionGeneration },
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}
