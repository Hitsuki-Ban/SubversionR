import type { DirtyFileEvent, FileEventKind, RawWatcherEvent, RepositoryWatchScope } from "./types";

export function normalizeWatcherEvent(
  scope: RepositoryWatchScope,
  event: RawWatcherEvent,
): DirtyFileEvent | null {
  const root = normalizePath(scope.workingCopyRoot);
  const path = normalizePath(event.fsPath);
  if (hasUnsafePathSegments(root) || hasUnsafePathSegments(path)) {
    return null;
  }
  const rootKey = comparisonKey(scope, root);
  const pathKey = comparisonKey(scope, path);

  if (pathKey !== rootKey && !pathKey.startsWith(`${rootKey}/`)) {
    return null;
  }
  if (isInsideBoundary(scope, path)) {
    return null;
  }

  const relative = pathKey === rootKey ? "." : path.slice(root.length + 1);
  if (isSvnInternal(scope, relative)) {
    return null;
  }

  return {
    path,
    kind: mapEventKind(event.kind),
    timestamp: event.timestamp,
  };
}

function normalizePath(path: string): string {
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

function isInsideBoundary(scope: RepositoryWatchScope, path: string): boolean {
  const pathKey = comparisonKey(scope, path);
  for (const boundaryRoot of scope.boundaryRoots ?? []) {
    const boundary = normalizePath(boundaryRoot);
    const boundaryKey = comparisonKey(scope, boundary);
    if (pathKey === boundaryKey || pathKey.startsWith(`${boundaryKey}/`)) {
      return true;
    }
  }
  return false;
}

function isSvnInternal(scope: RepositoryWatchScope, relativePath: string): boolean {
  const key = comparisonKey(scope, relativePath);
  return key === ".svn" || key.startsWith(".svn/");
}

function mapEventKind(kind: RawWatcherEvent["kind"]): FileEventKind {
  switch (kind) {
    case "created":
      return "create";
    case "changed":
      return "change";
    case "deleted":
      return "delete";
  }
}
