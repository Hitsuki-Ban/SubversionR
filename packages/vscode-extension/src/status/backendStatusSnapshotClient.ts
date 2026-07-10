import type { BackendService } from "../backend/backendService";
import {
  StatusSnapshotRpcClient,
  type StatusSnapshot,
  type StatusSnapshotRequest,
} from "./statusSnapshotRpcClient";

export class BackendStatusSnapshotClient {
  public constructor(private readonly backendService: Pick<BackendService, "initialize">) {}

  public async getSnapshot(request: StatusSnapshotRequest): Promise<StatusSnapshot> {
    const connection = await this.backendService.initialize();
    return await new StatusSnapshotRpcClient(connection).getSnapshot(request);
  }
}
