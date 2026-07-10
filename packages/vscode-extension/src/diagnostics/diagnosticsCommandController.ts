export interface DiagnosticsReports {
  collectDiagnosticsBundle(): Promise<Record<string, unknown>>;
  collectVersionReport(): Promise<Record<string, unknown>>;
}

export interface DiagnosticsCommandUi {
  showSaveDialog(defaultFileName: string): Promise<unknown | undefined>;
  writeFile(uri: unknown, content: Uint8Array): Promise<void>;
  createReadonlyDocument(content: string): unknown;
  openReadonlyDocument(uri: unknown): Promise<void>;
  showInformationMessage(message: string): Promise<void>;
  showErrorMessage(message: string): Promise<void>;
}

export interface DiagnosticsCommandControllerOptions {
  diagnostics: DiagnosticsReports;
  ui: DiagnosticsCommandUi;
  localize(message: string, ...args: unknown[]): string;
}

export class DiagnosticsCommandController {
  public constructor(private readonly options: DiagnosticsCommandControllerOptions) {}

  public async collectDiagnostics(): Promise<void> {
    try {
      const bundle = await this.options.diagnostics.collectDiagnosticsBundle();
      const target = await this.options.ui.showSaveDialog(defaultDiagnosticsFileName(bundle));
      if (!target) {
        return;
      }
      await this.options.ui.writeFile(target, encodeJson(bundle));
      await this.options.ui.showInformationMessage(
        this.options.localize("SubversionR diagnostics bundle saved."),
      );
    } catch (error) {
      await this.options.ui.showErrorMessage(
        this.options.localize("SubversionR diagnostics collection failed: {0}", extensionErrorCode(error)),
      );
    }
  }

  public async showVersionReport(): Promise<void> {
    try {
      const report = await this.options.diagnostics.collectVersionReport();
      const uri = this.options.ui.createReadonlyDocument(jsonString(report));
      await this.options.ui.openReadonlyDocument(uri);
    } catch (error) {
      await this.options.ui.showErrorMessage(
        this.options.localize("SubversionR version report failed: {0}", extensionErrorCode(error)),
      );
    }
  }
}

function defaultDiagnosticsFileName(bundle: Record<string, unknown>): string {
  const generatedAt = typeof bundle.generatedAt === "string" ? bundle.generatedAt : new Date().toISOString();
  return `subversionr-diagnostics-${generatedAt.replace(/[^0-9A-Za-z]/gu, "-")}.json`;
}

function encodeJson(value: unknown): Uint8Array {
  return new TextEncoder().encode(jsonString(value));
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
  return "SUBVERSIONR_DIAGNOSTICS_FAILED";
}
