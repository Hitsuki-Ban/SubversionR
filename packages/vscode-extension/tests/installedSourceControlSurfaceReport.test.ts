import { describe, expect, it, vi } from "vitest";
import {
  collectInstalledSourceControlSurfaceReport,
  collectInstalledSourceControlUiE2eCurrentSurfaceReport,
  collectInstalledSourceControlUiE2eLazyExternalProviderReport,
  collectInstalledSourceControlUiE2eCloseReport,
  collectInstalledSourceControlUiE2eFreshnessReport,
  collectInstalledSourceControlUiE2eOpenReport,
  InstalledSourceControlSurfaceReportError,
} from "../src/diagnostics/installedSourceControlSurfaceReport";
import type { RepositoryDiscoveryCandidate } from "../src/repository/repositoryDiscoveryService";
import type { RepositorySession } from "../src/repository/repositorySessionService";
import type { ScmRepositoryProjection } from "../src/scm/sourceControlResourceStore";
import type { VscodeSourceControlSnapshot } from "../src/scm/vscodeSourceControlPresenter";
import type { StatusSnapshot } from "../src/status/statusSnapshotRpcClient";
import type { CompletedStatusRefreshCoverage } from "../src/status/statusRefreshScheduler";

describe("collectInstalledSourceControlSurfaceReport", () => {
  it("opens a working copy and reports the VS Code SourceControl surface snapshot", async () => {
    const session = repositorySession();
    const sessionService = {
      openWorkingCopy: vi.fn(async () => session),
      closeRepository: vi.fn(async () => undefined),
    };

    const report = await collectInstalledSourceControlSurfaceReport(
      { path: "C:\\fixture\\wc" },
      {
        generatedAt: () => "2026-06-25T00:00:00Z",
        extensionVersion: "0.1.0",
        pathCasePolicy: () => "case-insensitive",
        workspaceTrusted: () => true,
        sessionService,
        sourceControlProjection: {
          getProjection: vi.fn(() => scmProjection()),
        },
        sourceControlSurface: {
          snapshotRepository: vi.fn(() => sourceControlSnapshot()),
        },
      },
    );

    expect(sessionService.openWorkingCopy).toHaveBeenCalledWith({
      path: "C:\\fixture\\wc",
      pathCase: "case-insensitive",
    });
    expect(sessionService.closeRepository).toHaveBeenCalledWith("repo-uuid:C:/fixture/wc");
    expect(report).toEqual({
      kind: "subversionr.installedSourceControlSurfaceReport",
      generatedAt: "2026-06-25T00:00:00Z",
      extension: {
        name: "subversionr",
        version: "0.1.0",
      },
      workspace: {
        trusted: true,
        pathCase: "case-insensitive",
      },
      repository: {
        repositoryId: "repo-uuid:C:/fixture/wc",
        epoch: 7,
        identity: session.identity,
      },
      openRequest: {
        path: "C:\\fixture\\wc",
        relationToWorkingCopyRoot: "workingCopyRoot",
      },
      providerResolution: {
        requestedPathResolvedToWorkingCopyRoot: true,
        workspaceScopeRootMatchedRequest: true,
        sourceControlRootMatchedWorkingCopyRoot: true,
        subdirectoryOpenResolvedToWorkingCopyRoot: false,
      },
      sourceControl: {
        repositoryId: "repo-uuid:C:/fixture/wc",
        epoch: 7,
        workingCopyRoot: "C:\\fixture\\wc",
        generation: 3,
        count: 1,
        freshness: {
          repositoryCompleteness: "complete",
          lastRefreshCompleteness: "complete",
          lastRefreshKind: "snapshot",
        },
        statusBarCommands: undefined,
        inputBox: {
          placeholder: "SVN commit message",
          acceptInputCommand: "subversionr.commitAll",
          acceptInputCommandArguments: ["repo-uuid:C:/fixture/wc"],
        },
        groups: [
          {
            id: "changes",
            contextValue: "subversionr.changes",
            hideWhenEmpty: true,
            count: 1,
            resources: [
              {
                path: "src/tracked.txt",
                contextValue: "subversionr.changedFile.baseDiffable",
                kind: "file",
                generation: 3,
              },
            ],
          },
          {
            id: "unversioned",
            contextValue: "subversionr.unversioned",
            hideWhenEmpty: true,
            count: 1,
            resources: [
              {
                path: "scratch.txt",
                contextValue: "subversionr.unversioned",
                kind: "file",
                generation: 3,
              },
            ],
          },
        ],
      },
      surfaceWorkflow: {
        repositoryOpen: true,
        scmProjection: true,
        sourceControlSurface: true,
        repositoryClosed: true,
      },
    });
  });

  it("reports subdirectory opens resolving to the parent working copy provider", async () => {
    const session = repositorySession({ workspaceScopeRoot: "C:\\fixture\\wc\\src" });
    const sessionService = {
      openWorkingCopy: vi.fn(async () => session),
      closeRepository: vi.fn(async () => undefined),
    };

    const report = await collectInstalledSourceControlSurfaceReport(
      { path: "C:\\fixture\\wc\\src" },
      {
        generatedAt: () => "2026-06-25T00:00:00Z",
        extensionVersion: "0.1.0",
        pathCasePolicy: () => "case-insensitive",
        workspaceTrusted: () => true,
        sessionService,
        sourceControlProjection: {
          getProjection: vi.fn(() => scmProjection()),
        },
        sourceControlSurface: {
          snapshotRepository: vi.fn(() => sourceControlSnapshot()),
        },
      },
    );

    expect(sessionService.openWorkingCopy).toHaveBeenCalledWith({
      path: "C:\\fixture\\wc\\src",
      pathCase: "case-insensitive",
    });
    expect(report.repository.identity.workingCopyRoot).toBe("C:\\fixture\\wc");
    expect(report.repository.identity.workspaceScopeRoot).toBe("C:\\fixture\\wc\\src");
    expect(report.sourceControl.workingCopyRoot).toBe("C:\\fixture\\wc");
    expect(report.openRequest).toEqual({
      path: "C:\\fixture\\wc\\src",
      relationToWorkingCopyRoot: "subdirectory",
    });
    expect(report.providerResolution).toEqual({
      requestedPathResolvedToWorkingCopyRoot: true,
      workspaceScopeRootMatchedRequest: true,
      sourceControlRootMatchedWorkingCopyRoot: true,
      subdirectoryOpenResolvedToWorkingCopyRoot: true,
    });
    expect(sessionService.closeRepository).toHaveBeenCalledWith("repo-uuid:C:/fixture/wc");
  });

  it("closes the opened repository when the SourceControl surface snapshot is missing", async () => {
    const session = repositorySession();
    const sessionService = {
      openWorkingCopy: vi.fn(async () => session),
      closeRepository: vi.fn(async () => undefined),
    };

    await expect(
      collectInstalledSourceControlSurfaceReport(
        { path: "C:\\fixture\\wc" },
        {
          generatedAt: () => "2026-06-25T00:00:00Z",
          extensionVersion: "0.1.0",
          pathCasePolicy: () => "case-insensitive",
          workspaceTrusted: () => true,
          sessionService,
          sourceControlProjection: {
            getProjection: vi.fn(() => scmProjection()),
          },
          sourceControlSurface: {
            snapshotRepository: vi.fn(() => undefined),
          },
        },
      ),
    ).rejects.toBeInstanceOf(InstalledSourceControlSurfaceReportError);
    expect(sessionService.closeRepository).toHaveBeenCalledWith("repo-uuid:C:/fixture/wc");
  });

  it("rejects a SourceControl surface snapshot from another projection generation", async () => {
    const session = repositorySession();
    const sessionService = {
      openWorkingCopy: vi.fn(async () => session),
      closeRepository: vi.fn(async () => undefined),
    };

    const error = await collectInstalledSourceControlSurfaceReport(
      { path: "C:\\fixture\\wc" },
      {
        generatedAt: () => "2026-06-25T00:00:00Z",
        extensionVersion: "0.1.0",
        pathCasePolicy: () => "case-insensitive",
        workspaceTrusted: () => true,
        sessionService,
        sourceControlProjection: {
          getProjection: vi.fn(() => scmProjection()),
        },
        sourceControlSurface: {
          snapshotRepository: vi.fn(() => ({
            ...sourceControlSnapshot(),
            generation: 2,
          })),
        },
      },
    ).catch((caught: unknown) => caught);

    expect(error).toBeInstanceOf(InstalledSourceControlSurfaceReportError);
    expect(error).toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_SURFACE_MISMATCH",
      category: "lifecycle",
      messageKey: "error.diagnostics.installedSourceControlSurfaceMismatch",
      safeArgs: expect.objectContaining({
        repositoryId: "repo-uuid:C:/fixture/wc",
        epoch: 7,
        sourceControlGroups: expect.any(Array),
        projectionGroups: expect.any(Array),
      }),
    });
    expect(sessionService.closeRepository).toHaveBeenCalledTimes(1);
  });

  it("reports SourceControl surface mismatch group summaries", async () => {
    const session = repositorySession();
    const sessionService = {
      openWorkingCopy: vi.fn(async () => session),
      closeRepository: vi.fn(async () => undefined),
    };
    const projection = scmProjection();
    const [unversionedGroup] = projection.groups.filter((group) => group.id === "unversioned");
    unversionedGroup.resources = [];

    const error = await collectInstalledSourceControlSurfaceReport(
      { path: "C:\\fixture\\wc" },
      {
        generatedAt: () => "2026-06-25T00:00:00Z",
        extensionVersion: "0.1.0",
        pathCasePolicy: () => "case-insensitive",
        workspaceTrusted: () => true,
        sessionService,
        sourceControlProjection: {
          getProjection: vi.fn(() => projection),
        },
        sourceControlSurface: {
          snapshotRepository: vi.fn(() => sourceControlSnapshot()),
        },
      },
    ).catch((caught: unknown) => caught);

    expect(error).toBeInstanceOf(InstalledSourceControlSurfaceReportError);
    expect(error).toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_SURFACE_MISMATCH",
      category: "lifecycle",
      messageKey: "error.diagnostics.installedSourceControlSurfaceMismatch",
      safeArgs: expect.objectContaining({
        repositoryId: "repo-uuid:C:/fixture/wc",
        epoch: 7,
        sourceControlGroups: expect.arrayContaining([
          expect.objectContaining({
            id: "unversioned",
            resources: [
              {
                path: "scratch.txt",
                contextValue: "subversionr.unversioned",
                kind: "file",
                generation: 3,
              },
            ],
          }),
        ]),
        projectionGroups: expect.arrayContaining([
          expect.objectContaining({
            id: "unversioned",
            resources: [],
          }),
        ]),
      }),
    });
    expect(sessionService.closeRepository).toHaveBeenCalledTimes(1);
  });

  it("matches SourceControl resource generations against the projection generation", async () => {
    const session = repositorySession();
    const sessionService = {
      openWorkingCopy: vi.fn(async () => session),
      closeRepository: vi.fn(async () => undefined),
    };
    const projection = scmProjection();
    projection.generation = 4;
    const [projectionChanges] = projection.groups.filter((group) => group.id === "changes");
    projectionChanges.resources[0].entry.generation = 2;
    const [projectionUnversioned] = projection.groups.filter((group) => group.id === "unversioned");
    projectionUnversioned.resources = [];

    const sourceControl = sourceControlSnapshot();
    sourceControl.generation = 4;
    const [surfaceChanges] = sourceControl.groups.filter((group) => group.id === "changes");
    surfaceChanges.resources[0].generation = 4;
    const [surfaceUnversioned] = sourceControl.groups.filter((group) => group.id === "unversioned");
    surfaceUnversioned.count = 0;
    surfaceUnversioned.resources = [];

    const report = await collectInstalledSourceControlSurfaceReport(
      { path: "C:\\fixture\\wc" },
      {
        generatedAt: () => "2026-06-25T00:00:00Z",
        extensionVersion: "0.1.0",
        pathCasePolicy: () => "case-insensitive",
        workspaceTrusted: () => true,
        sessionService,
        sourceControlProjection: {
          getProjection: vi.fn(() => projection),
        },
        sourceControlSurface: {
          snapshotRepository: vi.fn(() => sourceControl),
        },
      },
    );

    expect(report.sourceControl.generation).toBe(4);
    expect(report.sourceControl.groups.find((group) => group.id === "changes")?.resources[0]?.generation).toBe(4);
    expect(sessionService.closeRepository).toHaveBeenCalledWith("repo-uuid:C:/fixture/wc");
  });

  it("matches working-copy metadata file context values against the rendered SourceControl surface", async () => {
    const session = repositorySession();
    const sessionService = {
      openWorkingCopy: vi.fn(async () => session),
      closeRepository: vi.fn(async () => undefined),
    };
    const projection = scmProjection();
    const [projectionMetadata] = projection.groups.filter((group) => group.id === "metadata");
    projectionMetadata.resources.push(
      projectedResource({
        path: "src/needs-lock.txt",
        kind: "file",
        groupId: "metadata",
        contextValue: "subversionr.workingCopyMetadata",
        localStatus: "normal",
        nodeStatus: "normal",
      }),
    );

    const sourceControl = sourceControlSnapshot();
    const [surfaceMetadata] = sourceControl.groups.filter((group) => group.id === "metadata");
    surfaceMetadata.count = 1;
    surfaceMetadata.resources.push({
      path: "src/needs-lock.txt",
      contextValue: "subversionr.workingCopyMetadataFile",
      kind: "file",
      generation: 3,
    });

    const report = await collectInstalledSourceControlSurfaceReport(
      { path: "C:\\fixture\\wc" },
      {
        generatedAt: () => "2026-06-25T00:00:00Z",
        extensionVersion: "0.1.0",
        pathCasePolicy: () => "case-insensitive",
        workspaceTrusted: () => true,
        sessionService,
        sourceControlProjection: {
          getProjection: vi.fn(() => projection),
        },
        sourceControlSurface: {
          snapshotRepository: vi.fn(() => sourceControl),
        },
      },
    );

    expect(report.sourceControl.groups.find((group) => group.id === "metadata")?.resources[0]).toEqual({
      path: "src/needs-lock.txt",
      contextValue: "subversionr.workingCopyMetadataFile",
      kind: "file",
      generation: 3,
    });
    expect(sessionService.closeRepository).toHaveBeenCalledWith("repo-uuid:C:/fixture/wc");
  });

  it("reports the currently opened SourceControl surface for renderer UI E2E without opening or closing repositories", () => {
    const session = repositorySession();
    const sessionService = {
      listOpenSessions: vi.fn(() => [session]),
      openWorkingCopy: vi.fn(),
      closeRepository: vi.fn(),
    };
    const sourceControl = sourceControlSnapshot();

    const report = collectInstalledSourceControlUiE2eCurrentSurfaceReport(
      { path: "C:\\fixture\\wc\\src" },
      {
        generatedAt: () => "2026-06-25T00:00:00Z",
        extensionVersion: "0.1.0",
        pathCasePolicy: () => "case-insensitive",
        workspaceTrusted: () => true,
        sessionService,
        sourceControlSurface: {
          snapshotRepository: vi.fn(() => sourceControl),
        },
      },
    );

    expect(sessionService.openWorkingCopy).not.toHaveBeenCalled();
    expect(sessionService.closeRepository).not.toHaveBeenCalled();
    expect(report).toMatchObject({
      kind: "subversionr.installedSourceControlUiE2eCurrentSurfaceReport",
      repository: {
        repositoryId: "repo-uuid:C:/fixture/wc",
        epoch: 7,
        identity: session.identity,
      },
      openRequest: {
        path: "C:\\fixture\\wc\\src",
        relationToWorkingCopyRoot: "subdirectory",
      },
      sourceControl,
      surfaceWorkflow: {
        repositoryOpen: true,
        scmProjection: true,
        sourceControlSurface: true,
        repositoryClosed: false,
      },
    });
  });

  it("opens a working copy for renderer UI E2E capture without closing it", async () => {
    const session = repositorySession();
    const sessionService = {
      openWorkingCopy: vi.fn(async () => session),
      closeRepository: vi.fn(async () => undefined),
    };

    const report = await collectInstalledSourceControlUiE2eOpenReport(
      { path: "C:\\fixture\\wc" },
      {
        generatedAt: () => "2026-06-25T00:00:00Z",
        extensionVersion: "0.1.0",
        pathCasePolicy: () => "case-insensitive",
        workspaceTrusted: () => true,
        sessionService,
        sourceControlProjection: {
          getProjection: vi.fn(() => scmProjection()),
        },
        sourceControlSurface: {
          snapshotRepository: vi.fn(() => sourceControlSnapshot()),
        },
      },
    );

    expect(sessionService.openWorkingCopy).toHaveBeenCalledWith({
      path: "C:\\fixture\\wc",
      pathCase: "case-insensitive",
    });
    expect(sessionService.closeRepository).not.toHaveBeenCalled();
    expect(report.kind).toBe("subversionr.installedSourceControlUiE2eOpenReport");
    expect(report.repository.repositoryId).toBe("repo-uuid:C:/fixture/wc");
    expect(report.sourceControl.groups.map((group) => group.id)).toEqual(["changes", "unversioned"]);
    expect(report.rendererCaptureExpectations).toEqual({
      viewCommand: "workbench.view.scm",
      requiredDomTokens: [
        "SubversionR",
        "Changes",
        "Unversioned",
        "src",
        "tracked.txt",
        "scratch.txt",
        "SubversionR backend ready. libsvn:",
      ],
      requiredAccessibilityTokens: [
        "SubversionR",
        "Changes",
        "Unversioned",
        "src",
        "tracked.txt",
        "scratch.txt",
      ],
      requiredScreenshot: true,
      viewport: { width: 1440, height: 900 },
      scmActionSurface: {
        primaryActions: [
          { label: "SubversionR: Refresh", codicon: "refresh" },
          { label: "SubversionR: Commit Changes", codicon: "check" },
          { label: "SubversionR: Review and Commit…", codicon: "diff" },
        ],
        overflowSubmenus: [
          {
            label: "Commit",
            commands: ["SubversionR: Pick Commit Message History…", "SubversionR: Revert All…"],
          },
          {
            label: "Update",
            commands: [
              "SubversionR: Check Remote Changes",
              "SubversionR: Update Working Copy",
              "SubversionR: Update to Revision…",
            ],
          },
          {
            label: "Repository",
            commands: [
              "SubversionR: Create Branch or Tag…",
              "SubversionR: Switch Working Copy…",
              "SubversionR: Relocate Working Copy…",
              "SubversionR: Show Repository Properties",
              "SubversionR: Edit Repository svn:externals…",
              "SubversionR: Full Reconcile",
              "SubversionR: Cleanup Working Copy…",
              "SubversionR: Upgrade Working Copy",
              "SubversionR: Close Repository",
            ],
          },
          { label: "History", commands: ["SubversionR: Show Repository Log"] },
        ],
        resource: {
          pathToken: "tracked.txt",
          inlineActions: [
            { label: "SubversionR: Diff with BASE", codicon: "diff" },
            { label: "SubversionR: Revert Resource…", codicon: "discard" },
            { label: "SubversionR: Commit Resource", codicon: "check" },
          ],
          contextActions: [
            "SubversionR: Set Changelist…",
            "SubversionR: Open BASE",
            "SubversionR: Show Selected Properties",
          ],
        },
        forbiddenNotificationTokens: ["SubversionR backend ready. libsvn:"],
      },
    });
    expect(report.surfaceWorkflow).toEqual({
      repositoryOpen: true,
      scmProjection: true,
      sourceControlSurface: true,
      repositoryClosed: false,
    });
  });

  it("reports installed lazy external provider discovery and boundary planning", async () => {
    const parentCandidate = repositoryCandidate("C:\\fixture\\wc", {
      repositoryUuid: "parent-repository-uuid",
    });
    const directoryExternalCandidate = repositoryCandidate("C:\\fixture\\wc\\vendor\\lib", {
      repositoryUuid: "external-repository-uuid",
      repositoryRootUrl: "file:///C:/fixture/external-repo",
      isExternal: true,
      parentWorkingCopyRoot: "C:\\fixture\\wc",
    });
    const fileExternalBoundary = "C:\\fixture\\wc\\externals\\pinned.txt";
    const parentSession = repositorySession({
      repositoryUuid: "parent-repository-uuid",
      boundaryRoots: ["C:\\fixture\\wc\\vendor\\lib", fileExternalBoundary],
    });
    const externalSession = repositorySession({
      repositoryId: "repo-uuid:C:/fixture/wc/vendor/lib",
      repositoryUuid: "external-repository-uuid",
      repositoryRootUrl: "file:///C:/fixture/external-repo",
      workingCopyRoot: "C:\\fixture\\wc\\vendor\\lib",
      workspaceScopeRoot: "C:\\fixture\\wc\\vendor\\lib",
    });
    const discoveryService = {
      discoverRepositories: vi.fn(async () => ({
        candidates: [parentCandidate, directoryExternalCandidate],
        fileExternalBoundaries: [fileExternalBoundary],
      })),
      openDiscoveredRepository: vi.fn(async (request: { candidate: RepositoryDiscoveryCandidate }) => {
        if (request.candidate.identity.workingCopyRoot === parentCandidate.identity.workingCopyRoot) {
          return parentSession;
        }
        return externalSession;
      }),
    };
    const sessionService = {
      listOpenSessions: vi.fn(() => []),
      closeRepository: vi.fn(async () => undefined),
    };
    const sourceControlSurface = {
      snapshotRepository: vi.fn((repositoryId: string) =>
        repositoryId === parentSession.repositoryId
          ? sourceControlSnapshot()
          : sourceControlSnapshotFor(externalSession, "src/external.txt"),
      ),
    };

    const report = await collectInstalledSourceControlUiE2eLazyExternalProviderReport(
      { path: "C:\\fixture\\wc" },
      {
        generatedAt: () => "2026-06-25T00:00:20Z",
        extensionVersion: "0.1.0",
        pathCasePolicy: () => "case-insensitive",
        workspaceTrusted: () => true,
        discoveryService,
        sessionService,
        sourceControlSurface,
      },
    );

    expect(discoveryService.discoverRepositories).toHaveBeenCalledWith({
      workspaceRoots: ["C:\\fixture\\wc"],
      discoverNested: true,
      discoveryDepth: 4,
      discoveryIgnore: [],
      ignoredRoots: [],
      externalsMode: "lazy",
    });
    expect(discoveryService.openDiscoveredRepository).toHaveBeenNthCalledWith(1, {
      candidate: parentCandidate,
      pathCase: "case-insensitive",
      boundaryRoots: ["C:\\fixture\\wc\\vendor\\lib", fileExternalBoundary],
    });
    expect(discoveryService.openDiscoveredRepository).toHaveBeenNthCalledWith(2, {
      candidate: directoryExternalCandidate,
      pathCase: "case-insensitive",
    });
    expect(sessionService.closeRepository).toHaveBeenCalledWith(externalSession.repositoryId);
    expect(sessionService.closeRepository).toHaveBeenCalledWith(parentSession.repositoryId);
    expect(report).toMatchObject({
      kind: "subversionr.installedSourceControlUiE2eLazyExternalProviderReport",
      request: {
        path: "C:\\fixture\\wc",
        externalsMode: "lazy",
        discoveryDepth: 4,
      },
      discovery: {
        fileExternalBoundaries: [fileExternalBoundary],
      },
      parentProvider: {
        repositoryId: parentSession.repositoryId,
        workingCopyRoot: "C:\\fixture\\wc",
        boundaryRoots: ["C:\\fixture\\wc\\vendor\\lib", fileExternalBoundary],
      },
      externalProviders: [
        {
          repositoryId: externalSession.repositoryId,
          workingCopyRoot: "C:\\fixture\\wc\\vendor\\lib",
          parentWorkingCopyRoot: "C:\\fixture\\wc",
        },
      ],
      assertions: {
        lazyDiscoveryRequested: true,
        directoryExternalDiscovered: true,
        fileExternalBoundariesDiscovered: true,
        parentBoundaryRootsIncludedDirectoryExternal: true,
        parentBoundaryRootsIncludedFileExternal: true,
        distinctExternalProviderOpened: true,
        parentSourceControlExcludedExternalBoundaries: true,
        providersClosed: true,
      },
    });
  });

  it("closes the UI E2E repository session only when the epoch matches", async () => {
    const session = repositorySession();
    const sessionService = {
      listOpenSessions: vi.fn(() => [session]),
      closeRepository: vi.fn(async () => undefined),
    };

    const report = await collectInstalledSourceControlUiE2eCloseReport(
      {
        repositoryId: session.repositoryId,
        epoch: session.epoch,
      },
      {
        generatedAt: () => "2026-06-25T00:00:05Z",
        sessionService,
      },
    );

    expect(sessionService.closeRepository).toHaveBeenCalledWith(session.repositoryId);
    expect(report).toEqual({
      kind: "subversionr.installedSourceControlUiE2eCloseReport",
      generatedAt: "2026-06-25T00:00:05Z",
      repositoryId: session.repositoryId,
      epoch: session.epoch,
      repositoryClosed: true,
    });
  });

  it("rejects UI E2E close requests for stale repository epochs", async () => {
    const session = repositorySession();
    const sessionService = {
      listOpenSessions: vi.fn(() => [session]),
      closeRepository: vi.fn(async () => undefined),
    };

    await expect(
      collectInstalledSourceControlUiE2eCloseReport(
        {
          repositoryId: session.repositoryId,
          epoch: session.epoch + 1,
        },
        {
          generatedAt: () => "2026-06-25T00:00:05Z",
          sessionService,
        },
      ),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SESSION_MISMATCH",
      category: "lifecycle",
      messageKey: "error.diagnostics.installedSourceControlUiE2eSessionMismatch",
      safeArgs: {
        repositoryId: session.repositoryId,
        epoch: session.epoch + 1,
      },
    });
    expect(sessionService.closeRepository).not.toHaveBeenCalled();
  });

  it("reports an installed partial SourceControl freshness affordance for an open UI E2E session", async () => {
    const session = repositorySession();
    const storedSnapshot = statusSnapshot();
    const completedCoverage: CompletedStatusRefreshCoverage = {
      repositoryId: session.repositoryId,
      epoch: session.epoch,
      generation: 4,
      targets: [{ path: "load/modified-001.txt", depth: "empty", reason: "resourceRefresh" }],
      coverage: [{ path: "load/modified-001.txt", depth: "empty", generation: 4, reason: "resourceRefresh" }],
      completeness: "partial",
      timestamp: "2026-06-25T00:00:12Z",
      source: "libsvn-local",
    };
    const statusSnapshotStore = {
      getSnapshot: vi.fn(() => storedSnapshot),
      replaceSnapshot: vi.fn(() => ({ ...storedSnapshot, completeness: "partial" as const })),
      markStale: vi.fn(),
    };
    const sourceControlProjection = {
      getProjection: vi.fn(() => scmProjection(freshnessState("partial"))),
      replaceSnapshot: vi.fn(() => scmProjection(freshnessState("partial"))),
      markStale: vi.fn(),
    };

    const report = await collectInstalledSourceControlUiE2eFreshnessReport(
      {
        repositoryId: session.repositoryId,
        epoch: session.epoch,
        scenario: "partial",
      },
      {
        generatedAt: () => "2026-06-25T00:00:10Z",
        sessionService: {
          listOpenSessions: vi.fn(() => [session]),
        },
        statusSnapshotStore,
        sourceControlProjection,
        statusRefreshCoverage: {
          getLastCompletedRefresh: vi.fn(() => completedCoverage),
        },
        sourceControlSurface: {
          snapshotRepository: vi.fn(() => sourceControlSnapshot(freshnessState("partial"))),
        },
      },
    );

    expect(statusSnapshotStore.replaceSnapshot).toHaveBeenCalledWith({
      ...storedSnapshot,
      completeness: "partial",
      timestamp: "2026-06-25T00:00:10Z",
      source: "installed-source-control-ui-e2e",
    });
    expect(sourceControlProjection.replaceSnapshot).toHaveBeenCalledWith({
      ...storedSnapshot,
      completeness: "partial",
      timestamp: "2026-06-25T00:00:10Z",
      source: "installed-source-control-ui-e2e",
    });
    expect(report).toMatchObject({
      kind: "subversionr.installedSourceControlUiE2eFreshnessReport",
      scenario: "partial",
      repository: {
        repositoryId: session.repositoryId,
        epoch: session.epoch,
      },
      sourceControl: {
        freshness: {
          repositoryCompleteness: "partial",
          lastRefreshCompleteness: "partial",
          lastRefreshKind: "snapshot",
        },
        statusBarCommands: [
          {
            command: "subversionr.fullReconcile",
            title: "SVN status partial",
            arguments: [session.repositoryId],
          },
        ],
      },
      freshnessWorkflow: {
        repositoryOpen: true,
        currentEpochMatched: true,
        sourceControlSurface: true,
      },
      lastCompletedRefresh: {
        repositoryId: session.repositoryId,
        epoch: session.epoch,
        generation: 4,
        targets: [{ path: "load/modified-001.txt", depth: "empty", reason: "resourceRefresh" }],
        coverage: [{ path: "load/modified-001.txt", depth: "empty", generation: 4, reason: "resourceRefresh" }],
        completeness: "partial",
        timestamp: "2026-06-25T00:00:12Z",
        source: "libsvn-local",
      },
    });
  });

  it("matches changelist SourceControl resources using presenter context values", async () => {
    const session = repositorySession();
    const storedSnapshot = statusSnapshot();
    const sourceControlProjection = {
      getProjection: vi.fn(() => changelistScmProjection(freshnessState("partial"))),
      replaceSnapshot: vi.fn(() => changelistScmProjection(freshnessState("partial"))),
      markStale: vi.fn(),
    };

    const report = await collectInstalledSourceControlUiE2eFreshnessReport(
      {
        repositoryId: session.repositoryId,
        epoch: session.epoch,
        scenario: "partial",
      },
      {
        generatedAt: () => "2026-06-25T00:00:10Z",
        sessionService: {
          listOpenSessions: vi.fn(() => [session]),
        },
        statusSnapshotStore: {
          getSnapshot: vi.fn(() => storedSnapshot),
          replaceSnapshot: vi.fn(() => ({ ...storedSnapshot, completeness: "partial" as const })),
          markStale: vi.fn(),
        },
        sourceControlProjection,
        statusRefreshCoverage: {
          getLastCompletedRefresh: vi.fn(() => undefined),
        },
        sourceControlSurface: {
          snapshotRepository: vi.fn(() => changelistSourceControlSnapshot(freshnessState("partial"))),
        },
      },
    );

    expect(report.sourceControl.groups).toContainEqual(
      expect.objectContaining({
        id: "changelist:review",
        resources: [
          expect.objectContaining({
            path: "src/tracked.txt",
            contextValue: "subversionr.changedFile.baseDiffable.changelisted",
          }),
        ],
      }),
    );
  });

  it("reports conflict artifacts and count exclusions from the installed SourceControl surface", async () => {
    const session = repositorySession();
    const storedSnapshot = statusSnapshot();
    const freshness = freshnessState("partial");
    const projection = conflictArtifactScmProjection(freshness);
    const sourceControl = conflictArtifactSourceControlSnapshot(freshness);

    const report = await collectInstalledSourceControlUiE2eFreshnessReport(
      { repositoryId: session.repositoryId, epoch: session.epoch, scenario: "partial" },
      {
        generatedAt: () => "2026-06-25T00:00:10Z",
        sessionService: { listOpenSessions: vi.fn(() => [session]) },
        statusSnapshotStore: {
          getSnapshot: vi.fn(() => storedSnapshot),
          replaceSnapshot: vi.fn(() => storedSnapshot),
          markStale: vi.fn(),
        },
        sourceControlProjection: {
          getProjection: vi.fn(() => projection),
          replaceSnapshot: vi.fn(() => projection),
          markStale: vi.fn(),
        },
        statusRefreshCoverage: { getLastCompletedRefresh: vi.fn(() => undefined) },
        sourceControlSurface: { snapshotRepository: vi.fn(() => sourceControl) },
      },
    );

    expect(report.conflictArtifactSurface).toEqual({
      group: sourceControl.groups.find((group) => group.id === "conflictArtifacts"),
      counts: {
        sourceControl: 1,
        conflicts: 1,
        conflictArtifacts: 3,
        unversioned: 0,
      },
      collapseControl: {
        owner: "vscodeUserInterface",
        extensionDefaultSupported: false,
      },
    });
    expect(report.conflictArtifactSurface.group.resources).toEqual(
      CONFLICT_ARTIFACT_PATHS.map((artifactPath) => ({
        path: artifactPath,
        contextValue: "subversionr.conflictArtifact",
        kind: "file",
        generation: 3,
      })),
    );
  });

  it("reports an installed stale SourceControl freshness affordance for an open UI E2E session", async () => {
    const session = repositorySession();
    const markStale = vi.fn();

    const report = await collectInstalledSourceControlUiE2eFreshnessReport(
      {
        repositoryId: session.repositoryId,
        epoch: session.epoch,
        scenario: "stale",
      },
      {
        generatedAt: () => "2026-06-25T00:00:11Z",
        sessionService: {
          listOpenSessions: vi.fn(() => [session]),
        },
        statusSnapshotStore: {
          getSnapshot: vi.fn(() => statusSnapshot()),
          replaceSnapshot: vi.fn(),
          markStale,
        },
        sourceControlProjection: {
          getProjection: vi.fn(() => scmProjection(freshnessState("stale"))),
          replaceSnapshot: vi.fn(),
          markStale,
        },
        statusRefreshCoverage: {
          getLastCompletedRefresh: vi.fn(() => undefined),
        },
        sourceControlSurface: {
          snapshotRepository: vi.fn(() => sourceControlSnapshot(freshnessState("stale"))),
        },
      },
    );

    expect(markStale).toHaveBeenCalledWith({
      repositoryId: session.repositoryId,
      epoch: session.epoch,
      reason: "installedSourceControlUiE2e",
      timestamp: "2026-06-25T00:00:11Z",
      source: "installed-source-control-ui-e2e",
    });
    expect(markStale).toHaveBeenCalledTimes(2);
    expect(report.sourceControl.statusBarCommands).toEqual([
      {
        command: "subversionr.fullReconcile",
        title: "SVN status stale",
        arguments: [session.repositoryId],
      },
    ]);
  });
});

function repositorySession(
  overrides: {
    repositoryId?: string;
    repositoryUuid?: string;
    repositoryRootUrl?: string;
    workingCopyRoot?: string;
    workspaceScopeRoot?: string;
    boundaryRoots?: string[];
  } = {},
): RepositorySession {
  const workingCopyRoot = overrides.workingCopyRoot ?? "C:\\fixture\\wc";
  const repositoryId = overrides.repositoryId ?? "repo-uuid:C:/fixture/wc";
  return {
    repositoryId,
    epoch: 7,
    identity: {
      repositoryUuid: overrides.repositoryUuid ?? "fixture-repository-uuid",
      repositoryRootUrl: overrides.repositoryRootUrl ?? "file:///C:/fixture/repo",
      workingCopyRoot,
      workspaceScopeRoot: overrides.workspaceScopeRoot ?? workingCopyRoot,
      format: 31,
    },
    watchScope: {
      repositoryId,
      epoch: 7,
      workingCopyRoot,
      pathCase: "case-insensitive",
      boundaryRoots: overrides.boundaryRoots ?? ["C:\\fixture\\wc"],
    },
  };
}

function repositoryCandidate(
  workingCopyRoot: string,
  overrides: {
    repositoryUuid?: string;
    repositoryRootUrl?: string;
    isNested?: boolean;
    isExternal?: boolean;
    parentWorkingCopyRoot?: string;
  } = {},
): RepositoryDiscoveryCandidate {
  return {
    identity: {
      repositoryUuid: overrides.repositoryUuid ?? "fixture-repository-uuid",
      repositoryRootUrl: overrides.repositoryRootUrl ?? "file:///C:/fixture/repo",
      workingCopyRoot,
      workspaceScopeRoot: workingCopyRoot,
      format: 31,
    },
    isNested: overrides.isNested ?? false,
    isExternal: overrides.isExternal ?? false,
    ...(overrides.parentWorkingCopyRoot ? { parentWorkingCopyRoot: overrides.parentWorkingCopyRoot } : {}),
  };
}

function scmProjection(
  freshness: ScmRepositoryProjection["freshness"] = {
    repositoryCompleteness: "complete",
    lastRefreshCompleteness: "complete",
    lastRefreshKind: "snapshot",
  },
): ScmRepositoryProjection {
  return {
    repositoryId: "repo-uuid:C:/fixture/wc",
    epoch: 7,
    workingCopyRoot: "C:\\fixture\\wc",
    generation: 3,
    count: 1,
    freshness,
    groups: [
      { id: "conflicts", labelKey: "scm.group.conflicts", changelist: null, resources: [] },
      { id: "conflictArtifacts", labelKey: "scm.group.conflictArtifacts", changelist: null, resources: [] },
      {
        id: "changes",
        labelKey: "scm.group.changes",
        changelist: null,
        resources: [
          projectedResource({
            path: "src/tracked.txt",
            kind: "file",
            groupId: "changes",
            contextValue: "subversionr.changedFile",
            localStatus: "modified",
            nodeStatus: "modified",
          }),
        ],
      },
      {
        id: "unversioned",
        labelKey: "scm.group.unversioned",
        changelist: null,
        resources: [
          projectedResource({
            path: "scratch.txt",
            kind: "file",
            groupId: "unversioned",
            contextValue: "subversionr.unversioned",
            localStatus: "unversioned",
            nodeStatus: "unversioned",
          }),
        ],
      },
      { id: "metadata", labelKey: "scm.group.metadata", changelist: null, resources: [] },
      { id: "incoming", labelKey: "scm.group.incoming", changelist: null, resources: [] },
      { id: "externals", labelKey: "scm.group.externals", changelist: null, resources: [] },
      { id: "ignored", labelKey: "scm.group.ignored", changelist: null, resources: [] },
    ],
  };
}

function changelistScmProjection(
  freshness: ScmRepositoryProjection["freshness"],
): ScmRepositoryProjection {
  return {
    ...scmProjection(freshness),
    count: 1,
    groups: [
      { id: "conflicts", labelKey: "scm.group.conflicts", changelist: null, resources: [] },
      { id: "conflictArtifacts", labelKey: "scm.group.conflictArtifacts", changelist: null, resources: [] },
      { id: "changes", labelKey: "scm.group.changes", changelist: null, resources: [] },
      { id: "unversioned", labelKey: "scm.group.unversioned", changelist: null, resources: [] },
      { id: "metadata", labelKey: "scm.group.metadata", changelist: null, resources: [] },
      {
        id: "changelist:review",
        labelKey: "scm.group.changelist",
        changelist: "review",
        resources: [
          projectedResource({
            path: "src/tracked.txt",
            kind: "file",
            groupId: "changelist:review",
            contextValue: "subversionr.changedFile",
            localStatus: "modified",
            nodeStatus: "modified",
            changelist: "review",
          }),
        ],
      },
      { id: "incoming", labelKey: "scm.group.incoming", changelist: null, resources: [] },
      { id: "externals", labelKey: "scm.group.externals", changelist: null, resources: [] },
      { id: "ignored", labelKey: "scm.group.ignored", changelist: null, resources: [] },
    ],
  };
}

function sourceControlSnapshot(
  freshness: VscodeSourceControlSnapshot["freshness"] = {
    repositoryCompleteness: "complete",
    lastRefreshCompleteness: "complete",
    lastRefreshKind: "snapshot",
  },
): VscodeSourceControlSnapshot {
  return {
    repositoryId: "repo-uuid:C:/fixture/wc",
    epoch: 7,
    workingCopyRoot: "C:\\fixture\\wc",
    generation: 3,
    count: 1,
    freshness,
    inputBox: {
      placeholder: "SVN commit message",
      acceptInputCommand: "subversionr.commitAll",
      acceptInputCommandArguments: ["repo-uuid:C:/fixture/wc"],
    },
    statusBarCommands: freshnessCommand(freshness),
    groups: [
      { id: "conflicts", contextValue: "subversionr.conflicts", hideWhenEmpty: true, count: 0, resources: [] },
      { id: "conflictArtifacts", contextValue: "subversionr.conflictArtifacts", hideWhenEmpty: true, count: 0, resources: [] },
      {
        id: "changes",
        contextValue: "subversionr.changes",
        hideWhenEmpty: true,
        count: 1,
        resources: [
          {
            path: "src/tracked.txt",
            contextValue: "subversionr.changedFile.baseDiffable",
            kind: "file",
            generation: 3,
          },
        ],
      },
      {
        id: "unversioned",
        contextValue: "subversionr.unversioned",
        hideWhenEmpty: true,
        count: 1,
        resources: [
          {
            path: "scratch.txt",
            contextValue: "subversionr.unversioned",
            kind: "file",
            generation: 3,
          },
        ],
      },
      { id: "metadata", contextValue: "subversionr.metadata", hideWhenEmpty: true, count: 0, resources: [] },
      { id: "incoming", contextValue: "subversionr.incoming", hideWhenEmpty: true, count: 0, resources: [] },
      { id: "externals", contextValue: "subversionr.externals", hideWhenEmpty: true, count: 0, resources: [] },
      { id: "ignored", contextValue: "subversionr.ignored", hideWhenEmpty: true, count: 0, resources: [] },
    ],
  };
}

const CONFLICT_ARTIFACT_PATHS = [
  "src/tracked.txt.mine",
  "src/tracked.txt.r1",
  "src/tracked.txt.r2",
];

function conflictArtifactScmProjection(
  freshness: NonNullable<ScmRepositoryProjection["freshness"]>,
): ScmRepositoryProjection {
  const artifactResources = CONFLICT_ARTIFACT_PATHS.map((artifactPath) => {
    const resource = projectedResource({
      path: artifactPath,
      kind: "file",
      groupId: "conflictArtifacts",
      contextValue: "subversionr.conflictArtifact",
      localStatus: "unversioned",
      nodeStatus: "unversioned",
    });
    resource.tooltipKey = "scm.resource.conflictArtifact";
    return resource;
  });
  const conflictResource = projectedResource({
    path: "src/tracked.txt",
    kind: "file",
    groupId: "conflicts",
    contextValue: "subversionr.conflicted",
    localStatus: "normal",
    nodeStatus: "normal",
  });
  conflictResource.tooltipKey = "scm.resource.conflicted";
  return {
    ...scmProjection(freshness),
    count: 1,
    groups: [
      { id: "conflicts", labelKey: "scm.group.conflicts", changelist: null, resources: [conflictResource] },
      {
        id: "conflictArtifacts",
        labelKey: "scm.group.conflictArtifacts",
        changelist: null,
        resources: artifactResources,
      },
      { id: "changes", labelKey: "scm.group.changes", changelist: null, resources: [] },
      { id: "unversioned", labelKey: "scm.group.unversioned", changelist: null, resources: [] },
      { id: "metadata", labelKey: "scm.group.metadata", changelist: null, resources: [] },
      { id: "incoming", labelKey: "scm.group.incoming", changelist: null, resources: [] },
      { id: "externals", labelKey: "scm.group.externals", changelist: null, resources: [] },
      { id: "ignored", labelKey: "scm.group.ignored", changelist: null, resources: [] },
    ],
  };
}

function conflictArtifactSourceControlSnapshot(
  freshness: NonNullable<VscodeSourceControlSnapshot["freshness"]>,
): VscodeSourceControlSnapshot {
  const groups = conflictArtifactScmProjection(freshness).groups.map((group) => ({
    id: group.id,
    contextValue: `subversionr.${group.id}`,
    hideWhenEmpty: true,
    count: group.resources.length,
    resources: group.resources.map((resource) => ({
      path: resource.path,
      contextValue: resource.contextValue,
      kind: resource.entry.kind,
      generation: 3,
    })),
  }));
  return {
    ...sourceControlSnapshot(freshness),
    count: 1,
    groups,
  };
}

function changelistSourceControlSnapshot(
  freshness: VscodeSourceControlSnapshot["freshness"],
): VscodeSourceControlSnapshot {
  return {
    ...sourceControlSnapshot(freshness),
    count: 1,
    groups: [
      { id: "conflicts", contextValue: "subversionr.conflicts", hideWhenEmpty: true, count: 0, resources: [] },
      { id: "conflictArtifacts", contextValue: "subversionr.conflictArtifacts", hideWhenEmpty: true, count: 0, resources: [] },
      { id: "changes", contextValue: "subversionr.changes", hideWhenEmpty: true, count: 0, resources: [] },
      { id: "unversioned", contextValue: "subversionr.unversioned", hideWhenEmpty: true, count: 0, resources: [] },
      { id: "metadata", contextValue: "subversionr.metadata", hideWhenEmpty: true, count: 0, resources: [] },
      {
        id: "changelist:review",
        contextValue: "subversionr.changelist",
        hideWhenEmpty: true,
        count: 1,
        resources: [
          {
            path: "src/tracked.txt",
            contextValue: "subversionr.changedFile.baseDiffable.changelisted",
            kind: "file",
            generation: 3,
          },
        ],
      },
      { id: "incoming", contextValue: "subversionr.incoming", hideWhenEmpty: true, count: 0, resources: [] },
      { id: "externals", contextValue: "subversionr.externals", hideWhenEmpty: true, count: 0, resources: [] },
      { id: "ignored", contextValue: "subversionr.ignored", hideWhenEmpty: true, count: 0, resources: [] },
    ],
  };
}

function sourceControlSnapshotFor(session: RepositorySession, resourcePath: string): VscodeSourceControlSnapshot {
  return {
    ...sourceControlSnapshot(),
    repositoryId: session.repositoryId,
    epoch: session.epoch,
    workingCopyRoot: session.identity.workingCopyRoot,
    inputBox: {
      placeholder: "SVN commit message",
      acceptInputCommand: "subversionr.commitAll",
      acceptInputCommandArguments: [session.repositoryId],
    },
    groups: [
      { id: "conflicts", contextValue: "subversionr.conflicts", hideWhenEmpty: true, count: 0, resources: [] },
      { id: "conflictArtifacts", contextValue: "subversionr.conflictArtifacts", hideWhenEmpty: true, count: 0, resources: [] },
      {
        id: "changes",
        contextValue: "subversionr.changes",
        hideWhenEmpty: true,
        count: 1,
        resources: [
          {
            path: resourcePath,
            contextValue: "subversionr.changedFile.baseDiffable",
            kind: "file",
            generation: 3,
          },
        ],
      },
      { id: "unversioned", contextValue: "subversionr.unversioned", hideWhenEmpty: true, count: 0, resources: [] },
      { id: "metadata", contextValue: "subversionr.metadata", hideWhenEmpty: true, count: 0, resources: [] },
      { id: "incoming", contextValue: "subversionr.incoming", hideWhenEmpty: true, count: 0, resources: [] },
      { id: "externals", contextValue: "subversionr.externals", hideWhenEmpty: true, count: 0, resources: [] },
      { id: "ignored", contextValue: "subversionr.ignored", hideWhenEmpty: true, count: 0, resources: [] },
    ],
  };
}

function freshnessCommand(freshness: VscodeSourceControlSnapshot["freshness"]): VscodeSourceControlSnapshot["statusBarCommands"] {
  if (!freshness || freshness.repositoryCompleteness === "complete") {
    return undefined;
  }
  return [
    {
      command: "subversionr.fullReconcile",
      title: `SVN status ${freshness.repositoryCompleteness}`,
      arguments: ["repo-uuid:C:/fixture/wc"],
    },
  ];
}

function freshnessState(
  repositoryCompleteness: NonNullable<VscodeSourceControlSnapshot["freshness"]>["repositoryCompleteness"],
): NonNullable<VscodeSourceControlSnapshot["freshness"]> {
  return {
    repositoryCompleteness,
    lastRefreshCompleteness: repositoryCompleteness,
    lastRefreshKind: repositoryCompleteness === "stale" ? "stale" : "snapshot",
  };
}

function statusSnapshot(): StatusSnapshot {
  return {
    repositoryId: "repo-uuid:C:/fixture/wc",
    epoch: 7,
    generation: 3,
    completeness: "complete",
    identity: repositorySession().identity,
    localEntries: [
      statusEntry({
        path: "src/tracked.txt",
        localStatus: "modified",
        nodeStatus: "modified",
      }),
    ],
    remoteEntries: [],
    summary: {
      localChanges: 1,
      remoteChanges: 0,
      conflicts: 0,
      unversioned: 0,
    },
    timestamp: "2026-06-25T00:00:00Z",
    source: "libsvn-local",
  };
}

function statusEntry(overrides: Partial<StatusSnapshot["localEntries"][number]> = {}): StatusSnapshot["localEntries"][number] {
  return {
    path: "src/tracked.txt",
    kind: "file",
    nodeStatus: "normal",
    textStatus: "normal",
    propertyStatus: "normal",
    localStatus: "normal",
    remoteStatus: "notChecked",
    revision: 1,
    changedRevision: 1,
    changedAuthor: "subversionr",
    changedDate: "2026-06-25T00:00:00Z",
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
    generation: 3,
    ...overrides,
  };
}

function projectedResource(options: {
  path: string;
  kind: string;
  groupId: ScmRepositoryProjection["groups"][number]["id"];
  contextValue: string;
  localStatus: string;
  nodeStatus: string;
  changelist?: string | null;
}): ScmRepositoryProjection["groups"][number]["resources"][number] {
  return {
    key: `local:${options.path}`,
    repositoryId: "repo-uuid:C:/fixture/wc",
    path: options.path,
    source: "local",
    groupId: options.groupId,
    contextValue: options.contextValue,
    tooltipKey: "scm.resource.changed",
    entry: {
      path: options.path,
      kind: options.kind,
      nodeStatus: options.nodeStatus,
      textStatus: options.localStatus,
      propertyStatus: "none",
      localStatus: options.localStatus,
      remoteStatus: "none",
      revision: 1,
      changedRevision: 1,
      changedAuthor: "subversionr",
      changedDate: "2026-06-25T00:00:00Z",
      changelist: options.changelist ?? null,
      lock: null,
      needsLock: false,
      copy: null,
      move: null,
      switched: false,
      depth: "infinity",
      conflict: null,
      conflictArtifacts: [],
      external: false,
      generation: 3,
    },
  };
}
