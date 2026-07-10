export interface WorkspaceConfigurationReader {
  get<T>(section: string): T | undefined;
}

export interface StatusSettings {
  countUnversioned: boolean;
  ignoreChangelistsInCount: string[];
}

export type StatusSettingsErrorCategory = "configuration";

export class StatusSettingsError extends Error {
  public constructor(
    public readonly code: string,
    public readonly category: StatusSettingsErrorCategory,
    public readonly messageKey: string,
    public readonly safeArgs: Record<string, unknown> = {},
  ) {
    super(code);
    this.name = "StatusSettingsError";
  }
}

export function readStatusSettings(configuration: WorkspaceConfigurationReader): StatusSettings {
  return {
    countUnversioned: requireBoolean(configuration.get<boolean>("status.countUnversioned"), "status.countUnversioned"),
    ignoreChangelistsInCount: requireStringArray(
      configuration.get<string[]>("status.ignoreChangelistsInCount"),
      "status.ignoreChangelistsInCount",
    ),
  };
}

function requireBoolean(value: unknown, field: string): boolean {
  if (typeof value !== "boolean") {
    throw statusConfigError(field);
  }
  return value;
}

function requireStringArray(value: unknown, field: string): string[] {
  if (!Array.isArray(value)) {
    throw statusConfigError(field);
  }
  return value.map((entry, index) => {
    if (typeof entry !== "string" || entry.trim().length === 0) {
      throw statusConfigError(`${field}.${index}`);
    }
    return entry;
  });
}

function statusConfigError(field: string): StatusSettingsError {
  return new StatusSettingsError(
    "SUBVERSIONR_STATUS_CONFIG_INVALID",
    "configuration",
    "error.status.configInvalid",
    { field },
  );
}
