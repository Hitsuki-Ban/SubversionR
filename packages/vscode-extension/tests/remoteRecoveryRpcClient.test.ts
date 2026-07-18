import { describe, expect, it, vi } from "vitest";
import {
  RemoteRecoveryRpcClient,
  RemoteRecoveryRpcError,
  type RemoteRecoveryRequest,
} from "../src/status/remoteRecoveryRpcClient";
import type { JsonRpcSender } from "../src/status/types";

const ORIGIN_ID = "00000000-0000-4000-8000-000000000001";
const RECOVERY_ID = "00000000-0000-4000-8000-000000000002";

describe("RemoteRecoveryRpcClient", () => {
  it("sends strict distinct origin and recovery operation ids", async () => {
    const sendRequest = vi.fn().mockResolvedValue({
      outcome: "safe",
      operationId: RECOVERY_ID,
      completedAt: "2026-07-18T01:00:01.000Z",
    });

    await expect(new RemoteRecoveryRpcClient(senderFrom(sendRequest)).recoverWorkingCopy(request())).resolves.toEqual({
      outcome: "safe",
      operationId: RECOVERY_ID,
      completedAt: "2026-07-18T01:00:01.000Z",
    });
    expect(sendRequest).toHaveBeenCalledWith("remote/recoverWorkingCopy", request());
  });

  it("rejects a reused origin operation id before submission", async () => {
    const sendRequest = vi.fn();
    const client = new RemoteRecoveryRpcClient(senderFrom(sendRequest));

    await expect(client.recoverWorkingCopy({ ...request(), originOperationId: RECOVERY_ID }))
      .rejects.toBeInstanceOf(RemoteRecoveryRpcError);
    expect(sendRequest).not.toHaveBeenCalled();
  });

  it("parses bounded blocked failures and rejects response extensions", async () => {
    const sendRequest = vi.fn()
      .mockResolvedValueOnce({
        outcome: "blocked",
        operationId: RECOVERY_ID,
        failure: { category: "recovery", reason: "remoteRecoveryBlocked", cleanupAppropriate: false },
      })
      .mockResolvedValueOnce({
        outcome: "safe",
        operationId: RECOVERY_ID,
        completedAt: "2026-07-18T01:00:01.000Z",
        extra: true,
      });
    const client = new RemoteRecoveryRpcClient(senderFrom(sendRequest));

    await expect(client.recoverWorkingCopy(request())).resolves.toMatchObject({
      outcome: "blocked",
      failure: { category: "indeterminate", reason: "remoteRecoveryBlocked" },
    });
    await expect(client.recoverWorkingCopy(request())).rejects.toBeInstanceOf(RemoteRecoveryRpcError);
  });
});

function request(): RemoteRecoveryRequest {
  return {
    repositoryId: "repo",
    epoch: 1,
    operationId: RECOVERY_ID,
    originOperationId: ORIGIN_ID,
    timeoutMs: 30_000,
  };
}

function senderFrom(sendRequest: (...args: unknown[]) => Promise<unknown>): JsonRpcSender {
  return {
    sendRequest: async <T>(method: string, params: unknown, options?: unknown): Promise<T> =>
      await (options === undefined ? sendRequest(method, params) : sendRequest(method, params, options)) as T,
  };
}
