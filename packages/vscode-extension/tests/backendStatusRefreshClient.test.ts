import { describe, expect, it, vi } from "vitest";
import { BackendStatusRefreshClient } from "../src/status/backendStatusRefreshClient";
import type { BackendConnection, InitializeResult } from "../src/backend/backendProcess";
import type { BackendService } from "../src/backend/backendService";
import type { StatusDelta } from "../src/status/statusRefreshRpcClient";

describe("BackendStatusRefreshClient", () => {
  it("initializes the backend, sends status/refresh, and returns the parsed delta", async () => {
    const delta = deltaResponse();
    const connection = fakeConnection(delta);
    const service = {
      initialize: vi.fn().mockResolvedValue(connection),
    } as Pick<BackendService, "initialize">;
    const client = new BackendStatusRefreshClient(service);

    const result = await client.refreshStatus({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      targets: [{ path: "src/main.c", depth: "empty", reason: "fileChanged" }],
    });

    expect(service.initialize).toHaveBeenCalledTimes(1);
    expect(connection.sendRequest).toHaveBeenCalledWith("status/refresh", {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      targets: [{ path: "src/main.c", depth: "empty", reason: "fileChanged" }],
    });
    expect(result).toEqual(delta);
  });

  it("passes status refresh cancellation signals to the backend connection", async () => {
    const delta = deltaResponse();
    const connection = fakeConnection(delta);
    const service = {
      initialize: vi.fn().mockResolvedValue(connection),
    } as Pick<BackendService, "initialize">;
    const client = new BackendStatusRefreshClient(service);
    const signal = new AbortController().signal;

    await client.refreshStatus(
      {
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        targets: [{ path: "src/main.c", depth: "empty", reason: "fileChanged" }],
      },
      { signal },
    );

    expect(connection.sendRequest).toHaveBeenCalledWith(
      "status/refresh",
      {
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        targets: [{ path: "src/main.c", depth: "empty", reason: "fileChanged" }],
      },
      { signal },
    );
  });
});

function fakeConnection(delta: StatusDelta): BackendConnection {
  return {
    initializeResult: initializeResult(),
    sendRequest: vi.fn().mockResolvedValue(delta),
    onDidTerminate: vi.fn(() => ({ dispose: vi.fn() })),
    shutdown: vi.fn().mockResolvedValue(undefined),
    dispose: vi.fn(),
  };
}

function deltaResponse(): StatusDelta {
  return {
    repositoryId: "repo-uuid:C:/wc",
    epoch: 7,
    generation: 11,
    coverage: [{ path: "src/main.c", depth: "empty", generation: 11, reason: "fileChanged" }],
    upsert: [],
    remove: [],
    remoteUpsert: [],
    remoteRemove: [],
    summaryDelta: {
      localChanges: 0,
      remoteChanges: 0,
      conflicts: 0,
      unversioned: 0,
    },
    completeness: "partial",
    timestamp: "2026-06-22T00:00:00Z",
    source: "libsvn-local",
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
