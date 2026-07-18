import { describe, expect, it, vi } from "vitest";
import type { BackendConnection } from "../src/backend/backendProcess";
import {
  collectInstalledSvnAnonymousAuthzDeniedReport,
  type InstalledSvnAnonymousAuthzDeniedReportOptions,
} from "../src/diagnostics/installedSvnAnonymousAuthzDeniedReport";
import type { RepositorySession } from "../src/repository/repositorySessionService";
import { JsonRpcStreamError } from "../src/transport/jsonRpcStreamClient";

const TOKEN = "installed-i6-authz-denied-token";
const REPOSITORY_URL = "svn://127.0.0.1:3691/repo/denied";
const WORKING_COPY_PATH = "C:/evidence/i6-authz-denied-wc";
const OPERATION_ID = "30000000-0000-4000-8000-000000000001";
const REPOSITORY_ID = "repo-uuid:C:/evidence/i6-authz-denied-wc";

describe("installed SVN anonymous authz denied report", () => {
  it("uses the installed repository session and exact remote status path, then returns bounded evidence", async () => {
    const sendRequest = vi.fn(async (method: string, params: unknown): Promise<unknown> => {
      if (method === "status/checkRemote") {
        expect(params).toEqual({
          repositoryId: REPOSITORY_ID,
          epoch: 7,
          remote: expectedRemoteEnvelope(),
        });
        throw authzDeniedError();
      }
      expect(method).toBe("diagnostics/get");
      expect(params).toEqual({});
      return currentDiagnostics();
    });
    const options = baseOptions();
    options.initialize = vi.fn().mockResolvedValue(connection(sendRequest));

    const report = await collectInstalledSvnAnonymousAuthzDeniedReport(options);

    expect(report).toEqual({
      schema: "subversionr.release.m8-i6-installed-svn-anonymous-authz-denied.v1",
      schemaVersion: 1,
      kind: "subversionr.installedSvnAnonymousAuthzDeniedReport",
      settlement: {
        code: "SVN_REMOTE_STATUS_AUTH_FAILED",
        category: "auth",
        messageKey: "error.native.remoteStatusAuthFailed",
        retryable: false,
        remoteFailure: {
          category: "authorization",
          reason: "authorizationDenied",
          cleanupAppropriate: false,
        },
      },
      diagnostics: {
        cause: "authorizationDenied",
        svnErrorNames: ["SVN_ERR_AUTHZ_UNREADABLE"],
        truncated: false,
      },
      protocol: { major: 1, minor: 35 },
      trust: { acknowledgedEpoch: 7, consistent: true },
      authActivity: { credentialRequests: 0, credentialSettlements: 0, certificateRequests: 0 },
      repositorySession: { opened: true, closed: true },
      diagnosticsRedacted: true,
      redaction: { rawUrls: false, rawPaths: false, rawContent: false },
    });
    expect(options.openWorkingCopy).toHaveBeenCalledOnce();
    expect(options.openWorkingCopy).toHaveBeenCalledWith(WORKING_COPY_PATH);
    expect(options.closeRepository).toHaveBeenCalledOnce();
    expect(options.closeRepository).toHaveBeenCalledWith(REPOSITORY_ID);
    expect(sendRequest.mock.calls.map(([method]) => method)).toEqual([
      "status/checkRemote",
      "diagnostics/get",
    ]);
    const serialized = JSON.stringify(report);
    expect(serialized).not.toContain(TOKEN);
    expect(serialized).not.toContain(REPOSITORY_URL);
    expect(serialized).not.toContain(WORKING_COPY_PATH);
    expect(serialized).not.toContain(OPERATION_ID);
  });

  it("requires the independent one-time token and exact request keys", async () => {
    await expect(collectInstalledSvnAnonymousAuthzDeniedReport({
      ...baseOptions(),
      expectedToken: undefined,
    })).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_AUTHZ_DENIED_FORBIDDEN",
    });
    await expect(collectInstalledSvnAnonymousAuthzDeniedReport({
      ...baseOptions(),
      request: { ...request(), token: "wrong" },
    })).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_AUTHZ_DENIED_FORBIDDEN",
    });
    await expect(collectInstalledSvnAnonymousAuthzDeniedReport({
      ...baseOptions(),
      request: { ...request(), scenario: "authzDenied" },
    })).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_AUTHZ_DENIED_REQUEST_INVALID",
    });
  });

  it.each([
    ["non-loopback URL", { repositoryUrl: "svn://svn.example.test/repo/denied" }, "ORIGIN_INVALID"],
    ["credentials in URL", { repositoryUrl: "svn://alice:secret@127.0.0.1:3691/repo/denied" }, "ORIGIN_INVALID"],
    ["relative working copy", { workingCopyPath: "relative/wc" }, "REQUEST_INVALID"],
    ["non-canonical operation", { operationId: "NOT-A-UUID" }, "REQUEST_INVALID"],
    ["out-of-range timeout", { timeoutMs: 300_001 }, "REQUEST_INVALID"],
  ])("rejects %s", async (_label, override, suffix) => {
    await expect(collectInstalledSvnAnonymousAuthzDeniedReport({
      ...baseOptions(),
      request: { ...request(), ...override },
    })).rejects.toMatchObject({
      code: `SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_AUTHZ_DENIED_${suffix}`,
    });
  });

  it.each([
    ["wrong code", { code: "SVN_REMOTE_STATUS_FAILED" }],
    ["wrong top-level category", { category: "native" }],
    ["wrong message key", { messageKey: "error.native.remoteStatusFailed" }],
    ["retryable", { retryable: true }],
    ["wrong failure category", { failureCategory: "policy" }],
    ["wrong failure reason", { failureReason: "authenticationRequired" }],
    ["cleanup allowed", { cleanupAppropriate: true }],
    ["wrong diagnostics cause", { cause: "authenticationFailed" }],
    ["wrong working-copy path", { safePath: "C:\\fixture\\other" }],
    ["wrong native status", { status: 2 }],
  ])("rejects a settlement with %s", async (_label, override) => {
    const options = baseOptions();
    options.initialize = vi.fn().mockResolvedValue(connection(vi.fn(async (method: string) => {
      if (method === "status/checkRemote") {
        throw authzDeniedError(override);
      }
      return currentDiagnostics();
    })));

    await expect(collectInstalledSvnAnonymousAuthzDeniedReport(options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_AUTHZ_DENIED_SETTLEMENT_INVALID",
    });
    expect(options.closeRepository).toHaveBeenCalledWith(REPOSITORY_ID);
  });

  it("accepts the owned raw path/status error contract but rejects request data in follow-up diagnostics", async () => {
    const diagnosticsLeak = baseOptions();
    diagnosticsLeak.initialize = vi.fn().mockResolvedValue(connection(vi.fn(async (method: string) => {
      if (method === "status/checkRemote") {
        throw authzDeniedError();
      }
      return { ...currentDiagnostics(), leaked: REPOSITORY_URL };
    })));
    await expect(collectInstalledSvnAnonymousAuthzDeniedReport(diagnosticsLeak)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_AUTHZ_DENIED_DIAGNOSTICS_LEAK",
    });
  });

  it("rejects trust drift and still closes the opened repository session", async () => {
    const options = baseOptions();
    options.initialize = vi.fn().mockResolvedValue(connection(
      vi.fn(async (method: string) => {
        if (method === "status/checkRemote") {
          throw authzDeniedError();
        }
        return currentDiagnostics();
      }),
      [7, 7, 8],
    ));

    await expect(collectInstalledSvnAnonymousAuthzDeniedReport(options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_AUTHZ_DENIED_TRUST_EPOCH_INVALID",
    });
    expect(options.closeRepository).toHaveBeenCalledWith(REPOSITORY_ID);
  });

  it("rejects any installed auth UI activity measured across open, status, diagnostics, and close", async () => {
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
        throw authzDeniedError();
      }
      return currentDiagnostics();
    })));

    await expect(collectInstalledSvnAnonymousAuthzDeniedReport(options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_AUTHZ_DENIED_AUTH_ACTIVITY_INVALID",
    });
    expect(options.closeRepository).toHaveBeenCalledWith(REPOSITORY_ID);
  });
});

function baseOptions(): InstalledSvnAnonymousAuthzDeniedReportOptions {
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
    timeoutMs: 30_000,
  };
}

function session(): RepositorySession {
  return {
    repositoryId: REPOSITORY_ID,
    epoch: 7,
    identity: {
      repositoryUuid: "00000000-0000-4000-8000-000000000077",
      repositoryRootUrl: "svn://127.0.0.1:3691/repo",
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
  const authority = { scheme: "svn", canonicalHost: "127.0.0.1", effectivePort: 3691 };
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
      profileId: "installed-i6-svn-anonymous-authz-denied",
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

function authzDeniedError(overrides: Record<string, unknown> = {}): JsonRpcStreamError {
  return new JsonRpcStreamError({
    code: overrides.code ?? "SVN_REMOTE_STATUS_AUTH_FAILED",
    category: overrides.category ?? "auth",
    messageKey: overrides.messageKey ?? "error.native.remoteStatusAuthFailed",
    args: {
      path: overrides.safePath ?? WORKING_COPY_PATH,
      status: overrides.status ?? 12,
      remoteFailure: {
        category: overrides.failureCategory ?? "authorization",
        reason: overrides.failureReason ?? "authorizationDenied",
        cleanupAppropriate: overrides.cleanupAppropriate ?? false,
      },
    },
    retryable: overrides.retryable ?? false,
    diagnostics: {
      cause: overrides.cause ?? "authorizationDenied",
      svn: {
        entries: [{ code: 170001, name: "SVN_ERR_AUTHZ_UNREADABLE" }],
        truncated: false,
      },
    },
  });
}

function currentDiagnostics(): Record<string, unknown> {
  return {
    source: "subversionr-daemon",
    protocol: { major: 1, minor: 35 },
    capabilities: { remoteSvnAnonymous: true, statusRemoteCheck: true },
  };
}
