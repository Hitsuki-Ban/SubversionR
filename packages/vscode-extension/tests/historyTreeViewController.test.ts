import { describe, expect, it, vi } from "vitest";
import { HistoryTreeViewController } from "../src/history/historyTreeViewController";
import type { HistoryTreeNode } from "../src/history/historyTreeDataProvider";
import type { HistoryViewTarget } from "../src/history/historyViewTarget";

describe("HistoryTreeViewController", () => {
  it("loads and reveals the repository target before waiting for Extension Host view state", async () => {
    const calls: string[] = [];
    const targetNode = { kind: "target", target: historyTarget() } as HistoryTreeNode;
    const treeView = controllableTreeView();
    treeView.reveal.mockImplementation(async () => {
      calls.push("reveal");
      setTimeout(() => treeView.setState(true, [targetNode]), 0);
    });
    const controller = new HistoryTreeViewController({
      provider: {
        showHistory: vi.fn(async () => {
          calls.push("load");
        }),
        showLineHistory: vi.fn(),
        currentSearchMessage: vi.fn(() => "filtered"),
        currentTargetNode: vi.fn(() => targetNode),
      },
      treeView,
    });

    await controller.showHistory(historyTarget());

    expect(calls).toEqual(["load", "reveal"]);
    expect(treeView.message).toBe("filtered");
    expect(treeView.reveal).toHaveBeenCalledWith(targetNode, {
      select: true,
      focus: true,
      expand: true,
    });
    expect(treeView.visible).toBe(true);
    expect(treeView.selection).toEqual([targetNode]);
  });

  it("fails instead of claiming success when the loaded target is missing", async () => {
    const treeView = controllableTreeView();
    const controller = new HistoryTreeViewController({
      provider: {
        showHistory: vi.fn(async () => undefined),
        showLineHistory: vi.fn(),
        currentSearchMessage: vi.fn(() => undefined),
        currentTargetNode: vi.fn(() => undefined),
      },
      treeView,
    });

    await expect(controller.showHistory(historyTarget())).rejects.toMatchObject({
      code: "SUBVERSIONR_HISTORY_VIEW_TARGET_MISSING",
      category: "lifecycle",
    });
  });

  it("fails within a bound when VS Code does not synchronize the reveal state", async () => {
    const targetNode = { kind: "target", target: historyTarget() } as HistoryTreeNode;
    const treeView = controllableTreeView();
    const controller = new HistoryTreeViewController({
      provider: {
        showHistory: vi.fn(async () => undefined),
        showLineHistory: vi.fn(),
        currentSearchMessage: vi.fn(() => undefined),
        currentTargetNode: vi.fn(() => targetNode),
      },
      treeView,
      settleTimeoutMs: 5,
    });

    await expect(controller.showHistory(historyTarget())).rejects.toMatchObject({
      code: "SUBVERSIONR_HISTORY_VIEW_REVEAL_NOT_SETTLED",
      category: "lifecycle",
    });
  });

  it("wraps reveal rejection as a stable retryable lifecycle error", async () => {
    const targetNode = { kind: "target", target: historyTarget() } as HistoryTreeNode;
    const treeView = controllableTreeView();
    treeView.reveal.mockRejectedValue(new Error("provider must implement getParent"));
    const controller = new HistoryTreeViewController({
      provider: {
        showHistory: vi.fn(async () => undefined),
        showLineHistory: vi.fn(),
        currentSearchMessage: vi.fn(() => undefined),
        currentTargetNode: vi.fn(() => targetNode),
      },
      treeView,
    });

    await expect(controller.showHistory(historyTarget())).rejects.toMatchObject({
      code: "SUBVERSIONR_HISTORY_VIEW_REVEAL_FAILED",
      category: "lifecycle",
      retryable: true,
      diagnostics: { cause: "provider must implement getParent" },
    });
  });
});

function controllableTreeView() {
  const visibilityListeners = new Set<() => void>();
  const selectionListeners = new Set<() => void>();
  return {
    message: undefined as string | undefined,
    visible: false,
    selection: [] as readonly HistoryTreeNode[],
    reveal: vi.fn(async () => undefined),
    onDidChangeVisibility(listener: () => void) {
      visibilityListeners.add(listener);
      return { dispose: () => visibilityListeners.delete(listener) };
    },
    onDidChangeSelection(listener: () => void) {
      selectionListeners.add(listener);
      return { dispose: () => selectionListeners.delete(listener) };
    },
    setState(visible: boolean, selection: readonly HistoryTreeNode[]) {
      this.visible = visible;
      this.selection = selection;
      for (const listener of visibilityListeners) {
        listener();
      }
      for (const listener of selectionListeners) {
        listener();
      }
    },
  };
}

function historyTarget(): HistoryViewTarget {
  return {
    kind: "repository",
    repositoryId: "repo-uuid:C:/wc",
    epoch: 7,
    path: ".",
    label: "C:/wc",
  };
}
