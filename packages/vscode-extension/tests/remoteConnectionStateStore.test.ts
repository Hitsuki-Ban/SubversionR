import { describe, expect, it, vi } from "vitest";
import {
  RemoteConnectionStateStore,
  type NativeRemoteFailure,
} from "../src/status/remoteConnectionStateStore";

const CHECK_ID = "00000000-0000-4000-8000-000000000001";
const NEXT_CHECK_ID = "00000000-0000-4000-8000-000000000002";
const RECOVERY_ID = "00000000-0000-4000-8000-000000000003";
const STARTED_AT = "2026-07-18T01:00:00.000Z";
const COMPLETED_AT = "2026-07-18T01:00:01.000Z";

describe("RemoteConnectionStateStore", () => {
  it("registers independent unchecked state for each repository", () => {
    const store = new RemoteConnectionStateStore();

    expect(store.registerRepository({ repositoryId: "repo-a", epoch: 1 })).toEqual({
      kind: "unchecked",
      repositoryId: "repo-a",
      epoch: 1,
      incoming: { kind: "unchecked" },
      recovery: { kind: "notRequired" },
    });
    expect(store.registerRepository({ repositoryId: "repo-b", epoch: 2 })).toMatchObject({
      repositoryId: "repo-b",
      epoch: 2,
    });
    expect(store.getState("repo-a")).toMatchObject({ repositoryId: "repo-a", epoch: 1 });
  });

  it("linearizes checks by operation id and marks a successful Incoming projection fresh", () => {
    const store = registeredStore();
    store.beginCheck({ repositoryId: "repo", epoch: 1, operationId: CHECK_ID, startedAt: STARTED_AT });
    expect(() => store.beginCheck({ repositoryId: "repo", epoch: 1, operationId: NEXT_CHECK_ID, startedAt: COMPLETED_AT }))
      .toThrowError(expect.objectContaining({ code: "SUBVERSIONR_REMOTE_STATE_CHECK_IN_PROGRESS" }));
    store.completeFailure({
      repositoryId: "repo",
      epoch: 1,
      operationId: CHECK_ID,
      failedAt: COMPLETED_AT,
      failure: failure("cancelled", "operationCancelled"),
      workingCopyRecoveryRequired: false,
    });
    store.beginCheck({ repositoryId: "repo", epoch: 1, operationId: NEXT_CHECK_ID, startedAt: COMPLETED_AT });

    expect(store.completeOnline({
      repositoryId: "repo",
      epoch: 1,
      operationId: CHECK_ID,
      transport: "https",
      checkedAt: COMPLETED_AT,
      incomingApplied: true,
    }).applied).toBe(false);
    expect(store.completeOnline({
      repositoryId: "repo",
      epoch: 1,
      operationId: NEXT_CHECK_ID,
      transport: "https",
      checkedAt: COMPLETED_AT,
      incomingApplied: true,
    })).toEqual({
      applied: true,
      state: {
        kind: "online",
        repositoryId: "repo",
        epoch: 1,
        transport: "https",
        checkedAt: COMPLETED_AT,
        incoming: { kind: "fresh", lastSuccessfulCheckAt: COMPLETED_AT },
        recovery: { kind: "notRequired" },
      },
    });
  });

  it.each([
    [failure("attention", "authenticationRequired"), "attention", "authRequired"],
    [failure("attention", "authorizationDenied"), "attention", "authorizationDenied"],
    [failure("attention", "tlsUntrusted"), "attention", "certificateRequired"],
    [failure("attention", "sshHostKeyRequired"), "attention", "hostKeyRequired"],
    [failure("attention", "remoteConfigurationInvalid"), "attention", "configurationInvalid"],
    [failure("attention", "remoteCapabilityUnsupported"), "attention", "unsupportedCapability"],
    [failure("unreachable", "networkDns"), "unreachable", "dns"],
    [failure("unreachable", "networkRefused"), "unreachable", "refused"],
    [failure("unreachable", "proxyUnreachable"), "unreachable", "proxy"],
    [failure("unreachable", "networkTimeout"), "unreachable", "timeout"],
    [failure("unreachable", "operationDeadlineExceeded"), "unreachable", "timeout"],
    [failure("unreachable", "sshTunnelFailed"), "unreachable", "tunnel"],
    [failure("indeterminate", "remoteOperationIndeterminate"), "indeterminate", "cancelledAfterMutation"],
    [failure("indeterminate", "workerContainmentFailed"), "indeterminate", "workerTerminated"],
  ] as const)("maps %s to bounded %s/%s state", (remoteFailure, kind, reason) => {
    const store = onlineThenCheckingStore();

    const result = store.completeFailure({
      repositoryId: "repo",
      epoch: 1,
      operationId: NEXT_CHECK_ID,
      failedAt: COMPLETED_AT,
      failure: remoteFailure,
      workingCopyRecoveryRequired: false,
    });

    expect(result.applied).toBe(true);
    expect(result.state).toMatchObject({
      kind,
      reason,
      incoming: { kind: "stale", lastSuccessfulCheckAt: STARTED_AT },
      lastFailure: { reason: remoteFailure.reason, occurredAt: COMPLETED_AT },
    });
  });

  it("settles cancellation without a modal-loop state and keeps Incoming stale", () => {
    const store = onlineThenCheckingStore();

    expect(store.completeFailure({
      repositoryId: "repo",
      epoch: 1,
      operationId: NEXT_CHECK_ID,
      failedAt: COMPLETED_AT,
      failure: failure("cancelled", "operationCancelled"),
      workingCopyRecoveryRequired: false,
    }).state).toMatchObject({
      kind: "unchecked",
      incoming: { kind: "stale", lastSuccessfulCheckAt: STARTED_AT },
      lastFailure: { reason: "operationCancelled" },
    });
  });

  it("keeps an unknown bounded failure unclassified and redacted", () => {
    const store = onlineThenCheckingStore();

    expect(store.completeFailure({
      repositoryId: "repo",
      epoch: 1,
      operationId: NEXT_CHECK_ID,
      failedAt: COMPLETED_AT,
      failure: failure("attention", "unknownRemote"),
      workingCopyRecoveryRequired: false,
    }).state).toMatchObject({
      kind: "unchecked",
      incoming: { kind: "stale" },
      lastFailure: { reason: "unknownRemote", cleanupAppropriate: false },
    });
  });

  it("requires a new recovery operation id and retains a blocked terminal lane", () => {
    const store = registeredStore();
    store.beginCheck({ repositoryId: "repo", epoch: 1, operationId: CHECK_ID, startedAt: STARTED_AT });
    store.completeFailure({
      repositoryId: "repo",
      epoch: 1,
      operationId: CHECK_ID,
      failedAt: COMPLETED_AT,
      failure: failure("indeterminate", "workerContainmentFailed"),
      workingCopyRecoveryRequired: true,
    });

    expect(() => store.beginRecovery({
      repositoryId: "repo",
      epoch: 1,
      operationId: CHECK_ID,
      startedAt: COMPLETED_AT,
      deadlineAt: "2026-07-18T01:00:31.000Z",
    })).toThrowError(expect.objectContaining({ code: "SUBVERSIONR_REMOTE_STATE_RECOVERY_OPERATION_REUSED" }));

    store.beginRecovery({
      repositoryId: "repo",
      epoch: 1,
      operationId: RECOVERY_ID,
      startedAt: COMPLETED_AT,
      deadlineAt: "2026-07-18T01:00:31.000Z",
    });
    const blocked = store.completeRecovery({
      repositoryId: "repo",
      epoch: 1,
      operationId: RECOVERY_ID,
      completedAt: "2026-07-18T01:00:02.000Z",
      result: "blocked",
      failure: failure("indeterminate", "remoteRecoveryBlocked"),
    });

    expect(blocked.state).toMatchObject({
      kind: "indeterminate",
      recovery: { kind: "blocked", operationId: CHECK_ID, reason: "remoteRecoveryBlocked" },
    });
    expect(() => store.beginCheck({
      repositoryId: "repo",
      epoch: 1,
      operationId: NEXT_CHECK_ID,
      startedAt: COMPLETED_AT,
    })).toThrowError(expect.objectContaining({ code: "SUBVERSIONR_REMOTE_STATE_RECOVERY_REQUIRED" }));
  });

  it("rejects unbounded or inconsistent native failure payloads", () => {
    const store = registeredStore();
    store.beginCheck({ repositoryId: "repo", epoch: 1, operationId: CHECK_ID, startedAt: STARTED_AT });

    expect(() => store.completeFailure({
      repositoryId: "repo",
      epoch: 1,
      operationId: CHECK_ID,
      failedAt: COMPLETED_AT,
      failure: { category: "attention", reason: "networkDns", cleanupAppropriate: false },
      workingCopyRecoveryRequired: false,
    })).toThrowError(expect.objectContaining({ code: "SUBVERSIONR_REMOTE_FAILURE_INVALID" }));
    expect(() => store.completeFailure({
      repositoryId: "repo",
      epoch: 1,
      operationId: CHECK_ID,
      failedAt: COMPLETED_AT,
      failure: { category: "attention", reason: "authenticationRequired", cleanupAppropriate: false, raw: "secret" } as never,
      workingCopyRecoveryRequired: false,
    })).toThrowError(expect.objectContaining({ code: "SUBVERSIONR_REMOTE_FAILURE_INVALID" }));
  });

  it("keeps a read-only indeterminate failure retryable without requiring working-copy recovery", () => {
    const store = onlineThenCheckingStore();

    expect(store.completeFailure({
      repositoryId: "repo",
      epoch: 1,
      operationId: NEXT_CHECK_ID,
      failedAt: COMPLETED_AT,
      failure: failure("indeterminate", "workerContainmentFailed"),
      workingCopyRecoveryRequired: false,
    }).state).toMatchObject({
      kind: "indeterminate",
      reason: "workerTerminated",
      incoming: { kind: "stale", lastSuccessfulCheckAt: STARTED_AT },
      recovery: { kind: "notRequired" },
    });
  });

  it("prioritizes explicit mutation effect over cancellation classification", () => {
    const store = onlineThenCheckingStore();

    expect(store.completeFailure({
      repositoryId: "repo",
      epoch: 1,
      operationId: NEXT_CHECK_ID,
      failedAt: COMPLETED_AT,
      failure: failure("cancelled", "operationCancelled"),
      workingCopyRecoveryRequired: true,
    }).state).toMatchObject({
      kind: "indeterminate",
      reason: "cancelledAfterMutation",
      recovery: { kind: "required", operationId: NEXT_CHECK_ID },
    });
  });

  it("rebinds required and in-flight recovery to a new epoch without losing the origin operation", () => {
    const store = registeredStore();
    store.beginCheck({ repositoryId: "repo", epoch: 1, operationId: CHECK_ID, startedAt: STARTED_AT });
    store.completeFailure({
      repositoryId: "repo",
      epoch: 1,
      operationId: CHECK_ID,
      failedAt: COMPLETED_AT,
      failure: failure("indeterminate", "workerContainmentFailed"),
      workingCopyRecoveryRequired: true,
    });
    store.beginRecovery({
      repositoryId: "repo",
      epoch: 1,
      operationId: RECOVERY_ID,
      startedAt: COMPLETED_AT,
      deadlineAt: "2026-07-18T01:00:31.000Z",
    });

    expect(store.rebindRepository({ repositoryId: "repo", epoch: 2 })).toMatchObject({
      kind: "indeterminate",
      epoch: 2,
      recovery: { kind: "required", operationId: CHECK_ID, requiredAt: COMPLETED_AT },
    });
  });

  it("notifies with cloned state", () => {
    const store = new RemoteConnectionStateStore();
    const listener = vi.fn();
    store.onDidChange(listener);

    const state = store.registerRepository({ repositoryId: "repo", epoch: 1 });
    state.incoming.kind = "stale";

    expect(listener).toHaveBeenCalledWith(expect.objectContaining({ incoming: { kind: "unchecked" } }));
    expect(store.getState("repo")).toMatchObject({ incoming: { kind: "unchecked" } });
  });

  it("settles stale check completions as unapplied after unregister or epoch rebind", () => {
    const unregistered = registeredStore();
    unregistered.beginCheck({ repositoryId: "repo", epoch: 1, operationId: CHECK_ID, startedAt: STARTED_AT });
    unregistered.unregisterRepository("repo");

    expect(unregistered.completeOnline({
      repositoryId: "repo", epoch: 1, operationId: CHECK_ID, transport: "https",
      checkedAt: COMPLETED_AT, incomingApplied: true,
    })).toEqual({ applied: false, state: undefined });
    expect(unregistered.completeFailure({
      repositoryId: "repo", epoch: 1, operationId: CHECK_ID, failedAt: COMPLETED_AT,
      failure: failure("unreachable", "networkTimeout"), workingCopyRecoveryRequired: false,
    })).toEqual({ applied: false, state: undefined });

    const rebound = registeredStore();
    rebound.beginCheck({ repositoryId: "repo", epoch: 1, operationId: CHECK_ID, startedAt: STARTED_AT });
    const reboundState = rebound.rebindRepository({ repositoryId: "repo", epoch: 2 });
    expect(rebound.completeOnline({
      repositoryId: "repo", epoch: 1, operationId: CHECK_ID, transport: "https",
      checkedAt: COMPLETED_AT, incomingApplied: true,
    })).toEqual({ applied: false, state: undefined });
    expect(rebound.completeFailure({
      repositoryId: "repo", epoch: 1, operationId: CHECK_ID, failedAt: COMPLETED_AT,
      failure: failure("unreachable", "networkTimeout"), workingCopyRecoveryRequired: false,
    })).toEqual({ applied: false, state: undefined });
    expect(rebound.getState("repo")).toEqual(reboundState);
  });

  it("settles stale recovery completion as unapplied after epoch rebind", () => {
    const store = registeredStore();
    store.beginCheck({ repositoryId: "repo", epoch: 1, operationId: CHECK_ID, startedAt: STARTED_AT });
    store.completeFailure({
      repositoryId: "repo", epoch: 1, operationId: CHECK_ID, failedAt: COMPLETED_AT,
      failure: failure("indeterminate", "workerContainmentFailed"), workingCopyRecoveryRequired: true,
    });
    store.beginRecovery({
      repositoryId: "repo", epoch: 1, operationId: RECOVERY_ID,
      startedAt: COMPLETED_AT, deadlineAt: "2026-07-18T01:00:31.000Z",
    });
    const reboundState = store.rebindRepository({ repositoryId: "repo", epoch: 2 });

    expect(store.completeRecovery({
      repositoryId: "repo", epoch: 1, operationId: RECOVERY_ID,
      completedAt: "2026-07-18T01:00:02.000Z", result: "safe",
    })).toEqual({ applied: false, state: undefined });
    expect(store.getState("repo")).toEqual(reboundState);
  });

  it("keeps local command entry points strict after unregister", () => {
    const store = registeredStore();
    store.unregisterRepository("repo");

    expect(() => store.beginCheck({
      repositoryId: "repo", epoch: 1, operationId: CHECK_ID, startedAt: STARTED_AT,
    })).toThrowError(expect.objectContaining({ code: "SUBVERSIONR_REMOTE_STATE_REPOSITORY_NOT_REGISTERED" }));
  });
});

function registeredStore(): RemoteConnectionStateStore {
  const store = new RemoteConnectionStateStore();
  store.registerRepository({ repositoryId: "repo", epoch: 1 });
  return store;
}

function onlineThenCheckingStore(): RemoteConnectionStateStore {
  const store = registeredStore();
  store.beginCheck({ repositoryId: "repo", epoch: 1, operationId: CHECK_ID, startedAt: STARTED_AT });
  store.completeOnline({
    repositoryId: "repo",
    epoch: 1,
    operationId: CHECK_ID,
    transport: "https",
    checkedAt: STARTED_AT,
    incomingApplied: true,
  });
  store.beginCheck({ repositoryId: "repo", epoch: 1, operationId: NEXT_CHECK_ID, startedAt: COMPLETED_AT });
  return store;
}

function failure(
  category: NativeRemoteFailure["category"],
  reason: NativeRemoteFailure["reason"],
): NativeRemoteFailure {
  return { category, reason, cleanupAppropriate: false };
}
