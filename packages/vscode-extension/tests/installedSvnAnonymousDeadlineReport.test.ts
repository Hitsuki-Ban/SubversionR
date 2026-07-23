import { describe, expect, it, vi } from "vitest";
import type { BackendConnection } from "../src/backend/backendProcess";
import {
  collectInstalledSvnAnonymousDeadlineReport,
  type InstalledSvnAnonymousDeadlineReportOptions,
} from "../src/diagnostics/installedSvnAnonymousDeadlineReport";
import type { RepositorySession } from "../src/repository/repositorySessionService";
import { JsonRpcStreamError } from "../src/transport/jsonRpcStreamClient";

const TOKEN = "installed-i6-deadline-token";
const REPOSITORY_URL = "svn://127.0.0.1:3692/repo/trunk";
const WORKING_COPY_PATH = "C:/evidence/i6-deadline-wc";
const OPERATION_ID = "40000000-0000-4000-8000-000000000001";
const REPOSITORY_ID = "repo-uuid:C:/evidence/i6-deadline-wc";

describe("installed SVN anonymous deadline report", () => {
  it("proves bounded absolute-deadline timing and a local snapshot on the released native lane", async () => {
    const sendRequest = vi.fn(async (method: string, params: unknown): Promise<unknown> => {
      if (method === "status/checkRemote") {
        expect(params).toEqual({
          repositoryId: REPOSITORY_ID,
          epoch: 7,
          remote: expectedRemoteEnvelope(),
        });
        throw deadlineError();
      }
      if (method === "status/getSnapshot") {
        expect(params).toEqual({ repositoryId: REPOSITORY_ID, epoch: 7 });
        return localSnapshot();
      }
      expect(method).toBe("diagnostics/get");
      expect(params).toEqual({});
      return currentDiagnostics();
    });
    const options = baseOptions();
    options.initialize = vi.fn().mockResolvedValue(connection(sendRequest));

    const report = await collectInstalledSvnAnonymousDeadlineReport(options);

    expect(report).toEqual({
      schema: "subversionr.release.m8-i6-installed-vsix-deadline.v1",
      schemaVersion: 1,
      kind: "subversionr.installedSvnAnonymousDeadlineReport",
      scenario: "deadline",
      settlement: {
        code: "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT",
        category: "timeout",
        messageKey: "error.remote.workerTimedOut",
        retryable: false,
        remoteFailure: {
          category: "deadline",
          reason: "operationDeadlineExceeded",
          cleanupAppropriate: false,
        },
      },
      timing: {
        clock: "monotonic",
        timeoutMs: 500,
        elapsedMs: 1_250,
        cleanupSlackMs: 5_000,
      },
      diagnostics: null,
      nativeLaneReleased: true,
      localSnapshotAfterTimeout: true,
      protocol: { major: 1, minor: 35 },
      trust: { acknowledgedEpoch: 7, consistent: true },
      authActivity: { credentialRequests: 0, credentialSettlements: 0, certificateRequests: 0 },
      repositorySession: { opened: true, closed: true },
      diagnosticsRedacted: true,
      redaction: { rawUrls: false, rawPaths: false, rawContent: false },
    });
    expect(options.openWorkingCopy).toHaveBeenCalledWith(WORKING_COPY_PATH);
    expect(options.closeRepository).toHaveBeenCalledWith(REPOSITORY_ID);
    expect(sendRequest.mock.calls.map(([method]) => method)).toEqual([
      "status/checkRemote",
      "status/getSnapshot",
      "diagnostics/get",
    ]);
    const serialized = JSON.stringify(report);
    expect(serialized).not.toContain(TOKEN);
    expect(serialized).not.toContain(REPOSITORY_URL);
    expect(serialized).not.toContain(WORKING_COPY_PATH);
    expect(serialized).not.toContain(OPERATION_ID);
  });

  it("requires its independent token and exact request keys", async () => {
    await expect(collectInstalledSvnAnonymousDeadlineReport({
      ...baseOptions(),
      expectedToken: undefined,
    })).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DEADLINE_FORBIDDEN",
    });
    await expect(collectInstalledSvnAnonymousDeadlineReport({
      ...baseOptions(),
      request: { ...request(), token: "wrong" },
    })).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DEADLINE_FORBIDDEN",
    });
    await expect(collectInstalledSvnAnonymousDeadlineReport({
      ...baseOptions(),
      request: { ...request(), scenario: "deadline" },
    })).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DEADLINE_REQUEST_INVALID",
    });
  });

  it.each([
    ["non-loopback URL", { repositoryUrl: "svn://svn.example.test/repo/trunk" }, "ORIGIN_INVALID"],
    ["credentials in URL", { repositoryUrl: "svn://alice:secret@127.0.0.1:3692/repo/trunk" }, "ORIGIN_INVALID"],
    ["relative working copy", { workingCopyPath: "relative/wc" }, "REQUEST_INVALID"],
    ["non-canonical operation", { operationId: "NOT-A-UUID" }, "REQUEST_INVALID"],
    ["zero operation", { operationId: "00000000-0000-0000-0000-000000000000" }, "REQUEST_INVALID"],
    ["timeout below the exact contract", { timeoutMs: 499 }, "REQUEST_INVALID"],
    ["timeout above the exact contract", { timeoutMs: 501 }, "REQUEST_INVALID"],
  ])("rejects %s", async (_label, override, suffix) => {
    await expect(collectInstalledSvnAnonymousDeadlineReport({
      ...baseOptions(),
      request: { ...request(), ...override },
    })).rejects.toMatchObject({
      code: `SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DEADLINE_${suffix}`,
    });
  });

  it.each([
    ["wrong code", { code: "SUBVERSIONR_REMOTE_WORKER_CANCELLED" }],
    ["wrong top-level category", { category: "remote" }],
    ["wrong message key", { messageKey: "error.remote.workerCancelled" }],
    ["retryable", { retryable: true }],
    ["extra safe argument", { extraSafeArg: true }],
    ["wrong failure category", { failureCategory: "network" }],
    ["wrong failure reason", { failureReason: "networkTimeout" }],
    ["cleanup allowed", { cleanupAppropriate: true }],
    ["non-null diagnostics", { diagnostics: { cause: "timeout" } }],
  ])("rejects a settlement with %s", async (_label, override) => {
    const options = baseOptions();
    options.initialize = vi.fn().mockResolvedValue(connection(vi.fn(async (method: string) => {
      if (method === "status/checkRemote") {
        throw deadlineError(override);
      }
      if (method === "status/getSnapshot") {
        return localSnapshot();
      }
      return currentDiagnostics();
    })));

    await expect(collectInstalledSvnAnonymousDeadlineReport(options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DEADLINE_SETTLEMENT_INVALID",
    });
    expect(options.closeRepository).toHaveBeenCalledWith(REPOSITORY_ID);
  });

  it.each([
    ["before the absolute deadline", 10_499],
    ["after the reviewed cleanup slack", 15_501],
    ["with a regressed monotonic clock", 9_999],
    ["with a non-finite clock reading", Number.NaN],
  ])("rejects timeout settlement %s", async (_label, completedAtMs) => {
    const options = baseOptions();
    options.monotonicNowMs = vi.fn()
      .mockReturnValueOnce(10_000)
      .mockReturnValueOnce(completedAtMs);
    options.initialize = vi.fn().mockResolvedValue(connection(vi.fn(async (method: string) => {
      if (method === "status/checkRemote") {
        throw deadlineError();
      }
      if (method === "status/getSnapshot") {
        return localSnapshot();
      }
      return currentDiagnostics();
    })));

    await expect(collectInstalledSvnAnonymousDeadlineReport(options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DEADLINE_TIMING_INVALID",
    });
    expect(options.closeRepository).toHaveBeenCalledWith(REPOSITORY_ID);
  });

  it("rejects an invalid initial monotonic clock reading before remote submission", async () => {
    const sendRequest = vi.fn();
    const options = baseOptions();
    options.monotonicNowMs = vi.fn().mockReturnValue(-1);
    options.initialize = vi.fn().mockResolvedValue(connection(sendRequest));

    await expect(collectInstalledSvnAnonymousDeadlineReport(options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DEADLINE_TIMING_INVALID",
    });
    expect(sendRequest).not.toHaveBeenCalled();
    expect(options.closeRepository).toHaveBeenCalledWith(REPOSITORY_ID);
  });

  it("rejects a snapshot that does not prove the local native lane was released", async () => {
    const options = baseOptions();
    options.initialize = vi.fn().mockResolvedValue(connection(vi.fn(async (method: string) => {
      if (method === "status/checkRemote") {
        throw deadlineError();
      }
      if (method === "status/getSnapshot") {
        return { ...localSnapshot(), source: "cache" };
      }
      return currentDiagnostics();
    })));

    await expect(collectInstalledSvnAnonymousDeadlineReport(options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DEADLINE_LOCAL_SNAPSHOT_INVALID",
    });
    expect(options.closeRepository).toHaveBeenCalledWith(REPOSITORY_ID);
  });

  it("rejects request data in follow-up diagnostics", async () => {
    const options = baseOptions();
    options.initialize = vi.fn().mockResolvedValue(connection(vi.fn(async (method: string) => {
      if (method === "status/checkRemote") {
        throw deadlineError();
      }
      if (method === "status/getSnapshot") {
        return localSnapshot();
      }
      return { ...currentDiagnostics(), leaked: OPERATION_ID };
    })));

    await expect(collectInstalledSvnAnonymousDeadlineReport(options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DEADLINE_DIAGNOSTICS_LEAK",
    });
    expect(options.closeRepository).toHaveBeenCalledWith(REPOSITORY_ID);
  });

  it("rejects auth UI activity measured across open, timeout, local snapshot, diagnostics, and close", async () => {
    let reads = 0;
    const options = baseOptions();
    options.authActivity = () => {
      reads += 1;
      return {
        credentialRequests: reads === 1 ? 0 : 1,
        credentialSettlements: 0,
        certificateRequests: 0,
      };
    };
    options.initialize = vi.fn().mockResolvedValue(connection(vi.fn(async (method: string) => {
      if (method === "status/checkRemote") {
        throw deadlineError();
      }
      if (method === "status/getSnapshot") {
        return localSnapshot();
      }
      return currentDiagnostics();
    })));

    await expect(collectInstalledSvnAnonymousDeadlineReport(options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_DEADLINE_AUTH_ACTIVITY_INVALID",
    });
    expect(options.closeRepository).toHaveBeenCalledWith(REPOSITORY_ID);
  });
});

function baseOptions(): InstalledSvnAnonymousDeadlineReportOptions {
  return {
    expectedToken: TOKEN,
    request: request(),
    initialize: vi.fn(),
    openWorkingCopy: vi.fn().mockResolvedValue(session()),
    closeRepository: vi.fn().mockResolvedValue(undefined),
    authActivity: () => ({ credentialRequests: 0, credentialSettlements: 0, certificateRequests: 0 }),
    monotonicNowMs: vi.fn()
      .mockReturnValueOnce(10_000)
      .mockReturnValueOnce(11_250),
  };
}

function request(): Record<string, unknown> {
  return {
    token: TOKEN,
    repositoryUrl: REPOSITORY_URL,
    workingCopyPath: WORKING_COPY_PATH,
    operationId: OPERATION_ID,
    timeoutMs: 500,
  };
}

function session(): RepositorySession {
  return {
    repositoryId: REPOSITORY_ID,
    epoch: 7,
    identity: {
      repositoryUuid: "00000000-0000-4000-8000-000000000077",
      repositoryRootUrl: "svn://127.0.0.1:3692/repo",
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

function connection(
  sendRequest: (method: string, params: unknown) => Promise<unknown>,
  currentTrustEpochs: number[] = [],
): Pick<
  BackendConnection,
  "initializeResult" | "isRemoteSubmissionEnabled" | "currentRemoteTrustEpoch" | "sendRequest"
> {
  return {
    initializeResult: {
      protocol: { major: 1, minor: 35 },
      capabilities: {
        realLibsvnBridge: true,
        repositoryOpen: true,
        statusSnapshot: true,
        statusRemoteCheck: true,
        remoteOperationEnvelope: true,
        remoteWorkerIsolation: true,
        remoteConnectionState: true,
        remoteSvnAnonymous: true,
      },
      acknowledgedTrustEpoch: 7,
    } as BackendConnection["initializeResult"],
    isRemoteSubmissionEnabled: () => true,
    currentRemoteTrustEpoch: () => currentTrustEpochs.shift() ?? 7,
    sendRequest: sendRequest as BackendConnection["sendRequest"],
  };
}

function expectedRemoteEnvelope(): Record<string, unknown> {
  const authority = { scheme: "svn", canonicalHost: "127.0.0.1", effectivePort: 3692 };
  return {
    version: 1,
    operationId: OPERATION_ID,
    intent: "foreground",
    interaction: "allowed",
    timeoutMs: 500,
    workspaceTrust: "trusted",
    trustEpoch: 7,
    profile: {
      schema: "subversionr.remote-profile.v1",
      profileId: "installed-i6-svn-anonymous-deadline",
      authority,
      serverAuth: "anonymous",
      serverAccount: "none",
      serverCredentialPersistence: "secretStorage",
      proxy: "none",
      ssh: "none",
      redirectPolicy: "rejectAll",
    },
    expectedOrigin: authority,
  };
}

function deadlineError(overrides: Record<string, unknown> = {}): JsonRpcStreamError {
  return new JsonRpcStreamError({
    code: overrides.code ?? "SUBVERSIONR_REMOTE_WORKER_TIMED_OUT",
    category: overrides.category ?? "timeout",
    messageKey: overrides.messageKey ?? "error.remote.workerTimedOut",
    args: {
      remoteFailure: {
        category: overrides.failureCategory ?? "deadline",
        reason: overrides.failureReason ?? "operationDeadlineExceeded",
        cleanupAppropriate: overrides.cleanupAppropriate ?? false,
      },
      ...(overrides.extraSafeArg === true ? { unexpected: "value" } : {}),
    },
    retryable: overrides.retryable ?? false,
    diagnostics: Object.hasOwn(overrides, "diagnostics") ? overrides.diagnostics : null,
  });
}

function localSnapshot(): Record<string, unknown> {
  return {
    repositoryId: REPOSITORY_ID,
    epoch: 7,
    generation: 9,
    completeness: "complete",
    identity: session().identity,
    localEntries: [],
    remoteEntries: [],
    summary: { localChanges: 0, remoteChanges: 0, conflicts: 0, unversioned: 0 },
    timestamp: "2026-07-19T00:00:00.000Z",
    source: "libsvn-local",
  };
}

function currentDiagnostics(): Record<string, unknown> {
  return {
    source: "subversionr-daemon",
    protocol: { major: 1, minor: 35 },
    capabilities: { remoteSvnAnonymous: true, statusRemoteCheck: true, statusSnapshot: true },
  };
}
