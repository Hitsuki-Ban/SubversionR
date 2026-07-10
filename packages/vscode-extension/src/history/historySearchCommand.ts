import type { HistorySearchResult } from "./historyTreeDataProvider";

export interface LoadedHistorySearchProvider {
  ensureSearchableTarget(): void;
  currentSearchQuery(): string;
  applySearch(query: string): HistorySearchResult;
}

export interface LoadedHistorySearchInputOptions {
  prompt: string;
  placeHolder: string;
  value: string;
  validateInput(value: string): string | undefined;
}

export interface LoadedHistorySearchUi {
  showInputBox(options: LoadedHistorySearchInputOptions): Promise<string | undefined>;
  setTreeMessage(message: string | undefined): void;
  localize(message: string, ...args: unknown[]): string;
}

const MAX_HISTORY_SEARCH_QUERY_LENGTH = 200;

export async function searchLoadedHistory(
  provider: LoadedHistorySearchProvider,
  ui: LoadedHistorySearchUi,
): Promise<void> {
  provider.ensureSearchableTarget();
  const query = await ui.showInputBox({
    prompt: ui.localize(
      "Enter text, author, path, date, or revision to filter loaded SVN history. Leave empty to clear.",
    ),
    placeHolder: ui.localize("Search loaded SVN history"),
    value: provider.currentSearchQuery(),
    validateInput: (value) =>
      value.trim().length > MAX_HISTORY_SEARCH_QUERY_LENGTH
        ? ui.localize("Loaded SVN history search is limited to 200 characters.")
        : undefined,
  });
  if (query === undefined) {
    return;
  }
  const result = provider.applySearch(query);
  ui.setTreeMessage(result.message);
}
