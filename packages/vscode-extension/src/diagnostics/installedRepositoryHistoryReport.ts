import type { OperationDiagnostics } from "./operationDiagnostics";
import type { LoadedHistorySnapshot } from "../history/historyTreeDataProvider";
import type { RepositorySession, RepositorySessionService } from "../repository/repositorySessionService";
import type { VscodeSourceControlSnapshot } from "../scm/vscodeSourceControlPresenter";
import type { CompletedStatusRefreshCoverage } from "../status/statusRefreshScheduler";

export interface InstalledRepositoryHistoryReportRequest {
  repositoryId: string;
  epoch: number;
}

export interface InstalledRepositoryHistoryActivity {
  statusRefreshRequestCount: number;
  reconcileRequestCount: number;
  remoteStatusRequestCount: number;
}

export interface InstalledRepositoryHistoryTreeViewSnapshot {
  visible: boolean;
  selectionCount: number;
  selectedTargetLabel: string | null;
}

export interface InstalledRepositoryHistoryReportDependencies {
  generatedAt(): string;
  sessionService: Pick<RepositorySessionService, "listOpenSessions">;
  historySnapshot(): LoadedHistorySnapshot | undefined;
  historyTreeViewSnapshot(): InstalledRepositoryHistoryTreeViewSnapshot;
  sourceControlSurface: {
    snapshotRepository(repositoryId: string): VscodeSourceControlSnapshot | undefined;
  };
  lastCompletedRefresh(repositoryId: string, epoch: number): CompletedStatusRefreshCoverage | undefined;
  operationDiagnostics: Pick<OperationDiagnostics, "snapshot">;
  activity(): InstalledRepositoryHistoryActivity;
}

export interface InstalledRepositoryHistoryReport {
  kind: "subversionr.installedSourceControlUiE2eRepositoryHistoryReport";
  generatedAt: string;
  repository: {
    repositoryId: string;
    epoch: number;
    identity: RepositorySession["identity"];
  };
  history: {
    loaded: boolean;
    target: LoadedHistorySnapshot["target"] | null;
    entryCount: number;
    entries: LoadedHistorySnapshot["entries"];
    treeView: InstalledRepositoryHistoryTreeViewSnapshot;
  };
  sourceControl: VscodeSourceControlSnapshot;
  lastCompletedRefresh?: CompletedStatusRefreshCoverage;
  activity: InstalledRepositoryHistoryActivity;
  diagnostics: {
    lineCount: number;
    lines: readonly string[];
    latestHistoryTargetingError: {
      code: string;
      messageKey: string;
      safeArgs: Record<string, unknown>;
    } | null;
  };
}

const HISTORY_TARGETING_ERROR_CODES = new Set([
  "SUBVERSIONR_HISTORY_REPOSITORY_ID_INVALID",
  "SUBVERSIONR_HISTORY_REPOSITORY_NOT_OPEN",
  "SUBVERSIONR_HISTORY_REPOSITORY_SESSION_STALE",
]);

export function collectInstalledRepositoryHistoryReport(
  rawRequest: unknown,
  deps: InstalledRepositoryHistoryReportDependencies,
): InstalledRepositoryHistoryReport {
  const request = parseRequest(rawRequest);
  const session = deps.sessionService
    .listOpenSessions()
    .find((candidate) => candidate.repositoryId === request.repositoryId && candidate.epoch === request.epoch);
  if (!session) {
    throw reportError(
      "SUBVERSIONR_INSTALLED_UI_E2E_REPOSITORY_HISTORY_SESSION_NOT_OPEN",
      "lifecycle",
      "error.diagnostics.installedRepositoryHistorySessionNotOpen",
      { repositoryId: request.repositoryId, epoch: request.epoch },
    );
  }
  const sourceControl = deps.sourceControlSurface.snapshotRepository(request.repositoryId);
  if (!sourceControl) {
    throw reportError(
      "SUBVERSIONR_INSTALLED_UI_E2E_REPOSITORY_HISTORY_SOURCE_CONTROL_MISSING",
      "lifecycle",
      "error.diagnostics.installedRepositoryHistorySourceControlMissing",
      { repositoryId: request.repositoryId, epoch: request.epoch },
    );
  }
  const history = deps.historySnapshot();
  const lines = deps.operationDiagnostics.snapshot();
  const lastCompletedRefresh = deps.lastCompletedRefresh(request.repositoryId, request.epoch);
  return {
    kind: "subversionr.installedSourceControlUiE2eRepositoryHistoryReport",
    generatedAt: deps.generatedAt(),
    repository: {
      repositoryId: session.repositoryId,
      epoch: session.epoch,
      identity: { ...session.identity },
    },
    history: {
      loaded: history !== undefined,
      target: history ? { ...history.target } : null,
      entryCount: history?.entryCount ?? 0,
      entries: history ? history.entries.map((entry) => ({ ...entry })) : [],
      treeView: { ...deps.historyTreeViewSnapshot() },
    },
    sourceControl,
    ...(lastCompletedRefresh ? { lastCompletedRefresh } : {}),
    activity: validateActivity(deps.activity()),
    diagnostics: {
      lineCount: lines.length,
      lines,
      latestHistoryTargetingError: latestHistoryTargetingError(lines),
    },
  };
}

export class InstalledRepositoryHistoryReportError extends Error {
  public readonly retryable = false;
  public readonly diagnostics = null;

  public constructor(
    public readonly code: string,
    public readonly category: "input" | "lifecycle",
    public readonly messageKey: string,
    public readonly safeArgs: Record<string, unknown>,
  ) {
    super(code);
    this.name = "InstalledRepositoryHistoryReportError";
  }
}

function parseRequest(rawRequest: unknown): InstalledRepositoryHistoryReportRequest {
  if (typeof rawRequest !== "object" || rawRequest === null || Array.isArray(rawRequest)) {
    throw invalidRequest();
  }
  const request = rawRequest as Record<string, unknown>;
  const keys = Object.keys(request).sort();
  if (
    keys.length !== 2 ||
    keys[0] !== "epoch" ||
    keys[1] !== "repositoryId" ||
    typeof request.repositoryId !== "string" ||
    request.repositoryId.length === 0 ||
    request.repositoryId !== request.repositoryId.trim() ||
    !Number.isSafeInteger(request.epoch) ||
    (request.epoch as number) < 0
  ) {
    throw invalidRequest();
  }
  return { repositoryId: request.repositoryId, epoch: request.epoch as number };
}

function validateActivity(activity: InstalledRepositoryHistoryActivity): InstalledRepositoryHistoryActivity {
  for (const value of Object.values(activity)) {
    if (!Number.isSafeInteger(value) || value < 0) {
      throw reportError(
        "SUBVERSIONR_INSTALLED_UI_E2E_REPOSITORY_HISTORY_ACTIVITY_INVALID",
        "lifecycle",
        "error.diagnostics.installedRepositoryHistoryActivityInvalid",
      );
    }
  }
  return { ...activity };
}

function latestHistoryTargetingError(
  lines: readonly string[],
): InstalledRepositoryHistoryReport["diagnostics"]["latestHistoryTargetingError"] {
  for (let index = lines.length - 1; index >= 0; index -= 1) {
    const line = lines[index];
    if (!line) {
      continue;
    }
    try {
      const value = JSON.parse(line) as Record<string, unknown>;
      if (
        typeof value.code === "string" &&
        HISTORY_TARGETING_ERROR_CODES.has(value.code) &&
        typeof value.messageKey === "string" &&
        value.args !== null &&
        typeof value.args === "object" &&
        !Array.isArray(value.args)
      ) {
        return {
          code: value.code,
          messageKey: value.messageKey,
          safeArgs: value.args as Record<string, unknown>,
        };
      }
    } catch {
      continue;
    }
  }
  return null;
}

function invalidRequest(): InstalledRepositoryHistoryReportError {
  return reportError(
    "SUBVERSIONR_INSTALLED_UI_E2E_REPOSITORY_HISTORY_REQUEST_INVALID",
    "input",
    "error.diagnostics.installedRepositoryHistoryRequestInvalid",
  );
}

function reportError(
  code: string,
  category: "input" | "lifecycle",
  messageKey: string,
  safeArgs: Record<string, unknown> = {},
): InstalledRepositoryHistoryReportError {
  return new InstalledRepositoryHistoryReportError(code, category, messageKey, safeArgs);
}
