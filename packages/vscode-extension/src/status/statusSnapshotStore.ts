import type {
  RepositoryIdentity,
  StatusEntry,
  StatusSnapshot,
  StatusSnapshotCompleteness,
  StatusSummary,
} from "./statusSnapshotRpcClient";
import type { StatusDelta, StatusSummaryDelta } from "./statusRefreshRpcClient";

export type StatusSnapshotStoreErrorCategory = "input" | "lifecycle";

export interface StatusSnapshotRepository {
  repositoryId: string;
  epoch: number;
}

export interface StoredStatusSnapshot {
  repositoryId: string;
  epoch: number;
  generation: number;
  completeness: StatusSnapshotCompleteness;
  identity: RepositoryIdentity;
  localEntries: StatusEntry[];
  remoteEntries: StatusEntry[];
  summary: StatusSummary;
  timestamp: string;
  source: string;
}

export interface StatusStaleMark {
  repositoryId: string;
  epoch: number;
  reason: string;
  timestamp: string;
  source: string;
}

interface RepositoryState {
  repositoryId: string;
  epoch: number;
  generation: number | undefined;
  completeness: StatusSnapshotCompleteness | undefined;
  identity: RepositoryIdentity | undefined;
  localEntries: Map<string, StatusEntry>;
  remoteEntries: Map<string, StatusEntry>;
  summary: StatusSummary | undefined;
  timestamp: string | undefined;
  source: string | undefined;
}

type InitializedRepositoryState = RepositoryState & {
  generation: number;
  completeness: StatusSnapshotCompleteness;
  identity: RepositoryIdentity;
  summary: StatusSummary;
  timestamp: string;
  source: string;
};

export class StatusSnapshotStoreError extends Error {
  public constructor(
    public readonly code: string,
    public readonly category: StatusSnapshotStoreErrorCategory,
    public readonly messageKey: string,
    public readonly safeArgs: Record<string, unknown> = {},
  ) {
    super(code);
    this.name = "StatusSnapshotStoreError";
  }
}

export class StatusSnapshotStore {
  private readonly repositories = new Map<string, RepositoryState>();

  public registerRepository(repository: StatusSnapshotRepository): void {
    if (!isNonEmptyString(repository.repositoryId)) {
      throw statusStoreInputError("repositoryId");
    }
    if (!Number.isSafeInteger(repository.epoch) || repository.epoch < 0) {
      throw statusStoreInputError("epoch");
    }
    if (this.repositories.has(repository.repositoryId)) {
      throw new StatusSnapshotStoreError(
        "SUBVERSIONR_STATUS_STORE_REPOSITORY_ALREADY_REGISTERED",
        "lifecycle",
        "error.status.storeRepositoryAlreadyRegistered",
        { repositoryId: repository.repositoryId },
      );
    }
    this.repositories.set(repository.repositoryId, {
      repositoryId: repository.repositoryId,
      epoch: repository.epoch,
      generation: undefined,
      completeness: undefined,
      identity: undefined,
      localEntries: new Map(),
      remoteEntries: new Map(),
      summary: undefined,
      timestamp: undefined,
      source: undefined,
    });
  }

  public unregisterRepository(repositoryId: string): void {
    this.repositories.delete(repositoryId);
  }

  public applySnapshot(snapshot: StatusSnapshot): StoredStatusSnapshot {
    const state = this.repositories.get(snapshot.repositoryId);
    if (!state) {
      throw new StatusSnapshotStoreError(
        "SUBVERSIONR_STATUS_STORE_REPOSITORY_NOT_REGISTERED",
        "lifecycle",
        "error.status.storeRepositoryNotRegistered",
        { repositoryId: snapshot.repositoryId },
      );
    }
    if (state.epoch !== snapshot.epoch) {
      throw new StatusSnapshotStoreError(
        "SUBVERSIONR_STATUS_STORE_SNAPSHOT_EPOCH_MISMATCH",
        "lifecycle",
        "error.status.storeSnapshotMismatch",
        {
          repositoryId: state.repositoryId,
          expected: state.epoch,
          actual: snapshot.epoch,
        },
      );
    }
    if (state.generation !== undefined && snapshot.generation < state.generation) {
      throw new StatusSnapshotStoreError(
        "SUBVERSIONR_STATUS_STORE_SNAPSHOT_GENERATION_STALE",
        "lifecycle",
        "error.status.storeGenerationStale",
        {
          repositoryId: state.repositoryId,
          current: state.generation,
          actual: snapshot.generation,
        },
      );
    }

    return this.applySnapshotToState(state, snapshot);
  }

  public replaceSnapshot(snapshot: StatusSnapshot): StoredStatusSnapshot {
    const state = this.repositories.get(snapshot.repositoryId);
    if (!state) {
      throw new StatusSnapshotStoreError(
        "SUBVERSIONR_STATUS_STORE_REPOSITORY_NOT_REGISTERED",
        "lifecycle",
        "error.status.storeRepositoryNotRegistered",
        { repositoryId: snapshot.repositoryId },
      );
    }
    if (state.epoch === snapshot.epoch && state.generation !== undefined && snapshot.generation < state.generation) {
      throw new StatusSnapshotStoreError(
        "SUBVERSIONR_STATUS_STORE_SNAPSHOT_GENERATION_STALE",
        "lifecycle",
        "error.status.storeGenerationStale",
        {
          repositoryId: state.repositoryId,
          current: state.generation,
          actual: snapshot.generation,
        },
      );
    }

    state.epoch = snapshot.epoch;
    return this.applySnapshotToState(state, snapshot);
  }

  private applySnapshotToState(state: RepositoryState, snapshot: StatusSnapshot): StoredStatusSnapshot {
    state.generation = snapshot.generation;
    state.completeness = snapshot.completeness;
    state.identity = { ...snapshot.identity };
    state.localEntries = entriesByPath(snapshot.localEntries);
    state.remoteEntries = entriesByPath(snapshot.remoteEntries);
    state.summary = { ...snapshot.summary };
    state.timestamp = snapshot.timestamp;
    state.source = snapshot.source;
    return snapshotFromState(state);
  }

  public applyDelta(delta: StatusDelta): StoredStatusSnapshot {
    const state = this.repositories.get(delta.repositoryId);
    if (!state) {
      throw new StatusSnapshotStoreError(
        "SUBVERSIONR_STATUS_STORE_REPOSITORY_NOT_REGISTERED",
        "lifecycle",
        "error.status.storeRepositoryNotRegistered",
        { repositoryId: delta.repositoryId },
      );
    }
    if (state.epoch !== delta.epoch) {
      throw new StatusSnapshotStoreError(
        "SUBVERSIONR_STATUS_STORE_DELTA_EPOCH_MISMATCH",
        "lifecycle",
        "error.status.storeDeltaMismatch",
        {
          repositoryId: state.repositoryId,
          expected: state.epoch,
          actual: delta.epoch,
        },
      );
    }
    requireInitializedState(state);
    if (delta.generation <= state.generation) {
      throw new StatusSnapshotStoreError(
        "SUBVERSIONR_STATUS_STORE_DELTA_GENERATION_STALE",
        "lifecycle",
        "error.status.storeGenerationStale",
        {
          repositoryId: state.repositoryId,
          current: state.generation,
          actual: delta.generation,
        },
      );
    }

    const localEntries = new Map(state.localEntries);
    for (const path of delta.remove) {
      localEntries.delete(path);
    }
    for (const entry of delta.upsert) {
      localEntries.set(entry.path, cloneEntry(entry));
    }
    const remoteEntries = new Map(state.remoteEntries);
    for (const path of delta.remoteRemove) {
      remoteEntries.delete(path);
    }
    for (const entry of delta.remoteUpsert) {
      remoteEntries.set(entry.path, cloneEntry(entry));
    }
    const summary = applySummaryDelta(state.repositoryId, state.summary, delta.summaryDelta);

    state.generation = delta.generation;
    state.completeness = delta.completeness;
    state.localEntries = localEntries;
    state.remoteEntries = remoteEntries;
    state.summary = summary;
    state.timestamp = delta.timestamp;
    state.source = delta.source;
    return snapshotFromState(state);
  }

  public markStale(mark: StatusStaleMark): StoredStatusSnapshot {
    requireNonEmptyStaleField(mark.repositoryId, "repositoryId");
    requireNonEmptyStaleField(mark.reason, "reason");
    requireNonEmptyStaleField(mark.timestamp, "timestamp");
    requireNonEmptyStaleField(mark.source, "source");
    if (!Number.isSafeInteger(mark.epoch) || mark.epoch < 0) {
      throw statusStoreInputError("epoch");
    }

    const state = this.repositories.get(mark.repositoryId);
    if (!state) {
      throw new StatusSnapshotStoreError(
        "SUBVERSIONR_STATUS_STORE_REPOSITORY_NOT_REGISTERED",
        "lifecycle",
        "error.status.storeRepositoryNotRegistered",
        { repositoryId: mark.repositoryId },
      );
    }
    if (state.epoch !== mark.epoch) {
      throw new StatusSnapshotStoreError(
        "SUBVERSIONR_STATUS_STORE_STALE_EPOCH_MISMATCH",
        "lifecycle",
        "error.status.storeStaleMismatch",
        {
          repositoryId: state.repositoryId,
          expected: state.epoch,
          actual: mark.epoch,
        },
      );
    }
    requireInitializedState(state);

    state.completeness = "stale";
    state.timestamp = mark.timestamp;
    state.source = mark.source;
    return snapshotFromState(state);
  }

  public getSnapshot(repositoryId: string): StoredStatusSnapshot | undefined {
    const state = this.repositories.get(repositoryId);
    if (
      !state ||
      state.generation === undefined ||
      state.completeness === undefined ||
      !state.identity ||
      !state.summary ||
      state.timestamp === undefined ||
      state.source === undefined
    ) {
      return undefined;
    }
    return snapshotFromState(state);
  }

  public getLocalEntry(repositoryId: string, path: string): StatusEntry | undefined {
    return cloneEntry(this.repositories.get(repositoryId)?.localEntries.get(path));
  }

  public getRemoteEntry(repositoryId: string, path: string): StatusEntry | undefined {
    return cloneEntry(this.repositories.get(repositoryId)?.remoteEntries.get(path));
  }
}

function entriesByPath(entries: StatusEntry[]): Map<string, StatusEntry> {
  return new Map(entries.map((entry) => [entry.path, cloneEntry(entry)]));
}

function snapshotFromState(state: RepositoryState): StoredStatusSnapshot {
  if (
    state.generation === undefined ||
    state.completeness === undefined ||
    !state.identity ||
    !state.summary ||
    state.timestamp === undefined ||
    state.source === undefined
  ) {
    throw new StatusSnapshotStoreError(
      "SUBVERSIONR_STATUS_STORE_STATE_UNINITIALIZED",
      "lifecycle",
      "error.status.storeStateUninitialized",
      { repositoryId: state.repositoryId },
    );
  }
  return {
    repositoryId: state.repositoryId,
    epoch: state.epoch,
    generation: state.generation,
    completeness: state.completeness,
    identity: { ...state.identity },
    localEntries: Array.from(state.localEntries.values()).map(cloneStoredEntry),
    remoteEntries: Array.from(state.remoteEntries.values()).map(cloneStoredEntry),
    summary: { ...state.summary },
    timestamp: state.timestamp,
    source: state.source,
  };
}

function requireInitializedState(state: RepositoryState): asserts state is InitializedRepositoryState {
  if (
    state.generation === undefined ||
    state.completeness === undefined ||
    !state.identity ||
    !state.summary ||
    state.timestamp === undefined ||
    state.source === undefined
  ) {
    throw new StatusSnapshotStoreError(
      "SUBVERSIONR_STATUS_STORE_STATE_UNINITIALIZED",
      "lifecycle",
      "error.status.storeStateUninitialized",
      { repositoryId: state.repositoryId },
    );
  }
}

function applySummaryDelta(
  repositoryId: string,
  summary: StatusSummary,
  delta: StatusSummaryDelta,
): StatusSummary {
  return {
    localChanges: applySummaryValue(repositoryId, "localChanges", summary.localChanges, delta.localChanges),
    remoteChanges: applySummaryValue(repositoryId, "remoteChanges", summary.remoteChanges, delta.remoteChanges),
    conflicts: applySummaryValue(repositoryId, "conflicts", summary.conflicts, delta.conflicts),
    unversioned: applySummaryValue(repositoryId, "unversioned", summary.unversioned, delta.unversioned),
  };
}

function applySummaryValue(repositoryId: string, field: string, current: number, delta: number): number {
  const next = current + delta;
  if (!Number.isSafeInteger(next) || next < 0) {
    throw new StatusSnapshotStoreError(
      "SUBVERSIONR_STATUS_STORE_DELTA_SUMMARY_INVALID",
      "lifecycle",
      "error.status.storeDeltaSummaryInvalid",
      { repositoryId, field, current, delta },
    );
  }
  return next;
}

function cloneStoredEntry(entry: StatusEntry): StatusEntry {
  return cloneEntry(entry);
}

function cloneEntry(entry: StatusEntry): StatusEntry;
function cloneEntry(entry: StatusEntry | undefined): StatusEntry | undefined;
function cloneEntry(entry: StatusEntry | undefined): StatusEntry | undefined {
  return entry ? { ...entry, lock: entry.lock ? { ...entry.lock } : null } : undefined;
}

function isNonEmptyString(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0;
}

function statusStoreInputError(field: string): StatusSnapshotStoreError {
  return new StatusSnapshotStoreError(
    "SUBVERSIONR_STATUS_STORE_INPUT_INVALID",
    "input",
    "error.status.storeInputInvalid",
    { field },
  );
}

function requireNonEmptyStaleField(value: string, field: string): void {
  if (!isNonEmptyString(value)) {
    throw statusStoreInputError(field);
  }
}
