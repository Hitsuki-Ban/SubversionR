import type { DirtyPathPipeline } from "./dirtyPathPipeline";
import type { StatusRefreshRunOptions, TargetRefreshRequest } from "./statusRefreshScheduler";

export interface RepositoryRefreshTarget {
  repositoryId: string;
  epoch: number;
}

export interface RepositoryResourceRefreshTarget extends RepositoryRefreshTarget {
  path: string;
}

export interface RepositoryRefreshServiceOptions {
  dirtyPathPipeline: Pick<
    DirtyPathPipeline,
    "flushRepository" | "fullReconcileRepository" | "refreshResource" | "refreshTargets"
  >;
}

export class RepositoryRefreshService {
  public constructor(private readonly options: RepositoryRefreshServiceOptions) {}

  public refreshRepository(repositoryId: string, options?: StatusRefreshRunOptions): Promise<void> {
    if (options === undefined) {
      return this.options.dirtyPathPipeline.flushRepository(repositoryId);
    }
    return this.options.dirtyPathPipeline.flushRepository(repositoryId, options);
  }

  public fullReconcileRepository(
    target: RepositoryRefreshTarget,
    options?: StatusRefreshRunOptions,
  ): Promise<void> {
    if (options === undefined) {
      return this.options.dirtyPathPipeline.fullReconcileRepository(target);
    }
    return this.options.dirtyPathPipeline.fullReconcileRepository(target, options);
  }

  public refreshResource(target: RepositoryResourceRefreshTarget): Promise<void> {
    return this.options.dirtyPathPipeline.refreshResource(target);
  }

  public refreshTargets(target: TargetRefreshRequest, options?: StatusRefreshRunOptions): Promise<void> {
    if (options === undefined) {
      return this.options.dirtyPathPipeline.refreshTargets(target);
    }
    return this.options.dirtyPathPipeline.refreshTargets(target, options);
  }
}
