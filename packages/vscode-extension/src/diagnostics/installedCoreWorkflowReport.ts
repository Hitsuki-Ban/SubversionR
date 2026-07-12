import path from "node:path";
import type { RepositorySession, RepositorySessionService } from "../repository/repositorySessionService";
import type { ScmProjectedResource, ScmRepositoryProjection } from "../scm/sourceControlResourceStore";
import type { SourceControlProjectionService } from "../scm/sourceControlProjectionService";
import type { PathCasePolicy } from "../status/types";

export interface InstalledCoreWorkflowReportRequest {
  path: string;
}

export interface InstalledCoreWorkflowReportDependencies {
  generatedAt(): string;
  extensionVersion: string;
  pathCasePolicy(): PathCasePolicy;
  workspaceTrusted(): boolean;
  sessionService: Pick<RepositorySessionService, "listOpenSessions" | "openWorkingCopy" | "closeRepository">;
  sourceControlProjection: Pick<SourceControlProjectionService, "getProjection">;
}

export interface InstalledCoreWorkflowReport {
  kind: "subversionr.installedCoreWorkflowReport";
  generatedAt: string;
  extension: {
    name: "subversionr";
    version: string;
  };
  workspace: {
    trusted: boolean;
    pathCase: PathCasePolicy;
  };
  repository: {
    repositoryId: string;
    epoch: number;
    identity: RepositorySession["identity"];
  };
  backendWorkflow: {
    repositoryOpen: true;
    statusSnapshot: true;
    scmProjection: true;
    sessionSource: "organic-activation" | "report-open";
    repositoryClosed: boolean;
  };
  projection: {
    generation: number;
    count: number;
    groups: InstalledCoreWorkflowGroup[];
  };
}

export interface InstalledCoreWorkflowGroup {
  id: string;
  count: number;
  resources: InstalledCoreWorkflowResource[];
}

export interface InstalledCoreWorkflowResource {
  path: string;
  source: "local" | "remote";
  contextValue: string;
  localStatus: string;
  nodeStatus: string;
}

export class InstalledCoreWorkflowReportError extends Error {
  public constructor(
    public readonly code: string,
    public readonly category: "input" | "lifecycle",
    public readonly messageKey: string,
    public readonly safeArgs: Record<string, unknown> = {},
  ) {
    super(code);
    this.name = "InstalledCoreWorkflowReportError";
  }
}

export async function collectInstalledCoreWorkflowReport(
  rawRequest: unknown,
  deps: InstalledCoreWorkflowReportDependencies,
): Promise<InstalledCoreWorkflowReport> {
  const request = parseRequest(rawRequest);
  const pathCase = deps.pathCasePolicy();
  let session: RepositorySession | undefined;
  let sessionSource: "organic-activation" | "report-open" = "report-open";
  let openedByReport = false;
  let closeAttempted = false;

  try {
    session = deps.sessionService
      .listOpenSessions()
      .find(
        (candidate) =>
          normalizeForCase(candidate.identity.workingCopyRoot, pathCase) ===
          normalizeForCase(request.path, pathCase),
      );
    if (session) {
      sessionSource = "organic-activation";
    } else {
      session = await deps.sessionService.openWorkingCopy({
        path: request.path,
        pathCase,
      });
      openedByReport = true;
    }
    const projection = deps.sourceControlProjection.getProjection(session.repositoryId);
    if (!projection) {
      throw new InstalledCoreWorkflowReportError(
        "SUBVERSIONR_INSTALLED_CORE_WORKFLOW_PROJECTION_MISSING",
        "lifecycle",
        "error.diagnostics.installedCoreWorkflowProjectionMissing",
        { repositoryId: session.repositoryId },
      );
    }
    if (projection.repositoryId !== session.repositoryId || projection.epoch !== session.epoch) {
      throw new InstalledCoreWorkflowReportError(
        "SUBVERSIONR_INSTALLED_CORE_WORKFLOW_PROJECTION_MISMATCH",
        "lifecycle",
        "error.diagnostics.installedCoreWorkflowProjectionMismatch",
        {
          repositoryId: session.repositoryId,
          epoch: session.epoch,
        },
      );
    }

    if (openedByReport) {
      closeAttempted = true;
      await deps.sessionService.closeRepository(session.repositoryId);
    }
    return buildReport({
      generatedAt: deps.generatedAt(),
      extensionVersion: deps.extensionVersion,
      workspaceTrusted: deps.workspaceTrusted(),
      pathCase,
      session,
      projection,
      sessionSource,
      repositoryClosed: openedByReport,
    });
  } finally {
    if (session && openedByReport && !closeAttempted) {
      await deps.sessionService.closeRepository(session.repositoryId);
    }
  }
}

function parseRequest(rawRequest: unknown): InstalledCoreWorkflowReportRequest {
  if (!isRecord(rawRequest)) {
    throw pathRequired();
  }
  const pathValue = rawRequest.path;
  if (
    typeof pathValue !== "string" ||
    pathValue.trim().length === 0 ||
    pathValue.includes("\0") ||
    !isAbsolutePath(pathValue)
  ) {
    throw pathRequired();
  }
  return {
    path: pathValue,
  };
}

function buildReport(options: {
  generatedAt: string;
  extensionVersion: string;
  workspaceTrusted: boolean;
  pathCase: PathCasePolicy;
  session: RepositorySession;
  projection: ScmRepositoryProjection;
  sessionSource: "organic-activation" | "report-open";
  repositoryClosed: boolean;
}): InstalledCoreWorkflowReport {
  return {
    kind: "subversionr.installedCoreWorkflowReport",
    generatedAt: options.generatedAt,
    extension: {
      name: "subversionr",
      version: options.extensionVersion,
    },
    workspace: {
      trusted: options.workspaceTrusted,
      pathCase: options.pathCase,
    },
    repository: {
      repositoryId: options.session.repositoryId,
      epoch: options.session.epoch,
      identity: options.session.identity,
    },
    backendWorkflow: {
      repositoryOpen: true,
      statusSnapshot: true,
      scmProjection: true,
      sessionSource: options.sessionSource,
      repositoryClosed: options.repositoryClosed,
    },
    projection: {
      generation: options.projection.generation,
      count: options.projection.count,
      groups: options.projection.groups
        .filter((group) => group.resources.length > 0)
        .map((group) => ({
          id: group.id,
          count: group.resources.length,
          resources: group.resources.map(workflowResource),
        })),
    },
  };
}

function workflowResource(resource: ScmProjectedResource): InstalledCoreWorkflowResource {
  return {
    path: resource.path,
    source: resource.source,
    contextValue: resource.contextValue,
    localStatus: resource.entry.localStatus,
    nodeStatus: resource.entry.nodeStatus,
  };
}

function pathRequired(): InstalledCoreWorkflowReportError {
  return new InstalledCoreWorkflowReportError(
    "SUBVERSIONR_INSTALLED_CORE_WORKFLOW_PATH_REQUIRED",
    "input",
    "error.diagnostics.installedCoreWorkflowPathRequired",
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function isAbsolutePath(candidate: string): boolean {
  return path.isAbsolute(candidate) || path.win32.isAbsolute(candidate) || path.posix.isAbsolute(candidate);
}

function normalizeForCase(candidate: string, pathCase: PathCasePolicy): string {
  const normalized = candidate.replaceAll("\\", "/").replace(/\/+$/u, "");
  return pathCase === "case-insensitive" ? normalized.toLocaleLowerCase("en-US") : normalized;
}
