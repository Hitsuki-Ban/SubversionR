import type {
  DirtyFileEvent,
  FileEventKind,
  RepositoryWatchScope,
  StatusRefreshDepth,
  StatusRefreshTarget,
} from "./types";

export interface DirtyPathSetOptions {
  maxDirtyPaths?: number;
}

interface DirtyPathRecord {
  path: string;
  eventKinds: Set<FileEventKind>;
  firstKind: FileEventKind;
  lastKind: FileEventKind;
  firstTimestamp: number;
  lastTimestamp: number;
  eventCount: number;
}

interface SubtreeFoldGroup {
  ancestor: string;
  paths: string[];
}

const DEFAULT_MAX_DIRTY_PATHS = 512;

export class DirtyPathSet {
  private readonly entries = new Map<string, DirtyPathRecord>();
  private readonly explicitTargets = new Map<string, StatusRefreshTarget>();
  private readonly foldedTargets = new Map<string, StatusRefreshTarget>();
  private readonly maxDirtyPaths: number;
  private overflowed = false;
  private overflowedAt: number | undefined;

  public constructor(
    private readonly scope: RepositoryWatchScope,
    options: DirtyPathSetOptions = {},
  ) {
    this.maxDirtyPaths = options.maxDirtyPaths ?? DEFAULT_MAX_DIRTY_PATHS;
  }

  public get size(): number {
    return this.overflowed ? 1 : this.entries.size + this.explicitTargets.size + this.foldedTargets.size;
  }

  public get isOverflowed(): boolean {
    return this.overflowed;
  }

  public get overflowTimestamp(): number | undefined {
    return this.overflowedAt;
  }

  public record(event: DirtyFileEvent): boolean {
    if (this.overflowed) {
      return true;
    }

    const normalized = repositoryRelativePath(this.scope, event.path);
    if (!normalized) {
      return false;
    }
    if (this.mergeIntoFoldedTargetIfCovered(normalized, event.kind)) {
      return true;
    }

    const key = comparisonKey(this.scope, normalized);
    const existing = this.entries.get(key);
    if (existing) {
      existing.eventKinds.add(event.kind);
      if (event.timestamp < existing.firstTimestamp) {
        existing.firstTimestamp = event.timestamp;
      }
      if (event.timestamp > existing.lastTimestamp) {
        existing.lastTimestamp = event.timestamp;
      }
      existing.lastKind = event.kind;
      existing.eventCount += 1;
      return true;
    }

    this.entries.set(key, {
      path: normalized,
      eventKinds: new Set([event.kind]),
      firstKind: event.kind,
      lastKind: event.kind,
      firstTimestamp: event.timestamp,
      lastTimestamp: event.timestamp,
      eventCount: 1,
    });

    if (this.watcherQueueSize() > this.maxDirtyPaths) {
      this.foldSiblingRecordsIntoTargets();
      if (this.watcherQueueSize() > this.maxDirtyPaths) {
        this.foldSubtreeRecordsIntoTargets();
        if (this.watcherQueueSize() > this.maxDirtyPaths) {
          this.entries.clear();
          this.foldedTargets.clear();
          this.overflowed = true;
          this.overflowedAt = event.timestamp;
        }
      }
    }

    return true;
  }

  public toRefreshTargets(): StatusRefreshTarget[] {
    if (this.overflowed) {
      return [{ path: ".", depth: "infinity", reason: "watcherOverflow" }];
    }

    const targets = new Map<string, StatusRefreshTarget>();
    for (const target of this.explicitTargets.values()) {
      targets.set(targetKey(target), target);
    }
    for (const target of this.foldedTargets.values()) {
      targets.set(targetKey(target), target);
    }
    for (const record of this.sortedRecords()) {
      for (const target of targetsForRecord(record)) {
        targets.set(targetKey(target), target);
      }
    }

    return Array.from(targets.values()).sort(compareTargets);
  }

  public drainToRefreshTargets(): StatusRefreshTarget[] {
    const targets = this.toRefreshTargets();
    this.clear();
    return targets;
  }

  public clear(): void {
    this.entries.clear();
    this.explicitTargets.clear();
    this.foldedTargets.clear();
    this.overflowed = false;
    this.overflowedAt = undefined;
  }

  public mergeTargets(targets: StatusRefreshTarget[]): void {
    if (targets.length === 0) {
      return;
    }
    if (targets.some((target) => target.path === "." && target.depth === "infinity")) {
      this.entries.clear();
      this.explicitTargets.clear();
      this.foldedTargets.clear();
      this.overflowed = true;
      return;
    }

    for (const target of targets) {
      this.explicitTargets.set(targetKey(target), target);
    }
  }

  private sortedRecords(): DirtyPathRecord[] {
    return Array.from(this.entries.values()).sort((left, right) => compareText(left.path, right.path));
  }

  private foldSiblingRecordsIntoTargets(): void {
    const groups = new Map<string, DirtyPathRecord[]>();
    for (const record of this.entries.values()) {
      if (record.eventKinds.has("rename")) {
        continue;
      }
      const parent = parentPath(record.path);
      const key = comparisonKey(this.scope, parent);
      const group = groups.get(key);
      if (group) {
        group.push(record);
      } else {
        groups.set(key, [record]);
      }
    }

    const foldableGroups = Array.from(groups.values())
      .filter((records) => records.length > 1)
      .sort((left, right) => right.length - left.length || compareText(left[0]?.path ?? "", right[0]?.path ?? ""));

    for (const records of foldableGroups) {
      if (this.watcherQueueSize() <= this.maxDirtyPaths) {
        return;
      }
      const [first] = records;
      if (!first) {
        continue;
      }
      const parent = parentPath(first.path);
      const depth = records.some((record) => requiresSiblingDirectoryEntries(record)) ? "immediates" : "files";
      this.setFoldedTarget(parent, depth, "dirtyPathFold");
      for (const record of records) {
        this.entries.delete(comparisonKey(this.scope, record.path));
      }
    }
  }

  private mergeIntoFoldedTargetIfCovered(path: string, kind: FileEventKind): boolean {
    const target = this.findFoldedTargetCovering(path);
    if (!target) {
      return false;
    }
    if (target.depth !== "infinity" && (kind === "create" || kind === "delete")) {
      this.setFoldedTarget(target.path, "immediates", "dirtyPathFold");
    }
    return true;
  }

  private findFoldedTargetCovering(path: string): StatusRefreshTarget | undefined {
    const directParent = parentPath(path);
    const directTarget = this.foldedTargets.get(comparisonKey(this.scope, directParent));
    if (directTarget && isDirectChild(directParent, path)) {
      return directTarget;
    }

    const infinityTargets = Array.from(this.foldedTargets.values())
      .filter((target) => target.depth === "infinity" && this.isDescendantOf(target.path, path))
      .sort((left, right) => pathDepth(right.path) - pathDepth(left.path) || compareText(left.path, right.path));
    return infinityTargets[0];
  }

  private setFoldedTarget(
    path: string,
    depth: Extract<StatusRefreshDepth, "files" | "immediates" | "infinity">,
    reason: string,
  ): void {
    const key = comparisonKey(this.scope, path);
    const existing = this.foldedTargets.get(key);
    const targetDepth = existing && depthRank(existing.depth) > depthRank(depth) ? existing.depth : depth;
    this.foldedTargets.set(key, {
      path,
      depth: targetDepth,
      reason,
    });
  }

  private watcherQueueSize(): number {
    return this.entries.size + this.foldedTargets.size;
  }

  private foldSubtreeRecordsIntoTargets(): void {
    const groups = new Map<string, SubtreeFoldGroup>();
    for (const path of this.foldableQueuePaths()) {
      for (const ancestor of ancestorPaths(path)) {
        const key = comparisonKey(this.scope, ancestor);
        const group = groups.get(key);
        if (group) {
          group.paths.push(path);
        } else {
          groups.set(key, { ancestor, paths: [path] });
        }
      }
    }

    const foldableGroups = Array.from(groups.values())
      .filter((group) => group.paths.length > 1)
      .sort((left, right) => {
        const leftFits = this.queueSizeAfterSubtreeFold(left.ancestor) <= this.maxDirtyPaths;
        const rightFits = this.queueSizeAfterSubtreeFold(right.ancestor) <= this.maxDirtyPaths;
        if (leftFits !== rightFits) {
          return rightFits ? 1 : -1;
        }
        return (
          pathDepth(right.ancestor) - pathDepth(left.ancestor) ||
          right.paths.length - left.paths.length ||
          compareText(left.ancestor, right.ancestor)
        );
      });

    for (const { ancestor } of foldableGroups) {
      if (this.watcherQueueSize() <= this.maxDirtyPaths) {
        return;
      }
      this.setFoldedTarget(ancestor, "infinity", "dirtyPathSubtreeFold");
      this.deleteEntriesInside(ancestor);
      this.deleteFoldedTargetsInside(ancestor);
    }
  }

  private foldableQueuePaths(): string[] {
    const paths: string[] = [];
    for (const record of this.entries.values()) {
      if (!record.eventKinds.has("rename")) {
        paths.push(record.path);
      }
    }
    for (const target of this.foldedTargets.values()) {
      paths.push(target.path);
    }
    return paths;
  }

  private deleteEntriesInside(ancestor: string): void {
    for (const record of this.entries.values()) {
      if (this.isSameOrDescendantOf(ancestor, record.path)) {
        this.entries.delete(comparisonKey(this.scope, record.path));
      }
    }
  }

  private deleteFoldedTargetsInside(ancestor: string): void {
    for (const target of this.foldedTargets.values()) {
      if (comparisonKey(this.scope, target.path) !== comparisonKey(this.scope, ancestor) && this.isDescendantOf(ancestor, target.path)) {
        this.foldedTargets.delete(comparisonKey(this.scope, target.path));
      }
    }
  }

  private queueSizeAfterSubtreeFold(ancestor: string): number {
    let covered = 0;
    for (const record of this.entries.values()) {
      if (this.isSameOrDescendantOf(ancestor, record.path)) {
        covered += 1;
      }
    }
    for (const target of this.foldedTargets.values()) {
      if (this.isSameOrDescendantOf(ancestor, target.path)) {
        covered += 1;
      }
    }
    return this.watcherQueueSize() - covered + 1;
  }

  private isSameOrDescendantOf(ancestor: string, path: string): boolean {
    const ancestorKey = comparisonKey(this.scope, ancestor);
    const pathKey = comparisonKey(this.scope, path);
    return pathKey === ancestorKey || pathKey.startsWith(`${ancestorKey}/`);
  }

  private isDescendantOf(ancestor: string, path: string): boolean {
    const ancestorKey = comparisonKey(this.scope, ancestor);
    const pathKey = comparisonKey(this.scope, path);
    return pathKey.startsWith(`${ancestorKey}/`);
  }
}

function targetsForRecord(record: DirtyPathRecord): StatusRefreshTarget[] {
  if (record.eventKinds.has("rename")) {
    return [{ path: ".", depth: "infinity", reason: "manualFullReconcile" }];
  }
  if (isCreateThenDelete(record)) {
    return [parentTarget(record.path, "childDeleted")];
  }
  if (isDeleteThenCreate(record)) {
    return [
      parentTarget(record.path, "childReplaced"),
      { path: record.path, depth: "empty", reason: "fileReplaced" },
    ];
  }

  const targets: StatusRefreshTarget[] = [];
  if (record.eventKinds.has("create")) {
    targets.push(parentTarget(record.path, "childCreated"));
    targets.push({ path: record.path, depth: "empty", reason: "fileCreated" });
  }
  if (record.eventKinds.has("delete")) {
    targets.push(parentTarget(record.path, "childDeleted"));
    targets.push({ path: record.path, depth: "empty", reason: "fileDeleted" });
  }
  if (record.eventKinds.has("change") || record.eventKinds.has("metadata")) {
    targets.push({ path: record.path, depth: "empty", reason: "fileChanged" });
  }

  return targets;
}

function isCreateThenDelete(record: DirtyPathRecord): boolean {
  return record.eventKinds.has("create") && record.eventKinds.has("delete") && record.firstKind === "create" && record.lastKind === "delete";
}

function isDeleteThenCreate(record: DirtyPathRecord): boolean {
  return record.eventKinds.has("create") && record.eventKinds.has("delete") && record.firstKind === "delete" && record.lastKind === "create";
}

function parentTarget(path: string, reason: string): StatusRefreshTarget {
  return {
    path: parentPath(path),
    depth: "immediates",
    reason,
  };
}

function parentPath(path: string): string {
  const index = path.lastIndexOf("/");
  return index < 0 ? "." : path.slice(0, index);
}

function isDirectChild(parent: string, path: string): boolean {
  if (parent === ".") {
    return !path.includes("/");
  }
  if (!path.startsWith(`${parent}/`)) {
    return false;
  }
  return !path.slice(parent.length + 1).includes("/");
}

function ancestorPaths(path: string): string[] {
  const ancestors: string[] = [];
  let current = parentPath(path);
  while (current !== ".") {
    ancestors.push(current);
    current = parentPath(current);
  }
  return ancestors;
}

function pathDepth(path: string): number {
  return path === "." ? 0 : path.split("/").length;
}

function requiresSiblingDirectoryEntries(record: DirtyPathRecord): boolean {
  return record.eventKinds.has("create") || record.eventKinds.has("delete");
}

function repositoryRelativePath(scope: RepositoryWatchScope, eventPath: string): string | null {
  const root = normalizeAbsolutePath(scope.workingCopyRoot);
  const candidate = normalizeAbsolutePath(eventPath);
  if (hasUnsafePathSegments(root) || hasUnsafePathSegments(candidate)) {
    return null;
  }
  const rootKey = comparisonKey(scope, root);
  const candidateKey = comparisonKey(scope, candidate);

  if (candidateKey !== rootKey && !candidateKey.startsWith(`${rootKey}/`)) {
    return null;
  }
  if (isInsideBoundary(scope, candidate)) {
    return null;
  }

  const relative = candidateKey === rootKey ? "." : candidate.slice(root.length + 1);
  if (isSvnInternal(scope, relative)) {
    return null;
  }

  return relative;
}

function isInsideBoundary(scope: RepositoryWatchScope, candidate: string): boolean {
  for (const boundaryRoot of scope.boundaryRoots ?? []) {
    const boundary = normalizeAbsolutePath(boundaryRoot);
    const boundaryKey = comparisonKey(scope, boundary);
    const candidateKey = comparisonKey(scope, candidate);
    if (candidateKey === boundaryKey || candidateKey.startsWith(`${boundaryKey}/`)) {
      return true;
    }
  }
  return false;
}

function isSvnInternal(scope: RepositoryWatchScope, relativePath: string): boolean {
  const key = comparisonKey(scope, relativePath);
  return key === ".svn" || key.startsWith(".svn/");
}

function normalizeAbsolutePath(path: string): string {
  return path.replaceAll("\\", "/").replace(/\/+$/u, "");
}

function hasUnsafePathSegments(path: string): boolean {
  const parts = path.split("/");
  return parts.some((part, index) => {
    if (part === "." || part === "..") {
      return true;
    }
    if (part !== "") {
      return false;
    }
    return !isAllowedAbsolutePrefix(parts, index);
  });
}

function isAllowedAbsolutePrefix(parts: string[], index: number): boolean {
  if (index === 0 && parts.length > 1) {
    return true;
  }
  return index === 1 && parts[0] === "" && parts.length > 2;
}

function comparisonKey(scope: RepositoryWatchScope, path: string): string {
  return scope.pathCase === "case-insensitive" ? path.toLocaleLowerCase("en-US") : path;
}

function targetKey(target: StatusRefreshTarget): string {
  return `${target.path}\0${target.depth}\0${target.reason}`;
}

function compareTargets(left: StatusRefreshTarget, right: StatusRefreshTarget): number {
  const byPath = compareText(left.path, right.path);
  if (byPath !== 0) {
    return byPath;
  }
  const byDepth = depthRank(left.depth) - depthRank(right.depth);
  if (byDepth !== 0) {
    return byDepth;
  }
  return compareText(left.reason, right.reason);
}

function compareText(left: string, right: string): number {
  if (left < right) {
    return -1;
  }
  if (left > right) {
    return 1;
  }
  return 0;
}

function depthRank(depth: StatusRefreshDepth): number {
  switch (depth) {
    case "empty":
      return 0;
    case "files":
      return 1;
    case "immediates":
      return 2;
    case "infinity":
      return 3;
  }
}
