import { describe, expect, it, vi } from "vitest";
import { createStatusNotificationHandler } from "../src/status/statusStaleNotificationHandler";
import type { SourceControlProjectionService } from "../src/scm/sourceControlProjectionService";
import type { StatusDelta } from "../src/status/statusRefreshRpcClient";
import type { StatusEntry } from "../src/status/statusSnapshotRpcClient";
import type { StatusSnapshotStore, StoredStatusSnapshot } from "../src/status/statusSnapshotStore";
import { WatcherOverflowDiagnostics } from "../src/status/watcherOverflowDiagnostics";

describe("createStatusNotificationHandler", () => {
  it("marks canonical status and Source Control projection stale for status/stale notifications", () => {
    const statusSnapshotStore = fakeStatusSnapshotStore();
    const sourceControlProjection = fakeSourceControlProjection();
    const handleNotification = createStatusNotificationHandler({
      statusSnapshotStore,
      sourceControlProjection,
      watcherOverflowDiagnostics: new WatcherOverflowDiagnostics(),
    });

    handleNotification("status/stale", {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      reason: "backendRestart",
      timestamp: "2026-06-22T00:03:00Z",
      source: "daemon-status-stale",
    });

    const mark = {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      reason: "backendRestart",
      timestamp: "2026-06-22T00:03:00Z",
      source: "daemon-status-stale",
    };
    expect(statusSnapshotStore.markStale).toHaveBeenCalledWith(mark);
    expect(sourceControlProjection.markStale).toHaveBeenCalledWith(mark);
  });

  it("recovers Source Control projection from the canonical stale snapshot when status/stale publishing fails", () => {
    const statusSnapshotStore = fakeStatusSnapshotStore();
    const sourceControlProjection = fakeSourceControlProjection();
    sourceControlProjection.markStale.mockImplementationOnce(() => {
      throw new Error("projection failed");
    });
    const handleNotification = createStatusNotificationHandler({
      statusSnapshotStore,
      sourceControlProjection,
      watcherOverflowDiagnostics: new WatcherOverflowDiagnostics(),
    });
    const mark = {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      reason: "backendRestart",
      timestamp: "2026-06-22T00:03:00Z",
      source: "daemon-status-stale",
    };

    expect(() => handleNotification("status/stale", mark)).toThrow("projection failed");

    expect(statusSnapshotStore.markStale).toHaveBeenCalledWith(mark);
    expect(sourceControlProjection.markStale).toHaveBeenCalledWith(mark);
    expect(sourceControlProjection.replaceSnapshot).toHaveBeenCalledTimes(1);
    expect(sourceControlProjection.replaceSnapshot).toHaveBeenCalledWith(
      statusSnapshotStore.getSnapshot("repo-uuid:C:/wc"),
    );
  });

  it("marks status stale and records diagnostics for native watcher overflow notifications", () => {
    const statusSnapshotStore = fakeStatusSnapshotStore();
    const sourceControlProjection = fakeSourceControlProjection();
    const watcherOverflowDiagnostics = new WatcherOverflowDiagnostics();
    const handleNotification = createStatusNotificationHandler({
      statusSnapshotStore,
      sourceControlProjection,
      watcherOverflowDiagnostics,
    });

    handleNotification("watcher/overflow", {
      repositoryId: "repo-uuid:C:/Users/Alice/private-wc",
      epoch: 7,
      timestamp: "2026-06-25T00:00:00Z",
    });

    const mark = {
      repositoryId: "repo-uuid:C:/Users/Alice/private-wc",
      epoch: 7,
      reason: "watcherOverflow",
      timestamp: "2026-06-25T00:00:00Z",
      source: "native-watcher",
    };
    expect(statusSnapshotStore.markStale).toHaveBeenCalledWith(mark);
    expect(sourceControlProjection.markStale).toHaveBeenCalledWith(mark);
    const diagnostics = watcherOverflowDiagnostics.diagnosticsSnapshot();
    expect(diagnostics.overflowCount).toBe(1);
    expect(diagnostics.lastOverflow).toEqual({
      repositoryHash: expect.stringMatching(/^[0-9a-f]{16}$/u),
      epoch: 7,
      timestamp: "2026-06-25T00:00:00Z",
      source: "native-watcher",
    });
    expect(JSON.stringify(diagnostics)).not.toContain("Alice");
    expect(JSON.stringify(diagnostics)).not.toContain("private-wc");
    expect(JSON.stringify(diagnostics)).not.toContain("repo-uuid");
  });

  it("rejects invalid native watcher overflow notifications before changing status state", () => {
    const statusSnapshotStore = fakeStatusSnapshotStore();
    const sourceControlProjection = fakeSourceControlProjection();
    const watcherOverflowDiagnostics = new WatcherOverflowDiagnostics();
    const handleNotification = createStatusNotificationHandler({
      statusSnapshotStore,
      sourceControlProjection,
      watcherOverflowDiagnostics,
    });

    expect(() =>
      handleNotification("watcher/overflow", {
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        timestamp: "2026-06-25T00:00:00Z",
        source: "native-watcher",
      }),
    ).toThrow("SUBVERSIONR_WATCHER_OVERFLOW_NOTIFICATION_INVALID");
    expect(statusSnapshotStore.markStale).not.toHaveBeenCalled();
    expect(sourceControlProjection.markStale).not.toHaveBeenCalled();
    expect(watcherOverflowDiagnostics.diagnosticsSnapshot().overflowCount).toBe(0);
  });

  it("rejects invalid status/stale notification params before changing status state", () => {
    const statusSnapshotStore = fakeStatusSnapshotStore();
    const sourceControlProjection = fakeSourceControlProjection();
    const handleNotification = createStatusNotificationHandler({
      statusSnapshotStore,
      sourceControlProjection,
      watcherOverflowDiagnostics: new WatcherOverflowDiagnostics(),
    });

    expect(() =>
      handleNotification("status/stale", {
        repositoryId: "repo-uuid:C:/wc",
        epoch: -1,
        reason: "backendRestart",
        timestamp: "2026-06-22T00:03:00Z",
        source: "daemon-status-stale",
      }),
    ).toThrow("SUBVERSIONR_STATUS_STALE_NOTIFICATION_INVALID");
    expect(statusSnapshotStore.markStale).not.toHaveBeenCalled();
    expect(sourceControlProjection.markStale).not.toHaveBeenCalled();
  });

  it("rejects extra status/stale notification fields before changing status state", () => {
    const statusSnapshotStore = fakeStatusSnapshotStore();
    const sourceControlProjection = fakeSourceControlProjection();
    const handleNotification = createStatusNotificationHandler({
      statusSnapshotStore,
      sourceControlProjection,
      watcherOverflowDiagnostics: new WatcherOverflowDiagnostics(),
    });

    expect(() =>
      handleNotification("status/stale", {
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        reason: "backendRestart",
        timestamp: "2026-06-22T00:03:00Z",
        source: "daemon-status-stale",
        typo: true,
      }),
    ).toThrow("SUBVERSIONR_STATUS_STALE_NOTIFICATION_INVALID");
    expect(statusSnapshotStore.markStale).not.toHaveBeenCalled();
    expect(sourceControlProjection.markStale).not.toHaveBeenCalled();
  });

  it("rejects status/stale notifications before changing state when SCM projection state is unavailable", () => {
    const statusSnapshotStore = fakeStatusSnapshotStore();
    const sourceControlProjection = fakeSourceControlProjection({ projection: undefined });
    const handleNotification = createStatusNotificationHandler({
      statusSnapshotStore,
      sourceControlProjection,
      watcherOverflowDiagnostics: new WatcherOverflowDiagnostics(),
    });

    expect(() =>
      handleNotification("status/stale", {
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        reason: "backendRestart",
        timestamp: "2026-06-22T00:03:00Z",
        source: "daemon-status-stale",
      }),
    ).toThrow("SUBVERSIONR_STATUS_STALE_NOTIFICATION_STATE_UNAVAILABLE");
    expect(statusSnapshotStore.markStale).not.toHaveBeenCalled();
    expect(sourceControlProjection.markStale).not.toHaveBeenCalled();
  });

  it("applies canonical status and Source Control projection deltas for status/delta notifications", () => {
    const statusSnapshotStore = fakeStatusSnapshotStore();
    const sourceControlProjection = fakeSourceControlProjection();
    const handleNotification = createStatusNotificationHandler({
      statusSnapshotStore,
      sourceControlProjection,
      watcherOverflowDiagnostics: new WatcherOverflowDiagnostics(),
    });
    const delta = deltaResponse();

    handleNotification("status/delta", delta);

    expect(statusSnapshotStore.applyDelta).toHaveBeenCalledWith(delta);
    expect(sourceControlProjection.applyDelta).toHaveBeenCalledWith(delta);
  });

  it("recovers Source Control projection from the canonical status snapshot when status/delta publishing fails", () => {
    const statusSnapshotStore = fakeStatusSnapshotStore();
    const sourceControlProjection = fakeSourceControlProjection();
    sourceControlProjection.applyDelta.mockImplementationOnce(() => {
      throw new Error("projection failed");
    });
    const handleNotification = createStatusNotificationHandler({
      statusSnapshotStore,
      sourceControlProjection,
      watcherOverflowDiagnostics: new WatcherOverflowDiagnostics(),
    });
    const delta = deltaResponse();

    expect(() => handleNotification("status/delta", delta)).toThrow("projection failed");

    expect(statusSnapshotStore.applyDelta).toHaveBeenCalledWith(delta);
    expect(sourceControlProjection.applyDelta).toHaveBeenCalledWith(delta);
    expect(sourceControlProjection.replaceSnapshot).toHaveBeenCalledTimes(1);
    expect(sourceControlProjection.replaceSnapshot).toHaveBeenCalledWith(
      statusSnapshotStore.getSnapshot("repo-uuid:C:/wc"),
    );
  });

  it("rejects invalid status/delta notification params before changing status state", () => {
    const statusSnapshotStore = fakeStatusSnapshotStore();
    const sourceControlProjection = fakeSourceControlProjection();
    const handleNotification = createStatusNotificationHandler({
      statusSnapshotStore,
      sourceControlProjection,
      watcherOverflowDiagnostics: new WatcherOverflowDiagnostics(),
    });
    const delta = deltaResponse();
    (delta as unknown as Record<string, unknown>).extra = true;

    expect(() => handleNotification("status/delta", delta)).toThrow("SUBVERSIONR_STATUS_REFRESH_RESPONSE_INVALID");
    expect(statusSnapshotStore.applyDelta).not.toHaveBeenCalled();
    expect(sourceControlProjection.applyDelta).not.toHaveBeenCalled();
  });

  it("rejects status/delta notifications before changing state when SCM projection state is unavailable", () => {
    const statusSnapshotStore = fakeStatusSnapshotStore();
    const sourceControlProjection = fakeSourceControlProjection({ projection: undefined });
    const handleNotification = createStatusNotificationHandler({
      statusSnapshotStore,
      sourceControlProjection,
      watcherOverflowDiagnostics: new WatcherOverflowDiagnostics(),
    });

    expect(() => handleNotification("status/delta", deltaResponse())).toThrow(
      "SUBVERSIONR_STATUS_NOTIFICATION_STATE_UNAVAILABLE",
    );
    expect(statusSnapshotStore.applyDelta).not.toHaveBeenCalled();
    expect(sourceControlProjection.applyDelta).not.toHaveBeenCalled();
  });

  it("rejects status/delta notifications before changing state when canonical and projection generations differ", () => {
    const statusSnapshotStore = fakeStatusSnapshotStore();
    const sourceControlProjection = fakeSourceControlProjection({ generation: 10 });
    const handleNotification = createStatusNotificationHandler({
      statusSnapshotStore,
      sourceControlProjection,
      watcherOverflowDiagnostics: new WatcherOverflowDiagnostics(),
    });

    expect(() => handleNotification("status/delta", deltaResponse({ generation: 12 }))).toThrow(
      "SUBVERSIONR_STATUS_NOTIFICATION_STATE_DIVERGED",
    );
    expect(statusSnapshotStore.applyDelta).not.toHaveBeenCalled();
    expect(sourceControlProjection.applyDelta).not.toHaveBeenCalled();
  });

  it("rejects unsupported notification methods without changing status state", () => {
    const statusSnapshotStore = fakeStatusSnapshotStore();
    const sourceControlProjection = fakeSourceControlProjection();
    const handleNotification = createStatusNotificationHandler({
      statusSnapshotStore,
      sourceControlProjection,
      watcherOverflowDiagnostics: new WatcherOverflowDiagnostics(),
    });

    expect(() => handleNotification("status/progress", {})).toThrow("SUBVERSIONR_BACKEND_NOTIFICATION_UNSUPPORTED");
    expect(statusSnapshotStore.markStale).not.toHaveBeenCalled();
    expect(sourceControlProjection.markStale).not.toHaveBeenCalled();
  });
});

function fakeStatusSnapshotStore(): Pick<StatusSnapshotStore, "applyDelta" | "getSnapshot" | "markStale"> & {
  applyDelta: ReturnType<typeof vi.fn<StatusSnapshotStore["applyDelta"]>>;
  markStale: ReturnType<typeof vi.fn<StatusSnapshotStore["markStale"]>>;
  getSnapshot: ReturnType<typeof vi.fn<StatusSnapshotStore["getSnapshot"]>>;
} {
  let snapshot: StoredStatusSnapshot = {
    repositoryId: "repo-uuid:C:/wc",
    epoch: 7,
    generation: 11,
    completeness: "complete" as const,
    identity: {
      repositoryUuid: "repo-uuid",
      repositoryRootUrl: "file:///C:/repo",
      workingCopyRoot: "C:/wc",
      workspaceScopeRoot: "C:/workspace",
      format: 31,
    },
    localEntries: [],
    remoteEntries: [],
    summary: {
      localChanges: 0,
      remoteChanges: 0,
      conflicts: 0,
      unversioned: 0,
    },
    timestamp: "2026-06-22T00:00:00Z",
    source: "libsvn-local",
  };
  return {
    applyDelta: vi.fn<StatusSnapshotStore["applyDelta"]>((delta) => {
      snapshot = {
        ...snapshot,
        repositoryId: delta.repositoryId,
        epoch: delta.epoch,
        generation: delta.generation,
        completeness: delta.completeness,
        localEntries: delta.upsert,
        remoteEntries: delta.remoteUpsert,
        summary: {
          localChanges: snapshot.summary.localChanges + delta.summaryDelta.localChanges,
          remoteChanges: snapshot.summary.remoteChanges + delta.summaryDelta.remoteChanges,
          conflicts: snapshot.summary.conflicts + delta.summaryDelta.conflicts,
          unversioned: snapshot.summary.unversioned + delta.summaryDelta.unversioned,
        },
        timestamp: delta.timestamp,
        source: delta.source,
      };
      return snapshot;
    }),
    getSnapshot: vi.fn<StatusSnapshotStore["getSnapshot"]>(() => snapshot),
    markStale: vi.fn<StatusSnapshotStore["markStale"]>((mark) => {
      snapshot = {
        ...snapshot,
        epoch: mark.epoch,
        completeness: "stale",
        timestamp: mark.timestamp,
        source: mark.source,
      };
      return snapshot;
    }),
  };
}

function fakeSourceControlProjection(
  options: { generation?: number; projection?: ReturnType<SourceControlProjectionService["getProjection"]> } = {},
): Pick<
  SourceControlProjectionService,
  "applyDelta" | "getProjection" | "markStale" | "replaceSnapshot"
> & {
  applyDelta: ReturnType<typeof vi.fn<SourceControlProjectionService["applyDelta"]>>;
  getProjection: ReturnType<typeof vi.fn<SourceControlProjectionService["getProjection"]>>;
  markStale: ReturnType<typeof vi.fn<SourceControlProjectionService["markStale"]>>;
  replaceSnapshot: ReturnType<typeof vi.fn<SourceControlProjectionService["replaceSnapshot"]>>;
} {
  let projection = options.projection === undefined && "projection" in options
    ? undefined
    : ({ epoch: 7, generation: options.generation ?? 11 } as ReturnType<
        SourceControlProjectionService["getProjection"]
      >);
  return {
    applyDelta: vi.fn<SourceControlProjectionService["applyDelta"]>((delta) => {
      projection = {
        ...(projection ?? {}),
        repositoryId: delta.repositoryId,
        epoch: delta.epoch,
        generation: delta.generation,
      } as ReturnType<SourceControlProjectionService["applyDelta"]>;
      return projection;
    }),
    getProjection: vi.fn<SourceControlProjectionService["getProjection"]>(() => projection),
    markStale: vi.fn<SourceControlProjectionService["markStale"]>((mark) => {
      projection = {
        ...(projection ?? {}),
        repositoryId: mark.repositoryId,
        epoch: mark.epoch,
      } as ReturnType<SourceControlProjectionService["markStale"]>;
      return projection;
    }),
    replaceSnapshot: vi.fn<SourceControlProjectionService["replaceSnapshot"]>((snapshot) => {
      projection = {
        ...(projection ?? {}),
        repositoryId: snapshot.repositoryId,
        epoch: snapshot.epoch,
        generation: snapshot.generation,
      } as ReturnType<SourceControlProjectionService["replaceSnapshot"]>;
      return projection;
    }),
  };
}

function deltaResponse(options: Partial<StatusDelta> = {}): StatusDelta {
  const generation = options.generation ?? 12;
  return {
    repositoryId: "repo-uuid:C:/wc",
    epoch: 7,
    generation,
    coverage: [{ path: "src", depth: "files", generation, reason: "directoryChanged" }],
    upsert: [statusEntry({ generation })],
    remove: [],
    remoteUpsert: [],
    remoteRemove: [],
    summaryDelta: {
      localChanges: 1,
      remoteChanges: 0,
      conflicts: 0,
      unversioned: 0,
    },
    completeness: "partial",
    timestamp: "2026-06-22T00:02:00Z",
    source: "libsvn-local",
    ...options,
  };
}

function statusEntry(overrides: Partial<StatusEntry> = {}): StatusEntry {
  return {
    path: "src/main.c",
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
    conflictArtifacts: [],
    external: false,
    generation: 12,
    ...overrides,
  };
}
