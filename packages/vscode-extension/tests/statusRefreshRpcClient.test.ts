import { describe, expect, it, vi } from "vitest";
import {
  StatusRefreshResponseError,
  StatusRefreshRpcClient,
  type StatusDelta,
} from "../src/status/statusRefreshRpcClient";
import type { JsonRpcSender } from "../src/status/types";

describe("StatusRefreshRpcClient", () => {
  it("sends status/refresh with explicit repository, epoch, and targets and returns the parsed delta", async () => {
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(deltaResponse()),
    };
    const client = new StatusRefreshRpcClient(sender);

    const delta = await client.refreshStatus({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      targets: [{ path: "src/main.c", depth: "empty", reason: "fileChanged" }],
    });

    expect(sender.sendRequest).toHaveBeenCalledWith("status/refresh", {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      targets: [{ path: "src/main.c", depth: "empty", reason: "fileChanged" }],
    });
    expect(delta).toEqual(deltaResponse());
  });

  it.each([
    ["repositoryId", { repositoryId: "", epoch: 7, targets: [{ path: "src/main.c", depth: "empty", reason: "fileChanged" }] }],
    ["epoch", { repositoryId: "repo-uuid:C:/wc", epoch: -1, targets: [{ path: "src/main.c", depth: "empty", reason: "fileChanged" }] }],
    ["targets", { repositoryId: "repo-uuid:C:/wc", epoch: 7, targets: [] }],
    [
      "extra",
      {
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        targets: [{ path: "src/main.c", depth: "empty", reason: "fileChanged" }],
        extra: true,
      },
    ],
    ["targets.0.path", { repositoryId: "repo-uuid:C:/wc", epoch: 7, targets: [{ path: "../main.c", depth: "empty", reason: "fileChanged" }] }],
    ["targets.0.depth", { repositoryId: "repo-uuid:C:/wc", epoch: 7, targets: [{ path: "src/main.c", depth: "unknown", reason: "fileChanged" }] }],
    ["targets.0.reason", { repositoryId: "repo-uuid:C:/wc", epoch: 7, targets: [{ path: "src/main.c", depth: "empty", reason: "" }] }],
  ])("fails fast on invalid refresh request field: %s", async (field, request) => {
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(deltaResponse()),
    };
    const client = new StatusRefreshRpcClient(sender);

    await expect(client.refreshStatus(request as never)).rejects.toMatchObject({
      code: "SUBVERSIONR_STATUS_REFRESH_REQUEST_INVALID",
      category: "input",
      messageKey: "error.status.refreshRequestInvalid",
      safeArgs: { field },
    });
    expect(sender.sendRequest).not.toHaveBeenCalled();
  });

  it.each([
    ["repositoryId", (delta: StatusDelta) => (delta.repositoryId = "other-repo:C:/wc")],
    ["epoch", (delta: StatusDelta) => (delta.epoch = 8)],
    ["completeness", (delta: StatusDelta) => ((delta as { completeness: string }).completeness = "complete-ish")],
    ["coverage.0.generation", (delta: StatusDelta) => (delta.coverage[0].generation = 10)],
    ["coverage.0.path", (delta: StatusDelta) => (delta.coverage[0].path = "../main.c")],
    ["upsert.0.generation", (delta: StatusDelta) => (delta.upsert[0].generation = 10)],
    ["upsert.0.path", (delta: StatusDelta) => (delta.upsert[0].path = "/src/main.c")],
    ["upsert.0.needsLock", (delta: StatusDelta) => ((delta.upsert[0] as { needsLock: unknown }).needsLock = "yes")],
    [
      "upsert.0.lock.extra",
      (delta: StatusDelta) => {
        delta.upsert[0].lock = lockInfo();
        addWireField(delta.upsert[0].lock, "extra", true);
      },
    ],
    [
      "upsert.0.lock.isRemote",
      (delta: StatusDelta) => {
        delta.upsert[0].lock = { ...lockInfo(), isRemote: "no" } as never;
      },
    ],
    ["remove.0", (delta: StatusDelta) => (delta.remove = ["D:/outside.c"])],
    ["remove.1", (delta: StatusDelta) => (delta.remove = ["src/old.c", "src/old.c"])],
    ["upsert.1.path", (delta: StatusDelta) => delta.upsert.push({ ...delta.upsert[0] })],
    ["remove.0", (delta: StatusDelta) => (delta.remove = ["src/main.c"])],
    ["remoteUpsert.0.generation", (delta: StatusDelta) => (delta.remoteUpsert[0].generation = 10)],
    ["remoteUpsert.0.path", (delta: StatusDelta) => (delta.remoteUpsert[0].path = "/src/incoming.c")],
    ["remoteRemove.0", (delta: StatusDelta) => (delta.remoteRemove = ["D:/outside.c"])],
    ["remoteRemove.1", (delta: StatusDelta) => (delta.remoteRemove = ["src/old-incoming.c", "src/old-incoming.c"])],
    ["remoteUpsert.1.path", (delta: StatusDelta) => delta.remoteUpsert.push({ ...delta.remoteUpsert[0] })],
    ["remoteRemove.0", (delta: StatusDelta) => (delta.remoteRemove = ["src/incoming.c"])],
    ["timestamp", (delta: StatusDelta) => deleteWireField(delta, "timestamp")],
    ["coverage", (delta: StatusDelta) => addWireField(delta, "coverage", {})],
    ["summaryDelta.localChanges", (delta: StatusDelta) => (delta.summaryDelta.localChanges = 0.5)],
  ])("rejects inconsistent refresh response field: %s", async (field, mutate) => {
    const response = deltaResponse();
    mutate(response);
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(response),
    };
    const client = new StatusRefreshRpcClient(sender);

    await expect(
      client.refreshStatus({
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        targets: [{ path: "src/main.c", depth: "empty", reason: "fileChanged" }],
      }),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_STATUS_REFRESH_RESPONSE_INVALID",
      category: "protocol",
      messageKey: "error.status.refreshResponseInvalid",
      safeArgs: { field },
    });
  });

  it("rejects extra refresh response fields", async () => {
    const response = deltaResponse();
    addWireField(response.summaryDelta, "extraSummary", true);
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(response),
    };
    const client = new StatusRefreshRpcClient(sender);

    await expect(
      client.refreshStatus({
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        targets: [{ path: "src/main.c", depth: "empty", reason: "fileChanged" }],
      }),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_STATUS_REFRESH_RESPONSE_INVALID",
      category: "protocol",
      messageKey: "error.status.refreshResponseInvalid",
      safeArgs: { field: "summaryDelta.extraSummary" },
    });
  });

  it("carries opaque status tokens and signed summary deltas", async () => {
    const response = deltaResponse();
    response.upsert[0] = {
      ...response.upsert[0],
      kind: "future-kind",
      localStatus: "future-local-status",
      remoteStatus: "future-remote-status",
      revision: -1,
      changedRevision: -1,
      depth: "future-depth",
    };
    response.summaryDelta.localChanges = -1;
    response.completeness = "complete";
    response.source = "future-source";
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(response),
    };
    const client = new StatusRefreshRpcClient(sender);

    const delta = await client.refreshStatus({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      targets: [{ path: "src/main.c", depth: "empty", reason: "fileChanged" }],
    });

    expect(delta.summaryDelta.localChanges).toBe(-1);
    expect(delta.source).toBe("future-source");
    expect(delta.upsert[0]).toMatchObject({
      kind: "future-kind",
      localStatus: "future-local-status",
      remoteStatus: "future-remote-status",
      revision: -1,
      changedRevision: -1,
      depth: "future-depth",
    });
    expect(delta.remoteUpsert[0]).toMatchObject({
      path: "src/incoming.c",
      remoteStatus: "modified",
    });
    expect(delta.remoteRemove).toEqual(["src/old-incoming.c"]);
  });

  it("preserves switched metadata from refresh delta upserts", async () => {
    const response = deltaResponse();
    response.upsert[0] = {
      ...response.upsert[0],
      path: "branches/feature-src",
      kind: "dir",
      nodeStatus: "normal",
      textStatus: "normal",
      propertyStatus: "normal",
      localStatus: "normal",
      switched: true,
      depth: "infinity",
    };
    response.coverage[0] = {
      path: "branches/feature-src",
      depth: "empty",
      generation: 11,
      reason: "directoryChanged",
    };
    response.summaryDelta.localChanges = 0;
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(response),
    };
    const client = new StatusRefreshRpcClient(sender);

    const delta = await client.refreshStatus({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      targets: [{ path: "branches/feature-src", depth: "empty", reason: "directoryChanged" }],
    });

    expect(delta.upsert[0]).toMatchObject({
      path: "branches/feature-src",
      kind: "dir",
      localStatus: "normal",
      switched: true,
      depth: "infinity",
    });
    expect(delta.summaryDelta.localChanges).toBe(0);
  });

  it("preserves structured lock and needs-lock metadata from refresh delta upserts", async () => {
    const response = deltaResponse();
    response.upsert[0] = {
      ...response.upsert[0],
      lock: lockInfo(),
      needsLock: true,
    };
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockResolvedValue(response),
    };
    const client = new StatusRefreshRpcClient(sender);

    const delta = await client.refreshStatus({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      targets: [{ path: "src/main.c", depth: "empty", reason: "fileChanged" }],
    });

    expect(delta.upsert[0].lock).toEqual(lockInfo());
    expect(delta.upsert[0].needsLock).toBe(true);
  });

  it("propagates backend errors without replacing their structured payload", async () => {
    const backendError = new Error("backend failed");
    const sender: JsonRpcSender = {
      sendRequest: vi.fn().mockRejectedValue(backendError),
    };
    const client = new StatusRefreshRpcClient(sender);

    await expect(
      client.refreshStatus({
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        targets: [{ path: "src/main.c", depth: "empty", reason: "fileChanged" }],
      }),
    ).rejects.toBe(backendError);
  });
});

function deltaResponse(): StatusDelta {
  return {
    repositoryId: "repo-uuid:C:/wc",
    epoch: 7,
    generation: 11,
    coverage: [{ path: "src/main.c", depth: "empty", generation: 11, reason: "fileChanged" }],
    upsert: [
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
    remove: ["src/old.c"],
    remoteUpsert: [
      {
        path: "src/incoming.c",
        kind: "file",
        nodeStatus: "normal",
        textStatus: "normal",
        propertyStatus: "normal",
        localStatus: "normal",
        remoteStatus: "modified",
        revision: 7,
        changedRevision: 8,
        changedAuthor: "bob",
        changedDate: "2026-06-22T00:01:00Z",
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
    remoteRemove: ["src/old-incoming.c"],
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

function addWireField(target: object, key: string, value: unknown): void {
  (target as Record<string, unknown>)[key] = value;
}

function deleteWireField(target: object, key: string): void {
  delete (target as Record<string, unknown>)[key];
}

function lockInfo(): NonNullable<StatusDelta["upsert"][number]["lock"]> {
  return {
    token: "opaquelocktoken:1",
    owner: "alice",
    comment: "editing",
    createdDate: "2026-06-25T00:00:00Z",
    expiresDate: null,
    isRemote: false,
  };
}

expect(StatusRefreshResponseError).toBeDefined();
