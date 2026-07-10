import type { JsonRpcSender } from "../status/types";

export type PropertiesErrorCategory = "input" | "protocol";

export interface PropertiesListRequest {
  repositoryId: string;
  epoch: number;
  path: string;
}

export interface PropertyEntry {
  name: string;
  value: string;
  valueEncoding: "utf8";
}

export interface PropertiesListResponse {
  repositoryId: string;
  epoch: number;
  path: string;
  properties: PropertyEntry[];
  source: "libsvn-local";
}

export interface PropertiesClient {
  listProperties(request: PropertiesListRequest): Promise<PropertiesListResponse>;
}

export class PropertiesListResponseError extends Error {
  public constructor(
    public readonly code: string,
    public readonly category: PropertiesErrorCategory,
    public readonly messageKey: string,
    public readonly safeArgs: Record<string, unknown> = {},
  ) {
    super(code);
    this.name = "PropertiesListResponseError";
  }
}

export class PropertiesListRpcClient implements PropertiesClient {
  public constructor(private readonly sender: JsonRpcSender) {}

  public async listProperties(request: PropertiesListRequest): Promise<PropertiesListResponse> {
    const validatedRequest = validatePropertiesListRequest(request);
    const rawResponse = await this.sender.sendRequest<unknown>("properties/list", validatedRequest);
    const response = parsePropertiesListResponse(rawResponse);
    requireResponseMatchesRequest(response, validatedRequest);
    return response;
  }
}

function validatePropertiesListRequest(request: PropertiesListRequest): PropertiesListRequest {
  if (!isRecord(request)) {
    throw invalidPropertiesRequest("repositoryId");
  }
  requireExactRequestKeys(request, "request", ["repositoryId", "epoch", "path"]);
  return {
    repositoryId: requireRequestString(request.repositoryId, "repositoryId"),
    epoch: requireNonNegativeInteger(request.epoch, "epoch", "request"),
    path: requireRequestPath(request.path, "path"),
  };
}

function parsePropertiesListResponse(rawResponse: unknown): PropertiesListResponse {
  const response = requireResponseRecord(rawResponse, "result");
  requireExactResponseKeys(response, "result", [
    "repositoryId",
    "epoch",
    "path",
    "properties",
    "source",
  ]);
  return {
    repositoryId: requireResponseString(response.repositoryId, "repositoryId"),
    epoch: requireNonNegativeInteger(response.epoch, "epoch", "response"),
    path: requireResponsePath(response.path, "path"),
    properties: parsePropertyEntries(response.properties, "properties"),
    source: requireSource(response.source, "source"),
  };
}

function requireResponseMatchesRequest(
  response: PropertiesListResponse,
  request: PropertiesListRequest,
): void {
  if (response.repositoryId !== request.repositoryId) {
    throw invalidPropertiesResponse("repositoryId");
  }
  if (response.epoch !== request.epoch) {
    throw invalidPropertiesResponse("epoch");
  }
  if (response.path !== request.path) {
    throw invalidPropertiesResponse("path");
  }
}

function parsePropertyEntries(value: unknown, field: string): PropertyEntry[] {
  if (!Array.isArray(value)) {
    throw invalidPropertiesResponse(field);
  }
  return value.map((entry, index) => parsePropertyEntry(entry, `${field}.${index}`));
}

function parsePropertyEntry(value: unknown, field: string): PropertyEntry {
  const entry = requireResponseRecord(value, field);
  requireExactResponseKeys(entry, field, ["name", "value", "valueEncoding"]);
  return {
    name: requirePropertyName(entry.name, `${field}.name`, "response"),
    value: requirePropertyValue(entry.value, `${field}.value`, "response"),
    valueEncoding: requireValueEncoding(entry.valueEncoding, `${field}.valueEncoding`),
  };
}

function requireValueEncoding(value: unknown, field: string): "utf8" {
  const encoding = requireResponseString(value, field);
  if (encoding !== "utf8") {
    throw invalidPropertiesResponse(field);
  }
  return encoding;
}

function requireSource(value: unknown, field: string): "libsvn-local" {
  const source = requireResponseString(value, field);
  if (source !== "libsvn-local") {
    throw invalidPropertiesResponse(field);
  }
  return source;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function requireResponseRecord(value: unknown, field: string): Record<string, unknown> {
  if (!isRecord(value)) {
    throw invalidPropertiesResponse(field);
  }
  return value;
}

function requireExactRequestKeys(
  value: Record<string, unknown>,
  field: string,
  expectedKeys: readonly string[],
): void {
  const expected = new Set(expectedKeys);
  for (const key of Object.keys(value)) {
    if (!expected.has(key)) {
      throw invalidPropertiesRequest(field === "request" ? key : `${field}.${key}`);
    }
  }
}

function requireExactResponseKeys(
  value: Record<string, unknown>,
  field: string,
  expectedKeys: readonly string[],
): void {
  const expected = new Set(expectedKeys);
  for (const key of Object.keys(value)) {
    if (!expected.has(key)) {
      throw invalidPropertiesResponse(field === "result" ? key : `${field}.${key}`);
    }
  }
}

function requireRequestString(value: unknown, field: string): string {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw invalidPropertiesRequest(field);
  }
  return value;
}

function requireResponseString(value: unknown, field: string): string {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw invalidPropertiesResponse(field);
  }
  return value;
}

function requireRequestPath(value: unknown, field: string): string {
  const path = requireRequestString(value, field);
  if (!isRepositoryRelativePath(path)) {
    throw invalidPropertiesRequest(field);
  }
  return path;
}

function requireResponsePath(value: unknown, field: string): string {
  const path = requireResponseString(value, field);
  if (!isRepositoryRelativePath(path)) {
    throw invalidPropertiesResponse(field);
  }
  return path;
}

function requirePropertyName(value: unknown, field: string, source: "request" | "response"): string {
  const name = source === "request" ? requireRequestString(value, field) : requireResponseString(value, field);
  if (
    name.includes("\0") ||
    name.includes("\r") ||
    name.includes("\n") ||
    !name.split(":").every(isPropertyNamePart)
  ) {
    throw source === "request" ? invalidPropertiesRequest(field) : invalidPropertiesResponse(field);
  }
  return name;
}

function isPropertyNamePart(part: string): boolean {
  return part.length > 0 && /^[A-Za-z0-9._-]+$/u.test(part);
}

function requirePropertyValue(value: unknown, field: string, source: "request" | "response"): string {
  if (typeof value !== "string" || value.includes("\0") || value.includes("\r")) {
    throw source === "request" ? invalidPropertiesRequest(field) : invalidPropertiesResponse(field);
  }
  return value;
}

function requireNonNegativeInteger(value: unknown, field: string, source: "request" | "response"): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
    throw source === "request" ? invalidPropertiesRequest(field) : invalidPropertiesResponse(field);
  }
  return value;
}

function isRepositoryRelativePath(path: string): boolean {
  if (path === ".") {
    return true;
  }
  const normalized = path.replace(/\\/g, "/");
  if (
    path.includes("\\") ||
    normalized.startsWith("/") ||
    normalized.includes(":") ||
    normalized.includes("\0")
  ) {
    return false;
  }
  return normalized.split("/").every((part) => part.length > 0 && part !== "." && part !== "..");
}

function invalidPropertiesRequest(field: string): PropertiesListResponseError {
  return new PropertiesListResponseError(
    "SUBVERSIONR_PROPERTIES_LIST_REQUEST_INVALID",
    "input",
    "error.properties.listRequestInvalid",
    { field },
  );
}

function invalidPropertiesResponse(field: string): PropertiesListResponseError {
  return new PropertiesListResponseError(
    "SUBVERSIONR_PROPERTIES_LIST_RESPONSE_INVALID",
    "protocol",
    "error.properties.listResponseInvalid",
    { field },
  );
}
