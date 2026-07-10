import { describe, expect, it, vi } from "vitest";
import {
  copyHistoryCommitMessage,
  copyHistoryRevisionNumber,
  type HistoryCopyCommandHost,
  type HistoryCopyTargetProvider,
} from "../src/history/historyCopyCommand";

describe("history copy commands", () => {
  it("copies the bare SVN revision number to the clipboard", async () => {
    const host = fakeHost();
    const provider = fakeProvider({ revision: 8, message: "edit file" });

    await copyHistoryRevisionNumber(provider, { kind: "revision" }, host);

    expect(host.writeText).toHaveBeenCalledWith("8");
    expect(host.showInformationMessage).toHaveBeenCalledWith("l10n:Copied SVN revision number: 8");
  });

  it("copies the original SVN log message to the clipboard", async () => {
    const host = fakeHost();
    const provider = fakeProvider({ revision: 8, message: "edit file\n\nbody" });

    await copyHistoryCommitMessage(provider, { kind: "revision" }, host);

    expect(host.writeText).toHaveBeenCalledWith("edit file\n\nbody");
    expect(host.showInformationMessage).toHaveBeenCalledWith("l10n:Copied SVN commit message.");
  });

  it("copies an empty string when svn:log is absent", async () => {
    const host = fakeHost();
    const provider = fakeProvider({ revision: 8, message: null });

    await copyHistoryCommitMessage(provider, { kind: "revision" }, host);

    expect(host.writeText).toHaveBeenCalledWith("");
    expect(host.showInformationMessage).toHaveBeenCalledWith("l10n:Copied SVN commit message.");
  });

  it("does not write to the clipboard when the history target is invalid", async () => {
    const host = fakeHost();
    const provider: HistoryCopyTargetProvider = {
      copyTarget: vi.fn(() => {
        throw new Error("invalid");
      }),
    };

    await expect(copyHistoryRevisionNumber(provider, { kind: "spoofed" }, host)).rejects.toThrow("invalid");

    expect(host.writeText).not.toHaveBeenCalled();
    expect(host.showInformationMessage).not.toHaveBeenCalled();
  });
});

function fakeProvider(target: ReturnType<HistoryCopyTargetProvider["copyTarget"]>): HistoryCopyTargetProvider {
  return {
    copyTarget: vi.fn(() => target),
  };
}

function fakeHost(): HistoryCopyCommandHost & {
  writeText: ReturnType<typeof vi.fn<(value: string) => Promise<void>>>;
  showInformationMessage: ReturnType<typeof vi.fn<(message: string) => Promise<void>>>;
} {
  return {
    writeText: vi.fn(async () => undefined),
    showInformationMessage: vi.fn(async () => undefined),
    localize: (message, ...args) =>
      `l10n:${args.reduce<string>((current, arg, index) => current.replace(`{${index}}`, String(arg)), message)}`,
  };
}
