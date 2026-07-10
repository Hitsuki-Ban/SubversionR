export const BASE_CONTENT_URI_SCHEME = "svn-r-base";

export interface BaseContentUriRequest {
  repositoryId: string;
  epoch: number;
  generation: number;
  path: string;
  revision: "base";
}

export interface BaseContentUriComponents {
  scheme: string;
  authority: string;
  path: string;
  query: string;
}

export class BaseContentUriError extends Error {
  public constructor(
    public readonly code: string,
    public readonly field: string,
  ) {
    super(code);
    this.name = "BaseContentUriError";
  }
}

export function createBaseContentUriComponents(request: BaseContentUriRequest): BaseContentUriComponents {
  validateBaseContentUriRequest(request);
  const query = new URLSearchParams();
  query.set("repositoryId", request.repositoryId);
  query.set("epoch", String(request.epoch));
  query.set("generation", String(request.generation));
  query.set("path", request.path);
  query.set("revision", request.revision);
  return {
    scheme: BASE_CONTENT_URI_SCHEME,
    authority: "base",
    path: "/",
    query: query.toString(),
  };
}

export function parseBaseContentUri(uri: BaseContentUriComponents): BaseContentUriRequest {
  if (uri.scheme !== BASE_CONTENT_URI_SCHEME) {
    throw invalidBaseContentUri("scheme");
  }
  if (uri.authority !== "base") {
    throw invalidBaseContentUri("authority");
  }
  if (uri.path !== "/") {
    throw invalidBaseContentUri("path");
  }
  const query = new URLSearchParams(uri.query);
  requireExactQueryKeys(query, ["repositoryId", "epoch", "generation", "path", "revision"]);
  const request = {
    repositoryId: requireQueryString(query, "repositoryId"),
    epoch: requireQueryInteger(query, "epoch"),
    generation: requireQueryInteger(query, "generation"),
    path: requireQueryString(query, "path"),
    revision: requireQueryString(query, "revision"),
  };
  validateBaseContentUriRequest(request);
  return {
    repositoryId: request.repositoryId,
    epoch: request.epoch,
    generation: request.generation,
    path: request.path,
    revision: "base",
  };
}

function requireExactQueryKeys(query: URLSearchParams, expectedKeys: readonly string[]): void {
  const expected = new Set(expectedKeys);
  const seen = new Map<string, number>();
  for (const key of query.keys()) {
    if (!expected.has(key)) {
      throw invalidBaseContentUri(key);
    }
    seen.set(key, (seen.get(key) ?? 0) + 1);
  }
  for (const key of expectedKeys) {
    if (seen.get(key) !== 1) {
      throw invalidBaseContentUri(key);
    }
  }
}

function validateBaseContentUriRequest(request: {
  repositoryId: string;
  epoch: number;
  generation: number;
  path: string;
  revision: string;
}): void {
  if (typeof request.repositoryId !== "string" || request.repositoryId.trim().length === 0) {
    throw invalidBaseContentUri("repositoryId");
  }
  if (!Number.isSafeInteger(request.epoch) || request.epoch < 0) {
    throw invalidBaseContentUri("epoch");
  }
  if (!Number.isSafeInteger(request.generation) || request.generation < 0) {
    throw invalidBaseContentUri("generation");
  }
  if (typeof request.path !== "string" || !isContentPath(request.path)) {
    throw invalidBaseContentUri("path");
  }
  if (request.revision !== "base") {
    throw invalidBaseContentUri("revision");
  }
}

function requireQueryString(query: URLSearchParams, field: string): string {
  const value = query.get(field);
  if (value === null || value.trim().length === 0) {
    throw invalidBaseContentUri(field);
  }
  return value;
}

function requireQueryInteger(query: URLSearchParams, field: string): number {
  const value = requireQueryString(query, field);
  if (!/^\d+$/.test(value)) {
    throw invalidBaseContentUri(field);
  }
  const integer = Number(value);
  if (!Number.isSafeInteger(integer)) {
    throw invalidBaseContentUri(field);
  }
  return integer;
}

function isContentPath(path: string): boolean {
  if (path === "." || path.trim().length === 0) {
    return false;
  }
  const normalized = path.replace(/\\/g, "/");
  if (normalized.startsWith("/") || normalized.includes(":") || normalized.includes("\0")) {
    return false;
  }
  return normalized.split("/").every((part) => part.length > 0 && part !== "." && part !== "..");
}

function invalidBaseContentUri(field: string): BaseContentUriError {
  return new BaseContentUriError("SUBVERSIONR_BASE_CONTENT_URI_INVALID", field);
}
