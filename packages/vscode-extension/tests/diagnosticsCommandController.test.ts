import { describe, expect, it, vi } from "vitest";
import { DiagnosticsCommandController } from "../src/diagnostics/diagnosticsCommandController";

describe("DiagnosticsCommandController", () => {
  it("writes a redacted diagnostics bundle to the selected file", async () => {
    const ui = fakeUi();
    const controller = new DiagnosticsCommandController({
      diagnostics: {
        collectDiagnosticsBundle: vi.fn().mockResolvedValue({
          kind: "subversionr.diagnosticsBundle",
          generatedAt: "2026-06-24T00:00:00.000Z",
          secret: "[REDACTED:secret]",
        }),
        collectVersionReport: vi.fn(),
      },
      ui,
      localize,
    });

    await controller.collectDiagnostics();

    expect(ui.showSaveDialog).toHaveBeenCalledWith("subversionr-diagnostics-2026-06-24T00-00-00-000Z.json");
    expect(ui.writeFile).toHaveBeenCalledWith(
      { fsPath: "C:/tmp/subversionr-diagnostics.json" },
      expect.any(Uint8Array),
    );
    const written = new TextDecoder().decode(ui.writeFile.mock.calls[0]?.[1]);
    expect(written).toContain('"kind": "subversionr.diagnosticsBundle"');
    expect(written).not.toContain("hunter2");
    expect(ui.showInformationMessage).toHaveBeenCalledWith("l10n:SubversionR diagnostics bundle saved.");
  });

  it("opens a redacted version report document", async () => {
    const ui = fakeUi();
    const controller = new DiagnosticsCommandController({
      diagnostics: {
        collectDiagnosticsBundle: vi.fn(),
        collectVersionReport: vi.fn().mockResolvedValue({
          kind: "subversionr.versionReport",
          backend: {
            status: "initialized",
            libsvnVersion: "1.14.5",
          },
        }),
      },
      ui,
      localize,
    });

    await controller.showVersionReport();

    expect(ui.createReadonlyDocument).toHaveBeenCalledWith(expect.stringContaining('"kind": "subversionr.versionReport"'));
    expect(ui.openReadonlyDocument).toHaveBeenCalledWith({ scheme: "svn-r-diagnostics", path: "/version-report.json" });
  });
});

function fakeUi() {
  return {
    showSaveDialog: vi.fn().mockResolvedValue({ fsPath: "C:/tmp/subversionr-diagnostics.json" }),
    writeFile: vi.fn().mockResolvedValue(undefined),
    createReadonlyDocument: vi.fn(() => ({ scheme: "svn-r-diagnostics", path: "/version-report.json" })),
    openReadonlyDocument: vi.fn().mockResolvedValue(undefined),
    showInformationMessage: vi.fn().mockResolvedValue(undefined),
    showErrorMessage: vi.fn().mockResolvedValue(undefined),
  };
}

function localize(message: string, ...args: unknown[]): string {
  return `l10n:${args.reduce<string>((current, arg, index) => current.replace(`{${index}}`, String(arg)), message)}`;
}
