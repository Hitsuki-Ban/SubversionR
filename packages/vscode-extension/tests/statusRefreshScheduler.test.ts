import { describe, expect, it, vi } from "vitest";
import { StatusRefreshScheduler } from "../src/status/statusRefreshScheduler";
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

describe("StatusRefreshScheduler", () => {
  it("flushes dirty paths through status/refresh, applies the delta, and clears them after success", async () => {
    const requests: StatusRefreshRequest[] = [];
    const delta = deltaResponse();
    const client: StatusRefreshClient = {
      refreshStatus: async (request) => {
        requests.push(request);
        return delta;
      },
    };
    const store = fakeStatusSnapshotStore();
    const projection = fakeSourceControlProjectionService();
    const scheduler = new StatusRefreshScheduler(client, store, projection, { debounceMs: 10 });

    scheduler.registerRepository(scope);
    scheduler.recordFileEvent("repo-uuid:C:/wc", {
      path: "C:/wc/src/main.c",
      kind: "change",
      timestamp: 100,
    });

    await scheduler.flushRepository("repo-uuid:C:/wc");
    await scheduler.flushRepository("repo-uuid:C:/wc");

    expect(requests).toEqual([
      {
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        targets: [{ path: "src/main.c", depth: "empty", reason: "fileChanged" }],
      },
    ]);
    expect(store.applyDelta).toHaveBeenCalledWith(delta);
    expect(projection.applyDelta).toHaveBeenCalledWith(delta);
    expect(store.applyDelta.mock.invocationCallOrder[0]).toBeLessThan(
      projection.applyDelta.mock.invocationCallOrder[0],
    );
  });

  it("records completed refresh targets and returned coverage for installed diagnostics", async () => {
    const calls: string[] = [];
    const coverageRecords: unknown[] = [];
    const client: StatusRefreshClient = {
      refreshStatus: vi.fn(async (request) => deltaResponseFromRequest(request)),
    };
    const scheduler = new StatusRefreshScheduler(
      client,
      fakeStatusSnapshotStore({ calls }),
      fakeSourceControlProjectionService({ calls }),
      {
        debounceMs: 10,
        coverageRecorder: {
          recordCompletedStatusRefreshCoverage: (record: unknown) => {
            calls.push("coverage-record");
            coverageRecords.push(record);
          },
        },
      },
    );

    scheduler.registerRepository(scope);
    await scheduler.refreshResource({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "load/modified-001.txt",
    });

    expect(calls).toEqual(["status-delta", "projection-delta", "coverage-record"]);
    expect(coverageRecords).toEqual([
      {
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        generation: 11,
        targets: [{ path: "load/modified-001.txt", depth: "empty", reason: "resourceRefresh" }],
        coverage: [{ path: "load/modified-001.txt", depth: "empty", generation: 11, reason: "resourceRefresh" }],
        completeness: "partial",
        timestamp: "2026-06-22T00:00:00Z",
        source: "libsvn-local",
      },
    ]);
  });

  it("does not record completed coverage when projection publication rejects the delta", async () => {
    const coverageRecords: unknown[] = [];
    const client: StatusRefreshClient = {
      refreshStatus: vi.fn(async (request) => deltaResponseFromRequest(request)),
    };
    const store = fakeStatusSnapshotStore();
    const projection = fakeSourceControlProjectionService();
    projection.applyDelta.mockImplementation(() => {
      throw new Error("projection failed");
    });
    const scheduler = new StatusRefreshScheduler(
      client,
      store,
      projection,
      {
        debounceMs: 10,
        coverageRecorder: {
          recordCompletedStatusRefreshCoverage: (record: unknown) => {
            coverageRecords.push(record);
          },
        },
      },
    );

    scheduler.registerRepository(scope);
    await expect(
      scheduler.refreshResource({
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        path: "load/modified-001.txt",
      }),
    ).rejects.toThrow("projection failed");

    expect(projection.replaceSnapshot).toHaveBeenCalledWith(store.getSnapshot("repo-uuid:C:/wc"));
    expect(coverageRecords).toEqual([]);
  });

  it("does not record completed coverage for a cancelled dirty-path refresh", async () => {
    const coverageRecords: unknown[] = [];
    const pendingRefreshes: Array<{
      signal: AbortSignal | undefined;
      resolve(delta: StatusDelta): void;
      reject(error: Error): void;
    }> = [];
    const client: StatusRefreshClient = {
      refreshStatus: vi.fn((_request, options) => {
        return new Promise<StatusDelta>((resolve, reject) => {
          pendingRefreshes.push({ signal: options?.signal, resolve, reject });
          options?.signal?.addEventListener("abort", () => {
            reject(new Error("refresh aborted"));
          });
        });
      }),
    };
    const scheduler = new StatusRefreshScheduler(
      client,
      fakeStatusSnapshotStore(),
      fakeSourceControlProjectionService(),
      {
        debounceMs: 10_000,
        coverageRecorder: {
          recordCompletedStatusRefreshCoverage: (record: unknown) => {
            coverageRecords.push(record);
          },
        },
      },
    );

    scheduler.registerRepository(scope);
    scheduler.recordFileEvent("repo-uuid:C:/wc", {
      path: "C:/wc/src/first.c",
      kind: "change",
      timestamp: Date.UTC(2026, 5, 22, 0, 0, 0),
    });

    const firstFlush = scheduler.flushRepository("repo-uuid:C:/wc");
    await flushMicrotasks();
    scheduler.recordFileEvent("repo-uuid:C:/wc", {
      path: "C:/wc/src/second.c",
      kind: "change",
      timestamp: Date.UTC(2026, 5, 22, 0, 0, 1),
    });

    expect(pendingRefreshes[0].signal?.aborted).toBe(true);
    await expect(firstFlush).rejects.toMatchObject({
      code: "SUBVERSIONR_STATUS_REFRESH_CANCELLED",
    });
    expect(coverageRecords).toEqual([]);
  });

  it("keeps dirty paths when status/refresh fails", async () => {
    const client: StatusRefreshClient = {
      refreshStatus: vi
        .fn()
        .mockRejectedValueOnce(new Error("bridge failed"))
        .mockResolvedValueOnce(deltaResponse()),
    };
    const scheduler = new StatusRefreshScheduler(client, fakeStatusSnapshotStore(), fakeSourceControlProjectionService(), { debounceMs: 10 });
    scheduler.registerRepository(scope);
    scheduler.recordFileEvent("repo-uuid:C:/wc", {
      path: "C:/wc/src/main.c",
      kind: "change",
      timestamp: 100,
    });

    await expect(scheduler.flushRepository("repo-uuid:C:/wc")).rejects.toThrow("bridge failed");
    await scheduler.flushRepository("repo-uuid:C:/wc");

    expect(client.refreshStatus).toHaveBeenCalledTimes(2);
  });

  it("marks initialized status stale and requeues targets when a new dirty generation cancels an in-flight refresh", async () => {
    const calls: string[] = [];
    const pendingRefreshes: Array<{
      request: StatusRefreshRequest;
      signal: AbortSignal | undefined;
      resolve(delta: StatusDelta): void;
      reject(error: Error): void;
    }> = [];
    const client: StatusRefreshClient = {
      refreshStatus: vi.fn((request, options) => {
        return new Promise<StatusDelta>((resolve, reject) => {
          pendingRefreshes.push({ request, signal: options?.signal, resolve, reject });
          options?.signal?.addEventListener("abort", () => {
            reject(new Error("refresh aborted"));
          });
        });
      }),
    };
    const store = fakeStatusSnapshotStore({ calls });
    const projection = fakeSourceControlProjectionService({ calls });
    const scheduler = new StatusRefreshScheduler(client, store, projection, { debounceMs: 10_000 });
    scheduler.registerRepository(scope);
    scheduler.recordFileEvent("repo-uuid:C:/wc", {
      path: "C:/wc/src/first.c",
      kind: "change",
      timestamp: Date.UTC(2026, 5, 22, 0, 0, 0),
    });

    const firstFlush = scheduler.flushRepository("repo-uuid:C:/wc");
    await flushMicrotasks();
    scheduler.recordFileEvent("repo-uuid:C:/wc", {
      path: "C:/wc/src/second.c",
      kind: "change",
      timestamp: Date.UTC(2026, 5, 22, 0, 0, 1),
    });

    expect(pendingRefreshes[0].signal?.aborted).toBe(true);
    const staleMark = {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      reason: "refreshCancelled",
      timestamp: "2026-06-22T00:00:01.000Z",
      source: "vscode-status-scheduler",
    };
    expect(store.markStale).toHaveBeenCalledWith(staleMark);
    expect(projection.markStale).toHaveBeenCalledWith(staleMark);
    await expect(firstFlush).rejects.toMatchObject({
      code: "SUBVERSIONR_STATUS_REFRESH_CANCELLED",
      category: "lifecycle",
      messageKey: "error.status.refreshCancelled",
      safeArgs: {
        repositoryId: "repo-uuid:C:/wc",
        reason: "dirtyGenerationSuperseded",
      },
    });

    const secondFlush = scheduler.flushRepository("repo-uuid:C:/wc");
    await flushMicrotasks();
    expect(pendingRefreshes[1].request).toEqual({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      targets: [
        { path: "src/first.c", depth: "empty", reason: "fileChanged" },
        { path: "src/second.c", depth: "empty", reason: "fileChanged" },
      ],
    });
    pendingRefreshes[1].resolve(deltaResponse({ generation: 12 }));
    await secondFlush;
    expect(calls).toEqual(["status-stale", "projection-stale", "status-delta", "projection-delta"]);
  });

  it("marks initialized status state stale when watcher dirty paths overflow", async () => {
    const calls: string[] = [];
    const client: StatusRefreshClient = {
      refreshStatus: vi.fn(async () => {
        calls.push("refresh");
        return deltaResponse();
      }),
    };
    const store = fakeStatusSnapshotStore({ calls });
    const projection = fakeSourceControlProjectionService({ calls });
    const scheduler = new StatusRefreshScheduler(client, store, projection, {
      debounceMs: 10,
      maxDirtyPaths: 3,
    });

    scheduler.registerRepository(scope);
    for (let index = 0; index < 6; index += 1) {
      scheduler.recordFileEvent("repo-uuid:C:/wc", {
        path: `C:/wc/generated-${index}/file.txt`,
        kind: "change",
        timestamp: Date.UTC(2026, 5, 22, 0, 0, index),
      });
    }
    await scheduler.flushRepository("repo-uuid:C:/wc");

    const mark = {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      reason: "watcherOverflow",
      timestamp: "2026-06-22T00:00:03.000Z",
      source: "vscode-watcher",
    };
    expect(store.markStale).toHaveBeenCalledTimes(1);
    expect(store.markStale).toHaveBeenCalledWith(mark);
    expect(projection.markStale).toHaveBeenCalledTimes(1);
    expect(projection.markStale).toHaveBeenCalledWith(mark);
    expect(calls).toEqual(["status-stale", "projection-stale", "refresh", "status-delta", "projection-delta"]);
  });

  it("recovers stale projection from the canonical snapshot when watcher overflow publishing fails", () => {
    const client: StatusRefreshClient = {
      refreshStatus: vi.fn(async () => deltaResponse()),
    };
    const store = fakeStatusSnapshotStore();
    const projection = fakeSourceControlProjectionService();
    projection.markStale.mockImplementationOnce(() => {
      throw new Error("projection failed");
    });
    const scheduler = new StatusRefreshScheduler(client, store, projection, {
      debounceMs: 10,
      maxDirtyPaths: 1,
    });
    scheduler.registerRepository(scope);
    scheduler.recordFileEvent("repo-uuid:C:/wc", {
      path: "C:/wc/generated-0/file.txt",
      kind: "change",
      timestamp: Date.UTC(2026, 5, 22, 0, 0, 0),
    });

    expect(() =>
      scheduler.recordFileEvent("repo-uuid:C:/wc", {
        path: "C:/wc/generated-1/file.txt",
        kind: "change",
        timestamp: Date.UTC(2026, 5, 22, 0, 0, 1),
      }),
    ).toThrow("projection failed");

    expect(projection.replaceSnapshot).toHaveBeenCalledTimes(1);
    expect(projection.replaceSnapshot).toHaveBeenCalledWith(store.getSnapshot("repo-uuid:C:/wc"));
  });

  it("does not fabricate stale state when watcher overflow happens before the first visible snapshot", async () => {
    const client: StatusRefreshClient = {
      refreshStatus: vi.fn((request: StatusRefreshRequest) => Promise.resolve(deltaResponseFromRequest(request))),
    };
    const store = fakeStatusSnapshotStore({ snapshot: undefined });
    const projection = fakeSourceControlProjectionService({ projection: undefined });
    const scheduler = new StatusRefreshScheduler(client, store, projection, {
      debounceMs: 10,
      maxDirtyPaths: 3,
    });

    scheduler.registerRepository(scope);
    for (let index = 0; index < 6; index += 1) {
      scheduler.recordFileEvent("repo-uuid:C:/wc", {
        path: `C:/wc/generated-${index}/file.txt`,
        kind: "change",
        timestamp: Date.UTC(2026, 5, 22, 0, 0, index),
      });
    }
    await scheduler.flushRepository("repo-uuid:C:/wc");

    expect(store.markStale).not.toHaveBeenCalled();
    expect(projection.markStale).not.toHaveBeenCalled();
    expectRefreshStatusRequest(client, 1, {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      targets: [{ path: ".", depth: "infinity", reason: "watcherOverflow" }],
    });
  });

  it("rejects watcher overflow stale marking before mutating when visible status state is incomplete", () => {
    const client: StatusRefreshClient = {
      refreshStatus: vi.fn().mockResolvedValue(deltaResponse()),
    };
    const store = fakeStatusSnapshotStore();
    const projection = fakeSourceControlProjectionService({ projection: undefined });
    const scheduler = new StatusRefreshScheduler(client, store, projection, {
      debounceMs: 10,
      maxDirtyPaths: 3,
    });

    scheduler.registerRepository(scope);
    for (let index = 0; index < 3; index += 1) {
      scheduler.recordFileEvent("repo-uuid:C:/wc", {
        path: `C:/wc/generated-${index}/file.txt`,
        kind: "change",
        timestamp: Date.UTC(2026, 5, 22, 0, 0, index),
      });
    }

    let thrown: unknown;
    try {
      scheduler.recordFileEvent("repo-uuid:C:/wc", {
        path: "C:/wc/generated-3/file.txt",
        kind: "change",
        timestamp: Date.UTC(2026, 5, 22, 0, 0, 3),
      });
    } catch (error) {
      thrown = error;
    }

    expect(thrown).toMatchObject({
      code: "SUBVERSIONR_STATUS_NOTIFICATION_STATE_UNAVAILABLE",
      category: "lifecycle",
      messageKey: "error.status.notificationStateUnavailable",
      safeArgs: {
        repositoryId: "repo-uuid:C:/wc",
        state: "projection",
      },
    });
    expect(store.markStale).not.toHaveBeenCalled();
    expect(projection.markStale).not.toHaveBeenCalled();
    expect(client.refreshStatus).not.toHaveBeenCalled();
  });

  it("refreshes an explicit resource target through status/refresh", async () => {
    const delta = deltaResponse();
    const client: StatusRefreshClient = {
      refreshStatus: vi.fn().mockResolvedValue(delta),
    };
    const store = fakeStatusSnapshotStore();
    const projection = fakeSourceControlProjectionService();
    const scheduler = new StatusRefreshScheduler(client, store, projection, { debounceMs: 10 });
    scheduler.registerRepository(scope);

    await scheduler.refreshResource({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src/main.c",
    });

    expectRefreshStatusRequest(client, 1, {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      targets: [{ path: "src/main.c", depth: "empty", reason: "resourceRefresh" }],
    });
    expect(store.applyDelta).toHaveBeenCalledWith(delta);
    expect(projection.applyDelta).toHaveBeenCalledWith(delta);
    expect(store.applyDelta.mock.invocationCallOrder[0]).toBeLessThan(
      projection.applyDelta.mock.invocationCallOrder[0],
    );
  });

  it("rejects explicit resource refresh when the session epoch is stale", async () => {
    const client: StatusRefreshClient = {
      refreshStatus: vi.fn().mockResolvedValue(deltaResponse()),
    };
    const scheduler = new StatusRefreshScheduler(client, fakeStatusSnapshotStore(), fakeSourceControlProjectionService(), {
      debounceMs: 10,
    });
    scheduler.registerRepository(scope);

    await expect(
      scheduler.refreshResource({
        repositoryId: "repo-uuid:C:/wc",
        epoch: 6,
        path: "src/main.c",
      }),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_STATUS_RESOURCE_REFRESH_EPOCH_MISMATCH",
      category: "lifecycle",
      messageKey: "error.status.resourceRefreshEpochMismatch",
      safeArgs: {
        repositoryId: "repo-uuid:C:/wc",
        expected: 7,
        actual: 6,
      },
    });
    expect(client.refreshStatus).not.toHaveBeenCalled();
  });

  it("does not drain pending dirty paths when refreshing one explicit resource", async () => {
    const client: StatusRefreshClient = {
      refreshStatus: vi
        .fn()
        .mockResolvedValueOnce(deltaResponse({ generation: 11 }))
        .mockResolvedValueOnce(deltaResponse({ generation: 12 })),
    };
    const scheduler = new StatusRefreshScheduler(client, fakeStatusSnapshotStore(), fakeSourceControlProjectionService(), {
      debounceMs: 10_000,
    });
    scheduler.registerRepository(scope);
    scheduler.recordFileEvent("repo-uuid:C:/wc", {
      path: "C:/wc/src/pending.c",
      kind: "change",
      timestamp: 100,
    });

    await scheduler.refreshResource({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src/main.c",
    });
    await scheduler.flushRepository("repo-uuid:C:/wc");

    expectRefreshStatusRequest(client, 1, {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      targets: [{ path: "src/main.c", depth: "empty", reason: "resourceRefresh" }],
    });
    expectRefreshStatusRequest(client, 2, {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      targets: [{ path: "src/pending.c", depth: "empty", reason: "fileChanged" }],
    });
  });

  it("refreshes explicit operation reconcile targets through status/refresh", async () => {
    const delta = deltaResponse();
    const client: StatusRefreshClient = {
      refreshStatus: vi.fn().mockResolvedValue(delta),
    };
    const store = fakeStatusSnapshotStore();
    const projection = fakeSourceControlProjectionService();
    const scheduler = new StatusRefreshScheduler(client, store, projection, { debounceMs: 10 });
    scheduler.registerRepository(scope);

    await scheduler.refreshTargets({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      targets: [{ path: "src/main.c", depth: "empty", reason: "operationRevert" }],
    });

    expectRefreshStatusRequest(client, 1, {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      targets: [{ path: "src/main.c", depth: "empty", reason: "operationRevert" }],
    });
    expect(store.applyDelta).toHaveBeenCalledWith(delta);
    expect(projection.applyDelta).toHaveBeenCalledWith(delta);
  });

  it("aborts explicit target refresh when the caller cancellation signal is triggered", async () => {
    const pendingRefreshes: Array<{
      request: StatusRefreshRequest;
      signal: AbortSignal | undefined;
      resolve(delta: StatusDelta): void;
      reject(error: Error): void;
    }> = [];
    const client: StatusRefreshClient = {
      refreshStatus: vi.fn((request, options) => {
        return new Promise<StatusDelta>((resolve, reject) => {
          pendingRefreshes.push({ request, signal: options?.signal, resolve, reject });
          options?.signal?.addEventListener("abort", () => {
            reject(new Error("refresh aborted"));
          });
        });
      }),
    };
    const scheduler = new StatusRefreshScheduler(client, fakeStatusSnapshotStore(), fakeSourceControlProjectionService());
    scheduler.registerRepository(scope);
    const cancellation = new AbortController();
    const request = {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      targets: [{ path: ".", depth: "infinity" as const, reason: "manualRemoteCheck" }],
    };

    const firstRefresh = scheduler.refreshTargets(request, { signal: cancellation.signal });
    await flushMicrotasks();
    cancellation.abort();

    expect(pendingRefreshes[0].signal?.aborted).toBe(true);
    await expect(firstRefresh).rejects.toMatchObject({
      code: "SUBVERSIONR_STATUS_REFRESH_CANCELLED",
      category: "lifecycle",
      messageKey: "error.status.refreshCancelled",
      safeArgs: {
        repositoryId: "repo-uuid:C:/wc",
        reason: "userCancelled",
      },
    });

    const secondRefresh = scheduler.refreshTargets(request);
    await flushMicrotasks();
    expect(pendingRefreshes[1].request.targets).toEqual([
      { path: ".", depth: "infinity", reason: "manualRemoteCheck" },
    ]);
    pendingRefreshes[1].resolve(deltaResponseFromRequest(pendingRefreshes[1].request));
    await secondRefresh;
  });

  it("retries explicit operation reconcile targets on the next repository flush after backend failure", async () => {
    const targets = [{ path: "src/main.c", depth: "empty", reason: "operationRevert" }] as const;
    const client: StatusRefreshClient = {
      refreshStatus: vi
        .fn()
        .mockRejectedValueOnce(new Error("bridge failed"))
        .mockResolvedValueOnce(deltaResponse()),
    };
    const scheduler = new StatusRefreshScheduler(client, fakeStatusSnapshotStore(), fakeSourceControlProjectionService(), {
      debounceMs: 10,
    });
    scheduler.registerRepository(scope);

    await expect(
      scheduler.refreshTargets({
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        targets: [...targets],
      }),
    ).rejects.toThrow("bridge failed");
    await scheduler.flushRepository("repo-uuid:C:/wc");

    const request = {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      targets: [...targets],
    };
    expectRefreshStatusRequest(client, 1, request);
    expectRefreshStatusRequest(client, 2, request);
  });

  it("retries explicit operation reconcile targets when canonical delta application fails", async () => {
    const targets = [{ path: "src/main.c", depth: "empty", reason: "operationCommit" }] as const;
    const client: StatusRefreshClient = {
      refreshStatus: vi.fn().mockResolvedValue(deltaResponse()),
    };
    const store = fakeStatusSnapshotStore();
    const projection = fakeSourceControlProjectionService();
    store.applyDelta.mockImplementationOnce(() => {
      throw new Error("store failed");
    });
    const scheduler = new StatusRefreshScheduler(client, store, projection, { debounceMs: 10 });
    scheduler.registerRepository(scope);

    await expect(
      scheduler.refreshTargets({
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        targets: [...targets],
      }),
    ).rejects.toThrow("store failed");
    await scheduler.flushRepository("repo-uuid:C:/wc");

    expect(client.refreshStatus).toHaveBeenCalledTimes(2);
    expect(store.applyDelta).toHaveBeenCalledTimes(2);
    expect(projection.applyDelta).toHaveBeenCalledTimes(1);
  });

  it("recovers explicit operation projection from the canonical snapshot when publishing fails", async () => {
    const targets = [{ path: "src/main.c", depth: "empty", reason: "operationUpdate" }] as const;
    const client: StatusRefreshClient = {
      refreshStatus: vi.fn().mockResolvedValue(deltaResponse()),
    };
    const store = fakeStatusSnapshotStore();
    const projection = fakeSourceControlProjectionService();
    projection.applyDelta.mockImplementationOnce(() => {
      throw new Error("projection failed");
    });
    const scheduler = new StatusRefreshScheduler(client, store, projection, { debounceMs: 10 });
    scheduler.registerRepository(scope);

    await expect(
      scheduler.refreshTargets({
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        targets: [...targets],
      }),
    ).rejects.toThrow("projection failed");
    await scheduler.flushRepository("repo-uuid:C:/wc");

    expect(client.refreshStatus).toHaveBeenCalledTimes(1);
    expect(projection.replaceSnapshot).toHaveBeenCalledTimes(1);
    expect(projection.replaceSnapshot).toHaveBeenCalledWith(store.getSnapshot("repo-uuid:C:/wc"));
  });

  it("rejects explicit operation reconcile targets with stale epochs or invalid target fields", async () => {
    const client: StatusRefreshClient = {
      refreshStatus: vi.fn().mockResolvedValue(deltaResponse()),
    };
    const scheduler = new StatusRefreshScheduler(client, fakeStatusSnapshotStore(), fakeSourceControlProjectionService(), {
      debounceMs: 10,
    });
    scheduler.registerRepository(scope);

    await expect(
      scheduler.refreshTargets({
        repositoryId: "repo-uuid:C:/wc",
        epoch: 6,
        targets: [{ path: "src/main.c", depth: "empty", reason: "operationRevert" }],
      }),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_STATUS_TARGET_REFRESH_EPOCH_MISMATCH",
      category: "lifecycle",
      messageKey: "error.status.targetRefreshEpochMismatch",
    });
    await expect(
      scheduler.refreshTargets({
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        targets: [{ path: "../main.c", depth: "empty", reason: "operationRevert" }],
      }),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_STATUS_TARGET_REFRESH_TARGET_INVALID",
      category: "input",
      messageKey: "error.status.targetRefreshTargetInvalid",
      safeArgs: { field: "targets.0.path" },
    });
    expect(client.refreshStatus).not.toHaveBeenCalled();
  });

  it("keeps dirty paths when applying a refresh delta fails", async () => {
    const client: StatusRefreshClient = {
      refreshStatus: vi.fn().mockResolvedValue(deltaResponse()),
    };
    const store = fakeStatusSnapshotStore();
    const projection = fakeSourceControlProjectionService();
    store.applyDelta.mockImplementationOnce(() => {
      throw new Error("apply failed");
    });
    const scheduler = new StatusRefreshScheduler(client, store, projection, { debounceMs: 10 });
    scheduler.registerRepository(scope);
    scheduler.recordFileEvent("repo-uuid:C:/wc", {
      path: "C:/wc/src/main.c",
      kind: "change",
      timestamp: 100,
    });

    await expect(scheduler.flushRepository("repo-uuid:C:/wc")).rejects.toThrow("apply failed");
    await scheduler.flushRepository("repo-uuid:C:/wc");

    expect(client.refreshStatus).toHaveBeenCalledTimes(2);
    expect(store.applyDelta).toHaveBeenCalledTimes(2);
    expect(projection.applyDelta).toHaveBeenCalledTimes(1);
  });

  it("recovers dirty-path projection from the canonical snapshot when publishing fails", async () => {
    const client: StatusRefreshClient = {
      refreshStatus: vi.fn().mockResolvedValue(deltaResponse()),
    };
    const store = fakeStatusSnapshotStore();
    const projection = fakeSourceControlProjectionService();
    projection.applyDelta.mockImplementationOnce(() => {
      throw new Error("projection failed");
    });
    const scheduler = new StatusRefreshScheduler(client, store, projection, { debounceMs: 10 });
    scheduler.registerRepository(scope);
    scheduler.recordFileEvent("repo-uuid:C:/wc", {
      path: "C:/wc/src/main.c",
      kind: "change",
      timestamp: 100,
    });

    await expect(scheduler.flushRepository("repo-uuid:C:/wc")).rejects.toThrow("projection failed");
    await scheduler.flushRepository("repo-uuid:C:/wc");

    expect(client.refreshStatus).toHaveBeenCalledTimes(1);
    expect(projection.replaceSnapshot).toHaveBeenCalledTimes(1);
    expect(projection.replaceSnapshot).toHaveBeenCalledWith(store.getSnapshot("repo-uuid:C:/wc"));
  });

  it("rejects stale in-flight refresh results and requeues events recorded while a refresh is in flight", async () => {
    let releaseFirstRefresh!: () => void;
    const firstRefresh = new Promise<StatusDelta>((resolve) => {
      releaseFirstRefresh = () => resolve(deltaResponse({ generation: 11 }));
    });
    const client: StatusRefreshClient = {
      refreshStatus: vi.fn().mockReturnValueOnce(firstRefresh).mockResolvedValueOnce(deltaResponse({ generation: 12 })),
    };
    const scheduler = new StatusRefreshScheduler(client, fakeStatusSnapshotStore(), fakeSourceControlProjectionService(), { debounceMs: 10 });
    scheduler.registerRepository(scope);
    scheduler.recordFileEvent("repo-uuid:C:/wc", {
      path: "C:/wc/src/a.c",
      kind: "change",
      timestamp: 100,
    });

    const pending = scheduler.flushRepository("repo-uuid:C:/wc");
    scheduler.recordFileEvent("repo-uuid:C:/wc", {
      path: "C:/wc/src/b.c",
      kind: "change",
      timestamp: 101,
    });
    releaseFirstRefresh();
    await expect(pending).rejects.toMatchObject({
      code: "SUBVERSIONR_STATUS_REFRESH_CANCELLED",
      safeArgs: {
        reason: "dirtyGenerationSuperseded",
      },
    });
    await scheduler.flushRepository("repo-uuid:C:/wc");

    expect(client.refreshStatus).toHaveBeenCalledTimes(2);
    expectRefreshStatusRequest(client, 2, {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      targets: [
        { path: "src/a.c", depth: "empty", reason: "fileChanged" },
        { path: "src/b.c", depth: "empty", reason: "fileChanged" },
      ],
    });
  });

  it("debounces repeated file events before flushing", async () => {
    vi.useFakeTimers();
    try {
      const client: StatusRefreshClient = {
        refreshStatus: vi.fn().mockResolvedValue(deltaResponse()),
      };
      const scheduler = new StatusRefreshScheduler(client, fakeStatusSnapshotStore(), fakeSourceControlProjectionService(), { debounceMs: 50 });
      scheduler.registerRepository(scope);

      scheduler.recordFileEvent("repo-uuid:C:/wc", {
        path: "C:/wc/src/a.c",
        kind: "change",
        timestamp: 100,
      });
      scheduler.recordFileEvent("repo-uuid:C:/wc", {
        path: "C:/wc/src/b.c",
        kind: "change",
        timestamp: 101,
      });

      await vi.advanceTimersByTimeAsync(49);
      expect(client.refreshStatus).not.toHaveBeenCalled();

      await vi.advanceTimersByTimeAsync(1);
      expect(client.refreshStatus).toHaveBeenCalledTimes(1);
    } finally {
      vi.useRealTimers();
    }
  });

  it("keeps scheduled backend failures observable without losing dirty paths", async () => {
    vi.useFakeTimers();
    try {
      const client: StatusRefreshClient = {
        refreshStatus: vi
          .fn()
          .mockRejectedValueOnce(new Error("backend failed"))
          .mockResolvedValueOnce(deltaResponse()),
      };
      const scheduler = new StatusRefreshScheduler(client, fakeStatusSnapshotStore(), fakeSourceControlProjectionService(), { debounceMs: 50 });
      scheduler.registerRepository(scope);
      scheduler.recordFileEvent("repo-uuid:C:/wc", {
        path: "C:/wc/src/a.c",
        kind: "change",
        timestamp: 100,
      });

      await vi.advanceTimersByTimeAsync(50);
      await scheduler.flushRepository("repo-uuid:C:/wc");

      expect(client.refreshStatus).toHaveBeenCalledTimes(2);
    } finally {
      vi.useRealTimers();
    }
  });

  it("runs full reconcile as a single root infinity refresh and clears pending dirty paths", async () => {
    vi.useFakeTimers();
    try {
      const client: StatusRefreshClient = {
        refreshStatus: vi.fn().mockResolvedValue(fullReconcileDeltaResponse()),
      };
      const store = fakeStatusSnapshotStore();
      const projection = fakeSourceControlProjectionService();
      const scheduler = new StatusRefreshScheduler(client, store, projection, { debounceMs: 50 });
      scheduler.registerRepository(scope);
      scheduler.recordFileEvent("repo-uuid:C:/wc", {
        path: "C:/wc/src/main.c",
        kind: "change",
        timestamp: 100,
      });

      await scheduler.fullReconcileRepository({ repositoryId: "repo-uuid:C:/wc", epoch: 7 });
      await vi.advanceTimersByTimeAsync(50);

      expect(client.refreshStatus).toHaveBeenCalledTimes(1);
      expectRefreshStatusRequest(client, 1, {
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        targets: [{ path: ".", depth: "infinity", reason: "manualFullReconcile" }],
      });
      expect(store.applyDelta).toHaveBeenCalledWith(fullReconcileDeltaResponse());
      expect(projection.applyDelta).toHaveBeenCalledWith(fullReconcileDeltaResponse());
    } finally {
      vi.useRealTimers();
    }
  });

  it("runs scheduled full reconcile after the configured low-frequency interval", async () => {
    vi.useFakeTimers();
    try {
      const client: StatusRefreshClient = {
        refreshStatus: vi.fn().mockResolvedValue(scheduledFullReconcileDeltaResponse()),
      };
      const scheduler = new StatusRefreshScheduler(
        client,
        fakeStatusSnapshotStore(),
        fakeSourceControlProjectionService(),
        {
          debounceMs: 10_000,
          fullReconcileIntervalMs: 100,
        },
      );

      scheduler.registerRepository(scope);
      await vi.advanceTimersByTimeAsync(99);
      expect(client.refreshStatus).not.toHaveBeenCalled();

      await vi.advanceTimersByTimeAsync(1);

      expectRefreshStatusRequest(client, 1, {
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        targets: [{ path: ".", depth: "infinity", reason: "scheduledFullReconcile" }],
      });
    } finally {
      vi.useRealTimers();
    }
  });

  it("cancels scheduled full reconcile when the repository is unregistered", async () => {
    vi.useFakeTimers();
    try {
      const client: StatusRefreshClient = {
        refreshStatus: vi.fn().mockResolvedValue(scheduledFullReconcileDeltaResponse()),
      };
      const scheduler = new StatusRefreshScheduler(
        client,
        fakeStatusSnapshotStore(),
        fakeSourceControlProjectionService(),
        {
          debounceMs: 10_000,
          fullReconcileIntervalMs: 100,
        },
      );

      scheduler.registerRepository(scope);
      scheduler.unregisterRepository(scope.repositoryId);
      await vi.advanceTimersByTimeAsync(100);

      expect(client.refreshStatus).not.toHaveBeenCalled();
    } finally {
      vi.useRealTimers();
    }
  });

  it("resets the scheduled full reconcile interval after manual full reconcile", async () => {
    vi.useFakeTimers();
    try {
      const client: StatusRefreshClient = {
        refreshStatus: vi
          .fn()
          .mockResolvedValueOnce(fullReconcileDeltaResponse())
          .mockResolvedValueOnce(scheduledFullReconcileDeltaResponse({ generation: 13 })),
      };
      const scheduler = new StatusRefreshScheduler(
        client,
        fakeStatusSnapshotStore(),
        fakeSourceControlProjectionService(),
        {
          debounceMs: 10_000,
          fullReconcileIntervalMs: 100,
        },
      );
      scheduler.registerRepository(scope);
      await vi.advanceTimersByTimeAsync(90);

      await scheduler.fullReconcileRepository({ repositoryId: "repo-uuid:C:/wc", epoch: 7 });
      await vi.advanceTimersByTimeAsync(99);
      expect(client.refreshStatus).toHaveBeenCalledTimes(1);

      await vi.advanceTimersByTimeAsync(1);
      expect(client.refreshStatus).toHaveBeenCalledTimes(2);
      expectRefreshStatusRequest(client, 2, {
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        targets: [{ path: ".", depth: "infinity", reason: "scheduledFullReconcile" }],
      });
    } finally {
      vi.useRealTimers();
    }
  });

  it("rejects incomplete full reconcile deltas before publishing to stores", async () => {
    const client: StatusRefreshClient = {
      refreshStatus: vi.fn().mockResolvedValue(fullReconcileDeltaResponse({ completeness: "partial" })),
    };
    const store = fakeStatusSnapshotStore();
    const projection = fakeSourceControlProjectionService();
    const scheduler = new StatusRefreshScheduler(client, store, projection, { debounceMs: 10 });
    scheduler.registerRepository(scope);

    await expect(
      scheduler.fullReconcileRepository({ repositoryId: "repo-uuid:C:/wc", epoch: 7 }),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_STATUS_FULL_RECONCILE_RESPONSE_INVALID",
      category: "protocol",
      messageKey: "error.status.fullReconcileResponseInvalid",
      safeArgs: { field: "completeness" },
    });

    expect(store.applyDelta).not.toHaveBeenCalled();
    expect(projection.applyDelta).not.toHaveBeenCalled();
  });

  it("rejects targeted coverage from full reconcile before publishing to stores", async () => {
    const client: StatusRefreshClient = {
      refreshStatus: vi.fn().mockResolvedValue(
        fullReconcileDeltaResponse({
          coverage: [{ path: "src/main.c", depth: "empty", generation: 12, reason: "fileChanged" }],
        }),
      ),
    };
    const store = fakeStatusSnapshotStore();
    const projection = fakeSourceControlProjectionService();
    const scheduler = new StatusRefreshScheduler(client, store, projection, { debounceMs: 10 });
    scheduler.registerRepository(scope);

    await expect(
      scheduler.fullReconcileRepository({ repositoryId: "repo-uuid:C:/wc", epoch: 7 }),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_STATUS_FULL_RECONCILE_RESPONSE_INVALID",
      category: "protocol",
      messageKey: "error.status.fullReconcileResponseInvalid",
      safeArgs: { field: "coverage.0" },
    });

    expect(store.applyDelta).not.toHaveBeenCalled();
    expect(projection.applyDelta).not.toHaveBeenCalled();
  });

  it("aborts manual full reconcile when the caller cancellation signal is triggered and requeues the reconcile target", async () => {
    const pendingRefreshes: Array<{
      request: StatusRefreshRequest;
      signal: AbortSignal | undefined;
      resolve(delta: StatusDelta): void;
      reject(error: Error): void;
    }> = [];
    const client: StatusRefreshClient = {
      refreshStatus: vi.fn((request, options) => {
        return new Promise<StatusDelta>((resolve, reject) => {
          pendingRefreshes.push({ request, signal: options?.signal, resolve, reject });
          options?.signal?.addEventListener("abort", () => {
            reject(new Error("refresh aborted"));
          });
        });
      }),
    };
    const scheduler = new StatusRefreshScheduler(client, fakeStatusSnapshotStore(), fakeSourceControlProjectionService());
    scheduler.registerRepository(scope);
    const cancellation = new AbortController();

    const firstReconcile = scheduler.fullReconcileRepository(
      { repositoryId: "repo-uuid:C:/wc", epoch: 7 },
      { signal: cancellation.signal },
    );
    await flushMicrotasks();
    cancellation.abort();

    expect(pendingRefreshes[0].signal?.aborted).toBe(true);
    await expect(firstReconcile).rejects.toMatchObject({
      code: "SUBVERSIONR_STATUS_REFRESH_CANCELLED",
      category: "lifecycle",
      messageKey: "error.status.refreshCancelled",
      safeArgs: {
        repositoryId: "repo-uuid:C:/wc",
        reason: "userCancelled",
      },
    });

    const secondReconcile = scheduler.fullReconcileRepository({ repositoryId: "repo-uuid:C:/wc", epoch: 7 });
    await flushMicrotasks();
    expect(pendingRefreshes[1].request.targets).toEqual([
      { path: ".", depth: "infinity", reason: "manualFullReconcile" },
    ]);
    pendingRefreshes[1].resolve(fullReconcileDeltaResponse({ generation: 12 }));
    await secondReconcile;
  });

  it("keeps pending dirty paths when full reconcile response validation fails", async () => {
    const client: StatusRefreshClient = {
      refreshStatus: vi
        .fn()
        .mockResolvedValueOnce(fullReconcileDeltaResponse({ completeness: "partial" }))
        .mockResolvedValueOnce(deltaResponse()),
    };
    const scheduler = new StatusRefreshScheduler(client, fakeStatusSnapshotStore(), fakeSourceControlProjectionService(), {
      debounceMs: 10,
    });
    scheduler.registerRepository(scope);
    scheduler.recordFileEvent("repo-uuid:C:/wc", {
      path: "C:/wc/src/main.c",
      kind: "change",
      timestamp: 100,
    });

    await expect(
      scheduler.fullReconcileRepository({ repositoryId: "repo-uuid:C:/wc", epoch: 7 }),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_STATUS_FULL_RECONCILE_RESPONSE_INVALID",
    });
    await scheduler.flushRepository("repo-uuid:C:/wc");

    expectRefreshStatusRequest(client, 2, {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      targets: [{ path: "src/main.c", depth: "empty", reason: "fileChanged" }],
    });
  });

  it("recovers full-reconcile projection from the canonical snapshot when publishing fails", async () => {
    vi.useFakeTimers();
    try {
      const client: StatusRefreshClient = {
        refreshStatus: vi.fn().mockResolvedValue(fullReconcileDeltaResponse()),
      };
      const store = fakeStatusSnapshotStore();
      const projection = fakeSourceControlProjectionService();
      projection.applyDelta.mockImplementation(() => {
        throw new Error("projection failed");
      });
      const scheduler = new StatusRefreshScheduler(client, store, projection, {
        debounceMs: 10,
      });
      scheduler.registerRepository(scope);
      scheduler.recordFileEvent("repo-uuid:C:/wc", {
        path: "C:/wc/src/main.c",
        kind: "change",
        timestamp: 100,
      });

      await expect(
        scheduler.fullReconcileRepository({ repositoryId: "repo-uuid:C:/wc", epoch: 7 }),
      ).rejects.toThrow("projection failed");
      await scheduler.flushRepository("repo-uuid:C:/wc");

      expect(client.refreshStatus).toHaveBeenCalledTimes(1);
      expect(projection.replaceSnapshot).toHaveBeenCalledTimes(1);
      expect(projection.replaceSnapshot).toHaveBeenCalledWith(store.getSnapshot("repo-uuid:C:/wc"));
    } finally {
      vi.useRealTimers();
    }
  });
});

function fakeStatusSnapshotStore(
  options: { calls?: string[]; snapshot?: ReturnType<StatusSnapshotStore["getSnapshot"]> } = {},
): Pick<
  StatusSnapshotStore,
  "applyDelta" | "getSnapshot" | "markStale"
> & {
  applyDelta: ReturnType<typeof vi.fn<(delta: StatusDelta) => ReturnType<StatusSnapshotStore["applyDelta"]>>>;
  getSnapshot: ReturnType<typeof vi.fn<StatusSnapshotStore["getSnapshot"]>>;
  markStale: ReturnType<typeof vi.fn<StatusSnapshotStore["markStale"]>>;
} {
  const defaultSnapshot = {
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
      localChanges: 1,
      remoteChanges: 0,
      conflicts: 0,
      unversioned: 0,
    },
    timestamp: "2026-06-22T00:00:00Z",
    source: "libsvn-local",
  };
  let snapshot = "snapshot" in options ? options.snapshot : defaultSnapshot;
  return {
    applyDelta: vi.fn<(delta: StatusDelta) => ReturnType<StatusSnapshotStore["applyDelta"]>>((delta) => {
      options.calls?.push("status-delta");
      const base = snapshot ?? defaultSnapshot;
      snapshot = {
        ...base,
        repositoryId: delta.repositoryId,
        epoch: delta.epoch,
        generation: delta.generation,
        completeness: delta.completeness,
        localEntries: delta.upsert,
        remoteEntries: delta.remoteUpsert,
        summary: {
          localChanges: base.summary.localChanges + delta.summaryDelta.localChanges,
          remoteChanges: base.summary.remoteChanges + delta.summaryDelta.remoteChanges,
          conflicts: base.summary.conflicts + delta.summaryDelta.conflicts,
          unversioned: base.summary.unversioned + delta.summaryDelta.unversioned,
        },
        timestamp: delta.timestamp,
        source: delta.source,
      };
      return snapshot;
    }),
    getSnapshot: vi.fn(() => snapshot),
    markStale: vi.fn((mark) => {
      options.calls?.push("status-stale");
      const base = snapshot ?? defaultSnapshot;
      snapshot = {
        ...base,
        epoch: mark.epoch,
        completeness: "stale",
        timestamp: mark.timestamp,
        source: mark.source,
      };
      return snapshot;
    }),
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

function fakeSourceControlProjectionService(
  options: { calls?: string[]; projection?: ReturnType<SourceControlProjectionService["getProjection"]> } = {},
): Pick<
  SourceControlProjectionService,
  "applyDelta" | "getProjection" | "markStale" | "replaceSnapshot"
> & {
  applyDelta: ReturnType<typeof vi.fn<(delta: StatusDelta) => ReturnType<SourceControlProjectionService["applyDelta"]>>>;
  getProjection: ReturnType<typeof vi.fn<SourceControlProjectionService["getProjection"]>>;
  markStale: ReturnType<typeof vi.fn<SourceControlProjectionService["markStale"]>>;
  replaceSnapshot: ReturnType<typeof vi.fn<SourceControlProjectionService["replaceSnapshot"]>>;
} {
  const defaultProjection = {
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
  let projection = "projection" in options ? options.projection : defaultProjection;
  return {
    applyDelta: vi.fn<(delta: StatusDelta) => ReturnType<SourceControlProjectionService["applyDelta"]>>((delta) => {
      options.calls?.push("projection-delta");
      const nextProjection: ReturnType<SourceControlProjectionService["applyDelta"]> = {
        ...(projection ?? defaultProjection),
        repositoryId: delta.repositoryId,
        epoch: delta.epoch,
        generation: delta.generation,
        freshness: {
          repositoryCompleteness: "complete" as const,
          lastRefreshCompleteness: delta.completeness,
          lastRefreshKind: "delta" as const,
        },
      };
      projection = nextProjection;
      return nextProjection;
    }),
    getProjection: vi.fn(() => projection),
    markStale: vi.fn((mark) => {
      options.calls?.push("projection-stale");
      const nextProjection: ReturnType<SourceControlProjectionService["markStale"]> = {
        ...(projection ?? defaultProjection),
        freshness: {
          repositoryCompleteness: "stale" as const,
          lastRefreshCompleteness: "stale" as const,
          lastRefreshKind: "stale" as const,
        },
        epoch: mark.epoch,
      };
      projection = nextProjection;
      return nextProjection;
    }),
    replaceSnapshot: vi.fn<SourceControlProjectionService["replaceSnapshot"]>((snapshot) => {
      options.calls?.push("projection-snapshot");
      const nextProjection: ReturnType<SourceControlProjectionService["replaceSnapshot"]> = {
        ...(projection ?? defaultProjection),
        repositoryId: snapshot.repositoryId,
        epoch: snapshot.epoch,
        workingCopyRoot: snapshot.identity.workingCopyRoot,
        generation: snapshot.generation,
        count: snapshot.summary.localChanges + snapshot.summary.conflicts,
        freshness: {
          repositoryCompleteness: snapshot.completeness,
          lastRefreshCompleteness: snapshot.completeness,
          lastRefreshKind: "snapshot" as const,
        },
      };
      projection = nextProjection;
      return nextProjection;
    }),
  };
}

function deltaResponse(options: { generation?: number } = {}): StatusDelta {
  const generation = options.generation ?? 11;
  return {
    repositoryId: "repo-uuid:C:/wc",
    epoch: 7,
    generation,
    coverage: [{ path: "src/main.c", depth: "empty", generation, reason: "fileChanged" }],
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

function deltaResponseFromRequest(request: StatusRefreshRequest): StatusDelta {
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

function fullReconcileDeltaResponse(
  options: {
    generation?: number;
    completeness?: StatusDelta["completeness"];
    coverage?: StatusDelta["coverage"];
  } = {},
): StatusDelta {
  const generation = options.generation ?? 12;
  return {
    repositoryId: "repo-uuid:C:/wc",
    epoch: 7,
    generation,
    coverage: options.coverage ?? [{ path: ".", depth: "infinity", generation, reason: "manualFullReconcile" }],
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
    completeness: options.completeness ?? "complete",
    timestamp: "2026-06-22T00:00:00Z",
    source: "libsvn-local",
  };
}

function scheduledFullReconcileDeltaResponse(
  options: {
    generation?: number;
    completeness?: StatusDelta["completeness"];
    coverage?: StatusDelta["coverage"];
  } = {},
): StatusDelta {
  const generation = options.generation ?? 12;
  return fullReconcileDeltaResponse({
    ...options,
    generation,
    coverage: options.coverage ?? [{ path: ".", depth: "infinity", generation, reason: "scheduledFullReconcile" }],
  });
}

async function flushMicrotasks(): Promise<void> {
  await new Promise<void>((resolve) => setImmediate(resolve));
}
