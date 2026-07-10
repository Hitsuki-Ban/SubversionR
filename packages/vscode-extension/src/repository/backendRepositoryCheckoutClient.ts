import type { BackendService } from "../backend/backendService";
import {
  RepositoryCheckoutRpcClient,
  type RepositoryCheckoutClient,
  type RepositoryCheckoutClientOptions,
  type RepositoryCheckoutRequest,
  type RepositoryCheckoutResponse,
} from "./repositoryCheckoutRpcClient";

export class BackendRepositoryCheckoutClient implements RepositoryCheckoutClient {
  public constructor(private readonly backendService: Pick<BackendService, "initialize">) {}

  public async checkout(
    request: RepositoryCheckoutRequest,
    options?: RepositoryCheckoutClientOptions,
  ): Promise<RepositoryCheckoutResponse> {
    const connection = await this.backendService.initialize();
    return new RepositoryCheckoutRpcClient(connection).checkout(request, options);
  }
}
