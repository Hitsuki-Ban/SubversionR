import type { ScmProjectedResource } from "./sourceControlResourceStore";
import { isChangelistResourceGroupId } from "./resourceStateClassifier";

export const BASE_DIFFABLE_FILE_CONTEXT_VALUE = "subversionr.changedFile.baseDiffable";

const BASE_DIFF_SUPPORTED_STATUS_TOKENS = new Set(["modified", "merged", "replaced"]);
const BASE_DIFF_UNSUPPORTED_STATUS_TOKENS = new Set([
  "added",
  "deleted",
  "missing",
  "obstructed",
  "incomplete",
]);

export function isBaseDiffableProjectedResource(resource: ScmProjectedResource): boolean {
  return (
    resource.source === "local" &&
    (resource.groupId === "changes" || isChangelistResourceGroupId(resource.groupId)) &&
    resource.contextValue === "subversionr.changedFile" &&
    resource.entry.kind === "file" &&
    !resource.entry.external &&
    !hasUnsupportedBaseDiffStatus(resource) &&
    hasSupportedBaseDiffStatus(resource)
  );
}

function hasUnsupportedBaseDiffStatus(resource: ScmProjectedResource): boolean {
  return baseDiffStatusTokens(resource).some((status) => BASE_DIFF_UNSUPPORTED_STATUS_TOKENS.has(status));
}

function hasSupportedBaseDiffStatus(resource: ScmProjectedResource): boolean {
  return baseDiffStatusTokens(resource).some((status) => BASE_DIFF_SUPPORTED_STATUS_TOKENS.has(status));
}

function baseDiffStatusTokens(resource: ScmProjectedResource): string[] {
  return [resource.entry.localStatus, resource.entry.nodeStatus, resource.entry.textStatus];
}
