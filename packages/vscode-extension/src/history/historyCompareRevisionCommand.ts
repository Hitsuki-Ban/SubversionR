import { createRevisionContentUriComponents, type RevisionContentUriComponents } from "../content/revisionContentUri";
import type { HistoryCompareRevisionTarget } from "./historyTreeDataProvider";

export interface HistoryRevisionComparisonUriComponents {
  left: RevisionContentUriComponents;
  right: RevisionContentUriComponents;
  label: string;
}

export class HistoryCompareRevisionCommandError extends Error {
  public constructor(
    public readonly code: string,
    public readonly category: "input",
    public readonly messageKey: string,
    public readonly safeArgs: Record<string, unknown> = {},
  ) {
    super(code);
    this.name = "HistoryCompareRevisionCommandError";
  }
}

export function historyCompareRevisionUriComponents(target: unknown): HistoryRevisionComparisonUriComponents {
  const compareTarget = requireHistoryCompareRevisionTarget(target);
  try {
    return {
      left: createRevisionContentUriComponents({
        repositoryId: compareTarget.repositoryId,
        epoch: compareTarget.epoch,
        path: compareTarget.path,
        revision: compareTarget.leftRevision,
      }),
      right: createRevisionContentUriComponents({
        repositoryId: compareTarget.repositoryId,
        epoch: compareTarget.epoch,
        path: compareTarget.path,
        revision: compareTarget.rightRevision,
      }),
      label: compareTarget.label,
    };
  } catch (error) {
    throw invalidCompareRevisionTarget(errorField(error));
  }
}

function requireHistoryCompareRevisionTarget(target: unknown): HistoryCompareRevisionTarget {
  if (typeof target !== "object" || target === null) {
    throw invalidCompareRevisionTarget("target");
  }
  const candidate = target as Partial<HistoryCompareRevisionTarget>;
  if (typeof candidate.repositoryId !== "string" || candidate.repositoryId.trim().length === 0) {
    throw invalidCompareRevisionTarget("repositoryId");
  }
  if (typeof candidate.epoch !== "number" || !Number.isSafeInteger(candidate.epoch) || candidate.epoch < 0) {
    throw invalidCompareRevisionTarget("epoch");
  }
  if (typeof candidate.path !== "string" || candidate.path.trim().length === 0) {
    throw invalidCompareRevisionTarget("path");
  }
  if (typeof candidate.leftRevision !== "string" || candidate.leftRevision.trim().length === 0) {
    throw invalidCompareRevisionTarget("leftRevision");
  }
  if (typeof candidate.rightRevision !== "string" || candidate.rightRevision.trim().length === 0) {
    throw invalidCompareRevisionTarget("rightRevision");
  }
  if (typeof candidate.label !== "string" || candidate.label.trim().length === 0) {
    throw invalidCompareRevisionTarget("label");
  }
  const leftRevisionNumber = explicitRevisionNumber(candidate.leftRevision, "leftRevision");
  const rightRevisionNumber = explicitRevisionNumber(candidate.rightRevision, "rightRevision");
  if (leftRevisionNumber >= rightRevisionNumber) {
    throw invalidCompareRevisionTarget("revisionOrder");
  }
  return {
    repositoryId: candidate.repositoryId,
    epoch: candidate.epoch,
    path: candidate.path,
    leftRevision: candidate.leftRevision,
    rightRevision: candidate.rightRevision,
    label: candidate.label,
  };
}

function explicitRevisionNumber(revision: string, field: string): number {
  const match = /^r(0|[1-9]\d*)$/u.exec(revision);
  if (match === null) {
    throw invalidCompareRevisionTarget(field);
  }
  const revisionNumber = Number(match[1]);
  if (!Number.isSafeInteger(revisionNumber) || revisionNumber > 2_147_483_647) {
    throw invalidCompareRevisionTarget(field);
  }
  return revisionNumber;
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

function invalidCompareRevisionTarget(field: string): HistoryCompareRevisionCommandError {
  return new HistoryCompareRevisionCommandError(
    "SUBVERSIONR_HISTORY_COMPARE_PREVIOUS_TARGET_INVALID",
    "input",
    "error.history.comparePreviousTargetInvalid",
    { field },
  );
}
