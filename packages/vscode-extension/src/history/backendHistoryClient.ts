import type { BackendService } from "../backend/backendService";
import { HistoryBlameRpcClient, type HistoryBlame, type HistoryBlameRequest } from "./historyBlameRpcClient";
import { HistoryLogRpcClient, type HistoryLog, type HistoryLogRequest } from "./historyLogRpcClient";

export class BackendHistoryClient {
  public constructor(private readonly backendService: Pick<BackendService, "initialize">) {}

  public async getLog(request: HistoryLogRequest): Promise<HistoryLog> {
    const connection = await this.backendService.initialize();
    return new HistoryLogRpcClient(connection).getLog(request);
  }

  public async getBlame(request: HistoryBlameRequest): Promise<HistoryBlame> {
    const connection = await this.backendService.initialize();
    return new HistoryBlameRpcClient(connection).getBlame(request);
  }
}
