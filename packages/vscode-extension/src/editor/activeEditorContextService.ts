import type { RepositorySession, RepositorySessionService } from "../repository/repositorySessionService";
import type { LensSettings } from "../lens/lensSettings";
import {
  BASE_DIFFABLE_FILE_CONTEXT_VALUE,
  isBaseDiffableProjectedResource,
} from "../scm/baseDiffResource";
import { isChangelistResourceGroupId } from "../scm/resourceStateClassifier";
import type { SourceControlProjectionService } from "../scm/sourceControlProjectionService";
import type {
  ScmProjectedResource,
  ScmProjectedResourceLookup,
  ScmRepositoryProjection,
} from "../scm/sourceControlResourceStore";
import type { PathCasePolicy } from "../status/types";

export const ACTIVE_EDITOR_HISTORY_FILE_CONTEXT = "subversionr.activeEditorHistoryFile";
export const ACTIVE_EDITOR_BASE_DIFFABLE_CONTEXT = "subversionr.activeEditorBaseDiffable";
export const ACTIVE_EDITOR_PREVIOUS_DIFFABLE_CONTEXT = "subversionr.activeEditorPreviousDiffable";
export const ACTIVE_EDITOR_LINE_HISTORY_FILE_CONTEXT = "subversionr.activeEditorLineHistoryFile";

export interface ActiveEditorContextServiceOptions {
  settings(): LensSettings;
  sessionService: Pick<RepositorySessionService, "listOpenSessions">;
  sourceControlProjection: Pick<SourceControlProjectionService, "getProjectedResource" | "getProjection">;
  api: ActiveEditorContextApi;
}

export interface ActiveEditorContextApi {
  activeTextDocument(): ActiveEditorTextDocument | undefined;
  setContext(key: string, value: boolean): Promise<void> | void;
}

export interface ActiveEditorTextDocument {
  uri: ActiveEditorUri;
  lineCount: number;
  isDirty: boolean;
}

export interface ActiveEditorUri {
  scheme: string;
  fsPath: string;
}

export interface ActiveEditorCommandTarget extends ActiveEditorUri {
  scheme: "file";
  subversionrProjectionGeneration: number;
}

interface ActiveEditorContextState {
  historyFile: boolean;
  baseDiffable: boolean;
  previousDiffable: boolean;
  lineHistoryFile: boolean;
}

interface ResourceMatch {
  session: RepositorySession;
  lookup: ScmProjectedResourceLookup;
  relativePath: string;
  rootLength: number;
}

interface ActiveEditorResolution {
  state: ActiveEditorContextState;
  commandTarget: ActiveEditorCommandTarget | undefined;
}

const FALSE_STATE: ActiveEditorContextState = {
  historyFile: false,
  baseDiffable: false,
  previousDiffable: false,
  lineHistoryFile: false,
};

export class ActiveEditorContextService {
  private refreshTail: Promise<void> = Promise.resolve();

  public constructor(private readonly options: ActiveEditorContextServiceOptions) {}

  public refresh(): Promise<void> {
    const refresh = this.refreshTail.then(() => this.applyCurrentContext());
    this.refreshTail = refresh.catch(() => undefined);
    return refresh;
  }

  private async applyCurrentContext(): Promise<void> {
    const { state } = this.resolveActiveEditor();
    await Promise.all([
      this.options.api.setContext(ACTIVE_EDITOR_HISTORY_FILE_CONTEXT, state.historyFile),
      this.options.api.setContext(ACTIVE_EDITOR_BASE_DIFFABLE_CONTEXT, state.baseDiffable),
      this.options.api.setContext(ACTIVE_EDITOR_PREVIOUS_DIFFABLE_CONTEXT, state.previousDiffable),
      this.options.api.setContext(ACTIVE_EDITOR_LINE_HISTORY_FILE_CONTEXT, state.lineHistoryFile),
    ]);
  }

  public commandTarget(): ActiveEditorCommandTarget | undefined {
    return this.resolveActiveEditor().commandTarget;
  }

  private resolveActiveEditor(): ActiveEditorResolution {
    const document = this.options.api.activeTextDocument();
    if (!document || !isFileDocument(document)) {
      return falseResolution();
    }
    const match = this.matchDocument(document.uri.fsPath);
    const projection = match
      ? this.options.sourceControlProjection.getProjection(match.session.repositoryId)
      : undefined;
    if (!match || !projection || !isCurrentResourceMatch(match, projection)) {
      return falseResolution();
    }
    const resource = match.lookup.resource;
    const historyFile = isHistoryFileProjectedResource(resource);
    const lineHistoryFile = isLineHistoryFileProjectedResource(resource, document, this.options.settings());
    return {
      state: {
        historyFile,
        baseDiffable: historyFile && isBaseDiffableProjectedResource(resource),
        previousDiffable: historyFile && isPreviousDiffableRevision(resource.entry.changedRevision),
        lineHistoryFile,
      },
      commandTarget: historyFile
        ? {
            scheme: "file",
            fsPath: document.uri.fsPath,
            subversionrProjectionGeneration: match.lookup.generation,
          }
        : undefined,
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

function falseResolution(): ActiveEditorResolution {
  return { state: FALSE_STATE, commandTarget: undefined };
}

function isCurrentResourceMatch(match: ResourceMatch, projection: ScmRepositoryProjection): boolean {
  const { lookup, relativePath, session } = match;
  const pathCase = session.watchScope.pathCase;
  return (
    projection.repositoryId === session.repositoryId &&
    projection.epoch === session.epoch &&
    projection.generation === lookup.generation &&
    projection.freshness.repositoryCompleteness !== "stale" &&
    lookup.epoch === session.epoch &&
    lookup.repositoryId === session.repositoryId &&
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

function isFileDocument(document: ActiveEditorTextDocument): boolean {
  return (
    document.uri.scheme === "file" &&
    typeof document.uri.fsPath === "string" &&
    document.uri.fsPath.length > 0 &&
    Number.isSafeInteger(document.lineCount) &&
    document.lineCount > 0
  );
}

function isHistoryFileProjectedResource(resource: ScmProjectedResource): boolean {
  return (
    resource.source === "local" &&
    resource.entry.kind === "file" &&
    (resource.groupId === "changes" ||
      resource.groupId === "conflicts" ||
      isChangelistResourceGroupId(resource.groupId)) &&
    !resource.entry.external &&
    resource.entry.localStatus !== "ignored" &&
    (resource.contextValue === "subversionr.changedFile" ||
      resource.contextValue === BASE_DIFFABLE_FILE_CONTEXT_VALUE ||
      resource.contextValue === "subversionr.conflicted")
  );
}

function isPreviousDiffableRevision(revision: number): boolean {
  return Number.isSafeInteger(revision) && revision > 0 && revision <= 2_147_483_647;
}

const DELETED_STATUS_TOKENS = new Set(["deleted", "missing"]);
const UNSAFE_LOCAL_STATUS_TOKENS = new Set(["added", "replaced", "obstructed", "incomplete", "conflicted", "unversioned"]);

function isLineHistoryFileProjectedResource(
  resource: ScmProjectedResource,
  document: ActiveEditorTextDocument,
  settings: LensSettings,
): boolean {
  return (
    settings.enabled &&
    !document.isDirty &&
    document.lineCount <= settings.maxFileLines &&
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
