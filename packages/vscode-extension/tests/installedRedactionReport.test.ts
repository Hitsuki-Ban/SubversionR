import { describe, expect, it, vi } from "vitest";
import { collectInstalledRedactionReport } from "../src/diagnostics/installedRedactionReport";
import { OperationDiagnostics } from "../src/diagnostics/operationDiagnostics";

describe("installed redaction report", () => {
  it("fails fast outside the installed Extension Host evidence harness", async () => {
    await expect(
      collectInstalledRedactionReport({
        expectedToken: undefined,
        request: { token: "token-1" },
        operationDiagnostics: operationDiagnostics(),
        collectDiagnosticsBundle: vi.fn().mockResolvedValue({ kind: "subversionr.diagnosticsBundle" }),
      }),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_REDACTION_REPORT_FORBIDDEN",
      messageKey: "error.diagnostics.installedRedactionReportForbidden",
    });
  });

  it("fails fast when the installed evidence harness token does not match", async () => {
    await expect(
      collectInstalledRedactionReport({
        expectedToken: "token-1",
        request: { token: "token-2" },
        operationDiagnostics: operationDiagnostics(),
        collectDiagnosticsBundle: vi.fn().mockResolvedValue({ kind: "subversionr.diagnosticsBundle" }),
      }),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_INSTALLED_REDACTION_REPORT_FORBIDDEN",
      messageKey: "error.diagnostics.installedRedactionReportForbidden",
    });
  });

  it("returns a redacted diagnostics bundle and public support fixture inside the evidence harness", async () => {
    const report = await collectInstalledRedactionReport({
      expectedToken: "token-1",
      request: { token: "token-1" },
      operationDiagnostics: operationDiagnostics(),
      collectDiagnosticsBundle: vi.fn().mockResolvedValue({
        kind: "subversionr.diagnosticsBundle",
        redaction: {
          paths: "redacted",
          urls: "redacted",
          secrets: "redacted",
        },
      }),
    });

    expect(report).toMatchObject({
      schemaVersion: 2,
      kind: "subversionr.installedRedactionReport",
      diagnosticsBundle: {
        kind: "subversionr.diagnosticsBundle",
      },
      publicSupportFixture: {
        status: "redacted",
      },
      operationFailureFixture: {
        status: "redacted",
        channel: "SubversionR",
        maxLines: 100,
        maxLineLength: 4096,
        showLogAction: "Show Log",
      },
    });

    const json = JSON.stringify(report);
    expect(json).not.toContain("hunter2");
    expect(json).not.toContain("abc123");
    expect(json).not.toContain("Alice");
    expect(json).not.toContain("example.com");
    expect(json).not.toContain(".svn/wc.db");
    expect(json).toContain("[REDACTED:url:");
    expect(json).toContain("[REDACTED:path:");
    expect(json).toContain("[REDACTED:secret]");
    expect(json).toContain("[REDACTED:repository-log]");
    expect(json).toContain("[REDACTED:source-content]");
    expect(json).toContain("SVN_ERR_WC_NOT_UP_TO_DATE");
    expect(json).toContain("SVN_ERR_FS_TXN_OUT_OF_DATE");
  });
});

function operationDiagnostics(): OperationDiagnostics {
  return new OperationDiagnostics({
    clear: vi.fn(),
    error: vi.fn(),
    show: vi.fn(),
  });
}
