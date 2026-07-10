import { describe, expect, it, vi } from "vitest";
import {
  collectInstalledRepositoryLifecycleReport,
  InstalledRepositoryLifecycleReportError,
} from "../src/diagnostics/installedRepositoryLifecycleReport";
import type { RepositoryLifecycleEvent } from "../src/repository/repositoryLifecycleService";

describe("collectInstalledRepositoryLifecycleReport", () => {
  it("runs installed deletion lifecycle reconciliation and reports the closed missing working copy", async () => {
    const closedEvent: RepositoryLifecycleEvent = {
      kind: "openSessionClosed",
      trigger: "workspaceFolders",
      reason: "workingCopyMissing",
      repositoryId: "repo-uuid:C:/fixture/delete-wc",
      epoch: 3,
      workingCopyRoot: "C:\\fixture\\delete-wc",
    };
    const lifecycleCoordinator = lifecycleCoordinatorForEvents({
      closeDisappeared: [closedEvent],
      autoOpen: {
        kind: "autoOpenSkipped",
        trigger: "workspaceFolders",
        reason: "noCandidates",
        candidateCount: 0,
      },
    });

    const report = await collectInstalledRepositoryLifecycleReport(
      {
        scenario: "deletedWorkingCopy",
        trigger: "workspaceFolders",
        expectedRepositoryId: "repo-uuid:C:/fixture/delete-wc",
        expectedEpoch: 3,
        expectedWorkingCopyRoot: "C:\\fixture\\delete-wc",
      },
      {
        generatedAt: () => "2026-06-25T00:00:20Z",
        extensionVersion: "0.1.0",
        pathCasePolicy: () => "case-insensitive",
        workspaceTrusted: () => true,
        lifecycleCoordinator,
      },
    );

    expect(lifecycleCoordinator.reconcileWorkspaceRepositories).toHaveBeenCalledWith("workspaceFolders");
    expect(report).toEqual({
      kind: "subversionr.installedRepositoryLifecycleReport",
      generatedAt: "2026-06-25T00:00:20Z",
      extension: {
        name: "subversionr",
        version: "0.1.0",
      },
      workspace: {
        trusted: true,
        pathCase: "case-insensitive",
      },
      request: {
        scenario: "deletedWorkingCopy",
        trigger: "workspaceFolders",
        expectedRepositoryId: "repo-uuid:C:/fixture/delete-wc",
        expectedEpoch: 3,
        expectedWorkingCopyRoot: "C:\\fixture\\delete-wc",
      },
      lifecycleWorkflow: {
        movedRecovery: true,
        disappearedCleanup: true,
        automaticOpen: true,
      },
      events: [
        closedEvent,
        {
          kind: "autoOpenSkipped",
          trigger: "workspaceFolders",
          reason: "noCandidates",
          candidateCount: 0,
        },
      ],
      assertions: {
        missingWorkingCopyClosed: true,
        movedWorkingCopyRecovered: false,
      },
    });
  });

  it("runs installed move lifecycle reconciliation and reports the moved working copy recovery", async () => {
    const movedEvent: RepositoryLifecycleEvent = {
      kind: "openSessionMoved",
      trigger: "workspaceFolders",
      previousRepositoryId: "repo-uuid:C:/fixture/move-old",
      previousEpoch: 5,
      previousWorkingCopyRoot: "C:\\fixture\\move-old",
      repositoryId: "repo-uuid:C:/fixture/move-new",
      epoch: 6,
      workingCopyRoot: "C:\\fixture\\move-new",
    };
    const lifecycleCoordinator = lifecycleCoordinatorForEvents({
      recoverMoved: [movedEvent],
      autoOpen: {
        kind: "autoOpenSkipped",
        trigger: "workspaceFolders",
        reason: "allCandidatesOpen",
        candidateCount: 1,
      },
    });

    const report = await collectInstalledRepositoryLifecycleReport(
      {
        scenario: "movedWorkingCopy",
        trigger: "workspaceFolders",
        expectedRepositoryId: "repo-uuid:C:/fixture/move-old",
        expectedEpoch: 5,
        expectedWorkingCopyRoot: "C:\\fixture\\move-old",
        expectedMovedWorkingCopyRoot: "C:\\fixture\\move-new",
      },
      {
        generatedAt: () => "2026-06-25T00:00:25Z",
        extensionVersion: "0.1.0",
        pathCasePolicy: () => "case-insensitive",
        workspaceTrusted: () => true,
        lifecycleCoordinator,
      },
    );

    expect(report.assertions).toEqual({
      missingWorkingCopyClosed: false,
      movedWorkingCopyRecovered: true,
    });
    expect(report.events).toEqual([
      movedEvent,
      {
        kind: "autoOpenSkipped",
        trigger: "workspaceFolders",
        reason: "allCandidatesOpen",
        candidateCount: 1,
      },
    ]);
  });

  it("rejects deletion reports when the missing close event is absent", async () => {
    await expect(
      collectInstalledRepositoryLifecycleReport(
        {
          scenario: "deletedWorkingCopy",
          trigger: "workspaceFolders",
          expectedRepositoryId: "repo-uuid:C:/fixture/delete-wc",
          expectedEpoch: 3,
          expectedWorkingCopyRoot: "C:\\fixture\\delete-wc",
        },
        {
          generatedAt: () => "2026-06-25T00:00:20Z",
          extensionVersion: "0.1.0",
          pathCasePolicy: () => "case-insensitive",
          workspaceTrusted: () => true,
          lifecycleCoordinator: lifecycleCoordinatorForEvents({
            closeDisappeared: [],
            autoOpen: {
              kind: "autoOpenSkipped",
              trigger: "workspaceFolders",
              reason: "noCandidates",
              candidateCount: 0,
            },
          }),
        },
      ),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_REPOSITORY_LIFECYCLE_DELETE_EVENT_MISSING",
      category: "lifecycle",
      messageKey: "error.diagnostics.installedRepositoryLifecycleDeleteEventMissing",
      safeArgs: {
        expectedRepositoryId: "repo-uuid:C:/fixture/delete-wc",
        expectedEpoch: 3,
        expectedWorkingCopyRoot: "C:\\fixture\\delete-wc",
      },
    });
  });

  it("requires the moved working-copy root for move reports", async () => {
    await expect(
      collectInstalledRepositoryLifecycleReport(
        {
          scenario: "movedWorkingCopy",
          trigger: "workspaceFolders",
          expectedRepositoryId: "repo-uuid:C:/fixture/move-old",
          expectedEpoch: 5,
          expectedWorkingCopyRoot: "C:\\fixture\\move-old",
        },
        {
          generatedAt: () => "2026-06-25T00:00:25Z",
          extensionVersion: "0.1.0",
          pathCasePolicy: () => "case-insensitive",
          workspaceTrusted: () => true,
          lifecycleCoordinator: lifecycleCoordinatorForEvents({}),
        },
      ),
    ).rejects.toBeInstanceOf(InstalledRepositoryLifecycleReportError);
  });
});

function lifecycleCoordinatorForEvents(options: {
  recoverMoved?: RepositoryLifecycleEvent[];
  closeDisappeared?: RepositoryLifecycleEvent[];
  autoOpen?: RepositoryLifecycleEvent;
}) {
  return {
    reconcileWorkspaceRepositories: vi.fn(async () => {
      if (!options.autoOpen) {
        return [
          ...(options.recoverMoved ?? []),
          ...(options.closeDisappeared ?? []),
          {
            kind: "autoOpenSkipped",
            trigger: "workspaceFolders",
            reason: "noCandidates",
            candidateCount: 0,
          } satisfies RepositoryLifecycleEvent,
        ];
      }
      return [
        ...(options.recoverMoved ?? []),
        ...(options.closeDisappeared ?? []),
        options.autoOpen,
      ];
    }),
  };
}
