export interface WorkspaceConfigurationReader {
  get<T>(section: string): T | undefined;
}

export interface HistorySettings {
  pageSize: number;
  includeMergedRevisions: boolean;
}

export type HistorySettingsErrorCategory = "configuration";

export class HistorySettingsError extends Error {
  public constructor(
    public readonly code: string,
    public readonly category: HistorySettingsErrorCategory,
    public readonly messageKey: string,
    public readonly safeArgs: Record<string, unknown> = {},
  ) {
    super(code);
    this.name = "HistorySettingsError";
  }
}

export function readHistorySettings(configuration: WorkspaceConfigurationReader): HistorySettings {
  return {
    pageSize: requirePageSize(configuration.get<number>("history.pageSize"), "history.pageSize"),
    includeMergedRevisions: requireBoolean(
      configuration.get<boolean>("history.includeMergedRevisions"),
      "history.includeMergedRevisions",
    ),
  };
}

function requirePageSize(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 1 || value > 500) {
    throw historyConfigError(field);
  }
  return value;
}

function requireBoolean(value: unknown, field: string): boolean {
  if (typeof value !== "boolean") {
    throw historyConfigError(field);
  }
  return value;
}

function historyConfigError(field: string): HistorySettingsError {
  return new HistorySettingsError(
    "SUBVERSIONR_HISTORY_CONFIG_INVALID",
    "configuration",
    "error.history.configInvalid",
    { field },
  );
}
