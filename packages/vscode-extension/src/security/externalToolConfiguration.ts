import path from "node:path";

export const EXTERNAL_TOOL_RESTRICTED_CONFIGURATION_KEYS = [
  "subversionr.tortoise.executablePath",
  "subversionr.tortoise.configDirectory",
] as const;

export type ExternalToolRestrictedConfigurationKey = (typeof EXTERNAL_TOOL_RESTRICTED_CONFIGURATION_KEYS)[number];
export type ExternalToolFeature = "tortoise";
export type ExternalToolErrorCategory = "configuration" | "lifecycle";

export interface ExternalToolSettings {
  tortoiseExecutablePath?: string;
  tortoiseConfigDirectory?: string;
}

export interface ExternalToolConfigurationInspection<T> {
  defaultValue?: T;
  globalValue?: T;
  workspaceValue?: T;
  workspaceFolderValue?: T;
  defaultLanguageValue?: T;
  globalLanguageValue?: T;
  workspaceLanguageValue?: T;
  workspaceFolderLanguageValue?: T;
}

export interface ExternalToolConfigurationReader {
  get<T>(section: string): T | undefined;
  inspect<T>(section: string): ExternalToolConfigurationInspection<T> | undefined;
}

export class ExternalToolConfigurationError extends Error {
  public constructor(
    public readonly code: string,
    public readonly category: ExternalToolErrorCategory,
    public readonly messageKey: string,
    public readonly safeArgs: Record<string, unknown> = {},
  ) {
    super(code);
    this.name = "ExternalToolConfigurationError";
  }
}

const SETTINGS: ReadonlyArray<{
  readonly section: keyof ExternalToolSettingsBySection;
  readonly fullKey: ExternalToolRestrictedConfigurationKey;
}> = [
  { section: "tortoise.executablePath", fullKey: "subversionr.tortoise.executablePath" },
  { section: "tortoise.configDirectory", fullKey: "subversionr.tortoise.configDirectory" },
];

interface ExternalToolSettingsBySection {
  "tortoise.executablePath": string | undefined;
  "tortoise.configDirectory": string | undefined;
}

export function readExternalToolSettings(configuration: ExternalToolConfigurationReader): ExternalToolSettings {
  return {
    tortoiseExecutablePath: configuration.get<string>("tortoise.executablePath"),
    tortoiseConfigDirectory: configuration.get<string>("tortoise.configDirectory"),
  };
}

export function requireExternalToolExecutionTrusted(workspaceTrusted: boolean, feature: ExternalToolFeature): void {
  if (!workspaceTrusted) {
    throw new ExternalToolConfigurationError(
      "SUBVERSIONR_EXTERNAL_TOOL_UNTRUSTED_WORKSPACE",
      "lifecycle",
      "error.externalTool.untrustedWorkspace",
      { feature },
    );
  }
}

export function assertExternalToolSettingsTrusted(
  configuration: ExternalToolConfigurationReader,
  workspaceTrusted: boolean,
): void {
  if (workspaceTrusted) {
    return;
  }

  for (const setting of SETTINGS) {
    const inspection = configuration.inspect<string>(setting.section);
    if (inspection !== undefined && hasWorkspaceProvidedValue(inspection)) {
      throw new ExternalToolConfigurationError(
        "SUBVERSIONR_EXTERNAL_TOOL_WORKSPACE_SETTING_UNTRUSTED",
        "configuration",
        "error.externalTool.workspaceSettingUntrusted",
        { setting: setting.fullKey },
      );
    }
  }
}

export function normalizeExternalToolPath(
  setting: ExternalToolRestrictedConfigurationKey,
  value: string | undefined,
): string | undefined {
  if (value === undefined || value.trim().length === 0) {
    return undefined;
  }

  const normalized = value.trim();
  if (!isAbsolutePath(normalized)) {
    throw new ExternalToolConfigurationError(
      "SUBVERSIONR_EXTERNAL_TOOL_PATH_NOT_ABSOLUTE",
      "configuration",
      "error.externalTool.pathNotAbsolute",
      { setting },
    );
  }
  return normalized;
}

function hasWorkspaceProvidedValue(inspection: ExternalToolConfigurationInspection<string>): boolean {
  return (
    inspection.workspaceValue !== undefined ||
    inspection.workspaceFolderValue !== undefined ||
    inspection.workspaceLanguageValue !== undefined ||
    inspection.workspaceFolderLanguageValue !== undefined
  );
}

function isAbsolutePath(value: string): boolean {
  return path.isAbsolute(value) || path.win32.isAbsolute(value) || path.posix.isAbsolute(value);
}
