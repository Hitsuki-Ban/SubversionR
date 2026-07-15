import { describe, expect, it, vi } from "vitest";
import { RepositoryOperationScheduler } from "../src/operations/repositoryOperationScheduler";

describe("RepositoryOperationScheduler", () => {
  it("serializes operations for the same repository", async () => {
    const scheduler = new RepositoryOperationScheduler();
    const releaseFirst = deferred<void>();
    const events: string[] = [];

    const first = scheduler.run("repo-a", async () => {
      events.push("first:start");
      await releaseFirst.promise;
      events.push("first:end");
      return "first";
    });
    const second = scheduler.run("repo-a", async () => {
      events.push("second:start");
      return "second";
    });

    await flushMicrotasks();

    expect(events).toEqual(["first:start"]);

    releaseFirst.resolve();

    await expect(first).resolves.toBe("first");
    await expect(second).resolves.toBe("second");
    expect(events).toEqual(["first:start", "first:end", "second:start"]);
  });

  it("runs operations for different repositories independently", async () => {
    const scheduler = new RepositoryOperationScheduler();
    const releaseFirst = deferred<void>();
    const events: string[] = [];

    const first = scheduler.run("repo-a", async () => {
      events.push("repo-a:start");
      await releaseFirst.promise;
      events.push("repo-a:end");
    });
    const second = scheduler.run("repo-b", async () => {
      events.push("repo-b:start");
    });

    await flushMicrotasks();

    expect(events).toEqual(["repo-a:start", "repo-b:start"]);

    releaseFirst.resolve();
    await Promise.all([first, second]);

    expect(events).toEqual(["repo-a:start", "repo-b:start", "repo-a:end"]);
  });

  it("continues a repository queue after a failed operation", async () => {
    const scheduler = new RepositoryOperationScheduler();
    const events: string[] = [];

    const first = scheduler.run("repo-a", async () => {
      events.push("first:start");
      throw new Error("operation failed");
    });
    const second = scheduler.run("repo-a", async () => {
      events.push("second:start");
      return "second";
    });

    await expect(first).rejects.toThrow("operation failed");
    await expect(second).resolves.toBe("second");
    expect(events).toEqual(["first:start", "second:start"]);
  });

  it("settles a cancelled queued operation without running it or bypassing the active tail", async () => {
    const scheduler = new RepositoryOperationScheduler();
    const releaseFirst = deferred<void>();
    const cancelledTask = vi.fn(async () => "cancelled task ran");
    const events: string[] = [];
    const cancellation = new AbortController();

    const first = scheduler.run("repo-a", async () => {
      events.push("first:start");
      await releaseFirst.promise;
      events.push("first:end");
    });
    const cancelled = scheduler.run("repo-a", cancelledTask, { signal: cancellation.signal });
    const third = scheduler.run("repo-a", async () => {
      events.push("third:start");
    });

    await flushMicrotasks();
    cancellation.abort();

    await expect(cancelled).rejects.toMatchObject({
      code: "SUBVERSIONR_OPERATION_SCHEDULER_CANCELLED",
      category: "cancelled",
    });
    expect(cancelledTask).not.toHaveBeenCalled();
    expect(events).toEqual(["first:start"]);

    releaseFirst.resolve();
    await Promise.all([first, third]);

    expect(cancelledTask).not.toHaveBeenCalled();
    expect(events).toEqual(["first:start", "first:end", "third:start"]);
  });

  it.each(["", "   ", " repo-a", "repo-a "])("fails fast for invalid repository id %j", async (repositoryId) => {
    const scheduler = new RepositoryOperationScheduler();
    const task = vi.fn(async () => undefined);

    await expect(scheduler.run(repositoryId, task)).rejects.toMatchObject({
      code: "SUBVERSIONR_OPERATION_SCHEDULER_REPOSITORY_ID_INVALID",
    });
    expect(task).not.toHaveBeenCalled();
  });
});

interface Deferred<T> {
  promise: Promise<T>;
  resolve(value: T | PromiseLike<T>): void;
  reject(error: unknown): void;
}

function deferred<T>(): Deferred<T> {
  let resolve: (value: T | PromiseLike<T>) => void = () => undefined;
  let reject: (error: unknown) => void = () => undefined;
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}

async function flushMicrotasks(): Promise<void> {
  await Promise.resolve();
  await Promise.resolve();
}
