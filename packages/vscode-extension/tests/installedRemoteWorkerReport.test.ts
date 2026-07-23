import { describe, expect, it, vi } from "vitest";
import type { BackendConnection } from "../src/backend/backendProcess";
import { collectInstalledRemoteWorkerReport } from "../src/diagnostics/installedRemoteWorkerReport";
import { JsonRpcStreamError } from "../src/transport/jsonRpcStreamClient";

const OPERATION_ID = "01234567-89ab-4def-8123-456789abcdef";
const SUBSEQUENT_OPERATION_ID = "11234567-89ab-4def-8123-456789abcdef";

describe("installed remote worker report", () => {
  it("fails closed without the one-shot harness token", async () => {
    await expect(
      collectInstalledRemoteWorkerReport({
        expectedToken: undefined,
        request: { token: "token-1" },
        targetPath: "C:/evidence/checkout",
        initialize: vi.fn(),
        collectCredentialLeaseReport: vi.fn(),
      }),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_REMOTE_WORKER_REPORT_FORBIDDEN",
    });
  });

  it("fails closed when the runtime capability is absent", async () => {
    await expect(
      collectInstalledRemoteWorkerReport({
        expectedToken: "token-1",
        request: { token: "token-1" },
        targetPath: "C:/evidence/checkout",
        initialize: vi.fn().mockResolvedValue(connection({ capability: false })),
        collectCredentialLeaseReport: vi.fn(),
      }),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_REMOTE_WORKER_CAPABILITY_UNAVAILABLE",
    });
  });

  it("fails closed when credential lease settlement is absent", async () => {
    await expect(
      collectInstalledRemoteWorkerReport({
        expectedToken: "token-1",
        request: { token: "token-1" },
        targetPath: "C:/evidence/checkout",
        initialize: vi.fn().mockResolvedValue(connection({ credentialLeaseSettlement: false })),
        collectCredentialLeaseReport: vi.fn(),
      }),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_REMOTE_WORKER_CAPABILITY_UNAVAILABLE",
    });
  });

  it("fails closed when remote connection state capability is explicitly unavailable", async () => {
    await expect(
      collectInstalledRemoteWorkerReport({
        expectedToken: "token-1",
        request: { token: "token-1" },
        targetPath: "C:/evidence/checkout",
        initialize: vi.fn().mockResolvedValue(connection({ remoteConnectionState: false })),
        collectCredentialLeaseReport: vi.fn(),
      }),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_REMOTE_WORKER_CAPABILITY_UNAVAILABLE",
    });
  });

  it("proves worker completion, transport boundary, and a subsequent diagnostics request", async () => {
    const sendRequest = vi.fn(async (method: string, params: unknown): Promise<unknown> => {
      if (method === "repository/checkout") {
        expect([OPERATION_ID, SUBSEQUENT_OPERATION_ID]).toContain(
          (params as { remote: { operationId: string } }).remote.operationId,
        );
        expect(params).toMatchObject({
          url: "https://svn.example.invalid/project/trunk",
          targetPath: "C:/evidence/checkout",
          remote: {
            trustEpoch: 1,
            profile: {
              serverAuth: "anonymous",
              serverAccount: "none",
              proxy: "none",
              ssh: "none",
            },
          },
        });
        throw rpcError("SUBVERSIONR_REMOTE_TRANSPORT_UNSUPPORTED");
      }
      expect(method).toBe("diagnostics/get");
      expect(params).toEqual({});
      return {
        protocol: { major: 1, minor: 35 },
        capabilities: { remoteWorkerIsolation: true, credentialLeaseSettlement: true, remoteConnectionState: true },
      };
    });

    const report = await collectInstalledRemoteWorkerReport({
      expectedToken: "token-1",
      request: { token: "token-1" },
      targetPath: "C:/evidence/checkout",
      initialize: vi.fn().mockResolvedValue(connection({ sendRequest })),
      collectCredentialLeaseReport: vi.fn().mockResolvedValue(credentialLeaseReport()),
      createOperationId: vi
        .fn()
        .mockReturnValueOnce(OPERATION_ID)
        .mockReturnValueOnce(SUBSEQUENT_OPERATION_ID),
    });

    expect(report).toEqual({
      schemaVersion: 3,
      kind: "subversionr.installedRemoteWorkerReport",
      protocol: { major: 1, minor: 35 },
      remoteWorkerIsolation: true,
      credentialLeaseSettlement: true,
      remoteConnectionState: {
        stateUnion: ["unchecked", "checking", "online", "attention", "unreachable", "indeterminate"],
        staleIncomingPreserved: true,
        localProjectionUnchanged: true,
        separateRecoveryOperation: true,
        separateRecoveryDeadline: true,
        recoveryGateEnforced: true,
        terminalBlockedStateProjected: true,
        cancellationSettledWithoutReprompt: true,
        unknownFailureRedacted: true,
        unrelatedRepositoryUnchanged: true,
        localEventZeroNetwork: true,
      },
      transportResult: "unsupportedAfterWorker",
      sameLaneSubsequent: true,
      subsequentDiagnostics: true,
      credentialLeaseReport: credentialLeaseReport(),
    });
    expect(sendRequest.mock.calls.map(([method]) => method)).toEqual([
      "repository/checkout",
      "repository/checkout",
      "diagnostics/get",
    ]);
    expect(JSON.stringify(report)).not.toContain("svn.example.invalid");
    expect(JSON.stringify(report)).not.toContain("C:/evidence/checkout");
    expect(JSON.stringify(report)).not.toContain(OPERATION_ID);
    expect(JSON.stringify(report)).not.toContain(SUBSEQUENT_OPERATION_ID);
  });

  it("rejects success before transport and unexpected worker failures", async () => {
    const successConnection = connection({ sendRequest: vi.fn().mockResolvedValue({}) });
    await expect(
      collectInstalledRemoteWorkerReport({
        expectedToken: "token-1",
        request: { token: "token-1" },
        targetPath: "C:/evidence/checkout",
        initialize: vi.fn().mockResolvedValue(successConnection),
        collectCredentialLeaseReport: vi.fn(),
        createOperationId: vi
          .fn()
          .mockReturnValueOnce(OPERATION_ID)
          .mockReturnValueOnce(SUBSEQUENT_OPERATION_ID),
      }),
    ).rejects.toMatchObject({ code: "SUBVERSIONR_INSTALLED_REMOTE_WORKER_BOUNDARY_INVALID" });

    const failedConnection = connection({
      sendRequest: vi.fn().mockRejectedValue(rpcError("SUBVERSIONR_REMOTE_WORKER_START_FAILED")),
    });
    await expect(
      collectInstalledRemoteWorkerReport({
        expectedToken: "token-1",
        request: { token: "token-1" },
        targetPath: "C:/evidence/checkout",
        initialize: vi.fn().mockResolvedValue(failedConnection),
        collectCredentialLeaseReport: vi.fn(),
        createOperationId: vi
          .fn()
          .mockReturnValueOnce(OPERATION_ID)
          .mockReturnValueOnce(SUBSEQUENT_OPERATION_ID),
      }),
    ).rejects.toMatchObject({ code: "SUBVERSIONR_REMOTE_WORKER_START_FAILED" });
  });
});

function connection(
  overrides: {
    capability?: boolean;
    credentialLeaseSettlement?: boolean;
    remoteConnectionState?: boolean;
    sendRequest?: (method: string, params: unknown) => Promise<unknown>;
  } = {},
): Pick<BackendConnection, "initializeResult" | "isRemoteSubmissionEnabled" | "sendRequest"> {
  return {
    initializeResult: {
      protocol: { major: 1, minor: 35 },
      capabilities: {
        remoteWorkerIsolation: overrides.capability ?? true,
        credentialLeaseSettlement: overrides.credentialLeaseSettlement ?? true,
        remoteConnectionState: overrides.remoteConnectionState ?? true,
      },
      acknowledgedTrustEpoch: 1,
    } as BackendConnection["initializeResult"],
    isRemoteSubmissionEnabled: () => true,
    sendRequest: (overrides.sendRequest ?? vi.fn().mockRejectedValue(rpcError("unexpected"))) as BackendConnection["sendRequest"],
  };
}

function rpcError(code: string): JsonRpcStreamError {
  return new JsonRpcStreamError({
    code,
    category: "unsupported",
    messageKey: "error.remote.test",
    args: {},
    retryable: false,
    diagnostics: null,
  });
}

function credentialLeaseReport(): Record<string, unknown> {
  return {
    schemaVersion: 1,
    kind: "subversionr.installedCredentialLeaseReport",
    storageCleanup: true,
  };
}
