import { describe, expect, it, vi } from "vitest";
import { CacheCommandController } from "../src/cache/cacheCommandController";
import type { CacheMigrationReport } from "../src/cache/cacheLifecycleService";

describe("CacheCommandController", () => {
  it("clears cache and reports that SVN working copies were not modified", async () => {
    const ui = fakeUi();
    const cache = {
      clearCache: vi.fn().mockResolvedValue(report({ action: "cleared", reason: "manual-clear" })),
      lastMigrationReport: vi.fn(),
    };
    const controller = new CacheCommandController({ cache, ui, localize });

    await controller.clearCache();

    expect(cache.clearCache).toHaveBeenCalledWith("manual-clear");
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "l10n:SubversionR extension cache cleared. SVN working copies were not modified.",
    );
  });

  it("opens the last migration report as a readonly document", async () => {
    const ui = fakeUi();
    const cache = {
      clearCache: vi.fn(),
      lastMigrationReport: vi.fn().mockReturnValue(report({ action: "schema-reset", reason: "stale-schema" })),
    };
    const controller = new CacheCommandController({ cache, ui, localize });

    await controller.showMigrationReport();

    expect(ui.createReadonlyDocument).toHaveBeenCalledWith(expect.stringContaining('"kind": "subversionr.cacheMigrationReport"'));
    expect(ui.openReadonlyDocument).toHaveBeenCalledWith({ scheme: "svn-r-diagnostics", path: "/cache-report.json" });
  });

  it("shows a localized message when no migration report exists", async () => {
    const ui = fakeUi();
    const cache = {
      clearCache: vi.fn(),
      lastMigrationReport: vi.fn().mockReturnValue(undefined),
    };
    const controller = new CacheCommandController({ cache, ui, localize });

    await controller.showMigrationReport();

    expect(ui.showInformationMessage).toHaveBeenCalledWith("l10n:No SubversionR migration report is available.");
    expect(ui.openReadonlyDocument).not.toHaveBeenCalled();
  });
});

function fakeUi() {
  return {
    createReadonlyDocument: vi.fn(() => ({ scheme: "svn-r-diagnostics", path: "/cache-report.json" })),
    openReadonlyDocument: vi.fn().mockResolvedValue(undefined),
    showInformationMessage: vi.fn().mockResolvedValue(undefined),
    showErrorMessage: vi.fn().mockResolvedValue(undefined),
  };
}

function report(fields: { action: CacheMigrationReport["action"]; reason: CacheMigrationReport["reason"] }): CacheMigrationReport {
  return {
    kind: "subversionr.cacheMigrationReport",
    generatedAt: "2026-06-24T00:00:00.000Z",
    currentSchemaVersion: 1,
    previousSchemaVersion: 0,
    action: fields.action,
    reason: fields.reason,
    workingCopyMutation: "none",
    storageRoots: [],
    releaseTraceIds: ["MIG-008", "MIG-010", "MIG-011", "SEC-013"],
  };
}

function localize(message: string, ...args: unknown[]): string {
  return `l10n:${args.reduce<string>((current, arg, index) => current.replace(`{${index}}`, String(arg)), message)}`;
}
