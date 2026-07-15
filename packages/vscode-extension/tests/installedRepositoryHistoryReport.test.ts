import { describe, expect, it, vi } from "vitest";
import {
  collectInstalledRepositoryHistoryReport,
  InstalledRepositoryHistoryReportError,
} from "../src/diagnostics/installedRepositoryHistoryReport";
import type { RepositorySession } from "../src/repository/repositorySessionService";
import type { VscodeSourceControlSnapshot } from "../src/scm/vscodeSourceControlPresenter";

describe("collectInstalledRepositoryHistoryReport", () => {
  it("reports an unloaded read-only baseline with cumulative activity", () => {
    const report = collectInstalledRepositoryHistoryReport(
      { repositoryId: "repo-uuid:C:/wc", epoch: 7 },
      dependencies(),
    );

    expect(report).toMatchObject({
      kind: "subversionr.installedSourceControlUiE2eRepositoryHistoryReport",
      repository: {
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        identity: { workingCopyRoot: "C:/wc" },
      },
      history: {
        loaded: false,
        target: null,
        entryCount: 0,
        entries: [],
        treeView: { visible: false, selectionCount: 0, selectedTargetLabel: null },
      },
      activity: {
        statusRefreshRequestCount: 3,
        reconcileRequestCount: 2,
        remoteStatusRequestCount: 1,
      },
      diagnostics: { lineCount: 0, latestHistoryTargetingError: null },
    });
  });

  it("reports loaded repository history and the latest bounded targeting error", () => {
    const diagnosticsLine = JSON.stringify({
      operation: "History",
      code: "SUBVERSIONR_HISTORY_REPOSITORY_SESSION_STALE",
      category: "lifecycle",
      messageKey: "error.repository.historyRepositorySessionStale",
      retryable: false,
      args: { repositoryId: "repo-uuid:C:/wc", expectedEpoch: 6, actualEpoch: 7 },
      diagnostics: null,
    });
    const report = collectInstalledRepositoryHistoryReport(
      { repositoryId: "repo-uuid:C:/wc", epoch: 7 },
      dependencies({
        historySnapshot: () => ({
          target: {
            kind: "repository",
            repositoryId: "repo-uuid:C:/wc",
            epoch: 7,
            path: ".",
            label: "C:/wc",
          },
          entryCount: 2,
          entries: [
            { revision: 2, author: null, message: "missing author" },
            { revision: 1, author: null, message: "empty author" },
          ],
        }),
        historyTreeViewSnapshot: () => ({
          visible: true,
          selectionCount: 1,
          selectedTargetLabel: "C:/wc",
        }),
        diagnostics: [diagnosticsLine],
      }),
    );

    expect(report.history).toMatchObject({
      loaded: true,
      entryCount: 2,
      treeView: { visible: true, selectionCount: 1, selectedTargetLabel: "C:/wc" },
    });
    expect(report.diagnostics.latestHistoryTargetingError).toEqual({
      code: "SUBVERSIONR_HISTORY_REPOSITORY_SESSION_STALE",
      messageKey: "error.repository.historyRepositorySessionStale",
      safeArgs: { repositoryId: "repo-uuid:C:/wc", expectedEpoch: 6, actualEpoch: 7 },
    });
  });

  it("rejects invalid and stale requests without selecting another session", () => {
    expect(() => collectInstalledRepositoryHistoryReport("repo-uuid:C:/wc", dependencies())).toThrow(
      InstalledRepositoryHistoryReportError,
    );
    expect(() =>
      collectInstalledRepositoryHistoryReport(
        { repositoryId: "repo-uuid:C:/wc", epoch: 6 },
        dependencies(),
      ),
    ).toThrow("SUBVERSIONR_INSTALLED_UI_E2E_REPOSITORY_HISTORY_SESSION_NOT_OPEN");
  });
});

function dependencies(overrides: {
  historySnapshot?: () => ReturnType<Parameters<typeof collectInstalledRepositoryHistoryReport>[1]["historySnapshot"]>;
  historyTreeViewSnapshot?: () => { visible: boolean; selectionCount: number; selectedTargetLabel: string | null };
  diagnostics?: string[];
} = {}): Parameters<typeof collectInstalledRepositoryHistoryReport>[1] {
  return {
    generatedAt: () => "2026-07-15T00:00:00.000Z",
    sessionService: { listOpenSessions: vi.fn(() => [repositorySession()]) },
    historySnapshot: overrides.historySnapshot ?? (() => undefined),
    historyTreeViewSnapshot: overrides.historyTreeViewSnapshot ?? (() => ({
      visible: false,
      selectionCount: 0,
      selectedTargetLabel: null,
    })),
    sourceControlSurface: { snapshotRepository: vi.fn(() => sourceControlSnapshot()) },
    lastCompletedRefresh: vi.fn(() => undefined),
    operationDiagnostics: { snapshot: vi.fn(() => overrides.diagnostics ?? []) },
    activity: () => ({
      statusRefreshRequestCount: 3,
      reconcileRequestCount: 2,
      remoteStatusRequestCount: 1,
    }),
  };
}

function repositorySession(): RepositorySession {
  return {
    repositoryId: "repo-uuid:C:/wc",
    epoch: 7,
    identity: {
      repositoryUuid: "repo-uuid",
      repositoryRootUrl: "file:///C:/repo",
      workingCopyRoot: "C:/wc",
      workspaceScopeRoot: "C:/wc",
      format: 31,
    },
    watchScope: {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      workingCopyRoot: "C:/wc",
      pathCase: "case-insensitive",
    },
  };
}

function sourceControlSnapshot(): VscodeSourceControlSnapshot {
  return {
    repositoryId: "repo-uuid:C:/wc",
    epoch: 7,
    workingCopyRoot: "C:/wc",
    generation: 11,
    freshness: undefined,
    count: 0,
    statusBarCommands: [],
    inputBox: {
      placeholder: "SVN commit message",
      acceptInputCommand: undefined,
      acceptInputCommandArguments: undefined,
    },
    groups: [],
  };
}
