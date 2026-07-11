import type { BackendService } from "../backend/backendService";
import {
  StatusRemoteCheckRpcClient,
  type StatusRemoteCheckClient,
  type StatusRemoteCheckRequest,
} from "./statusRemoteCheckRpcClient";
import type { StatusDelta } from "./statusRefreshRpcClient";
import type { StatusRefreshClientOptions } from "./types";

export class BackendStatusRemoteCheckClient implements StatusRemoteCheckClient {
  public constructor(private readonly backendService: Pick<BackendService, "initialize">) {}

  public async checkRemoteStatus(
    request: StatusRemoteCheckRequest,
    options: StatusRefreshClientOptions = {},
  ): Promise<StatusDelta> {
    const connection = await this.backendService.initialize();
    return new StatusRemoteCheckRpcClient(connection).checkRemoteStatus(request, options);
  }
}
