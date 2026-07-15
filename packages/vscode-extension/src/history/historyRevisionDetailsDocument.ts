import { randomUUID } from "node:crypto";
import type { HistoryLogEntry } from "./historyLogRpcClient";

export const REVISION_DETAILS_URI_SCHEME = "svn-r-revision-details";

const MAX_SVN_REVNUM = 2_147_483_647;

export interface RevisionDetailsUriComponents {
  scheme: string;
  authority: string;
  path: string;
  query: string;
}

export interface HistoryRevisionDetailsTarget {
  repositoryId: string;
  epoch: number;
  targetKind: "repository" | "file" | "line";
  path: string;
  label: string;
  revision: string;
  author: string | null;
  date: string | null;
  message: string | null;
  changedPaths: HistoryLogEntry["changedPaths"];
  hasChildren: boolean;
  nonInheritable: boolean;
  subtractiveMerge: boolean;
}

export class RevisionDetailsUriError extends Error {
  public constructor(
    public readonly code: string,
    public readonly field: string,
  ) {
    super(code);
    this.name = "RevisionDetailsUriError";
  }
}

export class HistoryRevisionDetailsDocumentError extends Error {
  public constructor(
    public readonly code: string,
    public readonly category: "input",
    public readonly messageKey: string,
    public readonly safeArgs: Record<string, unknown> = {},
  ) {
    super(code);
    this.name = "HistoryRevisionDetailsDocumentError";
  }
}

export class HistoryRevisionDetailsDocumentStore {
  private readonly documents = new Map<string, HistoryRevisionDetailsTarget>();

  public createDocumentUri(target: HistoryRevisionDetailsTarget): RevisionDetailsUriComponents {
    validateRevisionDetailsTarget(target);
    const id = randomUUID();
    this.documents.set(id, target);
    return createRevisionDetailsUriComponents(id, target.revision);
  }

  public get(id: string): HistoryRevisionDetailsTarget | undefined {
    return this.documents.get(id);
  }

  public releaseDocument(uri: RevisionDetailsUriComponents): boolean {
    const request = parseRevisionDetailsUri(uri);
    return this.documents.delete(request.id);
  }
}

export interface HistoryRevisionDetailsDocumentProviderOptions {
  store: HistoryRevisionDetailsDocumentStore;
  localize(message: string, ...args: unknown[]): string;
}

export class HistoryRevisionDetailsDocumentProvider {
  public constructor(private readonly options: HistoryRevisionDetailsDocumentProviderOptions) {}

  public async provideTextDocumentContent(uri: RevisionDetailsUriComponents): Promise<string> {
    const request = parseRevisionDetailsUri(uri);
    const details = this.options.store.get(request.id);
    if (!details) {
      throw new HistoryRevisionDetailsDocumentError(
        "SUBVERSIONR_REVISION_DETAILS_DOCUMENT_MISSING",
        "input",
        "error.history.revisionDetailsDocumentMissing",
        { id: request.id },
      );
    }
    if (details.revision !== request.revision) {
      throw new HistoryRevisionDetailsDocumentError(
        "SUBVERSIONR_REVISION_DETAILS_DOCUMENT_MISMATCH",
        "input",
        "error.history.revisionDetailsDocumentMismatch",
        { id: request.id },
      );
    }
    return renderRevisionDetails(details, this.options.localize);
  }
}

export function parseRevisionDetailsUri(uri: RevisionDetailsUriComponents): { id: string; revision: string } {
  if (uri.scheme !== REVISION_DETAILS_URI_SCHEME) {
    throw invalidRevisionDetailsUri("scheme");
  }
  if (uri.authority !== "details") {
    throw invalidRevisionDetailsUri("authority");
  }
  const revisionMatch = /^\/(r(?:0|[1-9]\d*))\.txt$/u.exec(uri.path);
  if (!revisionMatch) {
    throw invalidRevisionDetailsUri("path");
  }
  const query = new URLSearchParams(uri.query);
  requireExactQueryKeys(query, ["id"]);
  const id = requireQueryString(query, "id");
  if (!isDocumentId(id)) {
    throw invalidRevisionDetailsUri("id");
  }
  return {
    id,
    revision: revisionMatch[1],
  };
}

function createRevisionDetailsUriComponents(id: string, revision: string): RevisionDetailsUriComponents {
  if (!isDocumentId(id)) {
    throw invalidRevisionDetailsUri("id");
  }
  if (!isExplicitRevision(revision)) {
    throw invalidRevisionDetailsUri("revision");
  }
  const query = new URLSearchParams();
  query.set("id", id);
  return {
    scheme: REVISION_DETAILS_URI_SCHEME,
    authority: "details",
    path: `/${revision}.txt`,
    query: query.toString(),
  };
}

function renderRevisionDetails(
  details: HistoryRevisionDetailsTarget,
  localize: (message: string, ...args: unknown[]) => string,
): string {
  const lines = [
    localize("Revision {0}", details.revision),
    "",
    localize("Repository ID: {0}", details.repositoryId),
    historyTargetSummary(details, localize),
    localize("Author: {0}", details.author?.trim() || localize("Unknown author")),
    localize("Date: {0}", details.date ?? localize("Unknown date")),
    localize("Merged Revision Child: {0}", localizeBoolean(details.hasChildren, localize)),
    localize("Non-inheritable Merge: {0}", localizeBoolean(details.nonInheritable, localize)),
    localize("Subtractive Merge: {0}", localizeBoolean(details.subtractiveMerge, localize)),
    "",
    localize("Log Message:"),
    renderUntrustedHistoryText(details.message, localize),
    "",
    localize("Changed Paths:"),
  ];
  if (details.changedPaths.length === 0) {
    lines.push(localize("No changed paths reported."));
  } else {
    details.changedPaths.forEach((changedPath, index) => {
      lines.push(`${index + 1}. ${changedPath.action} ${changedPath.path}`);
      lines.push(`   ${localize("Node Kind: {0}", localizeNodeKind(changedPath.nodeKind, localize))}`);
      lines.push(`   ${localize("Text Modified: {0}", localizeTristate(changedPath.textModified, localize))}`);
      lines.push(
        `   ${localize("Properties Modified: {0}", localizeTristate(changedPath.propertiesModified, localize))}`,
      );
      if (changedPath.copyFromPath && changedPath.copyFromRevision !== null) {
        lines.push(`   ${localize("Copy From: {0}@r{1}", changedPath.copyFromPath, changedPath.copyFromRevision)}`);
      }
    });
  }
  lines.push("");
  return lines.join("\n");
}

function localizeBoolean(value: boolean, localize: (message: string, ...args: unknown[]) => string): string {
  return value ? localize("Yes") : localize("No");
}

function renderUntrustedHistoryText(
  value: string | null,
  localize: (message: string, ...args: unknown[]) => string,
): string {
  const trimmed = value?.trim();
  if (!trimmed) {
    return localize("No log message");
  }
  return trimmed.replace(/[\u0000-\u001f\u007f]/gu, (character) => {
    switch (character) {
      case "\r":
        return "\\r";
      case "\n":
        return "\\n";
      case "\t":
        return "\\t";
      default:
        return `\\u${character.codePointAt(0)?.toString(16).padStart(4, "0") ?? "0000"}`;
    }
  });
}

function localizeTristate(
  value: "true" | "false" | "unknown",
  localize: (message: string, ...args: unknown[]) => string,
): string {
  if (value === "true") {
    return localize("Yes");
  }
  if (value === "false") {
    return localize("No");
  }
  return localize("Unknown");
}

function localizeNodeKind(value: string, localize: (message: string, ...args: unknown[]) => string): string {
  switch (value) {
    case "none":
      return localize("No node");
    case "file":
      return localize("File");
    case "dir":
      return localize("Directory");
    case "unknown":
      return localize("Unknown");
    default:
      throw invalidRevisionDetailsUri("nodeKind");
  }
}

function validateRevisionDetailsTarget(target: HistoryRevisionDetailsTarget): void {
  if (typeof target.repositoryId !== "string" || target.repositoryId.trim().length === 0) {
    throw invalidRevisionDetailsUri("repositoryId");
  }
  if (!Number.isSafeInteger(target.epoch) || target.epoch < 0) {
    throw invalidRevisionDetailsUri("epoch");
  }
  if (target.targetKind !== "repository" && target.targetKind !== "file" && target.targetKind !== "line") {
    throw invalidRevisionDetailsUri("targetKind");
  }
  if (!isHistoryPath(target.path, target.targetKind)) {
    throw invalidRevisionDetailsUri("path");
  }
  if (typeof target.label !== "string" || target.label.trim().length === 0) {
    throw invalidRevisionDetailsUri("label");
  }
  if (!isExplicitRevision(target.revision)) {
    throw invalidRevisionDetailsUri("revision");
  }
  if (target.author !== null && typeof target.author !== "string") {
    throw invalidRevisionDetailsUri("author");
  }
  if (target.date !== null && typeof target.date !== "string") {
    throw invalidRevisionDetailsUri("date");
  }
  if (target.message !== null && typeof target.message !== "string") {
    throw invalidRevisionDetailsUri("message");
  }
  if (!Array.isArray(target.changedPaths)) {
    throw invalidRevisionDetailsUri("changedPaths");
  }
  target.changedPaths.forEach((changedPath, index) => {
    validateChangedPath(changedPath, `changedPaths.${index}`);
  });
  if (
    typeof target.hasChildren !== "boolean" ||
    typeof target.nonInheritable !== "boolean" ||
    typeof target.subtractiveMerge !== "boolean"
  ) {
    throw invalidRevisionDetailsUri("mergeFlags");
  }
}

function validateChangedPath(changedPath: unknown, field: string): void {
  if (!isRecord(changedPath)) {
    throw invalidRevisionDetailsUri(field);
  }
  requireExactChangedPathKeys(changedPath, field, [
    "path",
    "action",
    "copyFromPath",
    "copyFromRevision",
    "nodeKind",
    "textModified",
    "propertiesModified",
  ]);
  if (!isRepositoryChangedPath(changedPath.path)) {
    throw invalidRevisionDetailsUri(`${field}.path`);
  }
  if (typeof changedPath.action !== "string" || !/^[A-Z]$/u.test(changedPath.action)) {
    throw invalidRevisionDetailsUri(`${field}.action`);
  }
  if (changedPath.copyFromPath !== null && !isRepositoryChangedPath(changedPath.copyFromPath)) {
    throw invalidRevisionDetailsUri(`${field}.copyFromPath`);
  }
  if (changedPath.copyFromRevision !== null && !isSvnRevisionNumber(changedPath.copyFromRevision)) {
    throw invalidRevisionDetailsUri(`${field}.copyFromRevision`);
  }
  if ((changedPath.copyFromPath === null) !== (changedPath.copyFromRevision === null)) {
    throw invalidRevisionDetailsUri(`${field}.copyFromPath`);
  }
  if (
    typeof changedPath.nodeKind !== "string" ||
    !["none", "file", "dir", "unknown"].includes(changedPath.nodeKind)
  ) {
    throw invalidRevisionDetailsUri(`${field}.nodeKind`);
  }
  if (!isTristate(changedPath.textModified)) {
    throw invalidRevisionDetailsUri(`${field}.textModified`);
  }
  if (!isTristate(changedPath.propertiesModified)) {
    throw invalidRevisionDetailsUri(`${field}.propertiesModified`);
  }
}

function requireExactChangedPathKeys(
  value: Record<string, unknown>,
  field: string,
  expectedKeys: readonly string[],
): void {
  const expected = new Set(expectedKeys);
  for (const key of Object.keys(value)) {
    if (!expected.has(key)) {
      throw invalidRevisionDetailsUri(`${field}.${key}`);
    }
  }
  for (const key of expectedKeys) {
    if (!Object.prototype.hasOwnProperty.call(value, key)) {
      throw invalidRevisionDetailsUri(`${field}.${key}`);
    }
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function requireExactQueryKeys(query: URLSearchParams, expectedKeys: readonly string[]): void {
  const expected = new Set(expectedKeys);
  const seen = new Map<string, number>();
  for (const key of query.keys()) {
    if (!expected.has(key)) {
      throw invalidRevisionDetailsUri(key);
    }
    seen.set(key, (seen.get(key) ?? 0) + 1);
  }
  for (const key of expectedKeys) {
    if (seen.get(key) !== 1) {
      throw invalidRevisionDetailsUri(key);
    }
  }
}

function requireQueryString(query: URLSearchParams, field: string): string {
  const value = query.get(field);
  if (value === null || value.trim().length === 0) {
    throw invalidRevisionDetailsUri(field);
  }
  return value;
}

function isExplicitRevision(revision: string): boolean {
  const match = /^r(0|[1-9]\d*)$/u.exec(revision);
  if (match === null) {
    return false;
  }
  return Number(match[1]) <= 2_147_483_647;
}

function isDocumentId(id: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u.test(id);
}

function historyTargetSummary(
  details: HistoryRevisionDetailsTarget,
  localize: (message: string, ...args: unknown[]) => string,
): string {
  switch (details.targetKind) {
    case "repository":
      return localize("History Target: Repository Root");
    case "file":
      return localize("History Target: File {0}", details.path);
    case "line":
      return localize("History Target: Line {0}", details.label);
  }
}

function isHistoryPath(path: string, targetKind: "repository" | "file" | "line"): boolean {
  if (targetKind === "repository") {
    return path === ".";
  }
  if (path === "." || path.trim().length === 0) {
    return false;
  }
  if (path.startsWith("/") || path.includes(":") || path.includes("\\") || path.includes("\0")) {
    return false;
  }
  return path.split("/").every((part) => part.length > 0 && part !== "." && part !== "..");
}

function isRepositoryChangedPath(value: unknown): value is string {
  if (typeof value !== "string" || !value.startsWith("/") || value.includes("\\") || value.includes("\0")) {
    return false;
  }
  const parts = value.split("/");
  if (parts.length < 2 || parts[0] !== "") {
    return false;
  }
  return parts.slice(1).every((part) => part.length > 0 && part !== "." && part !== "..");
}

function isSvnRevisionNumber(value: unknown): boolean {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0 && value <= MAX_SVN_REVNUM;
}

function isTristate(value: unknown): boolean {
  return value === "true" || value === "false" || value === "unknown";
}

function invalidRevisionDetailsUri(field: string): RevisionDetailsUriError {
  return new RevisionDetailsUriError("SUBVERSIONR_REVISION_DETAILS_URI_INVALID", field);
}
