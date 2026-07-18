import { describe, expect, it, vi } from "vitest";
import {
  SourceControlProjectionService,
  type SourceControlProjectionPresenter,
} from "../src/scm/sourceControlProjectionService";
import { SourceControlResourceStore } from "../src/scm/sourceControlResourceStore";
import type { StatusDelta } from "../src/status/statusRefreshRpcClient";
import type { StatusEntry, StatusSnapshot } from "../src/status/statusSnapshotRpcClient";

describe("SourceControlProjectionService", () => {
  it("requires the presenter current-resource identity decision", () => {
    const presenter = fakePresenter();
    const resourceState = {};
    presenter.isCurrentResourceState.mockReturnValueOnce(true);
    const service = new SourceControlProjectionService(sourceControlResourceStore(), presenter);

    expect(service.isCurrentResourceState(resourceState)).toBe(true);
    expect(presenter.isCurrentResourceState).toHaveBeenCalledWith(resourceState);
  });

  it("registers a repository and publishes projection updates for snapshots and deltas", () => {
    const presenter = fakePresenter();
    const service = new SourceControlProjectionService(sourceControlResourceStore(), presenter);

    service.registerRepository(repository());
    service.applySnapshot(snapshotResponse({ localEntries: [statusEntry({ path: "src/main.c", localStatus: "modified" })] }));
    service.applyDelta(
      deltaResponse({
        generation: 12,
        upsert: [statusEntry({ path: "notes.txt", localStatus: "unversioned", generation: 12 })],
      }),
    );

    expect(presenter.registerRepository).toHaveBeenCalledWith(repository());
    expect(presenter.updateRepository).toHaveBeenCalledTimes(2);
    expect(
      presenter.updateRepository.mock.calls[0][0].groups.find((group) => group.id === "changes")?.resources.map(
        (resource) => resource.path,
      ),
    ).toEqual(["src/main.c"]);
    expect(
      presenter.updateRepository.mock.calls[1][0].groups.find((group) => group.id === "unversioned")?.resources.map(
        (resource) => resource.path,
      ),
    ).toEqual(["notes.txt"]);
  });

  it("publishes incoming resources from remote refresh deltas", () => {
    const presenter = fakePresenter();
    const service = new SourceControlProjectionService(sourceControlResourceStore(), presenter);

    service.registerRepository(repository());
    service.applySnapshot(
      snapshotResponse({
        generation: 11,
        remoteEntries: [statusEntry({ path: "src/old-incoming.c", remoteStatus: "modified", generation: 11 })],
      }),
    );
    const projection = service.applyDelta(
      deltaResponse({
        generation: 12,
        remoteUpsert: [statusEntry({ path: "src/new-incoming.c", remoteStatus: "modified", generation: 12 })],
        remoteRemove: ["src/old-incoming.c"],
      }),
    );

    expect(presenter.updateRepository).toHaveBeenLastCalledWith(projection);
    expect(projection.groups.find((group) => group.id === "incoming")?.resources.map((resource) => resource.path)).toEqual([
      "src/new-incoming.c",
    ]);
  });

  it("reprojects count policy changes without refreshing or mutating repository generations", () => {
    const presenter = fakePresenter();
    const service = new SourceControlProjectionService(sourceControlResourceStore(), presenter);
    const events: unknown[] = [];
    service.onDidChangeProjection((event) => events.push(event));
    service.registerRepository(repository());
    const initial = service.applySnapshot(
      snapshotResponse({
        localEntries: [
          statusEntry({ path: "src/main.c", localStatus: "modified" }),
          statusEntry({ path: "src/review.c", localStatus: "modified", changelist: "review" }),
          statusEntry({ path: "notes.txt", localStatus: "unversioned" }),
          statusEntry({ path: "src/needs-lock.c", needsLock: true }),
        ],
        remoteEntries: [statusEntry({ path: "src/incoming.c", remoteStatus: "modified" })],
      }),
    );
    presenter.updateRepository.mockClear();
    events.length = 0;

    const [withUnversioned] = service.updateCountPolicy({
      countUnversioned: true,
      ignoreChangelistsInCount: ["review"],
    });
    const [restored] = service.updateCountPolicy({
      countUnversioned: false,
      ignoreChangelistsInCount: [],
    });

    expect(withUnversioned.count).toBe(2);
    expect(restored.count).toBe(2);
    expect(presenter.updateRepository).toHaveBeenNthCalledWith(1, withUnversioned);
    expect(presenter.updateRepository).toHaveBeenNthCalledWith(2, restored);
    for (const projection of [withUnversioned, restored]) {
      expect(projection.epoch).toBe(initial.epoch);
      expect(projection.generation).toBe(initial.generation);
      expect(projection.freshness).toEqual(initial.freshness);
      expect(projection.groups.find((group) => group.id === "incoming")?.resources.map((resource) => resource.path)).toEqual([
        "src/incoming.c",
      ]);
      expect(projection.groups.find((group) => group.id === "metadata")?.resources.map((resource) => resource.path)).toEqual([
        "src/needs-lock.c",
      ]);
    }
    expect(events).toEqual([]);
  });

  it("emits lightweight projection change events after successful updates", () => {
    const presenter = fakePresenter();
    const service = new SourceControlProjectionService(sourceControlResourceStore(), presenter);
    const events: unknown[] = [];
    const subscription = service.onDidChangeProjection((event) => events.push(event));

    service.registerRepository(repository());
    service.applySnapshot(snapshotResponse({ generation: 11 }));
    service.applyDelta(deltaResponse({ generation: 12 }));
    service.unregisterRepository("repo-uuid:C:/wc");
    subscription.dispose();
    service.registerRepository(repository());

    expect(events).toEqual([
      { kind: "registered", repositoryId: "repo-uuid:C:/wc", epoch: 7 },
      {
        kind: "updated",
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        generation: 11,
        freshness: {
          repositoryCompleteness: "complete",
          lastRefreshCompleteness: "complete",
          lastRefreshKind: "snapshot",
        },
      },
      {
        kind: "updated",
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        generation: 12,
        freshness: {
          repositoryCompleteness: "complete",
          lastRefreshCompleteness: "partial",
          lastRefreshKind: "delta",
        },
      },
      { kind: "unregistered", repositoryId: "repo-uuid:C:/wc" },
    ]);
  });

  it("publishes stale projection updates from status stale notifications", () => {
    const presenter = fakePresenter();
    const service = new SourceControlProjectionService(sourceControlResourceStore(), presenter);
    const events: unknown[] = [];
    service.onDidChangeProjection((event) => events.push(event));
    service.registerRepository(repository());
    service.applySnapshot(snapshotResponse({ generation: 12 }));
    presenter.updateRepository.mockClear();

    const projection = service.markStale({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      reason: "backendRestart",
      timestamp: "2026-06-22T00:03:00Z",
      source: "daemon-status-stale",
    });

    expect(projection.freshness).toEqual({
      repositoryCompleteness: "stale",
      lastRefreshCompleteness: "stale",
      lastRefreshKind: "stale",
    });
    expect(presenter.updateRepository).toHaveBeenCalledWith(projection);
    expect(events.at(-1)).toEqual({
      kind: "updated",
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      generation: 12,
      freshness: {
        repositoryCompleteness: "stale",
        lastRefreshCompleteness: "stale",
        lastRefreshKind: "stale",
      },
    });
  });

  it("does not publish projection updates when delta validation fails", () => {
    const presenter = fakePresenter();
    const service = new SourceControlProjectionService(sourceControlResourceStore(), presenter);
    service.registerRepository(repository());
    service.applySnapshot(snapshotResponse({ generation: 12 }));
    presenter.updateRepository.mockClear();

    expect(() => service.applyDelta(deltaResponse({ generation: 12 }))).toThrow(
      "SUBVERSIONR_SCM_PROJECTION_DELTA_GENERATION_STALE",
    );

    expect(presenter.updateRepository).not.toHaveBeenCalled();
  });

  it("unregisters repositories from the store and presenter", () => {
    const presenter = fakePresenter();
    const service = new SourceControlProjectionService(sourceControlResourceStore(), presenter);
    service.registerRepository(repository());

    service.unregisterRepository("repo-uuid:C:/wc");

    expect(service.getProjection("repo-uuid:C:/wc")).toBeUndefined();
    expect(presenter.unregisterRepository).toHaveBeenCalledWith("repo-uuid:C:/wc");
  });

  it("publishes remote state without changing the local projection generation or count", () => {
    const presenter = fakePresenter();
    const service = new SourceControlProjectionService(sourceControlResourceStore(), presenter);
    const events: unknown[] = [];
    service.onDidChangeProjection((event) => events.push(event));
    service.registerRepository(repository());
    const before = service.applySnapshot(snapshotResponse({ generation: 12 }));

    service.updateRemoteConnectionState({
      kind: "unreachable",
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      reason: "timeout",
      incoming: { kind: "stale" },
      recovery: { kind: "notRequired" },
      lastFailure: {
        reason: "networkTimeout",
        cleanupAppropriate: false,
        occurredAt: "2026-07-18T01:00:00.000Z",
      },
    });

    expect(service.getProjection("repo-uuid:C:/wc")).toEqual(before);
    expect(presenter.updateRemoteConnectionState).toHaveBeenCalledOnce();
    expect(events.at(-1)).toEqual({
      kind: "remoteStateUpdated",
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      state: "unreachable",
    });
  });
});

function sourceControlResourceStore(): SourceControlResourceStore {
  return new SourceControlResourceStore({
    countPolicy: {
      countUnversioned: false,
      ignoreChangelistsInCount: ["ignore-on-commit"],
    },
  });
}

function fakePresenter(): SourceControlProjectionPresenter & {
  registerRepository: ReturnType<typeof vi.fn<SourceControlProjectionPresenter["registerRepository"]>>;
  updateRepository: ReturnType<typeof vi.fn<SourceControlProjectionPresenter["updateRepository"]>>;
  updateRemoteConnectionState: ReturnType<typeof vi.fn<SourceControlProjectionPresenter["updateRemoteConnectionState"]>>;
  unregisterRepository: ReturnType<typeof vi.fn<SourceControlProjectionPresenter["unregisterRepository"]>>;
  isCurrentResourceState: ReturnType<typeof vi.fn<SourceControlProjectionPresenter["isCurrentResourceState"]>>;
} {
  return {
    registerRepository: vi.fn<SourceControlProjectionPresenter["registerRepository"]>(),
    updateRepository: vi.fn<SourceControlProjectionPresenter["updateRepository"]>(),
    updateRemoteConnectionState: vi.fn<SourceControlProjectionPresenter["updateRemoteConnectionState"]>(),
    unregisterRepository: vi.fn<SourceControlProjectionPresenter["unregisterRepository"]>(),
    isCurrentResourceState: vi.fn<SourceControlProjectionPresenter["isCurrentResourceState"]>(() => false),
  };
}

function repository() {
  return {
    repositoryId: "repo-uuid:C:/wc",
    epoch: 7,
    workingCopyRoot: "C:/wc",
  };
}

function snapshotResponse(options: Partial<StatusSnapshot> = {}): StatusSnapshot {
  return {
    repositoryId: "repo-uuid:C:/wc",
    epoch: 7,
    generation: 11,
    completeness: "complete",
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
    ...options,
  };
}

function deltaResponse(options: Partial<StatusDelta> = {}): StatusDelta {
  const generation = options.generation ?? 12;
  return {
    repositoryId: "repo-uuid:C:/wc",
    epoch: 7,
    generation,
    coverage: [{ path: "src", depth: "files", generation, reason: "directoryChanged" }],
    upsert: [],
    remove: [],
    remoteUpsert: [],
    remoteRemove: [],
    summaryDelta: {
      localChanges: 0,
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
    nodeStatus: "normal",
    textStatus: "normal",
    propertyStatus: "normal",
    localStatus: "normal",
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
    generation: 11,
    ...overrides,
  };
}
