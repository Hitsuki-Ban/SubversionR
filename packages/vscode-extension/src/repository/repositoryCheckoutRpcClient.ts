import path from "node:path";
import type { JsonRpcRequestOptions, JsonRpcSender } from "../status/types";

export type RepositoryCheckoutErrorCategory = "input" | "protocol";
export type RepositoryCheckoutRevision = "head" | number;
export type RepositoryCheckoutDepth = "empty" | "files" | "immediates" | "infinity";

export interface RepositoryCheckoutRequest {
  url: string;
  targetPath: string;
  revision: RepositoryCheckoutRevision;
  depth: RepositoryCheckoutDepth;
  ignoreExternals: boolean;
}

export interface RepositoryCheckoutResponse {
  workingCopyPath: string;
  revision: number;
}

export type RepositoryCheckoutClientOptions = JsonRpcRequestOptions;

export interface RepositoryCheckoutClient {
  checkout(
    request: RepositoryCheckoutRequest,
    options?: RepositoryCheckoutClientOptions,
  ): Promise<RepositoryCheckoutResponse>;
}

export class RepositoryCheckoutResponseError extends Error {
  public constructor(
    public readonly code: string,
    public readonly category: RepositoryCheckoutErrorCategory,
    public readonly messageKey: string,
    public readonly safeArgs: Record<string, unknown> = {},
  ) {
    super(code);
    this.name = "RepositoryCheckoutResponseError";
  }
}

const MAX_SVN_REVNUM = 2_147_483_647;
const CHECKOUT_DEPTHS = new Set<RepositoryCheckoutDepth>(["empty", "files", "immediates", "infinity"]);

export class RepositoryCheckoutRpcClient implements RepositoryCheckoutClient {
  public constructor(private readonly sender: JsonRpcSender) {}

  public async checkout(
    request: RepositoryCheckoutRequest,
    options?: RepositoryCheckoutClientOptions,
  ): Promise<RepositoryCheckoutResponse> {
    const validatedRequest = validateCheckoutRequest(request);
    const rawResponse =
      options === undefined
        ? await this.sender.sendRequest<unknown>("repository/checkout", validatedRequest)
        : await this.sender.sendRequest<unknown>("repository/checkout", validatedRequest, options);
    return parseCheckoutResponse(rawResponse);
  }
}

function validateCheckoutRequest(request: RepositoryCheckoutRequest): RepositoryCheckoutRequest {
  if (!isRecord(request)) {
    throw invalidCheckoutRequest("url");
  }
  requireExactKeys(request, "request", ["url", "targetPath", "revision", "depth", "ignoreExternals"], "request");
  return {
    url: requireCheckoutUrl(request.url, "url"),
    targetPath: requireAbsolutePath(request.targetPath, "targetPath", "request"),
    revision: requireRevision(request.revision, "revision", "request"),
    depth: requireCheckoutDepth(request.depth, "depth"),
    ignoreExternals: requireBoolean(request.ignoreExternals, "ignoreExternals", "request"),
  };
}

function parseCheckoutResponse(rawResponse: unknown): RepositoryCheckoutResponse {
  const response = requireResponseRecord(rawResponse, "result");
  requireExactKeys(response, "result", ["workingCopyPath", "revision"], "response");
  return {
    workingCopyPath: requireAbsolutePath(response.workingCopyPath, "workingCopyPath", "response"),
    revision: requireRevisionNumber(response.revision, "revision", "response"),
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function requireResponseRecord(value: unknown, field: string): Record<string, unknown> {
  if (!isRecord(value)) {
    throw invalidCheckoutResponse(field);
  }
  return value;
}

function requireExactKeys(
  value: Record<string, unknown>,
  field: string,
  expectedKeys: readonly string[],
  source: "request" | "response",
): void {
  const expected = new Set(expectedKeys);
  for (const key of Object.keys(value)) {
    if (!expected.has(key)) {
      throw source === "request"
        ? invalidCheckoutRequest(field === "request" ? key : `${field}.${key}`)
        : invalidCheckoutResponse(field === "result" ? key : `${field}.${key}`);
    }
  }
}

function requireCheckoutUrl(value: unknown, field: string): string {
  const url = requireString(value, field, "request");
  if (url.includes("\0") || url.includes("\r") || url.includes("\n")) {
    throw invalidCheckoutRequest(field);
  }
  return url;
}

function requireAbsolutePath(value: unknown, field: string, source: "request" | "response"): string {
  const valuePath = requireString(value, field, source);
  if (!isAbsolutePath(valuePath) || valuePath.includes("\0") || valuePath.includes("\r") || valuePath.includes("\n")) {
    throw source === "request" ? invalidCheckoutRequest(field) : invalidCheckoutResponse(field);
  }
  return valuePath;
}

function requireRevision(value: unknown, field: string, source: "request" | "response"): RepositoryCheckoutRevision {
  if (value === "head") {
    return value;
  }
  return requireRevisionNumber(value, field, source);
}

function requireRevisionNumber(value: unknown, field: string, source: "request" | "response"): number {
  if (typeof value !== "number" || !Number.isInteger(value) || value < 0 || value > MAX_SVN_REVNUM) {
    throw source === "request" ? invalidCheckoutRequest(field) : invalidCheckoutResponse(field);
  }
  return value;
}

function requireCheckoutDepth(value: unknown, field: string): RepositoryCheckoutDepth {
  const depth = requireString(value, field, "request");
  if (!CHECKOUT_DEPTHS.has(depth as RepositoryCheckoutDepth)) {
    throw invalidCheckoutRequest(field);
  }
  return depth as RepositoryCheckoutDepth;
}

function requireString(value: unknown, field: string, source: "request" | "response"): string {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw source === "request" ? invalidCheckoutRequest(field) : invalidCheckoutResponse(field);
  }
  return value;
}

function requireBoolean(value: unknown, field: string, source: "request" | "response"): boolean {
  if (typeof value !== "boolean") {
    throw source === "request" ? invalidCheckoutRequest(field) : invalidCheckoutResponse(field);
  }
  return value;
}

function isAbsolutePath(value: string): boolean {
  return path.isAbsolute(value) || path.win32.isAbsolute(value) || path.posix.isAbsolute(value);
}

function invalidCheckoutRequest(field: string): RepositoryCheckoutResponseError {
  return new RepositoryCheckoutResponseError(
    "SUBVERSIONR_REPOSITORY_CHECKOUT_REQUEST_INVALID",
    "input",
    "error.repository.checkoutRequestInvalid",
    { field },
  );
}

function invalidCheckoutResponse(field: string): RepositoryCheckoutResponseError {
  return new RepositoryCheckoutResponseError(
    "SUBVERSIONR_REPOSITORY_CHECKOUT_RESPONSE_INVALID",
    "protocol",
    "error.repository.checkoutResponseInvalid",
    { field },
  );
}
