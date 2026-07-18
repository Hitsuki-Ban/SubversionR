import { describe, expect, it, vi } from "vitest";
import {
  createRemoteConnectionNotificationHandler,
  parseRemoteConnectionStateNotification,
} from "../src/status/remoteConnectionNotificationHandler";
import { RemoteConnectionStateStore } from "../src/status/remoteConnectionStateStore";

const ORIGIN_ID = "00000000-0000-4000-8000-000000000001";
const RECOVERY_ID = "00000000-0000-4000-8000-000000000002";
const NOW = "2026-07-18T01:00:02.000Z";

describe("remote connection notifications", () => {
  it("strictly parses pending recovery state", () => {
    expect(parseRemoteConnectionStateNotification(pendingNotification())).toEqual(pendingNotification());
    expect(() => parseRemoteConnectionStateNotification({ ...pendingNotification(), extra: true }))
      .toThrowError(expect.objectContaining({ code: "SUBVERSIONR_REMOTE_CONNECTION_NOTIFICATION_INVALID" }));
  });

  it("preserves authorization denial as distinct attention state", () => {
    const notification = {
      repositoryId: "repo",
      epoch: 1,
      state: { kind: "attention", reason: "authorizationDenied" },
    } as const;
    expect(parseRemoteConnectionStateNotification(notification)).toEqual(notification);
  });

  it("schedules pending recovery once and does not recurse while recovery is checking", async () => {
    const store = registeredStore();
    const scheduleRecovery = vi.fn().mockResolvedValue(undefined);
    const projection = { updateRemoteConnectionState: vi.fn() };
    const handler = createRemoteConnectionNotificationHandler({
      store, projection, now: () => NOW, scheduleRecovery, recordBackgroundRecoveryFailure: vi.fn(),
    });

    expect(handler("remoteConnection/state", pendingNotification())).toBe(true);
    expect(scheduleRecovery).toHaveBeenCalledOnce();
    store.beginRecovery({
      repositoryId: "repo", epoch: 1, operationId: RECOVERY_ID,
      startedAt: NOW, deadlineAt: "2026-07-18T01:00:32.000Z",
    });
    handler("remoteConnection/state", pendingNotification());
    await Promise.resolve();

    expect(scheduleRecovery).toHaveBeenCalledOnce();
    expect(store.getState("repo")).toMatchObject({
      kind: "indeterminate",
      recovery: { kind: "checking", operationId: RECOVERY_ID, originOperationId: ORIGIN_ID },
    });
  });

  it("accepts read-only indeterminate/notRequired without scheduling recovery", () => {
    const store = registeredStore();
    const scheduleRecovery = vi.fn();
    const handler = createRemoteConnectionNotificationHandler({
      store, projection: { updateRemoteConnectionState: vi.fn() }, now: () => NOW,
      scheduleRecovery, recordBackgroundRecoveryFailure: vi.fn(),
    });
    handler("remoteConnection/state", {
      ...pendingNotification(),
      state: { ...pendingNotification().state, recovery: "notRequired" },
    });

    expect(store.getState("repo")).toMatchObject({ kind: "indeterminate", recovery: { kind: "notRequired" } });
    expect(scheduleRecovery).not.toHaveBeenCalled();
  });

  it("marks Incoming stale on unchecked while preserving the last successful timestamp", () => {
    const store = registeredStore();
    store.beginCheck({ repositoryId: "repo", epoch: 1, operationId: ORIGIN_ID, startedAt: NOW });
    store.completeOnline({
      repositoryId: "repo", epoch: 1, operationId: ORIGIN_ID, transport: "https",
      checkedAt: NOW, incomingApplied: true,
    });
    const handler = createRemoteConnectionNotificationHandler({
      store, projection: { updateRemoteConnectionState: vi.fn() }, now: () => NOW,
      scheduleRecovery: vi.fn(), recordBackgroundRecoveryFailure: vi.fn(),
    });
    handler("remoteConnection/state", { repositoryId: "repo", epoch: 1, state: { kind: "unchecked" } });

    expect(store.getState("repo")).toMatchObject({
      kind: "unchecked",
      incoming: { kind: "stale", lastSuccessfulCheckAt: NOW },
    });
  });

  it("quietly consumes valid notifications for unregistered or rebound repository epochs", () => {
    const store = registeredStore();
    const projection = { updateRemoteConnectionState: vi.fn() };
    const scheduleRecovery = vi.fn();
    const handler = createRemoteConnectionNotificationHandler({
      store, projection, now: () => NOW, scheduleRecovery, recordBackgroundRecoveryFailure: vi.fn(),
    });
    store.unregisterRepository("repo");

    expect(handler("remoteConnection/state", pendingNotification())).toBe(true);
    expect(store.applyDaemonState({ ...pendingNotification(), receivedAt: NOW })).toEqual({
      applied: false,
      state: undefined,
    });

    store.registerRepository({ repositoryId: "repo", epoch: 2 });
    expect(handler("remoteConnection/state", pendingNotification())).toBe(true);
    expect(store.applyDaemonState({ ...pendingNotification(), receivedAt: NOW })).toEqual({
      applied: false,
      state: undefined,
    });
    expect(projection.updateRemoteConnectionState).not.toHaveBeenCalled();
    expect(scheduleRecovery).not.toHaveBeenCalled();
  });

  it("still fails fast for malformed stale notifications", () => {
    const store = registeredStore();
    store.unregisterRepository("repo");
    const handler = createRemoteConnectionNotificationHandler({
      store, projection: { updateRemoteConnectionState: vi.fn() }, now: () => NOW,
      scheduleRecovery: vi.fn(), recordBackgroundRecoveryFailure: vi.fn(),
    });

    expect(() => handler("remoteConnection/state", { ...pendingNotification(), extra: true }))
      .toThrowError(expect.objectContaining({ code: "SUBVERSIONR_REMOTE_CONNECTION_NOTIFICATION_INVALID" }));
  });
});

function registeredStore(): RemoteConnectionStateStore {
  const store = new RemoteConnectionStateStore();
  store.registerRepository({ repositoryId: "repo", epoch: 1 });
  return store;
}

function pendingNotification() {
  return {
    repositoryId: "repo",
    epoch: 1,
    state: {
      kind: "indeterminate" as const,
      reason: "workerTerminated" as const,
      originOperationId: ORIGIN_ID,
      recovery: "pending" as const,
      cleanupAppropriate: false,
    },
  };
}
