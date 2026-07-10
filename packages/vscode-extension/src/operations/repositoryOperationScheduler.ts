export type RepositoryOperationTask<T> = () => Promise<T>;

export class RepositoryOperationScheduler {
  private readonly tails = new Map<string, Promise<void>>();

  public async run<T>(repositoryId: string, task: RepositoryOperationTask<T>): Promise<T> {
    const normalizedRepositoryId = validatedRepositoryId(repositoryId);
    const previous = this.tails.get(normalizedRepositoryId) ?? Promise.resolve();
    const scheduled = previous.then(task);
    const tail = scheduled.then(
      () => undefined,
      () => undefined,
    );

    this.tails.set(normalizedRepositoryId, tail);
    void tail.finally(() => {
      if (this.tails.get(normalizedRepositoryId) === tail) {
        this.tails.delete(normalizedRepositoryId);
      }
    });

    return await scheduled;
  }
}

type RepositoryOperationSchedulerErrorCategory = "input";

export class RepositoryOperationSchedulerError extends Error {
  public constructor(
    public readonly code: string,
    public readonly category: RepositoryOperationSchedulerErrorCategory,
    public readonly messageKey: string,
    public readonly safeArgs: Record<string, unknown> = {},
  ) {
    super(code);
    this.name = "RepositoryOperationSchedulerError";
  }
}

function validatedRepositoryId(repositoryId: string): string {
  if (repositoryId.length === 0 || repositoryId !== repositoryId.trim()) {
    throw new RepositoryOperationSchedulerError(
      "SUBVERSIONR_OPERATION_SCHEDULER_REPOSITORY_ID_INVALID",
      "input",
      "error.operationScheduler.repositoryIdInvalid",
      { field: "repositoryId" },
    );
  }
  return repositoryId;
}
