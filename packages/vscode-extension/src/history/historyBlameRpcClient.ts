import { Buffer } from "node:buffer";
import type { JsonRpcSender } from "../status/types";

declare const blameRevisionBrand: unique symbol;
declare const blameNumberedRevisionBrand: unique symbol;

export type HistoryBlamePegOrEndRevision =
  | "base"
  | "head"
  | (string & { readonly [blameRevisionBrand]: true });
export type HistoryBlameNumberedRevision = string & {
  readonly [blameNumberedRevisionBrand]: true;
};
export type HistoryBlameIgnoreWhitespace = "none" | "change" | "all";
export type HistoryBlameErrorCategory = "input" | "protocol";

const MAX_SVN_REVNUM = 2_147_483_647;
const MAX_BLAME_LINE_LIMIT = 5_000;

export interface HistoryBlameRequest {
  repositoryId: string;
  epoch: number;
  path: string;
  pegRevision: string;
  startRevision: string;
  endRevision: string;
  lineStart: number;
  lineLimit: number;
  ignoreWhitespace: string;
  ignoreEolStyle: boolean;
  ignoreMimeType: boolean;
  includeMergedRevisions: boolean;
}

export interface ValidatedHistoryBlameRequest {
  repositoryId: string;
  epoch: number;
  path: string;
  pegRevision: HistoryBlamePegOrEndRevision;
  startRevision: HistoryBlameNumberedRevision;
  endRevision: HistoryBlamePegOrEndRevision;
  lineStart: number;
  lineLimit: number;
  ignoreWhitespace: HistoryBlameIgnoreWhitespace;
  ignoreEolStyle: boolean;
  ignoreMimeType: boolean;
  includeMergedRevisions: boolean;
}

export interface HistoryBlameLine {
  lineNumber: number;
  revision: number | null;
  author: string | null;
  date: string | null;
  mergedRevision: number | null;
  mergedAuthor: string | null;
  mergedDate: string | null;
  mergedPath: string | null;
  lineBase64: string;
  byteLength: number;
  localChange: boolean;
}

export interface HistoryBlame {
  repositoryId: string;
  epoch: number;
  path: string;
  pegRevision: HistoryBlamePegOrEndRevision;
  startRevision: HistoryBlameNumberedRevision;
  endRevision: HistoryBlamePegOrEndRevision;
  resolvedStartRevision: number;
  resolvedEndRevision: number;
  lineStart: number;
  lineLimit: number;
  ignoreWhitespace: HistoryBlameIgnoreWhitespace;
  ignoreEolStyle: boolean;
  ignoreMimeType: boolean;
  includeMergedRevisions: boolean;
  hasMore: boolean;
  lines: HistoryBlameLine[];
  source: string;
}

export interface HistoryBlameClient {
  getBlame(request: HistoryBlameRequest): Promise<HistoryBlame>;
}

export class HistoryBlameResponseError extends Error {
  public constructor(
    public readonly code: string,
    public readonly category: HistoryBlameErrorCategory,
    public readonly messageKey: string,
    public readonly safeArgs: Record<string, unknown> = {},
  ) {
    super(code);
    this.name = "HistoryBlameResponseError";
  }
}

export class HistoryBlameRpcClient implements HistoryBlameClient {
  public constructor(private readonly sender: JsonRpcSender) {}

  public async getBlame(request: HistoryBlameRequest): Promise<HistoryBlame> {
    const validatedRequest = validateHistoryBlameRequest(request);
    const rawResponse = await this.sender.sendRequest<unknown>("history/blame", validatedRequest);
    const blame = parseHistoryBlameResponse(rawResponse);
    requireHistoryBlameMatchesRequest(blame, validatedRequest);
    return blame;
  }
}

function validateHistoryBlameRequest(request: HistoryBlameRequest): ValidatedHistoryBlameRequest {
  if (!isRecord(request)) {
    throw invalidBlameRequest("request");
  }
  requireExactRequestKeys(request, "request", [
    "repositoryId",
    "epoch",
    "path",
    "pegRevision",
    "startRevision",
    "endRevision",
    "lineStart",
    "lineLimit",
    "ignoreWhitespace",
    "ignoreEolStyle",
    "ignoreMimeType",
    "includeMergedRevisions",
  ]);
  if (typeof request.repositoryId !== "string" || request.repositoryId.trim().length === 0) {
    throw invalidBlameRequest("repositoryId");
  }
  if (typeof request.epoch !== "number" || !Number.isSafeInteger(request.epoch) || request.epoch < 0) {
    throw invalidBlameRequest("epoch");
  }
  if (typeof request.path !== "string" || !isBlamePath(request.path)) {
    throw invalidBlameRequest("path");
  }
  if (!isBlamePegOrEndRevision(request.pegRevision)) {
    throw invalidBlameRequest("pegRevision");
  }
  if (!isBlameNumberedRevision(request.startRevision)) {
    throw invalidBlameRequest("startRevision");
  }
  if (!isBlamePegOrEndRevision(request.endRevision)) {
    throw invalidBlameRequest("endRevision");
  }
  if (
    typeof request.lineStart !== "number" ||
    !Number.isSafeInteger(request.lineStart) ||
    request.lineStart < 1 ||
    request.lineStart > Number.MAX_SAFE_INTEGER - MAX_BLAME_LINE_LIMIT
  ) {
    throw invalidBlameRequest("lineStart");
  }
  if (
    typeof request.lineLimit !== "number" ||
    !Number.isSafeInteger(request.lineLimit) ||
    request.lineLimit < 1 ||
    request.lineLimit > MAX_BLAME_LINE_LIMIT
  ) {
    throw invalidBlameRequest("lineLimit");
  }
  if (!isIgnoreWhitespace(request.ignoreWhitespace)) {
    throw invalidBlameRequest("ignoreWhitespace");
  }
  if (typeof request.ignoreEolStyle !== "boolean") {
    throw invalidBlameRequest("ignoreEolStyle");
  }
  if (typeof request.ignoreMimeType !== "boolean") {
    throw invalidBlameRequest("ignoreMimeType");
  }
  if (typeof request.includeMergedRevisions !== "boolean") {
    throw invalidBlameRequest("includeMergedRevisions");
  }

  return {
    repositoryId: request.repositoryId,
    epoch: request.epoch,
    path: request.path,
    pegRevision: request.pegRevision,
    startRevision: request.startRevision,
    endRevision: request.endRevision,
    lineStart: request.lineStart,
    lineLimit: request.lineLimit,
    ignoreWhitespace: request.ignoreWhitespace,
    ignoreEolStyle: request.ignoreEolStyle,
    ignoreMimeType: request.ignoreMimeType,
    includeMergedRevisions: request.includeMergedRevisions,
  };
}

function parseHistoryBlameResponse(rawResponse: unknown): HistoryBlame {
  const response = requireRecord(rawResponse, "result");
  requireExactKeys(response, "result", [
    "repositoryId",
    "epoch",
    "path",
    "pegRevision",
    "startRevision",
    "endRevision",
    "resolvedStartRevision",
    "resolvedEndRevision",
    "lineStart",
    "lineLimit",
    "ignoreWhitespace",
    "ignoreEolStyle",
    "ignoreMimeType",
    "includeMergedRevisions",
    "hasMore",
    "lines",
    "source",
  ]);

  return {
    repositoryId: requireNonEmptyString(response.repositoryId, "repositoryId"),
    epoch: requireSafeInteger(response.epoch, "epoch"),
    path: requireBlamePath(response.path, "path"),
    pegRevision: requireBlamePegOrEndRevision(response.pegRevision, "pegRevision"),
    startRevision: requireBlameNumberedRevision(response.startRevision, "startRevision"),
    endRevision: requireBlamePegOrEndRevision(response.endRevision, "endRevision"),
    resolvedStartRevision: requireSvnRevisionNumber(response.resolvedStartRevision, "resolvedStartRevision"),
    resolvedEndRevision: requireSvnRevisionNumber(response.resolvedEndRevision, "resolvedEndRevision"),
    lineStart: requireLineStart(response.lineStart, "lineStart"),
    lineLimit: requireLineLimit(response.lineLimit, "lineLimit"),
    ignoreWhitespace: requireIgnoreWhitespace(response.ignoreWhitespace, "ignoreWhitespace"),
    ignoreEolStyle: requireBoolean(response.ignoreEolStyle, "ignoreEolStyle"),
    ignoreMimeType: requireBoolean(response.ignoreMimeType, "ignoreMimeType"),
    includeMergedRevisions: requireBoolean(response.includeMergedRevisions, "includeMergedRevisions"),
    hasMore: requireBoolean(response.hasMore, "hasMore"),
    lines: requireBlameLines(response.lines, "lines"),
    source: requireNonEmptyString(response.source, "source"),
  };
}

function requireHistoryBlameMatchesRequest(
  blame: HistoryBlame,
  request: ValidatedHistoryBlameRequest,
): void {
  if (blame.repositoryId !== request.repositoryId) {
    throw invalidBlameResponse("repositoryId");
  }
  if (blame.epoch !== request.epoch) {
    throw invalidBlameResponse("epoch");
  }
  if (blame.path !== request.path) {
    throw invalidBlameResponse("path");
  }
  if (blame.pegRevision !== request.pegRevision) {
    throw invalidBlameResponse("pegRevision");
  }
  if (blame.startRevision !== request.startRevision) {
    throw invalidBlameResponse("startRevision");
  }
  if (blame.endRevision !== request.endRevision) {
    throw invalidBlameResponse("endRevision");
  }
  if (blame.lineStart !== request.lineStart) {
    throw invalidBlameResponse("lineStart");
  }
  if (blame.lineLimit !== request.lineLimit) {
    throw invalidBlameResponse("lineLimit");
  }
  if (blame.ignoreWhitespace !== request.ignoreWhitespace) {
    throw invalidBlameResponse("ignoreWhitespace");
  }
  if (blame.ignoreEolStyle !== request.ignoreEolStyle) {
    throw invalidBlameResponse("ignoreEolStyle");
  }
  if (blame.ignoreMimeType !== request.ignoreMimeType) {
    throw invalidBlameResponse("ignoreMimeType");
  }
  if (blame.includeMergedRevisions !== request.includeMergedRevisions) {
    throw invalidBlameResponse("includeMergedRevisions");
  }
  if (blame.source !== "libsvn-blame") {
    throw invalidBlameResponse("source");
  }
  requireLineWindow(blame);
}

function requireLineWindow(blame: HistoryBlame): void {
  if (blame.lines.length > blame.lineLimit) {
    throw invalidBlameResponse("lines");
  }

  let expectedLine = blame.lineStart;
  for (const line of blame.lines) {
    if (line.lineNumber !== expectedLine || line.lineNumber >= blame.lineStart + blame.lineLimit) {
      throw invalidBlameResponse("lines.lineNumber");
    }
    expectedLine += 1;
  }
}

function requireBlameLines(value: unknown, field: string): HistoryBlameLine[] {
  if (!Array.isArray(value)) {
    throw invalidBlameResponse(field);
  }
  return value.map((line, index) => parseBlameLine(line, `${field}.${index}`));
}

function parseBlameLine(value: unknown, field: string): HistoryBlameLine {
  const line = requireRecord(value, field);
  requireExactKeys(line, field, [
    "lineNumber",
    "revision",
    "author",
    "date",
    "mergedRevision",
    "mergedAuthor",
    "mergedDate",
    "mergedPath",
    "lineBase64",
    "byteLength",
    "localChange",
  ]);

  const lineBase64 = requireBase64(line.lineBase64, `${field}.lineBase64`);
  const byteLength = requireSafeInteger(line.byteLength, `${field}.byteLength`);
  if (byteLength !== Buffer.from(lineBase64, "base64").byteLength) {
    throw invalidBlameResponse(`${field}.byteLength`);
  }

  return {
    lineNumber: requirePositiveSafeInteger(line.lineNumber, `${field}.lineNumber`),
    revision: requireNullableRevisionNumber(line.revision, `${field}.revision`),
    author: requireNullableString(line.author, `${field}.author`),
    date: requireNullableString(line.date, `${field}.date`),
    mergedRevision: requireNullableRevisionNumber(line.mergedRevision, `${field}.mergedRevision`),
    mergedAuthor: requireNullableString(line.mergedAuthor, `${field}.mergedAuthor`),
    mergedDate: requireNullableString(line.mergedDate, `${field}.mergedDate`),
    mergedPath: requireNullableRepositoryPath(line.mergedPath, `${field}.mergedPath`),
    lineBase64,
    byteLength,
    localChange: requireBoolean(line.localChange, `${field}.localChange`),
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function requireRecord(value: unknown, field: string): Record<string, unknown> {
  if (!isRecord(value)) {
    throw invalidBlameResponse(field);
  }
  return value;
}

function requireExactKeys(value: Record<string, unknown>, field: string, expectedKeys: readonly string[]): void {
  const expected = new Set(expectedKeys);
  for (const key of Object.keys(value)) {
    if (!expected.has(key)) {
      throw invalidBlameResponse(field === "result" ? key : `${field}.${key}`);
    }
  }
}

function requireExactRequestKeys(
  value: Record<string, unknown>,
  field: string,
  expectedKeys: readonly string[],
): void {
  const expected = new Set(expectedKeys);
  for (const key of Object.keys(value)) {
    if (!expected.has(key)) {
      throw invalidBlameRequest(field === "request" ? key : `${field}.${key}`);
    }
  }
}

function requireNonEmptyString(value: unknown, field: string): string {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw invalidBlameResponse(field);
  }
  return value;
}

function requireNullableString(value: unknown, field: string): string | null {
  if (value === null) {
    return null;
  }
  if (typeof value !== "string") {
    throw invalidBlameResponse(field);
  }
  return value;
}

function requireSafeInteger(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
    throw invalidBlameResponse(field);
  }
  return value;
}

function requirePositiveSafeInteger(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 1) {
    throw invalidBlameResponse(field);
  }
  return value;
}

function requireSvnRevisionNumber(value: unknown, field: string): number {
  const revision = requireSafeInteger(value, field);
  if (revision > MAX_SVN_REVNUM) {
    throw invalidBlameResponse(field);
  }
  return revision;
}

function requireNullableRevisionNumber(value: unknown, field: string): number | null {
  if (value === null) {
    return null;
  }
  return requireSvnRevisionNumber(value, field);
}

function requireBoolean(value: unknown, field: string): boolean {
  if (typeof value !== "boolean") {
    throw invalidBlameResponse(field);
  }
  return value;
}

function requireBlamePath(value: unknown, field: string): string {
  const path = requireNonEmptyString(value, field);
  if (!isBlamePath(path)) {
    throw invalidBlameResponse(field);
  }
  return path;
}

function requireBlamePegOrEndRevision(value: unknown, field: string): HistoryBlamePegOrEndRevision {
  const revision = requireNonEmptyString(value, field);
  if (!isBlamePegOrEndRevision(revision)) {
    throw invalidBlameResponse(field);
  }
  return revision;
}

function requireBlameNumberedRevision(value: unknown, field: string): HistoryBlameNumberedRevision {
  const revision = requireNonEmptyString(value, field);
  if (!isBlameNumberedRevision(revision)) {
    throw invalidBlameResponse(field);
  }
  return revision;
}

function requireLineStart(value: unknown, field: string): number {
  const lineStart = requirePositiveSafeInteger(value, field);
  if (lineStart > Number.MAX_SAFE_INTEGER - MAX_BLAME_LINE_LIMIT) {
    throw invalidBlameResponse(field);
  }
  return lineStart;
}

function requireLineLimit(value: unknown, field: string): number {
  const lineLimit = requirePositiveSafeInteger(value, field);
  if (lineLimit > MAX_BLAME_LINE_LIMIT) {
    throw invalidBlameResponse(field);
  }
  return lineLimit;
}

function requireIgnoreWhitespace(value: unknown, field: string): HistoryBlameIgnoreWhitespace {
  if (!isIgnoreWhitespace(value)) {
    throw invalidBlameResponse(field);
  }
  return value;
}

function requireBase64(value: unknown, field: string): string {
  if (typeof value !== "string" || !isCanonicalBase64(value)) {
    throw invalidBlameResponse(field);
  }
  return value;
}

function requireNullableRepositoryPath(value: unknown, field: string): string | null {
  if (value === null) {
    return null;
  }
  const path = requireNonEmptyString(value, field);
  if (!isRepositoryPath(path)) {
    throw invalidBlameResponse(field);
  }
  return path;
}

function isBlamePath(path: string): boolean {
  if (path === "." || path.trim().length === 0) {
    return false;
  }
  if (path.startsWith("/") || path.includes(":") || path.includes("\\") || path.includes("\0")) {
    return false;
  }
  return path.split("/").every((part) => part.length > 0 && part !== "." && part !== "..");
}

function isRepositoryPath(path: string): boolean {
  if (!path.startsWith("/") || path.includes("\\") || path.includes("\0")) {
    return false;
  }
  const parts = path.split("/");
  if (parts.length < 2 || parts[0] !== "") {
    return false;
  }
  return parts.slice(1).every((part) => part.length > 0 && part !== "." && part !== "..");
}

function isBlamePegOrEndRevision(revision: string): revision is HistoryBlamePegOrEndRevision {
  return revision === "base" || revision === "head" || isBlameNumberedRevision(revision);
}

function isBlameNumberedRevision(revision: string): revision is HistoryBlameNumberedRevision {
  const match = /^r(0|[1-9]\d*)$/u.exec(revision);
  if (match === null) {
    return false;
  }
  return Number(match[1]) <= MAX_SVN_REVNUM;
}

function isIgnoreWhitespace(value: unknown): value is HistoryBlameIgnoreWhitespace {
  return value === "none" || value === "change" || value === "all";
}

function isCanonicalBase64(value: string): boolean {
  return /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/u.test(value);
}

function invalidBlameRequest(field: string): HistoryBlameResponseError {
  return new HistoryBlameResponseError(
    "SUBVERSIONR_HISTORY_BLAME_REQUEST_INVALID",
    "input",
    "error.history.blameRequestInvalid",
    { field },
  );
}

function invalidBlameResponse(field: string): HistoryBlameResponseError {
  return new HistoryBlameResponseError(
    "SUBVERSIONR_HISTORY_BLAME_RESPONSE_INVALID",
    "protocol",
    "error.history.blameResponseInvalid",
    { field },
  );
}
