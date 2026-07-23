import type { HistoryBlame, HistoryBlameClient } from "./historyBlameRpcClient";
import type { HistoryClient as HistoryLogClient, HistoryLogEntry } from "./historyLogRpcClient";
import type { HistoryViewTarget } from "./historyViewTarget";
import type { LensSettings } from "../lens/lensSettings";
import type { RepositorySession, RepositorySessionService } from "../repository/repositorySessionService";
import { isChangelistResourceGroupId } from "../scm/resourceStateClassifier";
import type { SourceControlProjectionService } from "../scm/sourceControlProjectionService";
import type {
  ScmProjectedResource,
  ScmProjectedResourceLookup,
  ScmRepositoryProjection,
} from "../scm/sourceControlResourceStore";
import { requireTrustedWorkspace } from "../security/workspaceTrust";
import type { RemoteOperationEnvelope } from "../security/remoteAccessProfile";
import type { PathCasePolicy } from "../status/types";

export interface LineHistoryCommandControllerOptions {
  settings(): LensSettings;
  includeMergedRevisions(): boolean;
  historyClient: HistoryBlameClient & HistoryLogClient;
  createRemoteEnvelope(input: { repositoryId: string; epoch: number }): Promise<RemoteOperationEnvelope | undefined>;
  sessionService: Pick<RepositorySessionService, "listOpenSessions">;
  sourceControlProjection: Pick<SourceControlProjectionService, "getProjectedResource" | "getProjection">;
  workspaceTrusted(): boolean;
  diagnostics: {
    recordFailure(operation: string, error: unknown): void;
    show(): void;
  };
  ui: LineHistoryCommandUi;
  localize(message: string, ...args: unknown[]): string;
}

export interface LineHistoryCommandUi {
  activeTextEditor(): LineHistoryActiveEditor | undefined;
  showLineHistory(target: HistoryViewTarget, entries: readonly HistoryLogEntry[]): Promise<void>;
  showErrorMessage(message: string, ...actions: string[]): Promise<unknown>;
}

export interface LineHistoryActiveEditor {
  document: LineHistoryTextDocument;
  selection: LineHistorySelection;
}

export interface LineHistoryTextDocument {
  uri: {
    scheme: string;
    fsPath: string;
  };
  lineCount: number;
  isDirty: boolean;
}

export interface LineHistorySelection {
  start: {
    line: number;
  };
  end: {
    line: number;
  };
}

interface ResourceMatch {
  session: RepositorySession;
  lookup: ScmProjectedResourceLookup;
  relativePath: string;
  rootLength: number;
}

interface LineHistoryTarget {
  repositoryId: string;
  epoch: number;
  path: string;
  lineStart: number;
  lineLimit: number;
}

const MAX_LINE_HISTORY_LINE_LIMIT = 5_000;
const MAX_LINE_HISTORY_REVISION_COUNT = 500;
const DELETED_STATUS_TOKENS = new Set(["deleted", "missing"]);
const UNSAFE_LOCAL_STATUS_TOKENS = new Set(["added", "replaced", "obstructed", "incomplete", "conflicted", "unversioned"]);

export class LineHistoryCommandController {
  private activeRequest: AbortController | undefined;

  public constructor(private readonly options: LineHistoryCommandControllerOptions) {}

  public async showLineHistory(): Promise<void> {
    this.activeRequest?.abort();
    const controller = new AbortController();
    this.activeRequest = controller;
    try {
      requireTrustedWorkspace(this.options.workspaceTrusted);
      const target = this.targetForActiveEditor();
      const includeMergedRevisions = this.options.includeMergedRevisions();
      const blameRemote = await this.options.createRemoteEnvelope({
        repositoryId: target.repositoryId,
        epoch: target.epoch,
      });
      controller.signal.throwIfAborted();
      const blame = await this.options.historyClient.getBlame(
        {
          repositoryId: target.repositoryId,
          epoch: target.epoch,
          path: target.path,
          pegRevision: "base",
          startRevision: "r0",
          endRevision: "base",
          lineStart: target.lineStart,
          lineLimit: target.lineLimit,
          ignoreWhitespace: "none",
          ignoreEolStyle: false,
          ignoreMimeType: false,
          includeMergedRevisions,
          ...(blameRemote === undefined ? {} : { remote: blameRemote }),
        },
        { signal: controller.signal },
      );
      const revisions = concreteLineRevisions(blame, target);
      const entries: HistoryLogEntry[] = [];
      for (const revision of revisions) {
        const revisionId = `r${revision}`;
        const remote = await this.options.createRemoteEnvelope({
          repositoryId: target.repositoryId,
          epoch: target.epoch,
        });
        controller.signal.throwIfAborted();
        const log = await this.options.historyClient.getLog(
          {
            repositoryId: target.repositoryId,
            epoch: target.epoch,
            path: target.path,
            startRevision: revisionId,
            endRevision: revisionId,
            limit: 1,
            discoverChangedPaths: false,
            strictNodeHistory: false,
            includeMergedRevisions,
            ...(remote === undefined ? {} : { remote }),
          },
          { signal: controller.signal },
        );
        const [entry] = log.entries;
        if (!entry || entry.revision !== revision) {
          throw lineHistoryLogIncomplete();
        }
        entries.push(entry);
      }

      await this.options.ui.showLineHistory(lineHistoryViewTarget(target), entries);
    } catch (error) {
      if (controller.signal.aborted) {
        return;
      }
      this.options.diagnostics.recordFailure("Line History", error);
      const showLog = this.options.localize("Show Log");
      void this.options.ui
        .showErrorMessage(
          this.options.localize(
            "SVN {0} failed. Open the SubversionR log for details.",
            this.options.localize("History"),
          ),
          showLog,
        )
        .then((selected) => {
          if (selected === showLog) {
            this.options.diagnostics.show();
          }
        })
        .catch((notificationError: unknown) => {
          console.error("SubversionR line history notification failed.", notificationError);
        });
    } finally {
      if (this.activeRequest === controller) {
        this.activeRequest = undefined;
      }
    }
  }

  private targetForActiveEditor(): LineHistoryTarget {
    const editor = this.options.ui.activeTextEditor();
    if (!editor || !isFileDocument(editor.document)) {
      throw invalidLineHistoryTarget();
    }
    const settings = this.options.settings();
    if (!settings.enabled || editor.document.isDirty || editor.document.lineCount > settings.maxFileLines) {
      throw invalidLineHistoryTarget();
    }
    const range = selectionLineRange(editor.selection, editor.document.lineCount);
    const match = this.matchDocument(editor.document.uri.fsPath);
    const projection = match
      ? this.options.sourceControlProjection.getProjection(match.session.repositoryId)
      : undefined;
    if (!match || !projection || !isCurrentResourceMatch(match, projection)) {
      throw invalidLineHistoryTarget();
    }
    const resource = match.lookup.resource;
    if (!isLineHistoryResource(resource)) {
      throw invalidLineHistoryTarget();
    }
    return {
      repositoryId: match.session.repositoryId,
      epoch: match.session.epoch,
      path: resource.path,
      lineStart: range.lineStart,
      lineLimit: range.lineLimit,
    };
  }

  private matchDocument(fsPath: string): ResourceMatch | undefined {
    const match = this.options.sessionService
      .listOpenSessions()
      .flatMap((session) => {
        const relativePath = repositoryRelativePath(session, fsPath);
        return relativePath ? [{ session, relativePath, rootLength: rootKey(session).length }] : [];
      })
      .sort(
        (left, right) =>
          right.rootLength - left.rootLength ||
          left.session.repositoryId.localeCompare(right.session.repositoryId),
      )[0];
    if (!match) {
      return undefined;
    }
    const lookup = this.options.sourceControlProjection.getProjectedResource(
      match.session.repositoryId,
      match.relativePath,
      match.session.watchScope.pathCase,
    );
    return lookup ? { ...match, lookup } : undefined;
  }
}

function isCurrentResourceMatch(match: ResourceMatch, projection: ScmRepositoryProjection): boolean {
  const { lookup, relativePath, session } = match;
  const pathCase = session.watchScope.pathCase;
  return (
    projection.repositoryId === session.repositoryId &&
    projection.epoch === session.epoch &&
    projection.generation === lookup.generation &&
    projection.freshness.repositoryCompleteness !== "stale" &&
    lookup.repositoryId === session.repositoryId &&
    lookup.epoch === session.epoch &&
    lookup.resource.repositoryId === session.repositoryId &&
    lookup.resource.entry.generation === lookup.generation &&
    absolutePathKey(pathCase, projection.workingCopyRoot) === absolutePathKey(pathCase, session.identity.workingCopyRoot) &&
    absolutePathKey(pathCase, lookup.workingCopyRoot) === absolutePathKey(pathCase, session.identity.workingCopyRoot) &&
    comparisonKey(pathCase, lookup.resource.path) === comparisonKey(pathCase, relativePath)
  );
}

function absolutePathKey(pathCase: PathCasePolicy, path: string): string {
  return comparisonKey(pathCase, normalizeAbsolutePath(path));
}

function selectionLineRange(selection: LineHistorySelection, lineCount: number): { lineStart: number; lineLimit: number } {
  const startLine = selection.start.line;
  const endLine = selection.end.line;
  if (!Number.isSafeInteger(startLine) || !Number.isSafeInteger(endLine)) {
    throw invalidLineHistorySelection();
  }
  const firstLine = Math.min(startLine, endLine);
  const lastLine = Math.max(startLine, endLine);
  if (firstLine < 0 || lastLine < firstLine || lastLine >= lineCount) {
    throw invalidLineHistorySelection();
  }
  const lineLimit = lastLine - firstLine + 1;
  if (lineLimit < 1 || lineLimit > MAX_LINE_HISTORY_LINE_LIMIT) {
    throw invalidLineHistorySelection();
  }
  return {
    lineStart: firstLine + 1,
    lineLimit,
  };
}

function concreteLineRevisions(blame: HistoryBlame, target: LineHistoryTarget): number[] {
  if (blame.lines.length !== target.lineLimit) {
    throw lineHistoryBlameIncomplete();
  }
  const revisions = new Set<number>();
  for (let index = 0; index < target.lineLimit; index += 1) {
    const line = blame.lines[index];
    if (!line || line.lineNumber !== target.lineStart + index || line.localChange || line.revision === null) {
      throw lineHistoryBlameIncomplete();
    }
    revisions.add(line.revision);
  }
  if (revisions.size === 0) {
    throw lineHistoryBlameIncomplete();
  }
  if (revisions.size > MAX_LINE_HISTORY_REVISION_COUNT) {
    throw lineHistoryRevisionLimitExceeded();
  }
  return [...revisions].sort((left, right) => right - left);
}

function lineHistoryViewTarget(target: LineHistoryTarget): HistoryViewTarget {
  const lineEnd = target.lineStart + target.lineLimit - 1;
  const label = target.lineLimit === 1 ? `${target.path}:${target.lineStart}` : `${target.path}:${target.lineStart}-${lineEnd}`;
  return {
    kind: "line",
    repositoryId: target.repositoryId,
    epoch: target.epoch,
    path: target.path,
    label,
    lineStart: target.lineStart,
    lineEnd,
  };
}

function isFileDocument(document: LineHistoryTextDocument): boolean {
  return (
    document.uri.scheme === "file" &&
    typeof document.uri.fsPath === "string" &&
    document.uri.fsPath.length > 0 &&
    Number.isSafeInteger(document.lineCount) &&
    document.lineCount > 0
  );
}

function isLineHistoryResource(resource: ScmProjectedResource): boolean {
  return (
    resource.source === "local" &&
    (resource.groupId === "changes" || isChangelistResourceGroupId(resource.groupId)) &&
    resource.contextValue === "subversionr.changedFile" &&
    resource.entry.kind === "file" &&
    !resource.entry.external &&
    resource.entry.localStatus !== "ignored" &&
    !hasDeletedStatus(resource) &&
    !hasUnsafeLocalStatus(resource) &&
    hasTextStableNodeStatus(resource) &&
    resource.entry.textStatus === "normal"
  );
}

function hasTextStableNodeStatus(resource: ScmProjectedResource): boolean {
  return (
    resource.entry.nodeStatus === "normal" ||
    (resource.entry.nodeStatus === "modified" && resource.entry.propertyStatus === "modified")
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

class LineHistoryCommandError extends Error {
  public constructor(
    public readonly code: string,
    public readonly category: "input" | "protocol" | "lifecycle",
    public readonly messageKey: string,
    public readonly safeArgs: Record<string, unknown> = {},
  ) {
    super(code);
    this.name = "LineHistoryCommandError";
  }
}

function invalidLineHistoryTarget(): LineHistoryCommandError {
  return new LineHistoryCommandError(
    "SUBVERSIONR_LINE_HISTORY_TARGET_INVALID",
    "input",
    "error.history.lineTargetInvalid",
  );
}

function invalidLineHistorySelection(): LineHistoryCommandError {
  return new LineHistoryCommandError(
    "SUBVERSIONR_LINE_HISTORY_SELECTION_INVALID",
    "input",
    "error.history.lineSelectionInvalid",
  );
}

function lineHistoryBlameIncomplete(): LineHistoryCommandError {
  return new LineHistoryCommandError(
    "SUBVERSIONR_LINE_HISTORY_BLAME_INCOMPLETE",
    "protocol",
    "error.history.lineBlameIncomplete",
  );
}

function lineHistoryLogIncomplete(): LineHistoryCommandError {
  return new LineHistoryCommandError(
    "SUBVERSIONR_LINE_HISTORY_LOG_INCOMPLETE",
    "protocol",
    "error.history.lineLogIncomplete",
  );
}

function lineHistoryRevisionLimitExceeded(): LineHistoryCommandError {
  return new LineHistoryCommandError(
    "SUBVERSIONR_LINE_HISTORY_REVISION_LIMIT_EXCEEDED",
    "input",
    "error.history.lineRevisionLimitExceeded",
  );
}
