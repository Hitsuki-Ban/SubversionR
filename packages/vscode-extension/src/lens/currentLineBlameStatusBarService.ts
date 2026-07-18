import type { HistoryBlameClient, HistoryBlameLine } from "../history/historyBlameRpcClient";
import type { RepositorySession, RepositorySessionService } from "../repository/repositorySessionService";
import type { SourceControlProjectionService } from "../scm/sourceControlProjectionService";
import type { ScmProjectedResource, ScmProjectedResourceLookup } from "../scm/sourceControlResourceStore";
import type { PathCasePolicy } from "../status/types";
import type { LensSettings } from "./lensSettings";
import { isChangelistResourceGroupId } from "../scm/resourceStateClassifier";
import type { RemoteOperationEnvelope } from "../security/remoteAccessProfile";

export interface CurrentLineBlameStatusBarServiceOptions {
  settings(): LensSettings;
  includeMergedRevisions(): boolean;
  historyClient: HistoryBlameClient;
  createRemoteEnvelope(input: { repositoryId: string; epoch: number }): Promise<RemoteOperationEnvelope | undefined>;
  sessionService: Pick<RepositorySessionService, "listOpenSessions">;
  sourceControlProjection: Pick<SourceControlProjectionService, "getProjectedResource">;
  workspaceTrusted(): boolean;
  api: CurrentLineBlameStatusBarApi;
}

export interface CurrentLineBlameStatusBarApi {
  activeTextEditor(): CurrentLineBlameTextEditor | undefined;
  createStatusBarItem(): CurrentLineBlameStatusItem;
  localize(message: string, ...args: unknown[]): string;
  setTimeout(callback: () => void, delayMs: number): unknown;
  clearTimeout(handle: unknown): void;
}

export interface CurrentLineBlameTextEditor {
  document: {
    uri: CurrentLineBlameUri;
    lineCount: number;
    isDirty: boolean;
  };
  selection: {
    active: {
      line: number;
    };
  };
}

export interface CurrentLineBlameUri {
  scheme: string;
  fsPath: string;
}

export interface CurrentLineBlameStatusItem {
  text?: string;
  tooltip?: unknown;
  command?: unknown;
  show(): void;
  hide(): void;
  dispose(): void;
}

interface CurrentLineBlameCommand {
  command: string;
  title: string;
  arguments?: unknown[];
}

interface ResourceMatch {
  session: RepositorySession;
  lookup: ScmProjectedResourceLookup;
  rootLength: number;
}

interface CurrentLineBlameTarget {
  repositoryId: string;
  epoch: number;
  generation: number;
  path: string;
  lineStart: number;
  contextValue: string;
  resourceUri: CurrentLineBlameUri;
}

const DEBOUNCE_MS = 250;
const DELETED_STATUS_TOKENS = new Set(["deleted", "missing"]);
const UNSAFE_LOCAL_STATUS_TOKENS = new Set(["added", "replaced", "obstructed", "incomplete", "conflicted", "unversioned"]);

export class CurrentLineBlameStatusBarService {
  private readonly statusItem: CurrentLineBlameStatusItem;
  private pendingTimer: unknown | undefined;
  private pendingResolve: (() => void) | undefined;
  private refreshSerial = 0;
  private disposed = false;
  private activeRequest: AbortController | undefined;

  public constructor(private readonly options: CurrentLineBlameStatusBarServiceOptions) {
    this.statusItem = options.api.createStatusBarItem();
  }

  public refresh(): Promise<void> {
    const serial = ++this.refreshSerial;
    this.activeRequest?.abort();
    this.activeRequest = undefined;
    if (this.pendingTimer !== undefined) {
      this.options.api.clearTimeout(this.pendingTimer);
      this.pendingTimer = undefined;
      this.pendingResolve?.();
      this.pendingResolve = undefined;
    }

    let target: CurrentLineBlameTarget | undefined;
    try {
      target = this.targetForActiveEditor();
    } catch (_error) {
      this.hide();
      return Promise.resolve();
    }
    if (!target) {
      this.hide();
      return Promise.resolve();
    }
    const refreshTarget = target;

    return new Promise((resolve) => {
      this.pendingResolve = resolve;
      let firedSynchronously = false;
      const timer = this.options.api.setTimeout(() => {
        firedSynchronously = true;
        this.pendingTimer = undefined;
        this.pendingResolve = undefined;
        void this.refreshNow(serial, refreshTarget)
          .catch(() => {
            if (!this.disposed && serial === this.refreshSerial) {
              this.hide();
            }
          })
          .finally(resolve);
      }, DEBOUNCE_MS);
      if (!firedSynchronously) {
        this.pendingTimer = timer;
      }
    });
  }

  public dispose(): void {
    this.disposed = true;
    this.activeRequest?.abort();
    this.activeRequest = undefined;
    if (this.pendingTimer !== undefined) {
      this.options.api.clearTimeout(this.pendingTimer);
      this.pendingTimer = undefined;
    }
    this.pendingResolve?.();
    this.pendingResolve = undefined;
    this.statusItem.dispose();
  }

  private async refreshNow(serial: number, target: CurrentLineBlameTarget): Promise<void> {
    if (this.disposed || serial !== this.refreshSerial) {
      return;
    }

    this.statusItem.text = `$(loading~spin) ${this.options.api.localize("SVN blame")}`;
    this.statusItem.tooltip = this.options.api.localize("Loading SVN blame for {0}:{1}", target.path, target.lineStart);
    this.statusItem.command = undefined;
    this.statusItem.show();

    const controller = new AbortController();
    this.activeRequest = controller;
    const blame = await this.getCurrentLineBlame(target, serial, controller.signal);
    if (this.activeRequest === controller) {
      this.activeRequest = undefined;
    }
    if (!blame) {
      return;
    }
    if (this.disposed || serial !== this.refreshSerial) {
      return;
    }

    const [line] = blame.lines;
    if (!line || line.localChange || line.revision === null) {
      this.hide();
      return;
    }
    this.showBlameLine(target, line);
  }

  private async getCurrentLineBlame(
    target: CurrentLineBlameTarget,
    serial: number,
    signal: AbortSignal,
  ): Promise<Awaited<ReturnType<HistoryBlameClient["getBlame"]>> | undefined> {
    try {
      const remote = await this.options.createRemoteEnvelope({
        repositoryId: target.repositoryId,
        epoch: target.epoch,
      });
      signal.throwIfAborted();
      return await this.options.historyClient.getBlame(
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
          includeMergedRevisions: this.options.includeMergedRevisions(),
          ...(remote === undefined ? {} : { remote }),
        },
        { signal },
      );
    } catch (_error) {
      if (!this.disposed && serial === this.refreshSerial) {
        this.hide();
      }
      return undefined;
    }
  }

  private targetForActiveEditor(): CurrentLineBlameTarget | undefined {
    if (!this.options.workspaceTrusted()) {
      return undefined;
    }
    const settings = this.options.settings();
    if (!settings.enabled || !settings.currentLine) {
      return undefined;
    }
    const editor = this.options.api.activeTextEditor();
    if (
      !editor ||
      !isFileDocument(editor.document) ||
      editor.document.isDirty ||
      editor.document.lineCount > settings.maxFileLines
    ) {
      return undefined;
    }
    const activeLine = editor.selection.active.line;
    if (!Number.isSafeInteger(activeLine) || activeLine < 0 || activeLine >= editor.document.lineCount) {
      return undefined;
    }
    const match = this.matchDocument(editor.document.uri.fsPath);
    if (!match || match.lookup.epoch !== match.session.epoch || match.lookup.repositoryId !== match.session.repositoryId) {
      return undefined;
    }
    const resource = match.lookup.resource;
    if (!isCurrentLineBlameResource(resource)) {
      return undefined;
    }
    return {
      repositoryId: match.session.repositoryId,
      epoch: match.session.epoch,
      generation: match.lookup.generation,
      path: resource.path,
      lineStart: activeLine + 1,
      contextValue: resource.contextValue,
      resourceUri: editor.document.uri,
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

  private showBlameLine(target: CurrentLineBlameTarget, line: HistoryBlameLine): void {
    const author = line.author ?? this.options.api.localize("Unknown author");
    this.statusItem.text = `$(history) ${this.options.api.localize("SVN r{0} {1}", line.revision, author)}`;
    this.statusItem.tooltip = this.options.api.localize("SVN blame for {0}:{1}", target.path, line.lineNumber);
    this.statusItem.command = {
      command: "subversionr.showBlame",
      title: this.options.api.localize("Blame"),
      arguments: [
        {
          contextValue: target.contextValue,
          subversionrResourceKind: "file",
          subversionrProjectionGeneration: target.generation,
          resourceUri: target.resourceUri,
        },
      ],
    };
  }

  private hide(): void {
    this.statusItem.hide();
  }
}

function isFileDocument(document: CurrentLineBlameTextEditor["document"]): boolean {
  return (
    document.uri.scheme === "file" &&
    typeof document.uri.fsPath === "string" &&
    document.uri.fsPath.length > 0 &&
    Number.isSafeInteger(document.lineCount) &&
    document.lineCount > 0
  );
}

function isCurrentLineBlameResource(resource: ScmProjectedResource): boolean {
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
    !hasUnsafeTextStatus(resource)
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

function hasUnsafeTextStatus(resource: ScmProjectedResource): boolean {
  return resource.entry.textStatus !== "normal";
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
