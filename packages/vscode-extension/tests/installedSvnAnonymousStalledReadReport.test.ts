import { describe, expect, it, vi } from "vitest";
import type { BackendConnection } from "../src/backend/backendProcess";
import {
  collectInstalledSvnAnonymousStalledReadReport,
  type InstalledSvnAnonymousStalledReadReportOptions,
} from "../src/diagnostics/installedSvnAnonymousStalledReadReport";
import type { RepositorySession } from "../src/repository/repositorySessionService";
import { JsonRpcStreamError } from "../src/transport/jsonRpcStreamClient";

const TOKEN = "installed-i6-stalled-read-token";
const REPOSITORY_URL = "svn://127.0.0.1:3692/repo/trunk";
const WORKING_COPY_PATH = "C:/evidence/i6-stalled-read-wc";
const OPERATION_ID = "40000000-0000-4000-8000-000000000001";
const REPOSITORY_ID = "repo-uuid:C:/evidence/i6-stalled-read-wc";

describe("installed SVN anonymous stalled-read report", () => {
  it("proves the exact timeout and a local snapshot on the released native lane", async () => {
    const sendRequest = vi.fn(async (method: string, params: unknown): Promise<unknown> => {
      if (method === "status/checkRemote") {
        expect(params).toEqual({
          repositoryId: REPOSITORY_ID,
          epoch: 7,
          remote: expectedRemoteEnvelope(),
        });
        throw stalledReadError();
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

    const report = await collectInstalledSvnAnonymousStalledReadReport(options);

    expect(report).toEqual({
      schema: "subversionr.release.m8-i6-installed-svn-anonymous-stalled-read.v1",
      schemaVersion: 1,
      kind: "subversionr.installedSvnAnonymousStalledReadReport",
      scenario: "stalledMidRead",
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
    await expect(collectInstalledSvnAnonymousStalledReadReport({
      ...baseOptions(),
      expectedToken: undefined,
    })).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_STALLED_READ_FORBIDDEN",
    });
    await expect(collectInstalledSvnAnonymousStalledReadReport({
      ...baseOptions(),
      request: { ...request(), token: "wrong" },
    })).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_STALLED_READ_FORBIDDEN",
    });
    await expect(collectInstalledSvnAnonymousStalledReadReport({
      ...baseOptions(),
      request: { ...request(), scenario: "stalledMidRead" },
    })).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_STALLED_READ_REQUEST_INVALID",
    });
  });

  it.each([
    ["non-loopback URL", { repositoryUrl: "svn://svn.example.test/repo/trunk" }, "ORIGIN_INVALID"],
    ["credentials in URL", { repositoryUrl: "svn://alice:secret@127.0.0.1:3692/repo/trunk" }, "ORIGIN_INVALID"],
    ["relative working copy", { workingCopyPath: "relative/wc" }, "REQUEST_INVALID"],
    ["non-canonical operation", { operationId: "NOT-A-UUID" }, "REQUEST_INVALID"],
    ["zero operation", { operationId: "00000000-0000-0000-0000-000000000000" }, "REQUEST_INVALID"],
    ["out-of-range timeout", { timeoutMs: 300_001 }, "REQUEST_INVALID"],
  ])("rejects %s", async (_label, override, suffix) => {
    await expect(collectInstalledSvnAnonymousStalledReadReport({
      ...baseOptions(),
      request: { ...request(), ...override },
    })).rejects.toMatchObject({
      code: `SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_STALLED_READ_${suffix}`,
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
        throw stalledReadError(override);
      }
      if (method === "status/getSnapshot") {
        return localSnapshot();
      }
      return currentDiagnostics();
    })));

    await expect(collectInstalledSvnAnonymousStalledReadReport(options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_STALLED_READ_SETTLEMENT_INVALID",
    });
    expect(options.closeRepository).toHaveBeenCalledWith(REPOSITORY_ID);
  });

  it("rejects a snapshot that does not prove the local native lane was released", async () => {
    const options = baseOptions();
    options.initialize = vi.fn().mockResolvedValue(connection(vi.fn(async (method: string) => {
      if (method === "status/checkRemote") {
        throw stalledReadError();
      }
      if (method === "status/getSnapshot") {
        return { ...localSnapshot(), source: "cache" };
      }
      return currentDiagnostics();
    })));

    await expect(collectInstalledSvnAnonymousStalledReadReport(options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_STALLED_READ_LOCAL_SNAPSHOT_INVALID",
    });
    expect(options.closeRepository).toHaveBeenCalledWith(REPOSITORY_ID);
  });

  it("rejects request data in follow-up diagnostics", async () => {
    const options = baseOptions();
    options.initialize = vi.fn().mockResolvedValue(connection(vi.fn(async (method: string) => {
      if (method === "status/checkRemote") {
        throw stalledReadError();
      }
      if (method === "status/getSnapshot") {
        return localSnapshot();
      }
      return { ...currentDiagnostics(), leaked: OPERATION_ID };
    })));

    await expect(collectInstalledSvnAnonymousStalledReadReport(options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_STALLED_READ_DIAGNOSTICS_LEAK",
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
        throw stalledReadError();
      }
      if (method === "status/getSnapshot") {
        return localSnapshot();
      }
      return currentDiagnostics();
    })));

    await expect(collectInstalledSvnAnonymousStalledReadReport(options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_STALLED_READ_AUTH_ACTIVITY_INVALID",
    });
    expect(options.closeRepository).toHaveBeenCalledWith(REPOSITORY_ID);
  });
});

function baseOptions(): InstalledSvnAnonymousStalledReadReportOptions {
  return {
    expectedToken: TOKEN,
    request: request(),
    initialize: vi.fn(),
    openWorkingCopy: vi.fn().mockResolvedValue(session()),
    closeRepository: vi.fn().mockResolvedValue(undefined),
    authActivity: () => ({ credentialRequests: 0, credentialSettlements: 0, certificateRequests: 0 }),
  };
}

function request(): Record<string, unknown> {
  return {
    token: TOKEN,
    repositoryUrl: REPOSITORY_URL,
    workingCopyPath: WORKING_COPY_PATH,
    operationId: OPERATION_ID,
    timeoutMs: 1_000,
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
    timeoutMs: 1_000,
    workspaceTrust: "trusted",
    trustEpoch: 7,
    profile: {
      schema: "subversionr.remote-profile.v1",
      profileId: "installed-i6-svn-anonymous-stalled-read",
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

function stalledReadError(overrides: Record<string, unknown> = {}): JsonRpcStreamError {
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
