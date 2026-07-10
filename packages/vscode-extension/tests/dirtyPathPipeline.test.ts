import { describe, expect, it, vi } from "vitest";
import { DirtyPathPipeline } from "../src/status/dirtyPathPipeline";
import type { SourceControlProjectionService } from "../src/scm/sourceControlProjectionService";
import type { StatusDelta } from "../src/status/statusRefreshRpcClient";
import type { StatusSnapshotStore } from "../src/status/statusSnapshotStore";
import type { RepositoryWatchScope, StatusRefreshClient, StatusRefreshRequest } from "../src/status/types";

const scope: RepositoryWatchScope = {
  repositoryId: "repo-uuid:C:/wc",
  epoch: 7,
  workingCopyRoot: "C:/wc",
  pathCase: "case-insensitive",
};

describe("DirtyPathPipeline", () => {
  it("coalesces a raw watcher burst into one refresh request", async () => {
    const client: StatusRefreshClient = {
      refreshStatus: vi.fn((request: StatusRefreshRequest) => Promise.resolve(deltaResponse(request))),
    };
    const pipeline = new DirtyPathPipeline(client, fakeStatusSnapshotStore(), fakeSourceControlProjectionService(), {
      debounceMs: 10,
    });
    pipeline.registerRepository(scope);

    pipeline.accept("repo-uuid:C:/wc", {
      fsPath: "C:/wc/src/a.c",
      kind: "changed",
      timestamp: 100,
    });
    pipeline.accept("repo-uuid:C:/wc", {
      fsPath: "C:/wc/src/b.c",
      kind: "changed",
      timestamp: 101,
    });

    await pipeline.flushRepository("repo-uuid:C:/wc");

    expect(client.refreshStatus).toHaveBeenCalledTimes(1);
    expectRefreshStatusRequest(client, 1, {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      targets: [
        { path: "src/a.c", depth: "empty", reason: "fileChanged" },
        { path: "src/b.c", depth: "empty", reason: "fileChanged" },
      ],
    });
  });

  it("folds a same-directory watcher storm before sending the refresh request", async () => {
    const client: StatusRefreshClient = {
      refreshStatus: vi.fn((request: StatusRefreshRequest) => Promise.resolve(deltaResponse(request))),
    };
    const pipeline = new DirtyPathPipeline(client, fakeStatusSnapshotStore(), fakeSourceControlProjectionService(), {
      debounceMs: 10,
      maxDirtyPaths: 4,
    });
    pipeline.registerRepository(scope);

    for (let index = 0; index < 5; index += 1) {
      pipeline.accept("repo-uuid:C:/wc", {
        fsPath: `C:/wc/generated/file-${index}.txt`,
        kind: "changed",
        timestamp: 100 + index,
      });
    }

    await pipeline.flushRepository("repo-uuid:C:/wc");

    expect(client.refreshStatus).toHaveBeenCalledTimes(1);
    expectRefreshStatusRequest(client, 1, {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      targets: [{ path: "generated", depth: "files", reason: "dirtyPathFold" }],
    });
  });

  it("folds a nested watcher storm into a subtree refresh request", async () => {
    const client: StatusRefreshClient = {
      refreshStatus: vi.fn((request: StatusRefreshRequest) => Promise.resolve(deltaResponse(request))),
    };
    const pipeline = new DirtyPathPipeline(client, fakeStatusSnapshotStore(), fakeSourceControlProjectionService(), {
      debounceMs: 10,
      maxDirtyPaths: 4,
    });
    pipeline.registerRepository(scope);

    for (let index = 0; index < 5; index += 1) {
      pipeline.accept("repo-uuid:C:/wc", {
        fsPath: `C:/wc/generated/module-${index}/src/file.txt`,
        kind: "changed",
        timestamp: 100 + index,
      });
    }

    await pipeline.flushRepository("repo-uuid:C:/wc");

    expect(client.refreshStatus).toHaveBeenCalledTimes(1);
    expectRefreshStatusRequest(client, 1, {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      targets: [{ path: "generated", depth: "infinity", reason: "dirtyPathSubtreeFold" }],
    });
  });

  it("preserves replacement semantics for deleted then created watcher events", async () => {
    const client: StatusRefreshClient = {
      refreshStatus: vi.fn((request: StatusRefreshRequest) => Promise.resolve(deltaResponse(request))),
    };
    const pipeline = new DirtyPathPipeline(client, fakeStatusSnapshotStore(), fakeSourceControlProjectionService(), {
      debounceMs: 10,
    });
    pipeline.registerRepository(scope);

    pipeline.accept("repo-uuid:C:/wc", {
      fsPath: "C:/wc/src/replaced.c",
      kind: "deleted",
      timestamp: 100,
    });
    pipeline.accept("repo-uuid:C:/wc", {
      fsPath: "C:/wc/src/replaced.c",
      kind: "created",
      timestamp: 101,
    });

    await pipeline.flushRepository("repo-uuid:C:/wc");

    expectRefreshStatusRequest(client, 1, {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      targets: [
        { path: "src", depth: "immediates", reason: "childReplaced" },
        { path: "src/replaced.c", depth: "empty", reason: "fileReplaced" },
      ],
    });
  });

  it("does not refresh for .svn noise or empty flushes", async () => {
    const client: StatusRefreshClient = {
      refreshStatus: vi.fn((request: StatusRefreshRequest) => Promise.resolve(deltaResponse(request))),
    };
    const pipeline = new DirtyPathPipeline(client, fakeStatusSnapshotStore(), fakeSourceControlProjectionService(), {
      debounceMs: 10,
    });
    pipeline.registerRepository(scope);

    pipeline.accept("repo-uuid:C:/wc", {
      fsPath: "C:/wc/.svn/wc.db",
      kind: "changed",
      timestamp: 100,
    });
    await pipeline.flushRepository("repo-uuid:C:/wc");

    expect(client.refreshStatus).not.toHaveBeenCalled();
  });

  it("delegates explicit operation reconcile targets without draining pending dirty paths", async () => {
    const client: StatusRefreshClient = {
      refreshStatus: vi.fn((request: StatusRefreshRequest) => Promise.resolve(deltaResponse(request))),
    };
    const pipeline = new DirtyPathPipeline(client, fakeStatusSnapshotStore(), fakeSourceControlProjectionService(), {
      debounceMs: 10_000,
    });
    pipeline.registerRepository(scope);
    pipeline.accept("repo-uuid:C:/wc", {
      fsPath: "C:/wc/src/pending.c",
      kind: "changed",
      timestamp: 100,
    });

    await pipeline.refreshTargets({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      targets: [{ path: "src/main.c", depth: "empty", reason: "operationRevert" }],
    });
    await pipeline.flushRepository("repo-uuid:C:/wc");

    expectRefreshStatusRequest(client, 1, {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      targets: [{ path: "src/main.c", depth: "empty", reason: "operationRevert" }],
    });
    expectRefreshStatusRequest(client, 2, {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      targets: [{ path: "src/pending.c", depth: "empty", reason: "fileChanged" }],
    });
  });
});

function fakeStatusSnapshotStore(): Pick<StatusSnapshotStore, "applyDelta" | "getSnapshot" | "markStale"> {
  const snapshot = {
    repositoryId: "repo-uuid:C:/wc",
    epoch: 7,
    generation: 10,
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
    applyDelta: vi.fn((delta: StatusDelta) => ({
      ...snapshot,
      repositoryId: delta.repositoryId,
      epoch: delta.epoch,
      generation: delta.generation,
      completeness: delta.completeness,
      localEntries: delta.upsert,
      timestamp: delta.timestamp,
      source: delta.source,
    })),
    getSnapshot: vi.fn(() => snapshot),
    markStale: vi.fn((mark) => ({
      ...snapshot,
      completeness: "stale" as const,
      timestamp: mark.timestamp,
      source: mark.source,
    })),
  };
}

function fakeSourceControlProjectionService(): Pick<
  SourceControlProjectionService,
  "applyDelta" | "getProjection" | "markStale" | "replaceSnapshot"
> {
  const projection = {
    repositoryId: "repo-uuid:C:/wc",
    epoch: 7,
    workingCopyRoot: "C:/wc",
    generation: 10,
    count: 0,
    freshness: {
      repositoryCompleteness: "complete" as const,
      lastRefreshCompleteness: "complete" as const,
      lastRefreshKind: "snapshot" as const,
    },
    groups: [],
  };
  return {
    applyDelta: vi.fn((delta: StatusDelta) => ({
      ...projection,
      repositoryId: delta.repositoryId,
      epoch: delta.epoch,
      generation: delta.generation,
      freshness: {
        repositoryCompleteness: "complete" as const,
        lastRefreshCompleteness: delta.completeness,
        lastRefreshKind: "delta" as const,
      },
    })),
    getProjection: vi.fn(() => projection),
    markStale: vi.fn((mark) => ({
      ...projection,
      epoch: mark.epoch,
      freshness: {
        repositoryCompleteness: "stale" as const,
        lastRefreshCompleteness: "stale" as const,
        lastRefreshKind: "stale" as const,
      },
    })),
    replaceSnapshot: vi.fn((snapshot) => ({
      ...projection,
      repositoryId: snapshot.repositoryId,
      epoch: snapshot.epoch,
      workingCopyRoot: snapshot.identity.workingCopyRoot,
      generation: snapshot.generation,
      freshness: {
        repositoryCompleteness: snapshot.completeness,
        lastRefreshCompleteness: snapshot.completeness,
        lastRefreshKind: "snapshot" as const,
      },
    })),
  };
}

function expectRefreshStatusRequest(
  client: StatusRefreshClient,
  callNumber: number,
  request: StatusRefreshRequest,
): void {
  const calls = (client.refreshStatus as unknown as { mock: { calls: Array<[StatusRefreshRequest, { signal?: AbortSignal }?]> } }).mock.calls;
  const call = calls[callNumber - 1];
  expect(call?.[0]).toEqual(request);
  expect(call?.[1]?.signal).toBeInstanceOf(AbortSignal);
}

function deltaResponse(request: StatusRefreshRequest): StatusDelta {
  return {
    repositoryId: request.repositoryId,
    epoch: request.epoch,
    generation: 11,
    coverage: request.targets.map((target) => ({
      path: target.path,
      depth: target.depth,
      generation: 11,
      reason: target.reason,
    })),
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
    timestamp: "2026-06-22T00:00:00Z",
    source: "libsvn-local",
  };
}
