import { describe, expect, it, vi } from "vitest";
import { ContentGetRpcClient, ContentResponseError } from "../src/content/contentGetRpcClient";
import type { JsonRpcSender } from "../src/status/types";

describe("ContentGetRpcClient", () => {
  it("sends BASE content/get and decodes binary-safe response bytes", async () => {
    const sender = fakeSender({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src/main.c",
      revision: "base",
      contentBase64: "YmFzZQo=",
      byteLength: 5,
      mimeType: "text/plain",
      isBinary: false,
      source: "libsvn-base",
    });
    const client = new ContentGetRpcClient(sender);

    const content = await client.getContent({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src/main.c",
      revision: "base",
    });

    expect(sender.sendRequest).toHaveBeenCalledWith("content/get", {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src/main.c",
      revision: "base",
    });
    expect(Array.from(content.bytes)).toEqual([98, 97, 115, 101, 10]);
    expect(content.byteLength).toBe(5);
    expect(content.mimeType).toBe("text/plain");
    expect(content.isBinary).toBe(false);
    expect(content.source).toBe("libsvn-base");
  });

  it("rejects invalid request paths before sending", async () => {
    const sender = fakeSender({});
    const client = new ContentGetRpcClient(sender);

    await expect(
      client.getContent({
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        path: "../outside.c",
        revision: "base",
      }),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_CONTENT_REQUEST_INVALID",
      safeArgs: { field: "path" },
    });
    expect(sender.sendRequest).not.toHaveBeenCalled();
  });

  it("accepts an empty BASE file response", async () => {
    const sender = fakeSender({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "empty.txt",
      revision: "base",
      contentBase64: "",
      byteLength: 0,
      mimeType: null,
      isBinary: false,
      source: "libsvn-base",
    });
    const client = new ContentGetRpcClient(sender);

    const content = await client.getContent({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "empty.txt",
      revision: "base",
    });

    expect(content.bytes).toHaveLength(0);
    expect(content.byteLength).toBe(0);
  });

  it("sends HEAD content/get and accepts the matching response identity", async () => {
    const sender = fakeSender({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src/main.c",
      revision: "head",
      contentBase64: "aGVhZAo=",
      byteLength: 5,
      mimeType: "text/plain",
      isBinary: false,
      source: "libsvn-head",
    });
    const client = new ContentGetRpcClient(sender);

    const content = await client.getContent({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src/main.c",
      revision: "head",
    });

    expect(sender.sendRequest).toHaveBeenCalledWith("content/get", {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src/main.c",
      revision: "head",
    });
    expect(Array.from(content.bytes)).toEqual([104, 101, 97, 100, 10]);
    expect(content.source).toBe("libsvn-head");
  });

  it("sends explicit revision content/get and accepts the matching response identity", async () => {
    const sender = fakeSender({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src/main.c",
      revision: "r42",
      contentBase64: "cjQyCg==",
      byteLength: 4,
      mimeType: null,
      isBinary: false,
      source: "libsvn-revision",
    });
    const client = new ContentGetRpcClient(sender);

    const content = await client.getContent({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src/main.c",
      revision: "r42",
    });

    expect(sender.sendRequest).toHaveBeenCalledWith("content/get", {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src/main.c",
      revision: "r42",
    });
    expect(Array.from(content.bytes)).toEqual([114, 52, 50, 10]);
    expect(content.source).toBe("libsvn-revision");
  });

  it.each(["HEAD", "42", "r", "r-1", "r01", "r1.5", "r1e3", "r2147483648", "working"])(
    "rejects invalid content revision %j before sending",
    async (revision) => {
      const sender = fakeSender({});
      const client = new ContentGetRpcClient(sender);

      await expect(
        client.getContent({
          repositoryId: "repo-uuid:C:/wc",
          epoch: 7,
          path: "src/main.c",
          revision,
        }),
      ).rejects.toMatchObject({
        code: "SUBVERSIONR_CONTENT_REQUEST_INVALID",
        safeArgs: { field: "revision" },
      });
      expect(sender.sendRequest).not.toHaveBeenCalled();
    },
  );

  it("rejects extra request fields before sending", async () => {
    const sender = fakeSender({});
    const client = new ContentGetRpcClient(sender);
    const request = {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src/main.c",
      revision: "base",
      extra: true,
    };

    await expect(client.getContent(request)).rejects.toMatchObject({
      code: "SUBVERSIONR_CONTENT_REQUEST_INVALID",
      safeArgs: { field: "extra" },
    });
    expect(sender.sendRequest).not.toHaveBeenCalled();
  });

  it("rejects unsupported content response revisions", async () => {
    const sender = fakeSender({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src/main.c",
      revision: "working",
      contentBase64: "d29ya2luZwo=",
      byteLength: 8,
      mimeType: null,
      isBinary: false,
      source: "libsvn-working",
    });
    const client = new ContentGetRpcClient(sender);

    await expect(
      client.getContent({
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        path: "src/main.c",
        revision: "head",
      }),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_CONTENT_RESPONSE_INVALID",
      safeArgs: { field: "revision" },
    });
  });

  it("rejects supported response revisions that do not match the request", async () => {
    const sender = fakeSender({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src/main.c",
      revision: "base",
      contentBase64: "YmFzZQo=",
      byteLength: 5,
      mimeType: null,
      isBinary: false,
      source: "libsvn-base",
    });
    const client = new ContentGetRpcClient(sender);

    await expect(
      client.getContent({
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        path: "src/main.c",
        revision: "head",
      }),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_CONTENT_RESPONSE_INVALID",
      safeArgs: { field: "revision" },
    });
  });

  it("rejects response sources that do not match the requested revision", async () => {
    const sender = fakeSender({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src/main.c",
      revision: "head",
      contentBase64: "aGVhZAo=",
      byteLength: 5,
      mimeType: null,
      isBinary: false,
      source: "libsvn-base",
    });
    const client = new ContentGetRpcClient(sender);

    await expect(
      client.getContent({
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        path: "src/main.c",
        revision: "head",
      }),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_CONTENT_RESPONSE_INVALID",
      safeArgs: { field: "source" },
    });
  });

  it("rejects base64 responses whose byteLength does not match decoded bytes", async () => {
    const sender = fakeSender({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src/main.c",
      revision: "base",
      contentBase64: "YmFzZQo=",
      byteLength: 6,
      mimeType: null,
      isBinary: false,
      source: "libsvn-base",
    });
    const client = new ContentGetRpcClient(sender);

    await expect(
      client.getContent({
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        path: "src/main.c",
        revision: "base",
      }),
    ).rejects.toBeInstanceOf(ContentResponseError);
    await expect(
      client.getContent({
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        path: "src/main.c",
        revision: "base",
      }),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_CONTENT_RESPONSE_INVALID",
      safeArgs: { field: "contentBase64" },
    });
  });

  it("rejects content responses with mismatched identity fields", async () => {
    const sender = fakeSender({
      repositoryId: "other-repo",
      epoch: 7,
      path: "src/main.c",
      revision: "base",
      contentBase64: "YmFzZQo=",
      byteLength: 5,
      mimeType: null,
      isBinary: false,
      source: "libsvn-base",
    });
    const client = new ContentGetRpcClient(sender);

    await expect(
      client.getContent({
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        path: "src/main.c",
        revision: "base",
      }),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_CONTENT_RESPONSE_INVALID",
      safeArgs: { field: "repositoryId" },
    });
  });
});

function fakeSender(result: unknown): JsonRpcSender & {
  sendRequest: ReturnType<typeof vi.fn>;
} {
  const sendRequest = vi.fn(async (_method: string, _params: unknown) => result);
  return {
    sendRequest: sendRequest as unknown as JsonRpcSender["sendRequest"],
  } as JsonRpcSender & { sendRequest: ReturnType<typeof vi.fn> };
}
