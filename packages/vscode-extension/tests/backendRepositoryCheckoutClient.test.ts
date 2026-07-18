import { describe, expect, it, vi } from "vitest";
import { BackendRepositoryCheckoutClient } from "../src/repository/backendRepositoryCheckoutClient";
import type { BackendConnection, InitializeResult } from "../src/backend/backendProcess";
import type { BackendService } from "../src/backend/backendService";

describe("BackendRepositoryCheckoutClient", () => {
  it("initializes the backend and sends repository/checkout through the active connection", async () => {
    const connection = fakeConnection();
    const service = {
      initialize: vi.fn().mockResolvedValue(connection),
    } as Pick<BackendService, "initialize">;
    const client = new BackendRepositoryCheckoutClient(service);

    const result = await client.checkout({
      url: "https://svn.example.invalid/project/trunk",
      targetPath: "C:/workspace/project",
      revision: "head",
      depth: "infinity",
      ignoreExternals: true,
    });

    expect(service.initialize).toHaveBeenCalledTimes(1);
    expect(connection.sendRequest).toHaveBeenCalledWith("repository/checkout", {
      url: "https://svn.example.invalid/project/trunk",
      targetPath: "C:/workspace/project",
      revision: "head",
      depth: "infinity",
      ignoreExternals: true,
    });
    expect(result).toEqual({
      workingCopyPath: "C:/workspace/project",
      revision: 42,
    });
  });
});

function fakeConnection(): BackendConnection {
  return {
    initializeResult: initializeResult(),
    sendRequest: vi.fn().mockResolvedValue({
      workingCopyPath: "C:/workspace/project",
      revision: 42,
    }),
    isRemoteSubmissionEnabled: vi.fn(() => true),
    updateWorkspaceTrust: vi.fn(async () => 2),
    onDidTerminate: vi.fn(() => ({ dispose: vi.fn() })),
    shutdown: vi.fn().mockResolvedValue(undefined),
    dispose: vi.fn(),
  };
}

function initializeResult(): InitializeResult {
  return {
    protocol: { major: 1, minor: 33 },
    backendVersion: "0.1.0",
    bridgeVersion: "subversionr-svn-bridge/0.1.0",
    libsvnVersion: "1.14.5",
    platform: { os: "windows", arch: "x86_64" },
    cacheSchema: {
      schemaId: "subversionr.cache.v1",
      version: 1,
      rollback: "delete-and-reconcile",
    },
    capabilities: {
      contentLengthFraming: true,
      realLibsvnBridge: true,
      repositoryDiscover: true,
      repositoryOpen: true,
      repositoryClose: true,
      repositoryCheckout: true,
      statusSnapshot: true,
      statusRefresh: true,
      statusRemoteCheck: true,
      statusStaleNotification: true,
      contentGet: true,
      contentGetRevision: true,
      historyLog: true,
      historyBlame: true,
      operationRun: true,
      operationRunAdd: true,
      operationRunRemove: true,
      operationRunMove: true,
      operationRunCleanup: true,
      operationRunResolve: true,
      operationRunUpdate: true,
      operationRunUpdateSelectedPath: true,
      operationRunUpdateToRevision: true,
      operationRunUpdateDepth: true,
      operationRunUpdateExternalsPolicy: true,
      propertiesList: true,
      operationRunPropertySet: true,
      operationRunPropertyDelete: true,
      ignore: true,
      operationRunChangelistSet: true,
      operationRunChangelistClear: true,
      operationRunLock: true,
      operationRunUnlock: true,
      operationRunBranchCreate: true,
      operationRunSwitch: true,
      operationRunCommit: true,
      operationRunCommitMultiPath: true,
      diagnosticsGet: true,
      credentialRequest: true,
      certificateRequest: true,
      remoteOperationEnvelope: true,
      trustedConfigSnapshot: true,
      remoteWorkerIsolation: true,
      credentialLeaseSettlement: true,
    },
    acknowledgedTrustEpoch: 1,
  };
}
