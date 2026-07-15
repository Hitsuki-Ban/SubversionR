import type * as vscode from "vscode";

export const DIAGNOSTICS_DOCUMENT_URI_SCHEME = "svn-r-diagnostics";

export type RepositoryReadonlyReportKind =
  | "repository-properties"
  | "resource-properties"
  | "repository-mergeinfo"
  | "resource-mergeinfo";

export interface RepositoryReadonlyReportDocument {
  kind: RepositoryReadonlyReportKind;
  repositoryId: string;
  epoch: number;
  path: string;
  content: string;
}

export interface DiagnosticsDocumentUriComponents {
  scheme: string;
  authority: string;
  path: string;
  query: string;
}

export interface DiagnosticsReadonlyDocumentProviderApi<TUri = unknown> {
  createEventEmitter(): DiagnosticsDocumentEventEmitter<TUri>;
  uriFromComponents(components: DiagnosticsDocumentUriComponents): TUri;
  currentRepositoryEpoch(repositoryId: string): number | undefined;
}

export interface DiagnosticsDocumentEventEmitter<TUri> {
  event: vscode.Event<TUri>;
  fire(uri?: TUri): void;
  dispose(): void;
}

interface RepositoryReadonlyReportEntry<TUri> {
  uri: TUri;
  content: string;
}

type ParsedDiagnosticsDocument =
  | { type: "version-report"; id: string }
  | {
      type: "repository-report";
      kind: RepositoryReadonlyReportKind;
      repositoryId: string;
      epoch: number;
      path: string;
    };

const REPORT_PATHS: Readonly<Record<RepositoryReadonlyReportKind, string>> = {
  "repository-properties": "/repository-properties.md",
  "resource-properties": "/resource-properties.md",
  "repository-mergeinfo": "/repository-mergeinfo.md",
  "resource-mergeinfo": "/resource-mergeinfo.md",
};

const REPORT_KINDS_BY_PATH = new Map<string, RepositoryReadonlyReportKind>(
  Object.entries(REPORT_PATHS).map(([kind, path]) => [path, kind as RepositoryReadonlyReportKind]),
);

export class DiagnosticsReadonlyDocumentProvider<TUri = unknown> {
  private readonly versionDocuments = new Map<string, string>();
  private readonly repositoryReports = new Map<string, RepositoryReadonlyReportEntry<TUri>>();
  private readonly emitter: DiagnosticsDocumentEventEmitter<TUri>;
  private nextDocumentId = 1;

  public constructor(private readonly api: DiagnosticsReadonlyDocumentProviderApi<TUri>) {
    this.emitter = api.createEventEmitter();
  }

  public get onDidChange(): vscode.Event<TUri> {
    return this.emitter.event;
  }

  public createDocument(content: string): TUri {
    const id = String(this.nextDocumentId);
    this.nextDocumentId += 1;
    this.versionDocuments.set(id, content);
    return this.api.uriFromComponents({
      scheme: DIAGNOSTICS_DOCUMENT_URI_SCHEME,
      authority: "readonly",
      path: "/version-report.json",
      query: `id=${encodeURIComponent(id)}`,
    });
  }

  public createOrUpdateRepositoryReport(document: RepositoryReadonlyReportDocument): TUri {
    validateRepositoryReportDocument(document);
    const key = repositoryReportKey(document);
    const existing = this.repositoryReports.get(key);
    if (existing) {
      existing.content = document.content;
      this.emitter.fire(existing.uri);
      return existing.uri;
    }

    const uri = this.api.uriFromComponents({
      scheme: DIAGNOSTICS_DOCUMENT_URI_SCHEME,
      authority: "readonly",
      path: REPORT_PATHS[document.kind],
      query: repositoryReportQuery(document),
    });
    this.repositoryReports.set(key, { uri, content: document.content });
    return uri;
  }

  public provideTextDocumentContent(uri: unknown): string {
    const document = parseDiagnosticsDocument(uri);
    if (document.type === "version-report") {
      const content = this.versionDocuments.get(document.id);
      if (content === undefined) {
        throw diagnosticsDocumentNotFound();
      }
      return content;
    }

    const currentEpoch = this.api.currentRepositoryEpoch(document.repositoryId);
    if (currentEpoch === undefined) {
      throw new DiagnosticsDocumentProviderError(
        "SUBVERSIONR_DIAGNOSTICS_REPORT_REPOSITORY_NOT_OPEN",
        "lifecycle",
        "error.diagnostics.reportRepositoryNotOpen",
        { repositoryId: document.repositoryId, epoch: document.epoch },
      );
    }
    if (currentEpoch !== document.epoch) {
      throw new DiagnosticsDocumentProviderError(
        "SUBVERSIONR_DIAGNOSTICS_REPORT_SESSION_STALE",
        "lifecycle",
        "error.diagnostics.reportSessionStale",
        {
          repositoryId: document.repositoryId,
          expectedEpoch: document.epoch,
          actualEpoch: currentEpoch,
        },
      );
    }

    const content = this.repositoryReports.get(repositoryReportKey(document))?.content;
    if (content === undefined) {
      throw diagnosticsDocumentNotFound();
    }
    return content;
  }

  public releaseDocument(uri: unknown): void {
    const document = parseDiagnosticsDocument(uri);
    if (document.type === "version-report") {
      this.versionDocuments.delete(document.id);
      return;
    }
    this.repositoryReports.delete(repositoryReportKey(document));
  }

  public dispose(): void {
    this.versionDocuments.clear();
    this.repositoryReports.clear();
    this.emitter.dispose();
  }
}

export type DiagnosticsDocumentProviderErrorCategory = "input" | "lifecycle";

export class DiagnosticsDocumentProviderError extends Error {
  public readonly retryable = false;
  public readonly diagnostics = null;

  public constructor(
    public readonly code: string,
    public readonly category: DiagnosticsDocumentProviderErrorCategory,
    public readonly messageKey: string,
    public readonly safeArgs: Record<string, unknown> = {},
  ) {
    super(code);
    this.name = "DiagnosticsDocumentProviderError";
  }
}

function parseDiagnosticsDocument(uri: unknown): ParsedDiagnosticsDocument {
  if (!isRecord(uri) || uri.scheme !== DIAGNOSTICS_DOCUMENT_URI_SCHEME || uri.authority !== "readonly") {
    throw invalidDiagnosticsDocumentUri("scheme");
  }
  if ("fragment" in uri && uri.fragment !== "") {
    throw invalidDiagnosticsDocumentUri("fragment");
  }
  if (typeof uri.path !== "string") {
    throw invalidDiagnosticsDocumentUri("path");
  }
  if (typeof uri.query !== "string") {
    throw invalidDiagnosticsDocumentUri("query");
  }

  if (uri.path === "/version-report.json") {
    return { type: "version-report", id: versionDocumentId(uri.query) };
  }

  const kind = REPORT_KINDS_BY_PATH.get(uri.path);
  if (!kind) {
    throw invalidDiagnosticsDocumentUri("path");
  }
  const parsed = parseRepositoryReportQuery(kind, uri.query);
  return { type: "repository-report", kind, ...parsed };
}

function versionDocumentId(query: string): string {
  if (hasInvalidPercentEncoding(query)) {
    throw invalidDiagnosticsDocumentUri("query");
  }
  const params = new URLSearchParams(query);
  if (!hasExactQueryKeys(params, ["id"])) {
    throw invalidDiagnosticsDocumentUri("query");
  }
  const id = params.get("id");
  if (id === null || !/^[1-9][0-9]*$/u.test(id) || !Number.isSafeInteger(Number(id))) {
    throw invalidDiagnosticsDocumentUri("id");
  }
  if (query !== `id=${encodeURIComponent(id)}`) {
    throw invalidDiagnosticsDocumentUri("query");
  }
  return id;
}

function parseRepositoryReportQuery(kind: RepositoryReadonlyReportKind, query: string): {
  repositoryId: string;
  epoch: number;
  path: string;
} {
  if (hasInvalidPercentEncoding(query)) {
    throw invalidDiagnosticsDocumentUri("query");
  }
  const params = new URLSearchParams(query);
  if (!hasExactQueryKeys(params, ["repositoryId", "epoch", "path"])) {
    throw invalidDiagnosticsDocumentUri("query");
  }

  const repositoryId = params.get("repositoryId");
  const epochText = params.get("epoch");
  const path = params.get("path");
  if (repositoryId === null || repositoryId.length === 0 || repositoryId !== repositoryId.trim()) {
    throw invalidDiagnosticsDocumentUri("repositoryId");
  }
  if (epochText === null || !/^(0|[1-9][0-9]*)$/u.test(epochText)) {
    throw invalidDiagnosticsDocumentUri("epoch");
  }
  const epoch = Number(epochText);
  if (!Number.isSafeInteger(epoch)) {
    throw invalidDiagnosticsDocumentUri("epoch");
  }
  if (path === null || !isReportTargetPath(kind, path)) {
    throw invalidDiagnosticsDocumentUri("path");
  }

  const parsed = { repositoryId, epoch, path };
  if (query !== repositoryReportQuery(parsed)) {
    throw invalidDiagnosticsDocumentUri("query");
  }
  return parsed;
}

function validateRepositoryReportDocument(document: RepositoryReadonlyReportDocument): void {
  if (!Object.prototype.hasOwnProperty.call(REPORT_PATHS, document.kind)) {
    throw invalidRepositoryReportDocument("kind");
  }
  if (
    typeof document.repositoryId !== "string" ||
    document.repositoryId.length === 0 ||
    document.repositoryId !== document.repositoryId.trim()
  ) {
    throw invalidRepositoryReportDocument("repositoryId");
  }
  if (!Number.isSafeInteger(document.epoch) || document.epoch < 0) {
    throw invalidRepositoryReportDocument("epoch");
  }
  if (typeof document.path !== "string" || !isReportTargetPath(document.kind, document.path)) {
    throw invalidRepositoryReportDocument("path");
  }
  if (typeof document.content !== "string") {
    throw invalidRepositoryReportDocument("content");
  }
}

function repositoryReportKey(document: {
  kind: RepositoryReadonlyReportKind;
  repositoryId: string;
  epoch: number;
  path: string;
}): string {
  return JSON.stringify([document.kind, document.repositoryId, document.epoch, document.path]);
}

function repositoryReportQuery(document: { repositoryId: string; epoch: number; path: string }): string {
  const params = new URLSearchParams();
  params.set("repositoryId", document.repositoryId);
  params.set("epoch", String(document.epoch));
  params.set("path", document.path);
  return params.toString();
}

function hasExactQueryKeys(params: URLSearchParams, expectedKeys: readonly string[]): boolean {
  const entries = Array.from(params.keys());
  return (
    entries.length === expectedKeys.length &&
    expectedKeys.every((key) => params.getAll(key).length === 1) &&
    entries.every((key) => expectedKeys.includes(key))
  );
}

function hasInvalidPercentEncoding(query: string): boolean {
  return /%(?![0-9A-Fa-f]{2})/u.test(query);
}

function isRepositoryRelativePath(path: string): boolean {
  if (path === ".") {
    return true;
  }
  if (
    path.length === 0 ||
    path.includes("\\") ||
    path.startsWith("/") ||
    path.includes(":") ||
    path.includes("\0")
  ) {
    return false;
  }
  return path.split("/").every((part) => part.length > 0 && part !== "." && part !== "..");
}

function isReportTargetPath(kind: RepositoryReadonlyReportKind, path: string): boolean {
  if (!isRepositoryRelativePath(path)) {
    return false;
  }
  return kind === "repository-properties" || kind === "repository-mergeinfo" ? path === "." : true;
}

function diagnosticsDocumentNotFound(): DiagnosticsDocumentProviderError {
  return new DiagnosticsDocumentProviderError(
    "SUBVERSIONR_DIAGNOSTICS_DOCUMENT_NOT_FOUND",
    "lifecycle",
    "error.diagnostics.documentNotFound",
  );
}

function invalidDiagnosticsDocumentUri(field: string): DiagnosticsDocumentProviderError {
  return new DiagnosticsDocumentProviderError(
    "SUBVERSIONR_DIAGNOSTICS_DOCUMENT_URI_INVALID",
    "input",
    "error.diagnostics.documentUriInvalid",
    { field },
  );
}

function invalidRepositoryReportDocument(field: string): DiagnosticsDocumentProviderError {
  return new DiagnosticsDocumentProviderError(
    "SUBVERSIONR_DIAGNOSTICS_REPORT_DOCUMENT_INVALID",
    "input",
    "error.diagnostics.reportDocumentInvalid",
    { field },
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}
