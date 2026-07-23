import { describe, expect, it, vi } from "vitest";
import type { BackendConnection } from "../src/backend/backendProcess";
import {
  collectInstalledSvnAnonymousCancellationReport,
  type InstalledSvnAnonymousCancellationReportOptions,
} from "../src/diagnostics/installedSvnAnonymousCancellationReport";
import type { RepositorySession } from "../src/repository/repositorySessionService";
import {
  JsonRpcRequestCancelledError,
  JsonRpcStreamError,
} from "../src/transport/jsonRpcStreamClient";

const TOKEN = "installed-i6-cancellation-token";
const REPOSITORY_URL = "svn://127.0.0.1:3692/repo/trunk";
const WORKING_COPY_PATH = "C:/evidence/i6-cancellation-wc";
const FIXTURE_STATE_PATH = "C:/evidence/i6-cancellation-fixture-state.json";
const OPERATION_ID = "60000000-0000-4000-8000-000000000001";
const REPOSITORY_ID = "repo-uuid:C:/evidence/i6-cancellation-wc";
const REQUEST_ID = 41;

describe("installed SVN anonymous cancellation report", () => {
  it("proves the greeting barrier, immediate local abort, wire settlement, and released local lane", async () => {
    const options = baseOptions();
    const active = cancellationConnection();
    options.initialize = vi.fn().mockResolvedValue(active.connection);

    const report = await collectInstalledSvnAnonymousCancellationReport(options);

    expect(report).toEqual({
      schema: "subversionr.release.m8-i6-installed-vsix-cancellation.v1",
      schemaVersion: 1,
      kind: "subversionr.installedSvnAnonymousCancellationReport",
      scenario: "cancellation",
      settlement: {
        code: "SUBVERSIONR_REMOTE_WORKER_CANCELLED",
        category: "cancelled",
        messageKey: "error.remote.workerCancelled",
        retryable: false,
        remoteFailure: {
          category: "cancellation",
          reason: "operationCancelled",
          cleanupAppropriate: false,
        },
      },
      cancellationSettlement: {
        trigger: "abort-signal-after-greeting",
        localCode: "JSON_RPC_REQUEST_CANCELLED",
        wireCode: "SUBVERSIONR_REMOTE_WORKER_CANCELLED",
        wireReason: "operationCancelled",
        wireSettlementObserved: true,
      },
      diagnostics: null,
      nativeLaneReleased: true,
      localSnapshotAfterCancellation: true,
      protocol: { major: 1, minor: 35 },
      trust: { acknowledgedEpoch: 7, consistent: true },
      authActivity: { credentialRequests: 0, credentialSettlements: 0, certificateRequests: 0 },
      repositorySession: { opened: true, closed: true },
      diagnosticsRedacted: true,
      redaction: { rawUrls: false, rawPaths: false, rawContent: false },
    });
    expect(active.abortObserved()).toBe(true);
    expect(active.connection.waitForCancelledRequestWireSettlement).toHaveBeenCalledWith(
      REQUEST_ID,
      5_500,
    );
    expect(options.readFixtureState).toHaveBeenCalledTimes(3);
    expect(options.closeRepository).toHaveBeenCalledWith(REPOSITORY_ID);
  });

  it("rejects non-exact requests and non-absolute fixture state paths before initialization", async () => {
    const options = baseOptions();
    options.request = { ...request(), extra: true };
    await expect(collectInstalledSvnAnonymousCancellationReport(options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CANCELLATION_REQUEST_INVALID",
    });
    expect(options.initialize).not.toHaveBeenCalled();

    options.request = { ...request(), fixtureStatePath: "relative-state.json" };
    await expect(collectInstalledSvnAnonymousCancellationReport(options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CANCELLATION_REQUEST_INVALID",
    });
  });

  it("fails fast when the initial fixture state is not fresh or uses the wrong port", async () => {
    for (const state of [fixtureState({ connections: 1 }), fixtureState({ port: 3693 })]) {
      const options = baseOptions();
      options.readFixtureState = vi.fn().mockResolvedValue(state);
      await expect(collectInstalledSvnAnonymousCancellationReport(options)).rejects.toMatchObject({
        code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CANCELLATION_FIXTURE_STATE_INVALID",
      });
      expect(options.initialize).not.toHaveBeenCalled();
    }
  });

  it("does not abort before the exact greeting-stall barrier and rejects forbidden progress", async () => {
    const options = baseOptions();
    const active = cancellationConnection();
    options.initialize = vi.fn().mockResolvedValue(active.connection);
    options.readFixtureState = vi.fn()
      .mockResolvedValueOnce(fixtureState())
      .mockResolvedValueOnce(fixtureState({ connections: 1, greetingSent: 1 }))
      .mockResolvedValueOnce(fixtureState({
        connections: 1,
        greetingSent: 1,
        clientResponseReceived: 1,
        commandsReceived: 1,
      }));

    await expect(collectInstalledSvnAnonymousCancellationReport(options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CANCELLATION_FIXTURE_STATE_INVALID",
    });
    expect(active.abortObserved()).toBe(false);
  });

  it("fails when the greeting barrier is not reached within its owned observation window", async () => {
    const options = baseOptions();
    const active = cancellationConnection();
    options.initialize = vi.fn().mockResolvedValue(active.connection);
    options.monotonicNowMs = vi.fn()
      .mockReturnValueOnce(0)
      .mockReturnValueOnce(10_001);
    options.readFixtureState = vi.fn().mockResolvedValue(fixtureState());

    await expect(collectInstalledSvnAnonymousCancellationReport(options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CANCELLATION_GREETING_NOT_OBSERVED",
    });
    expect(active.abortObserved()).toBe(false);
  });

  it("requires the ordinary promise to reject immediately with the exact local cancellation", async () => {
    const options = baseOptions();
    const active = cancellationConnection({ local: "pending" });
    options.initialize = vi.fn().mockResolvedValue(active.connection);

    await expect(collectInstalledSvnAnonymousCancellationReport(options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CANCELLATION_LOCAL_SETTLEMENT_INVALID",
    });
    expect(active.connection.waitForCancelledRequestWireSettlement).not.toHaveBeenCalled();
  });

  it("requires a distinct exact daemon wire cancellation for the same request id", async () => {
    for (const wireError of [
      undefined,
      new JsonRpcStreamError({
        code: "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT",
        category: "timeout",
        messageKey: "error.remote.workerTimedOut",
        args: { remoteFailure: { category: "deadline", reason: "operationDeadlineExceeded", cleanupAppropriate: false } },
        retryable: false,
        diagnostics: null,
      }),
      new JsonRpcStreamError({
        code: "SUBVERSIONR_REMOTE_WORKER_CANCELLED",
        category: "cancelled",
        messageKey: "error.remote.workerCancelled",
        args: { remoteFailure: { category: "cancelled", reason: "operationCancelled", cleanupAppropriate: false } },
        retryable: false,
        diagnostics: null,
      }),
    ]) {
      const options = baseOptions();
      const active = cancellationConnection({ wireError });
      options.initialize = vi.fn().mockResolvedValue(active.connection);
      await expect(collectInstalledSvnAnonymousCancellationReport(options)).rejects.toMatchObject({
        code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CANCELLATION_SETTLEMENT_INVALID",
      });
    }
  });

  it("fails closed when wire settlement observability is absent", async () => {
    const options = baseOptions();
    const active = cancellationConnection();
    delete active.connection.waitForCancelledRequestWireSettlement;
    options.initialize = vi.fn().mockResolvedValue(active.connection);

    await expect(collectInstalledSvnAnonymousCancellationReport(options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CANCELLATION_CAPABILITY_UNAVAILABLE",
    });
  });

  it("rejects an unusable post-cancellation snapshot and non-zero authentication activity", async () => {
    const invalidSnapshot = baseOptions();
    const snapshotConnection = cancellationConnection({ snapshotSource: "libsvn-remote" });
    invalidSnapshot.initialize = vi.fn().mockResolvedValue(snapshotConnection.connection);
    await expect(collectInstalledSvnAnonymousCancellationReport(invalidSnapshot)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CANCELLATION_LOCAL_SNAPSHOT_INVALID",
    });

    const auth = { credentialRequests: 0, credentialSettlements: 0, certificateRequests: 0 };
    const authOptions = baseOptions(auth);
    const authConnection = cancellationConnection({ onDiagnostics: () => { auth.credentialRequests = 1; } });
    authOptions.initialize = vi.fn().mockResolvedValue(authConnection.connection);
    await expect(collectInstalledSvnAnonymousCancellationReport(authOptions)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_CANCELLATION_AUTH_ACTIVITY_INVALID",
    });
  });
});

function baseOptions(
  auth = { credentialRequests: 0, credentialSettlements: 0, certificateRequests: 0 },
): InstalledSvnAnonymousCancellationReportOptions {
  const states = [
    fixtureState(),
    fixtureState({ connections: 1, greetingSent: 1, clientResponseReceived: 1 }),
    fixtureState({ connections: 1, greetingSent: 1, clientResponseReceived: 1 }),
  ];
  return {
    expectedToken: TOKEN,
    request: request(),
    initialize: vi.fn().mockResolvedValue(cancellationConnection().connection),
    openWorkingCopy: vi.fn().mockResolvedValue(session()),
    closeRepository: vi.fn().mockResolvedValue(undefined),
    authActivity: vi.fn(() => ({ ...auth })),
    monotonicNowMs: vi.fn(() => 100),
    readFixtureState: vi.fn(async () => states.shift() ?? fixtureState({
      connections: 1,
      greetingSent: 1,
      clientResponseReceived: 1,
    })),
  };
}

function request(): Record<string, unknown> {
  return {
    token: TOKEN,
    repositoryUrl: REPOSITORY_URL,
    workingCopyPath: WORKING_COPY_PATH,
    operationId: OPERATION_ID,
    fixtureStatePath: FIXTURE_STATE_PATH,
  };
}

function cancellationConnection(options: {
  local?: "cancelled" | "pending";
  wireError?: unknown;
  snapshotSource?: string;
  onDiagnostics?: () => void;
} = {}): { connection: BackendConnection; abortObserved(): boolean } {
  let aborted = false;
  const sendRequest = vi.fn((method: string, params: unknown, requestOptions?: {
    signal?: AbortSignal;
    retainCancelledWireSettlementForEvidence?: true;
  }) => {
    if (method === "status/checkRemote") {
      expect(params).toEqual({
        repositoryId: REPOSITORY_ID,
        epoch: 7,
        remote: expectedRemoteEnvelope(),
      });
      expect(requestOptions?.retainCancelledWireSettlementForEvidence).toBe(true);
      return new Promise<unknown>((_resolve, reject) => {
        requestOptions?.signal?.addEventListener("abort", () => {
          aborted = true;
          if (options.local !== "pending") {
            reject(new JsonRpcRequestCancelledError(REQUEST_ID));
          }
        }, { once: true });
      });
    }
    if (method === "status/getSnapshot") {
      return Promise.resolve({
        repositoryId: REPOSITORY_ID,
        epoch: 7,
        generation: 1,
        completeness: "complete",
        identity: session().identity,
        localEntries: [],
        remoteEntries: [],
        summary: { localChanges: 0, remoteChanges: 0, conflicts: 0, unversioned: 0 },
        timestamp: "2026-07-19T00:00:00Z",
        source: options.snapshotSource ?? "libsvn-local",
      });
    }
    expect(method).toBe("diagnostics/get");
    expect(params).toEqual({});
    options.onDiagnostics?.();
    return Promise.resolve(currentDiagnostics());
  });
  const wireError = "wireError" in options ? options.wireError : cancellationWireError();
  const waitForCancelledRequestWireSettlement = vi.fn(
    async (): Promise<unknown> => wireError === undefined ? undefined : Promise.reject(wireError),
  );
  return {
    connection: {
      initializeResult: initializeResult(),
      sendRequest,
      isRemoteSubmissionEnabled: () => true,
      currentRemoteTrustEpoch: () => 7,
      waitForCancelledRequestWireSettlement,
    } as unknown as BackendConnection,
    abortObserved: () => aborted,
  };
}

function cancellationWireError(): JsonRpcStreamError {
  return new JsonRpcStreamError({
    code: "SUBVERSIONR_REMOTE_WORKER_CANCELLED",
    category: "cancelled",
    messageKey: "error.remote.workerCancelled",
    args: {
      remoteFailure: {
        category: "cancellation",
        reason: "operationCancelled",
        cleanupAppropriate: false,
      },
    },
    retryable: false,
    diagnostics: null,
  });
}

function fixtureState(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    schema: "subversionr.release.m8-i6-ra-svn-fault-fixture.v1",
    pid: 1234,
    port: 3692,
    suppliedAuthorityPort: 0,
    scenario: "greeting-stall",
    status: "ready",
    connections: 0,
    suppliedAuthorityConnections: 0,
    greetingSent: 0,
    clientResponseReceived: 0,
    authRequestSent: 0,
    reposInfoSent: 0,
    commandsReceived: 0,
    followupContacts: 0,
    ...overrides,
  };
}

function session(): RepositorySession {
  return {
    repositoryId: REPOSITORY_ID,
    epoch: 7,
    identity: {
      repositoryUuid: "repo-uuid",
      repositoryRootUrl: REPOSITORY_URL,
      workingCopyRoot: WORKING_COPY_PATH,
      workspaceScopeRoot: WORKING_COPY_PATH,
      format: 31,
    },
    watchScope: {
      repositoryId: REPOSITORY_ID,
      epoch: 7,
      workingCopyRoot: WORKING_COPY_PATH,
      boundaryRoots: [],
      pathCase: "case-insensitive",
    },
  };
}

function expectedRemoteEnvelope(): Record<string, unknown> {
  return {
    version: 1,
    operationId: OPERATION_ID,
    intent: "foreground",
    interaction: "allowed",
    timeoutMs: 30_000,
    workspaceTrust: "trusted",
    trustEpoch: 7,
    profile: {
      schema: "subversionr.remote-profile.v1",
      profileId: "installed-i6-svn-anonymous-cancellation",
      authority: { scheme: "svn", canonicalHost: "127.0.0.1", effectivePort: 3692 },
      serverAuth: "anonymous",
      serverAccount: "none",
      serverCredentialPersistence: "secretStorage",
      proxy: "none",
      ssh: "none",
      redirectPolicy: "rejectAll",
    },
    expectedOrigin: { scheme: "svn", canonicalHost: "127.0.0.1", effectivePort: 3692 },
  };
}

function initializeResult(): BackendConnection["initializeResult"] {
  return {
    protocol: { major: 1, minor: 35 },
    capabilities: {
      realLibsvnBridge: true,
      repositoryOpen: true,
      repositoryClose: true,
      statusSnapshot: true,
      statusRemoteCheck: true,
      remoteOperationEnvelope: true,
      remoteWorkerIsolation: true,
      remoteConnectionState: true,
      remoteSvnAnonymous: true,
      diagnosticsGet: true,
    },
    acknowledgedTrustEpoch: 7,
  } as BackendConnection["initializeResult"];
}

function currentDiagnostics(): Record<string, unknown> {
  return {
    source: "subversionr-daemon",
    protocol: { major: 1, minor: 35 },
    capabilities: { remoteSvnAnonymous: true, statusRemoteCheck: true, statusSnapshot: true },
  };
}
