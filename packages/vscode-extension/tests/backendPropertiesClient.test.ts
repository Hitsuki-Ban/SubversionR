import { describe, expect, it, vi } from "vitest";
import type { BackendConnection, InitializeResult } from "../src/backend/backendProcess";
import type { BackendService } from "../src/backend/backendService";
import { BackendPropertiesClient } from "../src/properties/backendPropertiesClient";
import type { PropertiesListResponse } from "../src/properties/propertiesListRpcClient";

describe("BackendPropertiesClient", () => {
  it("initializes the backend and sends properties/list through the active connection", async () => {
    const response = propertiesResponse();
    const connection = fakeConnection(response);
    const service = {
      initialize: vi.fn().mockResolvedValue(connection),
    } as Pick<BackendService, "initialize">;
    const client = new BackendPropertiesClient(service);

    const result = await client.listProperties({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src",
    });

    expect(service.initialize).toHaveBeenCalledTimes(1);
    expect(connection.sendRequest).toHaveBeenCalledWith("properties/list", {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src",
    });
    expect(result).toEqual(response);
  });
});

function fakeConnection(response: PropertiesListResponse): BackendConnection {
  return {
    initializeResult: initializeResult(),
    sendRequest: vi.fn().mockResolvedValue(response),
    isRemoteSubmissionEnabled: vi.fn(() => true),
    currentRemoteTrustEpoch: vi.fn(() => 1),
    updateWorkspaceTrust: vi.fn(async () => 2),
    onDidTerminate: vi.fn(() => ({ dispose: vi.fn() })),
    shutdown: vi.fn().mockResolvedValue(undefined),
    dispose: vi.fn(),
  };
}

function propertiesResponse(): PropertiesListResponse {
  return {
    repositoryId: "repo-uuid:C:/wc",
    epoch: 7,
    path: "src",
    properties: [
      {
        name: "svn:ignore",
        value: "target",
        valueEncoding: "utf8",
      },
    ],
    source: "libsvn-local",
  };
}

function initializeResult(): InitializeResult {
  return {
    protocol: { major: 1, minor: 34 },
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
      remoteConnectionState: true,
    },
    acknowledgedTrustEpoch: 1,
  };
}
