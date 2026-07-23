import { describe, expect, it, vi } from "vitest";
import type { BackendConnection } from "../src/backend/backendProcess";
import {
  collectInstalledSvnAnonymousRecoveryIndeterminateReport,
  type InstalledSvnAnonymousRecoveryIndeterminateReportOptions,
} from "../src/diagnostics/installedSvnAnonymousRecoveryIndeterminateReport";
import type { ScmRepositoryProjection } from "../src/scm/sourceControlResourceStore";
import type { NativeRemoteFailureReason, RemoteConnectionState } from "../src/status/remoteConnectionStateStore";
import type { StoredStatusSnapshot } from "../src/status/statusSnapshotStore";
import { JsonRpcStreamError } from "../src/transport/jsonRpcStreamClient";

const TOKEN = "1234567890abcdef1234567890abcdef";
const URL = "svn://127.0.0.1:3791/repo/trunk";
const WC = "C:\\evidence\\recovery-indeterminate-wc";
const STATE_PATH = "C:\\evidence\\command-stall-state.json";
const ORIGIN_ID = "70000000-0000-4000-8000-000000000001";
const RECOVERY_ID = "70000000-0000-4000-8000-000000000002";

describe("installed SVN anonymous recovery-indeterminate report", () => {
  it("observes automatic recovery settling Indeterminate and proves the local lane remains blocked", async () => {
    const harness = createHarness();

    const report = await collectInstalledSvnAnonymousRecoveryIndeterminateReport(harness.options);

    expect(report).toMatchObject({
      schema: "subversionr.release.m8-i6-installed-vsix-recovery-indeterminate.v1",
      schemaVersion: 1,
      kind: "subversionr.installedSvnAnonymousRecoveryIndeterminateReport",
      status: "passed",
      cell: "recoveryIndeterminate",
      surface: "installed-vsix-extension-host",
      stableCode: "SUBVERSIONR_REMOTE_OPERATION_INDETERMINATE",
      reason: "remoteOperationIndeterminate",
      originCode: "SUBVERSIONR_REMOTE_OPERATION_INDETERMINATE",
      originReason: "remoteOperationIndeterminate",
      settlementCode: "SUBVERSIONR_REMOTE_OPERATION_INDETERMINATE",
      settlementReason: "remoteOperationIndeterminate",
      prerequisite: {
        code: "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT",
        reason: "operationDeadlineExceeded",
        recovery: "pending",
      },
      transitions: ["required", "checking", "required"],
      fixtureCountersUnchangedAfterPrerequisite: true,
      indeterminate: {
        outcome: "Indeterminate",
        stableCode: "SUBVERSIONR_REMOTE_OPERATION_INDETERMINATE",
        reason: "remoteOperationIndeterminate",
        nativeLaneBlocked: true,
        explicitRecoveryRequired: true,
      },
      networkProgress: "command",
      networkAttempts: 1,
      networkConnections: 1,
      followupNetworkContacts: 0,
      authActivity: { credentialRequests: 0, credentialSettlements: 0, certificateRequests: 0 },
      repositorySession: { opened: true, closeBlockedByIndeterminate: true },
      diagnosticsRedacted: true,
    });
    expect(JSON.stringify(report)).not.toContain(RECOVERY_ID);
    expect(harness.sendRequest.mock.calls.map(([method]) => method)).toEqual([
      "operation/run",
      "status/getSnapshot",
      "diagnostics/get",
    ]);
    expect(harness.options.closeRepository).toHaveBeenCalledWith("repo");
    expect(harness.disposed()).toBe(true);
  });

  it("fails closed if the automatic flow skips recovery checking", async () => {
    const harness = createHarness({ transitions: ["required", "required"] });

    await expect(collectInstalledSvnAnonymousRecoveryIndeterminateReport(harness.options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_INDETERMINATE_TRANSITION_INVALID",
    });
  });

  it("fails closed if the daemon replays the checking notification more than once", async () => {
    const harness = createHarness({ transitions: ["required", "checking", "checking", "checking", "required"] });

    await expect(collectInstalledSvnAnonymousRecoveryIndeterminateReport(harness.options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_INDETERMINATE_TRANSITION_INVALID",
    });
  });

  it.each([
    ["origin reason", { transition: "required", reason: "cancelledAfterMutation" }],
    ["checking failure", { transition: "checking", lastFailureReason: "operationCancelled" }],
    ["checking cleanup", { transition: "checking", cleanupAppropriate: true }],
    ["settlement failure", { transition: "settlement", lastFailureReason: "workerContainmentFailed" }],
    ["settlement cleanup", { transition: "settlement", cleanupAppropriate: true }],
  ] as const)("rejects an automatic recovery mismatch: %s", async (_name, stateMismatch) => {
    const harness = createHarness({ stateMismatch });

    await expect(collectInstalledSvnAnonymousRecoveryIndeterminateReport(harness.options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_INDETERMINATE_TRANSITION_INVALID",
    });
  });

  it("rejects fixture activity after the prerequisite command stalls", async () => {
    const harness = createHarness({ changeFixtureAfterPrerequisite: true });

    await expect(collectInstalledSvnAnonymousRecoveryIndeterminateReport(harness.options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_INDETERMINATE_NETWORK_PROGRESS_INVALID",
    });
  });

  it("rejects a lane error without the reviewed recovery safeArgs", async () => {
    const harness = createHarness({ laneError: indeterminateError({ category: "state" }) });

    await expect(collectInstalledSvnAnonymousRecoveryIndeterminateReport(harness.options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_INDETERMINATE_LANE_INVALID",
    });
  });

  it("rejects diagnostics that leak the observed recovery operation id", async () => {
    const harness = createHarness({
      diagnostics: {
        source: "subversionr-daemon",
        protocol: { major: 1, minor: 35 },
        recoveryOperationId: RECOVERY_ID,
      },
    });

    await expect(collectInstalledSvnAnonymousRecoveryIndeterminateReport(harness.options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_INDETERMINATE_DIAGNOSTICS_LEAK",
    });
  });

  it("rejects missing tokens, request extensions, non-canonical ids, and non-reviewed timeouts before initialization", async () => {
    for (const candidateRequest of [
      request({ token: "wrong" }),
      request({ extra: true }),
      request({ operationId: "not-a-uuid" }),
      request({ timeoutMs: 5001 }),
      request({ fixtureStatePath: "relative.json" }),
      request({ repositoryUrl: "https://127.0.0.1/repo/trunk" }),
    ]) {
      const harness = createHarness({ request: candidateRequest });
      await expect(collectInstalledSvnAnonymousRecoveryIndeterminateReport(harness.options)).rejects.toMatchObject({
        code: expect.stringMatching(/^SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_INDETERMINATE_/u),
      });
      expect(harness.options.initialize).not.toHaveBeenCalled();
    }
  });
});

interface StateMismatch {
  transition: "required" | "checking" | "settlement";
  reason?: "workerTerminated" | "cancelledAfterMutation";
  lastFailureReason?: "workerContainmentFailed" | "operationCancelled";
  cleanupAppropriate?: boolean;
}

function createHarness(overrides: {
  request?: Record<string, unknown>;
  transitions?: Array<"required" | "checking">;
  changeFixtureAfterPrerequisite?: boolean;
  stateMismatch?: StateMismatch;
  laneError?: JsonRpcStreamError;
  diagnostics?: unknown;
} = {}) {
  const stateListeners = new Set<(state: RemoteConnectionState) => void>();
  let disposed = false;
  let currentRemoteState = initialUncheckedState();
  let fixtureReads = 0;
  const laneError = overrides.laneError ?? indeterminateError();
  const emitState = (state: RemoteConnectionState) => {
    currentRemoteState = state;
    for (const listener of stateListeners) listener(state);
  };
  const requestedTransitions = overrides.transitions ?? ["required", "checking", "checking", "required"];
  const sendRequest = vi.fn(async (method: string, params: unknown): Promise<unknown> => {
    if (method === "operation/run") {
      expect(params).toMatchObject({
        kind: "update",
        repositoryId: "repo",
        epoch: 1,
        options: { path: "." },
        remote: { operationId: ORIGIN_ID, timeoutMs: 5_000 },
      });
      emitState(operationCheckingState());
      queueMicrotask(() => {
        for (let index = 0; index < requestedTransitions.length; index += 1) {
          emitState(remoteState(requestedTransitions[index]!, index, overrides.stateMismatch));
        }
      });
      throw timeoutError();
    }
    if (method === "status/getSnapshot") throw laneError;
    if (method === "diagnostics/get") {
      return overrides.diagnostics ?? {
        source: "subversionr-daemon",
        protocol: { major: 1, minor: 35 },
        operation: "[redacted]",
      };
    }
    throw new Error(`unexpected method ${method}`);
  });
  const options: InstalledSvnAnonymousRecoveryIndeterminateReportOptions = {
    expectedToken: TOKEN,
    request: overrides.request ?? request(),
    initialize: vi.fn().mockResolvedValue(connection(sendRequest)),
    openWorkingCopy: vi.fn().mockResolvedValue(session()),
    closeRepository: vi.fn().mockRejectedValue(indeterminateError()),
    onRemoteStateChange: (listener) => {
      stateListeners.add(listener);
      return { dispose: () => { disposed = true; stateListeners.delete(listener); } };
    },
    getRemoteState: () => currentRemoteState,
    getStatusSnapshot: () => snapshot(),
    getProjection: () => projection(),
    readFixtureState: vi.fn(async () => {
      fixtureReads += 1;
      return fixtureState(overrides.changeFixtureAfterPrerequisite && fixtureReads > 1 ? 1 : 0);
    }),
    authActivity: () => ({ credentialRequests: 0, credentialSettlements: 0, certificateRequests: 0 }),
  };
  return { options, sendRequest, disposed: () => disposed };
}

function request(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    token: TOKEN,
    repositoryUrl: URL,
    workingCopyPath: WC,
    operationId: ORIGIN_ID,
    fixtureStatePath: STATE_PATH,
    timeoutMs: 5_000,
    ...overrides,
  };
}

function session() {
  return {
    repositoryId: "repo",
    epoch: 1,
    identity: {
      repositoryUuid: "uuid",
      repositoryRootUrl: "svn://127.0.0.1:3791/repo",
      workingCopyRoot: WC,
      workspaceScopeRoot: WC,
      format: 31,
    },
    watchScope: { repositoryId: "repo", epoch: 1, workingCopyRoot: WC, workspaceScopeRoot: WC },
  };
}

function connection(sendRequest: (method: string, params: unknown) => Promise<unknown>) {
  return {
    initializeResult: {
      protocol: { major: 1, minor: 35 },
      capabilities: {
        realLibsvnBridge: true,
        repositoryOpen: true,
        statusSnapshot: true,
        statusRefresh: true,
        operationRun: true,
        operationRunUpdate: true,
        remoteOperationEnvelope: true,
        remoteWorkerIsolation: true,
        remoteConnectionState: true,
        remoteSvnAnonymous: true,
      },
      acknowledgedTrustEpoch: 7,
    } as BackendConnection["initializeResult"],
    isRemoteSubmissionEnabled: () => true,
    currentRemoteTrustEpoch: () => 7,
    sendRequest: sendRequest as BackendConnection["sendRequest"],
  };
}

function remoteState(
  transition: "required" | "checking",
  index: number,
  mismatch?: StateMismatch,
): RemoteConnectionState {
  const settlement = transition === "required" && index > 0;
  const mismatchKind = settlement ? "settlement" : transition;
  const activeMismatch = mismatch?.transition === mismatchKind ? mismatch : undefined;
  const failureReason: NativeRemoteFailureReason =
    activeMismatch?.lastFailureReason ?? (settlement ? "unknownRemote" : "workerContainmentFailed");
  const common = {
    repositoryId: "repo",
    epoch: 1,
    kind: "indeterminate" as const,
    reason: activeMismatch?.reason ?? "workerTerminated",
    lastFailure: {
      reason: failureReason,
      cleanupAppropriate: activeMismatch?.cleanupAppropriate ?? false,
      occurredAt: "2026-07-20T00:00:01.000Z",
    },
    incoming: { kind: "stale" as const },
  };
  if (transition === "checking") {
    return {
      ...common,
      recovery: {
        kind: "checking",
        operationId: RECOVERY_ID,
        originOperationId: ORIGIN_ID,
        startedAt: "2026-07-20T00:00:02.000Z",
        deadlineAt: "2026-07-20T00:00:32.000Z",
      },
    };
  }
  return {
    ...common,
    recovery: { kind: "required", operationId: ORIGIN_ID, requiredAt: "2026-07-20T00:00:03.000Z" },
  };
}

function initialUncheckedState(): RemoteConnectionState {
  return { kind: "unchecked", repositoryId: "repo", epoch: 1, incoming: { kind: "unchecked" }, recovery: { kind: "notRequired" } };
}

function operationCheckingState(): RemoteConnectionState {
  return {
    kind: "checking",
    repositoryId: "repo",
    epoch: 1,
    operationId: ORIGIN_ID,
    startedAt: "2026-07-20T00:00:00.000Z",
    incoming: { kind: "stale" },
    recovery: { kind: "notRequired" },
  };
}

function snapshot(): StoredStatusSnapshot {
  return {
    repositoryId: "repo",
    epoch: 1,
    generation: 1,
    completeness: "complete",
    identity: {
      repositoryUuid: "uuid",
      repositoryRootUrl: "svn://127.0.0.1:3791/repo",
      workingCopyRoot: WC,
      workspaceScopeRoot: WC,
      format: 31,
    },
    localEntries: [],
    remoteEntries: [],
    summary: { localChanges: 0, remoteChanges: 0, conflicts: 0, unversioned: 0 },
    timestamp: "2026-07-20T00:00:00.000Z",
    source: "libsvn-local",
  };
}

function projection(): ScmRepositoryProjection {
  return {
    repositoryId: "repo",
    epoch: 1,
    workingCopyRoot: WC,
    generation: 1,
    freshness: {
      repositoryCompleteness: "complete",
      lastRefreshCompleteness: "complete",
      lastRefreshKind: "snapshot",
    },
    count: 0,
    groups: [],
  };
}

function fixtureState(followupContacts: number) {
  return {
    schema: "subversionr.release.m8-i6-ra-svn-fault-fixture.v1",
    scenario: "command-stall",
    connections: 1,
    suppliedAuthorityConnections: 0,
    greetingSent: 1,
    clientResponseReceived: 1,
    authRequestSent: 1,
    reposInfoSent: 1,
    commandsReceived: 1,
    followupContacts,
  };
}

function timeoutError(): JsonRpcStreamError {
  return new JsonRpcStreamError({
    code: "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT",
    category: "timeout",
    messageKey: "error.remote.workerTimedOut",
    args: { remoteFailure: { category: "deadline", reason: "operationDeadlineExceeded", cleanupAppropriate: false } },
    retryable: false,
    diagnostics: null,
  });
}

function indeterminateError(
  args: Record<string, unknown> = {
    remoteFailure: { category: "recovery", reason: "remoteOperationIndeterminate", cleanupAppropriate: false },
  },
): JsonRpcStreamError {
  return new JsonRpcStreamError({
    code: "SUBVERSIONR_REMOTE_OPERATION_INDETERMINATE",
    category: "state",
    messageKey: "error.remote.operationIndeterminate",
    args,
    retryable: false,
    diagnostics: null,
  });
}
