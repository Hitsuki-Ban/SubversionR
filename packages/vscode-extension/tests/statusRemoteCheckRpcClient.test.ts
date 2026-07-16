import { describe, expect, it, vi } from "vitest";
import {
  StatusRemoteCheckRequestError,
  StatusRemoteCheckRpcClient,
} from "../src/status/statusRemoteCheckRpcClient";
import type { JsonRpcSender } from "../src/status/types";

describe("StatusRemoteCheckRpcClient", () => {
  it("sends the dedicated remote request with cancellation and accepts authoritative coverage", async () => {
    const signal = new AbortController().signal;
    const sender = senderReturning(remoteDelta());
    const client = new StatusRemoteCheckRpcClient(sender);

    const delta = await client.checkRemoteStatus(
      { repositoryId: "repo-uuid:C:/wc", epoch: 7 },
      { signal },
    );

    expect(sender.sendRequest).toHaveBeenCalledWith(
      "status/checkRemote",
      { repositoryId: "repo-uuid:C:/wc", epoch: 7 },
      { signal },
    );
    expect(delta.remoteUpsert.map((entry) => entry.path)).toEqual(["src/incoming.c"]);
  });

  it("rejects request aliases and missing required fields", async () => {
    const client = new StatusRemoteCheckRpcClient(senderReturning(remoteDelta()));

    await expect(
      client.checkRemoteStatus({ repositoryId: "repo-uuid:C:/wc", epoch: 7, mode: "remote" } as never),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_STATUS_REMOTE_CHECK_REQUEST_INVALID",
      messageKey: "error.status.remoteCheckRequestInvalid",
    });
  });

  it.each([
    ["source", { source: "libsvn-local" }],
    ["coverage", { coverage: [{ path: ".", depth: "infinity", generation: 8, reason: "manualRemoteCheck" }] }],
    ["local upsert", { upsert: [statusEntry("src/local.c")] }],
  ])("rejects non-authoritative remote response: %s", async (_label, override) => {
    const client = new StatusRemoteCheckRpcClient(senderReturning({ ...remoteDelta(), ...override }));

    await expect(client.checkRemoteStatus({ repositoryId: "repo-uuid:C:/wc", epoch: 7 })).rejects.toBeInstanceOf(
      StatusRemoteCheckRequestError,
    );
  });
});

function senderReturning(response: unknown): JsonRpcSender & { sendRequest: ReturnType<typeof vi.fn> } {
  return { sendRequest: vi.fn().mockResolvedValue(response) };
}

function remoteDelta(): Record<string, unknown> {
  return {
    repositoryId: "repo-uuid:C:/wc",
    epoch: 7,
    generation: 8,
    coverage: [{ path: ".", depth: "workingCopy", generation: 8, reason: "manualRemoteCheck" }],
    upsert: [],
    remove: [],
    remoteUpsert: [statusEntry("src/incoming.c")],
    remoteRemove: [],
    summaryDelta: { localChanges: 0, remoteChanges: 1, conflicts: 0, unversioned: 0 },
    completeness: "complete",
    timestamp: "2026-07-11T00:00:00Z",
    source: "libsvn-remote",
  };
}

function statusEntry(path: string): Record<string, unknown> {
  return {
    path,
    kind: "file",
    nodeStatus: "normal",
    textStatus: "modified",
    propertyStatus: "normal",
    localStatus: "normal",
    remoteStatus: "modified",
    revision: 7,
    changedRevision: 8,
    changedAuthor: "alice",
    changedDate: "2026-07-11T00:00:00Z",
    changelist: null,
    lock: null,
    needsLock: false,
    copy: null,
    move: null,
    switched: false,
    depth: "infinity",
    conflict: null,
    conflictArtifacts: [],
    external: false,
    generation: 8,
  };
}
