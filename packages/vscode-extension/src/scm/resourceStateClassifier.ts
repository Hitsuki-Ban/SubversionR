import type { StatusEntry } from "../status/statusSnapshotRpcClient";

export type ChangelistResourceGroupId = `changelist:${string}`;
export type ScmResourceGroupId =
  | "conflicts"
  | "changes"
  | "unversioned"
  | "metadata"
  | "incoming"
  | "externals"
  | "ignored"
  | ChangelistResourceGroupId;

export interface ScmResourceClassification {
  groupId: ScmResourceGroupId;
  contextValue: string;
  tooltipKey: string;
}

const NEUTRAL_STATUS_TOKENS = new Set(["none", "normal", "notChecked"]);
const KNOWN_LOCAL_CHANGE_STATUS_TOKENS = new Set([
  "added",
  "missing",
  "deleted",
  "replaced",
  "modified",
  "merged",
  "obstructed",
  "incomplete",
]);

export function classifyLocalStatusEntry(entry: StatusEntry): ScmResourceClassification | undefined {
  if (hasConflict(entry)) {
    return classification("conflicts", "conflicted");
  }
  if (entry.external) {
    return classification("externals", "external");
  }
  if (entry.localStatus === "ignored") {
    return classification("ignored", "ignored");
  }
  if (entry.localStatus === "unversioned") {
    return classification("unversioned", "unversioned");
  }
  if (
    isKnownLocalChangeStatus(entry.localStatus) ||
    isKnownLocalChangeStatus(entry.nodeStatus) ||
    isKnownLocalChangeStatus(entry.textStatus) ||
    isKnownLocalChangeStatus(entry.propertyStatus)
  ) {
    if (entry.changelist !== null) {
      return classification(changelistResourceGroupId(entry.changelist), changedResourceKind(entry), "changed");
    }
    return classification("changes", changedResourceKind(entry), "changed");
  }
  if (
    isActionableStatus(entry.localStatus) ||
    isActionableStatus(entry.nodeStatus) ||
    isActionableStatus(entry.textStatus) ||
    isActionableStatus(entry.propertyStatus)
  ) {
    return classification("changes", "changedUnknown");
  }
  if (hasWorkingCopyMetadataStatus(entry)) {
    return classification("metadata", "workingCopyMetadata");
  }
  return undefined;
}

export function classifyRemoteStatusEntry(entry: StatusEntry): ScmResourceClassification | undefined {
  if (!isActionableStatus(entry.remoteStatus)) {
    return undefined;
  }
  return classification("incoming", entry.kind === "file" ? "incomingFile" : "incoming", "incoming");
}

function hasConflict(entry: StatusEntry): boolean {
  return (
    entry.conflict !== null ||
    entry.localStatus === "conflicted" ||
    entry.nodeStatus === "conflicted" ||
    entry.textStatus === "conflicted" ||
    entry.propertyStatus === "conflicted"
  );
}

function isActionableStatus(status: string): boolean {
  return !NEUTRAL_STATUS_TOKENS.has(status);
}

function isKnownLocalChangeStatus(status: string): boolean {
  return KNOWN_LOCAL_CHANGE_STATUS_TOKENS.has(status);
}

function hasWorkingCopyMetadataStatus(entry: StatusEntry): boolean {
  return entry.switched || entry.lock !== null || entry.needsLock || isSparseStatusDepth(entry.depth);
}

export function isSparseStatusDepth(depth: string): boolean {
  return depth === "empty" || depth === "files" || depth === "immediates";
}

function changedResourceKind(entry: StatusEntry): string {
  return entry.kind === "file" ? "changedFile" : "changedDirectory";
}

export function changelistResourceGroupId(changelist: string): ChangelistResourceGroupId {
  return `changelist:${encodeURIComponent(changelist)}`;
}

export function isChangelistResourceGroupId(groupId: ScmResourceGroupId): groupId is ChangelistResourceGroupId {
  return groupId.startsWith("changelist:");
}

export function changelistNameFromResourceGroupId(groupId: ChangelistResourceGroupId): string {
  return decodeURIComponent(groupId.slice("changelist:".length));
}

function classification(
  groupId: ScmResourceGroupId,
  resourceKind: string,
  tooltipKind = resourceKind,
): ScmResourceClassification {
  return {
    groupId,
    contextValue: `subversionr.${resourceKind}`,
    tooltipKey: `scm.resource.${tooltipKind}`,
  };
}
