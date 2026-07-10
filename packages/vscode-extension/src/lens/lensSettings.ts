export interface LensSettings {
  enabled: boolean;
  fileHeader: boolean;
  currentLine: boolean;
  hover: boolean;
  symbols: boolean;
  maxFileLines: number;
}

export interface LensConfiguration {
  get(key: string, defaultValue?: unknown): unknown;
}

export class LensSettingsError extends Error {
  public constructor(
    public readonly code: string,
    public readonly field: string,
  ) {
    super(code);
    this.name = "LensSettingsError";
  }
}

export function readLensSettings(configuration: LensConfiguration): LensSettings {
  return {
    enabled: requireBoolean(configuration.get("lens.enabled", true), "lens.enabled"),
    fileHeader: requireBoolean(configuration.get("lens.fileHeader", true), "lens.fileHeader"),
    currentLine: requireBoolean(configuration.get("lens.currentLine", true), "lens.currentLine"),
    hover: requireBoolean(configuration.get("lens.hover", true), "lens.hover"),
    symbols: requireBoolean(configuration.get("lens.symbols", false), "lens.symbols"),
    maxFileLines: requirePositiveInteger(configuration.get("lens.maxFileLines", 20000), "lens.maxFileLines"),
  };
}

function requireBoolean(value: unknown, field: string): boolean {
  if (typeof value !== "boolean") {
    throw invalidLensSetting(field);
  }
  return value;
}

function requirePositiveInteger(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 1) {
    throw invalidLensSetting(field);
  }
  return value;
}

function invalidLensSetting(field: string): LensSettingsError {
  return new LensSettingsError("SUBVERSIONR_LENS_SETTING_INVALID", field);
}
