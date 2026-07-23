import { Buffer } from "node:buffer";
import {
  validateAnonymousSvnRemoteOperationEnvelope,
  type RemoteOperationEnvelope,
} from "../security/remoteAccessProfile";
import type { JsonRpcRequestOptions, JsonRpcSender } from "../status/types";

declare const contentRevisionBrand: unique symbol;

export type ContentRevision = "base" | "head" | (string & { readonly [contentRevisionBrand]: true });
export type ContentErrorCategory = "input" | "protocol";

const MAX_SVN_REVNUM = 2_147_483_647;

interface ContentGetRequestBase {
  repositoryId: string;
  epoch: number;
  path: string;
}

export interface BaseContentGetRequest extends ContentGetRequestBase {
  revision: "base";
  remote?: never;
}

export interface RepositoryContentGetRequest extends ContentGetRequestBase {
  revision: string;
  remote?: RemoteOperationEnvelope;
}

export type ContentGetRequest = BaseContentGetRequest | RepositoryContentGetRequest;

export interface ValidatedBaseContentGetRequest extends ContentGetRequestBase {
  revision: "base";
}

export interface ValidatedRepositoryContentGetRequest extends ContentGetRequestBase {
  revision: Exclude<ContentRevision, "base">;
  remote?: RemoteOperationEnvelope;
}

export type ValidatedContentGetRequest =
  | ValidatedBaseContentGetRequest
  | ValidatedRepositoryContentGetRequest;

export type ContentClientOptions = JsonRpcRequestOptions;

export interface ContentRequestIdentity {
  repositoryId: string;
  epoch: number;
  path: string;
  revision: ContentRevision;
}

export interface ContentBlob {
  repositoryId: string;
  epoch: number;
  path: string;
  revision: ContentRevision;
  bytes: Uint8Array;
  byteLength: number;
  mimeType: string | null;
  isBinary: boolean;
  source: string;
}

export interface ContentClient {
  getContent(request: ContentGetRequest, options?: ContentClientOptions): Promise<ContentBlob>;
}

export class ContentResponseError extends Error {
  public constructor(
    public readonly code: string,
    public readonly category: ContentErrorCategory,
    public readonly messageKey: string,
    public readonly safeArgs: Record<string, unknown> = {},
  ) {
    super(code);
    this.name = "ContentResponseError";
  }
}

export class ContentGetRpcClient implements ContentClient {
  public constructor(private readonly sender: JsonRpcSender) {}

  public async getContent(request: ContentGetRequest, options?: ContentClientOptions): Promise<ContentBlob> {
    const validatedRequest = validateContentRequest(request);
    const rawResponse = options === undefined
      ? await this.sender.sendRequest<unknown>("content/get", validatedRequest)
      : await this.sender.sendRequest<unknown>("content/get", validatedRequest, options);
    const content = parseContentResponse(rawResponse);
    requireContentMatchesRequest(content, validatedRequest);
    return content;
  }
}

function validateContentRequest(request: ContentGetRequest): ValidatedContentGetRequest {
  if (!isRecord(request) || typeof request.repositoryId !== "string" || request.repositoryId.trim().length === 0) {
    throw invalidContentRequest("repositoryId");
  }
  if (typeof request.epoch !== "number" || !Number.isSafeInteger(request.epoch) || request.epoch < 0) {
    throw invalidContentRequest("epoch");
  }
  if (typeof request.path !== "string" || !isContentPath(request.path)) {
    throw invalidContentRequest("path");
  }
  if (!isContentRevision(request.revision)) {
    throw invalidContentRequest("revision");
  }
  const identity: ContentRequestIdentity = {
    repositoryId: request.repositoryId,
    epoch: request.epoch,
    path: request.path,
    revision: request.revision,
  };
  if (request.revision === "base") {
    requireExactRequestKeys(request, "request", ["repositoryId", "epoch", "path", "revision"]);
    return { ...identity, revision: "base" };
  }
  requireExactRequestKeys(request, "request", ["repositoryId", "epoch", "path", "revision"], ["remote"]);
  const remote = "remote" in request
    ? validateAnonymousSvnRemoteOperationEnvelope(request.remote)
    : undefined;
  return {
    ...identity,
    revision: request.revision,
    ...(remote === undefined ? {} : { remote }),
  };
}

function parseContentResponse(rawResponse: unknown): ContentBlob {
  const response = requireRecord(rawResponse, "result");
  requireExactKeys(response, "result", [
    "repositoryId",
    "epoch",
    "path",
    "revision",
    "contentBase64",
    "byteLength",
    "mimeType",
    "isBinary",
    "source",
  ]);
  const byteLength = requireSafeInteger(response.byteLength, "byteLength");
  const bytes = requireBase64Bytes(response.contentBase64, "contentBase64", byteLength);

  return {
    repositoryId: requireString(response.repositoryId, "repositoryId"),
    epoch: requireSafeInteger(response.epoch, "epoch"),
    path: requireContentPath(response.path, "path"),
    revision: requireRevision(response.revision, "revision"),
    bytes,
    byteLength,
    mimeType: requireNullableString(response.mimeType, "mimeType"),
    isBinary: requireBoolean(response.isBinary, "isBinary"),
    source: requireString(response.source, "source"),
  };
}

function requireContentMatchesRequest(content: ContentBlob, request: ContentRequestIdentity): void {
  if (content.repositoryId !== request.repositoryId) {
    throw invalidContentResponse("repositoryId");
  }
  if (content.epoch !== request.epoch) {
    throw invalidContentResponse("epoch");
  }
  if (content.path !== request.path) {
    throw invalidContentResponse("path");
  }
  if (content.revision !== request.revision) {
    throw invalidContentResponse("revision");
  }
  if (content.source !== expectedContentSource(request.revision)) {
    throw invalidContentResponse("source");
  }
}

function requireBase64Bytes(value: unknown, field: string, expectedByteLength: number): Uint8Array {
  if (typeof value !== "string") {
    throw invalidContentResponse(field);
  }
  const encoded = value;
  if (!isStandardBase64(encoded)) {
    throw invalidContentResponse(field);
  }
  const bytes = Buffer.from(encoded, "base64");
  if (bytes.length !== expectedByteLength) {
    throw invalidContentResponse(field);
  }
  return new Uint8Array(bytes);
}

function isStandardBase64(value: string): boolean {
  return /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function requireRecord(value: unknown, field: string): Record<string, unknown> {
  if (!isRecord(value)) {
    throw invalidContentResponse(field);
  }
  return value;
}

function requireExactKeys(value: Record<string, unknown>, field: string, expectedKeys: readonly string[]): void {
  const expected = new Set(expectedKeys);
  for (const key of expected) {
    if (!(key in value)) {
      throw invalidContentResponse(key);
    }
  }
  for (const key of Object.keys(value)) {
    if (!expected.has(key)) {
      throw invalidContentResponse(field === "result" ? key : `${field}.${key}`);
    }
  }
}

function requireExactRequestKeys(
  value: Record<string, unknown>,
  field: string,
  expectedKeys: readonly string[],
  optionalKeys: readonly string[] = [],
): void {
  const expected = new Set(expectedKeys);
  const allowed = new Set([...expectedKeys, ...optionalKeys]);
  for (const key of expected) {
    if (!(key in value)) {
      throw invalidContentRequest(key);
    }
  }
  for (const key of Object.keys(value)) {
    if (!allowed.has(key)) {
      throw invalidContentRequest(field === "request" ? key : `${field}.${key}`);
    }
  }
}

function requireString(value: unknown, field: string): string {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw invalidContentResponse(field);
  }
  return value;
}

function requireNullableString(value: unknown, field: string): string | null {
  if (value === null) {
    return null;
  }
  if (typeof value !== "string" || value.trim().length === 0) {
    throw invalidContentResponse(field);
  }
  return value;
}

function requireSafeInteger(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
    throw invalidContentResponse(field);
  }
  return value;
}

function requireBoolean(value: unknown, field: string): boolean {
  if (typeof value !== "boolean") {
    throw invalidContentResponse(field);
  }
  return value;
}

function requireRevision(value: unknown, field: string): ContentRevision {
  const revision = requireString(value, field);
  if (!isContentRevision(revision)) {
    throw invalidContentResponse(field);
  }
  return revision;
}

function isContentRevision(revision: string): revision is ContentRevision {
  if (revision === "base" || revision === "head") {
    return true;
  }
  const match = /^r(0|[1-9]\d*)$/u.exec(revision);
  if (match === null) {
    return false;
  }
  return Number(match[1]) <= MAX_SVN_REVNUM;
}

function expectedContentSource(revision: ContentRevision): string {
  if (revision === "base") {
    return "libsvn-base";
  }
  if (revision === "head") {
    return "libsvn-head";
  }
  return "libsvn-revision";
}

function requireContentPath(value: unknown, field: string): string {
  const path = requireString(value, field);
  if (!isContentPath(path)) {
    throw invalidContentResponse(field);
  }
  return path;
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

function invalidContentRequest(field: string): ContentResponseError {
  return new ContentResponseError(
    "SUBVERSIONR_CONTENT_REQUEST_INVALID",
    "input",
    "error.content.requestInvalid",
    { field },
  );
}

function invalidContentResponse(field: string): ContentResponseError {
  return new ContentResponseError(
    "SUBVERSIONR_CONTENT_RESPONSE_INVALID",
    "protocol",
    "error.content.responseInvalid",
    { field },
  );
}
