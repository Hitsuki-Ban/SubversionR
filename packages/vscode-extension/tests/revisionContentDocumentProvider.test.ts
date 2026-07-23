import { describe, expect, it, vi } from "vitest";
import { RevisionContentDocumentProvider } from "../src/content/revisionContentDocumentProvider";
import { REVISION_CONTENT_URI_SCHEME } from "../src/content/revisionContentUri";
import type { ContentBlob, ContentClient } from "../src/content/contentGetRpcClient";
import { anonymousSvnRemoteEnvelope } from "./remoteOperationEnvelopeFixture";

describe("RevisionContentDocumentProvider", () => {
  it("loads explicit revision content through content/get and returns readonly text", async () => {
    const client = fakeContentClient({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src/main.c",
      revision: "r8" as ContentBlob["revision"],
      bytes: new Uint8Array([114, 101, 118, 10]),
      byteLength: 4,
      mimeType: "text/plain",
      isBinary: false,
      source: "libsvn-revision",
    });
    const provider = new RevisionContentDocumentProvider({
      contentClient: client,
      createRemoteEnvelope: async () => anonymousSvnRemoteEnvelope(),
      workspaceTrusted: () => true,
      localize: (message, ...args) =>
        `l10n:${args.reduce<string>((current, arg, index) => current.replace(`{${index}}`, String(arg)), message)}`,
    });

    const text = await provider.provideTextDocumentContent(revisionUri(), cancellationToken());

    expect(client.getContent).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src/main.c",
      revision: "r8",
      remote: anonymousSvnRemoteEnvelope(),
    }, { signal: expect.any(AbortSignal) });
    expect(text).toBe("rev\n");
  });

  it("returns localized placeholder text for binary explicit revision content", async () => {
    const client = fakeContentClient({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "image.bin",
      revision: "r8" as ContentBlob["revision"],
      bytes: new Uint8Array([0, 1, 2]),
      byteLength: 3,
      mimeType: "application/octet-stream",
      isBinary: true,
      source: "libsvn-revision",
    });
    const provider = new RevisionContentDocumentProvider({
      contentClient: client,
      createRemoteEnvelope: async () => undefined,
      workspaceTrusted: () => true,
      localize: (message, ...args) =>
        `l10n:${args.reduce<string>((current, arg, index) => current.replace(`{${index}}`, String(arg)), message)}`,
    });

    const text = await provider.provideTextDocumentContent({
      scheme: REVISION_CONTENT_URI_SCHEME,
      authority: "revision",
      path: "/",
      query: "repositoryId=repo-uuid%3AC%3A%2Fwc&epoch=7&path=image.bin&revision=r8",
    }, cancellationToken());

    expect(client.getContent).toHaveBeenCalledWith(
      {
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        path: "image.bin",
        revision: "r8",
      },
      { signal: expect.any(AbortSignal) },
    );
    expect(text).toBe("l10n:Binary SVN revision content is not displayed in the text editor: image.bin@r8");
  });

  it("rejects explicit revision content in untrusted workspaces before content/get", async () => {
    const client = fakeContentClient({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src/main.c",
      revision: "r8" as ContentBlob["revision"],
      bytes: new Uint8Array([114, 101, 118, 10]),
      byteLength: 4,
      mimeType: "text/plain",
      isBinary: false,
      source: "libsvn-revision",
    });
    const provider = new RevisionContentDocumentProvider({
      contentClient: client,
      createRemoteEnvelope: async () => anonymousSvnRemoteEnvelope(),
      workspaceTrusted: () => false,
      localize: (message, ...args) =>
        `l10n:${args.reduce<string>((current, arg, index) => current.replace(`{${index}}`, String(arg)), message)}`,
    });

    await expect(provider.provideTextDocumentContent(revisionUri(), cancellationToken())).rejects.toMatchObject({
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

function revisionUri() {
  return {
    scheme: REVISION_CONTENT_URI_SCHEME,
    authority: "revision",
    path: "/",
    query: "repositoryId=repo-uuid%3AC%3A%2Fwc&epoch=7&path=src%2Fmain.c&revision=r8",
  };
}

function cancellationToken() {
  return {
    isCancellationRequested: false,
    onCancellationRequested: vi.fn(() => ({ dispose: vi.fn() })),
  };
}
