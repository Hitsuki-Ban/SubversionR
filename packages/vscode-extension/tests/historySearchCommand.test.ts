import { describe, expect, it, vi } from "vitest";
import {
  searchLoadedHistory,
  type LoadedHistorySearchInputOptions,
} from "../src/history/historySearchCommand";

describe("searchLoadedHistory", () => {
  it("prompts with the current query, applies loaded-history search, and updates the tree message", async () => {
    const provider = fakeHistoryProvider({
      currentQuery: "parser",
      applyResult: {
        query: "renderer",
        message: "Filtering loaded SVN history: renderer",
      },
    });
    const ui = fakeSearchUi(" renderer ");

    await searchLoadedHistory(provider, ui);

    expect(ui.showInputBox).toHaveBeenCalledWith({
      prompt: "Enter text, author, path, date, or revision to filter loaded SVN history. Leave empty to clear.",
      placeHolder: "Search loaded SVN history",
      value: "parser",
      validateInput: expect.any(Function),
    });
    expect(provider.ensureSearchableTarget).toHaveBeenCalledTimes(1);
    expect(provider.applySearch).toHaveBeenCalledWith(" renderer ");
    expect(ui.setTreeMessage).toHaveBeenCalledWith("Filtering loaded SVN history: renderer");
  });

  it("does not apply loaded-history search when the input is cancelled", async () => {
    const provider = fakeHistoryProvider();
    const ui = fakeSearchUi(undefined);

    await searchLoadedHistory(provider, ui);

    expect(provider.ensureSearchableTarget).toHaveBeenCalledTimes(1);
    expect(provider.applySearch).not.toHaveBeenCalled();
    expect(ui.setTreeMessage).not.toHaveBeenCalled();
  });

  it("clears the tree message when the provider clears loaded-history search", async () => {
    const provider = fakeHistoryProvider({
      applyResult: {
        query: "",
        message: undefined,
      },
    });
    const ui = fakeSearchUi("");

    await searchLoadedHistory(provider, ui);

    expect(provider.applySearch).toHaveBeenCalledWith("");
    expect(ui.setTreeMessage).toHaveBeenCalledWith(undefined);
  });

  it("validates long search input before applying it", async () => {
    const provider = fakeHistoryProvider();
    const ui = fakeSearchUi("unused");

    await searchLoadedHistory(provider, ui);

    const options = ui.showInputBox.mock.calls[0]?.[0];
    expect(options?.validateInput?.("x".repeat(200))).toBeUndefined();
    expect(options?.validateInput?.(` ${"x".repeat(200)} `)).toBeUndefined();
    expect(options?.validateInput?.(" ".repeat(201))).toBeUndefined();
    expect(options?.validateInput?.("x".repeat(201))).toBe(
      "Loaded SVN history search is limited to 200 characters.",
    );
  });
});

function fakeHistoryProvider(
  options: {
    currentQuery?: string;
    applyResult?: { query: string; message?: string };
  } = {},
) {
  return {
    ensureSearchableTarget: vi.fn(),
    currentSearchQuery: vi.fn(() => options.currentQuery ?? ""),
    applySearch: vi.fn(() => options.applyResult ?? { query: "query", message: undefined }),
  };
}

function fakeSearchUi(input: string | undefined) {
  return {
    showInputBox: vi.fn(async (_options: LoadedHistorySearchInputOptions) => input),
    setTreeMessage: vi.fn(),
    localize: (message: string, ...args: unknown[]) =>
      args.reduce<string>((current, arg, index) => current.replace(`{${index}}`, String(arg)), message),
  };
}
