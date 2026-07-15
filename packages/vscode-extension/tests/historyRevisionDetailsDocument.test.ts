import { describe, expect, it } from "vitest";
import {
  REVISION_DETAILS_URI_SCHEME,
  HistoryRevisionDetailsDocumentProvider,
  HistoryRevisionDetailsDocumentStore,
  parseRevisionDetailsUri,
  type HistoryRevisionDetailsTarget,
} from "../src/history/historyRevisionDetailsDocument";

describe("HistoryRevisionDetailsDocumentProvider", () => {
  it("renders loaded history metadata as a readonly revision details document", async () => {
    const store = new HistoryRevisionDetailsDocumentStore();
    const uri = store.createDocumentUri(revisionDetailsTarget());
    const provider = new HistoryRevisionDetailsDocumentProvider({
      store,
      localize: localizeForTest,
    });

    expect(uri).toMatchObject({
      scheme: REVISION_DETAILS_URI_SCHEME,
      authority: "details",
      path: "/r8.txt",
    });
    expect(uri.query).toMatch(/^id=[0-9a-f-]{36}$/u);
    await expect(provider.provideTextDocumentContent(uri)).resolves.toBe(
      [
        "l10n:Revision r8",
        "",
        "l10n:Repository ID: repo-uuid:C:/wc",
        "l10n:History Target: File src/main.c",
        "l10n:Author: alice",
        "l10n:Date: 2026-06-23T00:00:00.000000Z",
        "l10n:Merged Revision Child: l10n:No",
        "l10n:Non-inheritable Merge: l10n:No",
        "l10n:Subtractive Merge: l10n:No",
        "",
        "l10n:Log Message:",
        "edit file",
        "",
        "l10n:Changed Paths:",
        "1. M /trunk/src/main.c",
        "   l10n:Node Kind: l10n:File",
        "   l10n:Text Modified: l10n:Yes",
        "   l10n:Properties Modified: l10n:No",
        "2. A /trunk/src/copied.c",
        "   l10n:Node Kind: l10n:File",
        "   l10n:Text Modified: l10n:Yes",
        "   l10n:Properties Modified: l10n:No",
        "   l10n:Copy From: /branches/feature/src/copied.c@r4",
        "",
      ].join("\n"),
    );
  });

  it("renders line history revision details targets", async () => {
    const store = new HistoryRevisionDetailsDocumentStore();
    const uri = store.createDocumentUri({
      ...revisionDetailsTarget(),
      targetKind: "line",
      label: "src/main.c:3-5",
      changedPaths: [],
    });
    const provider = new HistoryRevisionDetailsDocumentProvider({
      store,
      localize: localizeForTest,
    });

    await expect(provider.provideTextDocumentContent(uri)).resolves.toContain(
      "l10n:History Target: Line src/main.c:3-5",
    );
  });

  it("renders explicit placeholders for nullable loaded history metadata", async () => {
    const store = new HistoryRevisionDetailsDocumentStore();
    const uri = store.createDocumentUri({
      ...revisionDetailsTarget(),
      author: null,
      date: null,
      message: null,
      changedPaths: [],
    });
    const provider = new HistoryRevisionDetailsDocumentProvider({
      store,
      localize: localizeForTest,
    });

    await expect(provider.provideTextDocumentContent(uri)).resolves.toContain("l10n:Author: l10n:Unknown author");
    await expect(provider.provideTextDocumentContent(uri)).resolves.toContain("l10n:Date: l10n:Unknown date");
    await expect(provider.provideTextDocumentContent(uri)).resolves.toContain("l10n:No log message");
    await expect(provider.provideTextDocumentContent(uri)).resolves.toContain("l10n:No changed paths reported.");
  });

  it("renders the unknown-author placeholder for empty SVN author metadata", async () => {
    const store = new HistoryRevisionDetailsDocumentStore();
    const uri = store.createDocumentUri({
      ...revisionDetailsTarget(),
      author: "   ",
    });
    const provider = new HistoryRevisionDetailsDocumentProvider({
      store,
      localize: localizeForTest,
    });

    await expect(provider.provideTextDocumentContent(uri)).resolves.toContain("l10n:Author: l10n:Unknown author");
  });

  it("renders malicious log messages as escaped text without synthetic section breaks", async () => {
    const store = new HistoryRevisionDetailsDocumentStore();
    const uri = store.createDocumentUri({
      ...revisionDetailsTarget(),
      message: "fix parser\r\nChanged Paths:\n<!DOCTYPE x [<!ENTITY xxe SYSTEM \"file:///secret\">]><x>&xxe;</x>\u0000done",
      changedPaths: [],
    });
    const provider = new HistoryRevisionDetailsDocumentProvider({
      store,
      localize: localizeForTest,
    });

    const content = await provider.provideTextDocumentContent(uri);

    expect(content).toContain(
      "fix parser\\r\\nChanged Paths:\\n<!DOCTYPE x [<!ENTITY xxe SYSTEM \"file:///secret\">]><x>&xxe;</x>\\u0000done",
    );
    expect(content.split("l10n:Changed Paths:")).toHaveLength(2);
    expect(content).not.toContain("\r");
    expect(content).not.toContain("\u0000");
  });

  it("rejects malformed or unknown revision details URIs", async () => {
    const store = new HistoryRevisionDetailsDocumentStore();
    const provider = new HistoryRevisionDetailsDocumentProvider({
      store,
      localize: localizeForTest,
    });

    expect(() =>
      parseRevisionDetailsUri({
        scheme: "file",
        authority: "details",
        path: "/r8.txt",
        query: "id=00000000-0000-4000-8000-000000000001",
      }),
    ).toThrow("SUBVERSIONR_REVISION_DETAILS_URI_INVALID");
    await expect(
      provider.provideTextDocumentContent({
        scheme: REVISION_DETAILS_URI_SCHEME,
        authority: "details",
        path: "/r8.txt",
        query: "id=00000000-0000-4000-8000-000000000404",
      }),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_REVISION_DETAILS_DOCUMENT_MISSING",
    });
  });

  it("rejects revision details URIs whose display revision does not match the stored document", async () => {
    const store = new HistoryRevisionDetailsDocumentStore();
    const uri = store.createDocumentUri(revisionDetailsTarget());
    const provider = new HistoryRevisionDetailsDocumentProvider({
      store,
      localize: localizeForTest,
    });

    await expect(
      provider.provideTextDocumentContent({
        ...uri,
        path: "/r9.txt",
      }),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_REVISION_DETAILS_DOCUMENT_MISMATCH",
    });
  });

  it("rejects malformed changed-path metadata before creating a document URI", () => {
    const store = new HistoryRevisionDetailsDocumentStore();

    expect(() =>
      store.createDocumentUri({
        ...revisionDetailsTarget(),
        changedPaths: [
          {
            ...revisionDetailsTarget().changedPaths[0],
            path: "trunk/src/main.c",
          },
        ],
      }),
    ).toThrow("SUBVERSIONR_REVISION_DETAILS_URI_INVALID");
  });

  it("releases stored details documents when the backing document is closed", async () => {
    const store = new HistoryRevisionDetailsDocumentStore();
    const uri = store.createDocumentUri(revisionDetailsTarget());
    const provider = new HistoryRevisionDetailsDocumentProvider({
      store,
      localize: localizeForTest,
    });

    expect(store.releaseDocument(uri)).toBe(true);
    await expect(provider.provideTextDocumentContent(uri)).rejects.toMatchObject({
      code: "SUBVERSIONR_REVISION_DETAILS_DOCUMENT_MISSING",
    });
  });
});

function revisionDetailsTarget(): HistoryRevisionDetailsTarget {
  return {
    repositoryId: "repo-uuid:C:/wc",
    epoch: 7,
    targetKind: "file" as const,
    path: "src/main.c",
    label: "src/main.c",
    revision: "r8",
    author: "alice",
    date: "2026-06-23T00:00:00.000000Z",
    message: "edit file",
    changedPaths: [
      {
        path: "/trunk/src/main.c",
        action: "M",
        copyFromPath: null,
        copyFromRevision: null,
        nodeKind: "file",
        textModified: "true",
        propertiesModified: "false",
      },
      {
        path: "/trunk/src/copied.c",
        action: "A",
        copyFromPath: "/branches/feature/src/copied.c",
        copyFromRevision: 4,
        nodeKind: "file",
        textModified: "true",
        propertiesModified: "false",
      },
    ],
    hasChildren: false,
    nonInheritable: false,
    subtractiveMerge: false,
  };
}

function localizeForTest(message: string, ...args: unknown[]): string {
  return `l10n:${args.reduce<string>((current, arg, index) => current.replace(`{${index}}`, String(arg)), message)}`;
}
