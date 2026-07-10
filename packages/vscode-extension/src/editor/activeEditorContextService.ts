import type { RepositorySession, RepositorySessionService } from "../repository/repositorySessionService";
import type { LensSettings } from "../lens/lensSettings";
import {
  BASE_DIFFABLE_FILE_CONTEXT_VALUE,
  isBaseDiffableProjectedResource,
} from "../scm/baseDiffResource";
import { isChangelistResourceGroupId } from "../scm/resourceStateClassifier";
import type { SourceControlProjectionService } from "../scm/sourceControlProjectionService";
import type { ScmProjectedResource, ScmProjectedResourceLookup } from "../scm/sourceControlResourceStore";
import type { PathCasePolicy } from "../status/types";

export const ACTIVE_EDITOR_HISTORY_FILE_CONTEXT = "subversionr.activeEditorHistoryFile";
export const ACTIVE_EDITOR_BASE_DIFFABLE_CONTEXT = "subversionr.activeEditorBaseDiffable";
export const ACTIVE_EDITOR_PREVIOUS_DIFFABLE_CONTEXT = "subversionr.activeEditorPreviousDiffable";
export const ACTIVE_EDITOR_LINE_HISTORY_FILE_CONTEXT = "subversionr.activeEditorLineHistoryFile";

export interface ActiveEditorContextServiceOptions {
  settings(): LensSettings;
  sessionService: Pick<RepositorySessionService, "listOpenSessions">;
  sourceControlProjection: Pick<SourceControlProjectionService, "getProjectedResource">;
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

interface ActiveEditorContextState {
  historyFile: boolean;
  baseDiffable: boolean;
  previousDiffable: boolean;
  lineHistoryFile: boolean;
}

interface ResourceMatch {
  session: RepositorySession;
  lookup: ScmProjectedResourceLookup;
  rootLength: number;
}

const FALSE_STATE: ActiveEditorContextState = {
  historyFile: false,
  baseDiffable: false,
  previousDiffable: false,
  lineHistoryFile: false,
};

export class ActiveEditorContextService {
  public constructor(private readonly options: ActiveEditorContextServiceOptions) {}

  public async refresh(): Promise<void> {
    const state = this.contextState();
    await Promise.all([
      this.options.api.setContext(ACTIVE_EDITOR_HISTORY_FILE_CONTEXT, state.historyFile),
      this.options.api.setContext(ACTIVE_EDITOR_BASE_DIFFABLE_CONTEXT, state.baseDiffable),
      this.options.api.setContext(ACTIVE_EDITOR_PREVIOUS_DIFFABLE_CONTEXT, state.previousDiffable),
      this.options.api.setContext(ACTIVE_EDITOR_LINE_HISTORY_FILE_CONTEXT, state.lineHistoryFile),
    ]);
  }

  private contextState(): ActiveEditorContextState {
    const document = this.options.api.activeTextDocument();
    if (!document || !isFileDocument(document)) {
      return FALSE_STATE;
    }
    const match = this.matchDocument(document.uri.fsPath);
    if (!match || match.lookup.epoch !== match.session.epoch || match.lookup.repositoryId !== match.session.repositoryId) {
      return FALSE_STATE;
    }
    const resource = match.lookup.resource;
    const historyFile = isHistoryFileProjectedResource(resource);
    const lineHistoryFile = isLineHistoryFileProjectedResource(resource, document, this.options.settings());
    return {
      historyFile,
      baseDiffable: historyFile && isBaseDiffableProjectedResource(resource),
      previousDiffable: historyFile && isPreviousDiffableRevision(resource.entry.changedRevision),
      lineHistoryFile,
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
