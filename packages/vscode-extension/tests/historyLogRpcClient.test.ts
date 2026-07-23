import { describe, expect, it, vi } from "vitest";
import type { BackendConnection } from "../src/backend/backendProcess";
import { BackendHistoryClient } from "../src/history/backendHistoryClient";
import { HistoryLogResponseError, HistoryLogRpcClient } from "../src/history/historyLogRpcClient";
import type { JsonRpcSender } from "../src/status/types";
import { anonymousSvnRemoteEnvelope } from "./remoteOperationEnvelopeFixture";

describe("HistoryLogRpcClient", () => {
  it("sends history/log and parses changed-path metadata", async () => {
    const sender = fakeSender(historyLogResponse());
    const client = new HistoryLogRpcClient(sender);

    const log = await client.getLog(historyLogRequest());

    expect(sender.sendRequest).toHaveBeenCalledWith("history/log", historyLogRequest());
    expect(log.entries).toHaveLength(1);
    expect(log.entries[0]).toMatchObject({
      revision: 7,
      author: "alice",
      date: "2026-06-23T00:00:00.000000Z",
      message: "edit file",
      hasChildren: false,
      nonInheritable: false,
      subtractiveMerge: false,
    });
    expect(log.entries[0]?.changedPaths[0]).toEqual({
      path: "/trunk/src/main.c",
      action: "M",
      copyFromPath: null,
      copyFromRevision: null,
      nodeKind: "file",
      textModified: "true",
      propertiesModified: "false",
    });
  });

  it("passes cancellation signals to history/log", async () => {
    const sender = fakeSender(historyLogResponse());
    const request = historyLogRequest();
    const signal = new AbortController().signal;

    await new HistoryLogRpcClient(sender).getLog(request, { signal });

    expect(sender.sendRequest).toHaveBeenCalledWith("history/log", request, { signal });
  });

  it("accepts root history requests with an empty response", async () => {
    const request = {
      ...historyLogRequest(),
      path: ".",
      startRevision: "r10",
      limit: 1,
      discoverChangedPaths: false,
      strictNodeHistory: false,
      includeMergedRevisions: true,
    };
    const sender = fakeSender({
      ...historyLogResponse(),
      path: ".",
      startRevision: "r10",
      limit: 1,
      entries: [],
    });
    const client = new HistoryLogRpcClient(sender);

    const log = await client.getLog(request);

    expect(log.path).toBe(".");
    expect(log.entries).toEqual([]);
    expect(sender.sendRequest).toHaveBeenCalledWith("history/log", request);
  });

  it.each(["", "src\\main.c", "../outside.c", "/trunk/main.c", "C:/wc/main.c", "src//main.c"])(
    "rejects invalid history request path %j before sending",
    async (path) => {
      const sender = fakeSender({});
      const client = new HistoryLogRpcClient(sender);

      await expect(client.getLog({ ...historyLogRequest(), path })).rejects.toMatchObject({
        code: "SUBVERSIONR_HISTORY_LOG_REQUEST_INVALID",
        safeArgs: { field: "path" },
      });
      expect(sender.sendRequest).not.toHaveBeenCalled();
    },
  );

  it.each(["base", "HEAD", "r", "r-1", "r01", "r2147483648"])(
    "rejects invalid start revision %j before sending",
    async (startRevision) => {
      const sender = fakeSender({});
      const client = new HistoryLogRpcClient(sender);

      await expect(client.getLog({ ...historyLogRequest(), startRevision })).rejects.toMatchObject({
        code: "SUBVERSIONR_HISTORY_LOG_REQUEST_INVALID",
        safeArgs: { field: "startRevision" },
      });
      expect(sender.sendRequest).not.toHaveBeenCalled();
    },
  );

  it.each(["head", "base", "r", "r-1", "r01", "r2147483648"])(
    "rejects invalid end revision %j before sending",
    async (endRevision) => {
      const sender = fakeSender({});
      const client = new HistoryLogRpcClient(sender);

      await expect(client.getLog({ ...historyLogRequest(), endRevision })).rejects.toMatchObject({
        code: "SUBVERSIONR_HISTORY_LOG_REQUEST_INVALID",
        safeArgs: { field: "endRevision" },
      });
      expect(sender.sendRequest).not.toHaveBeenCalled();
    },
  );

  it.each([0, 501, 1.5, Number.NaN])("rejects invalid history limit %j before sending", async (limit) => {
    const sender = fakeSender({});
    const client = new HistoryLogRpcClient(sender);

    await expect(client.getLog({ ...historyLogRequest(), limit })).rejects.toMatchObject({
      code: "SUBVERSIONR_HISTORY_LOG_REQUEST_INVALID",
      safeArgs: { field: "limit" },
    });
    expect(sender.sendRequest).not.toHaveBeenCalled();
  });

  it("rejects extra request fields before sending", async () => {
    const sender = fakeSender({});
    const client = new HistoryLogRpcClient(sender);
    const request = { ...historyLogRequest(), extra: true };

    await expect(client.getLog(request)).rejects.toMatchObject({
      code: "SUBVERSIONR_HISTORY_LOG_REQUEST_INVALID",
      safeArgs: { field: "extra" },
    });
    expect(sender.sendRequest).not.toHaveBeenCalled();
  });

  it("accepts local history requests without a remote envelope", async () => {
    const sender = fakeSender(historyLogResponse());
    const client = new HistoryLogRpcClient(sender);
    const { remote: _remote, ...request } = historyLogRequest();
    void _remote;

    await expect(client.getLog(request)).resolves.toMatchObject({ repositoryId: request.repositoryId });
    expect(sender.sendRequest).toHaveBeenCalledWith("history/log", request);
  });

  it("rejects history responses with mismatched identity fields", async () => {
    const sender = fakeSender({ ...historyLogResponse(), repositoryId: "other-repo" });
    const client = new HistoryLogRpcClient(sender);

    await expect(client.getLog(historyLogRequest())).rejects.toMatchObject({
      code: "SUBVERSIONR_HISTORY_LOG_RESPONSE_INVALID",
      safeArgs: { field: "repositoryId" },
    });
  });

  it("rejects history responses from an unexpected source", async () => {
    const sender = fakeSender({ ...historyLogResponse(), source: "cache" });
    const client = new HistoryLogRpcClient(sender);

    await expect(client.getLog(historyLogRequest())).rejects.toMatchObject({
      code: "SUBVERSIONR_HISTORY_LOG_RESPONSE_INVALID",
      safeArgs: { field: "source" },
    });
  });

  it("rejects malformed changed path metadata", async () => {
    const sender = fakeSender({
      ...historyLogResponse(),
      entries: [
        {
          ...historyLogEntry(),
          changedPaths: [{ ...historyChangedPath(), textModified: "maybe" }],
        },
      ],
    });
    const client = new HistoryLogRpcClient(sender);

    await expect(client.getLog(historyLogRequest())).rejects.toBeInstanceOf(HistoryLogResponseError);
    await expect(client.getLog(historyLogRequest())).rejects.toMatchObject({
      code: "SUBVERSIONR_HISTORY_LOG_RESPONSE_INVALID",
      safeArgs: { field: "entries.0.changedPaths.0.textModified" },
    });
  });
});

describe("BackendHistoryClient", () => {
  it("initializes the backend lazily and forwards history/log", async () => {
    const connection = fakeBackendConnection(historyLogResponse());
    const backendService = {
      initialize: vi.fn(async () => connection),
    };
    const client = new BackendHistoryClient(backendService);

    const log = await client.getLog(historyLogRequest());

    expect(backendService.initialize).toHaveBeenCalledTimes(1);
    expect(connection.sendRequest).toHaveBeenCalledWith("history/log", historyLogRequest());
    expect(log.source).toBe("libsvn-log");
  });
});

function historyLogRequest() {
  return {
    repositoryId: "repo-uuid:C:/wc",
    epoch: 7,
    path: "src/main.c",
    startRevision: "head",
    endRevision: "r0",
    limit: 25,
    discoverChangedPaths: true,
    strictNodeHistory: true,
    includeMergedRevisions: false,
    remote: anonymousSvnRemoteEnvelope(),
  };
}

function historyLogResponse() {
  return {
    repositoryId: "repo-uuid:C:/wc",
    epoch: 7,
    path: "src/main.c",
    startRevision: "head",
    endRevision: "r0",
    limit: 25,
    entries: [historyLogEntry()],
    source: "libsvn-log",
  };
}

function historyLogEntry() {
  return {
    revision: 7,
    author: "alice",
    date: "2026-06-23T00:00:00.000000Z",
    message: "edit file",
    changedPaths: [historyChangedPath()],
    hasChildren: false,
    nonInheritable: false,
    subtractiveMerge: false,
  };
}

function historyChangedPath() {
  return {
    path: "/trunk/src/main.c",
    action: "M",
    copyFromPath: null,
    copyFromRevision: null,
    nodeKind: "file",
    textModified: "true",
    propertiesModified: "false",
  };
}

function fakeSender(result: unknown): JsonRpcSender & {
  sendRequest: ReturnType<typeof vi.fn>;
} {
  const sendRequest = vi.fn(async (_method: string, _params: unknown) => result);
  return {
    sendRequest: sendRequest as unknown as JsonRpcSender["sendRequest"],
  } as JsonRpcSender & { sendRequest: ReturnType<typeof vi.fn> };
}

function fakeBackendConnection(result: unknown): BackendConnection & {
  sendRequest: ReturnType<typeof vi.fn>;
} {
  const sender = fakeSender(result);
  return {
    ...sender,
    initializeResult: {} as BackendConnection["initializeResult"],
    isRemoteSubmissionEnabled: vi.fn(() => true),
    currentRemoteTrustEpoch: vi.fn(() => 1),
    updateWorkspaceTrust: vi.fn(async () => 2),
    onDidTerminate: vi.fn(() => ({ dispose: vi.fn() })),
    shutdown: vi.fn(async () => {}),
    dispose: vi.fn(),
  } as BackendConnection & { sendRequest: ReturnType<typeof vi.fn> };
}
