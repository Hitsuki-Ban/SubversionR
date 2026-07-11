import type { JsonRpcSender, StatusRefreshClientOptions } from "./types";
import { parseStatusDelta, type StatusDelta } from "./statusRefreshRpcClient";

export interface StatusRemoteCheckRequest {
  repositoryId: string;
  epoch: number;
}

export interface StatusRemoteCheckClient {
  checkRemoteStatus(
    request: StatusRemoteCheckRequest,
    options?: StatusRefreshClientOptions,
  ): Promise<StatusDelta>;
}

export class StatusRemoteCheckRequestError extends Error {
  public constructor(
    public readonly code: string,
    public readonly category: "input" | "protocol",
    public readonly messageKey: string,
    public readonly safeArgs: Record<string, unknown>,
  ) {
    super(code);
    this.name = "StatusRemoteCheckRequestError";
  }
}

export class StatusRemoteCheckRpcClient implements StatusRemoteCheckClient {
  public constructor(private readonly sender: JsonRpcSender) {}

  public async checkRemoteStatus(
    request: StatusRemoteCheckRequest,
    options: StatusRefreshClientOptions = {},
  ): Promise<StatusDelta> {
    const validatedRequest = validateRequest(request);
    const rawResponse = options.signal
      ? await this.sender.sendRequest<unknown>("status/checkRemote", validatedRequest, options)
      : await this.sender.sendRequest<unknown>("status/checkRemote", validatedRequest);
    const delta = parseStatusDelta(rawResponse);
    if (delta.repositoryId !== validatedRequest.repositoryId) {
      throw invalidResponse("repositoryId");
    }
    if (delta.epoch !== validatedRequest.epoch) {
      throw invalidResponse("epoch");
    }
    if (
      delta.source !== "libsvn-remote" ||
      delta.completeness !== "complete" ||
      delta.upsert.length !== 0 ||
      delta.remove.length !== 0 ||
      delta.coverage.length !== 1 ||
      delta.coverage[0]?.path !== "." ||
      delta.coverage[0]?.depth !== "workingCopy" ||
      delta.coverage[0]?.reason !== "manualRemoteCheck"
    ) {
      throw invalidResponse("remoteCoverage");
    }
    return delta;
  }
}

function validateRequest(request: StatusRemoteCheckRequest): StatusRemoteCheckRequest {
  if (!isRecord(request)) {
    throw invalidRequest("repositoryId");
  }
  const keys = Object.keys(request).sort();
  if (keys.length !== 2 || keys[0] !== "epoch" || keys[1] !== "repositoryId") {
    throw invalidRequest("request");
  }
  if (typeof request.repositoryId !== "string" || request.repositoryId.trim().length === 0) {
    throw invalidRequest("repositoryId");
  }
  if (!Number.isSafeInteger(request.epoch) || request.epoch < 0) {
    throw invalidRequest("epoch");
  }
  return { repositoryId: request.repositoryId, epoch: request.epoch };
}

function invalidRequest(field: string): StatusRemoteCheckRequestError {
  return new StatusRemoteCheckRequestError(
    "SUBVERSIONR_STATUS_REMOTE_CHECK_REQUEST_INVALID",
    "input",
    "error.status.remoteCheckRequestInvalid",
    { field },
  );
}

function invalidResponse(field: string): StatusRemoteCheckRequestError {
  return new StatusRemoteCheckRequestError(
    "SUBVERSIONR_STATUS_REMOTE_CHECK_RESPONSE_INVALID",
    "protocol",
    "error.status.remoteCheckResponseInvalid",
    { field },
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
