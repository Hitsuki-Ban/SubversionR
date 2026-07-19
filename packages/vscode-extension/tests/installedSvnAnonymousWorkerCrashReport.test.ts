import { describe, expect, it, vi } from "vitest";
import type { BackendConnection } from "../src/backend/backendProcess";
import {
  collectInstalledSvnAnonymousWorkerCrashReport,
  type InstalledSvnAnonymousWorkerCrashReportOptions,
} from "../src/diagnostics/installedSvnAnonymousWorkerCrashReport";
import type { RepositorySession } from "../src/repository/repositorySessionService";
import type { RemoteConnectionNotification } from "../src/status/remoteConnectionNotificationHandler";
import { JsonRpcStreamError } from "../src/transport/jsonRpcStreamClient";

const TOKEN = "1234567890abcdef1234567890abcdef";
const REPOSITORY_URL = "svn://127.0.0.1:3692/repo/trunk";
const WORKING_COPY_PATH = "C:/evidence/i6-worker-crash-wc";
const FIXTURE_STATE_PATH = "C:/evidence/i6-worker-crash-fixture-state.json";
const OPERATION_ID = "70000000-0000-4000-8000-000000000001";
const REPOSITORY_ID = "repo-uuid:C:/evidence/i6-worker-crash-wc";

describe("installed SVN anonymous worker crash report", () => {
  it("requires the exact worker crash wire, raw/store terminal state, and a released local lane", async () => {
    const harness = createHarness();
    const report = await collectInstalledSvnAnonymousWorkerCrashReport(harness.options);

    expect(report).toEqual({
      schema: "subversionr.release.m8-i6-installed-vsix-worker-crash.v1",
      schemaVersion: 1,
      kind: "subversionr.installedSvnAnonymousWorkerCrashReport",
      scenario: "workerCrash",
      settlement: {
        code: "SUBVERSIONR_REMOTE_WORKER_CRASHED",
        category: "process",
        messageKey: "error.remote.workerCrashed",
        retryable: false,
        safeArgs: {
          stage: "workerProcess",
          remoteFailure: { category: "process", reason: "workerContainmentFailed", cleanupAppropriate: false },
        },
        diagnostics: null,
      },
      daemonState: {
        kind: "indeterminate",
        reason: "workerTerminated",
        originOperationIdMatched: true,
        recovery: "notRequired",
        cleanupAppropriate: false,
        repositoryIdMatched: true,
        epochMatched: true,
      },
      workerCrashSettlement: {
        trigger: "external-worker-termination-after-greeting",
        terminationExitCode: 1_398_166_083,
        workerIdentityBound: true,
        workerTerminationObserved: true,
        wireSettlementObserved: true,
        daemonSurvived: true,
        nativeLaneReleased: true,
        localSnapshotAfterCrash: true,
        workingCopyPreserved: true,
      },
      protocol: { major: 1, minor: 35 },
      trust: { acknowledgedEpoch: 7, consistent: true },
      authActivity: { credentialRequests: 0, credentialSettlements: 0, certificateRequests: 0 },
      repositorySession: { opened: true, closed: true },
      diagnosticsRedacted: true,
      redaction: { rawUrls: false, rawPaths: false, rawContent: false },
    });
    expect(harness.options.closeRepository).toHaveBeenCalledWith(REPOSITORY_ID);
    expect(harness.sendRequest.mock.calls.map(([method]) => method)).toEqual([
      "status/checkRemote", "status/getSnapshot", "diagnostics/get",
    ]);
  });

  it("rejects non-exact requests before product initialization", async () => {
    for (const requestValue of [
      { ...request(), extra: true },
      { ...request(), operationId: "70000000-0000-4000-8000-00000000000A" },
      { ...request(), fixtureStatePath: "relative.json" },
    ]) {
      const harness = createHarness();
      harness.options.request = requestValue;
      await expect(collectInstalledSvnAnonymousWorkerCrashReport(harness.options)).rejects.toMatchObject({
        code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_WORKER_CRASH_REQUEST_INVALID",
      });
      expect(harness.options.initialize).not.toHaveBeenCalled();
    }
  });

  it("rejects every non-exact crash settlement component", async () => {
    const cases: Array<Record<string, unknown>> = [
      { code: "SUBVERSIONR_REMOTE_WORKER_PROTOCOL_INVALID" },
      { category: "protocol" },
      { messageKey: "error.remote.workerProtocolInvalid" },
      { retryable: true },
      { diagnostics: {} },
      { stage: "supervisor" },
      { failureReason: "unknownRemote" },
      { cleanupAppropriate: true },
      { safeArgsExtra: true },
    ];
    for (const crash of cases) {
      const harness = createHarness({ crash });
      await expect(collectInstalledSvnAnonymousWorkerCrashReport(harness.options)).rejects.toMatchObject({
        code: expect.stringMatching(/^SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_WORKER_CRASH_(WIRE|FAILURE)_INVALID$/u),
      });
    }
  });

  it("rejects a mismatched raw terminal state and a non-released stored lane", async () => {
    const raw = createHarness({ terminal: { recovery: "pending" } });
    await expect(collectInstalledSvnAnonymousWorkerCrashReport(raw.options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_WORKER_CRASH_STATE_INVALID",
    });

    const stored = createHarness({ storedRecovery: "required" });
    await expect(collectInstalledSvnAnonymousWorkerCrashReport(stored.options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_WORKER_CRASH_STORED_STATE_INVALID",
    });
  });

  it("rejects fixture progress, unusable local snapshot, auth activity, and diagnostic leaks", async () => {
    const fixture = createHarness({ finalFixture: fixtureState({ commandsReceived: 1 }) });
    await expect(collectInstalledSvnAnonymousWorkerCrashReport(fixture.options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_WORKER_CRASH_FIXTURE_STATE_INVALID",
    });

    const snapshot = createHarness({ snapshotSource: "libsvn-remote" });
    await expect(collectInstalledSvnAnonymousWorkerCrashReport(snapshot.options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_WORKER_CRASH_LOCAL_SNAPSHOT_INVALID",
    });

    const auth = { credentialRequests: 0, credentialSettlements: 0, certificateRequests: 0 };
    const authHarness = createHarness({ auth, mutateAuth: () => { auth.certificateRequests = 1; } });
    await expect(collectInstalledSvnAnonymousWorkerCrashReport(authHarness.options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_WORKER_CRASH_AUTH_ACTIVITY_INVALID",
    });

    const leak = createHarness({ diagnostics: { source: "subversionr-daemon", protocol: { major: 1, minor: 35 }, capabilities: { remoteSvnAnonymous: true, statusRemoteCheck: true, statusSnapshot: true }, leak: WORKING_COPY_PATH } });
    await expect(collectInstalledSvnAnonymousWorkerCrashReport(leak.options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_WORKER_CRASH_DIAGNOSTICS_LEAK",
    });
  });
});

function createHarness(config: {
  crash?: Record<string, unknown>;
  terminal?: Record<string, unknown>;
  storedRecovery?: "notRequired" | "required";
  finalFixture?: Record<string, unknown>;
  snapshotSource?: string;
  diagnostics?: Record<string, unknown>;
  auth?: { credentialRequests: number; credentialSettlements: number; certificateRequests: number };
  mutateAuth?: () => void;
} = {}) {
  const listeners = new Set<(state: RemoteConnectionNotification) => void>();
  const auth = config.auth ?? { credentialRequests: 0, credentialSettlements: 0, certificateRequests: 0 };
  const sendRequest = vi.fn(async (method: string, params: unknown): Promise<unknown> => {
    if (method === "status/checkRemote") {
      expect(params).toEqual({ repositoryId: REPOSITORY_ID, epoch: 7, remote: expectedRemote() });
      for (const listener of listeners) listener(checkingNotification());
      for (const listener of listeners) listener(terminalNotification(config.terminal));
      throw crashError(config.crash);
    }
    if (method === "status/getSnapshot") {
      return {
        repositoryId: REPOSITORY_ID, epoch: 7, generation: 2, completeness: "complete",
        identity: session().identity, localEntries: [], remoteEntries: [],
        summary: { localChanges: 0, remoteChanges: 0, conflicts: 0, unversioned: 0 },
        timestamp: "2026-07-20T00:00:00Z", source: config.snapshotSource ?? "libsvn-local",
      };
    }
    expect(method).toBe("diagnostics/get");
    config.mutateAuth?.();
    return config.diagnostics ?? diagnostics();
  });
  const finalFixture = config.finalFixture ?? fixtureState({
    connections: 1, greetingSent: 1, clientResponseReceived: 1,
  });
  const fixtureValues = [fixtureState(), finalFixture, finalFixture];
  const connection = {
    initializeResult: initializeResult(),
    isRemoteSubmissionEnabled: () => true,
    currentRemoteTrustEpoch: () => 7,
    sendRequest,
  } as unknown as BackendConnection;
  const options: InstalledSvnAnonymousWorkerCrashReportOptions = {
    expectedToken: TOKEN,
    request: request(),
    initialize: vi.fn().mockResolvedValue(connection),
    openWorkingCopy: vi.fn().mockResolvedValue(session()),
    closeRepository: vi.fn().mockResolvedValue(undefined),
    onDaemonRemoteStateChange: (listener) => {
      listeners.add(listener);
      return { dispose: () => listeners.delete(listener) };
    },
    getRemoteState: () => storedState(config.storedRecovery ?? "notRequired"),
    readFixtureState: vi.fn(async () => fixtureValues.shift() ?? finalFixture),
    authActivity: () => ({ ...auth }),
  };
  return { options, sendRequest };
}

function crashError(overrides: Record<string, unknown> = {}): JsonRpcStreamError {
  const safeArgs: Record<string, unknown> = {
    stage: overrides.stage ?? "workerProcess",
    remoteFailure: {
      category: "process",
      reason: overrides.failureReason ?? "workerContainmentFailed",
      cleanupAppropriate: overrides.cleanupAppropriate ?? false,
    },
  };
  if (overrides.safeArgsExtra === true) safeArgs.extra = true;
  return new JsonRpcStreamError({
    code: String(overrides.code ?? "SUBVERSIONR_REMOTE_WORKER_CRASHED"),
    category: String(overrides.category ?? "process"),
    messageKey: String(overrides.messageKey ?? "error.remote.workerCrashed"),
    args: safeArgs,
    retryable: overrides.retryable === true,
    diagnostics: "diagnostics" in overrides ? overrides.diagnostics : null,
  });
}

function request(): Record<string, unknown> {
  return { token: TOKEN, repositoryUrl: REPOSITORY_URL, workingCopyPath: WORKING_COPY_PATH, operationId: OPERATION_ID, fixtureStatePath: FIXTURE_STATE_PATH };
}

function fixtureState(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    schema: "subversionr.release.m8-i6-ra-svn-fault-fixture.v1", pid: 1234, port: 3692,
    suppliedAuthorityPort: 0, scenario: "greeting-stall", status: "ready", connections: 0,
    suppliedAuthorityConnections: 0, greetingSent: 0, clientResponseReceived: 0,
    authRequestSent: 0, reposInfoSent: 0, commandsReceived: 0, followupContacts: 0,
    ...overrides,
  };
}

function checkingNotification(): RemoteConnectionNotification {
  return { repositoryId: REPOSITORY_ID, epoch: 7, state: { kind: "checking", operationId: OPERATION_ID, startedAt: "2026-07-20T00:00:00Z" } };
}

function terminalNotification(overrides: Record<string, unknown> = {}): RemoteConnectionNotification {
  return {
    repositoryId: REPOSITORY_ID,
    epoch: 7,
    state: {
      kind: "indeterminate", reason: "workerTerminated", originOperationId: OPERATION_ID,
      recovery: "notRequired", cleanupAppropriate: false, ...overrides,
    } as RemoteConnectionNotification["state"],
  };
}

function storedState(recovery: "notRequired" | "required"): ReturnType<InstalledSvnAnonymousWorkerCrashReportOptions["getRemoteState"]> {
  return {
    repositoryId: REPOSITORY_ID, epoch: 7, kind: "indeterminate", reason: "workerTerminated",
    incoming: { kind: "stale" },
    recovery: recovery === "notRequired" ? { kind: "notRequired" } : { kind: "required", operationId: OPERATION_ID, requiredAt: "2026-07-20T00:00:00Z" },
    lastFailure: { reason: "workerContainmentFailed", cleanupAppropriate: false, occurredAt: "2026-07-20T00:00:00Z" },
  };
}

function session(): RepositorySession {
  return {
    repositoryId: REPOSITORY_ID, epoch: 7,
    identity: { repositoryUuid: "repo-uuid", repositoryRootUrl: REPOSITORY_URL, workingCopyRoot: WORKING_COPY_PATH, workspaceScopeRoot: WORKING_COPY_PATH, format: 31 },
    watchScope: { repositoryId: REPOSITORY_ID, epoch: 7, workingCopyRoot: WORKING_COPY_PATH, boundaryRoots: [], pathCase: "case-insensitive" },
  };
}

function expectedRemote(): Record<string, unknown> {
  const endpoint = { scheme: "svn", canonicalHost: "127.0.0.1", effectivePort: 3692 };
  return {
    version: 1, operationId: OPERATION_ID, intent: "foreground", interaction: "allowed", timeoutMs: 30_000,
    workspaceTrust: "trusted", trustEpoch: 7,
    profile: { schema: "subversionr.remote-profile.v1", profileId: "installed-i6-svn-anonymous-worker-crash", authority: endpoint, serverAuth: "anonymous", serverAccount: "none", serverCredentialPersistence: "secretStorage", proxy: "none", ssh: "none", redirectPolicy: "rejectAll" },
    expectedOrigin: endpoint,
  };
}

function initializeResult(): BackendConnection["initializeResult"] {
  return {
    protocol: { major: 1, minor: 35 },
    capabilities: { realLibsvnBridge: true, repositoryOpen: true, repositoryClose: true, statusSnapshot: true, statusRemoteCheck: true, remoteOperationEnvelope: true, remoteWorkerIsolation: true, remoteConnectionState: true, remoteSvnAnonymous: true, diagnosticsGet: true },
    acknowledgedTrustEpoch: 7,
  } as BackendConnection["initializeResult"];
}

function diagnostics(): Record<string, unknown> {
  return { source: "subversionr-daemon", protocol: { major: 1, minor: 35 }, capabilities: { remoteSvnAnonymous: true, statusRemoteCheck: true, statusSnapshot: true } };
}
