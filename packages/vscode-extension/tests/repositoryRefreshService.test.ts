import { describe, expect, it, vi } from "vitest";
import { RepositoryRefreshService } from "../src/status/repositoryRefreshService";

describe("RepositoryRefreshService", () => {
  it("flushes pending dirty paths through the dirty-path pipeline", async () => {
    const dirtyPathPipeline = fakeDirtyPathPipeline();
    const service = refreshService({ dirtyPathPipeline });

    await service.refreshRepository("repo-uuid:C:/wc");

    expect(dirtyPathPipeline.flushRepository).toHaveBeenCalledWith("repo-uuid:C:/wc");
  });

  it("passes refresh cancellation options through to the dirty-path pipeline", async () => {
    const dirtyPathPipeline = fakeDirtyPathPipeline();
    const service = refreshService({ dirtyPathPipeline });
    const cancellation = new AbortController();

    await service.refreshRepository("repo-uuid:C:/wc", { signal: cancellation.signal });

    expect(dirtyPathPipeline.flushRepository).toHaveBeenCalledWith(
      "repo-uuid:C:/wc",
      { signal: cancellation.signal },
    );
  });

  it("delegates full reconcile to the dirty-path pipeline", async () => {
    const dirtyPathPipeline = fakeDirtyPathPipeline();
    const service = refreshService({ dirtyPathPipeline });

    await service.fullReconcileRepository({ repositoryId: "repo-uuid:C:/wc", epoch: 7 });

    expect(dirtyPathPipeline.fullReconcileRepository).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
    });
  });

  it("passes full reconcile cancellation options through to the dirty-path pipeline", async () => {
    const dirtyPathPipeline = fakeDirtyPathPipeline();
    const service = refreshService({ dirtyPathPipeline });
    const cancellation = new AbortController();

    await service.fullReconcileRepository(
      { repositoryId: "repo-uuid:C:/wc", epoch: 7 },
      { signal: cancellation.signal },
    );

    expect(dirtyPathPipeline.fullReconcileRepository).toHaveBeenCalledWith(
      {
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
      },
      { signal: cancellation.signal },
    );
  });

  it("delegates explicit resource refresh to the dirty-path pipeline", async () => {
    const dirtyPathPipeline = fakeDirtyPathPipeline();
    const service = refreshService({ dirtyPathPipeline });

    await service.refreshResource({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src/main.c",
    });

    expect(dirtyPathPipeline.refreshResource).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src/main.c",
    });
  });

  it("delegates explicit target refresh to the dirty-path pipeline", async () => {
    const dirtyPathPipeline = fakeDirtyPathPipeline();
    const service = refreshService({ dirtyPathPipeline });

    await service.refreshTargets({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      targets: [{ path: "src/main.c", depth: "empty", reason: "operationRevert" }],
    });

    expect(dirtyPathPipeline.refreshTargets).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      targets: [{ path: "src/main.c", depth: "empty", reason: "operationRevert" }],
    });
  });

  it("passes explicit target refresh cancellation options through to the dirty-path pipeline", async () => {
    const dirtyPathPipeline = fakeDirtyPathPipeline();
    const service = refreshService({ dirtyPathPipeline });
    const cancellation = new AbortController();

    await service.refreshTargets(
      {
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        targets: [{ path: ".", depth: "infinity", reason: "manualRemoteCheck" }],
      },
      { signal: cancellation.signal },
    );

    expect(dirtyPathPipeline.refreshTargets).toHaveBeenCalledWith(
      {
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        targets: [{ path: ".", depth: "infinity", reason: "manualRemoteCheck" }],
      },
      { signal: cancellation.signal },
    );
  });
});

function refreshService(deps: {
  dirtyPathPipeline?: ReturnType<typeof fakeDirtyPathPipeline>;
} = {}): RepositoryRefreshService {
  return new RepositoryRefreshService({
    dirtyPathPipeline: deps.dirtyPathPipeline ?? fakeDirtyPathPipeline(),
  });
}

function fakeDirtyPathPipeline(): {
  flushRepository: ReturnType<typeof vi.fn<(repositoryId: string, options?: { signal?: AbortSignal }) => Promise<void>>>;
  fullReconcileRepository: ReturnType<
    typeof vi.fn<(target: { repositoryId: string; epoch: number }, options?: { signal?: AbortSignal }) => Promise<void>>
  >;
  refreshResource: ReturnType<
    typeof vi.fn<(target: { repositoryId: string; epoch: number; path: string }) => Promise<void>>
  >;
  refreshTargets: ReturnType<
    typeof vi.fn<
      (target: {
        repositoryId: string;
        epoch: number;
        targets: Array<{ path: string; depth: string; reason: string }>;
      }, options?: { signal?: AbortSignal }) => Promise<void>
    >
  >;
} {
  return {
    flushRepository: vi.fn<(repositoryId: string, options?: { signal?: AbortSignal }) => Promise<void>>()
      .mockResolvedValue(undefined),
    fullReconcileRepository: vi
      .fn<(target: { repositoryId: string; epoch: number }, options?: { signal?: AbortSignal }) => Promise<void>>()
      .mockResolvedValue(undefined),
    refreshResource: vi
      .fn<(target: { repositoryId: string; epoch: number; path: string }) => Promise<void>>()
      .mockResolvedValue(undefined),
    refreshTargets: vi
      .fn<
        (target: {
          repositoryId: string;
          epoch: number;
          targets: Array<{ path: string; depth: string; reason: string }>;
        }, options?: { signal?: AbortSignal }) => Promise<void>
      >()
      .mockResolvedValue(undefined),
  };
}
