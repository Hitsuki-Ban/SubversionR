import { describe, expect, it, vi } from "vitest";
import {
  HistoryTreeDataProvider,
  type HistoryTreeApi,
} from "../src/history/historyTreeDataProvider";
import type {
  HistoryClient,
  HistoryClientOptions,
  HistoryLog,
  HistoryLogRequest,
} from "../src/history/historyLogRpcClient";
import { anonymousSvnRemoteEnvelope } from "./remoteOperationEnvelopeFixture";

describe("HistoryTreeDataProvider", () => {
  it("loads repository history through bounded explicit history/log parameters", async () => {
    const historyClient = fakeHistoryClient(
      historyLog({
        path: ".",
        limit: 2,
        entries: [
          historyEntry({ revision: 8, message: "edit project" }),
          historyEntry({ revision: 7, message: "add file" }),
        ],
      }),
    );
    const provider = historyProvider(historyClient, { pageSize: 2, includeMergedRevisions: true });

    await provider.showHistory({
      kind: "repository",
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: ".",
      label: "C:/wc",
    });

    expect(historyClient.getLog).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: ".",
      startRevision: "head",
      endRevision: "r0",
      limit: 2,
      discoverChangedPaths: true,
      strictNodeHistory: false,
      includeMergedRevisions: true,
      remote: anonymousSvnRemoteEnvelope(),
    }, { signal: expect.any(AbortSignal) });
    const roots = await provider.getChildren();
    expect(provider.getTreeItem(roots[0])).toMatchObject({
      label: "C:/wc",
      collapsibleState: 2,
    });
    expect(provider.getTreeItem(roots[0])).not.toHaveProperty("description");
    const children = await provider.getChildren(roots[0]);
    const treeItems = children.map((child) => provider.getTreeItem(child));
    expect(treeItems).toMatchObject([
      {
        label: "r8",
        description: "alice 2026-06-23 edit project",
        collapsibleState: 1,
        contextValue: "subversionr.history.repositoryRevision",
      },
      {
        label: "r7",
        description: "alice 2026-06-23 add file",
        collapsibleState: 1,
      },
      {
        label: "l10n:Load More",
        collapsibleState: 0,
        command: {
          command: "subversionr.history.loadMore",
          title: "l10n:Load More",
        },
      },
    ]);
    expect(treeItems[0]?.command).toMatchObject({
      command: "subversionr.history.openRevisionDetails",
      title: "l10n:Open Revision Details",
    });
  });

  it.each([null, "", "   "])("renders an unknown author for missing or empty SVN author metadata", async (author) => {
    const provider = historyProvider(
      fakeHistoryClient(historyLog({
        path: ".",
        entries: [historyEntry({ author })],
      })),
      { pageSize: 25, includeMergedRevisions: false },
    );

    await provider.showHistory({
      kind: "repository",
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: ".",
      label: "C:/wc",
    });

    const [target] = await provider.getChildren();
    const [revision] = await provider.getChildren(target);
    expect(provider.getTreeItem(revision).description).toContain("l10n:Unknown author");
  });

  it("provides the exact parent chain required by the VS Code reveal API", async () => {
    const provider = historyProvider(
      fakeHistoryClient(historyLog({ path: ".", limit: 1 })),
      { pageSize: 1, includeMergedRevisions: false },
    );
    await provider.showHistory(historyTarget());

    const [target] = await provider.getChildren();
    const [revision, loadMore] = await provider.getChildren(target);
    const [changedPath] = await provider.getChildren(revision);

    expect(provider.getParent(target)).toBeUndefined();
    expect(provider.getParent(revision)).toBe(target);
    expect(provider.getParent(changedPath)).toBe(revision);
    expect(provider.getParent(loadMore)).toBe(target);
  });

  it("loads file history with copy-following SVN semantics and appends older pages", async () => {
    const historyClient = fakeHistoryClient(
      historyLog({
        path: "src/main.c",
        limit: 1,
        entries: [historyEntry({ revision: 8, message: "edit file" })],
      }),
      historyLog({
        path: "src/main.c",
        startRevision: "r7" as HistoryLog["startRevision"],
        limit: 1,
        entries: [historyEntry({ revision: 5, message: "copy file" })],
      }),
    );
    const provider = historyProvider(historyClient, { pageSize: 1, includeMergedRevisions: false });

    await provider.showHistory({
      kind: "file",
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src/main.c",
      label: "src/main.c",
    });
    await provider.loadMore();

    expect(historyClient.getLog).toHaveBeenNthCalledWith(1, {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src/main.c",
      startRevision: "head",
      endRevision: "r0",
      limit: 1,
      discoverChangedPaths: true,
      strictNodeHistory: false,
      includeMergedRevisions: false,
      remote: anonymousSvnRemoteEnvelope(),
    }, { signal: expect.any(AbortSignal) });
    expect(historyClient.getLog).toHaveBeenNthCalledWith(2, {
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src/main.c",
      startRevision: "r7",
      endRevision: "r0",
      limit: 1,
      discoverChangedPaths: true,
      strictNodeHistory: false,
      includeMergedRevisions: false,
      remote: anonymousSvnRemoteEnvelope(),
    }, { signal: expect.any(AbortSignal) });

    const [target] = await provider.getChildren();
    const children = await provider.getChildren(target);
    expect(children.map((child) => provider.getTreeItem(child).label)).toEqual([
      "r8",
      "r5",
      "l10n:Load More",
    ]);
  });

  it("adds an Open Revision command to file history revision rows", async () => {
    const historyClient = fakeHistoryClient(
      historyLog({
        path: "src/main.c",
        entries: [historyEntry({ revision: 8, message: "edit file" })],
      }),
    );
    const provider = historyProvider(historyClient);

    await provider.showHistory(historyTarget());

    const [target] = await provider.getChildren();
    const [revision] = await provider.getChildren(target);
    const treeItem = provider.getTreeItem(revision);
    expect(treeItem).toMatchObject({
      label: "r8",
      contextValue: "subversionr.history.fileRevision",
      command: {
        command: "subversionr.history.openRevision",
        title: "l10n:Open Revision",
      },
    });
    expect(treeItem.command?.arguments).toEqual([revision]);
    expect(provider.openRevisionTarget(revision)).toEqual({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src/main.c",
      revision: "r8",
      label: "src/main.c@r8",
    });
  });

  it("blocks remote history loading and revision content targets in untrusted workspaces", async () => {
    let workspaceTrusted = false;
    const historyClient = fakeHistoryClient(
      historyLog({
        path: "src/main.c",
        limit: 1,
        entries: [historyEntry({ revision: 8, message: "edit file" })],
      }),
      historyLog({
        path: "src/main.c",
        startRevision: "r7" as HistoryLog["startRevision"],
        limit: 1,
        entries: [historyEntry({ revision: 5, message: "copy file" })],
      }),
    );
    const provider = historyProvider(historyClient, { pageSize: 1, includeMergedRevisions: false }, {
      workspaceTrusted: () => workspaceTrusted,
    });

    await expect(provider.showHistory(historyTarget())).rejects.toMatchObject({
      code: "SUBVERSIONR_WORKSPACE_UNTRUSTED_OPERATION",
    });
    expect(historyClient.getLog).not.toHaveBeenCalled();

    workspaceTrusted = true;
    await provider.showHistory(historyTarget());
    workspaceTrusted = false;

    await expect(provider.loadMore()).rejects.toMatchObject({
      code: "SUBVERSIONR_WORKSPACE_UNTRUSTED_OPERATION",
    });
    expect(historyClient.getLog).toHaveBeenCalledTimes(1);

    const [target] = await provider.getChildren();
    const [revision] = await provider.getChildren(target);
    expect(provider.getTreeItem(revision)).toMatchObject({
      command: {
        command: "subversionr.history.openRevisionDetails",
      },
    });
    expect(() => provider.openRevisionTarget(revision)).toThrow(
      expect.objectContaining({ code: "SUBVERSIONR_WORKSPACE_UNTRUSTED_OPERATION" }),
    );
    expect(() => provider.compareRevisionTarget(revision)).toThrow(
      expect.objectContaining({ code: "SUBVERSIONR_WORKSPACE_UNTRUSTED_OPERATION" }),
    );
    expect(() => provider.compareRevisionsTarget(revision, [revision, revision])).toThrow(
      expect.objectContaining({ code: "SUBVERSIONR_WORKSPACE_UNTRUSTED_OPERATION" }),
    );
    expect(provider.revisionDetailsTarget(revision)).toMatchObject({
      revision: "r8",
      targetKind: "file",
    });
  });

  it("rerenders loaded history items on workspace trust refresh without loading remote history", async () => {
    let workspaceTrusted = true;
    const fire = vi.fn();
    const historyClient = fakeHistoryClient(
      historyLog({
        path: "src/main.c",
        entries: [historyEntry({ revision: 8, message: "edit file" })],
      }),
    );
    const provider = historyProvider(historyClient, undefined, {
      workspaceTrusted: () => workspaceTrusted,
      api: fakeTreeApi({ fire }),
    });

    await provider.showHistory(historyTarget());
    expect(historyClient.getLog).toHaveBeenCalledTimes(1);
    fire.mockClear();

    workspaceTrusted = false;
    provider.refreshWorkspaceTrust();

    expect(fire).toHaveBeenCalledWith(undefined);
    expect(historyClient.getLog).toHaveBeenCalledTimes(1);

    const [target] = await provider.getChildren();
    const [revision] = await provider.getChildren(target);
    expect(provider.getTreeItem(revision).command).toMatchObject({
      command: "subversionr.history.openRevisionDetails",
    });
  });

  it("reloads the current backend history target when history settings change", async () => {
    const fire = vi.fn();
    const historyClient = fakeHistoryClient(
      historyLog({
        limit: 1,
        entries: [historyEntry({ revision: 8, message: "initial page" })],
      }),
      historyLog({
        limit: 2,
        entries: [
          historyEntry({ revision: 8, message: "updated page" }),
          historyEntry({ revision: 7, message: "merged history" }),
        ],
      }),
    );
    const provider = historyProvider(
      historyClient,
      { pageSize: 1, includeMergedRevisions: false },
      { api: fakeTreeApi({ fire }) },
    );

    await provider.showHistory(historyTarget());
    fire.mockClear();
    await provider.updateSettings({ pageSize: 2, includeMergedRevisions: true });

    expect(historyClient.getLog).toHaveBeenNthCalledWith(
      2,
      expect.objectContaining({
        limit: 2,
        includeMergedRevisions: true,
      }),
      { signal: expect.any(AbortSignal) },
    );
    expect(fire).toHaveBeenCalledWith(undefined);
    const [target] = await provider.getChildren();
    expect((await provider.getChildren(target)).map((child) => provider.getTreeItem(child).label)).toEqual([
      "r8",
      "r7",
      "l10n:Load More",
    ]);
  });

  it("updates history settings for preloaded line history without loading remote history", async () => {
    const fire = vi.fn();
    const historyClient = fakeHistoryClient();
    const provider = historyProvider(historyClient, undefined, { api: fakeTreeApi({ fire }) });
    provider.showLineHistory(
      {
        kind: "line",
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        path: "src/main.c",
        label: "src/main.c:3",
        lineStart: 3,
        lineEnd: 3,
      },
      [historyEntry({ revision: 8, message: "loaded line history" })],
    );
    fire.mockClear();

    await provider.updateSettings({ pageSize: 5, includeMergedRevisions: true });

    expect(historyClient.getLog).not.toHaveBeenCalled();
    expect(fire).toHaveBeenCalledWith(undefined);
    const [target] = await provider.getChildren();
    expect((await provider.getChildren(target)).map((child) => provider.getTreeItem(child).label)).toEqual(["r8"]);
  });

  it("renders preloaded line history without backend pagination or file compare actions", async () => {
    const historyClient = fakeHistoryClient();
    const provider = historyProvider(historyClient);

    provider.showLineHistory(
      {
        kind: "line",
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        path: "src/main.c",
        label: "src/main.c:3-5",
        lineStart: 3,
        lineEnd: 5,
      },
      [
        historyEntry({ revision: 9, message: "newer selected line edit", changedPaths: [] }),
        historyEntry({ revision: 4, message: "older selected line edit", changedPaths: [] }),
      ],
    );

    expect(historyClient.getLog).not.toHaveBeenCalled();
    await provider.refresh();
    await provider.loadMore();
    expect(historyClient.getLog).not.toHaveBeenCalled();
    const [target] = await provider.getChildren();
    expect(provider.getTreeItem(target)).toMatchObject({
      label: "l10n:Line History: src/main.c:3-5",
      collapsibleState: 2,
      contextValue: "subversionr.history.target",
    });
    expect(provider.getTreeItem(target)).not.toHaveProperty("description");
    const revisions = await provider.getChildren(target);
    expect(revisions.map((revision) => provider.getTreeItem(revision))).toMatchObject([
      {
        label: "r9",
        description: "alice 2026-06-23 newer selected line edit",
        collapsibleState: 0,
        contextValue: "subversionr.history.lineRevision",
        command: {
          command: "subversionr.history.openRevisionDetails",
          title: "l10n:Open Revision Details",
        },
      },
      {
        label: "r4",
        description: "alice 2026-06-23 older selected line edit",
        collapsibleState: 0,
        contextValue: "subversionr.history.lineRevision",
      },
    ]);
    expect(revisions).toHaveLength(2);
    expect(() => provider.openRevisionTarget(revisions[0])).toThrow(
      expect.objectContaining({
        code: "SUBVERSIONR_HISTORY_OPEN_REVISION_TARGET_INVALID",
      }),
    );
    expect(() => provider.compareRevisionTarget(revisions[0])).toThrow(
      expect.objectContaining({
        code: "SUBVERSIONR_HISTORY_COMPARE_PREVIOUS_TARGET_INVALID",
      }),
    );
    expect(provider.revisionDetailsTarget(revisions[0])).toMatchObject({
      targetKind: "line",
      path: "src/main.c",
      label: "src/main.c:3-5",
      revision: "r9",
    });
  });

  it("exposes compare-with-previous targets only when a file revision has an older loaded history entry", async () => {
    const historyClient = fakeHistoryClient(
      historyLog({
        path: "src/main.c",
        entries: [
          historyEntry({ revision: 8, message: "newest edit" }),
          historyEntry({ revision: 5, message: "middle edit" }),
          historyEntry({ revision: 3, message: "oldest loaded edit" }),
        ],
      }),
    );
    const provider = historyProvider(historyClient);

    await provider.showHistory(historyTarget());

    const [target] = await provider.getChildren();
    const revisions = await provider.getChildren(target);
    expect(revisions.map((revision) => provider.getTreeItem(revision).contextValue)).toEqual([
      "subversionr.history.fileRevision.previousDiffable",
      "subversionr.history.fileRevision.previousDiffable",
      "subversionr.history.fileRevision",
    ]);
    expect(provider.compareRevisionTarget(revisions[0])).toEqual({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src/main.c",
      leftRevision: "r5",
      rightRevision: "r8",
      label: "src/main.c r5..r8",
    });
    expect(provider.compareRevisionTarget(revisions[1])).toEqual({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src/main.c",
      leftRevision: "r3",
      rightRevision: "r5",
      label: "src/main.c r3..r5",
    });
    expect(() => provider.compareRevisionTarget(revisions[2])).toThrow(
      expect.objectContaining({
        code: "SUBVERSIONR_HISTORY_COMPARE_PREVIOUS_TARGET_INVALID",
      }),
    );
    expect(() =>
      provider.compareRevisionTarget({
        ...revisions[2],
        previousRevision: 1,
      }),
    ).toThrow(
      expect.objectContaining({
        code: "SUBVERSIONR_HISTORY_COMPARE_PREVIOUS_TARGET_INVALID",
      }),
    );
  });

  it("creates compare targets from exactly two current loaded file revision rows", async () => {
    const historyClient = fakeHistoryClient(
      historyLog({
        path: "src/main.c",
        entries: [
          historyEntry({ revision: 8, message: "newest edit" }),
          historyEntry({ revision: 5, message: "middle edit" }),
          historyEntry({ revision: 3, message: "oldest loaded edit" }),
        ],
      }),
    );
    const provider = historyProvider(historyClient);

    await provider.showHistory(historyTarget());

    const [target] = await provider.getChildren();
    const revisions = await provider.getChildren(target);
    expect(provider.compareRevisionsTarget(revisions[0], [revisions[0], revisions[2]])).toEqual({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src/main.c",
      leftRevision: "r3",
      rightRevision: "r8",
      label: "src/main.c r3..r8",
    });
    expect(provider.compareRevisionsTarget(revisions[2], [revisions[2], revisions[0]])).toEqual({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src/main.c",
      leftRevision: "r3",
      rightRevision: "r8",
      label: "src/main.c r3..r8",
    });
  });

  it("filters loaded history entries by revision, metadata, message, and changed paths without backend work", async () => {
    const historyClient = fakeHistoryClient(
      historyLog({
        entries: [
          historyEntry({
            revision: 12,
            author: "alice",
            date: "2026-06-23T00:00:00.000000Z",
            message: "tighten parser",
            changedPaths: [historyChangedPath({ path: "/trunk/src/parser.c" })],
          }),
          historyEntry({
            revision: 9,
            author: "bob",
            date: "2026-06-20T00:00:00.000000Z",
            message: "update renderer",
            changedPaths: [historyChangedPath({ path: "/trunk/src/render.c" })],
          }),
          historyEntry({
            revision: 6,
            author: "carol",
            date: "2026-06-18T00:00:00.000000Z",
            message: "copy shared code",
            changedPaths: [
              historyChangedPath({
                path: "/trunk/src/copied.c",
                action: "A",
                copyFromPath: "/branches/shared/src/copied.c",
                copyFromRevision: 4,
              }),
            ],
          }),
        ],
      }),
    );
    const provider = historyProvider(historyClient);

    await provider.showHistory(historyTarget());

    expect(provider.applySearch("  PARSER  ")).toEqual({
      query: "PARSER",
      message: "l10n:Filtering loaded SVN history: PARSER",
    });
    const [target] = await provider.getChildren();
    expect((await provider.getChildren(target)).map((child) => provider.getTreeItem(child).label)).toEqual([
      "r12",
    ]);

    provider.applySearch("r9");
    expect((await provider.getChildren(target)).map((child) => provider.getTreeItem(child).label)).toEqual(["r9"]);

    provider.applySearch("branches/shared");
    expect((await provider.getChildren(target)).map((child) => provider.getTreeItem(child).label)).toEqual(["r6"]);
    expect(historyClient.getLog).toHaveBeenCalledTimes(1);
  });

  it("keeps compare-with-previous targets based on unfiltered loaded history order while filtered", async () => {
    const historyClient = fakeHistoryClient(
      historyLog({
        entries: [
          historyEntry({ revision: 12, message: "parser visible" }),
          historyEntry({ revision: 9, message: "hidden middle revision" }),
          historyEntry({ revision: 6, message: "parser older visible" }),
        ],
      }),
    );
    const provider = historyProvider(historyClient);

    await provider.showHistory(historyTarget());
    provider.applySearch("parser");

    const [target] = await provider.getChildren();
    const [newerVisibleRevision, olderVisibleRevision] = await provider.getChildren(target);
    expect(provider.getTreeItem(newerVisibleRevision).label).toBe("r12");
    expect(provider.getTreeItem(olderVisibleRevision).label).toBe("r6");
    expect(provider.compareRevisionTarget(newerVisibleRevision)).toEqual({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src/main.c",
      leftRevision: "r9",
      rightRevision: "r12",
      label: "src/main.c r9..r12",
    });
  });

  it("shows a search empty row and keeps load more available for loaded-history filters", async () => {
    const historyClient = fakeHistoryClient(
      historyLog({
        limit: 2,
        entries: [
          historyEntry({ revision: 12, message: "parser" }),
          historyEntry({ revision: 9, message: "renderer" }),
        ],
      }),
    );
    const provider = historyProvider(historyClient, { pageSize: 2, includeMergedRevisions: false });

    await provider.showHistory(historyTarget());
    provider.applySearch("not-loaded-yet");

    const [target] = await provider.getChildren();
    const children = await provider.getChildren(target);
    expect(children.map((child) => provider.getTreeItem(child))).toMatchObject([
      {
        label: "l10n:No loaded SVN history entries match the search.",
        contextValue: "subversionr.history.searchEmpty",
      },
      {
        label: "l10n:Load More",
        contextValue: "subversionr.history.loadMore",
      },
    ]);
    expect(historyClient.getLog).toHaveBeenCalledTimes(1);
  });

  it("clears loaded-history search on empty input and when opening another target", async () => {
    const historyClient = fakeHistoryClient(
      historyLog({
        entries: [
          historyEntry({ revision: 12, message: "parser" }),
          historyEntry({ revision: 9, message: "renderer" }),
        ],
      }),
      historyLog({
        path: "src/other.c",
        entries: [historyEntry({ revision: 5, message: "other file" })],
      }),
    );
    const provider = historyProvider(historyClient);

    await provider.showHistory(historyTarget());
    provider.applySearch("parser");
    expect(provider.currentSearchQuery()).toBe("parser");
    expect(provider.applySearch("   ")).toEqual({ query: "", message: undefined });
    const [target] = await provider.getChildren();
    expect((await provider.getChildren(target)).map((child) => provider.getTreeItem(child).label)).toEqual([
      "r12",
      "r9",
    ]);

    provider.applySearch("renderer");
    await provider.showHistory({
      kind: "file",
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src/other.c",
      label: "src/other.c",
    });

    expect(provider.currentSearchQuery()).toBe("");
    const [newTarget] = await provider.getChildren();
    expect((await provider.getChildren(newTarget)).map((child) => provider.getTreeItem(child).label)).toEqual(["r5"]);
  });

  it("invalidates previously visible revision nodes when loaded-history search changes", async () => {
    const historyClient = fakeHistoryClient(
      historyLog({
        entries: [
          historyEntry({ revision: 12, message: "parser" }),
          historyEntry({ revision: 9, message: "renderer" }),
        ],
      }),
    );
    const provider = historyProvider(historyClient);

    await provider.showHistory(historyTarget());
    const [target] = await provider.getChildren();
    const [parserRevision, rendererRevision] = await provider.getChildren(target);

    provider.applySearch("renderer");
    expect(() => provider.openRevisionTarget(parserRevision)).toThrow(
      expect.objectContaining({
        code: "SUBVERSIONR_HISTORY_OPEN_REVISION_TARGET_INVALID",
      }),
    );
    const [visibleRevision] = await provider.getChildren(target);
    expect(visibleRevision).not.toBe(rendererRevision);
    expect(provider.openRevisionTarget(visibleRevision)).toEqual({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src/main.c",
      revision: "r9",
      label: "src/main.c@r9",
    });
  });

  it("rejects loaded-history search without a target or with invalid query input", async () => {
    const provider = historyProvider(fakeHistoryClient(historyLog()));

    expect(() => provider.applySearch("parser")).toThrow(
      expect.objectContaining({
        code: "SUBVERSIONR_HISTORY_SEARCH_TARGET_MISSING",
      }),
    );
    await provider.showHistory(historyTarget());
    expect(() => provider.applySearch(7)).toThrow(
      expect.objectContaining({
        code: "SUBVERSIONR_HISTORY_SEARCH_QUERY_INVALID",
      }),
    );
    expect(() => provider.applySearch("x".repeat(201))).toThrow(
      expect.objectContaining({
        code: "SUBVERSIONR_HISTORY_SEARCH_QUERY_INVALID",
      }),
    );
  });

  it("rejects invalid multi-select compare revision targets before diffing", async () => {
    const historyClient = fakeHistoryClient(
      historyLog({
        path: "src/main.c",
        entries: [
          historyEntry({ revision: 8, message: "newest edit" }),
          historyEntry({ revision: 5, message: "middle edit" }),
          historyEntry({ revision: 3, message: "oldest loaded edit" }),
        ],
      }),
    );
    const provider = historyProvider(historyClient);

    await provider.showHistory(historyTarget());

    const [target] = await provider.getChildren();
    const revisions = await provider.getChildren(target);
    const clonedRevision = { ...revisions[0] };

    for (const selected of [
      undefined,
      [revisions[0]],
      [revisions[0], revisions[1], revisions[2]],
      [revisions[0], revisions[0]],
      [clonedRevision, revisions[1]],
      [revisions[1], revisions[2]],
    ]) {
      expect(() => provider.compareRevisionsTarget(revisions[0], selected)).toThrow(
        expect.objectContaining({
          code: "SUBVERSIONR_HISTORY_COMPARE_REVISIONS_TARGET_INVALID",
        }),
      );
    }
  });

  it("creates revision details targets from current history revision rows", async () => {
    const historyClient = fakeHistoryClient(
      historyLog({
        path: "src/main.c",
        entries: [
          historyEntry({
            revision: 8,
            message: "edit file",
            changedPaths: [
              historyChangedPath({ path: "/trunk/src/main.c", action: "M" }),
              historyChangedPath({
                path: "/trunk/src/copied.c",
                action: "A",
                copyFromPath: "/branches/feature/src/copied.c",
                copyFromRevision: 4,
              }),
            ],
          }),
        ],
      }),
    );
    const provider = historyProvider(historyClient);

    await provider.showHistory(historyTarget());

    const [target] = await provider.getChildren();
    const [revision] = await provider.getChildren(target);
    expect(provider.revisionDetailsTarget(revision)).toEqual({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      targetKind: "file",
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
    });
  });

  it("creates revision details targets from current repository revision rows", async () => {
    const historyClient = fakeHistoryClient(
      historyLog({
        path: ".",
        entries: [historyEntry({ revision: 8, message: "edit project" })],
      }),
    );
    const provider = historyProvider(historyClient);

    await provider.showHistory({
      kind: "repository",
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: ".",
      label: "C:/wc",
    });

    const [target] = await provider.getChildren();
    const [revision] = await provider.getChildren(target);
    expect(provider.getTreeItem(revision)).toMatchObject({
      label: "r8",
      contextValue: "subversionr.history.repositoryRevision",
      command: {
        command: "subversionr.history.openRevisionDetails",
        title: "l10n:Open Revision Details",
        arguments: [revision],
      },
    });
    expect(provider.revisionDetailsTarget(revision)).toMatchObject({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      targetKind: "repository",
      path: ".",
      label: "C:/wc",
      revision: "r8",
      message: "edit project",
    });
  });

  it("creates copy targets from current history revision rows", async () => {
    const historyClient = fakeHistoryClient(
      historyLog({
        entries: [historyEntry({ revision: 8, message: "copy this commit message" })],
      }),
    );
    const provider = historyProvider(historyClient);

    await provider.showHistory(historyTarget());

    const [target] = await provider.getChildren();
    const [revision] = await provider.getChildren(target);
    expect(provider.copyTarget(revision)).toEqual({
      revision: 8,
      message: "copy this commit message",
    });
  });

  it("keeps nullable SVN log messages out of localized copy targets", async () => {
    const historyClient = fakeHistoryClient(
      historyLog({
        entries: [historyEntry({ revision: 8, message: null })],
      }),
    );
    const provider = historyProvider(historyClient);

    await provider.showHistory(historyTarget());

    const [target] = await provider.getChildren();
    const [revision] = await provider.getChildren(target);
    expect(provider.copyTarget(revision)).toEqual({
      revision: 8,
      message: null,
    });
  });

  it("rejects structurally cloned history revision command nodes", async () => {
    const historyClient = fakeHistoryClient(
      historyLog({
        path: "src/main.c",
        entries: [
          historyEntry({ revision: 8, message: "newest edit" }),
          historyEntry({ revision: 5, message: "older edit" }),
        ],
      }),
    );
    const provider = historyProvider(historyClient);

    await provider.showHistory(historyTarget());

    const [target] = await provider.getChildren();
    const [revision] = await provider.getChildren(target);
    const shallowSpoofedRevision = { ...revision };
    const spoofedRevision = structuredClone(revision);

    expect(() => provider.openRevisionTarget(shallowSpoofedRevision)).toThrow(
      expect.objectContaining({
        code: "SUBVERSIONR_HISTORY_OPEN_REVISION_TARGET_INVALID",
      }),
    );
    expect(() => provider.compareRevisionTarget(shallowSpoofedRevision)).toThrow(
      expect.objectContaining({
        code: "SUBVERSIONR_HISTORY_COMPARE_PREVIOUS_TARGET_INVALID",
      }),
    );
    expect(() => provider.revisionDetailsTarget(shallowSpoofedRevision)).toThrow(
      expect.objectContaining({
        code: "SUBVERSIONR_HISTORY_REVISION_DETAILS_TARGET_INVALID",
      }),
    );
    expect(() => provider.copyTarget(shallowSpoofedRevision)).toThrow(
      expect.objectContaining({
        code: "SUBVERSIONR_HISTORY_COPY_TARGET_INVALID",
      }),
    );
    expect(() => provider.openRevisionTarget(spoofedRevision)).toThrow(
      expect.objectContaining({
        code: "SUBVERSIONR_HISTORY_OPEN_REVISION_TARGET_INVALID",
      }),
    );
    expect(() => provider.compareRevisionTarget(spoofedRevision)).toThrow(
      expect.objectContaining({
        code: "SUBVERSIONR_HISTORY_COMPARE_PREVIOUS_TARGET_INVALID",
      }),
    );
    expect(() => provider.compareRevisionsTarget(revision, [shallowSpoofedRevision, revision])).toThrow(
      expect.objectContaining({
        code: "SUBVERSIONR_HISTORY_COMPARE_REVISIONS_TARGET_INVALID",
      }),
    );
    expect(() => provider.revisionDetailsTarget(spoofedRevision)).toThrow(
      expect.objectContaining({
        code: "SUBVERSIONR_HISTORY_REVISION_DETAILS_TARGET_INVALID",
      }),
    );
    expect(() => provider.copyTarget(spoofedRevision)).toThrow(
      expect.objectContaining({
        code: "SUBVERSIONR_HISTORY_COPY_TARGET_INVALID",
      }),
    );
  });

  it("does not expose compare-with-previous targets for repository revision rows", async () => {
    const historyClient = fakeHistoryClient(
      historyLog({
        path: ".",
        entries: [
          historyEntry({ revision: 8, message: "newest project edit" }),
          historyEntry({ revision: 7, message: "older project edit" }),
        ],
      }),
    );
    const provider = historyProvider(historyClient);

    await provider.showHistory({
      kind: "repository",
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: ".",
      label: "C:/wc",
    });

    const [target] = await provider.getChildren();
    const revisions = await provider.getChildren(target);
    expect(revisions.map((revision) => provider.getTreeItem(revision).contextValue)).toEqual([
      "subversionr.history.repositoryRevision",
      "subversionr.history.repositoryRevision",
    ]);
    expect(() => provider.compareRevisionTarget(revisions[0])).toThrow(
      expect.objectContaining({
        code: "SUBVERSIONR_HISTORY_COMPARE_PREVIOUS_TARGET_INVALID",
      }),
    );
    expect(() => provider.compareRevisionsTarget(revisions[0], [revisions[0], revisions[1]])).toThrow(
      expect.objectContaining({
        code: "SUBVERSIONR_HISTORY_COMPARE_REVISIONS_TARGET_INVALID",
      }),
    );
  });

  it("aborts an older target when a newer selection starts", async () => {
    const first = deferredHistoryLog();
    const second = deferredHistoryLog();
    const historyClient = fakeDeferredHistoryClient(first, second);
    const provider = historyProvider(historyClient);

    const firstLoad = provider.showHistory({
      kind: "file",
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src/old.c",
      label: "src/old.c",
    });
    await vi.waitFor(() => expect(historyClient.getLog).toHaveBeenCalledTimes(1));
    const firstSignal = historyClient.getLog.mock.calls[0]?.[1]?.signal;
    const secondLoad = provider.showHistory({
      kind: "file",
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src/new.c",
      label: "src/new.c",
    });
    await vi.waitFor(() => expect(historyClient.getLog).toHaveBeenCalledTimes(2));
    expect(firstSignal?.aborted).toBe(true);

    second.resolve(
      historyLog({
        path: "src/new.c",
        entries: [historyEntry({ revision: 9, message: "new target" })],
      }),
    );
    await secondLoad;
    first.resolve(
      historyLog({
        path: "src/old.c",
        entries: [historyEntry({ revision: 8, message: "old target" })],
      }),
    );
    await firstLoad;

    const [target] = await provider.getChildren();
    expect(provider.getTreeItem(target).label).toBe("l10n:File: src/new.c");
    const children = await provider.getChildren(target);
    expect(children.map((child) => provider.getTreeItem(child).description)).toContain("alice 2026-06-23 new target");
    expect(children.map((child) => provider.getTreeItem(child).description)).not.toContain("alice 2026-06-23 old target");
  });

  it("renders changed paths under revision entries without doing extra backend work", async () => {
    const historyClient = fakeHistoryClient(
      historyLog({
        entries: [
          historyEntry({
            revision: 8,
            changedPaths: [
              historyChangedPath({ path: "/trunk/src/main.c", action: "M" }),
              historyChangedPath({
                path: "/trunk/src/copied.c",
                action: "A",
                copyFromPath: "/branches/feature/src/copied.c",
                copyFromRevision: 4,
              }),
            ],
          }),
        ],
      }),
    );
    const provider = historyProvider(historyClient);

    await provider.showHistory(historyTarget());

    const [target] = await provider.getChildren();
    const [revision] = await provider.getChildren(target);
    const changedPaths = await provider.getChildren(revision);
    expect(changedPaths.map((node) => provider.getTreeItem(node))).toMatchObject([
      {
        label: "M /trunk/src/main.c",
        collapsibleState: 0,
      },
      {
        label: "A /trunk/src/copied.c",
        description: "l10n:from /branches/feature/src/copied.c@r4",
        collapsibleState: 0,
      },
    ]);
  });

  it("shows a localized placeholder before a history target is selected", async () => {
    const provider = historyProvider(fakeHistoryClient());

    const [placeholder] = await provider.getChildren();

    expect(provider.getTreeItem(placeholder)).toMatchObject({
      label: "l10n:Open an SVN file or repository history.",
      collapsibleState: 0,
    });
  });
});

function historyProvider(
  historyClient: HistoryClient,
  settings: { pageSize: number; includeMergedRevisions: boolean } = {
    pageSize: 25,
    includeMergedRevisions: false,
  },
  options: { workspaceTrusted?: () => boolean; api?: HistoryTreeApi } = {},
): HistoryTreeDataProvider {
  return new HistoryTreeDataProvider({
    historyClient,
    createRemoteEnvelope: async () => anonymousSvnRemoteEnvelope(),
    settings,
    workspaceTrusted: options.workspaceTrusted ?? (() => true),
    api: options.api ?? fakeTreeApi(),
    localize: (message: string, ...args: unknown[]) =>
      `l10n:${args.reduce<string>((current, arg, index) => current.replace(`{${index}}`, String(arg)), message)}`,
  });
}

function fakeTreeApi(options: { fire?: ReturnType<typeof vi.fn<(element?: unknown) => void>> } = {}): HistoryTreeApi {
  return {
    collapsibleState: {
      none: 0,
      collapsed: 1,
      expanded: 2,
    },
    createEventEmitter: () => ({
      event: vi.fn(),
      fire: options.fire ?? vi.fn(),
      dispose: vi.fn(),
    }),
  };
}

function fakeHistoryClient(...responses: HistoryLog[]): HistoryClient & {
  getLog: ReturnType<typeof vi.fn<(request: HistoryLogRequest, options?: HistoryClientOptions) => Promise<HistoryLog>>>;
} {
  const pending = [...responses];
  return {
    getLog: vi.fn(async (request) => {
      const response = pending.shift();
      if (!response) {
        throw new Error("missing fake history response");
      }
      return {
        ...response,
        repositoryId: request.repositoryId,
        epoch: request.epoch,
        path: request.path,
        startRevision: request.startRevision as HistoryLog["startRevision"],
        endRevision: request.endRevision as HistoryLog["endRevision"],
        limit: request.limit,
      };
    }),
  };
}

function fakeDeferredHistoryClient(
  ...responses: Array<DeferredHistoryLog>
): HistoryClient & {
  getLog: ReturnType<typeof vi.fn<(request: HistoryLogRequest, options?: HistoryClientOptions) => Promise<HistoryLog>>>;
} {
  const pending = [...responses];
  return {
    getLog: vi.fn((request) => {
      const deferred = pending.shift();
      if (!deferred) {
        throw new Error("missing fake history response");
      }
      return deferred.promise.then((response) => ({
        ...response,
        repositoryId: request.repositoryId,
        epoch: request.epoch,
        path: request.path,
        startRevision: request.startRevision as HistoryLog["startRevision"],
        endRevision: request.endRevision as HistoryLog["endRevision"],
        limit: request.limit,
      }));
    }),
  };
}

interface DeferredHistoryLog {
  promise: Promise<HistoryLog>;
  resolve(response: HistoryLog): void;
}

function deferredHistoryLog(): DeferredHistoryLog {
  let resolveResponse: (response: HistoryLog) => void = () => undefined;
  const promise = new Promise<HistoryLog>((resolve) => {
    resolveResponse = resolve;
  });
  return {
    promise,
    resolve: resolveResponse,
  };
}

function historyTarget() {
  return {
    kind: "file" as const,
    repositoryId: "repo-uuid:C:/wc",
    epoch: 7,
    path: "src/main.c",
    label: "src/main.c",
  };
}

function historyLog(overrides: Partial<HistoryLog> = {}): HistoryLog {
  return {
    repositoryId: overrides.repositoryId ?? "repo-uuid:C:/wc",
    epoch: overrides.epoch ?? 7,
    path: overrides.path ?? "src/main.c",
    startRevision: overrides.startRevision ?? "head",
    endRevision: overrides.endRevision ?? ("r0" as HistoryLog["endRevision"]),
    limit: overrides.limit ?? 25,
    entries: overrides.entries ?? [historyEntry()],
    source: overrides.source ?? "libsvn-log",
  };
}

function historyEntry(overrides: Partial<HistoryLog["entries"][number]> = {}): HistoryLog["entries"][number] {
  return {
    revision: overrides.revision ?? 8,
    author: "author" in overrides ? (overrides.author ?? null) : "alice",
    date: overrides.date ?? "2026-06-23T00:00:00.000000Z",
    message: "message" in overrides ? (overrides.message ?? null) : "edit file",
    changedPaths: overrides.changedPaths ?? [historyChangedPath()],
    hasChildren: overrides.hasChildren ?? false,
    nonInheritable: overrides.nonInheritable ?? false,
    subtractiveMerge: overrides.subtractiveMerge ?? false,
  };
}

function historyChangedPath(
  overrides: Partial<HistoryLog["entries"][number]["changedPaths"][number]> = {},
): HistoryLog["entries"][number]["changedPaths"][number] {
  return {
    path: overrides.path ?? "/trunk/src/main.c",
    action: overrides.action ?? "M",
    copyFromPath: overrides.copyFromPath ?? null,
    copyFromRevision: overrides.copyFromRevision ?? null,
    nodeKind: overrides.nodeKind ?? "file",
    textModified: overrides.textModified ?? "true",
    propertiesModified: overrides.propertiesModified ?? "false",
  };
}
