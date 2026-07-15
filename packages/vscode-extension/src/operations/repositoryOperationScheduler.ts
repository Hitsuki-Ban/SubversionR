export type RepositoryOperationTask<T> = () => Promise<T>;

export interface RepositoryOperationScheduleOptions {
  readonly signal?: AbortSignal;
}

export class RepositoryOperationScheduler {
  private readonly tails = new Map<string, Promise<void>>();

  public async run<T>(
    repositoryId: string,
    task: RepositoryOperationTask<T>,
    options: RepositoryOperationScheduleOptions = {},
  ): Promise<T> {
    const normalizedRepositoryId = validatedRepositoryId(repositoryId);
    const previous = this.tails.get(normalizedRepositoryId) ?? Promise.resolve();
    const scheduled = previous.then(async () => {
      throwIfCancelled(options.signal);
      return await task();
    });
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

    return await settleWithCancellation(scheduled, options.signal);
  }
}

type RepositoryOperationSchedulerErrorCategory = "cancelled" | "input";

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

function throwIfCancelled(signal: AbortSignal | undefined): void {
  if (signal?.aborted) {
    throw cancelledOperationSchedule();
  }
}

async function settleWithCancellation<T>(scheduled: Promise<T>, signal: AbortSignal | undefined): Promise<T> {
  if (signal === undefined) {
    return await scheduled;
  }
  throwIfCancelled(signal);
  let rejectCancellation: (error: RepositoryOperationSchedulerError) => void = () => undefined;
  const cancellation = new Promise<never>((_resolve, reject) => {
    rejectCancellation = reject;
  });
  const cancel = (): void => rejectCancellation(cancelledOperationSchedule());
  signal.addEventListener("abort", cancel, { once: true });
  try {
    return await Promise.race([scheduled, cancellation]);
  } finally {
    signal.removeEventListener("abort", cancel);
  }
}

function cancelledOperationSchedule(): RepositoryOperationSchedulerError {
  return new RepositoryOperationSchedulerError(
    "SUBVERSIONR_OPERATION_SCHEDULER_CANCELLED",
    "cancelled",
    "error.operationScheduler.cancelled",
  );
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
