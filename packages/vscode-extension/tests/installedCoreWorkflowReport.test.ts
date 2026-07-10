import { describe, expect, it, vi } from "vitest";
import {
  collectInstalledCoreWorkflowReport,
  InstalledCoreWorkflowReportError,
} from "../src/diagnostics/installedCoreWorkflowReport";
import type { RepositorySession } from "../src/repository/repositorySessionService";
import type { ScmRepositoryProjection } from "../src/scm/sourceControlResourceStore";

describe("collectInstalledCoreWorkflowReport", () => {
  it("opens a working copy through the repository session service and reports SCM projection groups", async () => {
    const session = repositorySession();
    const projection = scmProjection();
    const sessionService = {
      openWorkingCopy: vi.fn(async () => session),
      closeRepository: vi.fn(async () => undefined),
    };

    const report = await collectInstalledCoreWorkflowReport(
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
      },
    );

    expect(sessionService.openWorkingCopy).toHaveBeenCalledWith({
      path: "C:\\fixture\\wc",
      pathCase: "case-insensitive",
    });
    expect(sessionService.closeRepository).toHaveBeenCalledWith("repo-uuid:C:/fixture/wc");
    expect(report).toMatchObject({
      kind: "subversionr.installedCoreWorkflowReport",
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
        identity: {
          repositoryUuid: "fixture-repository-uuid",
          workingCopyRoot: "C:\\fixture\\wc",
        },
      },
      backendWorkflow: {
        repositoryOpen: true,
        statusSnapshot: true,
        scmProjection: true,
        repositoryClosed: true,
      },
      projection: {
        generation: 3,
        count: 2,
      },
    });
    expect(report.projection.groups).toEqual([
      {
        id: "changes",
        count: 1,
        resources: [
          {
            path: "src/tracked.txt",
            source: "local",
            contextValue: "subversionr.changedFile",
            localStatus: "modified",
            nodeStatus: "modified",
          },
        ],
      },
      {
        id: "unversioned",
        count: 1,
        resources: [
          {
            path: "scratch.txt",
            source: "local",
            contextValue: "subversionr.unversioned",
            localStatus: "unversioned",
            nodeStatus: "unversioned",
          },
        ],
      },
    ]);
  });

  it("rejects a missing path before opening a repository", async () => {
    const sessionService = {
      openWorkingCopy: vi.fn(),
      closeRepository: vi.fn(),
    };

    await expect(
      collectInstalledCoreWorkflowReport(
        {},
        {
          generatedAt: () => "2026-06-25T00:00:00Z",
          extensionVersion: "0.1.0",
          pathCasePolicy: () => "case-insensitive",
          workspaceTrusted: () => true,
          sessionService,
          sourceControlProjection: {
            getProjection: vi.fn(),
          },
        },
      ),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_CORE_WORKFLOW_PATH_REQUIRED",
      messageKey: "error.diagnostics.installedCoreWorkflowPathRequired",
    });
    expect(sessionService.openWorkingCopy).not.toHaveBeenCalled();
  });

  it("closes the opened repository when the SCM projection is missing", async () => {
    const session = repositorySession();
    const sessionService = {
      openWorkingCopy: vi.fn(async () => session),
      closeRepository: vi.fn(async () => undefined),
    };

    await expect(
      collectInstalledCoreWorkflowReport(
        { path: "C:\\fixture\\wc" },
        {
          generatedAt: () => "2026-06-25T00:00:00Z",
          extensionVersion: "0.1.0",
          pathCasePolicy: () => "case-insensitive",
          workspaceTrusted: () => true,
          sessionService,
          sourceControlProjection: {
            getProjection: vi.fn(() => undefined),
          },
        },
      ),
    ).rejects.toBeInstanceOf(InstalledCoreWorkflowReportError);
    expect(sessionService.closeRepository).toHaveBeenCalledWith("repo-uuid:C:/fixture/wc");
  });

  it("closes the opened repository when the SCM projection belongs to another epoch", async () => {
    const session = repositorySession();
    const sessionService = {
      openWorkingCopy: vi.fn(async () => session),
      closeRepository: vi.fn(async () => undefined),
    };

    await expect(
      collectInstalledCoreWorkflowReport(
        { path: "C:\\fixture\\wc" },
        {
          generatedAt: () => "2026-06-25T00:00:00Z",
          extensionVersion: "0.1.0",
          pathCasePolicy: () => "case-insensitive",
          workspaceTrusted: () => true,
          sessionService,
          sourceControlProjection: {
            getProjection: vi.fn(() => ({
              ...scmProjection(),
              epoch: 8,
            })),
          },
        },
      ),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_CORE_WORKFLOW_PROJECTION_MISMATCH",
      category: "lifecycle",
      messageKey: "error.diagnostics.installedCoreWorkflowProjectionMismatch",
      safeArgs: {
        repositoryId: "repo-uuid:C:/fixture/wc",
        epoch: 7,
      },
    });
    expect(sessionService.closeRepository).toHaveBeenCalledTimes(1);
    expect(sessionService.closeRepository).toHaveBeenCalledWith("repo-uuid:C:/fixture/wc");
  });

  it("does not retry close when the explicit close step fails", async () => {
    const session = repositorySession();
    const closeError = new Error("close failed");
    const sessionService = {
      openWorkingCopy: vi.fn(async () => session),
      closeRepository: vi.fn(async () => {
        throw closeError;
      }),
    };

    await expect(
      collectInstalledCoreWorkflowReport(
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
        },
      ),
    ).rejects.toBe(closeError);
    expect(sessionService.closeRepository).toHaveBeenCalledTimes(1);
  });
});

function repositorySession(): RepositorySession {
  return {
    repositoryId: "repo-uuid:C:/fixture/wc",
    epoch: 7,
    identity: {
      repositoryUuid: "fixture-repository-uuid",
      repositoryRootUrl: "file:///C:/fixture/repo",
      workingCopyRoot: "C:\\fixture\\wc",
      workspaceScopeRoot: "C:\\fixture\\wc",
      format: 31,
    },
    watchScope: {
      repositoryId: "repo-uuid:C:/fixture/wc",
      epoch: 7,
      workingCopyRoot: "C:\\fixture\\wc",
      pathCase: "case-insensitive",
      boundaryRoots: ["C:\\fixture\\wc"],
    },
  };
}

function scmProjection(): ScmRepositoryProjection {
  const trackedEntry = statusEntry({
    path: "src/tracked.txt",
    localStatus: "modified",
    nodeStatus: "modified",
    textStatus: "modified",
  });
  const unversionedEntry = statusEntry({
    path: "scratch.txt",
    kind: "unknown",
    localStatus: "unversioned",
    nodeStatus: "unversioned",
    textStatus: "unversioned",
  });
  return {
    repositoryId: "repo-uuid:C:/fixture/wc",
    epoch: 7,
    workingCopyRoot: "C:\\fixture\\wc",
    generation: 3,
    count: 2,
    freshness: {
      repositoryCompleteness: "complete",
      lastRefreshCompleteness: "complete",
      lastRefreshKind: "snapshot",
    },
    groups: [
      {
        id: "conflicts",
        labelKey: "scm.group.conflicts",
        changelist: null,
        resources: [],
      },
      {
        id: "changes",
        labelKey: "scm.group.changes",
        changelist: null,
        resources: [
          {
            key: "local:src/tracked.txt",
            repositoryId: "repo-uuid:C:/fixture/wc",
            path: "src/tracked.txt",
            source: "local",
            groupId: "changes",
            contextValue: "subversionr.changedFile",
            tooltipKey: "scm.resource.changed",
            entry: trackedEntry,
          },
        ],
      },
      {
        id: "unversioned",
        labelKey: "scm.group.unversioned",
        changelist: null,
        resources: [
          {
            key: "local:scratch.txt",
            repositoryId: "repo-uuid:C:/fixture/wc",
            path: "scratch.txt",
            source: "local",
            groupId: "unversioned",
            contextValue: "subversionr.unversioned",
            tooltipKey: "scm.resource.unversioned",
            entry: unversionedEntry,
          },
        ],
      },
      {
        id: "incoming",
        labelKey: "scm.group.incoming",
        changelist: null,
        resources: [],
      },
      {
        id: "externals",
        labelKey: "scm.group.externals",
        changelist: null,
        resources: [],
      },
      {
        id: "ignored",
        labelKey: "scm.group.ignored",
        changelist: null,
        resources: [],
      },
    ],
  };
}

function statusEntry(overrides: Partial<ScmRepositoryProjection["groups"][number]["resources"][number]["entry"]>) {
  return {
    path: "src/tracked.txt",
    kind: "file",
    nodeStatus: "normal",
    textStatus: "normal",
    propertyStatus: "none",
    localStatus: "normal",
    remoteStatus: "none",
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
    external: false,
    generation: 3,
    ...overrides,
  };
}
