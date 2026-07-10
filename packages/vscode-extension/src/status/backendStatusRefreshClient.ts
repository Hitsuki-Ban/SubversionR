import type { BackendService } from "../backend/backendService";
import { StatusRefreshRpcClient, type StatusDelta } from "./statusRefreshRpcClient";
import type { StatusRefreshClient, StatusRefreshClientOptions, StatusRefreshRequest } from "./types";

export class BackendStatusRefreshClient implements StatusRefreshClient {
  public constructor(private readonly backendService: Pick<BackendService, "initialize">) {}

  public async refreshStatus(
    request: StatusRefreshRequest,
    options: StatusRefreshClientOptions = {},
  ): Promise<StatusDelta> {
    const connection = await this.backendService.initialize();
    return new StatusRefreshRpcClient(connection).refreshStatus(request, options);
  }
}
