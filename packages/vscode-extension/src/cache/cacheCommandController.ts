import type { CacheMigrationReport } from "./cacheLifecycleService";

export interface CacheCommands {
  clearCache(reason: "manual-clear"): Promise<CacheMigrationReport>;
  lastMigrationReport(): CacheMigrationReport | undefined;
}

export interface CacheCommandUi {
  createReadonlyDocument(content: string): unknown;
  openReadonlyDocument(uri: unknown): Promise<void>;
  showInformationMessage(message: string): Promise<void>;
  showErrorMessage(message: string): Promise<void>;
}

export interface CacheCommandControllerOptions {
  cache: CacheCommands;
  ui: CacheCommandUi;
  localize(message: string, ...args: unknown[]): string;
}

export class CacheCommandController {
  public constructor(private readonly options: CacheCommandControllerOptions) {}

  public async clearCache(): Promise<void> {
    try {
      await this.options.cache.clearCache("manual-clear");
      await this.options.ui.showInformationMessage(
        this.options.localize("SubversionR extension cache cleared. SVN working copies were not modified."),
      );
    } catch (error) {
      await this.options.ui.showErrorMessage(
        this.options.localize("SubversionR cache clear failed: {0}", extensionErrorCode(error)),
      );
    }
  }

  public async showMigrationReport(): Promise<void> {
    try {
      const report = this.options.cache.lastMigrationReport();
      if (report === undefined) {
        await this.options.ui.showInformationMessage(
          this.options.localize("No SubversionR migration report is available."),
        );
        return;
      }
      const uri = this.options.ui.createReadonlyDocument(jsonString(report));
      await this.options.ui.openReadonlyDocument(uri);
    } catch (error) {
      await this.options.ui.showErrorMessage(
        this.options.localize("SubversionR migration report failed: {0}", extensionErrorCode(error)),
      );
    }
  }
}

function jsonString(value: unknown): string {
  return `${JSON.stringify(value, null, 2)}\n`;
}

function extensionErrorCode(error: unknown): string {
  if (typeof error === "object" && error !== null && "code" in error) {
    const code = (error as { code?: unknown }).code;
    if (typeof code === "string" && code.trim().length > 0) {
      return code;
    }
  }
  return "SUBVERSIONR_CACHE_COMMAND_FAILED";
}
