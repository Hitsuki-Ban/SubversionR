export const REVISION_CONTENT_URI_SCHEME = "svn-r-revision";

export interface RevisionContentUriRequest {
  repositoryId: string;
  epoch: number;
  path: string;
  revision: string;
}

export interface RevisionContentUriComponents {
  scheme: string;
  authority: string;
  path: string;
  query: string;
}

export class RevisionContentUriError extends Error {
  public constructor(
    public readonly code: string,
    public readonly field: string,
  ) {
    super(code);
    this.name = "RevisionContentUriError";
  }
}

export function createRevisionContentUriComponents(
  request: RevisionContentUriRequest,
): RevisionContentUriComponents {
  validateRevisionContentUriRequest(request);
  const query = new URLSearchParams();
  query.set("repositoryId", request.repositoryId);
  query.set("epoch", String(request.epoch));
  query.set("path", request.path);
  query.set("revision", request.revision);
  return {
    scheme: REVISION_CONTENT_URI_SCHEME,
    authority: "revision",
    path: "/",
    query: query.toString(),
  };
}

export function parseRevisionContentUri(uri: RevisionContentUriComponents): RevisionContentUriRequest {
  if (uri.scheme !== REVISION_CONTENT_URI_SCHEME) {
    throw invalidRevisionContentUri("scheme");
  }
  if (uri.authority !== "revision") {
    throw invalidRevisionContentUri("authority");
  }
  if (uri.path !== "/") {
    throw invalidRevisionContentUri("path");
  }
  const query = new URLSearchParams(uri.query);
  requireExactQueryKeys(query, ["repositoryId", "epoch", "path", "revision"]);
  const request = {
    repositoryId: requireQueryString(query, "repositoryId"),
    epoch: requireQueryInteger(query, "epoch"),
    path: requireQueryString(query, "path"),
    revision: requireQueryString(query, "revision"),
  };
  validateRevisionContentUriRequest(request);
  return request;
}

function requireExactQueryKeys(query: URLSearchParams, expectedKeys: readonly string[]): void {
  const expected = new Set(expectedKeys);
  const seen = new Map<string, number>();
  for (const key of query.keys()) {
    if (!expected.has(key)) {
      throw invalidRevisionContentUri(key);
    }
    seen.set(key, (seen.get(key) ?? 0) + 1);
  }
  for (const key of expectedKeys) {
    if (seen.get(key) !== 1) {
      throw invalidRevisionContentUri(key);
    }
  }
}

function validateRevisionContentUriRequest(request: {
  repositoryId: string;
  epoch: number;
  path: string;
  revision: string;
}): void {
  if (typeof request.repositoryId !== "string" || request.repositoryId.trim().length === 0) {
    throw invalidRevisionContentUri("repositoryId");
  }
  if (!Number.isSafeInteger(request.epoch) || request.epoch < 0) {
    throw invalidRevisionContentUri("epoch");
  }
  if (typeof request.path !== "string" || !isContentPath(request.path)) {
    throw invalidRevisionContentUri("path");
  }
  if (!isExplicitRevision(request.revision)) {
    throw invalidRevisionContentUri("revision");
  }
}

function requireQueryString(query: URLSearchParams, field: string): string {
  const value = query.get(field);
  if (value === null || value.trim().length === 0) {
    throw invalidRevisionContentUri(field);
  }
  return value;
}

function requireQueryInteger(query: URLSearchParams, field: string): number {
  const value = requireQueryString(query, field);
  if (!/^\d+$/.test(value)) {
    throw invalidRevisionContentUri(field);
  }
  const integer = Number(value);
  if (!Number.isSafeInteger(integer)) {
    throw invalidRevisionContentUri(field);
  }
  return integer;
}

function isExplicitRevision(revision: string): boolean {
  const match = /^r(0|[1-9]\d*)$/u.exec(revision);
  if (match === null) {
    return false;
  }
  return Number(match[1]) <= 2_147_483_647;
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

function invalidRevisionContentUri(field: string): RevisionContentUriError {
  return new RevisionContentUriError("SUBVERSIONR_REVISION_CONTENT_URI_INVALID", field);
}
