import type { BackendService } from "../backend/backendService";
import {
  HistoryBlameRpcClient,
  type HistoryBlame,
  type HistoryBlameClientOptions,
  type HistoryBlameRequest,
} from "./historyBlameRpcClient";
import {
  HistoryLogRpcClient,
  type HistoryClientOptions,
  type HistoryLog,
  type HistoryLogRequest,
} from "./historyLogRpcClient";

export class BackendHistoryClient {
  public constructor(private readonly backendService: Pick<BackendService, "initialize">) {}

  public async getLog(request: HistoryLogRequest, options?: HistoryClientOptions): Promise<HistoryLog> {
    const connection = await this.backendService.initialize();
    return new HistoryLogRpcClient(connection).getLog(request, options);
  }

  public async getBlame(
    request: HistoryBlameRequest,
    options?: HistoryBlameClientOptions,
  ): Promise<HistoryBlame> {
    const connection = await this.backendService.initialize();
    return new HistoryBlameRpcClient(connection).getBlame(request, options);
  }
}
