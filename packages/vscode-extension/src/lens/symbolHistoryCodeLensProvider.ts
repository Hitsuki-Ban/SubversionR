import type * as vscode from "vscode";
import type { HistoryBlameClient, HistoryBlameLine } from "../history/historyBlameRpcClient";
import type { RepositorySession, RepositorySessionService } from "../repository/repositorySessionService";
import type { SourceControlProjectionService } from "../scm/sourceControlProjectionService";
import type { ScmProjectedResource, ScmProjectedResourceLookup } from "../scm/sourceControlResourceStore";
import type { PathCasePolicy } from "../status/types";
import type { LensSettings } from "./lensSettings";
import { isChangelistResourceGroupId } from "../scm/resourceStateClassifier";
import type { RemoteOperationEnvelope } from "../security/remoteAccessProfile";

export interface SymbolHistoryCodeLensProviderOptions<TCodeLens extends SymbolHistoryCodeLens> {
  settings(): LensSettings;
  includeMergedRevisions(): boolean;
  historyClient: HistoryBlameClient;
  createRemoteEnvelope(input: { repositoryId: string; epoch: number }): Promise<RemoteOperationEnvelope | undefined>;
  sessionService: Pick<RepositorySessionService, "listOpenSessions">;
  sourceControlProjection: Pick<SourceControlProjectionService, "getProjectedResource">;
  workspaceTrusted(): boolean;
  api: SymbolHistoryCodeLensApi<TCodeLens>;
}

export interface SymbolHistoryCodeLensApi<TCodeLens extends SymbolHistoryCodeLens> {
  createEventEmitter(): SymbolHistoryCodeLensEventEmitter;
  createRange(startLine: number, startCharacter: number, endLine: number, endCharacter: number): unknown;
  createCodeLens(range: unknown): TCodeLens;
  executeDocumentSymbols(uri: SymbolHistoryUri): Promise<readonly SymbolHistorySymbol[] | undefined>;
  localize(message: string, ...args: unknown[]): string;
}

export interface SymbolHistoryCodeLensEventEmitter {
  event: vscode.Event<void>;
  fire(): void;
  dispose(): void;
}

export interface SymbolHistoryCodeLens {
  range: unknown;
  command?: SymbolHistoryCommand;
}

export interface SymbolHistoryTextDocument {
  uri: SymbolHistoryUri;
  lineCount: number;
  isDirty: boolean;
}

export interface SymbolHistoryUri {
  scheme: string;
  fsPath: string;
}

export interface SymbolHistoryCancellationToken {
  isCancellationRequested: boolean;
  onCancellationRequested(listener: () => void): { dispose(): void };
}

export interface SymbolHistoryRange {
  start: SymbolHistoryPosition;
  end: SymbolHistoryPosition;
}

export interface SymbolHistoryPosition {
  line: number;
  character: number;
}

export interface SymbolHistoryDocumentSymbol {
  name: string;
  range: SymbolHistoryRange;
  selectionRange?: SymbolHistoryRange;
  children?: readonly SymbolHistoryDocumentSymbol[];
}

export interface SymbolHistorySymbolInformation {
  name: string;
  location: {
    uri?: SymbolHistoryUri;
    range: SymbolHistoryRange;
  };
}

export type SymbolHistorySymbol = SymbolHistoryDocumentSymbol | SymbolHistorySymbolInformation;

interface SymbolHistoryCommand {
  command: string;
  title: string;
  arguments?: unknown[];
}

interface SymbolHistoryLensData {
  target: SymbolHistoryLensTarget;
  symbol: SymbolHistoryLensSymbol;
}

interface SymbolHistoryLensTarget {
  repositoryId: string;
  epoch: number;
  generation: number;
  path: string;
  contextValue: string;
  resourceUri: SymbolHistoryUri;
}

interface SymbolHistoryLensSymbol {
  name: string;
  lineStart: number;
  lineLimit: number;
  lensLine: number;
}

interface ResourceMatch {
  session: RepositorySession;
  lookup: ScmProjectedResourceLookup;
  rootLength: number;
}

const MAX_SYMBOL_BLAME_LINES = 5000;
const DELETED_STATUS_TOKENS = new Set(["deleted", "missing"]);
const UNSAFE_LOCAL_STATUS_TOKENS = new Set(["added", "replaced", "obstructed", "incomplete", "conflicted", "unversioned"]);

export class SymbolHistoryCodeLensProvider<TCodeLens extends SymbolHistoryCodeLens = SymbolHistoryCodeLens> {
  private readonly emitter: SymbolHistoryCodeLensEventEmitter;

  public constructor(private readonly options: SymbolHistoryCodeLensProviderOptions<TCodeLens>) {
    this.emitter = options.api.createEventEmitter();
  }

  public get onDidChangeCodeLenses(): vscode.Event<void> {
    return this.emitter.event;
  }

  public async provideCodeLenses(
    document: SymbolHistoryTextDocument,
    token: SymbolHistoryCancellationToken,
  ): Promise<TCodeLens[]> {
    const target = this.targetForDocument(document);
    if (!target || token.isCancellationRequested) {
      return [];
    }

    let symbols: readonly SymbolHistorySymbol[] | undefined;
    try {
      symbols = await this.options.api.executeDocumentSymbols(document.uri);
    } catch (_error) {
      return [];
    }
    if (!symbols || token.isCancellationRequested) {
      return [];
    }

    return flattenSymbols(document, symbols)
      .map((symbol) => lensSymbolFromSymbol(document, symbol))
      .filter((symbol): symbol is SymbolHistoryLensSymbol => symbol !== undefined)
      .map((symbol) => {
        const range = this.options.api.createRange(symbol.lensLine, 0, symbol.lensLine, 0);
        const lens = this.options.api.createCodeLens(range);
        setLensData(lens, { target, symbol });
        return lens;
      });
  }

  public async resolveCodeLens(
    lens: TCodeLens,
    token: SymbolHistoryCancellationToken,
  ): Promise<TCodeLens> {
    if (token.isCancellationRequested || lens.command) {
      return lens;
    }
    const data = lensData(lens);
    if (!data) {
      return lens;
    }
    if (!this.options.workspaceTrusted()) {
      return lens;
    }

    const cancellation = cancellationFromToken(token);
    try {
      const aggregate = await this.resolveAggregate(data, token, cancellation.signal);
      if (!aggregate || token.isCancellationRequested) {
        return lens;
      }
      lens.command = commandForAggregate(data, aggregate, this.options.api.localize);
      return lens;
    } finally {
      cancellation.dispose();
    }
  }

  public refresh(): void {
    this.emitter.fire();
  }

  public dispose(): void {
    this.emitter.dispose();
  }

  private async resolveAggregate(
    data: SymbolHistoryLensData,
    token: SymbolHistoryCancellationToken,
    signal: AbortSignal,
  ): Promise<SymbolHistoryAggregate | undefined> {
    let blame;
    try {
      const remote = await this.options.createRemoteEnvelope({
        repositoryId: data.target.repositoryId,
        epoch: data.target.epoch,
      });
      if (signal.aborted) {
        return undefined;
      }
      blame = await this.options.historyClient.getBlame(
        {
          repositoryId: data.target.repositoryId,
          epoch: data.target.epoch,
          path: data.target.path,
          pegRevision: "base",
          startRevision: "r0",
          endRevision: "base",
          lineStart: data.symbol.lineStart,
          lineLimit: data.symbol.lineLimit,
          ignoreWhitespace: "none",
          ignoreEolStyle: false,
          ignoreMimeType: false,
          includeMergedRevisions: this.options.includeMergedRevisions(),
          ...(remote === undefined ? {} : { remote }),
        },
        { signal },
      );
    } catch (_error) {
      return undefined;
    }
    if (token.isCancellationRequested || blame.hasMore) {
      return undefined;
    }
    return aggregateBlameWindow(data.symbol, blame.lines);
  }

  private targetForDocument(document: SymbolHistoryTextDocument): SymbolHistoryLensTarget | undefined {
    if (!this.options.workspaceTrusted()) {
      return undefined;
    }
    const settings = this.options.settings();
    if (
      !settings.enabled ||
      !settings.symbols ||
      !isFileDocument(document) ||
      document.isDirty ||
      document.lineCount > settings.maxFileLines
    ) {
      return undefined;
    }
    const match = this.matchDocument(document.uri.fsPath);
    if (!match || match.lookup.epoch !== match.session.epoch || match.lookup.repositoryId !== match.session.repositoryId) {
      return undefined;
    }
    const resource = match.lookup.resource;
    if (!isSymbolHistoryResource(resource)) {
      return undefined;
    }
    return {
      repositoryId: match.session.repositoryId,
      epoch: match.session.epoch,
      generation: match.lookup.generation,
      path: resource.path,
      contextValue: resource.contextValue,
      resourceUri: document.uri,
    };
  }

  private matchDocument(fsPath: string): ResourceMatch | undefined {
    return this.options.sessionService
      .listOpenSessions()
      .flatMap((session) => {
        const relativePath = repositoryRelativePath(session, fsPath);
        const lookup = relativePath
          ? this.options.sourceControlProjection.getProjectedResource(
              session.repositoryId,
              relativePath,
              session.watchScope.pathCase,
            )
          : undefined;
        return lookup ? [{ session, lookup, rootLength: rootKey(session).length }] : [];
      })
      .sort(
        (left, right) =>
          right.rootLength - left.rootLength ||
          left.session.repositoryId.localeCompare(right.session.repositoryId),
      )[0];
  }
}

function cancellationFromToken(token: SymbolHistoryCancellationToken): {
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

interface SymbolHistoryAggregate {
  latestRevision: number;
  authorCount: number;
  revisionCount: number;
}

function setLensData(lens: SymbolHistoryCodeLens, data: SymbolHistoryLensData): void {
  (lens as SymbolHistoryCodeLens & { subversionrSymbolHistoryLens?: SymbolHistoryLensData }).subversionrSymbolHistoryLens =
    data;
}

function lensData(lens: SymbolHistoryCodeLens): SymbolHistoryLensData | undefined {
  return (lens as SymbolHistoryCodeLens & { subversionrSymbolHistoryLens?: SymbolHistoryLensData })
    .subversionrSymbolHistoryLens;
}

function commandForAggregate(
  data: SymbolHistoryLensData,
  aggregate: SymbolHistoryAggregate,
  localize: (message: string, ...args: unknown[]) => string,
): SymbolHistoryCommand {
  return {
    command: "subversionr.showBlame",
    title: localize(
      "SVN r{0} - Authors {1}, Revisions {2}",
      aggregate.latestRevision,
      aggregate.authorCount,
      aggregate.revisionCount,
    ),
    arguments: [
      {
        contextValue: data.target.contextValue,
        subversionrResourceKind: "file",
        subversionrProjectionGeneration: data.target.generation,
        resourceUri: data.target.resourceUri,
      },
    ],
  };
}

function aggregateBlameWindow(
  symbol: SymbolHistoryLensSymbol,
  lines: readonly HistoryBlameLine[],
): SymbolHistoryAggregate | undefined {
  if (lines.length !== symbol.lineLimit) {
    return undefined;
  }
  const revisions = new Set<number>();
  const authors = new Set<string>();
  for (let index = 0; index < symbol.lineLimit; index += 1) {
    const line = lines[index];
    if (!line || line.lineNumber !== symbol.lineStart + index || line.localChange || line.revision === null) {
      return undefined;
    }
    revisions.add(line.revision);
    authors.add(line.author ?? "");
  }
  if (revisions.size === 0) {
    return undefined;
  }
  return {
    latestRevision: Math.max(...revisions),
    authorCount: authors.size,
    revisionCount: revisions.size,
  };
}

function flattenSymbols(
  document: SymbolHistoryTextDocument,
  symbols: readonly SymbolHistorySymbol[],
): SymbolHistoryDocumentSymbol[] {
  const flattened: SymbolHistoryDocumentSymbol[] = [];
  for (const symbol of symbols) {
    if (isDocumentSymbol(symbol)) {
      flattened.push(symbol);
      flattened.push(...flattenSymbols(document, symbol.children ?? []));
    } else if (isCurrentDocumentSymbolInformation(document, symbol)) {
      flattened.push({
        name: symbol.name,
        range: symbol.location.range,
        selectionRange: symbol.location.range,
        children: [],
      });
    }
  }
  return flattened;
}

function lensSymbolFromSymbol(
  document: SymbolHistoryTextDocument,
  symbol: SymbolHistoryDocumentSymbol,
): SymbolHistoryLensSymbol | undefined {
  if (!validSymbolRange(document, symbol.range)) {
    return undefined;
  }
  const selectionRange = validSymbolRange(document, symbol.selectionRange) ? symbol.selectionRange : symbol.range;
  const lineLimit = symbol.range.end.line - symbol.range.start.line + 1;
  if (lineLimit > MAX_SYMBOL_BLAME_LINES) {
    return undefined;
  }
  return {
    name: symbol.name,
    lineStart: symbol.range.start.line + 1,
    lineLimit,
    lensLine: selectionRange.start.line,
  };
}

function isDocumentSymbol(symbol: SymbolHistorySymbol): symbol is SymbolHistoryDocumentSymbol {
  return "range" in symbol;
}

function isCurrentDocumentSymbolInformation(
  document: SymbolHistoryTextDocument,
  symbol: SymbolHistorySymbolInformation,
): boolean {
  const uri = symbol.location.uri;
  return !uri || (uri.scheme === document.uri.scheme && normalizeAbsolutePath(uri.fsPath) === normalizeAbsolutePath(document.uri.fsPath));
}

function validSymbolRange(document: SymbolHistoryTextDocument, range: SymbolHistoryRange | undefined): range is SymbolHistoryRange {
  return (
    range !== undefined &&
    Number.isSafeInteger(range.start.line) &&
    Number.isSafeInteger(range.start.character) &&
    Number.isSafeInteger(range.end.line) &&
    Number.isSafeInteger(range.end.character) &&
    range.start.line >= 0 &&
    range.end.line >= range.start.line &&
    range.end.line < document.lineCount
  );
}

function isFileDocument(document: SymbolHistoryTextDocument): boolean {
  return (
    document.uri.scheme === "file" &&
    typeof document.uri.fsPath === "string" &&
    document.uri.fsPath.length > 0 &&
    Number.isSafeInteger(document.lineCount) &&
    document.lineCount > 0
  );
}

function isSymbolHistoryResource(resource: ScmProjectedResource): boolean {
  return (
    resource.source === "local" &&
    (resource.groupId === "changes" || isChangelistResourceGroupId(resource.groupId)) &&
    resource.contextValue === "subversionr.changedFile" &&
    resource.entry.kind === "file" &&
    !resource.entry.external &&
    resource.entry.localStatus !== "ignored" &&
    !hasDeletedStatus(resource) &&
    !hasUnsafeLocalStatus(resource) &&
    resource.entry.nodeStatus === "normal" &&
    resource.entry.textStatus === "normal"
  );
}

function hasDeletedStatus(resource: ScmProjectedResource): boolean {
  return [resource.entry.localStatus, resource.entry.nodeStatus, resource.entry.textStatus].some((status) =>
    DELETED_STATUS_TOKENS.has(status),
  );
}

function hasUnsafeLocalStatus(resource: ScmProjectedResource): boolean {
  return UNSAFE_LOCAL_STATUS_TOKENS.has(resource.entry.localStatus);
}

function repositoryRelativePath(session: RepositorySession, fsPath: string): string | undefined {
  const root = normalizeAbsolutePath(session.identity.workingCopyRoot);
  const candidate = normalizeAbsolutePath(fsPath);
  const pathCase = session.watchScope.pathCase;
  const rootComparison = comparisonKey(pathCase, root);
  const candidateComparison = comparisonKey(pathCase, candidate);
  if (candidateComparison === rootComparison) {
    return undefined;
  }
  if (!candidateComparison.startsWith(`${rootComparison}/`)) {
    return undefined;
  }
  const relative = candidate.slice(root.length + 1);
  return isRepositoryRelativeFilePath(relative) ? relative.replaceAll("\\", "/") : undefined;
}

function rootKey(session: RepositorySession): string {
  return comparisonKey(session.watchScope.pathCase, normalizeAbsolutePath(session.identity.workingCopyRoot));
}

function isRepositoryRelativeFilePath(path: string): boolean {
  if (path.trim().length === 0 || path.includes("\\") || path.startsWith("/") || path.endsWith("/")) {
    return false;
  }
  const parts = path.split("/");
  return !parts.some((part) => part.length === 0 || part === "." || part === ".." || part === ".svn");
}

function normalizeAbsolutePath(path: string): string {
  return path.replaceAll("\\", "/").replace(/\/+$/u, "");
}

function comparisonKey(pathCase: PathCasePolicy, path: string): string {
  return pathCase === "case-insensitive" ? path.toLocaleLowerCase("en-US") : path;
}
