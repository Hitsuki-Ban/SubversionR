export const HEAD_CONTENT_URI_SCHEME = "svn-r-head";

export interface HeadContentUriRequest {
  repositoryId: string;
  epoch: number;
  generation: number;
  path: string;
  revision: "head";
  requestId: string;
}

export interface HeadContentUriComponents {
  scheme: string;
  authority: string;
  path: string;
  query: string;
}

export class HeadContentUriError extends Error {
  public constructor(
    public readonly code: string,
    public readonly field: string,
  ) {
    super(code);
    this.name = "HeadContentUriError";
  }
}

export function createHeadContentUriComponents(request: HeadContentUriRequest): HeadContentUriComponents {
  validateHeadContentUriRequest(request);
  const query = new URLSearchParams();
  query.set("repositoryId", request.repositoryId);
  query.set("epoch", String(request.epoch));
  query.set("generation", String(request.generation));
  query.set("path", request.path);
  query.set("revision", request.revision);
  query.set("requestId", request.requestId);
  return {
    scheme: HEAD_CONTENT_URI_SCHEME,
    authority: "head",
    path: "/",
    query: query.toString(),
  };
}

export function parseHeadContentUri(uri: HeadContentUriComponents): HeadContentUriRequest {
  if (uri.scheme !== HEAD_CONTENT_URI_SCHEME) {
    throw invalidHeadContentUri("scheme");
  }
  if (uri.authority !== "head") {
    throw invalidHeadContentUri("authority");
  }
  if (uri.path !== "/") {
    throw invalidHeadContentUri("path");
  }
  const query = new URLSearchParams(uri.query);
  requireExactQueryKeys(query, ["repositoryId", "epoch", "generation", "path", "revision", "requestId"]);
  const request = {
    repositoryId: requireQueryString(query, "repositoryId"),
    epoch: requireQueryInteger(query, "epoch"),
    generation: requireQueryInteger(query, "generation"),
    path: requireQueryString(query, "path"),
    revision: requireQueryString(query, "revision"),
    requestId: requireQueryString(query, "requestId"),
  };
  validateHeadContentUriRequest(request);
  return {
    repositoryId: request.repositoryId,
    epoch: request.epoch,
    generation: request.generation,
    path: request.path,
    revision: "head",
    requestId: request.requestId,
  };
}

function requireExactQueryKeys(query: URLSearchParams, expectedKeys: readonly string[]): void {
  const expected = new Set(expectedKeys);
  const seen = new Map<string, number>();
  for (const key of query.keys()) {
    if (!expected.has(key)) {
      throw invalidHeadContentUri(key);
    }
    seen.set(key, (seen.get(key) ?? 0) + 1);
  }
  for (const key of expectedKeys) {
    if (seen.get(key) !== 1) {
      throw invalidHeadContentUri(key);
    }
  }
}

function validateHeadContentUriRequest(request: {
  repositoryId: string;
  epoch: number;
  generation: number;
  path: string;
  revision: string;
  requestId: string;
}): void {
  if (typeof request.repositoryId !== "string" || request.repositoryId.trim().length === 0) {
    throw invalidHeadContentUri("repositoryId");
  }
  if (!Number.isSafeInteger(request.epoch) || request.epoch < 0) {
    throw invalidHeadContentUri("epoch");
  }
  if (!Number.isSafeInteger(request.generation) || request.generation < 0) {
    throw invalidHeadContentUri("generation");
  }
  if (typeof request.path !== "string" || !isContentPath(request.path)) {
    throw invalidHeadContentUri("path");
  }
  if (request.revision !== "head") {
    throw invalidHeadContentUri("revision");
  }
  if (!isRequestId(request.requestId)) {
    throw invalidHeadContentUri("requestId");
  }
}

function requireQueryString(query: URLSearchParams, field: string): string {
  const value = query.get(field);
  if (value === null || value.trim().length === 0) {
    throw invalidHeadContentUri(field);
  }
  return value;
}

function requireQueryInteger(query: URLSearchParams, field: string): number {
  const value = requireQueryString(query, field);
  if (!/^\d+$/u.test(value)) {
    throw invalidHeadContentUri(field);
  }
  const integer = Number(value);
  if (!Number.isSafeInteger(integer)) {
    throw invalidHeadContentUri(field);
  }
  return integer;
}

function isContentPath(path: string): boolean {
  if (path === "." || path.trim().length === 0) {
    return false;
  }
  if (path.startsWith("/") || path.includes(":") || path.includes("\\") || path.includes("\0")) {
    return false;
  }
  return path.split("/").every((part) => part.length > 0 && part !== "." && part !== "..");
}

function isRequestId(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u.test(value);
}

function invalidHeadContentUri(field: string): HeadContentUriError {
  return new HeadContentUriError("SUBVERSIONR_HEAD_CONTENT_URI_INVALID", field);
}
