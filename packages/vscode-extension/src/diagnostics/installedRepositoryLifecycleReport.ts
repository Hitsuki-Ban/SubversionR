import type {
  RepositoryAutoOpenTrigger,
  RepositoryLifecycleEvent,
} from "../repository/repositoryLifecycleService";
import type { RepositoryLifecycleCoordinator } from "../repository/repositoryLifecycleCoordinator";
import type { PathCasePolicy } from "../status/types";

export type InstalledRepositoryLifecycleScenario = "deletedWorkingCopy" | "movedWorkingCopy";

export interface InstalledRepositoryLifecycleReportRequest {
  scenario: InstalledRepositoryLifecycleScenario;
  trigger: RepositoryAutoOpenTrigger;
  expectedRepositoryId: string;
  expectedEpoch: number;
  expectedWorkingCopyRoot: string;
  expectedMovedWorkingCopyRoot?: string;
}

export interface InstalledRepositoryLifecycleReportDependencies {
  generatedAt(): string;
  extensionVersion: string;
  pathCasePolicy(): PathCasePolicy;
  workspaceTrusted(): boolean;
  lifecycleCoordinator: Pick<RepositoryLifecycleCoordinator, "reconcileWorkspaceRepositories">;
}

export interface InstalledRepositoryLifecycleReport {
  kind: "subversionr.installedRepositoryLifecycleReport";
  generatedAt: string;
  extension: {
    name: "subversionr";
    version: string;
  };
  workspace: {
    trusted: boolean;
    pathCase: PathCasePolicy;
  };
  request: InstalledRepositoryLifecycleReportRequest;
  lifecycleWorkflow: {
    movedRecovery: true;
    disappearedCleanup: true;
    automaticOpen: true;
  };
  events: RepositoryLifecycleEvent[];
  assertions: {
    missingWorkingCopyClosed: boolean;
    movedWorkingCopyRecovered: boolean;
  };
}

export class InstalledRepositoryLifecycleReportError extends Error {
  public constructor(
    public readonly code: string,
    public readonly category: "input" | "lifecycle",
    public readonly messageKey: string,
    public readonly safeArgs: Record<string, unknown> = {},
  ) {
    super(code);
    this.name = "InstalledRepositoryLifecycleReportError";
  }
}

export async function collectInstalledRepositoryLifecycleReport(
  rawRequest: unknown,
  deps: InstalledRepositoryLifecycleReportDependencies,
): Promise<InstalledRepositoryLifecycleReport> {
  const request = parseRequest(rawRequest);
  const events = await deps.lifecycleCoordinator.reconcileWorkspaceRepositories(request.trigger);

  const missingWorkingCopyClosed = hasExpectedDeleteEvent(events, request);
  const movedWorkingCopyRecovered = hasExpectedMoveEvent(events, request);
  if (request.scenario === "deletedWorkingCopy" && !missingWorkingCopyClosed) {
    throw new InstalledRepositoryLifecycleReportError(
      "SUBVERSIONR_INSTALLED_REPOSITORY_LIFECYCLE_DELETE_EVENT_MISSING",
      "lifecycle",
      "error.diagnostics.installedRepositoryLifecycleDeleteEventMissing",
      expectedSafeArgs(request),
    );
  }
  if (request.scenario === "movedWorkingCopy" && !movedWorkingCopyRecovered) {
    throw new InstalledRepositoryLifecycleReportError(
      "SUBVERSIONR_INSTALLED_REPOSITORY_LIFECYCLE_MOVE_EVENT_MISSING",
      "lifecycle",
      "error.diagnostics.installedRepositoryLifecycleMoveEventMissing",
      expectedSafeArgs(request),
    );
  }

  return {
    kind: "subversionr.installedRepositoryLifecycleReport",
    generatedAt: deps.generatedAt(),
    extension: {
      name: "subversionr",
      version: deps.extensionVersion,
    },
    workspace: {
      trusted: deps.workspaceTrusted(),
      pathCase: deps.pathCasePolicy(),
    },
    request,
    lifecycleWorkflow: {
      movedRecovery: true,
      disappearedCleanup: true,
      automaticOpen: true,
    },
    events,
    assertions: {
      missingWorkingCopyClosed,
      movedWorkingCopyRecovered,
    },
  };
}

function parseRequest(rawRequest: unknown): InstalledRepositoryLifecycleReportRequest {
  if (!isRecord(rawRequest)) {
    throw requestRequired();
  }
  const scenario = rawRequest.scenario;
  if (scenario !== "deletedWorkingCopy" && scenario !== "movedWorkingCopy") {
    throw requestRequired();
  }
  const trigger = rawRequest.trigger;
  if (trigger !== "activation" && trigger !== "workspaceTrust" && trigger !== "workspaceFolders") {
    throw requestRequired();
  }
  const expectedRepositoryId = rawRequest.expectedRepositoryId;
  if (typeof expectedRepositoryId !== "string" || expectedRepositoryId.trim().length === 0) {
    throw requestRequired();
  }
  const expectedEpoch = rawRequest.expectedEpoch;
  if (typeof expectedEpoch !== "number" || !Number.isInteger(expectedEpoch) || expectedEpoch < 0) {
    throw requestRequired();
  }
  const expectedWorkingCopyRoot = rawRequest.expectedWorkingCopyRoot;
  if (!isAbsoluteNonEmptyPath(expectedWorkingCopyRoot)) {
    throw requestRequired();
  }
  const expectedMovedWorkingCopyRoot = rawRequest.expectedMovedWorkingCopyRoot;
  if (scenario === "movedWorkingCopy" && !isAbsoluteNonEmptyPath(expectedMovedWorkingCopyRoot)) {
    throw requestRequired();
  }

  return {
    scenario,
    trigger,
    expectedRepositoryId,
    expectedEpoch,
    expectedWorkingCopyRoot,
    ...(isAbsoluteNonEmptyPath(expectedMovedWorkingCopyRoot) ? { expectedMovedWorkingCopyRoot } : {}),
  };
}

function hasExpectedDeleteEvent(
  events: RepositoryLifecycleEvent[],
  request: InstalledRepositoryLifecycleReportRequest,
): boolean {
  return events.some(
    (event) =>
      event.kind === "openSessionClosed" &&
      event.reason === "workingCopyMissing" &&
      event.repositoryId === request.expectedRepositoryId &&
      event.epoch === request.expectedEpoch &&
      samePath(event.workingCopyRoot, request.expectedWorkingCopyRoot),
  );
}

function hasExpectedMoveEvent(
  events: RepositoryLifecycleEvent[],
  request: InstalledRepositoryLifecycleReportRequest,
): boolean {
  return events.some(
    (event) =>
      event.kind === "openSessionMoved" &&
      event.previousRepositoryId === request.expectedRepositoryId &&
      event.previousEpoch === request.expectedEpoch &&
      samePath(event.previousWorkingCopyRoot, request.expectedWorkingCopyRoot) &&
      request.expectedMovedWorkingCopyRoot !== undefined &&
      samePath(event.workingCopyRoot, request.expectedMovedWorkingCopyRoot),
  );
}

function expectedSafeArgs(request: InstalledRepositoryLifecycleReportRequest): Record<string, unknown> {
  return {
    expectedRepositoryId: request.expectedRepositoryId,
    expectedEpoch: request.expectedEpoch,
    expectedWorkingCopyRoot: request.expectedWorkingCopyRoot,
    ...(request.expectedMovedWorkingCopyRoot ? { expectedMovedWorkingCopyRoot: request.expectedMovedWorkingCopyRoot } : {}),
  };
}

function requestRequired(): InstalledRepositoryLifecycleReportError {
  return new InstalledRepositoryLifecycleReportError(
    "SUBVERSIONR_INSTALLED_REPOSITORY_LIFECYCLE_REQUEST_REQUIRED",
    "input",
    "error.diagnostics.installedRepositoryLifecycleRequestRequired",
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function isAbsoluteNonEmptyPath(value: unknown): value is string {
  if (typeof value !== "string" || value.trim().length === 0 || value.includes("\0")) {
    return false;
  }
  return /^[a-zA-Z]:[\\/]/u.test(value) || value.startsWith("/") || value.startsWith("\\\\");
}

function samePath(left: string, right: string): boolean {
  return normalizePath(left) === normalizePath(right);
}

function normalizePath(value: string): string {
  const normalized = value.replace(/\\/g, "/").replace(/\/+$/u, "");
  return process.platform === "win32" ? normalized.toLocaleLowerCase("en-US") : normalized;
}
