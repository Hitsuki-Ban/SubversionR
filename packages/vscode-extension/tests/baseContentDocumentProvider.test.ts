import { describe, expect, it, vi } from "vitest";
import { BaseContentDocumentProvider } from "../src/content/baseContentDocumentProvider";
import { BASE_CONTENT_URI_SCHEME } from "../src/content/baseContentUri";
import type { ContentBlob, ContentClient } from "../src/content/contentGetRpcClient";

describe("BaseContentDocumentProvider", () => {
  it("loads BASE content through content/get and returns readonly text", async () => {
    const client = fakeContentClient({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src/main.c",
      revision: "base",
      bytes: new Uint8Array([98, 97, 115, 101, 10]),
      byteLength: 5,
      mimeType: "text/plain",
      isBinary: false,
      source: "libsvn-base",
    });
    const provider = new BaseContentDocumentProvider({
      contentClient: client,
      localize: (message) => `l10n:${message}`,
    });

    const text = await provider.provideTextDocumentContent(baseUri());

    expect(client.getContent).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src/main.c",
      revision: "base",
    });
    expect(text).toBe("base\n");
  });

  it("returns localized placeholder text for binary BASE content", async () => {
    const client = fakeContentClient({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "image.bin",
      revision: "base",
      bytes: new Uint8Array([0, 1, 2]),
      byteLength: 3,
      mimeType: "application/octet-stream",
      isBinary: true,
      source: "libsvn-base",
    });
    const provider = new BaseContentDocumentProvider({
      contentClient: client,
      localize: (message) => `l10n:${message}`,
    });

    const text = await provider.provideTextDocumentContent({
      scheme: BASE_CONTENT_URI_SCHEME,
      authority: "base",
      path: "/",
      query:
        "repositoryId=repo-uuid%3AC%3A%2Fwc&epoch=7&generation=11&path=image.bin&revision=base",
    });

    expect(text).toBe("l10n:Binary SVN BASE content is not displayed in the text editor.");
  });
});

function fakeContentClient(content: ContentBlob): ContentClient & {
  getContent: ReturnType<typeof vi.fn<(request: unknown) => Promise<ContentBlob>>>;
} {
  return {
    getContent: vi.fn(async () => content),
  };
}

function baseUri() {
  return {
    scheme: BASE_CONTENT_URI_SCHEME,
    authority: "base",
    path: "/",
    query:
      "repositoryId=repo-uuid%3AC%3A%2Fwc&epoch=7&generation=11&path=src%2Fmain.c&revision=base",
  };
}
