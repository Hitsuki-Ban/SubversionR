import type { HistoryBlameClient, HistoryBlameLine } from "../history/historyBlameRpcClient";
import type { HistoryClient as HistoryLogClient } from "../history/historyLogRpcClient";
import type { RepositorySession, RepositorySessionService } from "../repository/repositorySessionService";
import type { SourceControlProjectionService } from "../scm/sourceControlProjectionService";
import type { ScmProjectedResource, ScmProjectedResourceLookup } from "../scm/sourceControlResourceStore";
import type { PathCasePolicy } from "../status/types";
import type { LensSettings } from "./lensSettings";
import { isChangelistResourceGroupId } from "../scm/resourceStateClassifier";
import type { RemoteOperationEnvelope } from "../security/remoteAccessProfile";

export interface CurrentLineBlameHoverProviderOptions<THover, TMarkdownString> {
  settings(): LensSettings;
  includeMergedRevisions(): boolean;
  historyClient: HistoryBlameClient & HistoryLogClient;
  createRemoteEnvelope(input: { repositoryId: string; epoch: number }): Promise<RemoteOperationEnvelope | undefined>;
  sessionService: Pick<RepositorySessionService, "listOpenSessions">;
  sourceControlProjection: Pick<SourceControlProjectionService, "getProjectedResource">;
  workspaceTrusted(): boolean;
  api: CurrentLineBlameHoverApi<THover, TMarkdownString>;
}

export interface CurrentLineBlameHoverApi<THover, TMarkdownString> {
  createMarkdownString(value: string): TMarkdownString;
  createHover(contents: readonly TMarkdownString[]): THover;
  localize(message: string, ...args: unknown[]): string;
}

export interface CurrentLineBlameHoverTextDocument {
  uri: {
    scheme: string;
    fsPath: string;
  };
  lineCount: number;
  isDirty: boolean;
}

export interface CurrentLineBlameHoverPosition {
  line: number;
}

export interface CurrentLineBlameHoverCancellationToken {
  isCancellationRequested: boolean;
  onCancellationRequested(listener: () => void): { dispose(): void };
}

interface ResourceMatch {
  session: RepositorySession;
  lookup: ScmProjectedResourceLookup;
  rootLength: number;
}

interface CurrentLineBlameHoverTarget {
  repositoryId: string;
  epoch: number;
  path: string;
  lineStart: number;
}

const DELETED_STATUS_TOKENS = new Set(["deleted", "missing"]);
const UNSAFE_LOCAL_STATUS_TOKENS = new Set(["added", "replaced", "obstructed", "incomplete", "conflicted", "unversioned"]);

export class CurrentLineBlameHoverProvider<THover, TMarkdownString> {
  public constructor(private readonly options: CurrentLineBlameHoverProviderOptions<THover, TMarkdownString>) {}

  public async provideHover(
    document: CurrentLineBlameHoverTextDocument,
    position: CurrentLineBlameHoverPosition,
    token: CurrentLineBlameHoverCancellationToken,
  ): Promise<THover | undefined> {
    const cancellation = cancellationFromToken(token);
    try {
      return await this.provideHoverUnchecked(document, position, token, cancellation.signal);
    } catch (_error) {
      return undefined;
    } finally {
      cancellation.dispose();
    }
  }

  private async provideHoverUnchecked(
    document: CurrentLineBlameHoverTextDocument,
    position: CurrentLineBlameHoverPosition,
    token: CurrentLineBlameHoverCancellationToken,
    signal: AbortSignal,
  ): Promise<THover | undefined> {
    if (token.isCancellationRequested) {
      return undefined;
    }
    const target = this.targetForDocument(document, position);
    if (!target) {
      return undefined;
    }
    const includeMergedRevisions = this.options.includeMergedRevisions();
    const blameRemote = await this.options.createRemoteEnvelope({
      repositoryId: target.repositoryId,
      epoch: target.epoch,
    });
    if (signal.aborted) {
      return undefined;
    }

    const blame = await this.options.historyClient.getBlame(
      {
        repositoryId: target.repositoryId,
        epoch: target.epoch,
        path: target.path,
        pegRevision: "base",
        startRevision: "r0",
        endRevision: "base",
        lineStart: target.lineStart,
        lineLimit: 1,
        ignoreWhitespace: "none",
        ignoreEolStyle: false,
        ignoreMimeType: false,
        includeMergedRevisions,
        ...(blameRemote === undefined ? {} : { remote: blameRemote }),
      },
      { signal },
    );
    if (token.isCancellationRequested) {
      return undefined;
    }

    const [line] = blame.lines;
    if (!line || line.localChange || line.revision === null) {
      return undefined;
    }
    const revision = `r${line.revision}`;
    const logRemote = await this.options.createRemoteEnvelope({
      repositoryId: target.repositoryId,
      epoch: target.epoch,
    });
    if (signal.aborted) {
      return undefined;
    }
    const log = await this.options.historyClient.getLog(
      {
        repositoryId: target.repositoryId,
        epoch: target.epoch,
        path: target.path,
        startRevision: revision,
        endRevision: revision,
        limit: 1,
        discoverChangedPaths: false,
        strictNodeHistory: false,
        includeMergedRevisions,
        ...(logRemote === undefined ? {} : { remote: logRemote }),
      },
      { signal },
    );
    if (token.isCancellationRequested) {
      return undefined;
    }

    const [entry] = log.entries;
    if (!entry || entry.revision !== line.revision) {
      return undefined;
    }
    const logSummary = firstLogMessageLine(entry.message, this.options.api.localize);
    return this.options.api.createHover([
      this.options.api.createMarkdownString(renderHoverMarkdown(target, line, logSummary, this.options.api.localize)),
    ]);
  }

  private targetForDocument(
    document: CurrentLineBlameHoverTextDocument,
    position: CurrentLineBlameHoverPosition,
  ): CurrentLineBlameHoverTarget | undefined {
    if (!this.options.workspaceTrusted()) {
      return undefined;
    }
    const settings = this.options.settings();
    if (!settings.enabled || !settings.hover) {
      return undefined;
    }
    if (
      !isFileDocument(document) ||
      document.isDirty ||
      document.lineCount > settings.maxFileLines ||
      !Number.isSafeInteger(position.line) ||
      position.line < 0 ||
      position.line >= document.lineCount
    ) {
      return undefined;
    }
    const match = this.matchDocument(document.uri.fsPath);
    if (!match || match.lookup.epoch !== match.session.epoch || match.lookup.repositoryId !== match.session.repositoryId) {
      return undefined;
    }
    const resource = match.lookup.resource;
    if (!isCurrentLineBlameHoverResource(resource)) {
      return undefined;
    }
    return {
      repositoryId: match.session.repositoryId,
      epoch: match.session.epoch,
      path: resource.path,
      lineStart: position.line + 1,
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

function cancellationFromToken(token: CurrentLineBlameHoverCancellationToken): {
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

function renderHoverMarkdown(
  target: CurrentLineBlameHoverTarget,
  line: HistoryBlameLine,
  logSummary: string,
  localize: (message: string, ...args: unknown[]) => string,
): string {
  const pathLine = `${target.path}:${line.lineNumber}`;
  return [
    `**${escapeMarkdown(localize("SVN Blame: {0}", pathLine))}**`,
    escapeMarkdown(localize("Revision {0}", `r${line.revision}`)),
    escapeMarkdown(localize("Author: {0}", line.author ?? localize("Unknown author"))),
    escapeMarkdown(localize("Date: {0}", line.date ?? localize("Unknown date"))),
    escapeMarkdown(localize("Log Message:")),
    escapeMarkdown(logSummary),
  ].join("\n\n");
}

function firstLogMessageLine(
  message: string | null,
  localize: (message: string, ...args: unknown[]) => string,
): string {
  for (const rawLine of message?.split("\n") ?? []) {
    const trimmed = rawLine.replace(/\r$/u, "").trim();
    if (trimmed.length > 0) {
      return trimmed;
    }
  }
  return localize("No log message");
}

function isFileDocument(document: CurrentLineBlameHoverTextDocument): boolean {
  return (
    document.uri.scheme === "file" &&
    typeof document.uri.fsPath === "string" &&
    document.uri.fsPath.length > 0 &&
    Number.isSafeInteger(document.lineCount) &&
    document.lineCount > 0
  );
}

function isCurrentLineBlameHoverResource(resource: ScmProjectedResource): boolean {
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

function escapeMarkdown(value: string): string {
  return value.replace(/[\\`*_{}\[\]()#+\-.!|<>]/gu, "\\$&");
}
