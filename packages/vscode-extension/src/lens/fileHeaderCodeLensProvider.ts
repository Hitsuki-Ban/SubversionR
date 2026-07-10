import type * as vscode from "vscode";
import type { RepositorySession, RepositorySessionService } from "../repository/repositorySessionService";
import {
  BASE_DIFFABLE_FILE_CONTEXT_VALUE,
  isBaseDiffableProjectedResource,
} from "../scm/baseDiffResource";
import { isChangelistResourceGroupId } from "../scm/resourceStateClassifier";
import type { SourceControlProjectionService } from "../scm/sourceControlProjectionService";
import type { ScmProjectedResource, ScmProjectedResourceLookup } from "../scm/sourceControlResourceStore";
import type { PathCasePolicy } from "../status/types";
import type { LensSettings } from "./lensSettings";

export interface FileHeaderCodeLensProviderOptions<TCodeLens extends FileHeaderCodeLens> {
  settings(): LensSettings;
  sessionService: Pick<RepositorySessionService, "listOpenSessions">;
  sourceControlProjection: Pick<SourceControlProjectionService, "getProjectedResource">;
  workspaceTrusted(): boolean;
  api: FileHeaderCodeLensApi<TCodeLens>;
}

export interface FileHeaderCodeLensApi<TCodeLens extends FileHeaderCodeLens> {
  createEventEmitter(): FileHeaderCodeLensEventEmitter;
  createRange(startLine: number, startCharacter: number, endLine: number, endCharacter: number): unknown;
  createCodeLens(range: unknown): TCodeLens;
  localize(message: string, ...args: unknown[]): string;
}

export interface FileHeaderCodeLensEventEmitter {
  event: vscode.Event<void>;
  fire(): void;
  dispose(): void;
}

export interface FileHeaderCodeLens {
  range: unknown;
  command?: FileHeaderCommand;
}

export interface FileHeaderTextDocument {
  uri: FileHeaderUri;
  lineCount: number;
}

export interface FileHeaderUri {
  scheme: string;
  fsPath: string;
}

export interface FileHeaderCancellationToken {
  isCancellationRequested: boolean;
}

interface FileHeaderCommand {
  command: string;
  title: string;
  arguments?: unknown[];
}

type FileHeaderLensAction = "summary" | "diffPrevious" | "diffBase" | "diffHead" | "history" | "blame" | "log";

interface FileHeaderLensData {
  action: FileHeaderLensAction;
  target: FileHeaderLensTarget;
}

interface FileHeaderLensTarget {
  repositoryId: string;
  generation: number;
  contextValue: string;
  resourceUri: FileHeaderUri;
  changedRevision: number;
  changedAuthor: string | null;
  changedDate: string | null;
  previousDiffable: boolean;
  baseDiffable: boolean;
}

interface ResourceMatch {
  session: RepositorySession;
  lookup: ScmProjectedResourceLookup;
  relativePath: string;
  rootLength: number;
}

const FILE_HEADER_DIFF_ACTIONS: readonly FileHeaderLensAction[] = ["diffBase", "diffHead"];
const DELETED_STATUS_TOKENS = new Set(["deleted", "missing"]);

export class FileHeaderCodeLensProvider<TCodeLens extends FileHeaderCodeLens = FileHeaderCodeLens> {
  private readonly emitter: FileHeaderCodeLensEventEmitter;

  public constructor(private readonly options: FileHeaderCodeLensProviderOptions<TCodeLens>) {
    this.emitter = options.api.createEventEmitter();
  }

  public get onDidChangeCodeLenses(): vscode.Event<void> {
    return this.emitter.event;
  }

  public provideCodeLenses(document: FileHeaderTextDocument): TCodeLens[] {
    const target = this.targetForDocument(document);
    if (!target) {
      return [];
    }
    const range = this.options.api.createRange(0, 0, 0, 0);
    return actionsForTarget(target, this.options.workspaceTrusted()).map((action) => {
      const lens = this.options.api.createCodeLens(range);
      setLensData(lens, { action, target });
      return lens;
    });
  }

  public resolveCodeLens(lens: TCodeLens, token: FileHeaderCancellationToken): TCodeLens {
    if (token.isCancellationRequested || lens.command) {
      return lens;
    }
    const data = lensData(lens);
    if (!data) {
      return lens;
    }
    lens.command = commandForAction(data, this.options.api.localize);
    return lens;
  }

  public refresh(): void {
    this.emitter.fire();
  }

  public dispose(): void {
    this.emitter.dispose();
  }

  private targetForDocument(document: FileHeaderTextDocument): FileHeaderLensTarget | undefined {
    const settings = this.options.settings();
    if (!settings.enabled || !settings.fileHeader || document.lineCount > settings.maxFileLines) {
      return undefined;
    }
    if (!isFileDocument(document)) {
      return undefined;
    }
    const match = this.matchDocument(document.uri.fsPath);
    if (!match || match.lookup.epoch !== match.session.epoch || match.lookup.repositoryId !== match.session.repositoryId) {
      return undefined;
    }
    const resource = match.lookup.resource;
    if (!isFileHeaderResource(resource)) {
      return undefined;
    }
    return {
      repositoryId: match.session.repositoryId,
      generation: match.lookup.generation,
      contextValue: resource.contextValue,
      resourceUri: document.uri,
      changedRevision: resource.entry.changedRevision,
      changedAuthor: resource.entry.changedAuthor,
      changedDate: resource.entry.changedDate,
      previousDiffable: isPreviousDiffableRevision(resource.entry.changedRevision),
      baseDiffable: isBaseDiffableProjectedResource(resource),
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
        return lookup ? [{ session, lookup, relativePath: lookup.resource.path, rootLength: rootKey(session).length }] : [];
      })
      .sort(
        (left, right) =>
          right.rootLength - left.rootLength ||
          left.session.repositoryId.localeCompare(right.session.repositoryId),
      )[0];
  }
}

function setLensData(lens: FileHeaderCodeLens, data: FileHeaderLensData): void {
  (lens as FileHeaderCodeLens & { subversionrFileHeaderLens?: FileHeaderLensData }).subversionrFileHeaderLens = data;
}

function lensData(lens: FileHeaderCodeLens): FileHeaderLensData | undefined {
  return (lens as FileHeaderCodeLens & { subversionrFileHeaderLens?: FileHeaderLensData })
    .subversionrFileHeaderLens;
}

function commandForAction(
  data: FileHeaderLensData,
  localize: (message: string, ...args: unknown[]) => string,
): FileHeaderCommand {
  switch (data.action) {
    case "summary":
      return {
        command: "subversionr.showFileHistory",
        title: localize(
          "SVN r{0} by {1} on {2}",
          data.target.changedRevision,
          data.target.changedAuthor ?? localize("Unknown author"),
          dateSummary(data.target.changedDate, localize),
        ),
        arguments: [resourceStateArgument(data.target)],
      };
    case "diffBase":
      return {
        command: "subversionr.diffWithBase",
        title: localize("Compare BASE"),
        arguments: [resourceStateArgument(data.target, BASE_DIFFABLE_FILE_CONTEXT_VALUE)],
      };
    case "diffPrevious":
      return {
        command: "subversionr.diffWithPrevious",
        title: localize("Compare PREV"),
        arguments: [resourceStateArgument(data.target)],
      };
    case "diffHead":
      return {
        command: "subversionr.diffWithHead",
        title: localize("Compare HEAD"),
        arguments: [resourceStateArgument(data.target, BASE_DIFFABLE_FILE_CONTEXT_VALUE)],
      };
    case "history":
      return {
        command: "subversionr.showFileHistory",
        title: localize("File History"),
        arguments: [resourceStateArgument(data.target)],
      };
    case "blame":
      return {
        command: "subversionr.showBlame",
        title: localize("Blame"),
        arguments: [resourceStateArgument(data.target)],
      };
    case "log":
      return {
        command: "subversionr.showRepositoryLog",
        title: localize("Open Log"),
        arguments: [data.target.repositoryId],
      };
  }
}

function actionsForTarget(target: FileHeaderLensTarget, workspaceTrusted: boolean): readonly FileHeaderLensAction[] {
  if (!workspaceTrusted) {
    return target.baseDiffable ? ["diffBase"] : [];
  }
  const previousActions: FileHeaderLensAction[] = target.previousDiffable ? ["diffPrevious"] : [];
  return target.baseDiffable
    ? ["summary", ...previousActions, ...FILE_HEADER_DIFF_ACTIONS, "history", "blame", "log"]
    : ["summary", ...previousActions, "history", "blame", "log"];
}

function resourceStateArgument(target: FileHeaderLensTarget, contextValue = target.contextValue): Record<string, unknown> {
  return {
    contextValue,
    subversionrResourceKind: "file",
    subversionrProjectionGeneration: target.generation,
    resourceUri: target.resourceUri,
  };
}

function dateSummary(date: string | null, localize: (message: string, ...args: unknown[]) => string): string {
  if (!date) {
    return localize("Unknown date");
  }
  return date.slice(0, 10);
}

function isPreviousDiffableRevision(revision: number): boolean {
  return Number.isSafeInteger(revision) && revision > 0 && revision <= 2_147_483_647;
}

function isFileDocument(document: FileHeaderTextDocument): boolean {
  return document.uri.scheme === "file" && typeof document.uri.fsPath === "string" && document.uri.fsPath.length > 0;
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

function isFileHeaderResource(resource: ScmProjectedResource): boolean {
  return (
    resource.source === "local" &&
    resource.entry.kind === "file" &&
    !resource.entry.external &&
    resource.entry.localStatus !== "ignored" &&
    (resource.groupId === "changes" ||
      resource.groupId === "conflicts" ||
      isChangelistResourceGroupId(resource.groupId)) &&
    !hasDeletedStatus(resource) &&
    (resource.contextValue === "subversionr.changedFile" || resource.contextValue === "subversionr.conflicted")
  );
}

function hasDeletedStatus(resource: ScmProjectedResource): boolean {
  return [resource.entry.localStatus, resource.entry.nodeStatus, resource.entry.textStatus].some((status) =>
    DELETED_STATUS_TOKENS.has(status),
  );
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
