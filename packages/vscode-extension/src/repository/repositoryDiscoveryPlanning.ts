import type { PathCasePolicy } from "../status/types";
import type { RepositoryDiscoveryCandidate } from "./repositoryDiscoveryService";
import type { RepositorySession } from "./repositorySessionService";

export const REPOSITORY_DISCOVERY_DEPTH = 4;

export function unopenedDiscoveryCandidates(
  candidates: RepositoryDiscoveryCandidate[],
  openSessions: RepositorySession[],
  pathCase: PathCasePolicy,
): RepositoryDiscoveryCandidate[] {
  const openRootKeys = new Set(
    openSessions.map((session) => repositoryRootKey(session.identity.workingCopyRoot, pathCase)),
  );
  return candidates.filter(
    (candidate) => !openRootKeys.has(repositoryRootKey(candidate.identity.workingCopyRoot, pathCase)),
  );
}

export function discoveryBoundaryRoots(
  candidates: RepositoryDiscoveryCandidate[],
  selected: RepositoryDiscoveryCandidate,
  pathCase: PathCasePolicy,
  openSessions: RepositorySession[],
  fileExternalBoundaries: string[],
): string[] {
  const selectedRootKey = repositoryRootKey(selected.identity.workingCopyRoot, pathCase);
  const seen = new Set<string>();
  const boundaryRoots: string[] = [];
  const addBoundaryRoot = (root: string): void => {
    const rootKey = repositoryRootKey(root, pathCase);
    if (rootKey === selectedRootKey || seen.has(rootKey) || !isDescendantRootKey(rootKey, selectedRootKey)) {
      return;
    }
    seen.add(rootKey);
    boundaryRoots.push(root);
  };

  for (const candidate of candidates) {
    if (!candidate.isNested && !candidate.isExternal) {
      continue;
    }
    if (!candidate.parentWorkingCopyRoot) {
      continue;
    }
    if (repositoryRootKey(candidate.parentWorkingCopyRoot, pathCase) !== selectedRootKey) {
      continue;
    }
    addBoundaryRoot(candidate.identity.workingCopyRoot);
  }
  for (const session of openSessions) {
    addBoundaryRoot(session.identity.workingCopyRoot);
  }
  for (const fileExternalBoundary of fileExternalBoundaries) {
    addBoundaryRoot(fileExternalBoundary);
  }
  return boundaryRoots;
}

function repositoryRootKey(root: string, pathCase: PathCasePolicy): string {
  return comparisonKey(pathCase, normalizeAbsolutePath(root));
}

function normalizeAbsolutePath(path: string): string {
  return path.replaceAll("\\", "/").replace(/\/+$/u, "");
}

function comparisonKey(pathCase: PathCasePolicy, path: string): string {
  return pathCase === "case-insensitive" ? path.toLocaleLowerCase("en-US") : path;
}

function isDescendantRootKey(childRootKey: string, parentRootKey: string): boolean {
  return childRootKey
    .slice(parentRootKey.length)
    .startsWith("/");
}
