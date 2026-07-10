import { describe, expect, it, vi } from "vitest";
import {
  StatusSnapshotResponseError,
  StatusSnapshotRpcClient,
  type StatusSnapshot,
} from "../src/status/statusSnapshotRpcClient";
import type { JsonRpcSender } from "../src/status/types";

describe("StatusSnapshotRpcClient", () => {
  it("sends status/getSnapshot with explicit repository id and epoch", async () => {
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(snapshotResponse()),
    };
    const client = new StatusSnapshotRpcClient(sender);

    const snapshot = await client.getSnapshot({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
    });

    expect(sender.sendRequest).toHaveBeenCalledWith("status/getSnapshot", {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
    });
    expect(snapshot).toEqual(snapshotResponse());
  });

  it.each([
    ["repositoryId", { repositoryId: "", epoch: 7 }],
    ["epoch", { repositoryId: "repo-uuid:C:/wc", epoch: -1 }],
  ])("fails fast on invalid snapshot request field: %s", async (field, request) => {
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(snapshotResponse()),
    };
    const client = new StatusSnapshotRpcClient(sender);

    await expect(client.getSnapshot(request as never)).rejects.toMatchObject({
      code: "SUBVERSIONR_STATUS_SNAPSHOT_REQUEST_INVALID",
      category: "input",
      messageKey: "error.status.snapshotRequestInvalid",
      safeArgs: { field },
    });
    expect(sender.sendRequest).not.toHaveBeenCalled();
  });

  it("rejects invalid snapshot responses with stable protocol errors", async () => {
    const response = snapshotResponse();
    delete (response.localEntries[0] as Partial<typeof response.localEntries[number]>).localStatus;
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(response),
    };
    const client = new StatusSnapshotRpcClient(sender);

    await expect(
      client.getSnapshot({
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
      }),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_STATUS_SNAPSHOT_RESPONSE_INVALID",
      category: "protocol",
      messageKey: "error.status.snapshotResponseInvalid",
      safeArgs: { field: "localEntries.0.localStatus" },
    });
  });

  it.each([
    ["repositoryId", (response: StatusSnapshot) => (response.repositoryId = "other-repo:C:/wc")],
    ["epoch", (response: StatusSnapshot) => (response.epoch = 8)],
    [
      "completeness",
      (response: StatusSnapshot) => ((response as { completeness: string }).completeness = "complete-ish"),
    ],
    ["localEntries.0.generation", (response: StatusSnapshot) => (response.localEntries[0].generation = 10)],
    ["localEntries.0.path", (response: StatusSnapshot) => (response.localEntries[0].path = "../main.c")],
    ["localEntries.0.needsLock", (response: StatusSnapshot) => ((response.localEntries[0] as { needsLock: unknown }).needsLock = "yes")],
    [
      "localEntries.0.lock.extra",
      (response: StatusSnapshot) => {
        response.localEntries[0].lock = lockInfo();
        addWireField(response.localEntries[0].lock, "extra", true);
      },
    ],
    [
      "localEntries.0.lock.isRemote",
      (response: StatusSnapshot) => {
        response.localEntries[0].lock = { ...lockInfo(), isRemote: "no" } as never;
      },
    ],
    [
      "remoteEntries.0.path",
      (response: StatusSnapshot) => {
        response.remoteEntries = [{ ...response.localEntries[0], path: "C:/escape.c" }];
      },
    ],
  ])("rejects inconsistent snapshot response field: %s", async (field, mutate) => {
    const response = snapshotResponse();
    mutate(response);
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(response),
    };
    const client = new StatusSnapshotRpcClient(sender);

    await expect(
      client.getSnapshot({
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
      }),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_STATUS_SNAPSHOT_RESPONSE_INVALID",
      category: "protocol",
      messageKey: "error.status.snapshotResponseInvalid",
      safeArgs: { field },
    });
  });

  it("carries opaque SVN tokens and signed unknown revisions", async () => {
    const response = snapshotResponse();
    response.completeness = "stale";
    response.source = "future-source";
    response.localEntries[0] = {
      ...response.localEntries[0],
      kind: "future-kind",
      localStatus: "future-local-status",
      remoteStatus: "future-remote-status",
      revision: -1,
      changedRevision: -1,
      depth: "future-depth",
    };
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(response),
    };
    const client = new StatusSnapshotRpcClient(sender);

    const snapshot = await client.getSnapshot({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
    });

    expect(snapshot.completeness).toBe("stale");
    expect(snapshot.source).toBe("future-source");
    expect(snapshot.localEntries[0]).toMatchObject({
      kind: "future-kind",
      localStatus: "future-local-status",
      remoteStatus: "future-remote-status",
      revision: -1,
      changedRevision: -1,
      depth: "future-depth",
    });
  });

  it("preserves switched and sparse depth metadata from status entries", async () => {
    const response = snapshotResponse();
    response.localEntries[0] = {
      ...response.localEntries[0],
      kind: "dir",
      localStatus: "normal",
      nodeStatus: "normal",
      textStatus: "normal",
      switched: true,
      depth: "files",
    };
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(response),
    };
    const client = new StatusSnapshotRpcClient(sender);

    const snapshot = await client.getSnapshot({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
    });

    expect(snapshot.localEntries[0]).toMatchObject({
      kind: "dir",
      localStatus: "normal",
      nodeStatus: "normal",
      textStatus: "normal",
      switched: true,
      depth: "files",
    });
  });

  it("preserves structured lock and needs-lock metadata from status entries", async () => {
    const response = snapshotResponse();
    response.localEntries[0] = {
      ...response.localEntries[0],
      lock: lockInfo(),
      needsLock: true,
    };
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(response),
    };
    const client = new StatusSnapshotRpcClient(sender);

    const snapshot = await client.getSnapshot({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
    });

    expect(snapshot.localEntries[0].lock).toEqual(lockInfo());
    expect(snapshot.localEntries[0].needsLock).toBe(true);
  });

  it.each([
    ["unexpectedTopLevel", (response: StatusSnapshot) => addWireField(response, "unexpectedTopLevel", true)],
    ["identity.unexpectedIdentity", (response: StatusSnapshot) => addWireField(response.identity, "unexpectedIdentity", true)],
    [
      "localEntries.0.unexpectedStatus",
      (response: StatusSnapshot) => addWireField(response.localEntries[0], "unexpectedStatus", true),
    ],
    ["summary.unexpectedSummary", (response: StatusSnapshot) => addWireField(response.summary, "unexpectedSummary", true)],
  ])("rejects extra snapshot response field: %s", async (field, mutate) => {
    const response = snapshotResponse();
    mutate(response);
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(response),
    };
    const client = new StatusSnapshotRpcClient(sender);

    await expect(
      client.getSnapshot({
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
      }),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_STATUS_SNAPSHOT_RESPONSE_INVALID",
      category: "protocol",
      messageKey: "error.status.snapshotResponseInvalid",
      safeArgs: { field },
    });
  });

  it("propagates backend errors without replacing their structured payload", async () => {
    const backendError = new Error("REPOSITORY_NOT_OPEN");
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockRejectedValue(backendError),
    };
    const client = new StatusSnapshotRpcClient(sender);

    await expect(
      client.getSnapshot({
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
      }),
    ).rejects.toBe(backendError);
  });
});

function snapshotResponse(): StatusSnapshot {
  return {
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
    localEntries: [
      {
        path: "src/main.c",
        kind: "file",
        nodeStatus: "modified",
        textStatus: "modified",
        propertyStatus: "normal",
        localStatus: "modified",
        remoteStatus: "notChecked",
        revision: 7,
        changedRevision: 7,
        changedAuthor: "alice",
        changedDate: "2026-06-22T00:00:00Z",
        changelist: null,
        lock: null,
        needsLock: false,
        copy: null,
        move: null,
        switched: false,
        depth: "infinity",
        conflict: null,
        external: false,
        generation: 11,
      },
    ],
    remoteEntries: [],
    summary: {
      localChanges: 1,
      remoteChanges: 0,
      conflicts: 0,
      unversioned: 0,
    },
    timestamp: "2026-06-22T00:00:00Z",
    source: "libsvn-local",
  };
}

function addWireField(target: object, key: string, value: unknown): void {
  (target as Record<string, unknown>)[key] = value;
}

function lockInfo(): NonNullable<StatusSnapshot["localEntries"][number]["lock"]> {
  return {
    token: "opaquelocktoken:1",
    owner: "alice",
    comment: "editing",
    createdDate: "2026-06-25T00:00:00Z",
    expiresDate: null,
    isRemote: false,
  };
}

expect(StatusSnapshotResponseError).toBeDefined();
