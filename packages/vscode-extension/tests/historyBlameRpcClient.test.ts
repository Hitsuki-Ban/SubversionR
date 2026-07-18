import { describe, expect, it, vi } from "vitest";
import type { BackendConnection } from "../src/backend/backendProcess";
import { BackendHistoryClient } from "../src/history/backendHistoryClient";
import { HistoryBlameResponseError, HistoryBlameRpcClient } from "../src/history/historyBlameRpcClient";
import type { JsonRpcSender } from "../src/status/types";

describe("HistoryBlameRpcClient", () => {
  it("sends history/blame and parses line attribution metadata", async () => {
    const sender = fakeSender(historyBlameResponse());
    const client = new HistoryBlameRpcClient(sender);

    const blame = await client.getBlame(historyBlameRequest());

    expect(sender.sendRequest).toHaveBeenCalledWith("history/blame", historyBlameRequest());
    expect(blame.source).toBe("libsvn-blame");
    expect(blame.lines).toEqual([
      {
        lineNumber: 1,
        revision: 7,
        author: "alice",
        date: "2026-06-23T00:00:00.000000Z",
        mergedRevision: null,
        mergedAuthor: null,
        mergedDate: null,
        mergedPath: null,
        lineBase64: "YWxwaGE=",
        byteLength: 5,
        localChange: false,
      },
      {
        lineNumber: 2,
        revision: 8,
        author: "bob",
        date: "2026-06-23T01:00:00.000000Z",
        mergedRevision: 6,
        mergedAuthor: "carol",
        mergedDate: "2026-06-22T00:00:00.000000Z",
        mergedPath: "/trunk/src/main.c",
        lineBase64: "YmV0YQ==",
        byteLength: 4,
        localChange: false,
      },
    ]);
  });

  it("accepts an explicit one-line window with alternate blame options", async () => {
    const request = {
      ...historyBlameRequest(),
      pegRevision: "head",
      endRevision: "head",
      lineStart: 3,
      lineLimit: 1,
      ignoreWhitespace: "all",
      ignoreEolStyle: true,
      ignoreMimeType: true,
      includeMergedRevisions: true,
    };
    const sender = fakeSender({
      ...historyBlameResponse(),
      pegRevision: "head",
      endRevision: "head",
      lineStart: 3,
      lineLimit: 1,
      ignoreWhitespace: "all",
      ignoreEolStyle: true,
      ignoreMimeType: true,
      includeMergedRevisions: true,
      hasMore: true,
      lines: [{ ...historyBlameLine(), lineNumber: 3 }],
    });
    const client = new HistoryBlameRpcClient(sender);

    const blame = await client.getBlame(request);

    expect(blame.lineStart).toBe(3);
    expect(blame.lineLimit).toBe(1);
    expect(blame.hasMore).toBe(true);
    expect(sender.sendRequest).toHaveBeenCalledWith("history/blame", request);
  });

  it.each(["", ".", "src\\main.c", "../outside.c", "/trunk/main.c", "C:/wc/main.c", "src//main.c"])(
    "rejects invalid blame request path %j before sending",
    async (path) => {
      const sender = fakeSender({});
      const client = new HistoryBlameRpcClient(sender);

      await expect(client.getBlame({ ...historyBlameRequest(), path })).rejects.toMatchObject({
        code: "SUBVERSIONR_HISTORY_BLAME_REQUEST_INVALID",
        safeArgs: { field: "path" },
      });
      expect(sender.sendRequest).not.toHaveBeenCalled();
    },
  );

  it.each(["working", "HEAD", "r", "r-1", "r01", "r2147483648"])(
    "rejects invalid peg revision %j before sending",
    async (pegRevision) => {
      const sender = fakeSender({});
      const client = new HistoryBlameRpcClient(sender);

      await expect(client.getBlame({ ...historyBlameRequest(), pegRevision })).rejects.toMatchObject({
        code: "SUBVERSIONR_HISTORY_BLAME_REQUEST_INVALID",
        safeArgs: { field: "pegRevision" },
      });
      expect(sender.sendRequest).not.toHaveBeenCalled();
    },
  );

  it.each(["base", "head", "working", "r", "r-1", "r01", "r2147483648"])(
    "rejects invalid start revision %j before sending",
    async (startRevision) => {
      const sender = fakeSender({});
      const client = new HistoryBlameRpcClient(sender);

      await expect(client.getBlame({ ...historyBlameRequest(), startRevision })).rejects.toMatchObject({
        code: "SUBVERSIONR_HISTORY_BLAME_REQUEST_INVALID",
        safeArgs: { field: "startRevision" },
      });
      expect(sender.sendRequest).not.toHaveBeenCalled();
    },
  );

  it.each(["working", "HEAD", "r", "r-1", "r01", "r2147483648"])(
    "rejects invalid end revision %j before sending",
    async (endRevision) => {
      const sender = fakeSender({});
      const client = new HistoryBlameRpcClient(sender);

      await expect(client.getBlame({ ...historyBlameRequest(), endRevision })).rejects.toMatchObject({
        code: "SUBVERSIONR_HISTORY_BLAME_REQUEST_INVALID",
        safeArgs: { field: "endRevision" },
      });
      expect(sender.sendRequest).not.toHaveBeenCalled();
    },
  );

  it.each([
    ["lineStart", 0],
    ["lineStart", 1.5],
    ["lineLimit", 0],
    ["lineLimit", 5001],
    ["ignoreWhitespace", "tabs"],
  ])("rejects invalid %s before sending", async (field, value) => {
    const sender = fakeSender({});
    const client = new HistoryBlameRpcClient(sender);

    await expect(client.getBlame({ ...historyBlameRequest(), [field]: value })).rejects.toMatchObject({
      code: "SUBVERSIONR_HISTORY_BLAME_REQUEST_INVALID",
      safeArgs: { field },
    });
    expect(sender.sendRequest).not.toHaveBeenCalled();
  });

  it("rejects extra request fields before sending", async () => {
    const sender = fakeSender({});
    const client = new HistoryBlameRpcClient(sender);
    const request = { ...historyBlameRequest(), extra: true };

    await expect(client.getBlame(request)).rejects.toMatchObject({
      code: "SUBVERSIONR_HISTORY_BLAME_REQUEST_INVALID",
      safeArgs: { field: "extra" },
    });
    expect(sender.sendRequest).not.toHaveBeenCalled();
  });

  it("rejects blame responses with mismatched identity fields", async () => {
    const sender = fakeSender({ ...historyBlameResponse(), repositoryId: "other-repo" });
    const client = new HistoryBlameRpcClient(sender);

    await expect(client.getBlame(historyBlameRequest())).rejects.toMatchObject({
      code: "SUBVERSIONR_HISTORY_BLAME_RESPONSE_INVALID",
      safeArgs: { field: "repositoryId" },
    });
  });

  it("rejects blame responses from an unexpected source", async () => {
    const sender = fakeSender({ ...historyBlameResponse(), source: "cache" });
    const client = new HistoryBlameRpcClient(sender);

    await expect(client.getBlame(historyBlameRequest())).rejects.toMatchObject({
      code: "SUBVERSIONR_HISTORY_BLAME_RESPONSE_INVALID",
      safeArgs: { field: "source" },
    });
  });

  it("rejects malformed line byte metadata", async () => {
    const sender = fakeSender({
      ...historyBlameResponse(),
      lines: [{ ...historyBlameLine(), lineBase64: "YWxwaGE=", byteLength: 99 }],
    });
    const client = new HistoryBlameRpcClient(sender);

    await expect(client.getBlame(historyBlameRequest())).rejects.toBeInstanceOf(HistoryBlameResponseError);
    await expect(client.getBlame(historyBlameRequest())).rejects.toMatchObject({
      code: "SUBVERSIONR_HISTORY_BLAME_RESPONSE_INVALID",
      safeArgs: { field: "lines.0.byteLength" },
    });
  });

  it("rejects response lines outside the requested contiguous window", async () => {
    const sender = fakeSender({
      ...historyBlameResponse(),
      lines: [{ ...historyBlameLine(), lineNumber: 2 }],
    });
    const client = new HistoryBlameRpcClient(sender);

    await expect(client.getBlame(historyBlameRequest())).rejects.toMatchObject({
      code: "SUBVERSIONR_HISTORY_BLAME_RESPONSE_INVALID",
      safeArgs: { field: "lines.lineNumber" },
    });
  });
});

describe("BackendHistoryClient blame", () => {
  it("initializes the backend lazily and forwards history/blame", async () => {
    const connection = fakeBackendConnection(historyBlameResponse());
    const backendService = {
      initialize: vi.fn(async () => connection),
    };
    const client = new BackendHistoryClient(backendService);

    const blame = await client.getBlame(historyBlameRequest());

    expect(backendService.initialize).toHaveBeenCalledTimes(1);
    expect(connection.sendRequest).toHaveBeenCalledWith("history/blame", historyBlameRequest());
    expect(blame.source).toBe("libsvn-blame");
  });
});

function historyBlameRequest() {
  return {
    repositoryId: "repo-uuid:C:/wc",
    epoch: 7,
    path: "src/main.c",
    pegRevision: "base",
    startRevision: "r0",
    endRevision: "base",
    lineStart: 1,
    lineLimit: 2,
    ignoreWhitespace: "none",
    ignoreEolStyle: false,
    ignoreMimeType: false,
    includeMergedRevisions: false,
  };
}

function historyBlameResponse() {
  return {
    repositoryId: "repo-uuid:C:/wc",
    epoch: 7,
    path: "src/main.c",
    pegRevision: "base",
    startRevision: "r0",
    endRevision: "base",
    resolvedStartRevision: 0,
    resolvedEndRevision: 8,
    lineStart: 1,
    lineLimit: 2,
    ignoreWhitespace: "none",
    ignoreEolStyle: false,
    ignoreMimeType: false,
    includeMergedRevisions: false,
    hasMore: true,
    lines: [
      historyBlameLine(),
      {
        ...historyBlameLine(),
        lineNumber: 2,
        revision: 8,
        author: "bob",
        date: "2026-06-23T01:00:00.000000Z",
        mergedRevision: 6,
        mergedAuthor: "carol",
        mergedDate: "2026-06-22T00:00:00.000000Z",
        mergedPath: "/trunk/src/main.c",
        lineBase64: "YmV0YQ==",
        byteLength: 4,
      },
    ],
    source: "libsvn-blame",
  };
}

function historyBlameLine() {
  return {
    lineNumber: 1,
    revision: 7,
    author: "alice",
    date: "2026-06-23T00:00:00.000000Z",
    mergedRevision: null,
    mergedAuthor: null,
    mergedDate: null,
    mergedPath: null,
    lineBase64: "YWxwaGE=",
    byteLength: 5,
    localChange: false,
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
