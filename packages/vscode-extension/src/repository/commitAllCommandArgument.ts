export function commitAllRepositoryIdArgument(
  argument: unknown,
  sourceControlRepositoryIds: WeakMap<object, string>,
): unknown {
  if (typeof argument === "object" && argument !== null) {
    const repositoryId = sourceControlRepositoryIds.get(argument);
    if (repositoryId !== undefined) {
      return repositoryId;
    }
  }
  return argument;
}
