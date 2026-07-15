import type { HistoryLogEntry } from "./historyLogRpcClient";
import type { HistoryTreeNode } from "./historyTreeDataProvider";
import type { HistoryViewTarget } from "./historyViewTarget";

export interface HistoryTreeViewDataProvider {
  showHistory(target: HistoryViewTarget): Promise<void>;
  showLineHistory(target: HistoryViewTarget, entries: readonly HistoryLogEntry[]): void;
  currentSearchMessage(): string | undefined;
  currentTargetNode(): HistoryTreeNode | undefined;
}

export interface HistoryTreeViewHost {
  message?: string;
  readonly visible: boolean;
  readonly selection: readonly HistoryTreeNode[];
  onDidChangeVisibility(listener: () => void): { dispose(): void };
  onDidChangeSelection(listener: () => void): { dispose(): void };
  reveal(
    element: HistoryTreeNode,
    options: { select: true; focus: true; expand: true },
  ): PromiseLike<void>;
}

export interface HistoryTreeViewControllerOptions {
  provider: HistoryTreeViewDataProvider;
  treeView: HistoryTreeViewHost;
  settleTimeoutMs?: number;
}

const DEFAULT_SETTLE_TIMEOUT_MS = 10_000;

export class HistoryTreeViewController {
  public constructor(private readonly options: HistoryTreeViewControllerOptions) {}

  public async showHistory(target: HistoryViewTarget): Promise<void> {
    await this.options.provider.showHistory(target);
    await this.revealCurrentTarget();
  }

  public async showLineHistory(target: HistoryViewTarget, entries: readonly HistoryLogEntry[]): Promise<void> {
    this.options.provider.showLineHistory(target, entries);
    await this.revealCurrentTarget();
  }

  private async revealCurrentTarget(): Promise<void> {
    this.options.treeView.message = this.options.provider.currentSearchMessage();
    const targetNode = this.options.provider.currentTargetNode();
    if (!targetNode) {
      throw new HistoryTreeViewControllerError(
        "SUBVERSIONR_HISTORY_VIEW_TARGET_MISSING",
        "error.history.viewTargetMissing",
      );
    }
    try {
      await this.options.treeView.reveal(targetNode, {
        select: true,
        focus: true,
        expand: true,
      });
    } catch (error) {
      throw new HistoryTreeViewControllerError(
        "SUBVERSIONR_HISTORY_VIEW_REVEAL_FAILED",
        "error.history.viewRevealFailed",
        true,
        { cause: error instanceof Error ? error.message : String(error) },
      );
    }
    await this.waitForRevealState(targetNode);
  }

  private async waitForRevealState(targetNode: HistoryTreeNode): Promise<void> {
    const settled = (): boolean =>
      this.options.treeView.visible &&
      this.options.treeView.selection.length === 1 &&
      this.options.treeView.selection[0] === targetNode;
    if (settled()) {
      return;
    }

    await new Promise<void>((resolve, reject) => {
      let completed = false;
      const subscriptions = [
        this.options.treeView.onDidChangeVisibility(check),
        this.options.treeView.onDidChangeSelection(check),
      ];
      const timeout = setTimeout(() => {
        finish(() => reject(new HistoryTreeViewControllerError(
          "SUBVERSIONR_HISTORY_VIEW_REVEAL_NOT_SETTLED",
          "error.history.viewRevealNotSettled",
          true,
        )));
      }, this.options.settleTimeoutMs ?? DEFAULT_SETTLE_TIMEOUT_MS);

      function finish(complete: () => void): void {
        if (completed) {
          return;
        }
        completed = true;
        clearTimeout(timeout);
        for (const subscription of subscriptions) {
          subscription.dispose();
        }
        complete();
      }

      function check(): void {
        if (settled()) {
          finish(resolve);
        }
      }

      check();
    });
  }
}

export class HistoryTreeViewControllerError extends Error {
  public readonly category = "lifecycle";
  public readonly safeArgs = {};

  public constructor(
    public readonly code: string,
    public readonly messageKey: string,
    public readonly retryable = false,
    public readonly diagnostics: unknown = null,
  ) {
    super(code);
    this.name = "HistoryTreeViewControllerError";
  }
}
