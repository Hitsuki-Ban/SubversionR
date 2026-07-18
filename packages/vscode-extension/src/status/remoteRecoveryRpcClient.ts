import type { JsonRpcSender, StatusRefreshClientOptions } from "./types";
import { parseWireRemoteFailure, type NativeRemoteFailure } from "./remoteConnectionStateStore";

export interface RemoteRecoveryRequest {
  repositoryId: string;
  epoch: number;
  operationId: string;
  originOperationId: string;
  timeoutMs: number;
}

export type RemoteRecoveryResult =
  | { outcome: "safe"; operationId: string; completedAt: string }
  | { outcome: "indeterminate" | "blocked"; operationId: string; failure: NativeRemoteFailure };

export interface RemoteRecoveryClient {
  recoverWorkingCopy(request: RemoteRecoveryRequest, options?: StatusRefreshClientOptions): Promise<RemoteRecoveryResult>;
}

export class RemoteRecoveryRpcClient implements RemoteRecoveryClient {
  public constructor(private readonly sender: JsonRpcSender) {}

  public async recoverWorkingCopy(
    request: RemoteRecoveryRequest,
    options: StatusRefreshClientOptions = {},
  ): Promise<RemoteRecoveryResult> {
    const validated = validateRequest(request);
    const result = options.signal
      ? await this.sender.sendRequest<unknown>("remote/recoverWorkingCopy", validated, options)
      : await this.sender.sendRequest<unknown>("remote/recoverWorkingCopy", validated);
    return parseResponse(result, validated.operationId);
  }
}

function parseResponse(value: unknown, expectedOperationId: string): RemoteRecoveryResult {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new RemoteRecoveryRpcError("response");
  }
  const response = value as Record<string, unknown>;
  if (response.operationId !== expectedOperationId) {
    throw new RemoteRecoveryRpcError("response.operationId");
  }
  if (response.outcome === "safe") {
    if (Object.keys(response).sort().join(",") !== "completedAt,operationId,outcome" || !isTimestamp(response.completedAt)) {
      throw new RemoteRecoveryRpcError("response.safe");
    }
    return { outcome: "safe", operationId: expectedOperationId, completedAt: response.completedAt as string };
  }
  if (response.outcome === "indeterminate" || response.outcome === "blocked") {
    if (Object.keys(response).sort().join(",") !== "failure,operationId,outcome") {
      throw new RemoteRecoveryRpcError("response.failure");
    }
    let failure: NativeRemoteFailure;
    try {
      failure = parseWireRemoteFailure(response.failure);
    } catch {
      throw new RemoteRecoveryRpcError("response.failure");
    }
    return { outcome: response.outcome, operationId: expectedOperationId, failure };
  }
  throw new RemoteRecoveryRpcError("response.outcome");
}

function isTimestamp(value: unknown): value is string {
  return typeof value === "string" && value.length <= 64 && !Number.isNaN(Date.parse(value));
}

export class RemoteRecoveryRpcError extends Error {
  public readonly code = "SUBVERSIONR_REMOTE_RECOVERY_RPC_INVALID";
  public readonly category = "protocol";
  public readonly messageKey = "error.remote.recoveryRpcInvalid";
  public readonly safeArgs: Readonly<Record<string, unknown>>;

  public constructor(field: string) {
    super("SUBVERSIONR_REMOTE_RECOVERY_RPC_INVALID");
    this.name = "RemoteRecoveryRpcError";
    this.safeArgs = { field };
  }
}

function validateRequest(request: RemoteRecoveryRequest): RemoteRecoveryRequest {
  if (
    typeof request !== "object" || request === null ||
    Object.keys(request).sort().join(",") !== "epoch,operationId,originOperationId,repositoryId,timeoutMs" ||
    typeof request.repositoryId !== "string" || request.repositoryId.trim().length === 0 ||
    !Number.isSafeInteger(request.epoch) || request.epoch < 0 ||
    !isCanonicalUuid(request.operationId) ||
    !isCanonicalUuid(request.originOperationId) ||
    request.originOperationId === request.operationId ||
    !Number.isSafeInteger(request.timeoutMs) || request.timeoutMs < 1 || request.timeoutMs > 300_000
  ) {
    throw new RemoteRecoveryRpcError("request");
  }
  return { ...request };
}

function isCanonicalUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(value);
}
