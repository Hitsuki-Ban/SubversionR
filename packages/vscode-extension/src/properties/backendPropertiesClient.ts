import type { BackendService } from "../backend/backendService";
import {
  PropertiesListRpcClient,
  type PropertiesClient,
  type PropertiesListRequest,
  type PropertiesListResponse,
} from "./propertiesListRpcClient";

export class BackendPropertiesClient implements PropertiesClient {
  public constructor(private readonly backendService: Pick<BackendService, "initialize">) {}

  public async listProperties(request: PropertiesListRequest): Promise<PropertiesListResponse> {
    const connection = await this.backendService.initialize();
    return new PropertiesListRpcClient(connection).listProperties(request);
  }
}
