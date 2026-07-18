import { describe, expect, it, vi } from "vitest";
import type { BackendConnection } from "../src/backend/backendProcess";
import {
  collectInstalledSvnAnonymousNegativeReport,
  type InstalledSvnAnonymousNegativeReportOptions,
} from "../src/diagnostics/installedSvnAnonymousNegativeReport";
import { JsonRpcStreamError } from "../src/transport/jsonRpcStreamClient";

const TOKEN = "installed-i6-negative-token";
const REPOSITORY_URL = "svn://127.0.0.1:3691/repo/trunk";
const CHECKOUT_PATH = "C:/evidence/i6-negative-checkout";
const OPERATION_ID = "20000000-0000-4000-8000-000000000001";

const SCENARIOS = [
  {
    scenario: "maliciousRoot" as const,
    code: "SUBVERSIONR_REMOTE_ORIGIN_MISMATCH",
    category: "policy",
    reason: "crossAuthorityRejected",
  },
  {
    scenario: "saslOnly" as const,
    code: "SUBVERSIONR_REMOTE_AUTH_UNSUPPORTED",
    category: "capability",
    reason: "remoteCapabilityUnsupported",
  },
];

describe("installed SVN anonymous negative report", () => {
  it.each(SCENARIOS)(
    "executes a real typed $scenario checkout and returns only bounded redacted failure evidence",
    async ({ scenario, code, category, reason }) => {
      const sendRequest = vi.fn(async (method: string, params: unknown): Promise<unknown> => {
        if (method === "repository/checkout") {
          expect(params).toEqual({
            url: REPOSITORY_URL,
            targetPath: CHECKOUT_PATH,
            revision: "head",
            depth: "infinity",
            ignoreExternals: true,
            remote: {
              version: 1,
              operationId: OPERATION_ID,
              intent: "foreground",
              interaction: "forbidden",
              timeoutMs: 30_000,
              workspaceTrust: "trusted",
              trustEpoch: 7,
              profile: {
                schema: "subversionr.remote-profile.v1",
                profileId: "installed-i6-svn-anonymous-negative",
                authority: { scheme: "svn", canonicalHost: "127.0.0.1", effectivePort: 3691 },
                serverAuth: "anonymous",
                serverAccount: "none",
                serverCredentialPersistence: "secretStorage",
                proxy: "none",
                ssh: "none",
                redirectPolicy: "rejectAll",
              },
              expectedOrigin: { scheme: "svn", canonicalHost: "127.0.0.1", effectivePort: 3691 },
            },
          });
          throw rpcError(code, category, reason);
        }
        expect(method).toBe("diagnostics/get");
        expect(params).toEqual({});
        return currentDiagnostics();
      });
      const report = await collectInstalledSvnAnonymousNegativeReport({
        ...baseOptions(scenario),
        initialize: vi.fn().mockResolvedValue(connection(sendRequest)),
      });

      expect(report).toEqual({
        schema: "subversionr.release.m8-i6-installed-svn-anonymous-negative.v1",
        schemaVersion: 1,
        kind: "subversionr.installedSvnAnonymousNegativeReport",
        scenario,
        originCode: code,
        originReason: reason,
        settlementCode: code,
        settlementReason: reason,
        protocol: { major: 1, minor: 35 },
        trust: { acknowledgedEpoch: 7, consistent: true },
        authActivity: { credentialRequests: 0, credentialSettlements: 0, certificateRequests: 0 },
        diagnosticsRedacted: true,
        redaction: { rawUrls: false, rawPaths: false, rawContent: false },
      });
      expect(sendRequest.mock.calls.map(([method]) => method)).toEqual([
        "repository/checkout",
        "diagnostics/get",
      ]);
      const serialized = JSON.stringify(report);
      expect(serialized).not.toContain(TOKEN);
      expect(serialized).not.toContain(REPOSITORY_URL);
      expect(serialized).not.toContain(CHECKOUT_PATH);
      expect(serialized).not.toContain(OPERATION_ID);
    },
  );

  it.each(SCENARIOS)(
    "rejects a non-exact structured $scenario settlement",
    async ({ scenario, code, category, reason }) => {
      const wrongCode = baseOptions(scenario);
      wrongCode.initialize = vi.fn().mockResolvedValue(connection(vi.fn(async (method: string) => {
        if (method === "repository/checkout") {
          throw rpcError(`${code}_WRONG`, category, reason);
        }
        return currentDiagnostics();
      })));
      await expect(collectInstalledSvnAnonymousNegativeReport(wrongCode)).rejects.toMatchObject({
        code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_NEGATIVE_SETTLEMENT_INVALID",
      });

      const wrongFailure = baseOptions(scenario);
      wrongFailure.initialize = vi.fn().mockResolvedValue(connection(vi.fn(async (method: string) => {
        if (method === "repository/checkout") {
          throw rpcError(code, category, reason, { cleanupAppropriate: true });
        }
        return currentDiagnostics();
      })));
      await expect(collectInstalledSvnAnonymousNegativeReport(wrongFailure)).rejects.toMatchObject({
        code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_NEGATIVE_SETTLEMENT_INVALID",
      });
    },
  );

  it("fails closed for a missing or mismatched independent token", async () => {
    const missing = baseOptions("maliciousRoot");
    missing.expectedToken = undefined;
    await expect(collectInstalledSvnAnonymousNegativeReport(missing)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_NEGATIVE_FORBIDDEN",
    });
    expect(missing.initialize).not.toHaveBeenCalled();

    const mismatch = baseOptions("saslOnly");
    mismatch.request = { ...request("saslOnly"), token: "wrong-token" };
    await expect(collectInstalledSvnAnonymousNegativeReport(mismatch)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_NEGATIVE_FORBIDDEN",
    });
    expect(mismatch.initialize).not.toHaveBeenCalled();
  });

  it.each([
    ["an extra key", { ...request("maliciousRoot"), extra: true }],
    ["an unknown scenario", { ...request("maliciousRoot"), scenario: "malicious-root" }],
    ["a relative path", { ...request("maliciousRoot"), checkoutPath: "relative/checkout" }],
    ["a nil operation ID", { ...request("maliciousRoot"), operationId: "00000000-0000-0000-0000-000000000000" }],
    ["a zero timeout", { ...request("maliciousRoot"), timeoutMs: 0 }],
    ["an oversized timeout", { ...request("maliciousRoot"), timeoutMs: 300_001 }],
  ])("rejects %s before backend initialization", async (_description, invalidRequest) => {
    const options = baseOptions("maliciousRoot");
    options.request = invalidRequest;
    await expect(collectInstalledSvnAnonymousNegativeReport(options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_NEGATIVE_REQUEST_INVALID",
    });
    expect(options.initialize).not.toHaveBeenCalled();
  });

  it.each([
    "https://127.0.0.1:3691/repo/trunk",
    "svn://svn.example.invalid:3691/repo/trunk",
    "svn://user@127.0.0.1:3691/repo/trunk",
    "svn://127.0.0.1:3691/",
    "svn://127.0.0.1:3691/repo/trunk?query=1",
  ])("rejects the uncontrolled origin %s before backend initialization", async (repositoryUrl) => {
    const options = baseOptions("maliciousRoot");
    options.request = { ...request("maliciousRoot"), repositoryUrl };
    await expect(collectInstalledSvnAnonymousNegativeReport(options)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_NEGATIVE_ORIGIN_INVALID",
    });
    expect(options.initialize).not.toHaveBeenCalled();
  });

  it("rejects diagnostics leaks, trust changes, and any auth activity", async () => {
    const leak = baseOptions("maliciousRoot");
    leak.initialize = vi.fn().mockResolvedValue(connection(vi.fn(async (method: string) => {
      if (method === "repository/checkout") {
        throw rpcError("SUBVERSIONR_REMOTE_ORIGIN_MISMATCH", "policy", "crossAuthorityRejected");
      }
      return { ...currentDiagnostics(), leaked: REPOSITORY_URL };
    })));
    await expect(collectInstalledSvnAnonymousNegativeReport(leak)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_NEGATIVE_DIAGNOSTICS_LEAK",
    });

    const trustChanged = baseOptions("saslOnly");
    trustChanged.initialize = vi.fn().mockResolvedValue(connection(
      vi.fn().mockRejectedValue(rpcError(
        "SUBVERSIONR_REMOTE_AUTH_UNSUPPORTED",
        "capability",
        "remoteCapabilityUnsupported",
      )),
      [7, 7, 8],
    ));
    await expect(collectInstalledSvnAnonymousNegativeReport(trustChanged)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_NEGATIVE_TRUST_EPOCH_INVALID",
    });

    let authReads = 0;
    const auth = baseOptions("saslOnly");
    auth.authActivity = () => authReads++ === 0
      ? { credentialRequests: 4, credentialSettlements: 3, certificateRequests: 2 }
      : { credentialRequests: 5, credentialSettlements: 3, certificateRequests: 2 };
    auth.initialize = vi.fn().mockResolvedValue(connection(vi.fn(async (method: string) => {
      if (method === "repository/checkout") {
        throw rpcError(
          "SUBVERSIONR_REMOTE_AUTH_UNSUPPORTED",
          "capability",
          "remoteCapabilityUnsupported",
        );
      }
      return currentDiagnostics();
    })));
    await expect(collectInstalledSvnAnonymousNegativeReport(auth)).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_NEGATIVE_AUTH_ACTIVITY_INVALID",
    });
  });
});

function baseOptions(
  scenario: "maliciousRoot" | "saslOnly",
): InstalledSvnAnonymousNegativeReportOptions {
  return {
    expectedToken: TOKEN,
    request: request(scenario),
    initialize: vi.fn(),
    authActivity: () => ({ credentialRequests: 0, credentialSettlements: 0, certificateRequests: 0 }),
  };
}

function request(scenario: "maliciousRoot" | "saslOnly"): Record<string, unknown> {
  return {
    token: TOKEN,
    scenario,
    repositoryUrl: REPOSITORY_URL,
    checkoutPath: CHECKOUT_PATH,
    operationId: OPERATION_ID,
    timeoutMs: 30_000,
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
        repositoryCheckout: true,
        remoteOperationEnvelope: true,
        remoteWorkerIsolation: true,
        remoteSvnAnonymous: true,
      },
      acknowledgedTrustEpoch: 7,
    } as BackendConnection["initializeResult"],
    isRemoteSubmissionEnabled: () => true,
    currentRemoteTrustEpoch: () => currentTrustEpochs.shift() ?? 7,
    sendRequest: sendRequest as BackendConnection["sendRequest"],
  };
}

function rpcError(
  code: string,
  category: string,
  reason: string,
  overrides: { cleanupAppropriate?: boolean } = {},
): JsonRpcStreamError {
  return new JsonRpcStreamError({
    code,
    category: "native",
    messageKey: "error.remote.test",
    args: {
      remoteFailure: {
        category,
        reason,
        cleanupAppropriate: overrides.cleanupAppropriate ?? false,
      },
    },
    retryable: false,
    diagnostics: null,
  });
}

function currentDiagnostics(): Record<string, unknown> {
  return {
    source: "subversionr-daemon",
    protocol: { major: 1, minor: 35 },
    capabilities: { remoteSvnAnonymous: true },
  };
}
