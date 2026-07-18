import { describe, expect, it, vi } from "vitest";
import { RemoteStatusCheckService, remoteFailureFromError } from "../src/status/remoteStatusCheckService";
import { RemoteConnectionStateStore } from "../src/status/remoteConnectionStateStore";
import type { StatusDelta } from "../src/status/statusRefreshRpcClient";
import { RemoteProfileConfigurationError } from "../src/security/remoteAccessProfile";

const OPERATION_ID = "00000000-0000-4000-8000-000000000001";

describe("RemoteStatusCheckService", () => {
  it("applies only the remote delta and publishes checking then online state", async () => {
    const delta = {} as StatusDelta;
    const client = { checkRemoteStatus: vi.fn().mockResolvedValue(delta) };
    const snapshot = { summary: { remoteChanges: 3 } };
    const sourceControlProjection = { applyDelta: vi.fn(), replaceSnapshot: vi.fn() };
    const remoteStateProjection = { updateRemoteConnectionState: vi.fn() };
    const refreshPipeline = {
      runExclusive: vi.fn(async (_repositoryId: string, operation: () => Promise<number>) => await operation()),
    };
    const service = createService({
      client,
      statusSnapshotStore: { applyDelta: vi.fn().mockReturnValue(snapshot) },
      sourceControlProjection,
      remoteStateProjection,
      refreshPipeline,
    });

    await expect(service.checkRemoteChanges(target())).resolves.toBe(3);

    expect(client.checkRemoteStatus).toHaveBeenCalledWith({
      repositoryId: "repo",
      epoch: 2,
      remote: remoteEnvelope(),
    }, {});
    expect(sourceControlProjection.applyDelta).toHaveBeenCalledWith(delta);
    expect(remoteStateProjection.updateRemoteConnectionState.mock.calls.map(([state]) => state.kind)).toEqual([
      "checking",
      "online",
    ]);
    expect(refreshPipeline.runExclusive).toHaveBeenCalledWith("repo", expect.any(Function));
  });

  it("rebuilds projection and marks Incoming stale when projection application fails", async () => {
    const delta = {} as StatusDelta;
    const snapshot = { summary: { remoteChanges: 1 } };
    const failure = new Error("projection failed");
    const sourceControlProjection = {
      applyDelta: vi.fn().mockImplementation(() => { throw failure; }),
      replaceSnapshot: vi.fn(),
    };
    const remoteStateProjection = { updateRemoteConnectionState: vi.fn() };
    const service = createService({
      client: { checkRemoteStatus: vi.fn().mockResolvedValue(delta) },
      statusSnapshotStore: { applyDelta: vi.fn().mockReturnValue(snapshot) },
      sourceControlProjection,
      remoteStateProjection,
    });

    await expect(service.checkRemoteChanges(target())).rejects.toBe(failure);

    expect(sourceControlProjection.replaceSnapshot).toHaveBeenCalledWith(snapshot);
    expect(remoteStateProjection.updateRemoteConnectionState.mock.calls.at(-1)?.[0]).toMatchObject({
      kind: "online",
      incoming: { kind: "fresh" },
    });
  });

  it("settles invalid profile construction as configuration attention before network", async () => {
    const client = { checkRemoteStatus: vi.fn() };
    const remoteStateProjection = { updateRemoteConnectionState: vi.fn() };
    const service = createService({
      client,
      remoteStateProjection,
      createRemoteEnvelope: vi.fn().mockRejectedValue(new RemoteProfileConfigurationError(
        "SUBVERSIONR_REMOTE_PROFILE_MATCH_INVALID",
        "error.remote.profileMatchInvalid",
      )),
    });

    await expect(service.checkRemoteChanges(target())).rejects.toMatchObject({
      code: "SUBVERSIONR_REMOTE_PROFILE_MATCH_INVALID",
    });

    expect(client.checkRemoteStatus).not.toHaveBeenCalled();
    expect(remoteStateProjection.updateRemoteConnectionState.mock.calls.at(-1)?.[0]).toMatchObject({
      kind: "attention",
      reason: "configurationInvalid",
      incoming: { kind: "stale" },
    });
  });

  it("settles the remote check online with stale Incoming if projection rebuild also fails", async () => {
    const delta = {} as StatusDelta;
    const remoteStateProjection = { updateRemoteConnectionState: vi.fn() };
    const service = createService({
      client: { checkRemoteStatus: vi.fn().mockResolvedValue(delta) },
      statusSnapshotStore: { applyDelta: vi.fn().mockReturnValue({ summary: { remoteChanges: 1 } }) },
      sourceControlProjection: {
        applyDelta: vi.fn().mockImplementation(() => { throw new Error("apply"); }),
        replaceSnapshot: vi.fn().mockImplementation(() => { throw new Error("replace"); }),
      },
      remoteStateProjection,
    });

    await expect(service.checkRemoteChanges(target())).rejects.toBeInstanceOf(AggregateError);

    expect(remoteStateProjection.updateRemoteConnectionState.mock.calls.at(-1)?.[0]).toMatchObject({
      kind: "online",
      transport: "https",
      incoming: { kind: "stale" },
    });
  });

  it("accepts only exact bounded daemon remoteFailure details", () => {
    expect(remoteFailureFromError({
      safeArgs: {
        remoteFailure: { category: "network", reason: "networkTimeout", cleanupAppropriate: false },
      },
    })).toEqual({ category: "unreachable", reason: "networkTimeout", cleanupAppropriate: false });
    expect(remoteFailureFromError({
      safeArgs: {
        remoteFailure: { category: "attention", reason: "networkTimeout", cleanupAppropriate: false, raw: "secret" },
      },
    })).toEqual({ category: "attention", reason: "unknownRemote", cleanupAppropriate: false });
    expect(remoteFailureFromError({ code: "VENDOR_UNSUPPORTED_REMOTE" })).toEqual({
      category: "attention",
      reason: "unknownRemote",
      cleanupAppropriate: false,
    });
  });

  it("keeps read-only worker containment failure indeterminate without working-copy recovery", async () => {
    const remoteStateProjection = { updateRemoteConnectionState: vi.fn() };
    const service = createService({
      client: {
        checkRemoteStatus: vi.fn().mockRejectedValue({
          safeArgs: {
            remoteFailure: { category: "process", reason: "workerContainmentFailed", cleanupAppropriate: false },
          },
        }),
      },
      remoteStateProjection,
    });

    await expect(service.checkRemoteChanges(target())).rejects.toBeDefined();
    expect(remoteStateProjection.updateRemoteConnectionState.mock.calls.at(-1)?.[0]).toMatchObject({
      kind: "indeterminate",
      reason: "workerTerminated",
      incoming: { kind: "stale" },
      recovery: { kind: "notRequired" },
    });
  });

  it("does not hold the local refresh lane while the remote RPC is pending", async () => {
    let resolveRemote!: (delta: StatusDelta) => void;
    const remoteResponse = new Promise<StatusDelta>((resolve) => { resolveRemote = resolve; });
    const client = { checkRemoteStatus: vi.fn().mockReturnValue(remoteResponse) };
    let tail = Promise.resolve<unknown>(undefined);
    const refreshPipeline = {
      runExclusive: vi.fn((_repositoryId: string, operation: () => Promise<unknown>) => {
        const result = tail.then(operation);
        tail = result.then(() => undefined, () => undefined);
        return result;
      }),
    };
    const service = createService({
      client,
      refreshPipeline,
      statusSnapshotStore: { applyDelta: vi.fn().mockReturnValue({ summary: { remoteChanges: 1 } }) },
    });
    const remoteCheck = service.checkRemoteChanges(target());
    await vi.waitFor(() => expect(client.checkRemoteStatus).toHaveBeenCalledOnce());

    let localRefreshCompleted = false;
    await refreshPipeline.runExclusive("repo", async () => {
      localRefreshCompleted = true;
    });
    expect(localRefreshCompleted).toBe(true);
    expect(refreshPipeline.runExclusive).toHaveBeenCalledOnce();

    resolveRemote({} as StatusDelta);
    await expect(remoteCheck).resolves.toBe(1);
    expect(refreshPipeline.runExclusive).toHaveBeenCalledTimes(2);
  });

  it("preserves the remote RPC outcome when the repository unregisters during the request", async () => {
    const successfulStore = new RemoteConnectionStateStore();
    successfulStore.registerRepository({ repositoryId: "repo", epoch: 2 });
    let resolveSuccess!: (delta: StatusDelta) => void;
    const successClient = {
      checkRemoteStatus: vi.fn().mockReturnValue(new Promise<StatusDelta>((resolve) => { resolveSuccess = resolve; })),
    };
    const successProjection = { updateRemoteConnectionState: vi.fn() };
    const success = createService({
      client: successClient,
      remoteConnectionStateStore: successfulStore,
      remoteStateProjection: successProjection,
      statusSnapshotStore: { applyDelta: vi.fn().mockReturnValue({ summary: { remoteChanges: 4 } }) },
    }).checkRemoteChanges(target());
    await vi.waitFor(() => expect(successClient.checkRemoteStatus).toHaveBeenCalledOnce());
    successfulStore.unregisterRepository("repo");
    resolveSuccess({} as StatusDelta);

    await expect(success).resolves.toBe(4);
    expect(successProjection.updateRemoteConnectionState.mock.calls.map(([state]) => state.kind)).toEqual(["checking"]);

    const failedStore = new RemoteConnectionStateStore();
    failedStore.registerRepository({ repositoryId: "repo", epoch: 2 });
    let rejectFailure!: (error: unknown) => void;
    const rpcFailure = new Error("remote RPC failed");
    const failureClient = {
      checkRemoteStatus: vi.fn().mockReturnValue(new Promise<StatusDelta>((_resolve, reject) => { rejectFailure = reject; })),
    };
    const failureProjection = { updateRemoteConnectionState: vi.fn() };
    const failed = createService({
      client: failureClient,
      remoteConnectionStateStore: failedStore,
      remoteStateProjection: failureProjection,
    }).checkRemoteChanges(target());
    await vi.waitFor(() => expect(failureClient.checkRemoteStatus).toHaveBeenCalledOnce());
    failedStore.unregisterRepository("repo");
    rejectFailure(rpcFailure);

    await expect(failed).rejects.toBe(rpcFailure);
    expect(failureProjection.updateRemoteConnectionState.mock.calls.map(([state]) => state.kind)).toEqual(["checking"]);
  });
});

function createService(overrides: Record<string, unknown> = {}): RemoteStatusCheckService {
  const remoteConnectionStateStore = new RemoteConnectionStateStore();
  remoteConnectionStateStore.registerRepository({ repositoryId: "repo", epoch: 2 });
  return new RemoteStatusCheckService({
    client: { checkRemoteStatus: vi.fn() },
    statusSnapshotStore: { applyDelta: vi.fn() } as never,
    sourceControlProjection: { applyDelta: vi.fn(), replaceSnapshot: vi.fn() } as never,
    remoteStateProjection: { updateRemoteConnectionState: vi.fn() },
    refreshPipeline: {
      runExclusive: vi.fn(async (_repositoryId: string, operation: () => Promise<number>) => await operation()),
    } as never,
    remoteConnectionStateStore,
    now: () => "2026-07-18T01:00:00.000Z",
    createOperationId: () => OPERATION_ID,
    createRemoteEnvelope: async () => remoteEnvelope(),
    ...overrides,
  } as never);
}

function target() {
  return { repositoryId: "repo", epoch: 2, repositoryRootUrl: "https://svn.example.test/repo" };
}

function remoteEnvelope() {
  return {
    version: 1 as const,
    operationId: OPERATION_ID,
    intent: "foreground" as const,
    interaction: "allowed" as const,
    timeoutMs: 30_000,
    workspaceTrust: "trusted" as const,
    trustEpoch: 1,
    profile: {
      schema: "subversionr.remote-profile.v1" as const,
      profileId: "test",
      authority: { scheme: "https" as const, canonicalHost: "svn.example.test", effectivePort: 443 },
      serverAuth: "anonymous" as const,
      serverAccount: "none" as const,
      serverCredentialPersistence: "secretStorage" as const,
      tls: { trust: "windowsRootsThenBroker" as const },
      proxy: "none" as const,
      ssh: "none" as const,
      redirectPolicy: "rejectAll" as const,
    },
    expectedOrigin: { scheme: "https" as const, canonicalHost: "svn.example.test", effectivePort: 443 },
  };
}
