import { Buffer } from "node:buffer";
import { describe, expect, it, vi } from "vitest";
import {
  BLAME_DOCUMENT_URI_SCHEME,
  HistoryBlameDocumentProvider,
  createBlameDocumentUriComponents,
  parseBlameDocumentUri,
  type HistoryBlameDocumentRequest,
} from "../src/history/historyBlameDocument";
import type { HistoryBlame, HistoryBlameClient, HistoryBlameRequest } from "../src/history/historyBlameRpcClient";

describe("history blame document helpers", () => {
  it("encodes blame request identity into a custom URI with generation-based invalidation", () => {
    const uri = createBlameDocumentUriComponents(blameDocumentRequest());

    expect(uri).toEqual({
      scheme: BLAME_DOCUMENT_URI_SCHEME,
      authority: "blame",
      path: "/",
      query:
        "repositoryId=repo-uuid%3AC%3A%2Fwc&epoch=7&generation=11&path=src%2Fmain.c&pegRevision=base&startRevision=r0&endRevision=base&lineStart=1&lineLimit=5000&ignoreWhitespace=none&ignoreEolStyle=false&ignoreMimeType=false&includeMergedRevisions=false",
    });
  });

  it("parses a blame document URI into a strict history/blame request", () => {
    const request = parseBlameDocumentUri({
      scheme: BLAME_DOCUMENT_URI_SCHEME,
      authority: "blame",
      path: "/",
      query:
        "repositoryId=repo-uuid%3AC%3A%2Fwc&epoch=7&generation=11&path=src%2Fmain.c&pegRevision=base&startRevision=r0&endRevision=base&lineStart=1&lineLimit=5000&ignoreWhitespace=none&ignoreEolStyle=false&ignoreMimeType=false&includeMergedRevisions=false",
    });

    expect(request).toEqual(blameDocumentRequest());
  });

  it("encodes merged-revision blame requests and passes them through to history/blame", async () => {
    const request = blameDocumentRequest({ includeMergedRevisions: true });
    const uri = createBlameDocumentUriComponents(request);
    const blameClient = fakeBlameClient({ ...blameResponse(), includeMergedRevisions: true });
    const provider = new HistoryBlameDocumentProvider({
      blameClient,
      workspaceTrusted: () => true,
      localize: localizeForTest,
    });

    expect(parseBlameDocumentUri(uri)).toEqual(request);
    await provider.provideTextDocumentContent(uri);

    expect(blameClient.getBlame).toHaveBeenCalledWith(blameRpcRequest({ includeMergedRevisions: true }));
  });

  it("rejects malformed blame document URIs and duplicate query keys", () => {
    expect(() =>
      parseBlameDocumentUri({
        scheme: "file",
        authority: "blame",
        path: "/",
        query:
          "repositoryId=repo-uuid%3AC%3A%2Fwc&epoch=7&generation=11&path=src%2Fmain.c&pegRevision=base&startRevision=r0&endRevision=base&lineStart=1&lineLimit=5000&ignoreWhitespace=none&ignoreEolStyle=false&ignoreMimeType=false&includeMergedRevisions=false",
      }),
    ).toThrow("SUBVERSIONR_BLAME_DOCUMENT_URI_INVALID");
    expect(() =>
      parseBlameDocumentUri({
        scheme: BLAME_DOCUMENT_URI_SCHEME,
        authority: "blame",
        path: "/",
        query:
          "repositoryId=repo-uuid%3AC%3A%2Fwc&repositoryId=other&epoch=7&generation=11&path=src%2Fmain.c&pegRevision=base&startRevision=r0&endRevision=base&lineStart=1&lineLimit=5000&ignoreWhitespace=none&ignoreEolStyle=false&ignoreMimeType=false&includeMergedRevisions=false",
      }),
    ).toThrow("SUBVERSIONR_BLAME_DOCUMENT_URI_INVALID");
  });

  it("rejects blame document URI parameters outside the fixed M5k BASE blame contract", () => {
    const variants: Array<Partial<HistoryBlameDocumentRequest>> = [
      { pegRevision: "head" },
      { startRevision: "r1" },
      { endRevision: "r8" },
      { lineStart: 2 },
      { lineLimit: 100 },
      { ignoreWhitespace: "all" },
      { ignoreEolStyle: true },
      { ignoreMimeType: true },
    ];

    variants.forEach((variant) => {
      expect(() => createBlameDocumentUriComponents({ ...blameDocumentRequest(), ...variant })).toThrow(
        "SUBVERSIONR_BLAME_DOCUMENT_URI_INVALID",
      );
    });
  });

  it.each(["", ".", "src\\main.c", "../outside.c", "/trunk/main.c", "C:/wc/main.c", "src//main.c"])(
    "rejects invalid blame document path %j",
    (path) => {
      expect(() => createBlameDocumentUriComponents({ ...blameDocumentRequest(), path })).toThrow(
        "SUBVERSIONR_BLAME_DOCUMENT_URI_INVALID",
      );
    },
  );
});

describe("HistoryBlameDocumentProvider", () => {
  it("loads file blame through history/blame and renders a localized readonly document", async () => {
    const blameClient = fakeBlameClient(blameResponse());
    const provider = new HistoryBlameDocumentProvider({
      blameClient,
      workspaceTrusted: () => true,
      localize: localizeForTest,
    });

    const text = await provider.provideTextDocumentContent(createBlameDocumentUriComponents(blameDocumentRequest()));

    expect(blameClient.getBlame).toHaveBeenCalledWith(blameRpcRequest());
    expect(text).toBe(
      [
        "l10n:SVN Blame: src/main.c",
        "",
        "l10n:Repository ID: repo-uuid:C:/wc",
        "l10n:Revision Range: r0 - base",
        "l10n:Resolved Revision Range: r1 - r8",
        "l10n:Line Window: 1 - 5000",
        "l10n:Has More Lines: l10n:No",
        "",
        "1 | r4 | alice | 2026-06-23T00:00:00.000000Z | int main()",
        "2 | l10n:Uncommitted | l10n:Unknown author | l10n:Unknown date |   return 0;",
        "3 | r7 (l10n:Merged from r6) | bob | 2026-06-24T00:00:00.000000Z | }",
        "",
      ].join("\n"),
    );
  });

  it("renders nullable non-local blame revisions as unknown instead of uncommitted", async () => {
    const blameClient = fakeBlameClient({
      ...blameResponse(),
      lines: [
        blameLine({
          lineNumber: 1,
          localChange: false,
          revision: null,
          author: null,
          date: null,
          line: "legacy line",
        }),
      ],
    });
    const provider = new HistoryBlameDocumentProvider({
      blameClient,
      workspaceTrusted: () => true,
      localize: localizeForTest,
    });

    const text = await provider.provideTextDocumentContent(createBlameDocumentUriComponents(blameDocumentRequest()));

    expect(text).toContain("1 | l10n:Unknown | l10n:Unknown author | l10n:Unknown date | legacy line");
  });

  it("rejects blame documents in untrusted workspaces before history/blame", async () => {
    const blameClient = fakeBlameClient(blameResponse());
    const provider = new HistoryBlameDocumentProvider({
      blameClient,
      workspaceTrusted: () => false,
      localize: localizeForTest,
    });

    await expect(provider.provideTextDocumentContent(createBlameDocumentUriComponents(blameDocumentRequest()))).rejects.toMatchObject({
      code: "SUBVERSIONR_WORKSPACE_UNTRUSTED_OPERATION",
    });
    expect(blameClient.getBlame).not.toHaveBeenCalled();
  });
});

function blameDocumentRequest(overrides: Partial<HistoryBlameDocumentRequest> = {}): HistoryBlameDocumentRequest {
  return {
    repositoryId: "repo-uuid:C:/wc",
    epoch: 7,
    generation: 11,
    path: "src/main.c",
    pegRevision: "base",
    startRevision: "r0" as HistoryBlame["startRevision"],
    endRevision: "base",
    lineStart: 1,
    lineLimit: 5000,
    ignoreWhitespace: "none",
    ignoreEolStyle: false,
    ignoreMimeType: false,
    includeMergedRevisions: false,
    ...overrides,
  };
}

function blameRpcRequest(overrides: Partial<HistoryBlameRequest> = {}): HistoryBlameRequest {
  const { generation: _generation, ...request } = blameDocumentRequest();
  return {
    ...request,
    ...overrides,
  };
}

function blameResponse(): HistoryBlame {
  return {
    repositoryId: "repo-uuid:C:/wc",
    epoch: 7,
    path: "src/main.c",
    pegRevision: "base",
    startRevision: "r0" as HistoryBlame["startRevision"],
    endRevision: "base",
    resolvedStartRevision: 1,
    resolvedEndRevision: 8,
    lineStart: 1,
    lineLimit: 5000,
    ignoreWhitespace: "none",
    ignoreEolStyle: false,
    ignoreMimeType: false,
    includeMergedRevisions: false,
    hasMore: false,
    lines: [
      blameLine({ lineNumber: 1, revision: 4, author: "alice", date: "2026-06-23T00:00:00.000000Z", line: "int main()" }),
      blameLine({ lineNumber: 2, localChange: true, revision: null, author: null, date: null, line: "  return 0;" }),
      blameLine({
        lineNumber: 3,
        revision: 7,
        author: "bob",
        date: "2026-06-24T00:00:00.000000Z",
        mergedRevision: 6,
        mergedAuthor: "carol",
        mergedDate: "2026-06-21T00:00:00.000000Z",
        mergedPath: "/branches/feature/src/main.c",
        line: "}",
      }),
    ],
    source: "libsvn-blame",
  };
}

function blameLine(
  overrides: Partial<HistoryBlame["lines"][number]> & { lineNumber: number; line: string },
): HistoryBlame["lines"][number] {
  const bytes = Buffer.from(overrides.line, "utf8");
  return {
    lineNumber: overrides.lineNumber,
    revision: "revision" in overrides ? (overrides.revision ?? null) : 4,
    author: "author" in overrides ? (overrides.author ?? null) : "alice",
    date: "date" in overrides ? (overrides.date ?? null) : "2026-06-23T00:00:00.000000Z",
    mergedRevision: "mergedRevision" in overrides ? (overrides.mergedRevision ?? null) : null,
    mergedAuthor: "mergedAuthor" in overrides ? (overrides.mergedAuthor ?? null) : null,
    mergedDate: "mergedDate" in overrides ? (overrides.mergedDate ?? null) : null,
    mergedPath: "mergedPath" in overrides ? (overrides.mergedPath ?? null) : null,
    lineBase64: bytes.toString("base64"),
    byteLength: bytes.byteLength,
    localChange: overrides.localChange ?? false,
  };
}

function fakeBlameClient(blame: HistoryBlame): HistoryBlameClient & {
  getBlame: ReturnType<typeof vi.fn<(request: unknown) => Promise<HistoryBlame>>>;
} {
  return {
    getBlame: vi.fn(async () => blame),
  };
}

function localizeForTest(message: string, ...args: unknown[]): string {
  return `l10n:${args.reduce<string>((current, arg, index) => current.replace(`{${index}}`, String(arg)), message)}`;
}
