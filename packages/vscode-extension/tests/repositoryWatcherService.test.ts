import { describe, expect, it, vi } from "vitest";
import { RepositoryWatcherService, type RepositoryFileWatcher } from "../src/status/repositoryWatcherService";
import { DirtyPathPipeline } from "../src/status/dirtyPathPipeline";
import type { SourceControlProjectionService } from "../src/scm/sourceControlProjectionService";
import type { StatusDelta } from "../src/status/statusRefreshRpcClient";
import type { StatusSnapshotStore } from "../src/status/statusSnapshotStore";
import type { RepositoryWatchScope, StatusRefreshClient, StatusRefreshRequest } from "../src/status/types";

const scope: RepositoryWatchScope = {
  repositoryId: "repo-uuid:C:/wc",
  epoch: 7,
  workingCopyRoot: "C:/wc/",
  pathCase: "case-insensitive",
};

describe("RepositoryWatcherService", () => {
  it("does not create watchers before a repository scope is registered", () => {
    const factory = new RecordingWatcherFactory();
    new RepositoryWatcherService({
      pipeline: new DirtyPathPipeline(noopRefreshClient(), fakeStatusSnapshotStore(), fakeSourceControlProjectionService()),
      createWatcher: factory.createWatcher,
    });

    expect(factory.requests).toEqual([]);
  });

  it("creates one recursive watcher for the working-copy root and routes changes to status refresh", async () => {
    const requests: StatusRefreshRequest[] = [];
    const factory = new RecordingWatcherFactory();
    const pipeline = new DirtyPathPipeline(
      refreshClient(requests),
      fakeStatusSnapshotStore(),
      fakeSourceControlProjectionService(),
      { debounceMs: 1000 },
    );
    const service = new RepositoryWatcherService({
      pipeline,
      createWatcher: factory.createWatcher,
      now: () => 100,
    });

    service.registerRepository(scope);
    factory.watchers[0].fireChanged("C:\\wc\\src\\main.c");
    await pipeline.flushRepository(scope.repositoryId);

    expect(factory.requests).toEqual([
      {
        repositoryId: "repo-uuid:C:/wc",
        basePath: "C:/wc",
        pattern: "**/*",
        ignoreCreateEvents: false,
        ignoreChangeEvents: false,
        ignoreDeleteEvents: false,
      },
    ]);
    expect(requests).toEqual([
      {
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        targets: [{ path: "src/main.c", depth: "empty", reason: "fileChanged" }],
      },
    ]);
  });

  it.each([
    ["C:\\", "C:/"],
    ["/", "/"],
    ["\\\\server\\share\\", "//server/share"],
  ])("preserves filesystem root watcher base paths for %s", (workingCopyRoot, expectedBasePath) => {
    const factory = new RecordingWatcherFactory();
    const service = new RepositoryWatcherService({
      pipeline: new DirtyPathPipeline(noopRefreshClient(), fakeStatusSnapshotStore(), fakeSourceControlProjectionService()),
      createWatcher: factory.createWatcher,
    });

    service.registerRepository({
      ...scope,
      workingCopyRoot,
    });

    expect(factory.requests[0].basePath).toBe(expectedBasePath);
  });

  it("routes create and delete events through the dirty-path planner", async () => {
    const requests: StatusRefreshRequest[] = [];
    const factory = new RecordingWatcherFactory();
    const pipeline = new DirtyPathPipeline(
      refreshClient(requests),
      fakeStatusSnapshotStore(),
      fakeSourceControlProjectionService(),
      { debounceMs: 1000 },
    );
    const service = new RepositoryWatcherService({
      pipeline,
      createWatcher: factory.createWatcher,
      now: vi.fn().mockReturnValueOnce(100).mockReturnValueOnce(101),
    });

    service.registerRepository(scope);
    factory.watchers[0].fireCreated("C:/wc/src/new.c");
    factory.watchers[0].fireDeleted("C:/wc/src/old.c");
    await pipeline.flushRepository(scope.repositoryId);

    expect(requests[0].targets).toEqual([
      { path: "src", depth: "immediates", reason: "childCreated" },
      { path: "src", depth: "immediates", reason: "childDeleted" },
      { path: "src/new.c", depth: "empty", reason: "fileCreated" },
      { path: "src/old.c", depth: "empty", reason: "fileDeleted" },
    ]);
  });

  it("fails fast on duplicate repository watcher registration", () => {
    const factory = new RecordingWatcherFactory();
    const service = new RepositoryWatcherService({
      pipeline: new DirtyPathPipeline(noopRefreshClient(), fakeStatusSnapshotStore(), fakeSourceControlProjectionService()),
      createWatcher: factory.createWatcher,
    });

    service.registerRepository(scope);

    expect(() => service.registerRepository(scope)).toThrow("Repository watcher already registered: repo-uuid:C:/wc");
    expect(factory.requests).toHaveLength(1);
  });

  it("rolls back pipeline registration when watcher creation fails", async () => {
    const pipeline = new DirtyPathPipeline(noopRefreshClient(), fakeStatusSnapshotStore(), fakeSourceControlProjectionService());
    const service = new RepositoryWatcherService({
      pipeline,
      createWatcher: () => {
        throw new Error("watcher unavailable");
      },
    });

    expect(() => service.registerRepository(scope)).toThrow("watcher unavailable");
    await expect(pipeline.flushRepository(scope.repositoryId)).rejects.toThrow(
      "Repository is not registered: repo-uuid:C:/wc",
    );
  });

  it("rolls back pipeline registration and disposes the watcher when listener registration fails", async () => {
    const pipeline = new DirtyPathPipeline(noopRefreshClient(), fakeStatusSnapshotStore(), fakeSourceControlProjectionService());
    const watcher = new ListenerFailureWatcher();
    const service = new RepositoryWatcherService({
      pipeline,
      createWatcher: () => watcher,
    });

    expect(() => service.registerRepository(scope)).toThrow("listener unavailable");
    expect(watcher.disposed).toBe(true);
    await expect(pipeline.flushRepository(scope.repositoryId)).rejects.toThrow(
      "Repository is not registered: repo-uuid:C:/wc",
    );
  });

  it("disposes listeners and watcher on unregister", async () => {
    const requests: StatusRefreshRequest[] = [];
    const factory = new RecordingWatcherFactory();
    const pipeline = new DirtyPathPipeline(
      refreshClient(requests),
      fakeStatusSnapshotStore(),
      fakeSourceControlProjectionService(),
      { debounceMs: 1000 },
    );
    const service = new RepositoryWatcherService({
      pipeline,
      createWatcher: factory.createWatcher,
      now: () => 100,
    });

    service.registerRepository(scope);
    service.unregisterRepository(scope.repositoryId);
    factory.watchers[0].fireChanged("C:/wc/src/main.c");

    expect(factory.watchers[0].disposed).toBe(true);
    expect(factory.watchers[0].listenerCount()).toBe(0);
    await expect(pipeline.flushRepository(scope.repositoryId)).rejects.toThrow(
      "Repository is not registered: repo-uuid:C:/wc",
    );
    expect(requests).toEqual([]);
  });

  it("keeps unregister idempotent for missing repositories", () => {
    const service = new RepositoryWatcherService({
      pipeline: new DirtyPathPipeline(noopRefreshClient(), fakeStatusSnapshotStore(), fakeSourceControlProjectionService()),
      createWatcher: new RecordingWatcherFactory().createWatcher,
    });

    expect(() => service.unregisterRepository(scope.repositoryId)).not.toThrow();
  });

  it("clears watcher and pipeline registrations even when watcher disposal fails", async () => {
    const pipeline = new DirtyPathPipeline(noopRefreshClient(), fakeStatusSnapshotStore(), fakeSourceControlProjectionService());
    const watcher = new DisposalFailureWatcher();
    const service = new RepositoryWatcherService({
      pipeline,
      createWatcher: () => watcher,
    });

    service.registerRepository(scope);

    expect(() => service.unregisterRepository(scope.repositoryId)).toThrow("watcher disposal failed");
    expect(() => service.registerRepository(scope)).not.toThrow();
    await expect(pipeline.flushRepository(scope.repositoryId)).resolves.toBeUndefined();
  });

  it("still disposes the watcher when a listener subscription disposal fails", async () => {
    const pipeline = new DirtyPathPipeline(noopRefreshClient(), fakeStatusSnapshotStore(), fakeSourceControlProjectionService());
    const watcher = new SubscriptionDisposalFailureWatcher();
    const service = new RepositoryWatcherService({
      pipeline,
      createWatcher: () => watcher,
    });

    service.registerRepository(scope);

    expect(() => service.unregisterRepository(scope.repositoryId)).toThrow("subscription disposal failed");
    expect(watcher.disposed).toBe(true);
    expect(() => service.registerRepository(scope)).not.toThrow();
  });


  it("disposes all registered repository watchers", () => {
    const factory = new RecordingWatcherFactory();
    const service = new RepositoryWatcherService({
      pipeline: new DirtyPathPipeline(noopRefreshClient(), fakeStatusSnapshotStore(), fakeSourceControlProjectionService()),
      createWatcher: factory.createWatcher,
    });

    service.registerRepository(scope);
    service.registerRepository({
      ...scope,
      repositoryId: "repo-uuid:C:/other",
      workingCopyRoot: "C:/other",
    });

    service.dispose();

    expect(factory.watchers.map((watcher) => watcher.disposed)).toEqual([true, true]);
    expect(factory.watchers.map((watcher) => watcher.listenerCount())).toEqual([0, 0]);
  });

  it("keeps dispose idempotent", () => {
    const factory = new RecordingWatcherFactory();
    const service = new RepositoryWatcherService({
      pipeline: new DirtyPathPipeline(noopRefreshClient(), fakeStatusSnapshotStore(), fakeSourceControlProjectionService()),
      createWatcher: factory.createWatcher,
    });

    service.registerRepository(scope);
    service.dispose();
    service.dispose();

    expect(factory.watchers[0].disposeCalls).toBe(1);
  });

  it("keeps parent watcher events out of nested repository boundaries while child watcher accepts them", async () => {
    const requests: StatusRefreshRequest[] = [];
    const factory = new RecordingWatcherFactory();
    const pipeline = new DirtyPathPipeline(
      refreshClient(requests),
      fakeStatusSnapshotStore(),
      fakeSourceControlProjectionService(),
      { debounceMs: 1000 },
    );
    const service = new RepositoryWatcherService({
      pipeline,
      createWatcher: factory.createWatcher,
      now: vi.fn().mockReturnValueOnce(100).mockReturnValueOnce(101),
    });
    const parent = {
      ...scope,
      boundaryRoots: ["C:/wc/vendor/external"],
    };
    const child = {
      ...scope,
      repositoryId: "repo-uuid:C:/wc/vendor/external",
      workingCopyRoot: "C:/wc/vendor/external",
    };

    service.registerRepository(parent);
    service.registerRepository(child);
    factory.watchers[0].fireChanged("C:/wc/vendor/external/main.c");
    factory.watchers[1].fireChanged("C:/wc/vendor/external/main.c");
    await pipeline.flushRepository(parent.repositoryId);
    await pipeline.flushRepository(child.repositoryId);

    expect(requests).toEqual([
      {
        repositoryId: "repo-uuid:C:/wc/vendor/external",
        epoch: 7,
        targets: [{ path: "main.c", depth: "empty", reason: "fileChanged" }],
      },
    ]);
  });

  it("folds watcher event storms through the dirty-path overflow target", async () => {
    const requests: StatusRefreshRequest[] = [];
    const factory = new RecordingWatcherFactory();
    const pipeline = new DirtyPathPipeline(refreshClient(requests), fakeStatusSnapshotStore(), fakeSourceControlProjectionService(), {
      debounceMs: 1000,
      maxDirtyPaths: 3,
    });
    const service = new RepositoryWatcherService({
      pipeline,
      createWatcher: factory.createWatcher,
      now: () => 100,
    });

    service.registerRepository(scope);
    for (let index = 0; index < 10; index += 1) {
      factory.watchers[0].fireChanged(`C:/wc/generated-${index}/file.txt`);
    }
    await pipeline.flushRepository(scope.repositoryId);

    expect(requests).toEqual([
      {
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        targets: [{ path: ".", depth: "infinity", reason: "watcherOverflow" }],
      },
    ]);
  });
});

class RecordingWatcherFactory {
  public readonly requests: Array<{
    repositoryId: string;
    basePath: string;
    pattern: string;
    ignoreCreateEvents: boolean;
    ignoreChangeEvents: boolean;
    ignoreDeleteEvents: boolean;
  }> = [];
  public readonly watchers: FakeRepositoryFileWatcher[] = [];

  public readonly createWatcher = (request: {
    repositoryId: string;
    basePath: string;
    pattern: string;
    ignoreCreateEvents: boolean;
    ignoreChangeEvents: boolean;
    ignoreDeleteEvents: boolean;
  }): RepositoryFileWatcher => {
    this.requests.push(request);
    const watcher = new FakeRepositoryFileWatcher();
    this.watchers.push(watcher);
    return watcher;
  };
}

class FakeRepositoryFileWatcher implements RepositoryFileWatcher {
  public disposed = false;
  public disposeCalls = 0;
  private readonly changeListeners: Array<(uri: { fsPath: string }) => void> = [];
  private readonly createListeners: Array<(uri: { fsPath: string }) => void> = [];
  private readonly deleteListeners: Array<(uri: { fsPath: string }) => void> = [];

  public onDidChange(listener: (uri: { fsPath: string }) => void): { dispose(): void } {
    this.changeListeners.push(listener);
    return disposable(() => removeListener(this.changeListeners, listener));
  }

  public onDidCreate(listener: (uri: { fsPath: string }) => void): { dispose(): void } {
    this.createListeners.push(listener);
    return disposable(() => removeListener(this.createListeners, listener));
  }

  public onDidDelete(listener: (uri: { fsPath: string }) => void): { dispose(): void } {
    this.deleteListeners.push(listener);
    return disposable(() => removeListener(this.deleteListeners, listener));
  }

  public dispose(): void {
    this.disposeCalls += 1;
    this.disposed = true;
    this.changeListeners.length = 0;
    this.createListeners.length = 0;
    this.deleteListeners.length = 0;
  }

  public fireChanged(fsPath: string): void {
    this.changeListeners.forEach((listener) => listener({ fsPath }));
  }

  public fireCreated(fsPath: string): void {
    this.createListeners.forEach((listener) => listener({ fsPath }));
  }

  public fireDeleted(fsPath: string): void {
    this.deleteListeners.forEach((listener) => listener({ fsPath }));
  }

  public listenerCount(): number {
    return this.changeListeners.length + this.createListeners.length + this.deleteListeners.length;
  }
}

class ListenerFailureWatcher extends FakeRepositoryFileWatcher {
  public override onDidCreate(): { dispose(): void } {
    throw new Error("listener unavailable");
  }
}

class DisposalFailureWatcher extends FakeRepositoryFileWatcher {
  public override dispose(): void {
    super.dispose();
    throw new Error("watcher disposal failed");
  }
}

class SubscriptionDisposalFailureWatcher extends FakeRepositoryFileWatcher {
  public override onDidChange(listener: (uri: { fsPath: string }) => void): { dispose(): void } {
    super.onDidChange(listener);
    return disposable(() => {
      throw new Error("subscription disposal failed");
    });
  }
}

function refreshClient(requests: StatusRefreshRequest[]): StatusRefreshClient {
  return {
    refreshStatus: async (request) => {
      requests.push(request);
      return deltaResponse(request);
    },
  };
}

function noopRefreshClient(): StatusRefreshClient {
  return {
    refreshStatus: async (request) => deltaResponse(request),
  };
}

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

function disposable(dispose: () => void): { dispose(): void } {
  return { dispose };
}

function removeListener<T>(listeners: T[], listener: T): void {
  const index = listeners.indexOf(listener);
  if (index >= 0) {
    listeners.splice(index, 1);
  }
}
