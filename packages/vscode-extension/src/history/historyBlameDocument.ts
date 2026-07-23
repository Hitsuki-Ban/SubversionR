import { Buffer } from "node:buffer";
import type * as vscode from "vscode";
import type {
  HistoryBlame,
  HistoryBlameClient,
  HistoryBlameIgnoreWhitespace,
  HistoryBlameLine,
  HistoryBlamePegOrEndRevision,
  HistoryBlameRequest,
} from "./historyBlameRpcClient";
import { requireTrustedWorkspace } from "../security/workspaceTrust";
import type { RemoteOperationEnvelope } from "../security/remoteAccessProfile";

export const BLAME_DOCUMENT_URI_SCHEME = "svn-r-blame";

const MAX_SVN_REVNUM = 2_147_483_647;
const MAX_BLAME_LINE_LIMIT = 5_000;

export interface HistoryBlameDocumentRequest extends Omit<HistoryBlameRequest, "remote"> {
  generation: number;
}

export interface BlameDocumentUriComponents {
  scheme: string;
  authority: string;
  path: string;
  query: string;
}

export class BlameDocumentUriError extends Error {
  public constructor(
    public readonly code: string,
    public readonly field: string,
  ) {
    super(code);
    this.name = "BlameDocumentUriError";
  }
}

export interface HistoryBlameDocumentProviderOptions {
  blameClient: HistoryBlameClient;
  createRemoteEnvelope(input: { repositoryId: string; epoch: number }): Promise<RemoteOperationEnvelope | undefined>;
  workspaceTrusted(): boolean;
  localize(message: string, ...args: unknown[]): string;
}

export class HistoryBlameDocumentProvider {
  public constructor(private readonly options: HistoryBlameDocumentProviderOptions) {}

  public async provideTextDocumentContent(
    uri: BlameDocumentUriComponents,
    token: vscode.CancellationToken,
  ): Promise<string> {
    requireTrustedWorkspace(this.options.workspaceTrusted);
    const cancellation = cancellationFromToken(token);
    try {
      cancellation.signal.throwIfAborted();
      const request = parseBlameDocumentUri(uri);
      const remote = await this.options.createRemoteEnvelope({
        repositoryId: request.repositoryId,
        epoch: request.epoch,
      });
      cancellation.signal.throwIfAborted();
      const blame = await this.options.blameClient.getBlame(
        blameRpcRequest(request, remote),
        { signal: cancellation.signal },
      );
      return renderBlameDocument(blame, this.options.localize);
    } finally {
      cancellation.dispose();
    }
  }
}

function cancellationFromToken(token: vscode.CancellationToken): {
  signal: AbortSignal;
  dispose(): void;
} {
  const controller = new AbortController();
  const subscription = token.onCancellationRequested(() => controller.abort());
  if (token.isCancellationRequested) {
    controller.abort();
  }
  return { signal: controller.signal, dispose: () => subscription.dispose() };
}

export function createBlameDocumentUriComponents(
  request: HistoryBlameDocumentRequest,
): BlameDocumentUriComponents {
  validateBlameDocumentRequest(request);
  const query = new URLSearchParams();
  query.set("repositoryId", request.repositoryId);
  query.set("epoch", String(request.epoch));
  query.set("generation", String(request.generation));
  query.set("path", request.path);
  query.set("pegRevision", request.pegRevision);
  query.set("startRevision", request.startRevision);
  query.set("endRevision", request.endRevision);
  query.set("lineStart", String(request.lineStart));
  query.set("lineLimit", String(request.lineLimit));
  query.set("ignoreWhitespace", request.ignoreWhitespace);
  query.set("ignoreEolStyle", String(request.ignoreEolStyle));
  query.set("ignoreMimeType", String(request.ignoreMimeType));
  query.set("includeMergedRevisions", String(request.includeMergedRevisions));
  return {
    scheme: BLAME_DOCUMENT_URI_SCHEME,
    authority: "blame",
    path: "/",
    query: query.toString(),
  };
}

export function parseBlameDocumentUri(uri: BlameDocumentUriComponents): HistoryBlameDocumentRequest {
  if (uri.scheme !== BLAME_DOCUMENT_URI_SCHEME) {
    throw invalidBlameDocumentUri("scheme");
  }
  if (uri.authority !== "blame") {
    throw invalidBlameDocumentUri("authority");
  }
  if (uri.path !== "/") {
    throw invalidBlameDocumentUri("path");
  }
  const query = new URLSearchParams(uri.query);
  requireExactQueryKeys(query, [
    "repositoryId",
    "epoch",
    "generation",
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
  const request = {
    repositoryId: requireQueryString(query, "repositoryId"),
    epoch: requireQueryInteger(query, "epoch"),
    generation: requireQueryInteger(query, "generation"),
    path: requireQueryString(query, "path"),
    pegRevision: requireQueryString(query, "pegRevision"),
    startRevision: requireQueryString(query, "startRevision"),
    endRevision: requireQueryString(query, "endRevision"),
    lineStart: requireQueryInteger(query, "lineStart"),
    lineLimit: requireQueryInteger(query, "lineLimit"),
    ignoreWhitespace: requireQueryString(query, "ignoreWhitespace"),
    ignoreEolStyle: requireQueryBoolean(query, "ignoreEolStyle"),
    ignoreMimeType: requireQueryBoolean(query, "ignoreMimeType"),
    includeMergedRevisions: requireQueryBoolean(query, "includeMergedRevisions"),
  };
  validateBlameDocumentRequest(request);
  return request;
}

function blameRpcRequest(
  request: HistoryBlameDocumentRequest,
  remote: RemoteOperationEnvelope | undefined,
): HistoryBlameRequest {
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
    ...(remote === undefined ? {} : { remote }),
  };
}

function renderBlameDocument(
  blame: HistoryBlame,
  localize: (message: string, ...args: unknown[]) => string,
): string {
  const lines = [
    localize("SVN Blame: {0}", blame.path),
    "",
    localize("Repository ID: {0}", blame.repositoryId),
    localize("Revision Range: {0} - {1}", blame.startRevision, blame.endRevision),
    localize("Resolved Revision Range: r{0} - r{1}", blame.resolvedStartRevision, blame.resolvedEndRevision),
    localize("Line Window: {0} - {1}", blame.lineStart, blame.lineStart + blame.lineLimit - 1),
    localize("Has More Lines: {0}", localizeBoolean(blame.hasMore, localize)),
    "",
    ...blame.lines.map((line) => renderBlameLine(line, localize)),
    "",
  ];
  return lines.join("\n");
}

function renderBlameLine(
  line: HistoryBlameLine,
  localize: (message: string, ...args: unknown[]) => string,
): string {
  return [
    String(line.lineNumber),
    blameRevisionLabel(line, localize),
    line.author ?? localize("Unknown author"),
    line.date ?? localize("Unknown date"),
    decodeLine(line),
  ].join(" | ");
}

function blameRevisionLabel(
  line: HistoryBlameLine,
  localize: (message: string, ...args: unknown[]) => string,
): string {
  if (line.localChange) {
    return localize("Uncommitted");
  }
  if (line.revision === null) {
    return localize("Unknown");
  }
  const revision = `r${line.revision}`;
  if (line.mergedRevision === null) {
    return revision;
  }
  return `${revision} (${localize("Merged from r{0}", line.mergedRevision)})`;
}

function decodeLine(line: HistoryBlameLine): string {
  return new TextDecoder("utf-8", { fatal: false }).decode(Buffer.from(line.lineBase64, "base64"));
}

function localizeBoolean(value: boolean, localize: (message: string, ...args: unknown[]) => string): string {
  return value ? localize("Yes") : localize("No");
}

function requireExactQueryKeys(query: URLSearchParams, expectedKeys: readonly string[]): void {
  const expected = new Set(expectedKeys);
  const seen = new Map<string, number>();
  for (const key of query.keys()) {
    if (!expected.has(key)) {
      throw invalidBlameDocumentUri(key);
    }
    seen.set(key, (seen.get(key) ?? 0) + 1);
  }
  for (const key of expectedKeys) {
    if (seen.get(key) !== 1) {
      throw invalidBlameDocumentUri(key);
    }
  }
}

function validateBlameDocumentRequest(request: HistoryBlameDocumentRequest): void {
  if (typeof request.repositoryId !== "string" || request.repositoryId.trim().length === 0) {
    throw invalidBlameDocumentUri("repositoryId");
  }
  if (!Number.isSafeInteger(request.epoch) || request.epoch < 0) {
    throw invalidBlameDocumentUri("epoch");
  }
  if (!Number.isSafeInteger(request.generation) || request.generation < 0) {
    throw invalidBlameDocumentUri("generation");
  }
  if (typeof request.path !== "string" || !isBlamePath(request.path)) {
    throw invalidBlameDocumentUri("path");
  }
  if (!isBlamePegOrEndRevision(request.pegRevision)) {
    throw invalidBlameDocumentUri("pegRevision");
  }
  if (!isBlameNumberedRevision(request.startRevision)) {
    throw invalidBlameDocumentUri("startRevision");
  }
  if (!isBlamePegOrEndRevision(request.endRevision)) {
    throw invalidBlameDocumentUri("endRevision");
  }
  if (!isLineStart(request.lineStart)) {
    throw invalidBlameDocumentUri("lineStart");
  }
  if (!isLineLimit(request.lineLimit)) {
    throw invalidBlameDocumentUri("lineLimit");
  }
  if (!isIgnoreWhitespace(request.ignoreWhitespace)) {
    throw invalidBlameDocumentUri("ignoreWhitespace");
  }
  if (
    typeof request.ignoreEolStyle !== "boolean" ||
    typeof request.ignoreMimeType !== "boolean" ||
    typeof request.includeMergedRevisions !== "boolean"
  ) {
    throw invalidBlameDocumentUri("options");
  }
  requireFixedBlameContract(request);
}

function requireFixedBlameContract(request: HistoryBlameDocumentRequest): void {
  if (request.pegRevision !== "base") {
    throw invalidBlameDocumentUri("pegRevision");
  }
  if (request.startRevision !== "r0") {
    throw invalidBlameDocumentUri("startRevision");
  }
  if (request.endRevision !== "base") {
    throw invalidBlameDocumentUri("endRevision");
  }
  if (request.lineStart !== 1) {
    throw invalidBlameDocumentUri("lineStart");
  }
  if (request.lineLimit !== MAX_BLAME_LINE_LIMIT) {
    throw invalidBlameDocumentUri("lineLimit");
  }
  if (request.ignoreWhitespace !== "none") {
    throw invalidBlameDocumentUri("ignoreWhitespace");
  }
  if (request.ignoreEolStyle) {
    throw invalidBlameDocumentUri("ignoreEolStyle");
  }
  if (request.ignoreMimeType) {
    throw invalidBlameDocumentUri("ignoreMimeType");
  }
}

function requireQueryString(query: URLSearchParams, field: string): string {
  const value = query.get(field);
  if (value === null || value.trim().length === 0) {
    throw invalidBlameDocumentUri(field);
  }
  return value;
}

function requireQueryInteger(query: URLSearchParams, field: string): number {
  const value = requireQueryString(query, field);
  if (!/^\d+$/u.test(value)) {
    throw invalidBlameDocumentUri(field);
  }
  const integer = Number(value);
  if (!Number.isSafeInteger(integer)) {
    throw invalidBlameDocumentUri(field);
  }
  return integer;
}

function requireQueryBoolean(query: URLSearchParams, field: string): boolean {
  const value = requireQueryString(query, field);
  if (value === "true") {
    return true;
  }
  if (value === "false") {
    return false;
  }
  throw invalidBlameDocumentUri(field);
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

function isBlamePegOrEndRevision(revision: string): revision is HistoryBlamePegOrEndRevision {
  return revision === "base" || revision === "head" || isBlameNumberedRevision(revision);
}

function isBlameNumberedRevision(revision: string): boolean {
  const match = /^r(0|[1-9]\d*)$/u.exec(revision);
  if (match === null) {
    return false;
  }
  return Number(match[1]) <= MAX_SVN_REVNUM;
}

function isLineStart(value: number): boolean {
  return (
    Number.isSafeInteger(value) &&
    value >= 1 &&
    value <= Number.MAX_SAFE_INTEGER - MAX_BLAME_LINE_LIMIT
  );
}

function isLineLimit(value: number): boolean {
  return Number.isSafeInteger(value) && value >= 1 && value <= MAX_BLAME_LINE_LIMIT;
}

function isIgnoreWhitespace(value: string): value is HistoryBlameIgnoreWhitespace {
  return value === "none" || value === "change" || value === "all";
}

function invalidBlameDocumentUri(field: string): BlameDocumentUriError {
  return new BlameDocumentUriError("SUBVERSIONR_BLAME_DOCUMENT_URI_INVALID", field);
}
