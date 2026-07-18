import { describe, expect, it, vi } from "vitest";
import { redriveRequiredRemoteRecoveries } from "../src/status/remoteRecoveryReconnect";
import { RemoteConnectionStateStore } from "../src/status/remoteConnectionStateStore";

const ORIGIN_ID = "00000000-0000-4000-8000-000000000001";
const RECOVERY_ID = "00000000-0000-4000-8000-000000000002";

describe("redriveRequiredRemoteRecoveries", () => {
  it("redrives required recovery after epoch rebind and skips terminal blocked state", async () => {
    const store = new RemoteConnectionStateStore();
    required(store, "required");
    required(store, "blocked");
    store.beginRecovery({
      repositoryId: "blocked", epoch: 1, operationId: RECOVERY_ID,
      startedAt: "2026-07-18T01:00:01.000Z", deadlineAt: "2026-07-18T01:00:31.000Z",
    });
    store.completeRecovery({
      repositoryId: "blocked", epoch: 1, operationId: RECOVERY_ID,
      completedAt: "2026-07-18T01:00:02.000Z", result: "blocked",
      failure: { category: "indeterminate", reason: "remoteRecoveryBlocked", cleanupAppropriate: false },
    });
    store.rebindRepository({ repositoryId: "required", epoch: 2 });
    store.rebindRepository({ repositoryId: "blocked", epoch: 2 });
    const recover = vi.fn().mockResolvedValue("safe");

    await redriveRequiredRemoteRecoveries({
      sessions: { listOpenSessions: () => [session("required"), session("blocked")] },
      store,
      recovery: { recover },
      recordFailure: vi.fn(),
    });

    expect(recover).toHaveBeenCalledOnce();
    expect(recover).toHaveBeenCalledWith({ repositoryId: "required", epoch: 2 });
  });
});

function required(store: RemoteConnectionStateStore, repositoryId: string): void {
  store.registerRepository({ repositoryId, epoch: 1 });
  store.beginCheck({ repositoryId, epoch: 1, operationId: ORIGIN_ID, startedAt: "2026-07-18T01:00:00.000Z" });
  store.completeFailure({
    repositoryId, epoch: 1, operationId: ORIGIN_ID, failedAt: "2026-07-18T01:00:01.000Z",
    failure: { category: "indeterminate", reason: "workerContainmentFailed", cleanupAppropriate: false },
    workingCopyRecoveryRequired: true,
  });
}

function session(repositoryId: string) {
  return {
    repositoryId,
    epoch: 2,
    identity: {
      repositoryUuid: "uuid", repositoryRootUrl: "https://example.test/repo",
      workingCopyRoot: `C:/${repositoryId}`, workspaceScopeRoot: `C:/${repositoryId}`, format: 31,
    },
    watchScope: { repositoryId, epoch: 2, workingCopyRoot: `C:/${repositoryId}`, pathCase: "case-insensitive" as const },
  };
}
