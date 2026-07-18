import { describe, expect, it, vi } from "vitest";
import { RemoteConnectionStateStore } from "../src/status/remoteConnectionStateStore";
import { RemoteRecoveryService } from "../src/status/remoteRecoveryService";
import type { RemoteRecoveryClient } from "../src/status/remoteRecoveryRpcClient";

const ORIGIN_ID = "00000000-0000-4000-8000-000000000001";
const RECOVERY_ID = "00000000-0000-4000-8000-000000000002";

describe("RemoteRecoveryService", () => {
  it("uses a fresh recovery id while sending the stored origin operation id", async () => {
    const store = recoveryRequiredStore();
    const recoverWorkingCopy = vi.fn<RemoteRecoveryClient["recoverWorkingCopy"]>().mockResolvedValue({
      outcome: "safe",
      operationId: RECOVERY_ID,
      completedAt: "2026-07-18T01:00:02.000Z",
    });
    const projection = { updateRemoteConnectionState: vi.fn() };
    const service = new RemoteRecoveryService({
      client: { recoverWorkingCopy },
      store,
      projection,
      createOperationId: () => RECOVERY_ID,
      now: sequentialNow(),
      timeoutMs: 30_000,
    });

    await expect(service.recover({ repositoryId: "repo", epoch: 1 })).resolves.toBe("safe");
    expect(recoverWorkingCopy).toHaveBeenCalledWith({
      repositoryId: "repo",
      epoch: 1,
      operationId: RECOVERY_ID,
      originOperationId: ORIGIN_ID,
      timeoutMs: 30_000,
    }, {});
    expect(store.getState("repo")).toMatchObject({ kind: "unchecked", recovery: { kind: "safe", operationId: RECOVERY_ID } });
  });

  it("keeps the original operation pending after an indeterminate recovery result", async () => {
    const store = recoveryRequiredStore();
    const service = new RemoteRecoveryService({
      client: {
        recoverWorkingCopy: vi.fn().mockResolvedValue({
          outcome: "indeterminate",
          operationId: RECOVERY_ID,
          failure: { category: "indeterminate", reason: "workerContainmentFailed", cleanupAppropriate: false },
        }),
      },
      store,
      projection: { updateRemoteConnectionState: vi.fn() },
      createOperationId: () => RECOVERY_ID,
      now: sequentialNow(),
      timeoutMs: 30_000,
    });

    await expect(service.recover({ repositoryId: "repo", epoch: 1 })).resolves.toBe("indeterminate");
    expect(store.getState("repo")).toMatchObject({
      kind: "indeterminate",
      recovery: { kind: "required", operationId: ORIGIN_ID },
    });
  });

  it("does not submit blocked recovery again", async () => {
    const store = recoveryRequiredStore();
    store.beginRecovery({
      repositoryId: "repo", epoch: 1, operationId: RECOVERY_ID,
      startedAt: "2026-07-18T01:00:01.000Z", deadlineAt: "2026-07-18T01:00:31.000Z",
    });
    store.completeRecovery({
      repositoryId: "repo", epoch: 1, operationId: RECOVERY_ID,
      completedAt: "2026-07-18T01:00:02.000Z", result: "blocked",
      failure: { category: "indeterminate", reason: "remoteRecoveryBlocked", cleanupAppropriate: false },
    });
    const recoverWorkingCopy = vi.fn<RemoteRecoveryClient["recoverWorkingCopy"]>();
    const service = new RemoteRecoveryService({
      client: { recoverWorkingCopy }, store, projection: { updateRemoteConnectionState: vi.fn() },
      createOperationId: () => "00000000-0000-4000-8000-000000000003",
      now: sequentialNow(), timeoutMs: 30_000,
    });

    await expect(service.recover({ repositoryId: "repo", epoch: 1 })).rejects.toThrow("SUBVERSIONR_REMOTE_RECOVERY_NOT_REQUIRED");
    expect(recoverWorkingCopy).not.toHaveBeenCalled();
  });
});

function recoveryRequiredStore(): RemoteConnectionStateStore {
  const store = new RemoteConnectionStateStore();
  store.registerRepository({ repositoryId: "repo", epoch: 1 });
  store.beginCheck({ repositoryId: "repo", epoch: 1, operationId: ORIGIN_ID, startedAt: "2026-07-18T01:00:00.000Z" });
  store.completeFailure({
    repositoryId: "repo", epoch: 1, operationId: ORIGIN_ID, failedAt: "2026-07-18T01:00:01.000Z",
    failure: { category: "indeterminate", reason: "workerContainmentFailed", cleanupAppropriate: false },
    workingCopyRecoveryRequired: true,
  });
  return store;
}

function sequentialNow(): () => string {
  const values = ["2026-07-18T01:00:01.000Z", "2026-07-18T01:00:02.000Z"];
  return () => values.shift() ?? "2026-07-18T01:00:03.000Z";
}
