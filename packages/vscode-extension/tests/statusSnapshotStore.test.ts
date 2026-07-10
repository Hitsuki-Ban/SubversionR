import { describe, expect, it } from "vitest";
import { StatusSnapshotStore, StatusSnapshotStoreError } from "../src/status/statusSnapshotStore";
import type { StatusSnapshot } from "../src/status/statusSnapshotRpcClient";
import type { StatusDelta } from "../src/status/statusRefreshRpcClient";

describe("StatusSnapshotStore", () => {
  it("applies a full snapshot replacement for a registered repository", () => {
    const store = new StatusSnapshotStore();
    store.registerRepository({ repositoryId: "repo-uuid:C:/wc", epoch: 7 });
    store.applySnapshot(
      snapshotResponse({
        generation: 11,
        localPaths: ["src/a.c", "src/b.c"],
      }),
    );

    const view = store.applySnapshot(
      snapshotResponse({
        generation: 12,
        localPaths: ["src/b.c"],
        completeness: "partial",
      }),
    );

    expect(view).toMatchObject({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      generation: 12,
      completeness: "partial",
      identity: {
        repositoryUuid: "repo-uuid",
      },
      summary: {
        localChanges: 1,
        remoteChanges: 0,
      },
      timestamp: "2026-06-22T00:00:00Z",
      source: "libsvn-local",
    });
    expect(store.getLocalEntry("repo-uuid:C:/wc", "src/a.c")).toBeUndefined();
    expect(store.getLocalEntry("repo-uuid:C:/wc", "src/b.c")).toMatchObject({
      path: "src/b.c",
      generation: 12,
    });
    expect(store.getSnapshot("repo-uuid:C:/wc")?.localEntries.map((entry) => entry.path)).toEqual(["src/b.c"]);
  });

  it("keeps local and remote status dimensions independent for the same path", () => {
    const store = new StatusSnapshotStore();
    store.registerRepository({ repositoryId: "repo-uuid:C:/wc", epoch: 7 });

    store.applySnapshot(
      snapshotResponse({
        localPaths: ["src/main.c"],
        remotePaths: ["src/main.c"],
      }),
    );

    expect(store.getLocalEntry("repo-uuid:C:/wc", "src/main.c")).toMatchObject({
      path: "src/main.c",
      localStatus: "modified",
      remoteStatus: "notChecked",
    });
    expect(store.getRemoteEntry("repo-uuid:C:/wc", "src/main.c")).toMatchObject({
      path: "src/main.c",
      localStatus: "normal",
      remoteStatus: "modified",
    });
  });

  it("preserves stale completeness without presenting the snapshot as complete", () => {
    const store = new StatusSnapshotStore();
    store.registerRepository({ repositoryId: "repo-uuid:C:/wc", epoch: 7 });

    const view = store.applySnapshot(snapshotResponse({ completeness: "stale" }));

    expect(view.completeness).toBe("stale");
    expect(store.getSnapshot("repo-uuid:C:/wc")?.completeness).toBe("stale");
  });

  it("marks an initialized repository stale without changing generation or entries", () => {
    const store = new StatusSnapshotStore();
    store.registerRepository({ repositoryId: "repo-uuid:C:/wc", epoch: 7 });
    store.applySnapshot(
      snapshotResponse({
        generation: 12,
        localPaths: ["src/current.c"],
        remotePaths: ["src/incoming.c"],
      }),
    );

    const view = store.markStale({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      reason: "backendRestart",
      timestamp: "2026-06-22T00:03:00Z",
      source: "daemon-status-stale",
    });

    expect(view).toMatchObject({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      generation: 12,
      completeness: "stale",
      timestamp: "2026-06-22T00:03:00Z",
      source: "daemon-status-stale",
    });
    expect(view.localEntries.map((entry) => entry.path)).toEqual(["src/current.c"]);
    expect(view.remoteEntries.map((entry) => entry.path)).toEqual(["src/incoming.c"]);
  });

  it("rejects stale marks before an initial snapshot is loaded", () => {
    const store = new StatusSnapshotStore();
    store.registerRepository({ repositoryId: "repo-uuid:C:/wc", epoch: 7 });

    expect(captureStoreError(() =>
      store.markStale({
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        reason: "backendRestart",
        timestamp: "2026-06-22T00:03:00Z",
        source: "daemon-status-stale",
      }),
    )).toMatchObject({
      code: "SUBVERSIONR_STATUS_STORE_STATE_UNINITIALIZED",
      category: "lifecycle",
      messageKey: "error.status.storeStateUninitialized",
      safeArgs: { repositoryId: "repo-uuid:C:/wc" },
    });
  });

  it("rejects stale marks with a mismatched epoch", () => {
    const store = new StatusSnapshotStore();
    store.registerRepository({ repositoryId: "repo-uuid:C:/wc", epoch: 7 });
    store.applySnapshot(snapshotResponse({ generation: 12 }));

    expect(captureStoreError(() =>
      store.markStale({
        repositoryId: "repo-uuid:C:/wc",
        epoch: 8,
        reason: "backendRestart",
        timestamp: "2026-06-22T00:03:00Z",
        source: "daemon-status-stale",
      }),
    )).toMatchObject({
      code: "SUBVERSIONR_STATUS_STORE_STALE_EPOCH_MISMATCH",
      category: "lifecycle",
      messageKey: "error.status.storeStaleMismatch",
      safeArgs: { repositoryId: "repo-uuid:C:/wc", expected: 7, actual: 8 },
    });
    expect(store.getSnapshot("repo-uuid:C:/wc")?.completeness).toBe("complete");
  });

  it("rejects snapshot with a mismatched epoch", () => {
    const store = new StatusSnapshotStore();
    store.registerRepository({ repositoryId: "repo-uuid:C:/wc", epoch: 7 });

    expect(captureStoreError(() => store.applySnapshot(snapshotResponse({ epoch: 8 })))).toMatchObject({
      category: "lifecycle",
      messageKey: "error.status.storeSnapshotMismatch",
      code: "SUBVERSIONR_STATUS_STORE_SNAPSHOT_EPOCH_MISMATCH",
      safeArgs: { repositoryId: "repo-uuid:C:/wc", expected: 7, actual: 8 },
    });
    expect(store.getSnapshot("repo-uuid:C:/wc")).toBeUndefined();
  });

  it("rejects stale generations without replacing newer state", () => {
    const store = new StatusSnapshotStore();
    store.registerRepository({ repositoryId: "repo-uuid:C:/wc", epoch: 7 });
    store.applySnapshot(snapshotResponse({ generation: 12, localPaths: ["src/new.c"] }));

    expect(captureStoreError(() => store.applySnapshot(snapshotResponse({ generation: 11, localPaths: ["src/old.c"] })))).toMatchObject({
      code: "SUBVERSIONR_STATUS_STORE_SNAPSHOT_GENERATION_STALE",
      category: "lifecycle",
      messageKey: "error.status.storeGenerationStale",
      safeArgs: { repositoryId: "repo-uuid:C:/wc", current: 12, actual: 11 },
    });
    expect(store.getSnapshot("repo-uuid:C:/wc")?.localEntries.map((entry) => entry.path)).toEqual(["src/new.c"]);
  });

  it("allows equal-generation full snapshot replay", () => {
    const store = new StatusSnapshotStore();
    store.registerRepository({ repositoryId: "repo-uuid:C:/wc", epoch: 7 });
    store.applySnapshot(snapshotResponse({ generation: 12, localPaths: ["src/a.c"] }));

    store.applySnapshot(snapshotResponse({ generation: 12, localPaths: ["src/b.c"] }));

    expect(store.getSnapshot("repo-uuid:C:/wc")?.localEntries.map((entry) => entry.path)).toEqual(["src/b.c"]);
  });

  it("applies refresh deltas by upserting and removing explicit local paths", () => {
    const store = new StatusSnapshotStore();
    store.registerRepository({ repositoryId: "repo-uuid:C:/wc", epoch: 7 });
    store.applySnapshot(
      snapshotResponse({
        generation: 11,
        localPaths: ["src/old.c", "src/unchanged.c"],
        remotePaths: ["src/old.c"],
      }),
    );

    const view = store.applyDelta(
      deltaResponse({
        generation: 12,
        upsertPaths: ["src/new.c"],
        remove: ["src/old.c"],
        summaryDelta: {
          localChanges: 0,
          remoteChanges: 0,
          conflicts: 0,
          unversioned: 0,
        },
      }),
    );

    expect(view).toMatchObject({
      generation: 12,
      completeness: "partial",
      summary: {
        localChanges: 2,
        remoteChanges: 1,
      },
      timestamp: "2026-06-22T00:02:00Z",
      source: "libsvn-local",
    });
    expect(store.getLocalEntry("repo-uuid:C:/wc", "src/old.c")).toBeUndefined();
    expect(store.getLocalEntry("repo-uuid:C:/wc", "src/new.c")).toMatchObject({
      path: "src/new.c",
      generation: 12,
    });
    expect(store.getLocalEntry("repo-uuid:C:/wc", "src/unchanged.c")).toMatchObject({
      path: "src/unchanged.c",
      generation: 11,
    });
    expect(store.getRemoteEntry("repo-uuid:C:/wc", "src/old.c")).toMatchObject({
      path: "src/old.c",
      remoteStatus: "modified",
    });
  });

  it("rejects refresh deltas before an initial snapshot is loaded", () => {
    const store = new StatusSnapshotStore();
    store.registerRepository({ repositoryId: "repo-uuid:C:/wc", epoch: 7 });

    expect(captureStoreError(() => store.applyDelta(deltaResponse()))).toMatchObject({
      code: "SUBVERSIONR_STATUS_STORE_STATE_UNINITIALIZED",
      category: "lifecycle",
      messageKey: "error.status.storeStateUninitialized",
      safeArgs: { repositoryId: "repo-uuid:C:/wc" },
    });
  });

  it("rejects refresh deltas with stale generations without replacing newer state", () => {
    const store = new StatusSnapshotStore();
    store.registerRepository({ repositoryId: "repo-uuid:C:/wc", epoch: 7 });
    store.applySnapshot(snapshotResponse({ generation: 12, localPaths: ["src/current.c"] }));

    expect(captureStoreError(() => store.applyDelta(deltaResponse({ generation: 11, upsertPaths: ["src/old.c"] })))).toMatchObject({
      code: "SUBVERSIONR_STATUS_STORE_DELTA_GENERATION_STALE",
      category: "lifecycle",
      messageKey: "error.status.storeGenerationStale",
      safeArgs: { repositoryId: "repo-uuid:C:/wc", current: 12, actual: 11 },
    });
    expect(store.getSnapshot("repo-uuid:C:/wc")?.localEntries.map((entry) => entry.path)).toEqual(["src/current.c"]);
  });

  it("rejects refresh deltas with equal generations because summary deltas are additive", () => {
    const store = new StatusSnapshotStore();
    store.registerRepository({ repositoryId: "repo-uuid:C:/wc", epoch: 7 });
    store.applySnapshot(snapshotResponse({ generation: 12, localPaths: ["src/current.c"] }));

    expect(captureStoreError(() => store.applyDelta(deltaResponse({ generation: 12, upsertPaths: ["src/replayed.c"] })))).toMatchObject({
      code: "SUBVERSIONR_STATUS_STORE_DELTA_GENERATION_STALE",
      category: "lifecycle",
      messageKey: "error.status.storeGenerationStale",
      safeArgs: { repositoryId: "repo-uuid:C:/wc", current: 12, actual: 12 },
    });
    expect(store.getSnapshot("repo-uuid:C:/wc")?.localEntries.map((entry) => entry.path)).toEqual(["src/current.c"]);
  });

  it("applies signed summary deltas without touching remote entries", () => {
    const store = new StatusSnapshotStore();
    store.registerRepository({ repositoryId: "repo-uuid:C:/wc", epoch: 7 });
    store.applySnapshot(
      snapshotResponse({
        generation: 11,
        localPaths: ["src/old.c", "src/unchanged.c"],
        remotePaths: ["src/old.c"],
      }),
    );

    const view = store.applyDelta(
      deltaResponse({
        generation: 12,
        upsertPaths: [],
        remove: ["src/old.c"],
        summaryDelta: {
          localChanges: -1,
          remoteChanges: 0,
          conflicts: 0,
          unversioned: 0,
        },
      }),
    );

    expect(view.summary.localChanges).toBe(1);
    expect(view.summary.remoteChanges).toBe(1);
    expect(store.getLocalEntry("repo-uuid:C:/wc", "src/old.c")).toBeUndefined();
    expect(store.getRemoteEntry("repo-uuid:C:/wc", "src/old.c")).toMatchObject({
      path: "src/old.c",
      remoteStatus: "modified",
    });
  });

  it("applies remote refresh deltas without touching local entries", () => {
    const store = new StatusSnapshotStore();
    store.registerRepository({ repositoryId: "repo-uuid:C:/wc", epoch: 7 });
    store.applySnapshot(
      snapshotResponse({
        generation: 11,
        localPaths: ["src/local.c"],
        remotePaths: ["src/old-incoming.c"],
      }),
    );

    const view = store.applyDelta(
      deltaResponse({
        generation: 12,
        upsertPaths: [],
        remoteUpsertPaths: ["src/new-incoming.c", "src/another-incoming.c"],
        remoteRemove: ["src/old-incoming.c"],
        summaryDelta: {
          localChanges: 0,
          remoteChanges: 1,
          conflicts: 0,
          unversioned: 0,
        },
      }),
    );

    expect(view.summary.remoteChanges).toBe(2);
    expect(store.getLocalEntry("repo-uuid:C:/wc", "src/local.c")).toMatchObject({
      path: "src/local.c",
    });
    expect(store.getRemoteEntry("repo-uuid:C:/wc", "src/old-incoming.c")).toBeUndefined();
    expect(store.getRemoteEntry("repo-uuid:C:/wc", "src/new-incoming.c")).toMatchObject({
      remoteStatus: "modified",
      generation: 12,
    });
    expect(view.remoteEntries.map((entry) => entry.path)).toEqual([
      "src/new-incoming.c",
      "src/another-incoming.c",
    ]);
  });

  it("rejects summary deltas that would make counts negative without mutating state", () => {
    const store = new StatusSnapshotStore();
    store.registerRepository({ repositoryId: "repo-uuid:C:/wc", epoch: 7 });
    store.applySnapshot(snapshotResponse({ generation: 11, localPaths: ["src/current.c"] }));

    expect(
      captureStoreError(() =>
        store.applyDelta(
          deltaResponse({
            generation: 12,
            upsertPaths: ["src/new.c"],
            summaryDelta: {
              localChanges: -2,
              remoteChanges: 0,
              conflicts: 0,
              unversioned: 0,
            },
          }),
        ),
      ),
    ).toMatchObject({
      code: "SUBVERSIONR_STATUS_STORE_DELTA_SUMMARY_INVALID",
      category: "lifecycle",
      messageKey: "error.status.storeDeltaSummaryInvalid",
      safeArgs: {
        repositoryId: "repo-uuid:C:/wc",
        field: "localChanges",
        current: 1,
        delta: -2,
      },
    });
    expect(store.getSnapshot("repo-uuid:C:/wc")).toMatchObject({
      generation: 11,
      summary: { localChanges: 1 },
    });
    expect(store.getLocalEntry("repo-uuid:C:/wc", "src/new.c")).toBeUndefined();
  });

  it("rejects remote summary deltas that would make counts negative without mutating remote state", () => {
    const store = new StatusSnapshotStore();
    store.registerRepository({ repositoryId: "repo-uuid:C:/wc", epoch: 7 });
    store.applySnapshot(snapshotResponse({ generation: 11, localPaths: [], remotePaths: ["src/current-incoming.c"] }));

    expect(
      captureStoreError(() =>
        store.applyDelta(
          deltaResponse({
            generation: 12,
            upsertPaths: [],
            remoteUpsertPaths: ["src/new-incoming.c"],
            remoteRemove: ["src/current-incoming.c"],
            summaryDelta: {
              localChanges: 0,
              remoteChanges: -2,
              conflicts: 0,
              unversioned: 0,
            },
          }),
        ),
      ),
    ).toMatchObject({
      code: "SUBVERSIONR_STATUS_STORE_DELTA_SUMMARY_INVALID",
      category: "lifecycle",
      messageKey: "error.status.storeDeltaSummaryInvalid",
      safeArgs: {
        repositoryId: "repo-uuid:C:/wc",
        field: "remoteChanges",
        current: 1,
        delta: -2,
      },
    });
    expect(store.getRemoteEntry("repo-uuid:C:/wc", "src/current-incoming.c")).toMatchObject({
      path: "src/current-incoming.c",
    });
    expect(store.getRemoteEntry("repo-uuid:C:/wc", "src/new-incoming.c")).toBeUndefined();
  });

  it("rejects summary deltas that would overflow safe integers without mutating state", () => {
    const store = new StatusSnapshotStore();
    store.registerRepository({ repositoryId: "repo-uuid:C:/wc", epoch: 7 });
    const snapshot = snapshotResponse({ generation: 11, localPaths: ["src/current.c"] });
    snapshot.summary.localChanges = Number.MAX_SAFE_INTEGER;
    store.applySnapshot(snapshot);

    expect(
      captureStoreError(() =>
        store.applyDelta(
          deltaResponse({
            generation: 12,
            upsertPaths: ["src/new.c"],
            summaryDelta: {
              localChanges: 1,
              remoteChanges: 0,
              conflicts: 0,
              unversioned: 0,
            },
          }),
        ),
      ),
    ).toMatchObject({
      code: "SUBVERSIONR_STATUS_STORE_DELTA_SUMMARY_INVALID",
      category: "lifecycle",
      messageKey: "error.status.storeDeltaSummaryInvalid",
      safeArgs: {
        repositoryId: "repo-uuid:C:/wc",
        field: "localChanges",
        current: Number.MAX_SAFE_INTEGER,
        delta: 1,
      },
    });
    expect(store.getSnapshot("repo-uuid:C:/wc")).toMatchObject({
      generation: 11,
      summary: { localChanges: Number.MAX_SAFE_INTEGER },
    });
    expect(store.getLocalEntry("repo-uuid:C:/wc", "src/new.c")).toBeUndefined();
  });

  it("rejects refresh deltas with mismatched epochs", () => {
    const store = new StatusSnapshotStore();
    store.registerRepository({ repositoryId: "repo-uuid:C:/wc", epoch: 7 });
    store.applySnapshot(snapshotResponse({ generation: 11 }));

    expect(captureStoreError(() => store.applyDelta(deltaResponse({ epoch: 8 })))).toMatchObject({
      code: "SUBVERSIONR_STATUS_STORE_DELTA_EPOCH_MISMATCH",
      category: "lifecycle",
      messageKey: "error.status.storeDeltaMismatch",
      safeArgs: { repositoryId: "repo-uuid:C:/wc", expected: 7, actual: 8 },
    });
  });

  it("requires repositories to be registered before applying snapshots", () => {
    const store = new StatusSnapshotStore();

    expect(captureStoreError(() => store.applySnapshot(snapshotResponse()))).toMatchObject({
      code: "SUBVERSIONR_STATUS_STORE_REPOSITORY_NOT_REGISTERED",
      category: "lifecycle",
      messageKey: "error.status.storeRepositoryNotRegistered",
      safeArgs: { repositoryId: "repo-uuid:C:/wc" },
    });
  });

  it("fails fast on duplicate repository registration", () => {
    const store = new StatusSnapshotStore();
    store.registerRepository({ repositoryId: "repo-uuid:C:/wc", epoch: 7 });

    expect(captureStoreError(() => store.registerRepository({ repositoryId: "repo-uuid:C:/wc", epoch: 7 }))).toMatchObject({
      code: "SUBVERSIONR_STATUS_STORE_REPOSITORY_ALREADY_REGISTERED",
      category: "lifecycle",
      messageKey: "error.status.storeRepositoryAlreadyRegistered",
      safeArgs: { repositoryId: "repo-uuid:C:/wc" },
    });
  });

  it("removes repository state on unregister", () => {
    const store = new StatusSnapshotStore();
    store.registerRepository({ repositoryId: "repo-uuid:C:/wc", epoch: 7 });
    store.applySnapshot(snapshotResponse());

    store.unregisterRepository("repo-uuid:C:/wc");

    expect(store.getSnapshot("repo-uuid:C:/wc")).toBeUndefined();
    expect(store.getLocalEntry("repo-uuid:C:/wc", "src/main.c")).toBeUndefined();
  });

  it("returns immutable copies of stored snapshots", () => {
    const store = new StatusSnapshotStore();
    store.registerRepository({ repositoryId: "repo-uuid:C:/wc", epoch: 7 });
    const view = store.applySnapshot(snapshotResponse());
    const localEntry = store.getLocalEntry("repo-uuid:C:/wc", "src/main.c");

    view.localEntries[0].path = "mutated.c";
    view.identity.repositoryUuid = "mutated-repo";
    view.summary.localChanges = 99;
    if (!localEntry) {
      throw new Error("Expected local entry");
    }
    localEntry.path = "entry-mutated.c";

    expect(store.getLocalEntry("repo-uuid:C:/wc", "src/main.c")?.path).toBe("src/main.c");
    expect(store.getSnapshot("repo-uuid:C:/wc")).toMatchObject({
      identity: { repositoryUuid: "repo-uuid" },
      summary: { localChanges: 1 },
    });
  });
});

interface SnapshotOptions {
  repositoryId?: string;
  epoch?: number;
  generation?: number;
  completeness?: StatusSnapshot["completeness"];
  localPaths?: string[];
  remotePaths?: string[];
}

interface DeltaOptions {
  repositoryId?: string;
  epoch?: number;
  generation?: number;
  completeness?: StatusDelta["completeness"];
  upsertPaths?: string[];
  remove?: string[];
  remoteUpsertPaths?: string[];
  remoteRemove?: string[];
  summaryDelta?: StatusDelta["summaryDelta"];
}

function deltaResponse(options: DeltaOptions = {}): StatusDelta {
  const generation = options.generation ?? 12;
  const upsertPaths = options.upsertPaths ?? ["src/main.c"];
  const remoteUpsertPaths = options.remoteUpsertPaths ?? [];
  return {
    repositoryId: options.repositoryId ?? "repo-uuid:C:/wc",
    epoch: options.epoch ?? 7,
    generation,
    coverage: [{ path: "src", depth: "files", generation, reason: "directoryChanged" }],
    upsert: upsertPaths.map((path) => ({
      path,
      kind: "file",
      nodeStatus: "modified",
      textStatus: "modified",
      propertyStatus: "normal",
      localStatus: "modified",
      remoteStatus: "notChecked",
      revision: 7,
      changedRevision: 7,
      changedAuthor: "alice",
      changedDate: "2026-06-22T00:02:00Z",
      changelist: null,
      lock: null,
      needsLock: false,
      copy: null,
      move: null,
      switched: false,
      depth: "infinity",
      conflict: null,
      external: false,
      generation,
    })),
    remove: options.remove ?? [],
    remoteUpsert: remoteUpsertPaths.map((path) => ({
      path,
      kind: "file",
      nodeStatus: "normal",
      textStatus: "normal",
      propertyStatus: "normal",
      localStatus: "normal",
      remoteStatus: "modified",
      revision: 7,
      changedRevision: 8,
      changedAuthor: "bob",
      changedDate: "2026-06-22T00:02:00Z",
      changelist: null,
      lock: null,
      needsLock: false,
      copy: null,
      move: null,
      switched: false,
      depth: "infinity",
      conflict: null,
      external: false,
      generation,
    })),
    remoteRemove: options.remoteRemove ?? [],
    summaryDelta: options.summaryDelta ?? {
      localChanges: upsertPaths.length,
      remoteChanges: remoteUpsertPaths.length,
      conflicts: 0,
      unversioned: 0,
    },
    completeness: options.completeness ?? "partial",
    timestamp: "2026-06-22T00:02:00Z",
    source: "libsvn-local",
  };
}

function snapshotResponse(options: SnapshotOptions = {}): StatusSnapshot {
  const generation = options.generation ?? 11;
  const localPaths = options.localPaths ?? ["src/main.c"];
  const remotePaths = options.remotePaths ?? [];
  return {
    repositoryId: options.repositoryId ?? "repo-uuid:C:/wc",
    epoch: options.epoch ?? 7,
    generation,
    completeness: options.completeness ?? "complete",
    identity: {
      repositoryUuid: "repo-uuid",
      repositoryRootUrl: "file:///C:/repo",
      workingCopyRoot: "C:/wc",
      workspaceScopeRoot: "C:/workspace",
      format: 31,
    },
    localEntries: localPaths.map((path) => ({
      path,
      kind: "file",
      nodeStatus: "modified",
      textStatus: "modified",
      propertyStatus: "normal",
      localStatus: "modified",
      remoteStatus: "notChecked",
      revision: 7,
      changedRevision: 7,
      changedAuthor: "alice",
      changedDate: "2026-06-22T00:00:00Z",
      changelist: null,
      lock: null,
      needsLock: false,
      copy: null,
      move: null,
      switched: false,
      depth: "infinity",
      conflict: null,
      external: false,
      generation,
    })),
    remoteEntries: remotePaths.map((path) => ({
      path,
      kind: "file",
      nodeStatus: "normal",
      textStatus: "normal",
      propertyStatus: "normal",
      localStatus: "normal",
      remoteStatus: "modified",
      revision: 7,
      changedRevision: 8,
      changedAuthor: "bob",
      changedDate: "2026-06-22T00:01:00Z",
      changelist: null,
      lock: null,
      needsLock: false,
      copy: null,
      move: null,
      switched: false,
      depth: "infinity",
      conflict: null,
      external: false,
      generation,
    })),
    summary: {
      localChanges: localPaths.length,
      remoteChanges: remotePaths.length,
      conflicts: 0,
      unversioned: 0,
    },
    timestamp: "2026-06-22T00:00:00Z",
    source: "libsvn-local",
  };
}

function captureStoreError(action: () => unknown): StatusSnapshotStoreError {
  try {
    action();
  } catch (error) {
    expect(error).toBeInstanceOf(StatusSnapshotStoreError);
    return error as StatusSnapshotStoreError;
  }
  throw new Error("Expected StatusSnapshotStoreError");
}
