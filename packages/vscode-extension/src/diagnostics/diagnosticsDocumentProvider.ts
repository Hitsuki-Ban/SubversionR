import type * as vscode from "vscode";

export const DIAGNOSTICS_DOCUMENT_URI_SCHEME = "svn-r-diagnostics";

export interface DiagnosticsDocumentUriComponents {
  scheme: string;
  authority: string;
  path: string;
  query: string;
}

export interface DiagnosticsReadonlyDocumentProviderApi {
  createEventEmitter(): DiagnosticsDocumentEventEmitter<unknown>;
  uriFromComponents(components: DiagnosticsDocumentUriComponents): unknown;
}

export interface DiagnosticsDocumentEventEmitter<TUri> {
  event: vscode.Event<TUri>;
  fire(uri?: TUri): void;
  dispose(): void;
}

export class DiagnosticsReadonlyDocumentProvider<TUri = unknown> {
  private readonly documents = new Map<string, string>();
  private readonly emitter: DiagnosticsDocumentEventEmitter<TUri>;
  private nextDocumentId = 1;

  public constructor(
    private readonly api: {
      createEventEmitter(): DiagnosticsDocumentEventEmitter<TUri>;
      uriFromComponents(components: DiagnosticsDocumentUriComponents): TUri;
    },
  ) {
    this.emitter = api.createEventEmitter();
  }

  public get onDidChange(): vscode.Event<TUri> {
    return this.emitter.event;
  }

  public createDocument(content: string): TUri {
    const id = String(this.nextDocumentId);
    this.nextDocumentId += 1;
    this.documents.set(id, content);
    return this.api.uriFromComponents({
      scheme: DIAGNOSTICS_DOCUMENT_URI_SCHEME,
      authority: "readonly",
      path: "/version-report.json",
      query: `id=${encodeURIComponent(id)}`,
    });
  }

  public provideTextDocumentContent(uri: unknown): string {
    const id = diagnosticsDocumentId(uri);
    const content = this.documents.get(id);
    if (content === undefined) {
      throw new DiagnosticsDocumentProviderError(
        "SUBVERSIONR_DIAGNOSTICS_DOCUMENT_NOT_FOUND",
        "error.diagnostics.documentNotFound",
      );
    }
    return content;
  }

  public releaseDocument(uri: unknown): void {
    const id = diagnosticsDocumentId(uri);
    this.documents.delete(id);
  }

  public dispose(): void {
    this.documents.clear();
    this.emitter.dispose();
  }
}

export class DiagnosticsDocumentProviderError extends Error {
  public constructor(
    public readonly code: string,
    public readonly messageKey: string,
  ) {
    super(code);
    this.name = "DiagnosticsDocumentProviderError";
  }
}

function diagnosticsDocumentId(uri: unknown): string {
  if (!isRecord(uri) || uri.scheme !== DIAGNOSTICS_DOCUMENT_URI_SCHEME || uri.authority !== "readonly") {
    throw invalidDiagnosticsDocumentUri("scheme");
  }
  if (uri.path !== "/version-report.json") {
    throw invalidDiagnosticsDocumentUri("path");
  }
  if (typeof uri.query !== "string") {
    throw invalidDiagnosticsDocumentUri("query");
  }
  const params = new URLSearchParams(uri.query);
  const id = params.get("id");
  if (id === null || id.trim().length === 0) {
    throw invalidDiagnosticsDocumentUri("id");
  }
  return id;
}

function invalidDiagnosticsDocumentUri(field: string): DiagnosticsDocumentProviderError {
  return new DiagnosticsDocumentProviderError(
    "SUBVERSIONR_DIAGNOSTICS_DOCUMENT_URI_INVALID",
    `error.diagnostics.documentUriInvalid.${field}`,
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}
