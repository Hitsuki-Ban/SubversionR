import type * as vscode from "vscode";
import type { HistoryClient, HistoryLogEntry, HistoryLogRequest } from "./historyLogRpcClient";
import type { HistoryRevisionDetailsTarget } from "./historyRevisionDetailsDocument";
import type { HistorySettings } from "./historySettings";
import type { HistoryViewTarget } from "./historyViewTarget";
import { requireTrustedWorkspace } from "../security/workspaceTrust";

export interface HistoryTreeApi {
  collapsibleState: {
    none: vscode.TreeItemCollapsibleState;
    collapsed: vscode.TreeItemCollapsibleState;
    expanded: vscode.TreeItemCollapsibleState;
  };
  createEventEmitter(): HistoryTreeEventEmitter;
}

export interface HistoryTreeEventEmitter {
  event: vscode.Event<HistoryTreeNode | undefined | null | void>;
  fire(element?: HistoryTreeNode): void;
  dispose(): void;
}

export type HistoryTreeNode =
  | HistoryPlaceholderNode
  | HistoryEmptyNode
  | HistorySearchEmptyNode
  | HistoryTargetNode
  | HistoryRevisionNode
  | HistoryChangedPathNode
  | HistoryLoadMoreNode;

export interface HistoryTreeItem {
  label: string;
  description?: string;
  tooltip?: string;
  collapsibleState: vscode.TreeItemCollapsibleState;
  contextValue?: string;
  command?: {
    command: string;
    title: string;
    arguments?: unknown[];
  };
}

export interface HistoryOpenRevisionTarget {
  repositoryId: string;
  epoch: number;
  path: string;
  revision: string;
  label: string;
}

export interface HistoryCompareRevisionTarget {
  repositoryId: string;
  epoch: number;
  path: string;
  leftRevision: string;
  rightRevision: string;
  label: string;
}

export interface HistorySearchResult {
  query: string;
  message?: string;
}

export interface LoadedHistorySnapshot {
  target: HistoryViewTarget;
  entryCount: number;
  entries: Array<{
    revision: number;
    author: string | null;
    message: string | null;
  }>;
}

export interface HistoryCopyTarget {
  revision: number;
  message: string | null;
}

export interface HistoryTreeDataProviderOptions {
  historyClient: HistoryClient;
  settings: HistorySettings;
  workspaceTrusted(): boolean;
  api: HistoryTreeApi;
  localize(message: string, ...args: unknown[]): string;
}

interface HistoryPlaceholderNode {
  kind: "placeholder";
}

interface HistoryEmptyNode {
  kind: "empty";
}

interface HistorySearchEmptyNode {
  kind: "searchEmpty";
}

interface HistoryTargetNode {
  kind: "target";
  target: HistoryViewTarget;
}

interface HistoryRevisionNode {
  kind: "revision";
  target: HistoryViewTarget;
  entry: HistoryLogEntry;
  previousRevision?: number;
}

interface HistoryChangedPathNode {
  kind: "changedPath";
  entry: HistoryLogEntry;
  index: number;
}

interface HistoryLoadMoreNode {
  kind: "loadMore";
}

interface HistoryState {
  target: HistoryViewTarget;
  targetNode: HistoryTargetNode;
  entries: HistoryLogEntry[];
  nextStartRevision: string | undefined;
}

export class HistoryTreeDataProvider implements vscode.TreeDataProvider<HistoryTreeNode>, vscode.Disposable {
  private readonly emitter: HistoryTreeEventEmitter;
  private settings: HistorySettings;
  private state: HistoryState | undefined;
  private currentRevisionNodes = new Map<HistoryLogEntry, HistoryRevisionNode>();
  private requestGeneration = 0;
  private searchQuery = "";

  public constructor(private readonly options: HistoryTreeDataProviderOptions) {
    this.settings = options.settings;
    this.emitter = options.api.createEventEmitter();
  }

  public get onDidChangeTreeData(): vscode.Event<HistoryTreeNode | undefined | null | void> {
    return this.emitter.event;
  }

  public async showHistory(target: HistoryViewTarget): Promise<void> {
    requireTrustedWorkspace(this.options.workspaceTrusted);
    this.requireHistoryTarget(target);
    const requestGeneration = this.nextRequestGeneration();
    this.searchQuery = "";
    this.state = {
      target,
      targetNode: { kind: "target", target },
      entries: [],
      nextStartRevision: "head",
    };
    this.currentRevisionNodes = new Map();
    await this.reload(requestGeneration);
  }

  public showLineHistory(target: HistoryViewTarget, entries: readonly HistoryLogEntry[]): void {
    this.requireLineHistoryTarget(target);
    this.searchQuery = "";
    this.state = {
      target,
      targetNode: { kind: "target", target },
      entries: [...entries],
      nextStartRevision: undefined,
    };
    this.currentRevisionNodes = new Map();
    this.emitter.fire(undefined);
  }

  public currentTargetNode(): HistoryTreeNode | undefined {
    return this.state?.targetNode;
  }

  public currentSnapshot(): LoadedHistorySnapshot | undefined {
    if (!this.state) {
      return undefined;
    }
    return {
      target: { ...this.state.target },
      entryCount: this.state.entries.length,
      entries: this.state.entries.map((entry) => ({
        revision: entry.revision,
        author: entry.author?.trim() || null,
        message: entry.message,
      })),
    };
  }

  public ensureSearchableTarget(): void {
    if (!this.state) {
      throw new HistoryTreeDataProviderError(
        "SUBVERSIONR_HISTORY_SEARCH_TARGET_MISSING",
        "input",
        "error.history.searchTargetMissing",
      );
    }
  }

  public currentSearchQuery(): string {
    return this.searchQuery;
  }

  public currentSearchMessage(): string | undefined {
    return this.searchQuery.length > 0
      ? this.options.localize("Filtering loaded SVN history: {0}", this.searchQuery)
      : undefined;
  }

  public refreshWorkspaceTrust(): void {
    this.emitter.fire(undefined);
  }

  public async updateSettings(settings: HistorySettings): Promise<void> {
    this.settings = settings;
    this.currentRevisionNodes = new Map();
    const state = this.state;
    if (!state || state.target.kind === "line" || !this.options.workspaceTrusted()) {
      this.emitter.fire(undefined);
      return;
    }
    await this.reload(this.nextRequestGeneration());
  }

  public applySearch(query: unknown): HistorySearchResult {
    this.ensureSearchableTarget();
    if (typeof query !== "string") {
      throw invalidSearchQuery();
    }
    const normalizedQuery = query.trim();
    if (normalizedQuery.length > MAX_HISTORY_SEARCH_QUERY_LENGTH) {
      throw invalidSearchQuery();
    }
    this.searchQuery = normalizedQuery;
    this.currentRevisionNodes = new Map();
    this.emitter.fire(undefined);
    return {
      query: normalizedQuery,
      message: this.currentSearchMessage(),
    };
  }

  public openRevisionTarget(element: unknown): HistoryOpenRevisionTarget {
    requireTrustedWorkspace(this.options.workspaceTrusted);
    const { node: revisionNode } = this.requireCurrentFileRevisionNode(element, invalidOpenRevisionTarget);
    return openRevisionTarget(revisionNode.target, revisionNode.entry.revision);
  }

  public revisionDetailsTarget(element: unknown): HistoryRevisionDetailsTarget {
    const { node: revisionNode } = this.requireCurrentRevisionNode(element, invalidRevisionDetailsTarget);
    const revisionId = `r${revisionNode.entry.revision}`;
    return {
      repositoryId: revisionNode.target.repositoryId,
      epoch: revisionNode.target.epoch,
      targetKind: revisionNode.target.kind,
      path: revisionNode.target.path,
      label: revisionNode.target.label,
      revision: revisionId,
      author: revisionNode.entry.author,
      date: revisionNode.entry.date,
      message: revisionNode.entry.message,
      changedPaths: revisionNode.entry.changedPaths,
      hasChildren: revisionNode.entry.hasChildren,
      nonInheritable: revisionNode.entry.nonInheritable,
      subtractiveMerge: revisionNode.entry.subtractiveMerge,
    };
  }

  public compareRevisionTarget(element: unknown): HistoryCompareRevisionTarget {
    requireTrustedWorkspace(this.options.workspaceTrusted);
    const { node: revisionNode, state, index } = this.requireCurrentFileRevisionNode(
      element,
      invalidCompareRevisionTarget,
    );
    const previousEntry = state.entries[index + 1];
    if (!previousEntry || previousEntry.revision >= revisionNode.entry.revision) {
      throw invalidCompareRevisionTarget();
    }
    const leftRevision = `r${previousEntry.revision}`;
    const rightRevision = `r${revisionNode.entry.revision}`;
    return {
      repositoryId: revisionNode.target.repositoryId,
      epoch: revisionNode.target.epoch,
      path: revisionNode.target.path,
      leftRevision,
      rightRevision,
      label: `${revisionNode.target.path} ${leftRevision}..${rightRevision}`,
    };
  }

  public compareRevisionsTarget(element: unknown, selectedElements: unknown): HistoryCompareRevisionTarget {
    requireTrustedWorkspace(this.options.workspaceTrusted);
    const focused = this.requireCurrentFileRevisionNode(element, invalidCompareRevisionsTarget);
    if (!Array.isArray(selectedElements) || selectedElements.length !== 2 || !selectedElements.includes(element)) {
      throw invalidCompareRevisionsTarget();
    }
    const [firstElement, secondElement] = selectedElements;
    if (firstElement === secondElement) {
      throw invalidCompareRevisionsTarget();
    }

    const first = this.requireCurrentFileRevisionNode(firstElement, invalidCompareRevisionsTarget);
    const second = this.requireCurrentFileRevisionNode(secondElement, invalidCompareRevisionsTarget);
    if (first.state !== focused.state || second.state !== focused.state || first.node.target !== second.node.target) {
      throw invalidCompareRevisionsTarget();
    }
    const firstRevision = first.node.entry.revision;
    const secondRevision = second.node.entry.revision;
    if (firstRevision === secondRevision) {
      throw invalidCompareRevisionsTarget();
    }
    const leftRevisionNumber = Math.min(firstRevision, secondRevision);
    const rightRevisionNumber = Math.max(firstRevision, secondRevision);
    const leftRevision = `r${leftRevisionNumber}`;
    const rightRevision = `r${rightRevisionNumber}`;
    return {
      repositoryId: focused.node.target.repositoryId,
      epoch: focused.node.target.epoch,
      path: focused.node.target.path,
      leftRevision,
      rightRevision,
      label: `${focused.node.target.path} ${leftRevision}..${rightRevision}`,
    };
  }

  public copyTarget(element: unknown): HistoryCopyTarget {
    const { node: revisionNode } = this.requireCurrentRevisionNode(element, invalidCopyTarget);
    return {
      revision: revisionNode.entry.revision,
      message: revisionNode.entry.message,
    };
  }

  public async refresh(): Promise<void> {
    if (!this.state || this.state.target.kind === "line") {
      return;
    }
    requireTrustedWorkspace(this.options.workspaceTrusted);
    await this.reload(this.nextRequestGeneration());
  }

  public async loadMore(): Promise<void> {
    const state = this.state;
    if (!state?.nextStartRevision) {
      return;
    }
    requireTrustedWorkspace(this.options.workspaceTrusted);
    const requestGeneration = this.nextRequestGeneration();
    const log = await this.options.historyClient.getLog(this.createRequest(state.target, state.nextStartRevision));
    if (this.requestGeneration !== requestGeneration || this.state?.targetNode !== state.targetNode) {
      return;
    }
    this.state = {
      target: state.target,
      targetNode: state.targetNode,
      entries: [...state.entries, ...log.entries],
      nextStartRevision: nextStartRevision(log.entries, this.settings.pageSize),
    };
    this.currentRevisionNodes = new Map();
    this.emitter.fire(undefined);
  }

  public getTreeItem(element: HistoryTreeNode): HistoryTreeItem {
    switch (element.kind) {
      case "placeholder":
        return {
          label: this.options.localize("Open an SVN file or repository history."),
          collapsibleState: this.options.api.collapsibleState.none,
          contextValue: "subversionr.history.placeholder",
        };
      case "empty":
        return {
          label: this.options.localize("No SVN history entries found."),
          collapsibleState: this.options.api.collapsibleState.none,
          contextValue: "subversionr.history.empty",
        };
      case "searchEmpty":
        return {
          label: this.options.localize("No loaded SVN history entries match the search."),
          collapsibleState: this.options.api.collapsibleState.none,
          contextValue: "subversionr.history.searchEmpty",
        };
      case "target":
        return {
          label: targetLabel(element.target, this.options.localize),
          collapsibleState: this.options.api.collapsibleState.expanded,
          contextValue: "subversionr.history.target",
        };
      case "revision":
        return {
          label: `r${element.entry.revision}`,
          description: revisionDescription(element.entry, this.options.localize),
          tooltip: revisionTooltip(element.entry, this.options.localize),
          collapsibleState:
            element.entry.changedPaths.length > 0
              ? this.options.api.collapsibleState.collapsed
              : this.options.api.collapsibleState.none,
          contextValue: revisionContextValue(element),
          command: revisionCommand(element, this.options.workspaceTrusted(), this.options.localize),
        };
      case "changedPath": {
        const changedPath = element.entry.changedPaths[element.index];
        if (!changedPath) {
          throw new HistoryTreeDataProviderError(
            "SUBVERSIONR_HISTORY_TREE_CHANGED_PATH_INVALID",
            "input",
            "error.history.changedPathInvalid",
          );
        }
        return {
          label: `${changedPath.action} ${changedPath.path}`,
          description:
            changedPath.copyFromPath && changedPath.copyFromRevision !== null
              ? this.options.localize("from {0}@r{1}", changedPath.copyFromPath, changedPath.copyFromRevision)
              : undefined,
          collapsibleState: this.options.api.collapsibleState.none,
          contextValue: "subversionr.history.changedPath",
        };
      }
      case "loadMore":
        return {
          label: this.options.localize("Load More"),
          collapsibleState: this.options.api.collapsibleState.none,
          contextValue: "subversionr.history.loadMore",
          command: {
            command: "subversionr.history.loadMore",
            title: this.options.localize("Load More"),
          },
        };
    }
  }

  public getParent(element: HistoryTreeNode): HistoryTreeNode | undefined {
    const state = this.state;
    if (!state) {
      return undefined;
    }
    switch (element.kind) {
      case "target":
      case "placeholder":
        return undefined;
      case "revision":
        return this.currentRevisionNodes.get(element.entry) === element
          ? state.targetNode
          : undefined;
      case "changedPath":
        return this.currentRevisionNodes.get(element.entry);
      case "empty":
      case "searchEmpty":
      case "loadMore":
        return state.targetNode;
    }
  }

  public async getChildren(element?: HistoryTreeNode): Promise<HistoryTreeNode[]> {
    const state = this.state;
    if (!element) {
      return state ? [state.targetNode] : [{ kind: "placeholder" }];
    }
    if (!state) {
      return [];
    }
    switch (element.kind) {
      case "target": {
        const visibleEntries = searchHistoryEntries(state.entries, this.searchQuery);
        const children: HistoryTreeNode[] = [];
        if (state.entries.length === 0) {
          children.push({ kind: "empty" });
        } else if (visibleEntries.length === 0) {
          children.push({ kind: "searchEmpty" });
        } else {
          const revisionNodes = visibleEntries.map(({ entry, index }): HistoryRevisionNode => ({
            kind: "revision",
            target: state.target,
            entry,
            previousRevision: state.target.kind === "file" ? state.entries[index + 1]?.revision : undefined,
          }));
          for (const revisionNode of revisionNodes) {
            this.currentRevisionNodes.set(revisionNode.entry, revisionNode);
          }
          children.push(...revisionNodes);
        }
        if (state.nextStartRevision) {
          children.push({ kind: "loadMore" });
        }
        return children;
      }
      case "revision":
        return element.entry.changedPaths.map((_changedPath, index) => ({
          kind: "changedPath",
          entry: element.entry,
          index,
        }));
      default:
        return [];
    }
  }

  public dispose(): void {
    this.emitter.dispose();
  }

  private async reload(requestGeneration: number): Promise<void> {
    const state = this.state;
    if (!state) {
      return;
    }
    const log = await this.options.historyClient.getLog(this.createRequest(state.target, "head"));
    if (this.requestGeneration !== requestGeneration || this.state?.targetNode !== state.targetNode) {
      return;
    }
    this.state = {
      target: state.target,
      targetNode: state.targetNode,
      entries: log.entries,
      nextStartRevision: nextStartRevision(log.entries, this.settings.pageSize),
    };
    this.currentRevisionNodes = new Map();
    this.emitter.fire(undefined);
  }

  private createRequest(target: HistoryViewTarget, startRevision: string): HistoryLogRequest {
    return {
      repositoryId: target.repositoryId,
      epoch: target.epoch,
      path: target.path,
      startRevision,
      endRevision: "r0",
      limit: this.settings.pageSize,
      discoverChangedPaths: true,
      strictNodeHistory: false,
      includeMergedRevisions: this.settings.includeMergedRevisions,
    };
  }

  private nextRequestGeneration(): number {
    this.requestGeneration += 1;
    return this.requestGeneration;
  }

  private requireHistoryTarget(target: HistoryViewTarget): void {
    if (
      (target.kind !== "repository" && target.kind !== "file") ||
      target.repositoryId.trim().length === 0 ||
      !Number.isSafeInteger(target.epoch) ||
      target.epoch < 0 ||
      target.path.trim().length === 0 ||
      target.label.trim().length === 0
    ) {
      throw new HistoryTreeDataProviderError(
        "SUBVERSIONR_HISTORY_VIEW_TARGET_INVALID",
        "input",
        "error.history.viewTargetInvalid",
      );
    }
  }

  private requireLineHistoryTarget(target: HistoryViewTarget): void {
    const lineStart = target.lineStart;
    const lineEnd = target.lineEnd;
    if (
      target.kind !== "line" ||
      target.repositoryId.trim().length === 0 ||
      !Number.isSafeInteger(target.epoch) ||
      target.epoch < 0 ||
      target.path.trim().length === 0 ||
      target.label.trim().length === 0 ||
      typeof lineStart !== "number" ||
      typeof lineEnd !== "number" ||
      !Number.isSafeInteger(lineStart) ||
      !Number.isSafeInteger(lineEnd) ||
      lineStart < 1 ||
      lineEnd < lineStart
    ) {
      throw new HistoryTreeDataProviderError(
        "SUBVERSIONR_HISTORY_VIEW_TARGET_INVALID",
        "input",
        "error.history.viewTargetInvalid",
      );
    }
  }

  private requireCurrentFileRevisionNode(
    element: unknown,
    invalid: () => HistoryTreeDataProviderError,
  ): { node: HistoryRevisionNode; state: HistoryState; index: number } {
    const result = this.requireCurrentRevisionNode(element, invalid);
    if (result.state.target.kind !== "file") {
      throw invalid();
    }
    return result;
  }

  private requireCurrentRevisionNode(
    element: unknown,
    invalid: () => HistoryTreeDataProviderError,
  ): { node: HistoryRevisionNode; state: HistoryState; index: number } {
    const state = this.state;
    if (!state) {
      throw invalid();
    }
    if (typeof element !== "object" || element === null) {
      throw invalid();
    }
    const candidate = element as Partial<HistoryRevisionNode>;
    if (candidate.kind !== "revision") {
      throw invalid();
    }
    if (!candidate.entry || this.currentRevisionNodes.get(candidate.entry) !== candidate) {
      throw invalid();
    }
    if (typeof candidate.target !== "object" || candidate.target === null) {
      throw invalid();
    }
    const target = candidate.target as Partial<HistoryViewTarget>;
    if (candidate.target !== state.target) {
      throw invalid();
    }
    if (
      (target.kind !== "repository" && target.kind !== "file" && target.kind !== "line") ||
      typeof target.repositoryId !== "string" ||
      target.repositoryId.trim().length === 0 ||
      typeof target.epoch !== "number" ||
      !Number.isSafeInteger(target.epoch) ||
      target.epoch < 0 ||
      typeof target.path !== "string" ||
      target.path.trim().length === 0 ||
      typeof target.label !== "string" ||
      target.label.trim().length === 0
    ) {
      throw invalid();
    }
    if (typeof candidate.entry !== "object" || candidate.entry === null) {
      throw invalid();
    }
    const index = state.entries.indexOf(candidate.entry as HistoryLogEntry);
    if (index < 0) {
      throw invalid();
    }
    const entry = candidate.entry as Partial<HistoryLogEntry>;
    if (
      typeof entry.revision !== "number" ||
      !Number.isSafeInteger(entry.revision) ||
      entry.revision < 0
    ) {
      throw invalid();
    }
    return {
      node: candidate as HistoryRevisionNode,
      state,
      index,
    };
  }
}

const MAX_HISTORY_SEARCH_QUERY_LENGTH = 200;

export class HistoryTreeDataProviderError extends Error {
  public constructor(
    public readonly code: string,
    public readonly category: "input",
    public readonly messageKey: string,
    public readonly safeArgs: Record<string, unknown> = {},
  ) {
    super(code);
    this.name = "HistoryTreeDataProviderError";
  }
}

function nextStartRevision(entries: readonly HistoryLogEntry[], limit: number): string | undefined {
  if (entries.length < limit) {
    return undefined;
  }
  const last = entries[entries.length - 1];
  if (!last || last.revision < 1) {
    return undefined;
  }
  return `r${last.revision - 1}`;
}

function searchHistoryEntries(
  entries: readonly HistoryLogEntry[],
  query: string,
): Array<{ entry: HistoryLogEntry; index: number }> {
  const normalizedQuery = query.trim().toLocaleLowerCase("en-US");
  if (normalizedQuery.length === 0) {
    return entries.map((entry, index) => ({ entry, index }));
  }
  return entries
    .map((entry, index) => ({ entry, index }))
    .filter(({ entry }) => historyEntryMatches(entry, normalizedQuery));
}

function historyEntryMatches(entry: HistoryLogEntry, normalizedQuery: string): boolean {
  const fields = [
    `r${entry.revision}`,
    String(entry.revision),
    entry.author,
    entry.date,
    entry.message,
    ...entry.changedPaths.flatMap((changedPath) => [
      changedPath.action,
      changedPath.path,
      changedPath.copyFromPath,
      changedPath.copyFromRevision === null ? null : `r${changedPath.copyFromRevision}`,
      changedPath.copyFromRevision === null ? null : String(changedPath.copyFromRevision),
      changedPath.nodeKind,
      changedPath.textModified,
      changedPath.propertiesModified,
    ]),
  ];
  return fields.some(
    (field) => typeof field === "string" && field.toLocaleLowerCase("en-US").includes(normalizedQuery),
  );
}

function openRevisionTarget(target: HistoryViewTarget, revision: number): HistoryOpenRevisionTarget {
  const revisionId = `r${revision}`;
  return {
    repositoryId: target.repositoryId,
    epoch: target.epoch,
    path: target.path,
    revision: revisionId,
    label: `${target.path}@${revisionId}`,
  };
}

function targetLabel(
  target: HistoryViewTarget,
  localize: (message: string, ...args: unknown[]) => string,
): string {
  switch (target.kind) {
    case "repository":
      return target.label;
    case "file":
      return localize("File: {0}", target.label);
    case "line":
      return localize("Line History: {0}", target.label);
  }
}

function revisionContextValue(element: HistoryRevisionNode): string {
  if (element.target.kind === "line") {
    return "subversionr.history.lineRevision";
  }
  if (element.target.kind !== "file") {
    return "subversionr.history.repositoryRevision";
  }
  return canCompareWithPrevious(element)
    ? "subversionr.history.fileRevision.previousDiffable"
    : "subversionr.history.fileRevision";
}

function revisionCommand(
  element: HistoryRevisionNode,
  workspaceTrusted: boolean,
  localize: (message: string, ...args: unknown[]) => string,
): HistoryTreeItem["command"] {
  if (element.target.kind === "file" && workspaceTrusted) {
    return {
      command: "subversionr.history.openRevision",
      title: localize("Open Revision"),
      arguments: [element],
    };
  }
  return {
    command: "subversionr.history.openRevisionDetails",
    title: localize("Open Revision Details"),
    arguments: [element],
  };
}

function canCompareWithPrevious(element: HistoryRevisionNode): boolean {
  return (
    typeof element.previousRevision === "number" &&
    Number.isSafeInteger(element.previousRevision) &&
    element.previousRevision >= 0 &&
    element.previousRevision < element.entry.revision
  );
}

function invalidOpenRevisionTarget(): HistoryTreeDataProviderError {
  return new HistoryTreeDataProviderError(
    "SUBVERSIONR_HISTORY_OPEN_REVISION_TARGET_INVALID",
    "input",
    "error.history.openRevisionTargetInvalid",
  );
}

function invalidCompareRevisionTarget(): HistoryTreeDataProviderError {
  return new HistoryTreeDataProviderError(
    "SUBVERSIONR_HISTORY_COMPARE_PREVIOUS_TARGET_INVALID",
    "input",
    "error.history.comparePreviousTargetInvalid",
  );
}

function invalidCompareRevisionsTarget(): HistoryTreeDataProviderError {
  return new HistoryTreeDataProviderError(
    "SUBVERSIONR_HISTORY_COMPARE_REVISIONS_TARGET_INVALID",
    "input",
    "error.history.compareRevisionsTargetInvalid",
  );
}

function invalidSearchQuery(): HistoryTreeDataProviderError {
  return new HistoryTreeDataProviderError(
    "SUBVERSIONR_HISTORY_SEARCH_QUERY_INVALID",
    "input",
    "error.history.searchQueryInvalid",
  );
}

function invalidRevisionDetailsTarget(): HistoryTreeDataProviderError {
  return new HistoryTreeDataProviderError(
    "SUBVERSIONR_HISTORY_REVISION_DETAILS_TARGET_INVALID",
    "input",
    "error.history.revisionDetailsTargetInvalid",
  );
}

function invalidCopyTarget(): HistoryTreeDataProviderError {
  return new HistoryTreeDataProviderError(
    "SUBVERSIONR_HISTORY_COPY_TARGET_INVALID",
    "input",
    "error.history.copyTargetInvalid",
  );
}

function revisionDescription(
  entry: HistoryLogEntry,
  localize: (message: string, ...args: unknown[]) => string,
): string {
  return [
    entry.author?.trim() || localize("Unknown author"),
    dateSummary(entry.date, localize),
    messageSummary(entry.message, localize),
  ].join(" ");
}

function revisionTooltip(
  entry: HistoryLogEntry,
  localize: (message: string, ...args: unknown[]) => string,
): string {
  return entry.message?.trim() || localize("No log message");
}

function dateSummary(date: string | null, localize: (message: string, ...args: unknown[]) => string): string {
  if (!date) {
    return localize("Unknown date");
  }
  return date.slice(0, 10);
}

function messageSummary(message: string | null, localize: (message: string, ...args: unknown[]) => string): string {
  const trimmed = message?.replace(/\s+/gu, " ").trim();
  return trimmed && trimmed.length > 0 ? trimmed : localize("No log message");
}
