import { describe, expect, it, vi } from "vitest";
import { BackendStatusSnapshotClient } from "../src/status/backendStatusSnapshotClient";
import type { BackendConnection, InitializeResult } from "../src/backend/backendProcess";
import type { BackendService } from "../src/backend/backendService";

describe("BackendStatusSnapshotClient", () => {
  it("initializes the backend and sends status/getSnapshot through the active connection", async () => {
    const connection = fakeConnection();
    const service = {
      initialize: vi.fn().mockResolvedValue(connection),
    } as Pick<BackendService, "initialize">;
    const client = new BackendStatusSnapshotClient(service);

    const snapshot = await client.getSnapshot({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
    });

    expect(service.initialize).toHaveBeenCalledTimes(1);
    expect(connection.sendRequest).toHaveBeenCalledWith("status/getSnapshot", {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
    });
    expect(snapshot.repositoryId).toBe("repo-uuid:C:/wc");
    expect(snapshot.generation).toBe(11);
  });
});

function fakeConnection(): BackendConnection {
  return {
    initializeResult: initializeResult(),
    sendRequest: vi.fn().mockResolvedValue({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      generation: 11,
      completeness: "complete",
      identity: {
        repositoryUuid: "repo-uuid",
        repositoryRootUrl: "file:///C:/repo",
        workingCopyRoot: "C:/wc",
        workspaceScopeRoot: "C:/workspace",
        format: 31,
      },
      localEntries: [],
      remoteEntries: [],
      summary: {
        localChanges: 0,
        remoteChanges: 0,
        conflicts: 0,
        unversioned: 0,
      },
      timestamp: "2026-06-22T00:00:00Z",
      source: "libsvn-local",
    }),
    onDidTerminate: vi.fn(() => ({ dispose: vi.fn() })),
    shutdown: vi.fn().mockResolvedValue(undefined),
    dispose: vi.fn(),
  };
}

function initializeResult(): InitializeResult {
  return {
    protocol: { major: 1, minor: 28 },
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
    },
  };
}
