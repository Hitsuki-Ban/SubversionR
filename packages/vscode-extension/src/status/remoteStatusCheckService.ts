import type { SourceControlProjectionService } from "../scm/sourceControlProjectionService";
import type { DirtyPathPipeline } from "./dirtyPathPipeline";
import type { StatusSnapshotStore } from "./statusSnapshotStore";
import type { StatusRemoteCheckClient, StatusRemoteCheckRequest } from "./statusRemoteCheckRpcClient";
import type { StatusRefreshClientOptions } from "./types";

export interface RemoteStatusCheckServiceOptions {
  client: StatusRemoteCheckClient;
  statusSnapshotStore: Pick<StatusSnapshotStore, "applyDelta">;
  sourceControlProjection: Pick<SourceControlProjectionService, "applyDelta" | "replaceSnapshot">;
  refreshPipeline: Pick<DirtyPathPipeline, "runExclusive">;
}

export class RemoteStatusCheckService {
  public constructor(private readonly options: RemoteStatusCheckServiceOptions) {}

  public async checkRemoteChanges(
    request: StatusRemoteCheckRequest,
    clientOptions: StatusRefreshClientOptions = {},
  ): Promise<number> {
    return await this.options.refreshPipeline.runExclusive(request.repositoryId, async () => {
      const delta = await this.options.client.checkRemoteStatus(request, clientOptions);
      const snapshot = this.options.statusSnapshotStore.applyDelta(delta);
      try {
        this.options.sourceControlProjection.applyDelta(delta);
      } catch (error) {
        this.options.sourceControlProjection.replaceSnapshot(snapshot);
        throw error;
      }
      return snapshot.summary.remoteChanges;
    });
  }
}
