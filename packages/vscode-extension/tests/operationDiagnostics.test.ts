import { Buffer } from "node:buffer";
import { describe, expect, it, vi } from "vitest";
import { OperationDiagnostics } from "../src/diagnostics/operationDiagnostics";

describe("OperationDiagnostics", () => {
  it("writes bounded redacted structured failures and deduplicates the same error object", () => {
    const channel = fakeChannel();
    const diagnostics = new OperationDiagnostics(channel);
    const error = {
      code: "SVN_OPERATION_COMMIT_FAILED",
      category: "native",
      messageKey: "error.native.operationCommitFailed",
      safeArgs: {
        path: "C:\\Users\\Alice\\wc\\private.txt",
        remote: "https://alice:secret@example.com/repos/private?token=abc",
        message: "x".repeat(2_000),
        [`${"a".repeat(128)}password`]: "hunter2",
      },
      retryable: false,
    };

    diagnostics.recordRpcFailure("operation/run", error);
    diagnostics.recordFailure("Commit", error);

    expect(channel.error).toHaveBeenCalledTimes(1);
    const line = channel.error.mock.calls[0]?.[0] ?? "";
    expect(Buffer.byteLength(line, "utf8")).toBeLessThanOrEqual(4096);
    expect(line).toContain("SVN_OPERATION_COMMIT_FAILED");
    expect(line).toContain("[REDACTED:path:");
    expect(line).toContain("[REDACTED:url:");
    expect(line).not.toContain("Alice");
    expect(line).not.toContain("secret@example.com");
    expect(line).not.toContain("hunter2");
  });

  it("bounds rendered records to four KiB after UTF-8 encoding", () => {
    const channel = fakeChannel();
    const diagnostics = new OperationDiagnostics(channel);
    const safeArgs = Object.fromEntries(
      Array.from({ length: 24 }, (_, index) => [`detail${index}`, "界".repeat(512)]),
    );

    diagnostics.recordFailure("History", {
      code: "SVN_HISTORY_LOG_FAILED",
      category: "native",
      messageKey: "error.native.historyLogFailed",
      safeArgs,
      retryable: false,
      diagnostics: null,
    });

    const line = channel.error.mock.calls[0]?.[0] ?? "";
    expect(Buffer.byteLength(line, "utf8")).toBeLessThanOrEqual(4096);
    expect(line).toContain("[TRUNCATED]");
  });

  it("keeps at most one hundred rendered records and replays the retained ring", () => {
    const channel = fakeChannel();
    const diagnostics = new OperationDiagnostics(channel);

    for (let index = 0; index < 101; index += 1) {
      diagnostics.recordFailure(`operation-${index}`, new Error(`failure-${index}`));
    }

    expect(channel.clear).toHaveBeenCalledTimes(1);
    const replayed = channel.error.mock.calls.slice(-100).map(([line]) => line).join("\n");
    expect(replayed).not.toContain("operation-0");
    expect(replayed).toContain("operation-100");
  });

  it("reveals the SubversionR channel without taking editor focus", () => {
    const channel = fakeChannel();
    const diagnostics = new OperationDiagnostics(channel);

    diagnostics.show();

    expect(channel.show).toHaveBeenCalledWith(true);
  });
});

function fakeChannel() {
  return {
    clear: vi.fn(),
    error: vi.fn<(message: string) => void>(),
    show: vi.fn<(preserveFocus?: boolean) => void>(),
  };
}
