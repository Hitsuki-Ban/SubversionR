import type { StatusDelta } from "../status/statusRefreshRpcClient";
import type { StatusStaleMark } from "../status/statusSnapshotStore";
import type { StatusSnapshot } from "../status/statusSnapshotRpcClient";
import {
  SourceControlResourceStore,
  type ScmCommitAllTargets,
  type ScmProjectionFreshness,
  type ScmProjectedResourceLookup,
  type ScmRepositoryProjection,
  type SourceControlCountPolicy,
  type SourceControlProjectionRepository,
} from "./sourceControlResourceStore";
import type { PathCasePolicy } from "../status/types";

export interface SourceControlProjectionPresenter {
  registerRepository(repository: SourceControlProjectionRepository): void;
  updateRepository(projection: ScmRepositoryProjection): void;
  unregisterRepository(repositoryId: string): void;
  isCurrentResourceState(resourceState: unknown): boolean;
}

export type SourceControlProjectionChange =
  | {
      kind: "registered";
      repositoryId: string;
      epoch: number;
    }
  | {
      kind: "updated";
      repositoryId: string;
      epoch: number;
      generation: number;
      freshness: ScmProjectionFreshness;
    }
  | {
      kind: "unregistered";
      repositoryId: string;
    };

export interface SourceControlProjectionSubscription {
  dispose(): void;
}

export class SourceControlProjectionService {
  private readonly listeners = new Set<(event: SourceControlProjectionChange) => void>();

  public constructor(
    private readonly store: SourceControlResourceStore,
    private readonly presenter: SourceControlProjectionPresenter,
  ) {}

  public onDidChangeProjection(
    listener: (event: SourceControlProjectionChange) => void,
  ): SourceControlProjectionSubscription {
    this.listeners.add(listener);
    return {
      dispose: () => {
        this.listeners.delete(listener);
      },
    };
  }

  public registerRepository(repository: SourceControlProjectionRepository): void {
    this.store.registerRepository(repository);
    try {
      this.presenter.registerRepository(repository);
    } catch (error) {
      this.store.unregisterRepository(repository.repositoryId);
      throw error;
    }
    this.fireProjectionChange({
      kind: "registered",
      repositoryId: repository.repositoryId,
      epoch: repository.epoch,
    });
  }

  public unregisterRepository(repositoryId: string): void {
    this.store.unregisterRepository(repositoryId);
    this.presenter.unregisterRepository(repositoryId);
    this.fireProjectionChange({
      kind: "unregistered",
      repositoryId,
    });
  }

  public applySnapshot(snapshot: StatusSnapshot): ScmRepositoryProjection {
    const projection = this.store.applySnapshot(snapshot);
    this.presenter.updateRepository(projection);
    this.fireProjectionChange({
      kind: "updated",
      repositoryId: projection.repositoryId,
      epoch: projection.epoch,
      generation: projection.generation,
      freshness: projection.freshness,
    });
    return projection;
  }

  public replaceSnapshot(snapshot: StatusSnapshot): ScmRepositoryProjection {
    const projection = this.store.replaceSnapshot(snapshot);
    this.presenter.updateRepository(projection);
    this.fireProjectionChange({
      kind: "updated",
      repositoryId: projection.repositoryId,
      epoch: projection.epoch,
      generation: projection.generation,
      freshness: projection.freshness,
    });
    return projection;
  }

  public applyDelta(delta: StatusDelta): ScmRepositoryProjection {
    const projection = this.store.applyDelta(delta);
    this.presenter.updateRepository(projection);
    this.fireProjectionChange({
      kind: "updated",
      repositoryId: projection.repositoryId,
      epoch: projection.epoch,
      generation: projection.generation,
      freshness: projection.freshness,
    });
    return projection;
  }

  public markStale(mark: StatusStaleMark): ScmRepositoryProjection {
    const projection = this.store.markStale(mark);
    this.presenter.updateRepository(projection);
    this.fireProjectionChange({
      kind: "updated",
      repositoryId: projection.repositoryId,
      epoch: projection.epoch,
      generation: projection.generation,
      freshness: projection.freshness,
    });
    return projection;
  }

  public getProjection(repositoryId: string): ScmRepositoryProjection | undefined {
    return this.store.getProjection(repositoryId);
  }

  public updateCountPolicy(countPolicy: SourceControlCountPolicy): ScmRepositoryProjection[] {
    const projections = this.store.updateCountPolicy(countPolicy);
    for (const projection of projections) {
      this.presenter.updateRepository(projection);
    }
    return projections;
  }

  public getCommitAllTargets(repositoryId: string): ScmCommitAllTargets | undefined {
    return this.store.getCommitAllTargets(repositoryId);
  }

  public getProjectedResource(
    repositoryId: string,
    path: string,
    pathCase: PathCasePolicy,
  ): ScmProjectedResourceLookup | undefined {
    return this.store.getProjectedResource(repositoryId, path, pathCase);
  }

  public isCurrentResourceState(resourceState: unknown): boolean {
    return this.presenter.isCurrentResourceState(resourceState);
  }

  private fireProjectionChange(event: SourceControlProjectionChange): void {
    for (const listener of this.listeners) {
      listener(event);
    }
  }
}
