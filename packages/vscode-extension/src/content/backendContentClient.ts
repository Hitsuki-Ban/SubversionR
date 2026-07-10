import type { BackendService } from "../backend/backendService";
import { ContentGetRpcClient, type ContentBlob, type ContentGetRequest } from "./contentGetRpcClient";

export class BackendContentClient {
  public constructor(private readonly backendService: Pick<BackendService, "initialize">) {}

  public async getContent(request: ContentGetRequest): Promise<ContentBlob> {
    const connection = await this.backendService.initialize();
    return new ContentGetRpcClient(connection).getContent(request);
  }
}
