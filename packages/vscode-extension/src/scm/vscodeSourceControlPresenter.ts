import * as nodePath from "node:path";
import { createBaseContentUriComponents, type BaseContentUriComponents } from "../content/baseContentUri";
import type { SourceControlProjectionPresenter } from "./sourceControlProjectionService";
import {
  BASE_DIFFABLE_FILE_CONTEXT_VALUE,
  isBaseDiffableProjectedResource,
} from "./baseDiffResource";
import {
  SCM_RESOURCE_GROUP_IDS,
  type ScmProjectionFreshness,
  type ScmProjectedResource,
  type ScmRepositoryProjection,
  type SourceControlProjectionRepository,
} from "./sourceControlResourceStore";
import {
  isChangelistResourceGroupId,
  isSparseStatusDepth,
} from "./resourceStateClassifier";

export interface VscodeSourceControlPresenterApi {
  createSourceControl(id: string, label: string, rootUri: unknown, repositoryId: string): VscodeSourceControl;
  uriFile(fsPath: string): unknown;
  uriFromComponents(components: BaseContentUriComponents): unknown;
  uriFsPath(uri: unknown): string | undefined;
  workspaceTrusted(): boolean;
  localize(message: string, ...args: unknown[]): string;
}

export interface VscodeSourceControl {
  count?: number;
  inputBox: VscodeSourceControlInputBox;
  acceptInputCommand?: VscodeSourceControlCommand;
  statusBarCommands?: VscodeSourceControlCommand[];
  createResourceGroup(id: string, label: string): VscodeSourceControlResourceGroup;
  dispose(): void;
}

export interface VscodeSourceControlCommand {
  command: string;
  title: string;
  arguments?: unknown[];
}

export interface VscodeSourceControlInputBox {
  placeholder: string;
  value: string;
}

export interface VscodeSourceControlQuickDiffProvider {
  provideOriginalResource(uri: unknown): unknown | undefined;
}

export interface VscodeSourceControlResourceGroup {
  contextValue?: string;
  hideWhenEmpty?: boolean;
  subversionrRepositoryId?: string;
  subversionrChangelistName?: string;
  resourceStates: VscodeSourceControlResourceState[];
  dispose(): void;
}

export interface VscodeSourceControlResourceState {
  resourceUri: unknown;
  contextValue?: string;
  subversionrResourceKind?: string;
  subversionrProjectionGeneration?: number;
  decorations?: {
    tooltip?: string;
  };
}

export interface VscodeSourceControlSnapshot {
  repositoryId: string;
  epoch: number;
  workingCopyRoot: string;
  generation: number | undefined;
  freshness: ScmProjectionFreshness | undefined;
  count: number | undefined;
  statusBarCommands: VscodeSourceControlCommand[] | undefined;
  inputBox: {
    placeholder: string;
    acceptInputCommand: string | undefined;
    acceptInputCommandArguments: unknown[] | undefined;
  };
  groups: VscodeSourceControlGroupSnapshot[];
}

export interface VscodeSourceControlGroupSnapshot {
  id: string;
  contextValue: string | undefined;
  hideWhenEmpty: boolean | undefined;
  count: number;
  resources: VscodeSourceControlResourceSnapshot[];
}

export interface VscodeSourceControlResourceSnapshot {
  path: string;
  contextValue: string | undefined;
  kind: string | undefined;
  generation: number | undefined;
}

interface RegisteredSourceControl {
  sourceControl: VscodeSourceControl;
  groups: Map<string, VscodeSourceControlResourceGroup>;
  repositoryId: string;
  epoch: number;
  workingCopyRoot: string;
  generation: number | undefined;
  freshness: ScmProjectionFreshness | undefined;
  groupOrder: string[];
  quickDiffPaths: Map<string, string>;
}

const GROUP_LABELS = {
  conflicts: "Conflicts",
  changes: "Changes",
  unversioned: "Unversioned",
  metadata: "Working Copy Metadata",
  incoming: "Incoming",
  externals: "Externals",
  ignored: "Ignored",
} as const;

const RESOURCE_TOOLTIPS: Record<string, string> = {
  "scm.resource.conflicted": "SVN conflict",
  "scm.resource.changed": "SVN local change",
  "scm.resource.changedUnknown": "SVN local change",
  "scm.resource.workingCopyMetadata": "SVN working copy metadata",
  "scm.resource.unversioned": "SVN unversioned item",
  "scm.resource.incoming": "SVN incoming change",
  "scm.resource.external": "SVN external",
  "scm.resource.ignored": "SVN ignored item",
};

const CHANGED_METADATA_TOOLTIP_KEYS = new Set([
  "scm.resource.changed",
  "scm.resource.changedUnknown",
  "scm.resource.incoming",
]);

const CHANGELIST_GROUP_CONTEXT_VALUE = "subversionr.changelist";
const WORKING_COPY_METADATA_CONTEXT_VALUE = "subversionr.workingCopyMetadata";
const WORKING_COPY_METADATA_FILE_CONTEXT_VALUE = "subversionr.workingCopyMetadataFile";
const CHANGELISTED_CONTEXT_VALUES = new Map<string, string>([
  ["subversionr.changedFile", "subversionr.changedFile.changelisted"],
  [BASE_DIFFABLE_FILE_CONTEXT_VALUE, "subversionr.changedFile.baseDiffable.changelisted"],
  ["subversionr.changedDirectory", "subversionr.changedDirectory.changelisted"],
  ["subversionr.conflicted", "subversionr.conflicted.changelisted"],
]);
const LOCKED_CONTEXT_VALUES = new Set([
  "subversionr.changedFile",
  BASE_DIFFABLE_FILE_CONTEXT_VALUE,
  "subversionr.changedFile.changelisted",
  "subversionr.changedFile.baseDiffable.changelisted",
  "subversionr.conflicted",
  "subversionr.conflicted.changelisted",
  "subversionr.incoming",
  "subversionr.incomingFile",
  WORKING_COPY_METADATA_FILE_CONTEXT_VALUE,
]);

export class VscodeSourceControlPresenter implements SourceControlProjectionPresenter {
  private readonly repositories = new Map<string, RegisteredSourceControl>();

  public constructor(private readonly api: VscodeSourceControlPresenterApi) {}

  public registerRepository(repository: SourceControlProjectionRepository): void {
    if (this.repositories.has(repository.repositoryId)) {
      throw new Error(`Source control repository is already registered: ${repository.repositoryId}`);
    }
    const sourceControl = this.api.createSourceControl(
      "svn-r",
      "SubversionR",
      this.api.uriFile(repository.workingCopyRoot),
      repository.repositoryId,
    );
    this.updateCommitInput(sourceControl, repository.repositoryId);
    setQuickDiffProvider(sourceControl, {
      provideOriginalResource: (uri) => this.provideOriginalResource(repository.repositoryId, uri),
    });
    const groups = new Map<string, VscodeSourceControlResourceGroup>();
    try {
      for (const groupId of SCM_RESOURCE_GROUP_IDS) {
        const group = sourceControl.createResourceGroup(groupId, this.api.localize(GROUP_LABELS[groupId]));
        group.contextValue = `subversionr.${groupId}`;
        group.hideWhenEmpty = true;
        group.subversionrRepositoryId = repository.repositoryId;
        groups.set(groupId, group);
      }
    } catch (error) {
      disposeRegisteredGroups(groups);
      disposeBestEffort(() => sourceControl.dispose());
      throw error;
    }
    this.repositories.set(repository.repositoryId, {
      sourceControl,
      groups,
      repositoryId: repository.repositoryId,
      epoch: repository.epoch,
      workingCopyRoot: repository.workingCopyRoot,
      generation: undefined,
      freshness: undefined,
      groupOrder: [...SCM_RESOURCE_GROUP_IDS],
      quickDiffPaths: new Map(),
    });
  }

  public commitMessage(repositoryId: string): string {
    return this.requireRegistered(repositoryId).sourceControl.inputBox.value;
  }

  public setCommitMessage(repositoryId: string, message: string): void {
    this.requireRegistered(repositoryId).sourceControl.inputBox.value = message;
  }

  public clearCommitMessage(repositoryId: string): void {
    this.requireRegistered(repositoryId).sourceControl.inputBox.value = "";
  }

  public refreshWorkspaceTrust(): void {
    for (const registered of this.repositories.values()) {
      this.updateCommitInput(registered.sourceControl, registered.repositoryId);
    }
  }

  public updateRepository(projection: ScmRepositoryProjection): void {
    const registered = this.repositories.get(projection.repositoryId);
    if (!registered) {
      throw new Error(`Source control repository is not registered: ${projection.repositoryId}`);
    }
    registered.sourceControl.count = projection.count;
    registered.sourceControl.statusBarCommands = freshnessStatusBarCommands(
      this.api,
      projection.repositoryId,
      projection.freshness,
    );
    registered.workingCopyRoot = projection.workingCopyRoot;
    registered.generation = projection.generation;
    registered.freshness = { ...projection.freshness };
    registered.quickDiffPaths = quickDiffPathsFromProjection(projection);
    const projectedGroupIds = new Set<string>(projection.groups.map((group) => group.id));
    for (const fixedGroupId of SCM_RESOURCE_GROUP_IDS) {
      if (!projectedGroupIds.has(fixedGroupId)) {
        throw new Error(`Source control projection is missing fixed resource group: ${fixedGroupId}`);
      }
    }
    for (const group of projection.groups) {
      const resourceGroup = ensureSourceControlGroup(this.api, registered, group);
      resourceGroup.resourceStates = group.resources.map((resource) =>
        resourceState(this.api, projection.workingCopyRoot, projection.generation, resource),
      );
    }
    for (const [groupId, resourceGroup] of registered.groups.entries()) {
      if (!projectedGroupIds.has(groupId)) {
        resourceGroup.dispose();
        registered.groups.delete(groupId);
      }
    }
    registered.groupOrder = projection.groups.map((group) => group.id);
  }

  public snapshotRepository(repositoryId: string): VscodeSourceControlSnapshot | undefined {
    const registered = this.repositories.get(repositoryId);
    if (!registered) {
      return undefined;
    }
    return {
      repositoryId: registered.repositoryId,
      epoch: registered.epoch,
      workingCopyRoot: registered.workingCopyRoot,
      generation: registered.generation,
      freshness: registered.freshness ? { ...registered.freshness } : undefined,
      count: registered.sourceControl.count,
      statusBarCommands: cloneCommands(registered.sourceControl.statusBarCommands),
      inputBox: {
        placeholder: registered.sourceControl.inputBox.placeholder,
        acceptInputCommand: registered.sourceControl.acceptInputCommand?.command,
        acceptInputCommandArguments: cloneCommandArguments(registered.sourceControl.acceptInputCommand?.arguments),
      },
      groups: registered.groupOrder.map((groupId) => {
        const group = registered.groups.get(groupId);
        if (!group) {
          throw new Error(`Source control resource group is not registered: ${groupId}`);
        }
        return sourceControlGroupSnapshot(this.api, registered.workingCopyRoot, groupId, group);
      }),
    };
  }

  public unregisterRepository(repositoryId: string): void {
    const registered = this.repositories.get(repositoryId);
    if (!registered) {
      return;
    }
    for (const group of registered.groups.values()) {
      group.dispose();
    }
    registered.sourceControl.dispose();
    this.repositories.delete(repositoryId);
  }

  private requireRegistered(repositoryId: string): RegisteredSourceControl {
    const registered = this.repositories.get(repositoryId);
    if (!registered) {
      throw new Error(`Source control repository is not registered: ${repositoryId}`);
    }
    return registered;
  }

  private updateCommitInput(sourceControl: VscodeSourceControl, repositoryId: string): void {
    if (!this.api.workspaceTrusted()) {
      sourceControl.inputBox.placeholder = this.api.localize("Trust this workspace to commit SVN changes");
      sourceControl.acceptInputCommand = undefined;
      return;
    }
    sourceControl.inputBox.placeholder = this.api.localize("SVN commit message");
    sourceControl.acceptInputCommand = {
      command: "subversionr.commitAll",
      title: this.api.localize("Commit"),
      arguments: [repositoryId],
    };
  }

  private provideOriginalResource(repositoryId: string, uri: unknown): unknown | undefined {
    const registered = this.repositories.get(repositoryId);
    if (!registered || registered.generation === undefined) {
      return undefined;
    }
    const fsPath = this.api.uriFsPath(uri);
    if (!fsPath) {
      return undefined;
    }
    const relativePath = repositoryRelativePath(registered.workingCopyRoot, fsPath);
    if (!relativePath) {
      return undefined;
    }
    const projectedPath = registered.quickDiffPaths.get(normalizeKeyPath(relativePath));
    if (!projectedPath) {
      return undefined;
    }

    return this.api.uriFromComponents(
      createBaseContentUriComponents({
        repositoryId: registered.repositoryId,
        epoch: registered.epoch,
        generation: registered.generation,
        path: projectedPath,
        revision: "base",
      }),
    );
  }
}

function freshnessStatusBarCommands(
  api: VscodeSourceControlPresenterApi,
  repositoryId: string,
  freshness: ScmProjectionFreshness,
): VscodeSourceControlCommand[] | undefined {
  if (freshness.repositoryCompleteness === "partial") {
    return [
      {
        command: "subversionr.fullReconcile",
        title: api.localize("SVN status partial"),
        arguments: [repositoryId],
      },
    ];
  }
  if (freshness.repositoryCompleteness === "stale") {
    return [
      {
        command: "subversionr.fullReconcile",
        title: api.localize("SVN status stale"),
        arguments: [repositoryId],
      },
    ];
  }
  return undefined;
}

function sourceControlGroupSnapshot(
  api: VscodeSourceControlPresenterApi,
  workingCopyRoot: string,
  id: string,
  group: VscodeSourceControlResourceGroup,
): VscodeSourceControlGroupSnapshot {
  return {
    id,
    contextValue: group.contextValue,
    hideWhenEmpty: group.hideWhenEmpty,
    count: group.resourceStates.length,
    resources: group.resourceStates.map((resource) => sourceControlResourceSnapshot(api, workingCopyRoot, resource)),
  };
}

function ensureSourceControlGroup(
  api: VscodeSourceControlPresenterApi,
  registered: RegisteredSourceControl,
  projectionGroup: ScmRepositoryProjection["groups"][number],
): VscodeSourceControlResourceGroup {
  const existing = registered.groups.get(projectionGroup.id);
  if (existing) {
    return existing;
  }
  if (!isChangelistResourceGroupId(projectionGroup.id) || projectionGroup.changelist === null) {
    throw new Error(`Source control resource group is not registered: ${projectionGroup.id}`);
  }
  const group = registered.sourceControl.createResourceGroup(
    projectionGroup.id,
    api.localize("Changelist: {0}", projectionGroup.changelist),
  );
  group.contextValue = CHANGELIST_GROUP_CONTEXT_VALUE;
  group.hideWhenEmpty = true;
  group.subversionrRepositoryId = registered.repositoryId;
  group.subversionrChangelistName = projectionGroup.changelist;
  registered.groups.set(projectionGroup.id, group);
  return group;
}

function sourceControlResourceSnapshot(
  api: VscodeSourceControlPresenterApi,
  workingCopyRoot: string,
  resource: VscodeSourceControlResourceState,
): VscodeSourceControlResourceSnapshot {
  const fsPath = api.uriFsPath(resource.resourceUri);
  const relativePath = fsPath ? repositoryRelativePath(workingCopyRoot, fsPath) : undefined;
  if (!relativePath) {
    throw new Error("Source control resource state must be inside the repository working copy root.");
  }
  return {
    path: relativePath,
    contextValue: resource.contextValue,
    kind: resource.subversionrResourceKind,
    generation: resource.subversionrProjectionGeneration,
  };
}

function cloneCommands(commands: VscodeSourceControlCommand[] | undefined): VscodeSourceControlCommand[] | undefined {
  return commands?.map((command) => ({
    command: command.command,
    title: command.title,
    ...(command.arguments ? { arguments: [...command.arguments] } : {}),
  }));
}

function cloneCommandArguments(arguments_: unknown[] | undefined): unknown[] | undefined {
  return arguments_ ? [...arguments_] : undefined;
}

function disposeRegisteredGroups(groups: Map<string, VscodeSourceControlResourceGroup>): void {
  for (const group of groups.values()) {
    disposeBestEffort(() => group.dispose());
  }
}

function disposeBestEffort(dispose: () => void): void {
  try {
    dispose();
  } catch {
    // Keep the original registration failure as the observable error.
  }
}

function setQuickDiffProvider(sourceControl: VscodeSourceControl, provider: VscodeSourceControlQuickDiffProvider): void {
  (sourceControl as VscodeSourceControl & { quickDiffProvider?: VscodeSourceControlQuickDiffProvider }).quickDiffProvider =
    provider;
}

function resourceState(
  api: VscodeSourceControlPresenterApi,
  workingCopyRoot: string,
  generation: number,
  resource: ScmProjectedResource,
): VscodeSourceControlResourceState {
  return {
    resourceUri: api.uriFile(nativePath(workingCopyRoot, resource.path)),
    contextValue: sourceControlResourceStateContextValue(resource),
    subversionrResourceKind: resource.entry.kind,
    subversionrProjectionGeneration: generation,
    decorations: {
      tooltip: resourceTooltip(api, resource),
    },
  };
}

function resourceTooltip(api: VscodeSourceControlPresenterApi, resource: ScmProjectedResource): string {
  const lines = [api.localize(RESOURCE_TOOLTIPS[resource.tooltipKey])];
  if (CHANGED_METADATA_TOOLTIP_KEYS.has(resource.tooltipKey)) {
    if (resource.entry.changedRevision >= 0) {
      lines.push(`${api.localize("SVN changed revision")}: r${resource.entry.changedRevision}`);
    }
    if (resource.entry.changedAuthor !== null) {
      lines.push(`${api.localize("SVN changed author")}: ${resource.entry.changedAuthor}`);
    }
    if (resource.entry.changedDate !== null) {
      lines.push(`${api.localize("SVN changed date")}: ${resource.entry.changedDate}`);
    }
  }
  if (resource.entry.copy !== null) {
    lines.push(`${api.localize("SVN copy from")}: ${resource.entry.copy}`);
  }
  if (resource.entry.move !== null) {
    lines.push(`${api.localize("SVN move from")}: ${resource.entry.move}`);
  }
  if (resource.entry.switched) {
    lines.push(api.localize("SVN switched node"));
  }
  if (resource.entry.lock !== null) {
    if (resource.entry.lock.isRemote) {
      lines.push(api.localize("SVN remote lock"));
    }
    if (resource.entry.lock.owner !== null) {
      lines.push(`${api.localize("SVN lock owner")}: ${resource.entry.lock.owner}`);
    } else {
      lines.push(api.localize("SVN locked"));
    }
    if (resource.entry.lock.comment !== null) {
      lines.push(`${api.localize("SVN lock comment")}: ${resource.entry.lock.comment}`);
    }
    if (resource.entry.lock.createdDate !== null) {
      lines.push(`${api.localize("SVN lock created")}: ${resource.entry.lock.createdDate}`);
    }
    if (resource.entry.lock.expiresDate !== null) {
      lines.push(`${api.localize("SVN lock expires")}: ${resource.entry.lock.expiresDate}`);
    }
    if (resource.entry.lock.token !== null) {
      lines.push(`${api.localize("SVN lock token")}: ${resource.entry.lock.token}`);
    }
  }
  if (resource.entry.needsLock) {
    lines.push(api.localize("SVN needs lock"));
  }
  if (isSparseStatusDepth(resource.entry.depth)) {
    lines.push(`${api.localize("SVN sparse depth")}: ${resource.entry.depth}`);
  }
  return lines.join("\n");
}

export function sourceControlResourceStateContextValue(resource: ScmProjectedResource): string {
  let contextValue = isBaseDiffableProjectedResource(resource) ? BASE_DIFFABLE_FILE_CONTEXT_VALUE : resource.contextValue;
  if (contextValue === WORKING_COPY_METADATA_CONTEXT_VALUE && resource.entry.kind === "file") {
    contextValue = WORKING_COPY_METADATA_FILE_CONTEXT_VALUE;
  }
  if (resource.entry.changelist !== null) {
    contextValue = CHANGELISTED_CONTEXT_VALUES.get(contextValue) ?? contextValue;
  }
  return resource.entry.lock === null || !LOCKED_CONTEXT_VALUES.has(contextValue)
    ? contextValue
    : `${contextValue}.locked`;
}

function nativePath(workingCopyRoot: string, repositoryRelativePath: string): string {
  if (repositoryRelativePath === ".") {
    return workingCopyRoot;
  }
  return nodePath.join(workingCopyRoot, ...repositoryRelativePath.split("/"));
}

function quickDiffPathsFromProjection(projection: ScmRepositoryProjection): Map<string, string> {
  const paths = new Map<string, string>();
  for (const group of projection.groups) {
    for (const resource of group.resources) {
      if (isQuickDiffResource(resource)) {
        paths.set(normalizeKeyPath(resource.path), resource.path);
      }
    }
  }
  return paths;
}

function isQuickDiffResource(resource: ScmProjectedResource): boolean {
  if (
    resource.source !== "local" ||
    resource.entry.kind !== "file" ||
    resource.entry.external ||
    resource.entry.localStatus === "ignored"
  ) {
    return false;
  }
  if (isBaseDiffableProjectedResource(resource)) {
    return true;
  }
  return resource.groupId === "conflicts";
}

function repositoryRelativePath(workingCopyRoot: string, fsPath: string): string | undefined {
  const root = normalizeAbsolutePath(workingCopyRoot);
  const candidate = normalizeAbsolutePath(fsPath);
  if (candidate === root) {
    return ".";
  }
  const prefix = `${root}/`;
  if (!candidate.startsWith(prefix)) {
    return undefined;
  }
  const relative = candidate.slice(prefix.length);
  return relative.length > 0 ? relative : undefined;
}

function normalizeAbsolutePath(path: string): string {
  const normalized = path.replace(/\\/g, "/").replace(/\/+$/u, "");
  return process.platform === "win32" ? normalized.toLocaleLowerCase("en-US") : normalized;
}

function normalizeKeyPath(path: string): string {
  const normalized = path.replace(/\\/g, "/");
  return process.platform === "win32" ? normalized.toLocaleLowerCase("en-US") : normalized;
}
