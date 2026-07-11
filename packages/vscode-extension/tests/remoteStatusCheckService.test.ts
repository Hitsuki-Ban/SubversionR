import { describe, expect, it, vi } from "vitest";
import { RemoteStatusCheckService } from "../src/status/remoteStatusCheckService";
import type { StatusDelta } from "../src/status/statusRefreshRpcClient";

describe("RemoteStatusCheckService", () => {
  it("applies the remote delta to canonical state and projection and returns the final total", async () => {
    const delta = {} as StatusDelta;
    const client = { checkRemoteStatus: vi.fn().mockResolvedValue(delta) };
    const snapshot = { summary: { remoteChanges: 3 } };
    const statusSnapshotStore = {
      applyDelta: vi.fn().mockReturnValue(snapshot),
    };
    const sourceControlProjection = {
      applyDelta: vi.fn(),
      replaceSnapshot: vi.fn(),
    };
    const refreshPipeline = {
      runExclusive: vi.fn(async (_repositoryId: string, operation: () => Promise<number>) => await operation()),
    };
    const service = new RemoteStatusCheckService({
      client,
      statusSnapshotStore: statusSnapshotStore as never,
      sourceControlProjection: sourceControlProjection as never,
      refreshPipeline: refreshPipeline as never,
    });

    await expect(service.checkRemoteChanges({ repositoryId: "repo", epoch: 2 })).resolves.toBe(3);
    expect(statusSnapshotStore.applyDelta).toHaveBeenCalledWith(delta);
    expect(sourceControlProjection.applyDelta).toHaveBeenCalledWith(delta);
    expect(refreshPipeline.runExclusive).toHaveBeenCalledWith("repo", expect.any(Function));
  });

  it("rebuilds projection from canonical state if projection application fails", async () => {
    const delta = {} as StatusDelta;
    const snapshot = { summary: { remoteChanges: 1 } };
    const failure = new Error("projection failed");
    const sourceControlProjection = {
      applyDelta: vi.fn().mockImplementation(() => { throw failure; }),
      replaceSnapshot: vi.fn(),
    };
    const service = new RemoteStatusCheckService({
      client: { checkRemoteStatus: vi.fn().mockResolvedValue(delta) },
      statusSnapshotStore: { applyDelta: vi.fn().mockReturnValue(snapshot) } as never,
      sourceControlProjection: sourceControlProjection as never,
      refreshPipeline: {
        runExclusive: vi.fn(async (_repositoryId: string, operation: () => Promise<number>) => await operation()),
      } as never,
    });

    await expect(service.checkRemoteChanges({ repositoryId: "repo", epoch: 2 })).rejects.toBe(failure);
    expect(sourceControlProjection.replaceSnapshot).toHaveBeenCalledWith(snapshot);
  });
});
