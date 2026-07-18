import type { BackendService } from "../backend/backendService";
import {
  ContentGetRpcClient,
  type ContentBlob,
  type ContentClientOptions,
  type ContentGetRequest,
} from "./contentGetRpcClient";

export class BackendContentClient {
  public constructor(private readonly backendService: Pick<BackendService, "initialize">) {}

  public async getContent(request: ContentGetRequest, options?: ContentClientOptions): Promise<ContentBlob> {
    const connection = await this.backendService.initialize();
    return new ContentGetRpcClient(connection).getContent(request, options);
  }
}
