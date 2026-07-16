import path from "node:path";
import type {
  RepositoryDiscoveryCandidate,
  RepositoryDiscoveryService,
} from "../repository/repositoryDiscoveryService";
import {
  discoveryBoundaryRoots,
  REPOSITORY_DISCOVERY_DEPTH,
} from "../repository/repositoryDiscoveryPlanning";
import type { RepositorySession, RepositorySessionService } from "../repository/repositorySessionService";
import type { SourceControlProjectionService } from "../scm/sourceControlProjectionService";
import type { ScmRepositoryProjection } from "../scm/sourceControlResourceStore";
import { sourceControlResourceStateContextValue } from "../scm/vscodeSourceControlPresenter";
import type {
  VscodeSourceControlGroupSnapshot,
  VscodeSourceControlSnapshot,
} from "../scm/vscodeSourceControlPresenter";
import type { StatusSnapshotStore } from "../status/statusSnapshotStore";
import type { StatusSnapshot } from "../status/statusSnapshotRpcClient";
import type { CompletedStatusRefreshCoverage } from "../status/statusRefreshScheduler";
import type { PathCasePolicy } from "../status/types";

export interface InstalledSourceControlSurfaceReportRequest {
  path: string;
}

export type InstalledSourceControlOpenRequestRelation =
  | "workingCopyRoot"
  | "subdirectory"
  | "outsideWorkingCopy";

export interface InstalledSourceControlSurfaceReportDependencies {
  generatedAt(): string;
  extensionVersion: string;
  pathCasePolicy(): PathCasePolicy;
  workspaceTrusted(): boolean;
  sessionService: Pick<RepositorySessionService, "openWorkingCopy" | "closeRepository">;
  sourceControlProjection: Pick<SourceControlProjectionService, "getProjection">;
  sourceControlSurface: {
    snapshotRepository(repositoryId: string): VscodeSourceControlSnapshot | undefined;
  };
}

export interface InstalledSourceControlSurfaceReport {
  kind: "subversionr.installedSourceControlSurfaceReport";
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
  openRequest: {
    path: string;
    relationToWorkingCopyRoot: InstalledSourceControlOpenRequestRelation;
  };
  providerResolution: {
    requestedPathResolvedToWorkingCopyRoot: boolean;
    workspaceScopeRootMatchedRequest: boolean;
    sourceControlRootMatchedWorkingCopyRoot: boolean;
    subdirectoryOpenResolvedToWorkingCopyRoot: boolean;
  };
  sourceControl: VscodeSourceControlSnapshot;
  surfaceWorkflow: {
    repositoryOpen: true;
    scmProjection: true;
    sourceControlSurface: true;
    repositoryClosed: true;
  };
}

export interface InstalledSourceControlUiE2eOpenReport {
  kind: "subversionr.installedSourceControlUiE2eOpenReport";
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
  sourceControl: VscodeSourceControlSnapshot;
  rendererCaptureExpectations: {
    viewCommand: "workbench.view.scm";
    requiredDomTokens: string[];
    requiredAccessibilityTokens: string[];
    requiredScreenshot: true;
    viewport: {
      width: 1440;
      height: 900;
    };
    scmActionSurface: {
      layout: {
        prepareCommand: "workbench.action.increaseViewSize";
        incrementCount: 1;
        minimumProviderWidth: 280;
        minimumActionsContainerWidth: 120;
      };
      primaryActions: { label: string; codicon: string }[];
      overflowSubmenus: { label: string; commands: string[] }[];
      resource: {
        pathToken: "tracked.txt";
        inlineActions: { label: string; codicon: string }[];
        contextActions: string[];
      };
      forbiddenNotificationTokens: string[];
    };
  };
  surfaceWorkflow: {
    repositoryOpen: true;
    scmProjection: true;
    sourceControlSurface: true;
    repositoryClosed: false;
  };
}

export interface InstalledSourceControlUiE2eCurrentSurfaceReport {
  kind: "subversionr.installedSourceControlUiE2eCurrentSurfaceReport";
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
  openRequest: {
    path: string;
    relationToWorkingCopyRoot: InstalledSourceControlOpenRequestRelation;
  };
  sourceControl: VscodeSourceControlSnapshot;
  surfaceWorkflow: {
    repositoryOpen: true;
    scmProjection: true;
    sourceControlSurface: true;
    repositoryClosed: false;
  };
}

export interface InstalledSourceControlUiE2eCloseReport {
  kind: "subversionr.installedSourceControlUiE2eCloseReport";
  generatedAt: string;
  repositoryId: string;
  epoch: number;
  repositoryClosed: true;
}

export interface InstalledSourceControlUiE2eLazyExternalProviderReport {
  kind: "subversionr.installedSourceControlUiE2eLazyExternalProviderReport";
  generatedAt: string;
  extension: {
    name: "subversionr";
    version: string;
  };
  workspace: {
    trusted: boolean;
    pathCase: PathCasePolicy;
  };
  request: {
    path: string;
    discoveryDepth: typeof REPOSITORY_DISCOVERY_DEPTH;
    externalsMode: "lazy";
  };
  discovery: {
    candidates: RepositoryDiscoveryCandidate[];
    fileExternalBoundaries: string[];
  };
  parentProvider: {
    repositoryId: string;
    epoch: number;
    workingCopyRoot: string;
    boundaryRoots: string[];
    sourceControl: VscodeSourceControlSnapshot;
  };
  externalProviders: {
    repositoryId: string;
    epoch: number;
    workingCopyRoot: string;
    parentWorkingCopyRoot: string;
    sourceControl: VscodeSourceControlSnapshot;
  }[];
  assertions: {
    lazyDiscoveryRequested: true;
    directoryExternalDiscovered: boolean;
    fileExternalBoundariesDiscovered: boolean;
    parentBoundaryRootsIncludedDirectoryExternal: boolean;
    parentBoundaryRootsIncludedFileExternal: boolean;
    distinctExternalProviderOpened: boolean;
    parentSourceControlExcludedExternalBoundaries: boolean;
    providersClosed: true;
  };
}

type InstalledSourceControlUiE2eFreshnessScenario = "partial" | "stale";

export interface InstalledSourceControlUiE2eFreshnessReport {
  kind: "subversionr.installedSourceControlUiE2eFreshnessReport";
  generatedAt: string;
  scenario: InstalledSourceControlUiE2eFreshnessScenario;
  repository: {
    repositoryId: string;
    epoch: number;
    identity: RepositorySession["identity"];
  };
  sourceControl: VscodeSourceControlSnapshot;
  conflictArtifactSurface: InstalledConflictArtifactSurfaceEvidence;
  lastCompletedRefresh?: CompletedStatusRefreshCoverage;
  freshnessWorkflow: {
    repositoryOpen: true;
    currentEpochMatched: true;
    sourceControlSurface: true;
  };
}

export interface InstalledConflictArtifactSurfaceEvidence {
  group: VscodeSourceControlGroupSnapshot;
  counts: {
    sourceControl: number | undefined;
    conflicts: number;
    conflictArtifacts: number;
    unversioned: number;
  };
  collapseControl: {
    owner: "vscodeUserInterface";
    extensionDefaultSupported: false;
  };
}

export class InstalledSourceControlSurfaceReportError extends Error {
  public constructor(
    public readonly code: string,
    public readonly category: "input" | "lifecycle",
    public readonly messageKey: string,
    public readonly safeArgs: Record<string, unknown> = {},
  ) {
    super(code);
    this.name = "InstalledSourceControlSurfaceReportError";
  }
}

export async function collectInstalledSourceControlSurfaceReport(
  rawRequest: unknown,
  deps: InstalledSourceControlSurfaceReportDependencies,
): Promise<InstalledSourceControlSurfaceReport> {
  const state = await openSurfaceState(rawRequest, deps);
  let closeAttempted = false;

  try {
    const report = buildReport({
      generatedAt: state.generatedAt,
      extensionVersion: deps.extensionVersion,
      workspaceTrusted: deps.workspaceTrusted(),
      pathCase: state.pathCase,
      request: state.request,
      session: state.session,
      sourceControl: nonEmptySourceControlSnapshot(state.sourceControl),
    });
    closeAttempted = true;
    await deps.sessionService.closeRepository(state.session.repositoryId);
    return report;
  } finally {
    if (!closeAttempted) {
      await deps.sessionService.closeRepository(state.session.repositoryId);
    }
  }
}

export async function collectInstalledSourceControlUiE2eOpenReport(
  rawRequest: unknown,
  deps: InstalledSourceControlSurfaceReportDependencies,
): Promise<InstalledSourceControlUiE2eOpenReport> {
  const state = await openSurfaceState(rawRequest, deps);
  return buildUiE2eOpenReport({
    generatedAt: state.generatedAt,
    extensionVersion: deps.extensionVersion,
    workspaceTrusted: deps.workspaceTrusted(),
    pathCase: state.pathCase,
    session: state.session,
    sourceControl: nonEmptySourceControlSnapshot(state.sourceControl),
  });
}

export function collectInstalledSourceControlUiE2eCurrentSurfaceReport(
  rawRequest: unknown,
  deps: {
    generatedAt(): string;
    extensionVersion: string;
    pathCasePolicy(): PathCasePolicy;
    workspaceTrusted(): boolean;
    sessionService: Pick<RepositorySessionService, "listOpenSessions">;
    sourceControlSurface: {
      snapshotRepository(repositoryId: string): VscodeSourceControlSnapshot | undefined;
    };
  },
): InstalledSourceControlUiE2eCurrentSurfaceReport {
  const request = parseRequest(rawRequest);
  const pathCase = deps.pathCasePolicy();
  const session = requireOpenSessionForPath(request.path, deps.sessionService.listOpenSessions());
  const sourceControl = requireSourceControlSnapshot(
    session.repositoryId,
    session.epoch,
    deps.sourceControlSurface.snapshotRepository(session.repositoryId),
  );
  if (normalizePath(sourceControl.workingCopyRoot) !== normalizePath(session.identity.workingCopyRoot)) {
    throw surfaceMismatch(session.repositoryId, session.epoch, {
      sourceControlGroups: sourceControlGroupSummaries(sourceControl.groups),
    });
  }

  return {
    kind: "subversionr.installedSourceControlUiE2eCurrentSurfaceReport",
    generatedAt: deps.generatedAt(),
    extension: {
      name: "subversionr",
      version: deps.extensionVersion,
    },
    workspace: {
      trusted: deps.workspaceTrusted(),
      pathCase,
    },
    repository: {
      repositoryId: session.repositoryId,
      epoch: session.epoch,
      identity: session.identity,
    },
    openRequest: {
      path: request.path,
      relationToWorkingCopyRoot: getRelationToWorkingCopyRoot(request.path, session.identity.workingCopyRoot),
    },
    sourceControl,
    surfaceWorkflow: {
      repositoryOpen: true,
      scmProjection: true,
      sourceControlSurface: true,
      repositoryClosed: false,
    },
  };
}

function conflictArtifactSurfaceEvidence(
  sourceControl: VscodeSourceControlSnapshot,
): InstalledConflictArtifactSurfaceEvidence {
  const conflicts = requireSourceControlGroup(sourceControl, "conflicts");
  const conflictArtifacts = requireSourceControlGroup(sourceControl, "conflictArtifacts");
  const unversioned = requireSourceControlGroup(sourceControl, "unversioned");
  return {
    group: {
      ...conflictArtifacts,
      resources: conflictArtifacts.resources.map((resource) => ({ ...resource })),
    },
    counts: {
      sourceControl: sourceControl.count,
      conflicts: conflicts.count,
      conflictArtifacts: conflictArtifacts.count,
      unversioned: unversioned.count,
    },
    collapseControl: {
      owner: "vscodeUserInterface",
      extensionDefaultSupported: false,
    },
  };
}

function requireSourceControlGroup(
  sourceControl: VscodeSourceControlSnapshot,
  groupId: string,
): VscodeSourceControlGroupSnapshot {
  const group = sourceControl.groups.find((candidate) => candidate.id === groupId);
  if (!group) {
    throw surfaceMismatch(sourceControl.repositoryId, sourceControl.epoch, {
      missingSourceControlGroup: groupId,
      sourceControlGroups: sourceControlGroupSummaries(sourceControl.groups),
    });
  }
  return group;
}

export async function collectInstalledSourceControlUiE2eLazyExternalProviderReport(
  rawRequest: unknown,
  deps: {
    generatedAt(): string;
    extensionVersion: string;
    pathCasePolicy(): PathCasePolicy;
    workspaceTrusted(): boolean;
    discoveryService: Pick<RepositoryDiscoveryService, "discoverRepositories" | "openDiscoveredRepository">;
    sessionService: Pick<RepositorySessionService, "listOpenSessions" | "closeRepository">;
    sourceControlSurface: {
      snapshotRepository(repositoryId: string): VscodeSourceControlSnapshot | undefined;
    };
  },
): Promise<InstalledSourceControlUiE2eLazyExternalProviderReport> {
  const request = parseRequest(rawRequest);
  const pathCase = deps.pathCasePolicy();
  const openSessions = deps.sessionService.listOpenSessions();
  const discovery = await deps.discoveryService.discoverRepositories({
    workspaceRoots: [request.path],
    discoverNested: true,
    discoveryDepth: REPOSITORY_DISCOVERY_DEPTH,
    discoveryIgnore: [],
    ignoredRoots: openSessions.map((session) => session.identity.workingCopyRoot),
    externalsMode: "lazy",
  });
  const parentCandidate = requireParentDiscoveryCandidate(discovery.candidates, request.path, pathCase);
  const directoryExternalCandidates = discovery.candidates.filter(
    (candidate) =>
      candidate.isExternal &&
      candidate.parentWorkingCopyRoot !== undefined &&
      normalizeForCase(candidate.parentWorkingCopyRoot, pathCase) ===
        normalizeForCase(parentCandidate.identity.workingCopyRoot, pathCase),
  );
  if (directoryExternalCandidates.length === 0) {
    throw externalReportError(
      "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_EXTERNAL_CANDIDATE_MISSING",
      { path: request.path },
    );
  }

  const parentBoundaryRoots = discoveryBoundaryRoots(
    discovery.candidates,
    parentCandidate,
    pathCase,
    openSessions,
    discovery.fileExternalBoundaries,
  );
  const openedSessions: RepositorySession[] = [];
  let providersClosed = false;

  try {
    const parentSession = await deps.discoveryService.openDiscoveredRepository({
      candidate: parentCandidate,
      pathCase,
      ...(parentBoundaryRoots.length > 0 ? { boundaryRoots: parentBoundaryRoots } : {}),
    });
    openedSessions.push(parentSession);
    const parentSourceControl = requireSourceControlSnapshot(
      parentSession.repositoryId,
      parentSession.epoch,
      deps.sourceControlSurface.snapshotRepository(parentSession.repositoryId),
    );

    const externalProviders = [];
    for (const candidate of directoryExternalCandidates) {
      const externalBoundaryRoots = discoveryBoundaryRoots(
        discovery.candidates,
        candidate,
        pathCase,
        [...openSessions, ...openedSessions],
        discovery.fileExternalBoundaries,
      );
      const externalSession = await deps.discoveryService.openDiscoveredRepository({
        candidate,
        pathCase,
        ...(externalBoundaryRoots.length > 0 ? { boundaryRoots: externalBoundaryRoots } : {}),
      });
      openedSessions.push(externalSession);
      externalProviders.push({
        repositoryId: externalSession.repositoryId,
        epoch: externalSession.epoch,
        workingCopyRoot: externalSession.identity.workingCopyRoot,
        parentWorkingCopyRoot: candidate.parentWorkingCopyRoot ?? parentSession.identity.workingCopyRoot,
        sourceControl: nonEmptySourceControlSnapshot(
          requireSourceControlSnapshot(
            externalSession.repositoryId,
            externalSession.epoch,
            deps.sourceControlSurface.snapshotRepository(externalSession.repositoryId),
          ),
        ),
      });
    }

    for (const session of [...openedSessions].reverse()) {
      await deps.sessionService.closeRepository(session.repositoryId);
    }
    providersClosed = true;

    const directoryExternalRoots = directoryExternalCandidates.map((candidate) => candidate.identity.workingCopyRoot);
    return {
      kind: "subversionr.installedSourceControlUiE2eLazyExternalProviderReport",
      generatedAt: deps.generatedAt(),
      extension: {
        name: "subversionr",
        version: deps.extensionVersion,
      },
      workspace: {
        trusted: deps.workspaceTrusted(),
        pathCase,
      },
      request: {
        path: request.path,
        discoveryDepth: REPOSITORY_DISCOVERY_DEPTH,
        externalsMode: "lazy",
      },
      discovery: {
        candidates: discovery.candidates,
        fileExternalBoundaries: [...discovery.fileExternalBoundaries],
      },
      parentProvider: {
        repositoryId: parentSession.repositoryId,
        epoch: parentSession.epoch,
        workingCopyRoot: parentSession.identity.workingCopyRoot,
        boundaryRoots: [...parentBoundaryRoots],
        sourceControl: nonEmptySourceControlSnapshot(parentSourceControl),
      },
      externalProviders,
      assertions: {
        lazyDiscoveryRequested: true,
        directoryExternalDiscovered: directoryExternalCandidates.length > 0,
        fileExternalBoundariesDiscovered: discovery.fileExternalBoundaries.length > 0,
        parentBoundaryRootsIncludedDirectoryExternal: directoryExternalRoots.every((root) =>
          containsPath(parentBoundaryRoots, root, pathCase),
        ),
        parentBoundaryRootsIncludedFileExternal: discovery.fileExternalBoundaries.every((root) =>
          containsPath(parentBoundaryRoots, root, pathCase),
        ),
        distinctExternalProviderOpened: externalProviders.every(
          (provider) => provider.repositoryId !== parentSession.repositoryId,
        ),
        parentSourceControlExcludedExternalBoundaries: sourceControlExcludesBoundaries(
          parentSourceControl,
          parentSession.identity.workingCopyRoot,
          parentBoundaryRoots,
          pathCase,
        ),
        providersClosed,
      },
    };
  } finally {
    if (!providersClosed) {
      for (const session of [...openedSessions].reverse()) {
        await deps.sessionService.closeRepository(session.repositoryId);
      }
    }
  }
}

export async function collectInstalledSourceControlUiE2eCloseReport(
  rawRequest: unknown,
  deps: {
    generatedAt(): string;
    sessionService: Pick<RepositorySessionService, "closeRepository" | "listOpenSessions">;
  },
): Promise<InstalledSourceControlUiE2eCloseReport> {
  const request = parseCloseRequest(rawRequest);
  const session = deps.sessionService
    .listOpenSessions()
    .find((candidate) => candidate.repositoryId === request.repositoryId);
  if (!session || session.epoch !== request.epoch) {
    throw new InstalledSourceControlSurfaceReportError(
      "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SESSION_MISMATCH",
      "lifecycle",
      "error.diagnostics.installedSourceControlUiE2eSessionMismatch",
      { repositoryId: request.repositoryId, epoch: request.epoch },
    );
  }
  await deps.sessionService.closeRepository(request.repositoryId);
  return {
    kind: "subversionr.installedSourceControlUiE2eCloseReport",
    generatedAt: deps.generatedAt(),
    repositoryId: request.repositoryId,
    epoch: request.epoch,
    repositoryClosed: true,
  };
}

export function collectInstalledSourceControlUiE2eFreshnessReport(
  rawRequest: unknown,
  deps: {
    generatedAt(): string;
    sessionService: Pick<RepositorySessionService, "listOpenSessions">;
    statusSnapshotStore: Pick<StatusSnapshotStore, "getSnapshot" | "replaceSnapshot" | "markStale">;
    sourceControlProjection: Pick<SourceControlProjectionService, "getProjection" | "replaceSnapshot" | "markStale">;
    statusRefreshCoverage: {
      getLastCompletedRefresh(repositoryId: string, epoch: number): CompletedStatusRefreshCoverage | undefined;
    };
    sourceControlSurface: {
      snapshotRepository(repositoryId: string): VscodeSourceControlSnapshot | undefined;
    };
  },
): InstalledSourceControlUiE2eFreshnessReport {
  const request = parseFreshnessRequest(rawRequest);
  const session = requireOpenSession(request, deps.sessionService.listOpenSessions());
  const generatedAt = deps.generatedAt();
  if (request.scenario === "partial") {
    const snapshot = requireCurrentStatusSnapshot(
      request.repositoryId,
      request.epoch,
      deps.statusSnapshotStore.getSnapshot(request.repositoryId),
    );
    const partialSnapshot: StatusSnapshot = {
      ...snapshot,
      completeness: "partial",
      timestamp: generatedAt,
      source: "installed-source-control-ui-e2e",
      identity: { ...snapshot.identity },
      localEntries: snapshot.localEntries.map((entry) => ({ ...entry })),
      remoteEntries: snapshot.remoteEntries.map((entry) => ({ ...entry })),
      summary: { ...snapshot.summary },
    };
    deps.statusSnapshotStore.replaceSnapshot(partialSnapshot);
    deps.sourceControlProjection.replaceSnapshot(partialSnapshot);
  } else {
    requireCurrentStatusSnapshot(
      request.repositoryId,
      request.epoch,
      deps.statusSnapshotStore.getSnapshot(request.repositoryId),
    );
    requireCurrentProjection(request.repositoryId, request.epoch, deps.sourceControlProjection.getProjection(request.repositoryId));
    const staleMark = {
      repositoryId: request.repositoryId,
      epoch: request.epoch,
      reason: "installedSourceControlUiE2e",
      timestamp: generatedAt,
      source: "installed-source-control-ui-e2e",
    };
    deps.statusSnapshotStore.markStale(staleMark);
    deps.sourceControlProjection.markStale(staleMark);
  }

  const projection = requireCurrentProjection(
    request.repositoryId,
    request.epoch,
    deps.sourceControlProjection.getProjection(request.repositoryId),
  );
  const sourceControl = deps.sourceControlSurface.snapshotRepository(request.repositoryId);
  if (!sourceControl) {
    throw new InstalledSourceControlSurfaceReportError(
      "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_SURFACE_MISSING",
      "lifecycle",
      "error.diagnostics.installedSourceControlSurfaceMissing",
      { repositoryId: request.repositoryId },
    );
  }
  assertSurfaceFreshness(sourceControl, projection, request.scenario);
  assertSurfaceMatchesProjection(sourceControl, projection);
  assertFreshnessCommand(sourceControl, request.repositoryId, request.scenario);
  return {
    kind: "subversionr.installedSourceControlUiE2eFreshnessReport",
    generatedAt,
    scenario: request.scenario,
    repository: {
      repositoryId: session.repositoryId,
      epoch: session.epoch,
      identity: session.identity,
    },
    sourceControl,
    conflictArtifactSurface: conflictArtifactSurfaceEvidence(sourceControl),
    lastCompletedRefresh: deps.statusRefreshCoverage.getLastCompletedRefresh(request.repositoryId, request.epoch),
    freshnessWorkflow: {
      repositoryOpen: true,
      currentEpochMatched: true,
      sourceControlSurface: true,
    },
  };
}

async function openSurfaceState(rawRequest: unknown, deps: InstalledSourceControlSurfaceReportDependencies): Promise<{
  generatedAt: string;
  pathCase: PathCasePolicy;
  request: InstalledSourceControlSurfaceReportRequest;
  session: RepositorySession;
  sourceControl: VscodeSourceControlSnapshot;
}> {
  const request = parseRequest(rawRequest);
  const pathCase = deps.pathCasePolicy();
  let session: RepositorySession | undefined;

  try {
    session = await deps.sessionService.openWorkingCopy({
      path: request.path,
      pathCase,
    });
    const projection = deps.sourceControlProjection.getProjection(session.repositoryId);
    if (!projection) {
      throw new InstalledSourceControlSurfaceReportError(
        "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_SURFACE_PROJECTION_MISSING",
        "lifecycle",
        "error.diagnostics.installedSourceControlSurfaceProjectionMissing",
        { repositoryId: session.repositoryId },
      );
    }
    if (projection.repositoryId !== session.repositoryId || projection.epoch !== session.epoch) {
      throw mismatch(session);
    }
    if (normalizePath(projection.workingCopyRoot) !== normalizePath(session.identity.workingCopyRoot)) {
      throw mismatch(session);
    }

    const sourceControl = deps.sourceControlSurface.snapshotRepository(session.repositoryId);
    if (!sourceControl) {
      throw new InstalledSourceControlSurfaceReportError(
        "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_SURFACE_MISSING",
        "lifecycle",
        "error.diagnostics.installedSourceControlSurfaceMissing",
        { repositoryId: session.repositoryId },
      );
    }
    if (
      sourceControl.repositoryId !== projection.repositoryId ||
      sourceControl.epoch !== projection.epoch ||
      sourceControl.generation !== projection.generation ||
      sourceControl.count !== projection.count ||
      normalizePath(sourceControl.workingCopyRoot) !== normalizePath(projection.workingCopyRoot) ||
      normalizePath(sourceControl.workingCopyRoot) !== normalizePath(session.identity.workingCopyRoot)
    ) {
      throw surfaceMismatch(session.repositoryId, session.epoch, {
        sourceControlGroups: sourceControlGroupSummaries(sourceControl.groups),
        projectionGroups: projectionGroupSummaries(projection),
      });
    }
    assertSurfaceMatchesProjection(sourceControl, projection);
    return {
      generatedAt: deps.generatedAt(),
      pathCase,
      request,
      session,
      sourceControl,
    };
  } catch (error) {
    if (session) {
      await deps.sessionService.closeRepository(session.repositoryId);
    }
    throw error;
  }
}

function parseRequest(rawRequest: unknown): InstalledSourceControlSurfaceReportRequest {
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

function requireParentDiscoveryCandidate(
  candidates: RepositoryDiscoveryCandidate[],
  requestedPath: string,
  pathCase: PathCasePolicy,
): RepositoryDiscoveryCandidate {
  const requestedKey = normalizeForCase(requestedPath, pathCase);
  const parentCandidate = candidates.find(
    (candidate) =>
      !candidate.isNested &&
      !candidate.isExternal &&
      normalizeForCase(candidate.identity.workingCopyRoot, pathCase) === requestedKey,
  );
  if (!parentCandidate) {
    throw externalReportError(
      "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_PARENT_CANDIDATE_MISSING",
      { path: requestedPath },
    );
  }
  return parentCandidate;
}

function requireSourceControlSnapshot(
  repositoryId: string,
  epoch: number,
  sourceControl: VscodeSourceControlSnapshot | undefined,
): VscodeSourceControlSnapshot {
  if (!sourceControl || sourceControl.repositoryId !== repositoryId || sourceControl.epoch !== epoch) {
    throw externalReportError(
      "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SOURCE_CONTROL_MISSING",
      { repositoryId, epoch },
    );
  }
  return sourceControl;
}

function containsPath(paths: string[], candidate: string, pathCase: PathCasePolicy): boolean {
  const candidateKey = normalizeForCase(candidate, pathCase);
  return paths.some((pathValue) => normalizeForCase(pathValue, pathCase) === candidateKey);
}

function sourceControlExcludesBoundaries(
  sourceControl: VscodeSourceControlSnapshot,
  workingCopyRoot: string,
  boundaryRoots: string[],
  pathCase: PathCasePolicy,
): boolean {
  const boundaryKeys = boundaryRoots.map((boundaryRoot) => normalizeForCase(boundaryRoot, pathCase));
  return sourceControl.groups.every((group) =>
    group.resources.every((resource) => {
      const resourceKey = normalizeForCase(`${normalizeAbsolutePath(workingCopyRoot)}/${resource.path}`, pathCase);
      return boundaryKeys.every(
        (boundaryKey) => resourceKey !== boundaryKey && !resourceKey.startsWith(`${boundaryKey}/`),
      );
    }),
  );
}

function normalizeForCase(candidate: string, pathCase: PathCasePolicy): string {
  const normalized = normalizeAbsolutePath(candidate);
  return pathCase === "case-insensitive" ? normalized.toLocaleLowerCase("en-US") : normalized;
}

function normalizeAbsolutePath(candidate: string): string {
  return candidate.replaceAll("\\", "/").replace(/\/+$/u, "");
}

function externalReportError(
  code: string,
  safeArgs: Record<string, unknown>,
): InstalledSourceControlSurfaceReportError {
  return new InstalledSourceControlSurfaceReportError(
    code,
    "lifecycle",
    "error.diagnostics.installedSourceControlSurfaceMismatch",
    safeArgs,
  );
}

function parseCloseRequest(rawRequest: unknown): { repositoryId: string; epoch: number } {
  if (!isRecord(rawRequest)) {
    throw closeRequestRequired();
  }
  if (typeof rawRequest.repositoryId !== "string" || rawRequest.repositoryId.trim().length === 0) {
    throw closeRequestRequired();
  }
  const epoch = rawRequest.epoch;
  if (typeof epoch !== "number" || !Number.isInteger(epoch) || epoch < 0) {
    throw closeRequestRequired();
  }
  return {
    repositoryId: rawRequest.repositoryId,
    epoch,
  };
}

function parseFreshnessRequest(rawRequest: unknown): {
  repositoryId: string;
  epoch: number;
  scenario: InstalledSourceControlUiE2eFreshnessScenario;
} {
  if (!isRecord(rawRequest)) {
    throw freshnessRequestRequired();
  }
  requireExactFields(rawRequest, ["repositoryId", "epoch", "scenario"], freshnessRequestRequired);
  if (typeof rawRequest.repositoryId !== "string" || rawRequest.repositoryId.trim().length === 0) {
    throw freshnessRequestRequired();
  }
  const epoch = rawRequest.epoch;
  if (typeof epoch !== "number" || !Number.isInteger(epoch) || epoch < 0) {
    throw freshnessRequestRequired();
  }
  if (rawRequest.scenario !== "partial" && rawRequest.scenario !== "stale") {
    throw freshnessRequestRequired();
  }
  return {
    repositoryId: rawRequest.repositoryId,
    epoch,
    scenario: rawRequest.scenario,
  };
}

function buildReport(options: {
  generatedAt: string;
  extensionVersion: string;
  workspaceTrusted: boolean;
  pathCase: PathCasePolicy;
  request: InstalledSourceControlSurfaceReportRequest;
  session: RepositorySession;
  sourceControl: VscodeSourceControlSnapshot;
}): InstalledSourceControlSurfaceReport {
  const relationToWorkingCopyRoot = getRelationToWorkingCopyRoot(
    options.request.path,
    options.session.identity.workingCopyRoot,
  );
  const sourceControlRootMatchedWorkingCopyRoot =
    normalizePath(options.sourceControl.workingCopyRoot) === normalizePath(options.session.identity.workingCopyRoot);
  const workspaceScopeRootMatchedRequest =
    normalizePath(options.session.identity.workspaceScopeRoot) === normalizePath(options.request.path);
  const requestedPathResolvedToWorkingCopyRoot =
    relationToWorkingCopyRoot === "workingCopyRoot" || relationToWorkingCopyRoot === "subdirectory";
  return {
    kind: "subversionr.installedSourceControlSurfaceReport",
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
    openRequest: {
      path: options.request.path,
      relationToWorkingCopyRoot,
    },
    providerResolution: {
      requestedPathResolvedToWorkingCopyRoot,
      workspaceScopeRootMatchedRequest,
      sourceControlRootMatchedWorkingCopyRoot,
      subdirectoryOpenResolvedToWorkingCopyRoot:
        relationToWorkingCopyRoot === "subdirectory" &&
        requestedPathResolvedToWorkingCopyRoot &&
        workspaceScopeRootMatchedRequest &&
        sourceControlRootMatchedWorkingCopyRoot,
    },
    sourceControl: options.sourceControl,
    surfaceWorkflow: {
      repositoryOpen: true,
      scmProjection: true,
      sourceControlSurface: true,
      repositoryClosed: true,
    },
  };
}

function getRelationToWorkingCopyRoot(
  requestedPath: string,
  workingCopyRoot: string,
): InstalledSourceControlOpenRequestRelation {
  const requested = normalizePath(requestedPath);
  const root = normalizePath(workingCopyRoot);
  if (requested === root) {
    return "workingCopyRoot";
  }
  if (requested.startsWith(`${root}/`)) {
    return "subdirectory";
  }
  return "outsideWorkingCopy";
}

function buildUiE2eOpenReport(options: {
  generatedAt: string;
  extensionVersion: string;
  workspaceTrusted: boolean;
  pathCase: PathCasePolicy;
  session: RepositorySession;
  sourceControl: VscodeSourceControlSnapshot;
}): InstalledSourceControlUiE2eOpenReport {
  const backendReadyLogToken = "SubversionR backend ready. libsvn:";
  const resourceTokens = options.sourceControl.groups.flatMap((group) =>
    group.resources.flatMap((resource) => resource.path.split(/[\\/]/u).filter((segment) => segment.length > 0)),
  );
  return {
    kind: "subversionr.installedSourceControlUiE2eOpenReport",
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
    sourceControl: options.sourceControl,
    rendererCaptureExpectations: {
      viewCommand: "workbench.view.scm",
      requiredDomTokens: uniqueTokens([
        "SubversionR",
        "Changes",
        "Unversioned",
        ...resourceTokens,
        backendReadyLogToken,
      ]),
      requiredAccessibilityTokens: uniqueTokens([
        "SubversionR",
        "Changes",
        "Unversioned",
        ...resourceTokens,
      ]),
      requiredScreenshot: true,
      viewport: {
        width: 1440,
        height: 900,
      },
      scmActionSurface: {
        layout: {
          prepareCommand: "workbench.action.increaseViewSize",
          incrementCount: 1,
          minimumProviderWidth: 280,
          minimumActionsContainerWidth: 120,
        },
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
          {
            label: "History",
            commands: ["SubversionR: Show Repository Log"],
          },
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
        forbiddenNotificationTokens: [backendReadyLogToken],
      },
    },
    surfaceWorkflow: {
      repositoryOpen: true,
      scmProjection: true,
      sourceControlSurface: true,
      repositoryClosed: false,
    },
  };
}

function nonEmptySourceControlSnapshot(sourceControl: VscodeSourceControlSnapshot): VscodeSourceControlSnapshot {
  return {
    ...sourceControl,
    groups: sourceControl.groups
      .filter((group) => group.resources.length > 0)
      .map((group) => ({
        ...group,
        resources: [...group.resources],
      })),
  };
}

function assertSurfaceMatchesProjection(
  sourceControl: VscodeSourceControlSnapshot,
  projection: ScmRepositoryProjection,
): void {
  for (const projectionGroup of projection.groups) {
    const surfaceGroup = sourceControl.groups.find((group) => group.id === projectionGroup.id);
    if (!surfaceGroup || surfaceGroup.count !== surfaceGroup.resources.length) {
      throw new InstalledSourceControlSurfaceReportError(
        "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_SURFACE_MISMATCH",
        "lifecycle",
        "error.diagnostics.installedSourceControlSurfaceMismatch",
        {
          repositoryId: sourceControl.repositoryId,
          epoch: sourceControl.epoch,
          sourceControlGroups: sourceControlGroupSummaries(sourceControl.groups),
          projectionGroups: projectionGroupSummaries(projection),
        },
      );
    }
    const projectionResources = projectionGroup.resources.map((resource) => ({
      path: normalizeRelativePath(resource.path),
      contextValue: sourceControlResourceStateContextValue(resource),
      kind: resource.entry.kind,
      generation: projection.generation,
    }));
    const surfaceResources = surfaceGroup.resources.map((resource) => ({
      path: normalizeRelativePath(resource.path),
      contextValue: resource.contextValue,
      kind: resource.kind,
      generation: resource.generation,
    }));
    if (JSON.stringify(surfaceResources) !== JSON.stringify(projectionResources)) {
      throw new InstalledSourceControlSurfaceReportError(
        "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_SURFACE_MISMATCH",
        "lifecycle",
        "error.diagnostics.installedSourceControlSurfaceMismatch",
        {
          repositoryId: sourceControl.repositoryId,
          epoch: sourceControl.epoch,
          sourceControlGroups: sourceControlGroupSummaries(sourceControl.groups),
          projectionGroups: projectionGroupSummaries(projection),
        },
      );
    }
  }
}

function assertSurfaceFreshness(
  sourceControl: VscodeSourceControlSnapshot,
  projection: ScmRepositoryProjection,
  scenario: InstalledSourceControlUiE2eFreshnessScenario,
): void {
  if (
    sourceControl.repositoryId !== projection.repositoryId ||
    sourceControl.epoch !== projection.epoch ||
    sourceControl.generation !== projection.generation ||
    sourceControl.freshness?.repositoryCompleteness !== scenario ||
    projection.freshness.repositoryCompleteness !== scenario ||
    JSON.stringify(sourceControl.freshness) !== JSON.stringify(projection.freshness)
  ) {
    throw surfaceMismatch(projection.repositoryId, projection.epoch, {
      sourceControlGroups: sourceControlGroupSummaries(sourceControl.groups),
      projectionGroups: projectionGroupSummaries(projection),
    });
  }
}

function assertFreshnessCommand(
  sourceControl: VscodeSourceControlSnapshot,
  repositoryId: string,
  scenario: InstalledSourceControlUiE2eFreshnessScenario,
): void {
  const expectedTitle = scenario === "partial" ? "SVN status partial" : "SVN status stale";
  if (
    !sourceControl.statusBarCommands ||
    sourceControl.statusBarCommands.length !== 1 ||
    sourceControl.statusBarCommands[0].command !== "subversionr.fullReconcile" ||
    sourceControl.statusBarCommands[0].title !== expectedTitle ||
    JSON.stringify(sourceControl.statusBarCommands[0].arguments) !== JSON.stringify([repositoryId])
  ) {
    throw new InstalledSourceControlSurfaceReportError(
      "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_FRESHNESS_COMMAND_MISSING",
      "lifecycle",
      "error.diagnostics.installedSourceControlFreshnessCommandMissing",
      { repositoryId, scenario },
    );
  }
}

function requireOpenSession(
  request: { repositoryId: string; epoch: number },
  sessions: RepositorySession[],
): RepositorySession {
  const session = sessions.find((candidate) => candidate.repositoryId === request.repositoryId);
  if (!session || session.epoch !== request.epoch) {
    throw new InstalledSourceControlSurfaceReportError(
      "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SESSION_MISMATCH",
      "lifecycle",
      "error.diagnostics.installedSourceControlUiE2eSessionMismatch",
      { repositoryId: request.repositoryId, epoch: request.epoch },
    );
  }
  return session;
}

function requireOpenSessionForPath(requestPath: string, sessions: RepositorySession[]): RepositorySession {
  const normalizedRequestPath = normalizePath(requestPath);
  const session = sessions.find((candidate) => {
    const normalizedWorkingCopyRoot = normalizePath(candidate.identity.workingCopyRoot);
    return (
      normalizedRequestPath === normalizedWorkingCopyRoot ||
      normalizedRequestPath.startsWith(`${normalizedWorkingCopyRoot}/`)
    );
  });
  if (!session) {
    throw new InstalledSourceControlSurfaceReportError(
      "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CURRENT_SESSION_MISSING",
      "lifecycle",
      "error.diagnostics.installedSourceControlUiE2eSessionMismatch",
      { path: requestPath },
    );
  }
  return session;
}

function requireCurrentStatusSnapshot(
  repositoryId: string,
  epoch: number,
  snapshot: ReturnType<StatusSnapshotStore["getSnapshot"]>,
): StatusSnapshot {
  if (!snapshot || snapshot.repositoryId !== repositoryId || snapshot.epoch !== epoch) {
    throw new InstalledSourceControlSurfaceReportError(
      "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_FRESHNESS_STATE_MISSING",
      "lifecycle",
      "error.diagnostics.installedSourceControlFreshnessStateMissing",
      { repositoryId, epoch, state: "status" },
    );
  }
  return snapshot;
}

function requireCurrentProjection(
  repositoryId: string,
  epoch: number,
  projection: ReturnType<SourceControlProjectionService["getProjection"]>,
): ScmRepositoryProjection {
  if (!projection || projection.repositoryId !== repositoryId || projection.epoch !== epoch) {
    throw new InstalledSourceControlSurfaceReportError(
      "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_FRESHNESS_STATE_MISSING",
      "lifecycle",
      "error.diagnostics.installedSourceControlFreshnessStateMissing",
      { repositoryId, epoch, state: "projection" },
    );
  }
  return projection;
}

function pathRequired(): InstalledSourceControlSurfaceReportError {
  return new InstalledSourceControlSurfaceReportError(
    "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_SURFACE_PATH_REQUIRED",
    "input",
    "error.diagnostics.installedSourceControlSurfacePathRequired",
  );
}

function closeRequestRequired(): InstalledSourceControlSurfaceReportError {
  return new InstalledSourceControlSurfaceReportError(
    "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_CLOSE_REQUEST_REQUIRED",
    "input",
    "error.diagnostics.installedSourceControlUiE2eCloseRequestRequired",
  );
}

function freshnessRequestRequired(): InstalledSourceControlSurfaceReportError {
  return new InstalledSourceControlSurfaceReportError(
    "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_FRESHNESS_REQUEST_REQUIRED",
    "input",
    "error.diagnostics.installedSourceControlUiE2eFreshnessRequestRequired",
  );
}

function mismatch(session: RepositorySession): InstalledSourceControlSurfaceReportError {
  return surfaceMismatch(session.repositoryId, session.epoch);
}

function sourceControlGroupSummaries(groups: VscodeSourceControlSnapshot["groups"]): unknown[] {
  return groups.map((group) => ({
    id: group.id,
    count: group.count,
    resources: group.resources.map((resource) => ({
      path: normalizeRelativePath(resource.path),
      contextValue: resource.contextValue,
      kind: resource.kind,
      generation: resource.generation,
    })),
  }));
}

function projectionGroupSummaries(projection: ScmRepositoryProjection): unknown[] {
  return projection.groups.map((group) => ({
    id: group.id,
    count: group.resources.length,
    resources: group.resources.map((resource) => ({
      path: normalizeRelativePath(resource.path),
      contextValue: sourceControlResourceStateContextValue(resource),
      kind: resource.entry.kind,
      generation: projection.generation,
    })),
  }));
}

function surfaceMismatch(
  repositoryId: string,
  epoch: number,
  details: Record<string, unknown> = {},
): InstalledSourceControlSurfaceReportError {
  return new InstalledSourceControlSurfaceReportError(
    "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_SURFACE_MISMATCH",
    "lifecycle",
    "error.diagnostics.installedSourceControlSurfaceMismatch",
    {
      repositoryId,
      epoch,
      ...details,
    },
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function requireExactFields(
  value: Record<string, unknown>,
  fields: readonly string[],
  errorFactory: () => InstalledSourceControlSurfaceReportError,
): void {
  const expected = new Set(fields);
  for (const field of Object.keys(value)) {
    if (!expected.has(field)) {
      throw errorFactory();
    }
  }
  for (const field of fields) {
    if (!(field in value)) {
      throw errorFactory();
    }
  }
}

function isAbsolutePath(candidate: string): boolean {
  return path.isAbsolute(candidate) || path.win32.isAbsolute(candidate) || path.posix.isAbsolute(candidate);
}

function uniqueTokens(tokens: string[]): string[] {
  return Array.from(new Set(tokens.filter((token) => token.trim().length > 0)));
}

function normalizePath(candidate: string): string {
  const normalized = candidate.replace(/\\/g, "/").replace(/\/+$/u, "");
  return process.platform === "win32" ? normalized.toLocaleLowerCase("en-US") : normalized;
}

function normalizeRelativePath(candidate: string): string {
  return candidate.replace(/\\/g, "/");
}
