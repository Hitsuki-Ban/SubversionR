import {
  StatusRefreshScheduler,
  type FullReconcileRequest,
  type ResourceRefreshRequest,
  type StatusRefreshRunOptions,
  type StatusRefreshSchedulerOptions,
  type TargetRefreshRequest,
} from "./statusRefreshScheduler";
import type { SourceControlProjectionService } from "../scm/sourceControlProjectionService";
import type { StatusSnapshotStore } from "./statusSnapshotStore";
import { normalizeWatcherEvent } from "./watcherEvents";
import type { RawWatcherEvent, RepositoryWatchScope, StatusRefreshClient } from "./types";

export class DirtyPathPipeline {
  private readonly scopes = new Map<string, RepositoryWatchScope>();
  private readonly scheduler: StatusRefreshScheduler;

  public constructor(
    client: StatusRefreshClient,
    statusSnapshotStore: Pick<StatusSnapshotStore, "applyDelta" | "getSnapshot" | "markStale">,
    sourceControlProjection: Pick<SourceControlProjectionService, "applyDelta" | "getProjection" | "markStale" | "replaceSnapshot">,
    options: StatusRefreshSchedulerOptions = {},
  ) {
    this.scheduler = new StatusRefreshScheduler(client, statusSnapshotStore, sourceControlProjection, options);
  }

  public registerRepository(scope: RepositoryWatchScope): void {
    this.scopes.set(scope.repositoryId, scope);
    this.scheduler.registerRepository(scope);
  }

  public unregisterRepository(repositoryId: string): void {
    this.scopes.delete(repositoryId);
    this.scheduler.unregisterRepository(repositoryId);
  }

  public accept(repositoryId: string, event: RawWatcherEvent): boolean {
    const scope = this.scopes.get(repositoryId);
    if (!scope) {
      throw new Error(`Repository is not registered: ${repositoryId}`);
    }

    const normalized = normalizeWatcherEvent(scope, event);
    if (!normalized) {
      return false;
    }

    return this.scheduler.recordFileEvent(repositoryId, normalized);
  }

  public flushRepository(repositoryId: string, options?: StatusRefreshRunOptions): Promise<void> {
    return this.scheduler.flushRepository(repositoryId, options);
  }

  public fullReconcileRepository(
    request: FullReconcileRequest,
    options?: StatusRefreshRunOptions,
  ): Promise<void> {
    return this.scheduler.fullReconcileRepository(request, options);
  }

  public refreshResource(request: ResourceRefreshRequest): Promise<void> {
    return this.scheduler.refreshResource(request);
  }

  public refreshTargets(request: TargetRefreshRequest, options?: StatusRefreshRunOptions): Promise<void> {
    return this.scheduler.refreshTargets(request, options);
  }
}
