import { describe, expect, it, vi } from "vitest";
import type { BackendConnection } from "../src/backend/backendProcess";
import {
  collectInstalledSvnAnonymousRecoverySafeReport,
  type InstalledSvnAnonymousRecoverySafeReportOptions,
} from "../src/diagnostics/installedSvnAnonymousRecoverySafeReport";
import type { ScmRepositoryProjection } from "../src/scm/sourceControlResourceStore";
import type { RemoteConnectionState } from "../src/status/remoteConnectionStateStore";
import type { StoredStatusSnapshot, StatusStaleMark } from "../src/status/statusSnapshotStore";
import { JsonRpcStreamError } from "../src/transport/jsonRpcStreamClient";

const TOKEN = "1234567890abcdef1234567890abcdef";
const URL = "svn://127.0.0.1:3791/repo/trunk";
const WC = "C:\\evidence\\recovery-safe-wc";
const STATE_PATH = "C:\\evidence\\command-stall-state.json";
const ORIGIN_ID = "70000000-0000-4000-8000-000000000001";
const RECOVERY_ID = "70000000-0000-4000-8000-000000000002";

describe("installed SVN anonymous recovery-safe report", () => {
  it("observes the production-scheduled recovery and proves a fresh local lane after Safe", async () => {
    const harness = createHarness();

    const report = await collectInstalledSvnAnonymousRecoverySafeReport(harness.options);

    expect(report).toMatchObject({
      schema: "subversionr.release.m8-i6-installed-vsix-recovery-safe.v1",
      schemaVersion: 1,
      kind: "subversionr.installedSvnAnonymousRecoverySafeReport",
      status: "passed",
      cell: "recoverySafe",
      surface: "installed-vsix-extension-host",
      prerequisite: {
        code: "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT",
        reason: "operationDeadlineExceeded",
        recovery: "pending",
      },
      transitions: ["required", "checking", "safe"],
      statusStaleReason: "remoteRecoverySafeRequiresFullReconcile",
      fixtureCountersUnchangedAfterPrerequisite: true,
      safe: {
        outcome: "Safe",
        freshReconcile: true,
        nativeLaneReleased: true,
        subsequentRequestPassed: true,
      },
      authActivity: { credentialRequests: 0, credentialSettlements: 0, certificateRequests: 0 },
      diagnosticsRedacted: true,
    });
    expect(JSON.stringify(report)).not.toContain(RECOVERY_ID);
    expect(harness.sendRequest.mock.calls.map(([method]) => method)).toEqual([
      "operation/run",
      "status/getSnapshot",
      "diagnostics/get",
    ]);
    expect(harness.options.fullReconcile).toHaveBeenCalledWith("repo", 1);
    expect(harness.options.closeRepository).toHaveBeenCalledWith("repo");
    expect(harness.disposed()).toEqual({ state: true, stale: true });
  });

  it("fails closed if the automatic flow skips the checking transition", async () => {
    const harness = createHarness({ transitions: ["required", "safe"] });

    await expect(collectInstalledSvnAnonymousRecoverySafeReport(harness.options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_SAFE_TRANSITION_INVALID",
    });
    expect(harness.options.fullReconcile).not.toHaveBeenCalled();
    expect(harness.options.closeRepository).toHaveBeenCalledWith("repo");
  });

  it("fails closed if recovery, reconcile, or subsequent local status contacts the fixture", async () => {
    const harness = createHarness({ changeFixtureAfterPrerequisite: true });

    await expect(collectInstalledSvnAnonymousRecoverySafeReport(harness.options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_SAFE_NETWORK_PROGRESS_INVALID",
    });
    expect(harness.options.fullReconcile).not.toHaveBeenCalled();
  });

  it.each([
    ["required cancellation state", { transition: "required", reason: "cancelledAfterMutation" }],
    ["checking cancellation state", { transition: "checking", reason: "cancelledAfterMutation" }],
    ["required cancellation failure", { transition: "required", lastFailureReason: "operationCancelled" }],
    ["checking cancellation failure", { transition: "checking", lastFailureReason: "operationCancelled" }],
    ["required cleanup-appropriate failure", { transition: "required", cleanupAppropriate: true }],
    ["checking cleanup-appropriate failure", { transition: "checking", cleanupAppropriate: true }],
  ] as const)("rejects a timeout-derived pending mismatch: %s", async (_name, pendingMismatch) => {
    const harness = createHarness({ pendingMismatch });

    await expect(collectInstalledSvnAnonymousRecoverySafeReport(harness.options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_SAFE_TRANSITION_INVALID",
    });
    expect(harness.options.fullReconcile).not.toHaveBeenCalled();
  });

  it.each([
    ["non-canonical", "recovery-operation"],
    ["reused origin", ORIGIN_ID],
  ])("rejects a %s recovery operation id", async (_name, recoveryOperationId) => {
    const harness = createHarness({ recoveryOperationId });

    await expect(collectInstalledSvnAnonymousRecoverySafeReport(harness.options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_SAFE_TRANSITION_INVALID",
    });
    expect(harness.options.fullReconcile).not.toHaveBeenCalled();
  });

  it("rejects diagnostics that leak the observed recovery operation id", async () => {
    const harness = createHarness({
      diagnostics: {
        source: "subversionr-daemon",
        protocol: { major: 1, minor: 35 },
        recoveryOperationId: RECOVERY_ID,
      },
    });

    await expect(collectInstalledSvnAnonymousRecoverySafeReport(harness.options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_SAFE_DIAGNOSTICS_LEAK",
    });
  });

  it("rejects missing tokens, request extensions, non-canonical ids, and non-reviewed timeouts before initialization", async () => {
    for (const candidateRequest of [
      request({ token: "wrong" }),
      request({ extra: true }),
      request({ operationId: "not-a-uuid" }),
      request({ timeoutMs: 501 }),
      request({ fixtureStatePath: "relative.json" }),
      request({ repositoryUrl: "https://127.0.0.1/repo/trunk" }),
    ]) {
      const harness = createHarness({ request: candidateRequest });
      await expect(collectInstalledSvnAnonymousRecoverySafeReport(harness.options)).rejects.toMatchObject({
        code: expect.stringMatching(/^SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_RECOVERY_SAFE_/u),
      });
      expect(harness.options.initialize).not.toHaveBeenCalled();
    }
  });
});

function createHarness(overrides: {
  request?: Record<string, unknown>;
  transitions?: Array<"required" | "checking" | "safe">;
  changeFixtureAfterPrerequisite?: boolean;
  recoveryOperationId?: string;
  pendingMismatch?: PendingMismatch;
  diagnostics?: unknown;
} = {}) {
  const stateListeners = new Set<(state: RemoteConnectionState) => void>();
  const staleListeners = new Set<(mark: StatusStaleMark) => void>();
  let stateDisposed = false;
  let staleDisposed = false;
  let currentRemoteState = initialUncheckedState();
  let currentSnapshot = snapshot(1, "complete", "libsvn-local");
  let fixtureReads = 0;
  const emitState = (state: RemoteConnectionState) => {
    currentRemoteState = state;
    for (const listener of stateListeners) listener(state);
  };
  const emitStale = () => {
    currentSnapshot = snapshot(1, "stale", "subversionr-daemon");
    const mark: StatusStaleMark = {
      repositoryId: "repo",
      epoch: 1,
      reason: "remoteRecoverySafeRequiresFullReconcile",
      timestamp: "2026-07-20T00:00:01.000Z",
      source: "subversionr-daemon",
    };
    for (const listener of staleListeners) listener(mark);
  };
  const requestedTransitions = overrides.transitions ?? ["required", "checking", "safe"];
  const sendRequest = vi.fn(async (method: string, params: unknown): Promise<unknown> => {
    if (method === "operation/run") {
      expect(params).toMatchObject({
        kind: "update",
        repositoryId: "repo",
        epoch: 1,
        options: { path: "." },
        remote: { operationId: ORIGIN_ID, timeoutMs: 500 },
      });
      emitState(operationCheckingState());
      queueMicrotask(() => {
        for (const transition of requestedTransitions) {
          emitState(remoteState(transition, overrides.recoveryOperationId ?? RECOVERY_ID, overrides.pendingMismatch));
        }
        emitStale();
      });
      throw timeoutError();
    }
    if (method === "status/getSnapshot") return snapshot(2, "complete", "libsvn-local");
    if (method === "diagnostics/get") {
      return overrides.diagnostics ?? {
        source: "subversionr-daemon",
        protocol: { major: 1, minor: 35 },
        operation: "[redacted]",
      };
    }
    throw new Error(`unexpected method ${method}`);
  });
  const options: InstalledSvnAnonymousRecoverySafeReportOptions = {
    expectedToken: TOKEN,
    request: overrides.request ?? request(),
    initialize: vi.fn().mockResolvedValue(connection(sendRequest)),
    openWorkingCopy: vi.fn().mockResolvedValue(session()),
    closeRepository: vi.fn().mockResolvedValue(undefined),
    onRemoteStateChange: (listener) => {
      stateListeners.add(listener);
      return { dispose: () => { stateDisposed = true; stateListeners.delete(listener); } };
    },
    onStatusStale: (listener) => {
      staleListeners.add(listener);
      return { dispose: () => { staleDisposed = true; staleListeners.delete(listener); } };
    },
    getRemoteState: () => currentRemoteState,
    getStatusSnapshot: () => currentSnapshot,
    getProjection: () => projection(currentSnapshot.generation, currentSnapshot.completeness === "complete" ? "complete" : "stale"),
    fullReconcile: vi.fn(async () => { currentSnapshot = snapshot(2, "complete", "libsvn-local"); }),
    readFixtureState: vi.fn(async () => {
      fixtureReads += 1;
      return fixtureState(overrides.changeFixtureAfterPrerequisite && fixtureReads > 1 ? 1 : 0);
    }),
    authActivity: () => ({ credentialRequests: 0, credentialSettlements: 0, certificateRequests: 0 }),
  };
  return {
    options,
    sendRequest,
    disposed: () => ({ state: stateDisposed, stale: staleDisposed }),
  };
}

function request(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    token: TOKEN,
    repositoryUrl: URL,
    workingCopyPath: WC,
    operationId: ORIGIN_ID,
    fixtureStatePath: STATE_PATH,
    timeoutMs: 500,
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

interface PendingMismatch {
  transition: "required" | "checking";
  reason?: "workerTerminated" | "cancelledAfterMutation";
  lastFailureReason?: "workerContainmentFailed" | "operationCancelled";
  cleanupAppropriate?: boolean;
}

function remoteState(
  transition: "required" | "checking" | "safe",
  recoveryOperationId: string,
  mismatch?: PendingMismatch,
): RemoteConnectionState {
  const common = { repositoryId: "repo", epoch: 1, incoming: { kind: "stale" as const } };
  const pendingMismatch = mismatch?.transition === transition ? mismatch : undefined;
  const pending = {
    ...common,
    kind: "indeterminate" as const,
    reason: pendingMismatch?.reason ?? "workerTerminated",
    lastFailure: {
      reason: pendingMismatch?.lastFailureReason ?? "workerContainmentFailed",
      cleanupAppropriate: pendingMismatch?.cleanupAppropriate ?? false,
      occurredAt: "2026-07-20T00:00:01.000Z",
    },
  };
  if (transition === "required") {
    return { ...pending, recovery: { kind: "required", operationId: ORIGIN_ID, requiredAt: "2026-07-20T00:00:01.000Z" } };
  }
  if (transition === "checking") {
    return { ...pending, recovery: { kind: "checking", operationId: recoveryOperationId, originOperationId: ORIGIN_ID, startedAt: "2026-07-20T00:00:02.000Z", deadlineAt: "2026-07-20T00:00:32.000Z" } };
  }
  return { ...common, kind: "unchecked", recovery: { kind: "safe", operationId: recoveryOperationId, completedAt: "2026-07-20T00:00:03.000Z" } };
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

function snapshot(generation: number, completeness: "complete" | "stale", source: string): StoredStatusSnapshot {
  return {
    repositoryId: "repo",
    epoch: 1,
    generation,
    completeness,
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
    source,
  };
}

function projection(generation: number, completeness: "complete" | "stale"): ScmRepositoryProjection {
  return {
    repositoryId: "repo",
    epoch: 1,
    workingCopyRoot: WC,
    generation,
    freshness: {
      repositoryCompleteness: completeness,
      lastRefreshCompleteness: completeness,
      lastRefreshKind: completeness === "complete" ? "snapshot" : "stale",
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
