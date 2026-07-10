import type { PathCasePolicy } from "../status/types";
import type {
  RepositoryDiscoveryCandidate,
  RepositoryDiscoveryService,
} from "./repositoryDiscoveryService";
import {
  discoveryBoundaryRoots,
  REPOSITORY_DISCOVERY_DEPTH,
  unopenedDiscoveryCandidates,
} from "./repositoryDiscoveryPlanning";
import type {
  RepositorySession,
  RepositorySessionReopenResult,
  RepositorySessionService,
} from "./repositorySessionService";

export type RepositoryAutoOpenTrigger = "activation" | "workspaceTrust" | "workspaceFolders";

export type RepositoryAutoOpenSkippedReason =
  | "workspaceUntrusted"
  | "noWorkspaceRoots"
  | "noCandidates"
  | "allCandidatesOpen"
  | "ambiguousCandidates"
  | "alreadyRunning";

export type RepositoryLifecycleEvent =
  | {
      kind: "autoOpenSkipped";
      trigger: RepositoryAutoOpenTrigger;
      reason: RepositoryAutoOpenSkippedReason;
      candidateCount?: number;
    }
  | {
      kind: "autoOpenOpened";
      trigger: RepositoryAutoOpenTrigger;
      repositoryId: string;
      epoch: number;
      workingCopyRoot: string;
    }
  | {
      kind: "autoOpenOpenedMany";
      trigger: RepositoryAutoOpenTrigger;
      openedCount: number;
      repositories: Array<{
        repositoryId: string;
        epoch: number;
        workingCopyRoot: string;
      }>;
    }
  | {
      kind: "autoOpenFailed";
      trigger: RepositoryAutoOpenTrigger;
      code: string;
    }
  | {
      kind: "openSessionClosed";
      trigger: RepositoryAutoOpenTrigger;
      reason: "workingCopyMissing";
      repositoryId: string;
      epoch: number;
      workingCopyRoot: string;
    }
  | {
      kind: "openSessionCloseFailed";
      trigger: RepositoryAutoOpenTrigger;
      reason: "workingCopyMissing" | "workingCopyStatusUnavailable";
      repositoryId: string;
      epoch: number;
      workingCopyRoot: string;
      code: string;
    }
  | {
      kind: "openSessionMoved";
      trigger: RepositoryAutoOpenTrigger;
      previousRepositoryId: string;
      previousEpoch: number;
      previousWorkingCopyRoot: string;
      repositoryId: string;
      epoch: number;
      workingCopyRoot: string;
    }
  | {
      kind: "openSessionMoveFailed";
      trigger: RepositoryAutoOpenTrigger;
      reason: "workingCopyStatusUnavailable" | "discoveryFailed" | "ambiguousCandidates" | "closeFailed" | "openFailed";
      repositoryId: string;
      epoch: number;
      workingCopyRoot: string;
      code: string;
      candidateCount?: number;
    }
  | {
      kind: "openSessionReopened";
      trigger: "backendRestart";
      repositoryId: string;
      previousEpoch: number;
      epoch: number;
      workingCopyRoot: string;
    }
  | {
      kind: "openSessionReopenFailed";
      trigger: "backendRestart";
      repositoryId: string;
      epoch: number;
      workingCopyRoot: string;
      code: string;
    };

export interface RepositoryLifecycleServiceOptions {
  discoveryService: Pick<RepositoryDiscoveryService, "discoverRepositories" | "openDiscoveredRepository">;
  sessionService: Pick<RepositorySessionService, "closeRepository" | "listOpenSessions" | "reopenOpenSessions">;
  workspaceRoots(): string[];
  workspaceTrusted(): boolean;
  pathCasePolicy(): PathCasePolicy;
  workingCopyExists(path: string): Promise<boolean>;
  onEvent?(event: RepositoryLifecycleEvent): void;
}

export class RepositoryLifecycleService {
  private autoOpenInFlight = false;

  public constructor(private readonly options: RepositoryLifecycleServiceOptions) {}

  public async autoOpenWorkspaceRepositories(
    trigger: RepositoryAutoOpenTrigger,
  ): Promise<RepositoryLifecycleEvent> {
    if (!this.options.workspaceTrusted()) {
      return this.emit({
        kind: "autoOpenSkipped",
        trigger,
        reason: "workspaceUntrusted",
      });
    }

    const workspaceRoots = this.options.workspaceRoots();
    if (workspaceRoots.length === 0) {
      return this.emit({
        kind: "autoOpenSkipped",
        trigger,
        reason: "noWorkspaceRoots",
      });
    }

    if (this.autoOpenInFlight) {
      return this.emit({
        kind: "autoOpenSkipped",
        trigger,
        reason: "alreadyRunning",
      });
    }

    this.autoOpenInFlight = true;
    try {
      const pathCase = this.options.pathCasePolicy();
      const openSessions = this.options.sessionService.listOpenSessions();
      const discovery = await this.options.discoveryService.discoverRepositories({
        workspaceRoots,
        discoverNested: true,
        discoveryDepth: REPOSITORY_DISCOVERY_DEPTH,
        discoveryIgnore: [],
        ignoredRoots: openSessions.map((session) => session.identity.workingCopyRoot),
        externalsMode: "lazy",
      });
      if (discovery.candidates.length === 0) {
        return this.emit({
          kind: "autoOpenSkipped",
          trigger,
          reason: "noCandidates",
          candidateCount: 0,
        });
      }

      const unopenedCandidates = automaticOpenCandidates(discovery.candidates, openSessions, pathCase);
      if (unopenedCandidates.length === 0) {
        return this.emit({
          kind: "autoOpenSkipped",
          trigger,
          reason: "allCandidatesOpen",
          candidateCount: discovery.candidates.length,
        });
      }
      if (unopenedCandidates.length > 1) {
        const sessions: RepositorySession[] = [];
        for (const candidate of unopenedCandidates) {
          const session = await this.openSingleCandidate(
            discovery.candidates,
            candidate,
            pathCase,
            openSessions.concat(sessions),
            discovery.fileExternalBoundaries,
          );
          sessions.push(session);
          this.emit(autoOpenOpenedEvent(trigger, session));
        }
        return this.emit({
          kind: "autoOpenOpenedMany",
          trigger,
          openedCount: sessions.length,
          repositories: sessions.map((session) => ({
            repositoryId: session.repositoryId,
            epoch: session.epoch,
            workingCopyRoot: session.identity.workingCopyRoot,
          })),
        });
      }

      const session = await this.openSingleCandidate(
        discovery.candidates,
        unopenedCandidates[0],
        pathCase,
        openSessions,
        discovery.fileExternalBoundaries,
      );
      return this.emit(autoOpenOpenedEvent(trigger, session));
    } catch (error) {
      return this.emit({
        kind: "autoOpenFailed",
        trigger,
        code: errorCode(error),
      });
    } finally {
      this.autoOpenInFlight = false;
    }
  }

  public async closeDisappearedRepositories(
    trigger: RepositoryAutoOpenTrigger,
  ): Promise<RepositoryLifecycleEvent[]> {
    const events: RepositoryLifecycleEvent[] = [];
    for (const session of this.options.sessionService.listOpenSessions()) {
      let exists: boolean;
      try {
        exists = await this.options.workingCopyExists(session.identity.workingCopyRoot);
      } catch (error) {
        events.push(
          this.emit({
            kind: "openSessionCloseFailed",
            trigger,
            reason: "workingCopyStatusUnavailable",
            repositoryId: session.repositoryId,
            epoch: session.epoch,
            workingCopyRoot: session.identity.workingCopyRoot,
            code: errorCode(error),
          }),
        );
        continue;
      }
      if (exists) {
        continue;
      }

      try {
        await this.options.sessionService.closeRepository(session.repositoryId);
        events.push(
          this.emit({
            kind: "openSessionClosed",
            trigger,
            reason: "workingCopyMissing",
            repositoryId: session.repositoryId,
            epoch: session.epoch,
            workingCopyRoot: session.identity.workingCopyRoot,
          }),
        );
      } catch (error) {
        events.push(
          this.emit({
            kind: "openSessionCloseFailed",
            trigger,
            reason: "workingCopyMissing",
            repositoryId: session.repositoryId,
            epoch: session.epoch,
            workingCopyRoot: session.identity.workingCopyRoot,
            code: errorCode(error),
          }),
        );
      }
    }
    return events;
  }

  public async recoverMovedRepositories(trigger: RepositoryAutoOpenTrigger): Promise<RepositoryLifecycleEvent[]> {
    const events: RepositoryLifecycleEvent[] = [];
    if (!this.options.workspaceTrusted()) {
      return events;
    }

    const workspaceRoots = this.options.workspaceRoots();
    if (workspaceRoots.length === 0) {
      return events;
    }

    const openSessions = this.options.sessionService.listOpenSessions();
    const missingSessions: RepositorySession[] = [];
    const existingSessions: RepositorySession[] = [];
    for (const session of openSessions) {
      let exists: boolean;
      try {
        exists = await this.options.workingCopyExists(session.identity.workingCopyRoot);
      } catch (error) {
        events.push(
          this.emit({
            kind: "openSessionMoveFailed",
            trigger,
            reason: "workingCopyStatusUnavailable",
            repositoryId: session.repositoryId,
            epoch: session.epoch,
            workingCopyRoot: session.identity.workingCopyRoot,
            code: errorCode(error),
          }),
        );
        continue;
      }
      if (exists) {
        existingSessions.push(session);
      } else {
        missingSessions.push(session);
      }
    }

    if (missingSessions.length === 0) {
      return events;
    }

    const pathCase = this.options.pathCasePolicy();
    let discovery: Awaited<ReturnType<RepositoryDiscoveryService["discoverRepositories"]>>;
    try {
      discovery = await this.options.discoveryService.discoverRepositories({
        workspaceRoots,
        discoverNested: true,
        discoveryDepth: REPOSITORY_DISCOVERY_DEPTH,
        discoveryIgnore: [],
        ignoredRoots: existingSessions.map((session) => session.identity.workingCopyRoot),
        externalsMode: "lazy",
      });
    } catch (error) {
      for (const session of missingSessions) {
        events.push(
          this.emit({
            kind: "openSessionMoveFailed",
            trigger,
            reason: "discoveryFailed",
            repositoryId: session.repositoryId,
            epoch: session.epoch,
            workingCopyRoot: session.identity.workingCopyRoot,
            code: errorCode(error),
          }),
        );
      }
      return events;
    }

    const unopenedCandidates = unopenedDiscoveryCandidates(discovery.candidates, existingSessions, pathCase);
    for (const session of missingSessions) {
      const movedCandidates = unopenedCandidates.filter((candidate) =>
        movedCandidateMatchesSession(candidate, session, pathCase),
      );
      if (movedCandidates.length === 0) {
        continue;
      }
      if (movedCandidates.length > 1) {
        events.push(
          this.emit({
            kind: "openSessionMoveFailed",
            trigger,
            reason: "ambiguousCandidates",
            repositoryId: session.repositoryId,
            epoch: session.epoch,
            workingCopyRoot: session.identity.workingCopyRoot,
            code: "SUBVERSIONR_REPOSITORY_MOVED_CANDIDATE_AMBIGUOUS",
            candidateCount: movedCandidates.length,
          }),
        );
        continue;
      }

      const candidate = movedCandidates[0];
      try {
        await this.options.sessionService.closeRepository(session.repositoryId);
      } catch (error) {
        events.push(
          this.emit({
            kind: "openSessionMoveFailed",
            trigger,
            reason: "closeFailed",
            repositoryId: session.repositoryId,
            epoch: session.epoch,
            workingCopyRoot: session.identity.workingCopyRoot,
            code: errorCode(error),
          }),
        );
        continue;
      }

      try {
        const movedSession = await this.openSingleCandidate(
          discovery.candidates,
          candidate,
          pathCase,
          existingSessions,
          discovery.fileExternalBoundaries,
        );
        events.push(
          this.emit({
            kind: "openSessionMoved",
            trigger,
            previousRepositoryId: session.repositoryId,
            previousEpoch: session.epoch,
            previousWorkingCopyRoot: session.identity.workingCopyRoot,
            repositoryId: movedSession.repositoryId,
            epoch: movedSession.epoch,
            workingCopyRoot: movedSession.identity.workingCopyRoot,
          }),
        );
      } catch (error) {
        events.push(
          this.emit({
            kind: "openSessionMoveFailed",
            trigger,
            reason: "openFailed",
            repositoryId: session.repositoryId,
            epoch: session.epoch,
            workingCopyRoot: session.identity.workingCopyRoot,
            code: errorCode(error),
          }),
        );
      }
    }

    return events;
  }

  public async reopenBackendRestartedRepositories(): Promise<RepositoryLifecycleEvent[]> {
    const results = await this.options.sessionService.reopenOpenSessions();
    return results.map((result) => this.emit(reopenResultToLifecycleEvent(result)));
  }

  private async openSingleCandidate(
    candidates: RepositoryDiscoveryCandidate[],
    candidate: RepositoryDiscoveryCandidate,
    pathCase: PathCasePolicy,
    openSessions: RepositorySession[],
    fileExternalBoundaries: string[],
  ): Promise<RepositorySession> {
    const boundaryRoots = discoveryBoundaryRoots(
      candidates,
      candidate,
      pathCase,
      openSessions,
      fileExternalBoundaries,
    );
    return await this.options.discoveryService.openDiscoveredRepository({
      candidate,
      pathCase,
      ...(boundaryRoots.length > 0 ? { boundaryRoots } : {}),
    });
  }

  private emit(event: RepositoryLifecycleEvent): RepositoryLifecycleEvent {
    this.options.onEvent?.(event);
    return event;
  }
}

function autoOpenOpenedEvent(
  trigger: RepositoryAutoOpenTrigger,
  session: RepositorySession,
): RepositoryLifecycleEvent {
  return {
    kind: "autoOpenOpened",
    trigger,
    repositoryId: session.repositoryId,
    epoch: session.epoch,
    workingCopyRoot: session.identity.workingCopyRoot,
  };
}

function reopenResultToLifecycleEvent(result: RepositorySessionReopenResult): RepositoryLifecycleEvent {
  if (result.kind === "reopened") {
    return {
      kind: "openSessionReopened",
      trigger: "backendRestart",
      repositoryId: result.repositoryId,
      previousEpoch: result.previousEpoch,
      epoch: result.epoch,
      workingCopyRoot: result.workingCopyRoot,
    };
  }
  return {
    kind: "openSessionReopenFailed",
    trigger: "backendRestart",
    repositoryId: result.repositoryId,
    epoch: result.epoch,
    workingCopyRoot: result.workingCopyRoot,
    code: result.code,
  };
}

function movedCandidateMatchesSession(
  candidate: RepositoryDiscoveryCandidate,
  session: RepositorySession,
  pathCase: PathCasePolicy,
): boolean {
  return (
    candidate.identity.repositoryUuid === session.identity.repositoryUuid &&
    candidate.identity.repositoryRootUrl === session.identity.repositoryRootUrl &&
    repositoryRootKey(candidate.identity.workingCopyRoot, pathCase) !==
      repositoryRootKey(session.identity.workingCopyRoot, pathCase)
  );
}

function automaticOpenCandidates(
  candidates: RepositoryDiscoveryCandidate[],
  openSessions: RepositorySession[],
  pathCase: PathCasePolicy,
): RepositoryDiscoveryCandidate[] {
  const unopenedCandidates = unopenedDiscoveryCandidates(candidates, openSessions, pathCase);
  const unopenedRootKeys = unopenedCandidates.map((candidate) =>
    repositoryRootKey(candidate.identity.workingCopyRoot, pathCase),
  );
  return unopenedCandidates.filter((candidate) => {
    const candidateRootKey = repositoryRootKey(candidate.identity.workingCopyRoot, pathCase);
    return !unopenedRootKeys.some(
      (ancestorRootKey) =>
        ancestorRootKey !== candidateRootKey && isDescendantRootKey(candidateRootKey, ancestorRootKey),
    );
  });
}

function repositoryRootKey(root: string, pathCase: PathCasePolicy): string {
  const normalized = root.replaceAll("\\", "/").replace(/\/+$/u, "");
  return pathCase === "case-insensitive" ? normalized.toLocaleLowerCase("en-US") : normalized;
}

function isDescendantRootKey(childRootKey: string, parentRootKey: string): boolean {
  return childRootKey.slice(parentRootKey.length).startsWith("/");
}

function errorCode(error: unknown): string {
  if (typeof error === "object" && error !== null && "code" in error) {
    const code = (error as { code?: unknown }).code;
    if (typeof code === "string" && code.trim().length > 0) {
      return code;
    }
  }
  return "SUBVERSIONR_REPOSITORY_LIFECYCLE_FAILED";
}
