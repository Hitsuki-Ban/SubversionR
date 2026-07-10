import type { JsonRpcSender } from "../status/types";

declare const historyRevisionBrand: unique symbol;
declare const historyNumberedRevisionBrand: unique symbol;

export type HistoryStartRevision =
  | "head"
  | (string & { readonly [historyRevisionBrand]: true });
export type HistoryNumberedRevision = string & {
  readonly [historyNumberedRevisionBrand]: true;
};
export type HistoryErrorCategory = "input" | "protocol";
export type HistoryTristate = "true" | "false" | "unknown";

const MAX_SVN_REVNUM = 2_147_483_647;
const MAX_HISTORY_LIMIT = 500;

export interface HistoryLogRequest {
  repositoryId: string;
  epoch: number;
  path: string;
  startRevision: string;
  endRevision: string;
  limit: number;
  discoverChangedPaths: boolean;
  strictNodeHistory: boolean;
  includeMergedRevisions: boolean;
}

export interface ValidatedHistoryLogRequest {
  repositoryId: string;
  epoch: number;
  path: string;
  startRevision: HistoryStartRevision;
  endRevision: HistoryNumberedRevision;
  limit: number;
  discoverChangedPaths: boolean;
  strictNodeHistory: boolean;
  includeMergedRevisions: boolean;
}

export interface HistoryChangedPath {
  path: string;
  action: string;
  copyFromPath: string | null;
  copyFromRevision: number | null;
  nodeKind: string;
  textModified: HistoryTristate;
  propertiesModified: HistoryTristate;
}

export interface HistoryLogEntry {
  revision: number;
  author: string | null;
  date: string | null;
  message: string | null;
  changedPaths: HistoryChangedPath[];
  hasChildren: boolean;
  nonInheritable: boolean;
  subtractiveMerge: boolean;
}

export interface HistoryLog {
  repositoryId: string;
  epoch: number;
  path: string;
  startRevision: HistoryStartRevision;
  endRevision: HistoryNumberedRevision;
  limit: number;
  entries: HistoryLogEntry[];
  source: string;
}

export interface HistoryClient {
  getLog(request: HistoryLogRequest): Promise<HistoryLog>;
}

export class HistoryLogResponseError extends Error {
  public constructor(
    public readonly code: string,
    public readonly category: HistoryErrorCategory,
    public readonly messageKey: string,
    public readonly safeArgs: Record<string, unknown> = {},
  ) {
    super(code);
    this.name = "HistoryLogResponseError";
  }
}

export class HistoryLogRpcClient implements HistoryClient {
  public constructor(private readonly sender: JsonRpcSender) {}

  public async getLog(request: HistoryLogRequest): Promise<HistoryLog> {
    const validatedRequest = validateHistoryLogRequest(request);
    const rawResponse = await this.sender.sendRequest<unknown>("history/log", validatedRequest);
    const log = parseHistoryLogResponse(rawResponse);
    requireHistoryLogMatchesRequest(log, validatedRequest);
    return log;
  }
}

function validateHistoryLogRequest(request: HistoryLogRequest): ValidatedHistoryLogRequest {
  if (!isRecord(request)) {
    throw invalidHistoryRequest("request");
  }
  requireExactRequestKeys(request, "request", [
    "repositoryId",
    "epoch",
    "path",
    "startRevision",
    "endRevision",
    "limit",
    "discoverChangedPaths",
    "strictNodeHistory",
    "includeMergedRevisions",
  ]);
  if (typeof request.repositoryId !== "string" || request.repositoryId.trim().length === 0) {
    throw invalidHistoryRequest("repositoryId");
  }
  if (typeof request.epoch !== "number" || !Number.isSafeInteger(request.epoch) || request.epoch < 0) {
    throw invalidHistoryRequest("epoch");
  }
  if (typeof request.path !== "string" || !isHistoryPath(request.path)) {
    throw invalidHistoryRequest("path");
  }
  if (!isHistoryStartRevision(request.startRevision)) {
    throw invalidHistoryRequest("startRevision");
  }
  if (!isHistoryNumberedRevision(request.endRevision)) {
    throw invalidHistoryRequest("endRevision");
  }
  if (
    typeof request.limit !== "number" ||
    !Number.isSafeInteger(request.limit) ||
    request.limit < 1 ||
    request.limit > MAX_HISTORY_LIMIT
  ) {
    throw invalidHistoryRequest("limit");
  }
  if (typeof request.discoverChangedPaths !== "boolean") {
    throw invalidHistoryRequest("discoverChangedPaths");
  }
  if (typeof request.strictNodeHistory !== "boolean") {
    throw invalidHistoryRequest("strictNodeHistory");
  }
  if (typeof request.includeMergedRevisions !== "boolean") {
    throw invalidHistoryRequest("includeMergedRevisions");
  }

  return {
    repositoryId: request.repositoryId,
    epoch: request.epoch,
    path: request.path,
    startRevision: request.startRevision,
    endRevision: request.endRevision,
    limit: request.limit,
    discoverChangedPaths: request.discoverChangedPaths,
    strictNodeHistory: request.strictNodeHistory,
    includeMergedRevisions: request.includeMergedRevisions,
  };
}

function parseHistoryLogResponse(rawResponse: unknown): HistoryLog {
  const response = requireRecord(rawResponse, "result");
  requireExactKeys(response, "result", [
    "repositoryId",
    "epoch",
    "path",
    "startRevision",
    "endRevision",
    "limit",
    "entries",
    "source",
  ]);

  return {
    repositoryId: requireNonEmptyString(response.repositoryId, "repositoryId"),
    epoch: requireSafeInteger(response.epoch, "epoch"),
    path: requireHistoryPath(response.path, "path"),
    startRevision: requireHistoryStartRevision(response.startRevision, "startRevision"),
    endRevision: requireHistoryNumberedRevision(response.endRevision, "endRevision"),
    limit: requireHistoryLimit(response.limit, "limit"),
    entries: requireHistoryEntries(response.entries, "entries"),
    source: requireNonEmptyString(response.source, "source"),
  };
}

function requireHistoryLogMatchesRequest(log: HistoryLog, request: ValidatedHistoryLogRequest): void {
  if (log.repositoryId !== request.repositoryId) {
    throw invalidHistoryResponse("repositoryId");
  }
  if (log.epoch !== request.epoch) {
    throw invalidHistoryResponse("epoch");
  }
  if (log.path !== request.path) {
    throw invalidHistoryResponse("path");
  }
  if (log.startRevision !== request.startRevision) {
    throw invalidHistoryResponse("startRevision");
  }
  if (log.endRevision !== request.endRevision) {
    throw invalidHistoryResponse("endRevision");
  }
  if (log.limit !== request.limit) {
    throw invalidHistoryResponse("limit");
  }
  if (log.source !== "libsvn-log") {
    throw invalidHistoryResponse("source");
  }
}

function requireHistoryEntries(value: unknown, field: string): HistoryLogEntry[] {
  if (!Array.isArray(value)) {
    throw invalidHistoryResponse(field);
  }
  return value.map((entry, index) => parseHistoryEntry(entry, `${field}.${index}`));
}

function parseHistoryEntry(value: unknown, field: string): HistoryLogEntry {
  const entry = requireRecord(value, field);
  requireExactKeys(entry, field, [
    "revision",
    "author",
    "date",
    "message",
    "changedPaths",
    "hasChildren",
    "nonInheritable",
    "subtractiveMerge",
  ]);

  return {
    revision: requireSvnRevisionNumber(entry.revision, `${field}.revision`),
    author: requireNullableString(entry.author, `${field}.author`),
    date: requireNullableString(entry.date, `${field}.date`),
    message: requireNullableString(entry.message, `${field}.message`),
    changedPaths: requireHistoryChangedPaths(entry.changedPaths, `${field}.changedPaths`),
    hasChildren: requireBoolean(entry.hasChildren, `${field}.hasChildren`),
    nonInheritable: requireBoolean(entry.nonInheritable, `${field}.nonInheritable`),
    subtractiveMerge: requireBoolean(entry.subtractiveMerge, `${field}.subtractiveMerge`),
  };
}

function requireHistoryChangedPaths(value: unknown, field: string): HistoryChangedPath[] {
  if (!Array.isArray(value)) {
    throw invalidHistoryResponse(field);
  }
  return value.map((changedPath, index) => parseHistoryChangedPath(changedPath, `${field}.${index}`));
}

function parseHistoryChangedPath(value: unknown, field: string): HistoryChangedPath {
  const changedPath = requireRecord(value, field);
  requireExactKeys(changedPath, field, [
    "path",
    "action",
    "copyFromPath",
    "copyFromRevision",
    "nodeKind",
    "textModified",
    "propertiesModified",
  ]);
  const copyFromPath = requireNullableChangedPath(changedPath.copyFromPath, `${field}.copyFromPath`);
  const copyFromRevision = requireNullableRevisionNumber(
    changedPath.copyFromRevision,
    `${field}.copyFromRevision`,
  );
  if ((copyFromPath === null) !== (copyFromRevision === null)) {
    throw invalidHistoryResponse(`${field}.copyFromPath`);
  }

  return {
    path: requireChangedPath(changedPath.path, `${field}.path`),
    action: requireChangedAction(changedPath.action, `${field}.action`),
    copyFromPath,
    copyFromRevision,
    nodeKind: requireNodeKind(changedPath.nodeKind, `${field}.nodeKind`),
    textModified: requireTristate(changedPath.textModified, `${field}.textModified`),
    propertiesModified: requireTristate(changedPath.propertiesModified, `${field}.propertiesModified`),
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function requireRecord(value: unknown, field: string): Record<string, unknown> {
  if (!isRecord(value)) {
    throw invalidHistoryResponse(field);
  }
  return value;
}

function requireExactKeys(value: Record<string, unknown>, field: string, expectedKeys: readonly string[]): void {
  const expected = new Set(expectedKeys);
  for (const key of Object.keys(value)) {
    if (!expected.has(key)) {
      throw invalidHistoryResponse(field === "result" ? key : `${field}.${key}`);
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
      throw invalidHistoryRequest(field === "request" ? key : `${field}.${key}`);
    }
  }
}

function requireNonEmptyString(value: unknown, field: string): string {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw invalidHistoryResponse(field);
  }
  return value;
}

function requireNullableString(value: unknown, field: string): string | null {
  if (value === null) {
    return null;
  }
  if (typeof value !== "string") {
    throw invalidHistoryResponse(field);
  }
  return value;
}

function requireSafeInteger(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
    throw invalidHistoryResponse(field);
  }
  return value;
}

function requireSvnRevisionNumber(value: unknown, field: string): number {
  const revision = requireSafeInteger(value, field);
  if (revision > MAX_SVN_REVNUM) {
    throw invalidHistoryResponse(field);
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
    throw invalidHistoryResponse(field);
  }
  return value;
}

function requireHistoryPath(value: unknown, field: string): string {
  const path = requireNonEmptyString(value, field);
  if (!isHistoryPath(path)) {
    throw invalidHistoryResponse(field);
  }
  return path;
}

function requireHistoryStartRevision(value: unknown, field: string): HistoryStartRevision {
  const revision = requireNonEmptyString(value, field);
  if (!isHistoryStartRevision(revision)) {
    throw invalidHistoryResponse(field);
  }
  return revision;
}

function requireHistoryNumberedRevision(value: unknown, field: string): HistoryNumberedRevision {
  const revision = requireNonEmptyString(value, field);
  if (!isHistoryNumberedRevision(revision)) {
    throw invalidHistoryResponse(field);
  }
  return revision;
}

function requireHistoryLimit(value: unknown, field: string): number {
  const limit = requireSafeInteger(value, field);
  if (limit < 1 || limit > MAX_HISTORY_LIMIT) {
    throw invalidHistoryResponse(field);
  }
  return limit;
}

function requireChangedPath(value: unknown, field: string): string {
  const path = requireNonEmptyString(value, field);
  if (!isRepositoryChangedPath(path)) {
    throw invalidHistoryResponse(field);
  }
  return path;
}

function requireNullableChangedPath(value: unknown, field: string): string | null {
  if (value === null) {
    return null;
  }
  return requireChangedPath(value, field);
}

function requireChangedAction(value: unknown, field: string): string {
  const action = requireNonEmptyString(value, field);
  if (!/^[A-Z]$/u.test(action)) {
    throw invalidHistoryResponse(field);
  }
  return action;
}

function requireNodeKind(value: unknown, field: string): string {
  const kind = requireNonEmptyString(value, field);
  if (!["none", "file", "dir", "unknown"].includes(kind)) {
    throw invalidHistoryResponse(field);
  }
  return kind;
}

function requireTristate(value: unknown, field: string): HistoryTristate {
  if (value !== "true" && value !== "false" && value !== "unknown") {
    throw invalidHistoryResponse(field);
  }
  return value;
}

function isHistoryPath(path: string): boolean {
  if (path === ".") {
    return true;
  }
  if (path.trim().length === 0) {
    return false;
  }
  if (path.startsWith("/") || path.includes(":") || path.includes("\\") || path.includes("\0")) {
    return false;
  }
  return path.split("/").every((part) => part.length > 0 && part !== "." && part !== "..");
}

function isRepositoryChangedPath(path: string): boolean {
  if (!path.startsWith("/") || path.includes("\\") || path.includes("\0")) {
    return false;
  }
  const parts = path.split("/");
  if (parts.length < 2 || parts[0] !== "") {
    return false;
  }
  return parts.slice(1).every((part) => part.length > 0 && part !== "." && part !== "..");
}

function isHistoryStartRevision(revision: string): revision is HistoryStartRevision {
  return revision === "head" || isHistoryNumberedRevision(revision);
}

function isHistoryNumberedRevision(revision: string): revision is HistoryNumberedRevision {
  const match = /^r(0|[1-9]\d*)$/u.exec(revision);
  if (match === null) {
    return false;
  }
  return Number(match[1]) <= MAX_SVN_REVNUM;
}

function invalidHistoryRequest(field: string): HistoryLogResponseError {
  return new HistoryLogResponseError(
    "SUBVERSIONR_HISTORY_LOG_REQUEST_INVALID",
    "input",
    "error.history.logRequestInvalid",
    { field },
  );
}

function invalidHistoryResponse(field: string): HistoryLogResponseError {
  return new HistoryLogResponseError(
    "SUBVERSIONR_HISTORY_LOG_RESPONSE_INVALID",
    "protocol",
    "error.history.logResponseInvalid",
    { field },
  );
}
