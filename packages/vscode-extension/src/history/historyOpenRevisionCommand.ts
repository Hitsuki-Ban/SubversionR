import { createRevisionContentUriComponents, type RevisionContentUriComponents } from "../content/revisionContentUri";
import type { HistoryOpenRevisionTarget } from "./historyTreeDataProvider";

export class HistoryOpenRevisionCommandError extends Error {
  public constructor(
    public readonly code: string,
    public readonly category: "input",
    public readonly messageKey: string,
    public readonly safeArgs: Record<string, unknown> = {},
  ) {
    super(code);
    this.name = "HistoryOpenRevisionCommandError";
  }
}

export function historyOpenRevisionUriComponents(target: unknown): RevisionContentUriComponents {
  const openTarget = requireHistoryOpenRevisionTarget(target);
  try {
    return createRevisionContentUriComponents({
      repositoryId: openTarget.repositoryId,
      epoch: openTarget.epoch,
      path: openTarget.path,
      revision: openTarget.revision,
    });
  } catch (error) {
    throw invalidOpenRevisionTarget(errorField(error));
  }
}

function requireHistoryOpenRevisionTarget(target: unknown): HistoryOpenRevisionTarget {
  if (typeof target !== "object" || target === null) {
    throw invalidOpenRevisionTarget("target");
  }
  const candidate = target as Partial<HistoryOpenRevisionTarget>;
  if (typeof candidate.repositoryId !== "string" || candidate.repositoryId.trim().length === 0) {
    throw invalidOpenRevisionTarget("repositoryId");
  }
  if (typeof candidate.epoch !== "number" || !Number.isSafeInteger(candidate.epoch) || candidate.epoch < 0) {
    throw invalidOpenRevisionTarget("epoch");
  }
  if (typeof candidate.path !== "string" || candidate.path.trim().length === 0) {
    throw invalidOpenRevisionTarget("path");
  }
  if (typeof candidate.revision !== "string" || candidate.revision.trim().length === 0) {
    throw invalidOpenRevisionTarget("revision");
  }
  if (typeof candidate.label !== "string" || candidate.label.trim().length === 0) {
    throw invalidOpenRevisionTarget("label");
  }
  return {
    repositoryId: candidate.repositoryId,
    epoch: candidate.epoch,
    path: candidate.path,
    revision: candidate.revision,
    label: candidate.label,
  };
}

function errorField(error: unknown): string {
  if (typeof error === "object" && error !== null && "field" in error) {
    const field = (error as { field?: unknown }).field;
    if (typeof field === "string" && field.trim().length > 0) {
      return field;
    }
  }
  return "target";
}

function invalidOpenRevisionTarget(field: string): HistoryOpenRevisionCommandError {
  return new HistoryOpenRevisionCommandError(
    "SUBVERSIONR_HISTORY_OPEN_REVISION_TARGET_INVALID",
    "input",
    "error.history.openRevisionTargetInvalid",
    { field },
  );
}
