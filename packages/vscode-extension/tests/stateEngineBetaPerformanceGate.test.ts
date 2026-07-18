import { afterAll, describe, expect, it, vi } from "vitest";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { performance } from "node:perf_hooks";
import { SourceControlProjectionService, type SourceControlProjectionPresenter } from "../src/scm/sourceControlProjectionService";
import { SourceControlResourceStore } from "../src/scm/sourceControlResourceStore";
import { DirtyPathPipeline } from "../src/status/dirtyPathPipeline";
import { StatusRefreshScheduler } from "../src/status/statusRefreshScheduler";
import type { StatusDelta } from "../src/status/statusRefreshRpcClient";
import type { StatusEntry, StatusSnapshot } from "../src/status/statusSnapshotRpcClient";
import { StatusSnapshotStore, type StatusStaleMark } from "../src/status/statusSnapshotStore";
import type { RepositoryWatchScope, StatusRefreshClient, StatusRefreshRequest } from "../src/status/types";
import { RepositoryLifecycleCoordinator } from "../src/repository/repositoryLifecycleCoordinator";
import type { RepositoryLifecycleEvent } from "../src/repository/repositoryLifecycleService";

const TARGET = process.env.SUBVERSIONR_STATE_ENGINE_BETA_PERFORMANCE_TARGET ?? "win32-x64";
const FIXTURE_ROOT = process.env.SUBVERSIONR_STATE_ENGINE_BETA_PERFORMANCE_FIXTURE_ROOT;
const TEN_THOUSAND_LOCAL_RESOURCES = 10_000;
const MAX_PROJECTION_MS = parsePositiveIntegerEnv(
  "SUBVERSIONR_STATE_ENGINE_BETA_PERFORMANCE_MAX_PROJECTION_MS",
  10_000,
);
const MAX_BURST_REFRESH_TARGETS = 128;

const scope: RepositoryWatchScope = {
  repositoryId: "repo-uuid:C:/wc",
  epoch: 7,
  workingCopyRoot: "C:/wc",
  pathCase: "case-insensitive",
};

const assertions: Record<string, unknown> = {};

describe("state engine Beta performance gate", () => {
  it("keeps a single-file save on the targeted dirty-path refresh path without full scan", async () => {
    const requests: StatusRefreshRequest[] = [];
    const pipeline = new DirtyPathPipeline(refreshClient(requests), statusStore(), projectionService(), {
      debounceMs: 10,
      maxDirtyPaths: MAX_BURST_REFRESH_TARGETS,
    });
    pipeline.registerRepository(scope);

    const accepted = pipeline.accept(scope.repositoryId, {
      fsPath: "C:/wc/src/main.c",
      kind: "changed",
      timestamp: 100,
    });
    await pipeline.flushRepository(scope.repositoryId);

    expect(accepted).toBe(true);
    expect(requests).toEqual([
      {
        repositoryId: scope.repositoryId,
        epoch: scope.epoch,
        targets: [{ path: "src/main.c", depth: "empty", reason: "fileChanged" }],
      },
    ]);
    expect(requests.flatMap((request) => request.targets)).not.toContainEqual({
      path: ".",
      depth: "infinity",
      reason: "manualFullReconcile",
    });
    expect(requests.flatMap((request) => request.targets)).not.toContainEqual({
      path: ".",
      depth: "infinity",
      reason: "scheduledFullReconcile",
    });

    assertions.singleFileSaveNoFullScan = {
      accepted,
      refreshRequestCount: requests.length,
      targets: requests[0]?.targets,
      rootInfinityTargetCount: requests
        .flatMap((request) => request.targets)
        .filter((target) => target.path === "." && target.depth === "infinity").length,
    };
  });

  it("folds a large same-directory event burst into a bounded refresh request", async () => {
    const requests: StatusRefreshRequest[] = [];
    const pipeline = new DirtyPathPipeline(refreshClient(requests), statusStore(), projectionService(), {
      debounceMs: 10,
      maxDirtyPaths: MAX_BURST_REFRESH_TARGETS,
    });
    pipeline.registerRepository(scope);

    for (let index = 0; index < TEN_THOUSAND_LOCAL_RESOURCES; index += 1) {
      pipeline.accept(scope.repositoryId, {
        fsPath: `C:/wc/generated/file-${index.toString().padStart(5, "0")}.txt`,
        kind: "changed",
        timestamp: 1_000 + index,
      });
    }

    await pipeline.flushRepository(scope.repositoryId);

    const targets = requests[0]?.targets ?? [];
    expect(requests).toHaveLength(1);
    expect(targets.length).toBeLessThanOrEqual(MAX_BURST_REFRESH_TARGETS);
    expect(targets).toEqual([{ path: "generated", depth: "files", reason: "dirtyPathFold" }]);

    assertions.eventBurstBounded = {
      inputEventCount: TEN_THOUSAND_LOCAL_RESOURCES,
      maxRefreshTargets: MAX_BURST_REFRESH_TARGETS,
      actualRefreshTargets: targets.length,
      targets,
    };
  });

  it("isolates nested working-copy and external boundary events from the parent provider", async () => {
    const requests: StatusRefreshRequest[] = [];
    const childScope: RepositoryWatchScope = {
      repositoryId: "external-repo-uuid:C:/wc/vendor/external",
      epoch: 3,
      workingCopyRoot: "C:/wc/vendor/external",
      pathCase: "case-insensitive",
    };
    const pipeline = new DirtyPathPipeline(
      refreshClient(requests),
      statusStore(repository(), repositoryFromScope(childScope)),
      projectionService(repository(), repositoryFromScope(childScope)),
      {
        debounceMs: 10,
      },
    );
    pipeline.registerRepository({
      ...scope,
      boundaryRoots: [childScope.workingCopyRoot],
    });
    pipeline.registerRepository(childScope);

    const parentAccepted = pipeline.accept(scope.repositoryId, {
      fsPath: "C:/wc/src/parent.c",
      kind: "changed",
      timestamp: 100,
    });
    const boundaryAcceptedByParent = pipeline.accept(scope.repositoryId, {
      fsPath: "C:/wc/vendor/external/child.c",
      kind: "changed",
      timestamp: 101,
    });
    const boundaryAcceptedByChild = pipeline.accept(childScope.repositoryId, {
      fsPath: "C:/wc/vendor/external/child.c",
      kind: "changed",
      timestamp: 102,
    });

    await pipeline.flushRepository(scope.repositoryId);
    await pipeline.flushRepository(childScope.repositoryId);

    expect(parentAccepted).toBe(true);
    expect(boundaryAcceptedByParent).toBe(false);
    expect(boundaryAcceptedByChild).toBe(true);
    expect(requests).toEqual([
      {
        repositoryId: scope.repositoryId,
        epoch: scope.epoch,
        targets: [{ path: "src/parent.c", depth: "empty", reason: "fileChanged" }],
      },
      {
        repositoryId: childScope.repositoryId,
        epoch: childScope.epoch,
        targets: [{ path: "child.c", depth: "empty", reason: "fileChanged" }],
      },
    ]);

    assertions.nestedExternalBoundaryIsolation = {
      parentAccepted,
      boundaryAcceptedByParent,
      boundaryAcceptedByChild,
      parentTargets: requests[0]?.targets,
      childTargets: requests[1]?.targets,
    };
  });

  it("cancels stale dirty-generation refreshes and requeues old plus new targets", async () => {
    const requests: StatusRefreshRequest[] = [];
    const pendingRefreshes: Array<{
      request: StatusRefreshRequest;
      signal: AbortSignal | undefined;
      resolve(delta: StatusDelta): void;
      reject(error: Error): void;
    }> = [];
    const staleMarks: StatusStaleMark[] = [];
    const store = statusStore();
    const projection = projectionService();
    const scheduler = new StatusRefreshScheduler(
      {
        refreshStatus: vi.fn((request, options) => {
          requests.push(request);
          return new Promise<StatusDelta>((resolve, reject) => {
            pendingRefreshes.push({ request, signal: options?.signal, resolve, reject });
            options?.signal?.addEventListener("abort", () => reject(new Error("refresh aborted")));
          });
        }),
      },
      {
        applyDelta: (delta) => store.applyDelta(delta),
        getSnapshot: (repositoryId) => store.getSnapshot(repositoryId),
        markStale: (mark) => {
          staleMarks.push(mark);
          return store.markStale(mark);
        },
      },
      projection,
      { debounceMs: 10_000 },
    );
    scheduler.registerRepository(scope);
    scheduler.recordFileEvent(scope.repositoryId, {
      path: "C:/wc/src/first.c",
      kind: "change",
      timestamp: Date.UTC(2026, 5, 28, 0, 0, 0),
    });

    const firstFlush = scheduler.flushRepository(scope.repositoryId);
    await flushMicrotasks();
    scheduler.recordFileEvent(scope.repositoryId, {
      path: "C:/wc/src/second.c",
      kind: "change",
      timestamp: Date.UTC(2026, 5, 28, 0, 0, 1),
    });

    expect(pendingRefreshes[0]?.signal?.aborted).toBe(true);
    await expect(firstFlush).rejects.toMatchObject({
      code: "SUBVERSIONR_STATUS_REFRESH_CANCELLED",
      safeArgs: { reason: "dirtyGenerationSuperseded" },
    });

    const secondFlush = scheduler.flushRepository(scope.repositoryId);
    await flushMicrotasks();
    expect(pendingRefreshes[1]?.request).toEqual({
      repositoryId: scope.repositoryId,
      epoch: scope.epoch,
      targets: [
        { path: "src/first.c", depth: "empty", reason: "fileChanged" },
        { path: "src/second.c", depth: "empty", reason: "fileChanged" },
      ],
    });
    pendingRefreshes[1]?.resolve(deltaResponseFromRequest(pendingRefreshes[1].request, 12));
    await secondFlush;

    expect(staleMarks).toEqual([
      {
        repositoryId: scope.repositoryId,
        epoch: scope.epoch,
        reason: "refreshCancelled",
        timestamp: "2026-06-28T00:00:01.000Z",
        source: "vscode-status-scheduler",
      },
    ]);
    expect(store.getSnapshot(scope.repositoryId)?.generation).toBe(12);
    expect(projection.getProjection(scope.repositoryId)?.generation).toBe(12);

    assertions.dirtyGenerationSupersede = {
      firstSignalAborted: pendingRefreshes[0]?.signal?.aborted,
      staleMarkReason: staleMarks[0]?.reason,
      secondTargets: pendingRefreshes[1]?.request.targets,
      completedGeneration: store.getSnapshot(scope.repositoryId)?.generation,
    };
  });

  it("marks state stale and reopens sessions explicitly after a sidecar restart", async () => {
    const store = statusStore();
    const projection = projectionService();
    const mark: StatusStaleMark = {
      repositoryId: scope.repositoryId,
      epoch: scope.epoch,
      reason: "backendRestart",
      timestamp: "2026-06-28T01:00:00.000Z",
      source: "backend-lifecycle",
    };
    const reopened: RepositoryLifecycleEvent[] = [
      {
        kind: "openSessionReopened",
        trigger: "backendRestart",
        repositoryId: scope.repositoryId,
        previousEpoch: scope.epoch,
        epoch: scope.epoch + 1,
        workingCopyRoot: scope.workingCopyRoot,
      },
    ];
    const lifecycleCalls: string[] = [];
    const coordinator = new RepositoryLifecycleCoordinator({
      lifecycleService: {
        recoverMovedRepositories: async () => [],
        closeDisappearedRepositories: async () => [],
        autoOpenWorkspaceRepositories: async (trigger) => ({
          kind: "autoOpenSkipped",
          trigger,
          reason: "noCandidates",
          candidateCount: 0,
        }),
        reopenBackendRestartedRepositories: async () => {
          lifecycleCalls.push("reopen");
          return reopened;
        },
      },
      sessionService: {
        markOpenSessionsStale: (request) => {
          lifecycleCalls.push(`stale:${request.reason}`);
          store.markStale(mark);
          projection.markStale(mark);
        },
      },
      now: () => mark.timestamp,
      onBackendRestartStaleFailure: async () => undefined,
    });

    const events = await coordinator.recoverBackendRestartedRepositories();

    expect(lifecycleCalls).toEqual(["stale:backendConnectionLost", "reopen"]);
    expect(events).toEqual(reopened);
    expect(store.getSnapshot(scope.repositoryId)?.completeness).toBe("stale");
    expect(projection.getProjection(scope.repositoryId)?.freshness).toEqual({
      repositoryCompleteness: "stale",
      lastRefreshCompleteness: "stale",
      lastRefreshKind: "stale",
    });

    assertions.sidecarRestartRecovery = {
      lifecycleCalls,
      reopenedCount: events.length,
      statusCompleteness: store.getSnapshot(scope.repositoryId)?.completeness,
      projectionFreshness: projection.getProjection(scope.repositoryId)?.freshness,
    };
  });

  it("projects a 10k local working-copy snapshot within the Beta baseline", () => {
    const store = new SourceControlResourceStore({
      countPolicy: {
        countUnversioned: false,
        ignoreChangelistsInCount: ["ignore-on-commit"],
      },
    });
    store.registerRepository(repository());
    const entries = Array.from({ length: TEN_THOUSAND_LOCAL_RESOURCES }, (_value, index) =>
      largeFixtureEntry(index),
    );

    const startedAt = performance.now();
    const projection = store.applySnapshot(
      snapshotResponse({
        localEntries: entries,
        summary: {
          localChanges: TEN_THOUSAND_LOCAL_RESOURCES,
          remoteChanges: 0,
          conflicts: 0,
          unversioned: 0,
        },
      }),
    );
    const elapsedMs = Math.round((performance.now() - startedAt) * 100) / 100;

    expect(projection.groups.find((group) => group.id === "changes")?.resources).toHaveLength(8_000);
    expect(projection.groups.find((group) => group.id === "unversioned")?.resources).toHaveLength(1_000);
    expect(projection.groups.find((group) => group.id === "externals")?.resources).toHaveLength(500);
    expect(projection.groups.find((group) => group.id === "ignored")?.resources).toHaveLength(500);
    expect(projection.count).toBe(8_000);
    expect(store.getProjectedResource(scope.repositoryId, "SRC/MODIFIED-007999.C", "case-insensitive")?.resource.path).toBe(
      "src/modified-007999.c",
    );
    expect(elapsedMs).toBeLessThanOrEqual(MAX_PROJECTION_MS);

    assertions.tenThousandWorkingCopyProjection = {
      localEntryCount: entries.length,
      projectedChangeCount: projection.groups.find((group) => group.id === "changes")?.resources.length,
      projectedUnversionedCount: projection.groups.find((group) => group.id === "unversioned")?.resources.length,
      projectedExternalCount: projection.groups.find((group) => group.id === "externals")?.resources.length,
      projectedIgnoredCount: projection.groups.find((group) => group.id === "ignored")?.resources.length,
      badgeCount: projection.count,
      elapsedMs,
      maxProjectionMs: MAX_PROJECTION_MS,
    };
  });
});

afterAll(() => {
  const evidencePath = process.env.SUBVERSIONR_STATE_ENGINE_BETA_PERFORMANCE_EVIDENCE_PATH;
  if (!evidencePath) {
    return;
  }

  mkdirSync(dirname(evidencePath), { recursive: true });
  writeFileSync(
    evidencePath,
    `${JSON.stringify({
      schema: `subversionr.release.state-engine-beta-performance.${TARGET}.v1`,
      publicReadinessClaim: false,
      target: TARGET,
      generatedAt: new Date().toISOString(),
      source: "packages/vscode-extension/tests/stateEngineBetaPerformanceGate.test.ts",
      fixtureRoots: {
        stateEngineBetaPerformance: FIXTURE_ROOT ?? null,
      },
      workingCopyMutation: "none",
      traceIds: [
        "PRD-006",
        "REP-005",
        "STA-001",
        "STA-012",
        "STA-014",
        "ARC-011",
        "DIR-002",
        "DIR-004",
        "DIR-006",
        "DIR-007",
        "DIR-009",
        "DIR-010",
        "DIR-011",
        "DIR-012",
        "DIR-013",
        "DIR-020",
        "OBS-004",
        "TST-024",
      ],
      thresholds: {
        tenThousandLocalResourceCount: TEN_THOUSAND_LOCAL_RESOURCES,
        maxProjectionMs: MAX_PROJECTION_MS,
        maxBurstRefreshTargets: MAX_BURST_REFRESH_TARGETS,
      },
      assertions,
      nonClaims: [
        "No 100k or 1M working-copy performance claim.",
        "No native watcher v2 or platform-wide file watcher replacement claim.",
        "No default background remote polling claim.",
        "No public Marketplace release, signing, provenance, or previous-stable rollback claim.",
      ],
    }, null, 2)}\n`,
    "utf8",
  );
});

function refreshClient(requests: StatusRefreshRequest[]): StatusRefreshClient {
  return {
    refreshStatus: vi.fn(async (request) => {
      requests.push(request);
      return deltaResponseFromRequest(request);
    }),
  };
}

function statusStore(...repositories: Array<ReturnType<typeof repository>>): StatusSnapshotStore {
  const store = new StatusSnapshotStore();
  const registeredRepositories = repositories.length > 0 ? repositories : [repository()];
  for (const registeredRepository of registeredRepositories) {
    store.registerRepository(registeredRepository);
    store.applySnapshot(snapshotResponseFromRepository(registeredRepository));
  }
  return store;
}

function projectionService(...repositories: Array<ReturnType<typeof repository>>): SourceControlProjectionService {
  const service = new SourceControlProjectionService(
    new SourceControlResourceStore({
      countPolicy: {
        countUnversioned: false,
        ignoreChangelistsInCount: ["ignore-on-commit"],
      },
    }),
    fakePresenter(),
  );
  const registeredRepositories = repositories.length > 0 ? repositories : [repository()];
  for (const registeredRepository of registeredRepositories) {
    service.registerRepository(registeredRepository);
    service.applySnapshot(snapshotResponseFromRepository(registeredRepository));
  }
  return service;
}

function fakePresenter(): SourceControlProjectionPresenter {
  return {
    registerRepository: vi.fn(),
    updateRepository: vi.fn(),
    updateRemoteConnectionState: vi.fn(),
    unregisterRepository: vi.fn(),
    isCurrentResourceState: vi.fn(() => false),
  };
}

function repository() {
  return {
    repositoryId: scope.repositoryId,
    epoch: scope.epoch,
    workingCopyRoot: scope.workingCopyRoot,
  };
}

function repositoryFromScope(watchScope: RepositoryWatchScope): ReturnType<typeof repository> {
  return {
    repositoryId: watchScope.repositoryId,
    epoch: watchScope.epoch,
    workingCopyRoot: watchScope.workingCopyRoot,
  };
}

function snapshotResponseFromRepository(
  registeredRepository: ReturnType<typeof repository>,
  options: Partial<StatusSnapshot> = {},
): StatusSnapshot {
  return snapshotResponse({
    repositoryId: registeredRepository.repositoryId,
    epoch: registeredRepository.epoch,
    identity: {
      repositoryUuid: registeredRepository.repositoryId.split(":")[0] ?? registeredRepository.repositoryId,
      repositoryRootUrl: "file:///C:/repo",
      workingCopyRoot: registeredRepository.workingCopyRoot,
      workspaceScopeRoot: "C:/workspace",
      format: 31,
    },
    ...options,
  });
}

function snapshotResponse(options: Partial<StatusSnapshot> = {}): StatusSnapshot {
  return {
    repositoryId: scope.repositoryId,
    epoch: scope.epoch,
    generation: 11,
    completeness: "complete",
    identity: {
      repositoryUuid: "repo-uuid",
      repositoryRootUrl: "file:///C:/repo",
      workingCopyRoot: scope.workingCopyRoot,
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
    timestamp: "2026-06-28T00:00:00.000Z",
    source: "libsvn-local",
    ...options,
  };
}

function deltaResponseFromRequest(request: StatusRefreshRequest, generation = 12): StatusDelta {
  return {
    repositoryId: request.repositoryId,
    epoch: request.epoch,
    generation,
    coverage: request.targets.map((target) => ({
      path: target.path,
      depth: target.depth,
      generation,
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
    timestamp: "2026-06-28T00:00:02.000Z",
    source: "libsvn-local",
  };
}

function largeFixtureEntry(index: number): StatusEntry {
  if (index < 8_000) {
    return statusEntry({
      path: `src/modified-${index.toString().padStart(6, "0")}.c`,
      localStatus: "modified",
    });
  }
  if (index < 9_000) {
    return statusEntry({
      path: `scratch/unversioned-${index.toString().padStart(6, "0")}.txt`,
      localStatus: "unversioned",
    });
  }
  if (index < 9_500) {
    return statusEntry({
      path: `vendor/external-${index.toString().padStart(6, "0")}.c`,
      localStatus: "modified",
      external: true,
    });
  }
  return statusEntry({
    path: `target/ignored-${index.toString().padStart(6, "0")}.log`,
    localStatus: "ignored",
  });
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
    changedDate: "2026-06-28T00:00:00.000Z",
    changelist: null,
    lock: null,
    needsLock: false,
    copy: null,
    move: null,
    switched: false,
    depth: "infinity",
    conflict: null,
    conflictArtifacts: overrides.conflictArtifacts ?? [],
    external: false,
    generation: 11,
    ...overrides,
  };
}

function parsePositiveIntegerEnv(name: string, fallback: number): number {
  const rawValue = process.env[name];
  if (rawValue === undefined) {
    return fallback;
  }
  const value = Number(rawValue);
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new Error(`${name} must be a positive integer.`);
  }
  return value;
}

async function flushMicrotasks(): Promise<void> {
  await new Promise<void>((resolve) => setImmediate(resolve));
}
