import type { SourceControlProjectionService } from "../scm/sourceControlProjectionService";
import type { RemoteConnectionStateStore } from "./remoteConnectionStateStore";
import type { RemoteRecoveryClient } from "./remoteRecoveryRpcClient";
import type { StatusRefreshClientOptions } from "./types";
import { remoteFailureFromError } from "./remoteStatusCheckService";

export interface RemoteRecoveryTarget {
  repositoryId: string;
  epoch: number;
}

export interface RemoteRecoveryServiceOptions {
  client: RemoteRecoveryClient;
  store: Pick<RemoteConnectionStateStore, "beginRecovery" | "completeRecovery" | "getState">;
  projection: Pick<SourceControlProjectionService, "updateRemoteConnectionState">;
  createOperationId(): string;
  now(): string;
  timeoutMs: number;
}

export class RemoteRecoveryServiceError extends Error {
  public readonly category: "input" | "lifecycle";
  public readonly messageKey: string;
  public readonly safeArgs: Readonly<Record<string, unknown>>;

  public constructor(
    public readonly code: string,
    category: "input" | "lifecycle",
    messageKey: string,
    safeArgs: Readonly<Record<string, unknown>> = {},
  ) {
    super(code);
    this.name = "RemoteRecoveryServiceError";
    this.category = category;
    this.messageKey = messageKey;
    this.safeArgs = safeArgs;
  }
}

export class RemoteRecoveryService {
  public constructor(private readonly options: RemoteRecoveryServiceOptions) {
    if (!Number.isSafeInteger(options.timeoutMs) || options.timeoutMs < 1 || options.timeoutMs > 300_000) {
      throw new RemoteRecoveryServiceError(
        "SUBVERSIONR_REMOTE_RECOVERY_TIMEOUT_INVALID",
        "input",
        "error.remote.recoveryTimeoutInvalid",
      );
    }
  }

  public async recover(
    target: RemoteRecoveryTarget,
    clientOptions: StatusRefreshClientOptions = {},
  ): Promise<"safe" | "indeterminate" | "blocked"> {
    const current = this.options.store.getState(target.repositoryId);
    if (
      !current || current.epoch !== target.epoch ||
      current.kind !== "indeterminate" || current.recovery.kind !== "required"
    ) {
      throw new RemoteRecoveryServiceError(
        "SUBVERSIONR_REMOTE_RECOVERY_NOT_REQUIRED",
        "lifecycle",
        "error.remote.recoveryNotRequired",
        { repositoryId: target.repositoryId },
      );
    }
    const originOperationId = current.recovery.operationId;
    const operationId = this.options.createOperationId();
    const startedAt = this.options.now();
    const deadlineAt = new Date(Date.parse(startedAt) + this.options.timeoutMs).toISOString();
    const checking = this.options.store.beginRecovery({
      ...target,
      operationId,
      startedAt,
      deadlineAt,
    });
    this.options.projection.updateRemoteConnectionState(checking);
    let result;
    try {
      result = await this.options.client.recoverWorkingCopy({
        ...target,
        operationId,
        originOperationId,
        timeoutMs: this.options.timeoutMs,
      }, clientOptions);
    } catch (error) {
      const completed = this.options.store.completeRecovery({
        ...target,
        operationId,
        completedAt: this.options.now(),
        result: "indeterminate",
        failure: remoteFailureFromError(error),
      });
      if (completed.applied) this.options.projection.updateRemoteConnectionState(completed.state);
      throw error;
    }
    const completed = this.options.store.completeRecovery({
      ...target,
      operationId,
      completedAt: result.outcome === "safe" ? result.completedAt : this.options.now(),
      result: result.outcome,
      ...(result.outcome === "safe" ? {} : { failure: result.failure }),
    });
    if (completed.applied) this.options.projection.updateRemoteConnectionState(completed.state);
    return result.outcome;
  }
}
