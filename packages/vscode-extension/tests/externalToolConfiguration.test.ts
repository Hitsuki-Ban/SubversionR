import { describe, expect, it } from "vitest";
import {
  EXTERNAL_TOOL_RESTRICTED_CONFIGURATION_KEYS,
  assertExternalToolSettingsTrusted,
  normalizeExternalToolPath,
  readExternalToolSettings,
  requireExternalToolExecutionTrusted,
  type ExternalToolConfigurationInspection,
  type ExternalToolConfigurationReader,
} from "../src/security/externalToolConfiguration";

describe("external tool configuration trust policy", () => {
  it("exposes the exact restricted configuration keys used by the manifest", () => {
    expect(EXTERNAL_TOOL_RESTRICTED_CONFIGURATION_KEYS).toEqual([
      "subversionr.tortoise.executablePath",
      "subversionr.tortoise.configDirectory",
    ]);
  });

  it("reads optional external tool settings from the subversionr configuration section", () => {
    const settings = readExternalToolSettings(
      fakeConfiguration({
        "tortoise.executablePath": "C:\\Tools\\TortoiseSVN\\bin\\TortoiseProc.exe",
        "tortoise.configDirectory": "C:\\Users\\Alice\\AppData\\Roaming\\Subversion",
      }),
    );

    expect(settings).toEqual({
      tortoiseExecutablePath: "C:\\Tools\\TortoiseSVN\\bin\\TortoiseProc.exe",
      tortoiseConfigDirectory: "C:\\Users\\Alice\\AppData\\Roaming\\Subversion",
    });
  });

  it("keeps optional Tortoise settings unconfigured without failing native core workflows", () => {
    expect(readExternalToolSettings(fakeConfiguration({}))).toEqual({
      tortoiseExecutablePath: undefined,
      tortoiseConfigDirectory: undefined,
    });
    expect(normalizeExternalToolPath("subversionr.tortoise.executablePath", undefined)).toBeUndefined();
  });

  it("blocks all external tool execution in an untrusted workspace before settings are used", () => {
    expect(() => requireExternalToolExecutionTrusted(false, "tortoise")).toThrowError(
      expect.objectContaining({
        code: "SUBVERSIONR_EXTERNAL_TOOL_UNTRUSTED_WORKSPACE",
        category: "lifecycle",
        messageKey: "error.externalTool.untrustedWorkspace",
        safeArgs: { feature: "tortoise" },
      }),
    );
  });

  it("blocks workspace-provided external tool settings in an untrusted workspace without leaking values", () => {
    const configuration = fakeConfiguration(
      {},
      {
        "tortoise.executablePath": {
          workspaceValue: "C:\\malicious\\TortoiseProc.exe",
        },
      },
    );

    expect(() => assertExternalToolSettingsTrusted(configuration, false)).toThrowError(
      expect.objectContaining({
        code: "SUBVERSIONR_EXTERNAL_TOOL_WORKSPACE_SETTING_UNTRUSTED",
        category: "configuration",
        messageKey: "error.externalTool.workspaceSettingUntrusted",
        safeArgs: { setting: "subversionr.tortoise.executablePath" },
      }),
    );
  });

  it("blocks folder and language scoped Tortoise settings in an untrusted workspace", () => {
    const configuration = fakeConfiguration(
      {},
      {
        "tortoise.configDirectory": {
          workspaceFolderLanguageValue: "C:\\malicious\\Subversion",
        },
      },
    );

    expect(() => assertExternalToolSettingsTrusted(configuration, false)).toThrowError(
      expect.objectContaining({
        code: "SUBVERSIONR_EXTERNAL_TOOL_WORKSPACE_SETTING_UNTRUSTED",
        safeArgs: { setting: "subversionr.tortoise.configDirectory" },
      }),
    );
  });

  it("allows workspace-provided settings after Workspace Trust is granted", () => {
    const configuration = fakeConfiguration(
      {},
      {
        "tortoise.configDirectory": {
          workspaceValue: "C:\\wc\\.subversion-config",
        },
      },
    );

    expect(() => assertExternalToolSettingsTrusted(configuration, true)).not.toThrow();
  });

  it("accepts absolute Tortoise executable and config paths without expanding them", () => {
    expect(
      normalizeExternalToolPath(
        "subversionr.tortoise.executablePath",
        "C:\\Tools\\TortoiseSVN\\bin\\TortoiseProc.exe",
      ),
    ).toBe("C:\\Tools\\TortoiseSVN\\bin\\TortoiseProc.exe");
    expect(normalizeExternalToolPath("subversionr.tortoise.configDirectory", "/home/alice/.subversion")).toBe(
      "/home/alice/.subversion",
    );
  });

  it.each([
    ["subversionr.tortoise.executablePath", "TortoiseProc.exe"],
    ["subversionr.tortoise.configDirectory", ".svn-config"],
  ] as const)("rejects non-absolute external tool path setting %s", (setting, value) => {
    expect(() => normalizeExternalToolPath(setting, value)).toThrowError(
      expect.objectContaining({
        code: "SUBVERSIONR_EXTERNAL_TOOL_PATH_NOT_ABSOLUTE",
        category: "configuration",
        messageKey: "error.externalTool.pathNotAbsolute",
        safeArgs: { setting },
      }),
    );
  });
});

function fakeConfiguration(
  values: Record<string, string | undefined>,
  inspections: Record<string, ExternalToolConfigurationInspection<string>> = {},
): ExternalToolConfigurationReader {
  return {
    get: <T>(section: string): T | undefined => values[section] as T | undefined,
    inspect: <T>(section: string): ExternalToolConfigurationInspection<T> | undefined =>
      inspections[section] as ExternalToolConfigurationInspection<T> | undefined,
  };
}
