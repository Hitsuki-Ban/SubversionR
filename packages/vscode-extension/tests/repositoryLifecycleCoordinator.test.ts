import { describe, expect, it, vi } from "vitest";
import {
  RepositoryLifecycleCoordinator,
  type RepositoryLifecycleCoordinatorOptions,
} from "../src/repository/repositoryLifecycleCoordinator";
import type {
  RepositoryAutoOpenTrigger,
  RepositoryLifecycleEvent,
  RepositoryLifecycleService,
} from "../src/repository/repositoryLifecycleService";
import type { RepositorySessionService } from "../src/repository/repositorySessionService";

describe("RepositoryLifecycleCoordinator", () => {
  it("serializes workspace lifecycle reconciliation runs", async () => {
    const firstRecover = deferred<RepositoryLifecycleEvent[]>();
    const calls: string[] = [];
    const lifecycleService = fakeLifecycleService({
      recoverMovedRepositories: async (trigger) => {
        calls.push(`recover:${trigger}`);
        if (trigger === "activation") {
          await firstRecover.promise;
        }
        return [];
      },
      closeDisappearedRepositories: async (trigger) => {
        calls.push(`close:${trigger}`);
        return [];
      },
      autoOpenWorkspaceRepositories: async (trigger) => {
        calls.push(`open:${trigger}`);
        return autoOpenSkipped(trigger);
      },
    });
    const coordinator = lifecycleCoordinator({ lifecycleService });

    const first = coordinator.reconcileWorkspaceRepositories("activation");
    const second = coordinator.reconcileWorkspaceRepositories("workspaceFolders");
    await flushMicrotasks();

    expect(calls).toEqual(["recover:activation"]);

    firstRecover.resolve([]);
    await Promise.all([first, second]);

    expect(calls).toEqual([
      "recover:activation",
      "close:activation",
      "open:activation",
      "recover:workspaceFolders",
      "close:workspaceFolders",
      "open:workspaceFolders",
    ]);
  });

  it("runs backend restart recovery after an in-flight workspace reconciliation", async () => {
    const firstRecover = deferred<RepositoryLifecycleEvent[]>();
    const calls: string[] = [];
    const lifecycleService = fakeLifecycleService({
      recoverMovedRepositories: async (trigger) => {
        calls.push(`recover:${trigger}`);
        await firstRecover.promise;
        return [];
      },
      closeDisappearedRepositories: async (trigger) => {
        calls.push(`close:${trigger}`);
        return [];
      },
      autoOpenWorkspaceRepositories: async (trigger) => {
        calls.push(`open:${trigger}`);
        return autoOpenSkipped(trigger);
      },
      reopenBackendRestartedRepositories: async () => {
        calls.push("reopen:backendRestart");
        return [];
      },
    });
    const sessionService = fakeSessionService({
      markOpenSessionsStale: (request) => {
        calls.push(`stale:${request.timestamp}`);
      },
    });
    const coordinator = lifecycleCoordinator({
      lifecycleService,
      sessionService,
      now: () => "2026-06-27T00:00:00.000Z",
    });

    const workspace = coordinator.reconcileWorkspaceRepositories("activation");
    const restart = coordinator.recoverBackendRestartedRepositories();
    await flushMicrotasks();

    expect(calls).toEqual(["recover:activation"]);

    firstRecover.resolve([]);
    await Promise.all([workspace, restart]);

    expect(calls).toEqual([
      "recover:activation",
      "close:activation",
      "open:activation",
      "stale:2026-06-27T00:00:00.000Z",
      "reopen:backendRestart",
    ]);
  });

  it("queues manual open and close work with lifecycle reconciliation", async () => {
    const firstRecover = deferred<RepositoryLifecycleEvent[]>();
    const calls: string[] = [];
    const lifecycleService = fakeLifecycleService({
      recoverMovedRepositories: async (trigger) => {
        calls.push(`recover:${trigger}`);
        await firstRecover.promise;
        return [];
      },
      closeDisappearedRepositories: async (trigger) => {
        calls.push(`close:${trigger}`);
        return [];
      },
      autoOpenWorkspaceRepositories: async (trigger) => {
        calls.push(`open:${trigger}`);
        return autoOpenSkipped(trigger);
      },
    });
    const coordinator = lifecycleCoordinator({ lifecycleService });

    const workspace = coordinator.reconcileWorkspaceRepositories("activation");
    const manualOpen = coordinator.runExclusive("manualOpen", async () => {
      calls.push("manual:open");
    });
    const manualClose = coordinator.runExclusive("manualClose", async () => {
      calls.push("manual:close");
    });
    await flushMicrotasks();

    expect(calls).toEqual(["recover:activation"]);

    firstRecover.resolve([]);
    await Promise.all([workspace, manualOpen, manualClose]);

    expect(calls).toEqual([
      "recover:activation",
      "close:activation",
      "open:activation",
      "manual:open",
      "manual:close",
    ]);
  });

  it("reports stale marking failures without reopening and keeps the queue usable", async () => {
    const reported: unknown[] = [];
    const calls: string[] = [];
    const lifecycleService = fakeLifecycleService({
      reopenBackendRestartedRepositories: async () => {
        calls.push("reopen:backendRestart");
        return [];
      },
      recoverMovedRepositories: async (trigger) => {
        calls.push(`recover:${trigger}`);
        return [];
      },
      closeDisappearedRepositories: async (trigger) => {
        calls.push(`close:${trigger}`);
        return [];
      },
      autoOpenWorkspaceRepositories: async (trigger) => {
        calls.push(`open:${trigger}`);
        return autoOpenSkipped(trigger);
      },
    });
    const staleFailure = new Error("stale failed");
    const coordinator = lifecycleCoordinator({
      lifecycleService,
      sessionService: fakeSessionService({
        markOpenSessionsStale: () => {
          throw staleFailure;
        },
      }),
      onBackendRestartStaleFailure: async (error) => {
        reported.push(error);
      },
    });

    await coordinator.recoverBackendRestartedRepositories();
    await coordinator.reconcileWorkspaceRepositories("workspaceTrust");

    expect(reported).toEqual([staleFailure]);
    expect(calls).toEqual(["recover:workspaceTrust", "close:workspaceTrust", "open:workspaceTrust"]);
  });
});

function lifecycleCoordinator(
  options: Partial<RepositoryLifecycleCoordinatorOptions> = {},
): RepositoryLifecycleCoordinator {
  return new RepositoryLifecycleCoordinator({
    lifecycleService: options.lifecycleService ?? fakeLifecycleService(),
    sessionService: options.sessionService ?? fakeSessionService(),
    now: options.now ?? (() => "2026-06-27T00:00:00.000Z"),
    onBackendRestartStaleFailure: options.onBackendRestartStaleFailure ?? (async () => undefined),
  });
}

function fakeLifecycleService(
  overrides: Partial<
    Pick<
      RepositoryLifecycleService,
      | "recoverMovedRepositories"
      | "closeDisappearedRepositories"
      | "autoOpenWorkspaceRepositories"
      | "reopenBackendRestartedRepositories"
    >
  > = {},
): Pick<
  RepositoryLifecycleService,
  | "recoverMovedRepositories"
  | "closeDisappearedRepositories"
  | "autoOpenWorkspaceRepositories"
  | "reopenBackendRestartedRepositories"
> {
  return {
    recoverMovedRepositories: vi.fn(overrides.recoverMovedRepositories ?? (async () => [])),
    closeDisappearedRepositories: vi.fn(overrides.closeDisappearedRepositories ?? (async () => [])),
    autoOpenWorkspaceRepositories: vi.fn(
      overrides.autoOpenWorkspaceRepositories ?? (async (trigger) => autoOpenSkipped(trigger)),
    ),
    reopenBackendRestartedRepositories: vi.fn(overrides.reopenBackendRestartedRepositories ?? (async () => [])),
  };
}

function fakeSessionService(
  overrides: Partial<Pick<RepositorySessionService, "markOpenSessionsStale">> = {},
): Pick<RepositorySessionService, "markOpenSessionsStale"> {
  return {
    markOpenSessionsStale: vi.fn(overrides.markOpenSessionsStale ?? (() => undefined)),
  };
}

function autoOpenSkipped(trigger: RepositoryAutoOpenTrigger): RepositoryLifecycleEvent {
  return {
    kind: "autoOpenSkipped",
    trigger,
    reason: "noCandidates",
    candidateCount: 0,
  };
}

function deferred<T>(): {
  promise: Promise<T>;
  resolve(value: T): void;
} {
  let resolveValue: ((value: T) => void) | undefined;
  const promise = new Promise<T>((resolve) => {
    resolveValue = resolve;
  });
  return {
    promise,
    resolve(value) {
      resolveValue?.(value);
    },
  };
}

async function flushMicrotasks(): Promise<void> {
  await Promise.resolve();
}
