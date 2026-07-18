import type { BackendService } from "../backend/backendService";
import {
  RemoteRecoveryRpcClient,
  type RemoteRecoveryClient,
  type RemoteRecoveryRequest,
  type RemoteRecoveryResult,
} from "./remoteRecoveryRpcClient";
import type { StatusRefreshClientOptions } from "./types";

export class BackendRemoteRecoveryClient implements RemoteRecoveryClient {
  public constructor(private readonly backendService: Pick<BackendService, "initialize">) {}

  public async recoverWorkingCopy(
    request: RemoteRecoveryRequest,
    options: StatusRefreshClientOptions = {},
  ): Promise<RemoteRecoveryResult> {
    const connection = await this.backendService.initialize();
    return await new RemoteRecoveryRpcClient(connection).recoverWorkingCopy(request, options);
  }
}
