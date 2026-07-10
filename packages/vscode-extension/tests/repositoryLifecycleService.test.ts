import { describe, expect, it, vi } from "vitest";
import {
  RepositoryLifecycleService,
  type RepositoryLifecycleEvent,
} from "../src/repository/repositoryLifecycleService";
import type {
  RepositoryDiscoveryCandidate,
  RepositoryDiscoveryResponse,
  RepositoryDiscoveryService,
} from "../src/repository/repositoryDiscoveryService";
import type {
  RepositorySession,
  RepositorySessionReopenResult,
  RepositorySessionService,
} from "../src/repository/repositorySessionService";
import type { PathCasePolicy } from "../src/status/types";

describe("RepositoryLifecycleService", () => {
  it("skips automatic discovery while the workspace is untrusted", async () => {
    const discoveryService = fakeDiscoveryService({ candidates: [discoveryCandidate()] });
    const events: RepositoryLifecycleEvent[] = [];
    const service = lifecycleService({
      discoveryService,
      workspaceTrusted: false,
      events,
    });

    const result = await service.autoOpenWorkspaceRepositories("activation");

    expect(result).toEqual({
      kind: "autoOpenSkipped",
      trigger: "activation",
      reason: "workspaceUntrusted",
    });
    expect(events).toEqual([result]);
    expect(discoveryService.discoverRepositories).not.toHaveBeenCalled();
    expect(discoveryService.openDiscoveredRepository).not.toHaveBeenCalled();
  });

  it("skips automatic discovery when no workspace folder is open", async () => {
    const discoveryService = fakeDiscoveryService({ candidates: [discoveryCandidate()] });
    const events: RepositoryLifecycleEvent[] = [];
    const service = lifecycleService({
      discoveryService,
      workspaceRoots: [],
      events,
    });

    const result = await service.autoOpenWorkspaceRepositories("activation");

    expect(result).toEqual({
      kind: "autoOpenSkipped",
      trigger: "activation",
      reason: "noWorkspaceRoots",
    });
    expect(events).toEqual([result]);
    expect(discoveryService.discoverRepositories).not.toHaveBeenCalled();
    expect(discoveryService.openDiscoveredRepository).not.toHaveBeenCalled();
  });

  it("opens the single unopened discovered working copy", async () => {
    const candidate = discoveryCandidate({ workingCopyRoot: "C:\\workspace" });
    const discoveryService = fakeDiscoveryService({ candidates: [candidate] });
    const events: RepositoryLifecycleEvent[] = [];
    const service = lifecycleService({
      discoveryService,
      workspaceRoots: ["C:\\workspace"],
      events,
    });

    const result = await service.autoOpenWorkspaceRepositories("activation");

    expect(discoveryService.discoverRepositories).toHaveBeenCalledWith({
      workspaceRoots: ["C:\\workspace"],
      discoverNested: true,
      discoveryDepth: 4,
      discoveryIgnore: [],
      ignoredRoots: [],
      externalsMode: "lazy",
    });
    expect(discoveryService.openDiscoveredRepository).toHaveBeenCalledWith({
      candidate,
      pathCase: "case-insensitive",
    });
    expect(result).toEqual({
      kind: "autoOpenOpened",
      trigger: "activation",
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      workingCopyRoot: "C:\\workspace",
    });
    expect(events).toEqual([result]);
  });

  it("passes open working copy roots to discovery and opens the remaining single unopened candidate", async () => {
    const alreadyOpen = discoveryCandidate({ workingCopyRoot: "C:\\workspace" });
    const unopened = discoveryCandidate({
      repositoryUuid: "other-repo",
      workingCopyRoot: "D:\\other-wc",
    });
    const discoveryService = fakeDiscoveryService({ candidates: [alreadyOpen, unopened] });
    const openSession = repositorySession({ workingCopyRoot: "C:\\workspace" });
    const service = lifecycleService({
      discoveryService,
      sessionService: fakeSessionService({ sessions: [openSession] }),
      workspaceRoots: ["C:\\workspace", "D:\\other-wc"],
    });

    const result = await service.autoOpenWorkspaceRepositories("workspaceFolders");

    expect(discoveryService.discoverRepositories).toHaveBeenCalledWith({
      workspaceRoots: ["C:\\workspace", "D:\\other-wc"],
      discoverNested: true,
      discoveryDepth: 4,
      discoveryIgnore: [],
      ignoredRoots: ["C:\\workspace"],
      externalsMode: "lazy",
    });
    expect(discoveryService.openDiscoveredRepository).toHaveBeenCalledWith({
      candidate: unopened,
      pathCase: "case-insensitive",
    });
    expect(result.kind).toBe("autoOpenOpened");
  });

  it("skips opening when discovery finds no working copies", async () => {
    const discoveryService = fakeDiscoveryService({ candidates: [] });
    const service = lifecycleService({
      discoveryService,
      workspaceRoots: ["C:\\workspace"],
    });

    const result = await service.autoOpenWorkspaceRepositories("activation");

    expect(result).toEqual({
      kind: "autoOpenSkipped",
      trigger: "activation",
      reason: "noCandidates",
      candidateCount: 0,
    });
    expect(discoveryService.openDiscoveredRepository).not.toHaveBeenCalled();
  });

  it("skips opening when all discovered working copies already have open sessions", async () => {
    const alreadyOpen = discoveryCandidate({ workingCopyRoot: "C:\\WORKSPACE" });
    const discoveryService = fakeDiscoveryService({ candidates: [alreadyOpen] });
    const service = lifecycleService({
      discoveryService,
      sessionService: fakeSessionService({
        sessions: [repositorySession({ workingCopyRoot: "C:\\workspace" })],
      }),
      workspaceRoots: ["C:\\workspace"],
    });

    const result = await service.autoOpenWorkspaceRepositories("activation");

    expect(result).toEqual({
      kind: "autoOpenSkipped",
      trigger: "activation",
      reason: "allCandidatesOpen",
      candidateCount: 1,
    });
    expect(discoveryService.openDiscoveredRepository).not.toHaveBeenCalled();
  });

  it("opens multiple independent unopened working copies discovered from a multi-root workspace", async () => {
    const first = discoveryCandidate({ workingCopyRoot: "C:\\workspace" });
    const second = discoveryCandidate({ repositoryUuid: "second-repo", workingCopyRoot: "D:\\other-wc" });
    const discoveryService = fakeDiscoveryService({ candidates: [first, second] });
    const events: RepositoryLifecycleEvent[] = [];
    const service = lifecycleService({
      discoveryService,
      workspaceRoots: ["C:\\workspace", "D:\\other-wc"],
      events,
    });

    const result = await service.autoOpenWorkspaceRepositories("workspaceFolders");

    expect(result).toEqual({
      kind: "autoOpenOpenedMany",
      trigger: "workspaceFolders",
      openedCount: 2,
      repositories: [
        {
          repositoryId: "repo-uuid:C:/workspace",
          epoch: 7,
          workingCopyRoot: "C:\\workspace",
        },
        {
          repositoryId: "second-repo:D:/other-wc",
          epoch: 7,
          workingCopyRoot: "D:\\other-wc",
        },
      ],
    });
    expect(discoveryService.openDiscoveredRepository).toHaveBeenCalledTimes(2);
    expect(discoveryService.openDiscoveredRepository).toHaveBeenNthCalledWith(1, {
      candidate: first,
      pathCase: "case-insensitive",
    });
    expect(discoveryService.openDiscoveredRepository).toHaveBeenNthCalledWith(2, {
      candidate: second,
      pathCase: "case-insensitive",
    });
    expect(events).toEqual([
      {
        kind: "autoOpenOpened",
        trigger: "workspaceFolders",
        repositoryId: "repo-uuid:C:/workspace",
        epoch: 7,
        workingCopyRoot: "C:\\workspace",
      },
      {
        kind: "autoOpenOpened",
        trigger: "workspaceFolders",
        repositoryId: "second-repo:D:/other-wc",
        epoch: 7,
        workingCopyRoot: "D:\\other-wc",
      },
      result,
    ]);
  });

  it("opens a parent automatic candidate with discovered nested roots as watcher boundaries", async () => {
    const parent = discoveryCandidate({ workingCopyRoot: "C:\\workspace" });
    const nested = discoveryCandidate(
      {
        repositoryUuid: "nested-repo",
        workingCopyRoot: "C:\\workspace\\vendor\\nested",
      },
      {
        isNested: true,
        parentWorkingCopyRoot: "C:\\workspace",
      },
    );
    const discoveryService = fakeDiscoveryService({ candidates: [parent, nested] });
    const events: RepositoryLifecycleEvent[] = [];
    const service = lifecycleService({
      discoveryService,
      workspaceRoots: ["C:\\workspace"],
      events,
    });

    const result = await service.autoOpenWorkspaceRepositories("activation");

    expect(discoveryService.openDiscoveredRepository).toHaveBeenCalledTimes(1);
    expect(discoveryService.openDiscoveredRepository).toHaveBeenCalledWith({
      candidate: parent,
      pathCase: "case-insensitive",
      boundaryRoots: ["C:\\workspace\\vendor\\nested"],
    });
    expect(result).toEqual({
      kind: "autoOpenOpened",
      trigger: "activation",
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      workingCopyRoot: "C:\\workspace",
    });
    expect(events).toEqual([result]);
  });

  it("opens a parent automatic candidate with already open child sessions as watcher boundaries", async () => {
    const parent = discoveryCandidate({ workingCopyRoot: "C:\\workspace" });
    const childSession = repositorySession({
      repositoryId: "nested-repo:C:/workspace/vendor/nested",
      workingCopyRoot: "C:\\workspace\\vendor\\nested",
    });
    const discoveryService = fakeDiscoveryService({ candidates: [parent] });
    const service = lifecycleService({
      discoveryService,
      sessionService: fakeSessionService({ sessions: [childSession] }),
      workspaceRoots: ["C:\\workspace"],
    });

    const result = await service.autoOpenWorkspaceRepositories("activation");

    expect(discoveryService.openDiscoveredRepository).toHaveBeenCalledTimes(1);
    expect(discoveryService.openDiscoveredRepository).toHaveBeenCalledWith({
      candidate: parent,
      pathCase: "case-insensitive",
      boundaryRoots: ["C:\\workspace\\vendor\\nested"],
    });
    expect(result.kind).toBe("autoOpenOpened");
  });

  it("opens a parent automatic candidate with discovered file external paths as watcher boundaries", async () => {
    const parent = discoveryCandidate({ workingCopyRoot: "C:\\workspace" });
    const discoveryService = fakeDiscoveryService({
      candidates: [parent],
      fileExternalBoundaries: ["C:\\workspace\\externals\\pinned.txt"],
    });
    const service = lifecycleService({
      discoveryService,
      workspaceRoots: ["C:\\workspace"],
    });

    const result = await service.autoOpenWorkspaceRepositories("activation");

    expect(discoveryService.openDiscoveredRepository).toHaveBeenCalledTimes(1);
    expect(discoveryService.openDiscoveredRepository).toHaveBeenCalledWith({
      candidate: parent,
      pathCase: "case-insensitive",
      boundaryRoots: ["C:\\workspace\\externals\\pinned.txt"],
    });
    expect(result.kind).toBe("autoOpenOpened");
  });

  it("opens only the nearest unopened nested parent when automatic discovery returns nested descendants", async () => {
    const openedParent = repositorySession({ workingCopyRoot: "C:\\workspace" });
    const nestedParent = discoveryCandidate(
      {
        repositoryUuid: "nested-parent-repo",
        workingCopyRoot: "C:\\workspace\\vendor",
      },
      {
        isNested: true,
        parentWorkingCopyRoot: "C:\\workspace",
      },
    );
    const nestedChild = discoveryCandidate(
      {
        repositoryUuid: "nested-child-repo",
        workingCopyRoot: "C:\\workspace\\vendor\\child",
      },
      {
        isNested: true,
        parentWorkingCopyRoot: "C:\\workspace\\vendor",
      },
    );
    const discoveryService = fakeDiscoveryService({ candidates: [nestedParent, nestedChild] });
    const service = lifecycleService({
      discoveryService,
      sessionService: fakeSessionService({ sessions: [openedParent] }),
      workspaceRoots: ["C:\\workspace"],
    });

    const result = await service.autoOpenWorkspaceRepositories("activation");

    expect(discoveryService.openDiscoveredRepository).toHaveBeenCalledTimes(1);
    expect(discoveryService.openDiscoveredRepository).toHaveBeenCalledWith({
      candidate: nestedParent,
      pathCase: "case-insensitive",
      boundaryRoots: ["C:\\workspace\\vendor\\child"],
    });
    expect(result).toEqual({
      kind: "autoOpenOpened",
      trigger: "activation",
      repositoryId: "nested-parent-repo:C:/workspace/vendor",
      epoch: 7,
      workingCopyRoot: "C:\\workspace\\vendor",
    });
  });

  it("reports discovery and open failures as lifecycle events", async () => {
    const discoveryService = fakeDiscoveryService(new CodedError("SUBVERSIONR_REPOSITORY_DISCOVERY_FAILED"));
    const events: RepositoryLifecycleEvent[] = [];
    const service = lifecycleService({
      discoveryService,
      workspaceRoots: ["C:\\workspace"],
      events,
    });

    const result = await service.autoOpenWorkspaceRepositories("activation");

    expect(result).toEqual({
      kind: "autoOpenFailed",
      trigger: "activation",
      code: "SUBVERSIONR_REPOSITORY_DISCOVERY_FAILED",
    });
    expect(events).toEqual([result]);
    expect(discoveryService.openDiscoveredRepository).not.toHaveBeenCalled();
  });

  it("skips overlapping automatic runs while a discovery request is already in flight", async () => {
    const candidate = discoveryCandidate({ workingCopyRoot: "C:\\workspace" });
    const discovery = deferred<RepositoryDiscoveryResponse>();
    const discoveryService = fakeControlledDiscoveryService(discovery.promise);
    const service = lifecycleService({
      discoveryService,
      workspaceRoots: ["C:\\workspace"],
    });

    const first = service.autoOpenWorkspaceRepositories("activation");
    const second = service.autoOpenWorkspaceRepositories("workspaceTrust");

    expect(discoveryService.discoverRepositories).toHaveBeenCalledTimes(1);
    discovery.resolve({ candidates: [candidate], fileExternalBoundaries: [] });
    await expect(second).resolves.toEqual({
      kind: "autoOpenSkipped",
      trigger: "workspaceTrust",
      reason: "alreadyRunning",
    });
    await expect(first).resolves.toEqual({
      kind: "autoOpenOpened",
      trigger: "activation",
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      workingCopyRoot: "C:\\workspace",
    });
    expect(discoveryService.openDiscoveredRepository).toHaveBeenCalledTimes(1);
  });

  it("closes open sessions whose working copy roots no longer exist", async () => {
    const missingSession = repositorySession({ repositoryId: "repo-uuid:C:/missing", workingCopyRoot: "C:\\missing" });
    const existingSession = repositorySession({ repositoryId: "repo-uuid:C:/workspace", workingCopyRoot: "C:\\workspace" });
    const sessionService = fakeSessionService({
      sessions: [missingSession, existingSession],
      missingRoots: new Set(["C:\\missing"]),
    });
    const events: RepositoryLifecycleEvent[] = [];
    const service = lifecycleService({
      sessionService,
      events,
    });

    const result = await service.closeDisappearedRepositories("workspaceFolders");

    expect(sessionService.closeRepository).toHaveBeenCalledTimes(1);
    expect(sessionService.closeRepository).toHaveBeenCalledWith("repo-uuid:C:/missing");
    expect(result).toEqual([
      {
        kind: "openSessionClosed",
        trigger: "workspaceFolders",
        reason: "workingCopyMissing",
        repositoryId: "repo-uuid:C:/missing",
        epoch: 7,
        workingCopyRoot: "C:\\missing",
      },
    ]);
    expect(events).toEqual(result);
  });

  it("reports close failures for disappeared working copies and continues checking later sessions", async () => {
    const missingSession = repositorySession({ repositoryId: "repo-uuid:C:/missing", workingCopyRoot: "C:\\missing" });
    const secondMissingSession = repositorySession({
      repositoryId: "repo-uuid:D:/missing",
      workingCopyRoot: "D:\\missing",
    });
    const sessionService = fakeSessionService({
      sessions: [missingSession, secondMissingSession],
      missingRoots: new Set(["C:\\missing", "D:\\missing"]),
      closeFailures: new Map([["repo-uuid:C:/missing", new CodedError("SUBVERSIONR_REPOSITORY_CLOSE_FAILED")]]),
    });
    const service = lifecycleService({ sessionService });

    const result = await service.closeDisappearedRepositories("workspaceFolders");

    expect(sessionService.closeRepository).toHaveBeenCalledTimes(2);
    expect(result).toEqual([
      {
        kind: "openSessionCloseFailed",
        trigger: "workspaceFolders",
        reason: "workingCopyMissing",
        repositoryId: "repo-uuid:C:/missing",
        epoch: 7,
        workingCopyRoot: "C:\\missing",
        code: "SUBVERSIONR_REPOSITORY_CLOSE_FAILED",
      },
      {
        kind: "openSessionClosed",
        trigger: "workspaceFolders",
        reason: "workingCopyMissing",
        repositoryId: "repo-uuid:D:/missing",
        epoch: 7,
        workingCopyRoot: "D:\\missing",
      },
    ]);
  });

  it("reports root existence check failures without closing the open session", async () => {
    const session = repositorySession({ repositoryId: "repo-uuid:C:/workspace", workingCopyRoot: "C:\\workspace" });
    const sessionService = fakeSessionService({
      sessions: [session],
      existsFailures: new Map([["C:\\workspace", new CodedError("SUBVERSIONR_WORKING_COPY_STAT_FAILED")]]),
    });
    const service = lifecycleService({ sessionService });

    const result = await service.closeDisappearedRepositories("workspaceFolders");

    expect(sessionService.closeRepository).not.toHaveBeenCalled();
    expect(result).toEqual([
      {
        kind: "openSessionCloseFailed",
        trigger: "workspaceFolders",
        reason: "workingCopyStatusUnavailable",
        repositoryId: "repo-uuid:C:/workspace",
        epoch: 7,
        workingCopyRoot: "C:\\workspace",
        code: "SUBVERSIONR_WORKING_COPY_STAT_FAILED",
      },
    ]);
  });

  it("recovers a missing open session from a moved working copy with the same repository identity", async () => {
    const oldSession = repositorySession({
      repositoryId: "repo-uuid:C:/old-wc",
      workingCopyRoot: "C:\\old-wc",
    });
    const movedCandidate = discoveryCandidate({
      workingCopyRoot: "C:\\new-wc",
    });
    const unrelatedCandidate = discoveryCandidate({
      repositoryUuid: "other-repo",
      workingCopyRoot: "D:\\other-wc",
    });
    const discoveryService = fakeDiscoveryService({ candidates: [movedCandidate, unrelatedCandidate] });
    const sessionService = fakeSessionService({
      sessions: [oldSession],
      missingRoots: new Set(["C:\\old-wc"]),
    });
    const events: RepositoryLifecycleEvent[] = [];
    const service = lifecycleService({
      discoveryService,
      sessionService,
      workspaceRoots: ["C:\\workspace", "D:\\other-wc"],
      events,
    });

    const result = await service.recoverMovedRepositories("workspaceFolders");

    expect(discoveryService.discoverRepositories).toHaveBeenCalledWith({
      workspaceRoots: ["C:\\workspace", "D:\\other-wc"],
      discoverNested: true,
      discoveryDepth: 4,
      discoveryIgnore: [],
      ignoredRoots: [],
      externalsMode: "lazy",
    });
    expect(sessionService.closeRepository).toHaveBeenCalledWith("repo-uuid:C:/old-wc");
    expect(discoveryService.openDiscoveredRepository).toHaveBeenCalledWith({
      candidate: movedCandidate,
      pathCase: "case-insensitive",
    });
    expect(result).toEqual([
      {
        kind: "openSessionMoved",
        trigger: "workspaceFolders",
        previousRepositoryId: "repo-uuid:C:/old-wc",
        previousEpoch: 7,
        previousWorkingCopyRoot: "C:\\old-wc",
        repositoryId: "repo-uuid:C:/new-wc",
        epoch: 7,
        workingCopyRoot: "C:\\new-wc",
      },
    ]);
    expect(events).toEqual(result);
  });

  it("leaves a missing open session for disappeared cleanup when no moved identity is discovered", async () => {
    const missingSession = repositorySession({
      repositoryId: "repo-uuid:C:/old-wc",
      workingCopyRoot: "C:\\old-wc",
    });
    const discoveryService = fakeDiscoveryService({
      candidates: [
        discoveryCandidate({
          repositoryUuid: "other-repo",
          workingCopyRoot: "D:\\other-wc",
        }),
      ],
    });
    const sessionService = fakeSessionService({
      sessions: [missingSession],
      missingRoots: new Set(["C:\\old-wc"]),
    });
    const service = lifecycleService({
      discoveryService,
      sessionService,
    });

    const result = await service.recoverMovedRepositories("activation");

    expect(result).toEqual([]);
    expect(sessionService.closeRepository).not.toHaveBeenCalled();
    expect(discoveryService.openDiscoveredRepository).not.toHaveBeenCalled();
  });

  it("does not recover a moved working copy when UUID matches but repository root URL differs", async () => {
    const missingSession = repositorySession({
      repositoryId: "repo-uuid:C:/old-wc",
      workingCopyRoot: "C:\\old-wc",
    });
    const sameUuidDifferentRootUrl = discoveryCandidate({
      repositoryUuid: "repo-uuid",
      repositoryRootUrl: "file:///D:/other-repo",
      workingCopyRoot: "C:\\new-wc",
    });
    const discoveryService = fakeDiscoveryService({ candidates: [sameUuidDifferentRootUrl] });
    const sessionService = fakeSessionService({
      sessions: [missingSession],
      missingRoots: new Set(["C:\\old-wc"]),
    });
    const service = lifecycleService({
      discoveryService,
      sessionService,
    });

    const result = await service.recoverMovedRepositories("workspaceFolders");

    expect(result).toEqual([]);
    expect(sessionService.closeRepository).not.toHaveBeenCalled();
    expect(discoveryService.openDiscoveredRepository).not.toHaveBeenCalled();
  });

  it("reports ambiguous moved working-copy candidates without closing the missing session", async () => {
    const missingSession = repositorySession({
      repositoryId: "repo-uuid:C:/old-wc",
      workingCopyRoot: "C:\\old-wc",
    });
    const firstCandidate = discoveryCandidate({ workingCopyRoot: "C:\\new-a" });
    const secondCandidate = discoveryCandidate({ workingCopyRoot: "C:\\new-b" });
    const discoveryService = fakeDiscoveryService({ candidates: [firstCandidate, secondCandidate] });
    const sessionService = fakeSessionService({
      sessions: [missingSession],
      missingRoots: new Set(["C:\\old-wc"]),
    });
    const service = lifecycleService({
      discoveryService,
      sessionService,
    });

    const result = await service.recoverMovedRepositories("workspaceFolders");

    expect(result).toEqual([
      {
        kind: "openSessionMoveFailed",
        trigger: "workspaceFolders",
        reason: "ambiguousCandidates",
        repositoryId: "repo-uuid:C:/old-wc",
        epoch: 7,
        workingCopyRoot: "C:\\old-wc",
        code: "SUBVERSIONR_REPOSITORY_MOVED_CANDIDATE_AMBIGUOUS",
        candidateCount: 2,
      },
    ]);
    expect(sessionService.closeRepository).not.toHaveBeenCalled();
    expect(discoveryService.openDiscoveredRepository).not.toHaveBeenCalled();
  });

  it("reopens stale repositories after backend termination without rediscovery", async () => {
    const discoveryService = fakeDiscoveryService({ candidates: [discoveryCandidate()] });
    const sessionService = fakeSessionService({
      reopenResults: [
        {
          kind: "reopened",
          repositoryId: "repo-uuid:C:/workspace",
          previousEpoch: 7,
          epoch: 1,
          workingCopyRoot: "C:\\workspace",
        },
      ],
    });
    const events: RepositoryLifecycleEvent[] = [];
    const service = lifecycleService({
      discoveryService,
      sessionService,
      events,
    });

    const result = await service.reopenBackendRestartedRepositories();

    expect(sessionService.reopenOpenSessions).toHaveBeenCalledTimes(1);
    expect(discoveryService.discoverRepositories).not.toHaveBeenCalled();
    expect(discoveryService.openDiscoveredRepository).not.toHaveBeenCalled();
    expect(result).toEqual([
      {
        kind: "openSessionReopened",
        trigger: "backendRestart",
        repositoryId: "repo-uuid:C:/workspace",
        previousEpoch: 7,
        epoch: 1,
        workingCopyRoot: "C:\\workspace",
      },
    ]);
    expect(events).toEqual(result);
  });

  it("reports backend restart reopen failures as lifecycle events", async () => {
    const sessionService = fakeSessionService({
      reopenResults: [
        {
          kind: "reopenFailed",
          repositoryId: "repo-uuid:C:/workspace",
          epoch: 7,
          workingCopyRoot: "C:\\workspace",
          code: "SUBVERSIONR_REPOSITORY_REOPEN_BACKEND_FAILED",
        },
      ],
    });
    const service = lifecycleService({ sessionService });

    const result = await service.reopenBackendRestartedRepositories();

    expect(result).toEqual([
      {
        kind: "openSessionReopenFailed",
        trigger: "backendRestart",
        repositoryId: "repo-uuid:C:/workspace",
        epoch: 7,
        workingCopyRoot: "C:\\workspace",
        code: "SUBVERSIONR_REPOSITORY_REOPEN_BACKEND_FAILED",
      },
    ]);
  });
});

function lifecycleService(options: {
  discoveryService?: Pick<RepositoryDiscoveryService, "discoverRepositories" | "openDiscoveredRepository">;
  sessionService?: Pick<RepositorySessionService, "closeRepository" | "listOpenSessions" | "reopenOpenSessions">;
  workspaceRoots?: string[];
  workspaceTrusted?: boolean;
  pathCase?: PathCasePolicy;
  events?: RepositoryLifecycleEvent[];
}): RepositoryLifecycleService {
  const sessionService = options.sessionService ?? fakeSessionService();
  return new RepositoryLifecycleService({
    discoveryService: options.discoveryService ?? fakeDiscoveryService({ candidates: [] }),
    sessionService,
    workspaceRoots: () => options.workspaceRoots ?? ["C:\\workspace"],
    workspaceTrusted: () => options.workspaceTrusted ?? true,
    pathCasePolicy: () => options.pathCase ?? "case-insensitive",
    workingCopyExists: (path) => {
      const error = existsFailures(sessionService).get(path);
      if (error) {
        return Promise.reject(error);
      }
      return Promise.resolve(!missingRoots(sessionService).has(path));
    },
    onEvent: (event) => {
      options.events?.push(event);
    },
  });
}

type RepositoryDiscoveryFixtureResponse = Pick<RepositoryDiscoveryResponse, "candidates"> &
  Partial<Pick<RepositoryDiscoveryResponse, "fileExternalBoundaries">>;

function fakeDiscoveryService(
  result: RepositoryDiscoveryFixtureResponse | Error,
): Pick<RepositoryDiscoveryService, "discoverRepositories" | "openDiscoveredRepository"> & {
  discoverRepositories: ReturnType<typeof vi.fn<RepositoryDiscoveryService["discoverRepositories"]>>;
  openDiscoveredRepository: ReturnType<typeof vi.fn<RepositoryDiscoveryService["openDiscoveredRepository"]>>;
} {
  return {
    discoverRepositories: vi.fn<RepositoryDiscoveryService["discoverRepositories"]>(() => {
      if (result instanceof Error) {
        return Promise.reject(result);
      }
      return Promise.resolve(discoveryResponse(result));
    }),
    openDiscoveredRepository: vi.fn<RepositoryDiscoveryService["openDiscoveredRepository"]>(async (request) => {
      const workingCopyRoot = request.candidate.identity.workingCopyRoot;
      const repositoryId = `${request.candidate.identity.repositoryUuid}:${workingCopyRoot.replaceAll("\\", "/")}`;
      return {
        repositoryId,
        epoch: 7,
        identity: request.candidate.identity,
        watchScope: {
          repositoryId,
          epoch: 7,
          workingCopyRoot,
          pathCase: "case-insensitive",
        },
      };
    }),
  };
}

function discoveryResponse(response: RepositoryDiscoveryFixtureResponse): RepositoryDiscoveryResponse {
  return {
    candidates: response.candidates,
    fileExternalBoundaries: response.fileExternalBoundaries ?? [],
  };
}

function fakeSessionService(
  options: {
    sessions?: RepositorySession[];
    reopenResults?: RepositorySessionReopenResult[];
    missingRoots?: Set<string>;
    existsFailures?: Map<string, Error>;
    closeFailures?: Map<string, Error>;
  } = {},
): Pick<
  RepositorySessionService,
  "closeRepository" | "listOpenSessions" | "reopenOpenSessions"
> & {
  listOpenSessions: ReturnType<typeof vi.fn<RepositorySessionService["listOpenSessions"]>>;
  closeRepository: ReturnType<typeof vi.fn<RepositorySessionService["closeRepository"]>>;
  reopenOpenSessions: ReturnType<typeof vi.fn<RepositorySessionService["reopenOpenSessions"]>>;
  missingRoots: Set<string>;
  existsFailures: Map<string, Error>;
} {
  return {
    listOpenSessions: vi.fn<RepositorySessionService["listOpenSessions"]>(() => options.sessions ?? []),
    closeRepository: vi.fn<RepositorySessionService["closeRepository"]>((repositoryId) => {
      const error = options.closeFailures?.get(repositoryId);
      if (error) {
        return Promise.reject(error);
      }
      return Promise.resolve();
    }),
    reopenOpenSessions: vi.fn<RepositorySessionService["reopenOpenSessions"]>(() =>
      Promise.resolve(options.reopenResults ?? []),
    ),
    missingRoots: options.missingRoots ?? new Set(),
    existsFailures: options.existsFailures ?? new Map(),
  };
}

function missingRoots(
  sessionService: Pick<RepositorySessionService, "closeRepository" | "listOpenSessions" | "reopenOpenSessions">,
): Set<string> {
  return "missingRoots" in sessionService && sessionService.missingRoots instanceof Set
    ? sessionService.missingRoots
    : new Set();
}

function existsFailures(
  sessionService: Pick<RepositorySessionService, "closeRepository" | "listOpenSessions" | "reopenOpenSessions">,
): Map<string, Error> {
  return "existsFailures" in sessionService && sessionService.existsFailures instanceof Map
    ? sessionService.existsFailures
    : new Map();
}

function fakeControlledDiscoveryService(
  response: Promise<RepositoryDiscoveryResponse>,
): Pick<RepositoryDiscoveryService, "discoverRepositories" | "openDiscoveredRepository"> & {
  discoverRepositories: ReturnType<typeof vi.fn<RepositoryDiscoveryService["discoverRepositories"]>>;
  openDiscoveredRepository: ReturnType<typeof vi.fn<RepositoryDiscoveryService["openDiscoveredRepository"]>>;
} {
  return {
    discoverRepositories: vi.fn<RepositoryDiscoveryService["discoverRepositories"]>(() => response),
    openDiscoveredRepository: vi.fn<RepositoryDiscoveryService["openDiscoveredRepository"]>(async (request) =>
      repositorySession({ workingCopyRoot: request.candidate.identity.workingCopyRoot }),
    ),
  };
}

function discoveryCandidate(
  overrides: Partial<RepositoryDiscoveryCandidate["identity"]> = {},
  candidateOverrides: Partial<
    Pick<RepositoryDiscoveryCandidate, "isNested" | "isExternal" | "parentWorkingCopyRoot">
  > = {},
): RepositoryDiscoveryCandidate {
  const workingCopyRoot = overrides.workingCopyRoot ?? "C:\\workspace";
  return {
    identity: {
      repositoryUuid: overrides.repositoryUuid ?? "repo-uuid",
      repositoryRootUrl: overrides.repositoryRootUrl ?? "file:///C:/repo",
      workingCopyRoot,
      workspaceScopeRoot: overrides.workspaceScopeRoot ?? workingCopyRoot,
      format: overrides.format ?? 31,
    },
    isNested: candidateOverrides.isNested ?? false,
    isExternal: candidateOverrides.isExternal ?? false,
    ...(candidateOverrides.parentWorkingCopyRoot
      ? { parentWorkingCopyRoot: candidateOverrides.parentWorkingCopyRoot }
      : {}),
  };
}

function repositorySession(
  overrides: Partial<{ repositoryId: string; workingCopyRoot: string }> = {},
): RepositorySession {
  const workingCopyRoot = overrides.workingCopyRoot ?? "C:\\workspace";
  const repositoryId = overrides.repositoryId ?? `repo-uuid:${workingCopyRoot.replaceAll("\\", "/")}`;
  return {
    repositoryId,
    epoch: 7,
    identity: discoveryCandidate({ workingCopyRoot }).identity,
    watchScope: {
      repositoryId,
      epoch: 7,
      workingCopyRoot,
      pathCase: "case-insensitive",
    },
  };
}

class CodedError extends Error {
  public constructor(public readonly code: string) {
    super(code);
  }
}

function deferred<T>(): {
  promise: Promise<T>;
  resolve(value: T): void;
  reject(error: unknown): void;
} {
  let resolveValue: ((value: T) => void) | undefined;
  let rejectValue: ((error: unknown) => void) | undefined;
  const promise = new Promise<T>((resolve, reject) => {
    resolveValue = resolve;
    rejectValue = reject;
  });
  return {
    promise,
    resolve(value) {
      resolveValue?.(value);
    },
    reject(error) {
      rejectValue?.(error);
    },
  };
}
