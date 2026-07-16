import type { StatusDelta } from "../status/statusRefreshRpcClient";
import type { StatusEntry, StatusSnapshot } from "../status/statusSnapshotRpcClient";
import type { StatusStaleMark } from "../status/statusSnapshotStore";
import type { PathCasePolicy } from "../status/types";
import {
  classifyLocalStatusEntry,
  classifyRemoteStatusEntry,
  changelistNameFromResourceGroupId,
  isChangelistResourceGroupId,
  type ScmResourceClassification,
  type ScmResourceGroupId,
} from "./resourceStateClassifier";

export const SCM_RESOURCE_GROUP_IDS = [
  "conflicts",
  "conflictArtifacts",
  "changes",
  "unversioned",
  "metadata",
  "incoming",
  "externals",
  "ignored",
] as const satisfies readonly ScmResourceGroupId[];

export interface SourceControlProjectionRepository {
  repositoryId: string;
  epoch: number;
  workingCopyRoot: string;
}

export interface SourceControlCountPolicy {
  countUnversioned: boolean;
  ignoreChangelistsInCount: string[];
}

export interface SourceControlResourceStoreOptions {
  countPolicy: SourceControlCountPolicy;
}

export interface ScmProjectedResource {
  key: string;
  repositoryId: string;
  path: string;
  source: "local" | "remote";
  groupId: ScmResourceGroupId;
  contextValue: string;
  tooltipKey: string;
  entry: StatusEntry;
}

export interface ScmProjectedResourceGroup {
  id: ScmResourceGroupId;
  labelKey: string;
  changelist: string | null;
  resources: ScmProjectedResource[];
}

export interface ScmRepositoryProjection {
  repositoryId: string;
  epoch: number;
  workingCopyRoot: string;
  generation: number;
  freshness: ScmProjectionFreshness;
  count: number;
  groups: ScmProjectedResourceGroup[];
}

export type ScmProjectionRefreshKind = "snapshot" | "delta" | "stale";

export interface ScmProjectionFreshness {
  repositoryCompleteness: StatusSnapshot["completeness"];
  lastRefreshCompleteness: StatusSnapshot["completeness"];
  lastRefreshKind: ScmProjectionRefreshKind;
}

export interface ScmCommitAllTarget {
  path: string;
  changelist: string | null;
  status: string;
  directory: string;
}

export interface ScmCommitAllTargets {
  repositoryId: string;
  epoch: number;
  workingCopyRoot: string;
  generation: number;
  hasConflicts: boolean;
  targets: ScmCommitAllTarget[];
}

export interface ScmProjectedResourceLookup {
  repositoryId: string;
  epoch: number;
  workingCopyRoot: string;
  generation: number;
  resource: ScmProjectedResource;
}

export type SourceControlResourceStoreErrorCategory = "input" | "lifecycle";

interface RepositoryProjectionState {
  repositoryId: string;
  epoch: number;
  workingCopyRoot: string;
  generation: number | undefined;
  freshness: ScmProjectionFreshness | undefined;
  localEntriesByPath: Map<string, StatusEntry>;
  conflictArtifactPathsByOwner: Map<string, Set<string>>;
  conflictArtifactOwnersByPath: Map<string, Set<string>>;
  localResourcesByPath: Map<string, ScmProjectedResource>;
  localResourcesByCaseInsensitivePath: Map<string, ScmProjectedResource>;
  remoteResourcesByPath: Map<string, ScmProjectedResource>;
  groups: Map<ScmResourceGroupId, Map<string, ScmProjectedResource>>;
}

export class SourceControlResourceStoreError extends Error {
  public constructor(
    public readonly code: string,
    public readonly category: SourceControlResourceStoreErrorCategory,
    public readonly messageKey: string,
    public readonly safeArgs: Record<string, unknown> = {},
  ) {
    super(code);
    this.name = "SourceControlResourceStoreError";
  }
}

export class SourceControlResourceStore {
  private readonly repositories = new Map<string, RepositoryProjectionState>();
  private countPolicy: SourceControlCountPolicy;

  public constructor(options: SourceControlResourceStoreOptions) {
    this.countPolicy = validateCountPolicy(options.countPolicy);
  }

  public registerRepository(repository: SourceControlProjectionRepository): void {
    if (!isNonEmptyString(repository.repositoryId)) {
      throw storeInputError("repositoryId");
    }
    if (!Number.isSafeInteger(repository.epoch) || repository.epoch < 0) {
      throw storeInputError("epoch");
    }
    if (!isNonEmptyString(repository.workingCopyRoot)) {
      throw storeInputError("workingCopyRoot");
    }
    if (this.repositories.has(repository.repositoryId)) {
      throw new SourceControlResourceStoreError(
        "SUBVERSIONR_SCM_PROJECTION_REPOSITORY_ALREADY_REGISTERED",
        "lifecycle",
        "error.scm.projectionRepositoryAlreadyRegistered",
        { repositoryId: repository.repositoryId },
      );
    }
    this.repositories.set(repository.repositoryId, {
      repositoryId: repository.repositoryId,
      epoch: repository.epoch,
      workingCopyRoot: repository.workingCopyRoot,
      generation: undefined,
      freshness: undefined,
      localEntriesByPath: new Map(),
      conflictArtifactPathsByOwner: new Map(),
      conflictArtifactOwnersByPath: new Map(),
      localResourcesByPath: new Map(),
      localResourcesByCaseInsensitivePath: new Map(),
      remoteResourcesByPath: new Map(),
      groups: emptyGroupMaps(),
    });
  }

  public unregisterRepository(repositoryId: string): void {
    this.repositories.delete(repositoryId);
  }

  public applySnapshot(snapshot: StatusSnapshot): ScmRepositoryProjection {
    const state = this.requireRepository(snapshot.repositoryId);
    this.requireEpoch(state, snapshot.epoch, "snapshot");
    if (state.generation !== undefined && snapshot.generation < state.generation) {
      throw new SourceControlResourceStoreError(
        "SUBVERSIONR_SCM_PROJECTION_SNAPSHOT_GENERATION_STALE",
        "lifecycle",
        "error.scm.projectionGenerationStale",
        {
          repositoryId: state.repositoryId,
          current: state.generation,
          actual: snapshot.generation,
        },
      );
    }

    return this.applySnapshotToState(state, snapshot);
  }

  public replaceSnapshot(snapshot: StatusSnapshot): ScmRepositoryProjection {
    const state = this.requireRepository(snapshot.repositoryId);
    if (state.epoch === snapshot.epoch && state.generation !== undefined && snapshot.generation < state.generation) {
      throw new SourceControlResourceStoreError(
        "SUBVERSIONR_SCM_PROJECTION_SNAPSHOT_GENERATION_STALE",
        "lifecycle",
        "error.scm.projectionGenerationStale",
        {
          repositoryId: state.repositoryId,
          current: state.generation,
          actual: snapshot.generation,
        },
      );
    }
    state.epoch = snapshot.epoch;
    return this.applySnapshotToState(state, snapshot);
  }

  private applySnapshotToState(
    state: RepositoryProjectionState,
    snapshot: StatusSnapshot,
  ): ScmRepositoryProjection {
    state.generation = snapshot.generation;
    state.freshness = {
      repositoryCompleteness: snapshot.completeness,
      lastRefreshCompleteness: snapshot.completeness,
      lastRefreshKind: "snapshot",
    };
    state.workingCopyRoot = snapshot.identity.workingCopyRoot;
    state.localEntriesByPath = new Map(snapshot.localEntries.map((entry) => [entry.path, cloneStatusEntry(entry)]));
    state.conflictArtifactPathsByOwner = new Map();
    state.conflictArtifactOwnersByPath = new Map();
    state.localResourcesByPath = new Map();
    state.localResourcesByCaseInsensitivePath = new Map();
    state.remoteResourcesByPath = new Map();
    state.groups = emptyGroupMaps();
    for (const entry of state.localEntriesByPath.values()) {
      addConflictArtifactOwner(state, entry);
    }
    const localPaths = new Set([
      ...state.localEntriesByPath.keys(),
      ...state.conflictArtifactOwnersByPath.keys(),
    ]);
    for (const path of localPaths) {
      this.projectLocalPath(state, path);
    }
    for (const entry of snapshot.remoteEntries) {
      this.upsertRemoteEntry(state, entry);
    }
    return projectionFromState(state, this.countPolicy);
  }

  public applyDelta(delta: StatusDelta): ScmRepositoryProjection {
    const state = this.requireRepository(delta.repositoryId);
    this.requireEpoch(state, delta.epoch, "delta");
    if (state.generation === undefined) {
      throw new SourceControlResourceStoreError(
        "SUBVERSIONR_SCM_PROJECTION_STATE_UNINITIALIZED",
        "lifecycle",
        "error.scm.projectionStateUninitialized",
        { repositoryId: state.repositoryId },
      );
    }
    if (delta.generation <= state.generation) {
      throw new SourceControlResourceStoreError(
        "SUBVERSIONR_SCM_PROJECTION_DELTA_GENERATION_STALE",
        "lifecycle",
        "error.scm.projectionGenerationStale",
        {
          repositoryId: state.repositoryId,
          current: state.generation,
          actual: delta.generation,
        },
      );
    }

    const affectedLocalPaths = new Set<string>();
    for (const path of delta.remove) {
      this.removeLocalEntry(state, path, affectedLocalPaths);
    }
    for (const entry of delta.upsert) {
      this.removeLocalEntry(state, entry.path, affectedLocalPaths);
      state.localEntriesByPath.set(entry.path, cloneStatusEntry(entry));
      addConflictArtifactOwner(state, entry);
      affectedLocalPaths.add(entry.path);
      for (const artifactPath of entry.conflictArtifacts) {
        affectedLocalPaths.add(artifactPath);
      }
    }
    for (const path of affectedLocalPaths) {
      this.removeProjectedLocalPath(state, path);
    }
    for (const path of affectedLocalPaths) {
      this.projectLocalPath(state, path);
    }
    for (const path of delta.remoteRemove) {
      this.removeRemotePath(state, path);
    }
    for (const entry of delta.remoteUpsert) {
      this.removeRemotePath(state, entry.path);
      this.upsertRemoteEntry(state, entry);
    }
    state.generation = delta.generation;
    state.freshness = freshnessAfterDelta(requireFreshness(state), delta.completeness);
    return projectionFromState(state, this.countPolicy);
  }

  public markStale(mark: StatusStaleMark): ScmRepositoryProjection {
    const state = this.requireRepository(mark.repositoryId);
    this.requireEpoch(state, mark.epoch, "stale");
    if (state.generation === undefined) {
      throw new SourceControlResourceStoreError(
        "SUBVERSIONR_SCM_PROJECTION_STATE_UNINITIALIZED",
        "lifecycle",
        "error.scm.projectionStateUninitialized",
        { repositoryId: state.repositoryId },
      );
    }
    state.freshness = {
      repositoryCompleteness: "stale",
      lastRefreshCompleteness: "stale",
      lastRefreshKind: "stale",
    };
    return projectionFromState(state, this.countPolicy);
  }

  public getProjection(repositoryId: string): ScmRepositoryProjection | undefined {
    const state = this.repositories.get(repositoryId);
    if (!state || state.generation === undefined) {
      return undefined;
    }
    return projectionFromState(state, this.countPolicy);
  }

  public updateCountPolicy(countPolicy: SourceControlCountPolicy): ScmRepositoryProjection[] {
    const validatedPolicy = validateCountPolicy(countPolicy);
    const projections = Array.from(this.repositories.values())
      .filter((state) => state.generation !== undefined)
      .map((state) => projectionFromState(state, validatedPolicy));
    this.countPolicy = validatedPolicy;
    return projections;
  }

  public getProjectedResource(
    repositoryId: string,
    path: string,
    pathCase: PathCasePolicy,
  ): ScmProjectedResourceLookup | undefined {
    const state = this.repositories.get(repositoryId);
    if (!state || state.generation === undefined || !isRepositoryRelativeLookupPath(path)) {
      return undefined;
    }
    const resource =
      pathCase === "case-insensitive"
        ? state.localResourcesByCaseInsensitivePath.get(caseInsensitivePath(path))
        : state.localResourcesByPath.get(path);
    if (!resource) {
      return undefined;
    }
    return {
      repositoryId: state.repositoryId,
      epoch: state.epoch,
      workingCopyRoot: state.workingCopyRoot,
      generation: state.generation,
      resource: cloneProjectedResource(resource),
    };
  }

  public getCommitAllTargets(repositoryId: string): ScmCommitAllTargets | undefined {
    const state = this.repositories.get(repositoryId);
    if (!state || state.generation === undefined) {
      return undefined;
    }
    return commitAllTargetsFromState(state, this.countPolicy);
  }

  private requireRepository(repositoryId: string): RepositoryProjectionState {
    const state = this.repositories.get(repositoryId);
    if (!state) {
      throw new SourceControlResourceStoreError(
        "SUBVERSIONR_SCM_PROJECTION_REPOSITORY_NOT_REGISTERED",
        "lifecycle",
        "error.scm.projectionRepositoryNotRegistered",
        { repositoryId },
      );
    }
    return state;
  }

  private requireEpoch(state: RepositoryProjectionState, actual: number, source: "snapshot" | "delta" | "stale"): void {
    if (state.epoch === actual) {
      return;
    }
    throw new SourceControlResourceStoreError(
      projectionEpochMismatchCode(source),
      "lifecycle",
      "error.scm.projectionEpochMismatch",
      {
        repositoryId: state.repositoryId,
        expected: state.epoch,
        actual,
      },
    );
  }

  private projectLocalPath(state: RepositoryProjectionState, path: string): void {
    const artifactOwners = state.conflictArtifactOwnersByPath.get(path);
    const ownerPath = artifactOwners ? Array.from(artifactOwners).sort(comparePaths)[0] : undefined;
    const ownerEntry = ownerPath ? state.localEntriesByPath.get(ownerPath) : undefined;
    if (ownerEntry) {
      this.upsertProjectedLocalEntry(
        state,
        {
          ...cloneStatusEntry(ownerEntry),
          path,
          kind: "file",
          conflictArtifacts: [],
        },
        {
          groupId: "conflictArtifacts",
          contextValue: "subversionr.conflictArtifact",
          tooltipKey: "scm.resource.conflictArtifact",
        },
      );
      return;
    }
    const entry = state.localEntriesByPath.get(path);
    if (!entry) {
      return;
    }
    const classification = classifyLocalStatusEntry(entry);
    if (!classification) {
      return;
    }
    this.upsertProjectedLocalEntry(state, entry, classification);
  }

  private upsertProjectedLocalEntry(
    state: RepositoryProjectionState,
    entry: StatusEntry,
    classification: ScmResourceClassification,
  ): void {
    const resource = projectedResource(state.repositoryId, "local", entry, classification);
    state.localResourcesByPath.set(entry.path, resource);
    state.localResourcesByCaseInsensitivePath.set(caseInsensitivePath(entry.path), resource);
    upsertGroupResource(state, resource);
  }

  private upsertRemoteEntry(state: RepositoryProjectionState, entry: StatusEntry): void {
    const classification = classifyRemoteStatusEntry(entry);
    if (!classification) {
      return;
    }
    const resource = projectedResource(state.repositoryId, "remote", entry, classification);
    state.remoteResourcesByPath.set(entry.path, resource);
    upsertGroupResource(state, resource);
  }

  private removeLocalEntry(
    state: RepositoryProjectionState,
    path: string,
    affectedPaths: Set<string>,
  ): void {
    affectedPaths.add(path);
    const artifacts = state.conflictArtifactPathsByOwner.get(path);
    if (artifacts) {
      for (const artifactPath of artifacts) {
        affectedPaths.add(artifactPath);
        const owners = state.conflictArtifactOwnersByPath.get(artifactPath);
        owners?.delete(path);
        if (owners?.size === 0) {
          state.conflictArtifactOwnersByPath.delete(artifactPath);
        }
      }
      state.conflictArtifactPathsByOwner.delete(path);
    }
    state.localEntriesByPath.delete(path);
  }

  private removeProjectedLocalPath(state: RepositoryProjectionState, path: string): void {
    const existing = state.localResourcesByPath.get(path);
    if (!existing) {
      return;
    }
    state.groups.get(existing.groupId)?.delete(existing.key);
    state.localResourcesByPath.delete(path);
    state.localResourcesByCaseInsensitivePath.delete(caseInsensitivePath(existing.path));
  }

  private removeRemotePath(state: RepositoryProjectionState, path: string): void {
    const existing = state.remoteResourcesByPath.get(path);
    if (!existing) {
      return;
    }
    state.groups.get(existing.groupId)?.delete(existing.key);
    state.remoteResourcesByPath.delete(path);
  }
}

function projectionEpochMismatchCode(source: "snapshot" | "delta" | "stale"): string {
  if (source === "snapshot") {
    return "SUBVERSIONR_SCM_PROJECTION_SNAPSHOT_EPOCH_MISMATCH";
  }
  if (source === "delta") {
    return "SUBVERSIONR_SCM_PROJECTION_DELTA_EPOCH_MISMATCH";
  }
  return "SUBVERSIONR_SCM_PROJECTION_STALE_EPOCH_MISMATCH";
}

function projectedResource(
  repositoryId: string,
  source: "local" | "remote",
  entry: StatusEntry,
  classification: ScmResourceClassification,
): ScmProjectedResource {
  return {
    key: `${source}:${entry.path}`,
    repositoryId,
    path: entry.path,
    source,
    groupId: classification.groupId,
    contextValue: classification.contextValue,
    tooltipKey: classification.tooltipKey,
    entry: cloneStatusEntry(entry),
  };
}

function cloneProjectedResource(resource: ScmProjectedResource): ScmProjectedResource {
  return {
    ...resource,
    entry: cloneStatusEntry(resource.entry),
  };
}

function cloneStatusEntry(entry: StatusEntry): StatusEntry {
  return {
    ...entry,
    lock: entry.lock ? { ...entry.lock } : null,
    conflictArtifacts: [...entry.conflictArtifacts],
  };
}

function projectionFromState(
  state: RepositoryProjectionState,
  countPolicy: SourceControlCountPolicy,
): ScmRepositoryProjection {
  if (state.generation === undefined) {
    throw new SourceControlResourceStoreError(
      "SUBVERSIONR_SCM_PROJECTION_STATE_UNINITIALIZED",
      "lifecycle",
      "error.scm.projectionStateUninitialized",
      { repositoryId: state.repositoryId },
    );
  }
  return {
    repositoryId: state.repositoryId,
    epoch: state.epoch,
    workingCopyRoot: state.workingCopyRoot,
    generation: state.generation,
    freshness: cloneFreshness(requireFreshness(state)),
    count: projectionCount(state, countPolicy),
    groups: projectionGroupsFromState(state),
  };
}

function projectionGroupsFromState(state: RepositoryProjectionState): ScmProjectedResourceGroup[] {
  return [
    fixedProjectionGroup(state, "conflicts"),
    fixedProjectionGroup(state, "conflictArtifacts"),
    ...changelistProjectionGroups(state),
    fixedProjectionGroup(state, "changes"),
    fixedProjectionGroup(state, "unversioned"),
    fixedProjectionGroup(state, "metadata"),
    fixedProjectionGroup(state, "incoming"),
    fixedProjectionGroup(state, "externals"),
    fixedProjectionGroup(state, "ignored"),
  ];
}

function addConflictArtifactOwner(state: RepositoryProjectionState, entry: StatusEntry): void {
  if (entry.conflictArtifacts.length === 0) {
    return;
  }
  const artifacts = new Set(entry.conflictArtifacts);
  state.conflictArtifactPathsByOwner.set(entry.path, artifacts);
  for (const artifactPath of artifacts) {
    let owners = state.conflictArtifactOwnersByPath.get(artifactPath);
    if (!owners) {
      owners = new Set();
      state.conflictArtifactOwnersByPath.set(artifactPath, owners);
    }
    owners.add(entry.path);
  }
}

function comparePaths(left: string, right: string): number {
  return left.localeCompare(right, "en-US");
}

function fixedProjectionGroup(state: RepositoryProjectionState, groupId: (typeof SCM_RESOURCE_GROUP_IDS)[number]): ScmProjectedResourceGroup {
  return {
    id: groupId,
    labelKey: `scm.group.${groupId}`,
    changelist: null,
    resources: sortedResources(state.groups.get(groupId) ?? new Map()),
  };
}

function changelistProjectionGroups(state: RepositoryProjectionState): ScmProjectedResourceGroup[] {
  return Array.from(state.groups.entries())
    .flatMap(([groupId, resources]) =>
      isChangelistResourceGroupId(groupId) && resources.size > 0 ? [[groupId, resources] as const] : [],
    )
    .sort(([left], [right]) =>
      changelistNameFromResourceGroupId(left).localeCompare(changelistNameFromResourceGroupId(right), "en-US"),
    )
    .map(([groupId, resources]) => ({
      id: groupId,
      labelKey: "scm.group.changelist",
      changelist: changelistNameFromResourceGroupId(groupId),
      resources: sortedResources(resources),
    }));
}

function requireFreshness(state: RepositoryProjectionState): ScmProjectionFreshness {
  if (!state.freshness) {
    throw new SourceControlResourceStoreError(
      "SUBVERSIONR_SCM_PROJECTION_FRESHNESS_UNINITIALIZED",
      "lifecycle",
      "error.scm.projectionFreshnessUninitialized",
      { repositoryId: state.repositoryId },
    );
  }
  return state.freshness;
}

function freshnessAfterDelta(
  current: ScmProjectionFreshness,
  deltaCompleteness: StatusSnapshot["completeness"],
): ScmProjectionFreshness {
  return {
    repositoryCompleteness:
      deltaCompleteness === "partial" ? current.repositoryCompleteness : deltaCompleteness,
    lastRefreshCompleteness: deltaCompleteness,
    lastRefreshKind: "delta",
  };
}

function cloneFreshness(freshness: ScmProjectionFreshness): ScmProjectionFreshness {
  return { ...freshness };
}

function projectionCount(state: RepositoryProjectionState, countPolicy: SourceControlCountPolicy): number {
  const ignoredChangelists = new Set(countPolicy.ignoreChangelistsInCount);
  let count = 0;
  for (const resource of state.localResourcesByPath.values()) {
    if (resource.entry.external || resource.entry.localStatus === "ignored") {
      continue;
    }
    if (resource.entry.changelist !== null && ignoredChangelists.has(resource.entry.changelist)) {
      continue;
    }
    if (resource.groupId === "conflicts" || isCountedLocalChangeResource(resource)) {
      count += 1;
    } else if (resource.groupId === "unversioned" && countPolicy.countUnversioned) {
      count += 1;
    }
  }
  return count;
}

function isCountedLocalChangeResource(resource: ScmProjectedResource): boolean {
  return isLocalChangeGroup(resource.groupId) && resource.contextValue !== "subversionr.workingCopyMetadata";
}

function commitAllTargetsFromState(
  state: RepositoryProjectionState,
  countPolicy: SourceControlCountPolicy,
): ScmCommitAllTargets {
  if (state.generation === undefined) {
    throw new SourceControlResourceStoreError(
      "SUBVERSIONR_SCM_PROJECTION_STATE_UNINITIALIZED",
      "lifecycle",
      "error.scm.projectionStateUninitialized",
      { repositoryId: state.repositoryId },
    );
  }
  const ignoredChangelists = new Set(countPolicy.ignoreChangelistsInCount);
  const changes = sortedResources(
    new Map(
      Array.from(state.localResourcesByPath.values())
        .filter((resource) => isLocalChangeGroup(resource.groupId))
        .map((resource) => [resource.key, resource]),
    ),
  );
  return {
    repositoryId: state.repositoryId,
    epoch: state.epoch,
    workingCopyRoot: state.workingCopyRoot,
    generation: state.generation,
    hasConflicts: (state.groups.get("conflicts")?.size ?? 0) > 0,
    targets: changes
      .filter((resource) => isCommitAllCandidate(resource, ignoredChangelists))
      .map((resource) => commitAllTargetFromResource(state.repositoryId, resource)),
  };
}

function isCommitAllCandidate(resource: ScmProjectedResource, ignoredChangelists: ReadonlySet<string>): boolean {
  return (
    resource.source === "local" &&
    isLocalChangeGroup(resource.groupId) &&
    resource.contextValue === "subversionr.changedFile" &&
    resource.entry.kind === "file" &&
    !resource.entry.external &&
    resource.entry.localStatus !== "ignored" &&
    (resource.entry.changelist === null || !ignoredChangelists.has(resource.entry.changelist))
  );
}

function isLocalChangeGroup(groupId: ScmResourceGroupId): boolean {
  return groupId === "changes" || isChangelistResourceGroupId(groupId);
}

function commitAllTargetFromResource(repositoryId: string, resource: ScmProjectedResource): ScmCommitAllTarget {
  if (!isRepositoryRelativeCommitPath(resource.path)) {
    throw new SourceControlResourceStoreError(
      "SUBVERSIONR_SCM_PROJECTION_COMMIT_ALL_TARGET_INVALID",
      "lifecycle",
      "error.scm.projectionCommitAllTargetInvalid",
      { repositoryId, path: resource.path },
    );
  }
  return {
    path: resource.path,
    changelist: resource.entry.changelist,
    status: commitAllTargetStatus(resource.entry),
    directory: repositoryRelativeParentDirectory(resource.path),
  };
}

function commitAllTargetStatus(entry: StatusEntry): string {
  for (const status of [entry.localStatus, entry.nodeStatus, entry.textStatus, entry.propertyStatus]) {
    if (status !== "none" && status !== "normal" && status !== "notChecked") {
      return status;
    }
  }
  return entry.localStatus;
}

function repositoryRelativeParentDirectory(path: string): string {
  const index = path.lastIndexOf("/");
  return index === -1 ? "." : path.slice(0, index);
}

function isRepositoryRelativeCommitPath(path: string): boolean {
  if (path.trim().length === 0 || path.includes("\\") || path.startsWith("/") || path.endsWith("/")) {
    return false;
  }
  const parts = path.split("/");
  return !parts.some((part) => part.length === 0 || part === "." || part === "..");
}

function isRepositoryRelativeLookupPath(path: string): boolean {
  if (path === "." || path.trim().length === 0 || path.includes("\\") || path.startsWith("/") || path.endsWith("/")) {
    return false;
  }
  const parts = path.split("/");
  return !parts.some((part) => part.length === 0 || part === "." || part === "..");
}

function caseInsensitivePath(path: string): string {
  return path.toLocaleLowerCase("en-US");
}

function validateCountPolicy(countPolicy: SourceControlCountPolicy): SourceControlCountPolicy {
  if (typeof countPolicy.countUnversioned !== "boolean") {
    throw storeInputError("countPolicy.countUnversioned");
  }
  if (!Array.isArray(countPolicy.ignoreChangelistsInCount)) {
    throw storeInputError("countPolicy.ignoreChangelistsInCount");
  }
  return {
    countUnversioned: countPolicy.countUnversioned,
    ignoreChangelistsInCount: countPolicy.ignoreChangelistsInCount.map((changelist, index) => {
      if (typeof changelist !== "string" || changelist.trim().length === 0) {
        throw storeInputError(`countPolicy.ignoreChangelistsInCount.${index}`);
      }
      return changelist;
    }),
  };
}

function sortedResources(resources: Map<string, ScmProjectedResource>): ScmProjectedResource[] {
  return Array.from(resources.values())
    .map(cloneProjectedResource)
    .sort((left, right) => left.path.localeCompare(right.path) || left.source.localeCompare(right.source));
}

function emptyGroupMaps(): Map<ScmResourceGroupId, Map<string, ScmProjectedResource>> {
  return new Map(SCM_RESOURCE_GROUP_IDS.map((groupId) => [groupId, new Map<string, ScmProjectedResource>()]));
}

function upsertGroupResource(state: RepositoryProjectionState, resource: ScmProjectedResource): void {
  let group = state.groups.get(resource.groupId);
  if (!group) {
    group = new Map<string, ScmProjectedResource>();
    state.groups.set(resource.groupId, group);
  }
  group.set(resource.key, resource);
}

function isNonEmptyString(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0;
}

function storeInputError(field: string): SourceControlResourceStoreError {
  return new SourceControlResourceStoreError(
    "SUBVERSIONR_SCM_PROJECTION_INPUT_INVALID",
    "input",
    "error.scm.projectionInputInvalid",
    { field },
  );
}
