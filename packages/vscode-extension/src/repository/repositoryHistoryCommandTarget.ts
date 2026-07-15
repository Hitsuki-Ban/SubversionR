export const REPOSITORY_HISTORY_COMMAND_TARGET_KIND = "subversionr.repositoryHistoryTarget" as const;

export interface RepositoryHistoryCommandTarget {
  kind: typeof REPOSITORY_HISTORY_COMMAND_TARGET_KIND;
  repositoryId: string;
  epoch: number;
}

export function repositoryHistoryCommandTarget(
  repositoryId: string,
  epoch: number,
): RepositoryHistoryCommandTarget {
  return {
    kind: REPOSITORY_HISTORY_COMMAND_TARGET_KIND,
    repositoryId,
    epoch,
  };
}

export function repositoryHistoryCommandArgument(
  argument: unknown,
  sourceControlTargets: WeakMap<object, RepositoryHistoryCommandTarget>,
): unknown {
  if (typeof argument === "object" && argument !== null) {
    const target = sourceControlTargets.get(argument);
    if (target !== undefined) {
      return target;
    }
  }
  return argument;
}
