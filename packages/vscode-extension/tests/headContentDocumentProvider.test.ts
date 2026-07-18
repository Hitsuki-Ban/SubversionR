import { describe, expect, it, vi } from "vitest";
import { HeadContentDocumentProvider } from "../src/content/headContentDocumentProvider";
import { HEAD_CONTENT_URI_SCHEME } from "../src/content/headContentUri";
import type { ContentBlob, ContentClient } from "../src/content/contentGetRpcClient";
import { anonymousSvnRemoteEnvelope } from "./remoteOperationEnvelopeFixture";

describe("HeadContentDocumentProvider", () => {
  it("loads HEAD content through content/get and returns readonly text", async () => {
    const client = fakeContentClient({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src/main.c",
      revision: "head" as ContentBlob["revision"],
      bytes: new Uint8Array([104, 101, 97, 100, 10]),
      byteLength: 5,
      mimeType: "text/plain",
      isBinary: false,
      source: "libsvn-head",
    });
    const provider = new HeadContentDocumentProvider({
      contentClient: client,
      createRemoteEnvelope: async () => anonymousSvnRemoteEnvelope(),
      workspaceTrusted: () => true,
      localize: (message, ...args) =>
        `l10n:${args.reduce<string>((current, arg, index) => current.replace(`{${index}}`, String(arg)), message)}`,
    });

    const text = await provider.provideTextDocumentContent(headUri(), cancellationToken());

    expect(client.getContent).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src/main.c",
      revision: "head",
      remote: anonymousSvnRemoteEnvelope(),
    }, { signal: expect.any(AbortSignal) });
    expect(text).toBe("head\n");
  });

  it("returns localized placeholder text for binary HEAD content", async () => {
    const client = fakeContentClient({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "image.bin",
      revision: "head" as ContentBlob["revision"],
      bytes: new Uint8Array([0, 1, 2]),
      byteLength: 3,
      mimeType: "application/octet-stream",
      isBinary: true,
      source: "libsvn-head",
    });
    const provider = new HeadContentDocumentProvider({
      contentClient: client,
      createRemoteEnvelope: async () => undefined,
      workspaceTrusted: () => true,
      localize: (message, ...args) =>
        `l10n:${args.reduce<string>((current, arg, index) => current.replace(`{${index}}`, String(arg)), message)}`,
    });

    const text = await provider.provideTextDocumentContent({
      scheme: HEAD_CONTENT_URI_SCHEME,
      authority: "head",
      path: "/",
      query:
        "repositoryId=repo-uuid%3AC%3A%2Fwc&epoch=7&generation=11&path=image.bin&revision=head&requestId=11111111-1111-4111-8111-111111111111",
    }, cancellationToken());

    expect(client.getContent).toHaveBeenCalledWith(
      {
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        path: "image.bin",
        revision: "head",
      },
      { signal: expect.any(AbortSignal) },
    );
    expect(text).toBe("l10n:Binary SVN HEAD content is not displayed in the text editor: image.bin");
  });

  it("rejects HEAD content in untrusted workspaces before content/get", async () => {
    const client = fakeContentClient({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src/main.c",
      revision: "head" as ContentBlob["revision"],
      bytes: new Uint8Array([104, 101, 97, 100, 10]),
      byteLength: 5,
      mimeType: "text/plain",
      isBinary: false,
      source: "libsvn-head",
    });
    const provider = new HeadContentDocumentProvider({
      contentClient: client,
      createRemoteEnvelope: async () => anonymousSvnRemoteEnvelope(),
      workspaceTrusted: () => false,
      localize: (message, ...args) =>
        `l10n:${args.reduce<string>((current, arg, index) => current.replace(`{${index}}`, String(arg)), message)}`,
    });

    await expect(provider.provideTextDocumentContent(headUri(), cancellationToken())).rejects.toMatchObject({
      code: "SUBVERSIONR_WORKSPACE_UNTRUSTED_OPERATION",
    });
    expect(client.getContent).not.toHaveBeenCalled();
  });
});

function fakeContentClient(content: ContentBlob): ContentClient & {
  getContent: ReturnType<typeof vi.fn<(request: unknown) => Promise<ContentBlob>>>;
} {
  return {
    getContent: vi.fn(async () => content),
  };
}

function headUri() {
  return {
    scheme: HEAD_CONTENT_URI_SCHEME,
    authority: "head",
    path: "/",
    query:
      "repositoryId=repo-uuid%3AC%3A%2Fwc&epoch=7&generation=11&path=src%2Fmain.c&revision=head&requestId=11111111-1111-4111-8111-111111111111",
  };
}

function cancellationToken() {
  return {
    isCancellationRequested: false,
    onCancellationRequested: vi.fn(() => ({ dispose: vi.fn() })),
  };
}
