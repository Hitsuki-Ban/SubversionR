import { describe, expect, it, vi } from "vitest";
import {
  detectTortoiseSvn,
  type TortoiseDetectionHost,
} from "../src/tortoise/tortoiseDetector";
import type {
  ExternalToolConfigurationInspection,
  ExternalToolConfigurationReader,
} from "../src/security/externalToolConfiguration";

describe("TortoiseSVN detector", () => {
  it("requires trusted workspace execution before reading Tortoise settings", async () => {
    const host = fakeHost({ files: ["C:\\Tools\\TortoiseSVN\\bin\\TortoiseProc.exe"] });

    await expect(
      detectTortoiseSvn(fakeConfiguration({ "tortoise.executablePath": "C:\\Tools\\TortoiseSVN\\bin\\TortoiseProc.exe" }), {
        ...host,
        workspaceTrusted: false,
      }),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_EXTERNAL_TOOL_UNTRUSTED_WORKSPACE",
      messageKey: "error.externalTool.untrustedWorkspace",
      safeArgs: { feature: "tortoise" },
    });
    expect(host.fileExists).not.toHaveBeenCalled();
  });

  it("uses an explicit configured TortoiseProc.exe path and does not probe lower-priority sources", async () => {
    const host = fakeHost({
      files: [
        "C:\\Configured\\TortoiseSVN\\bin\\TortoiseProc.exe",
        "C:\\Registry\\TortoiseSVN\\bin\\TortoiseProc.exe",
      ],
      registryValues: ["C:\\Registry\\TortoiseSVN\\bin\\TortoiseProc.exe"],
      pathValue: "C:\\Path\\TortoiseSVN\\bin",
    });

    await expect(
      detectTortoiseSvn(
        fakeConfiguration({ "tortoise.executablePath": "C:\\Configured\\TortoiseSVN\\bin\\TortoiseProc.exe" }),
        host,
      ),
    ).resolves.toEqual({
      status: "available",
      executablePath: "C:\\Configured\\TortoiseSVN\\bin\\TortoiseProc.exe",
      source: "configured",
      configDirectory: undefined,
    });
    expect(host.readRegistryValue).not.toHaveBeenCalled();
  });

  it("fails fast for a configured missing executable instead of falling back to registry or PATH", async () => {
    const host = fakeHost({
      files: ["C:\\Registry\\TortoiseSVN\\bin\\TortoiseProc.exe"],
      registryValues: ["C:\\Registry\\TortoiseSVN\\bin\\TortoiseProc.exe"],
      pathValue: "C:\\Path\\TortoiseSVN\\bin",
    });

    await expect(
      detectTortoiseSvn(
        fakeConfiguration({ "tortoise.executablePath": "C:\\Missing\\TortoiseSVN\\bin\\TortoiseProc.exe" }),
        host,
      ),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_TORTOISE_EXECUTABLE_NOT_FOUND",
      messageKey: "error.tortoise.executableNotFound",
      safeArgs: { setting: "subversionr.tortoise.executablePath" },
    });
    expect(host.readRegistryValue).not.toHaveBeenCalled();
  });

  it("rejects configured executable paths that are not TortoiseProc.exe", async () => {
    await expect(
      detectTortoiseSvn(
        fakeConfiguration({ "tortoise.executablePath": "C:\\Tools\\TortoiseSVN\\bin\\notepad.exe" }),
        fakeHost({ files: ["C:\\Tools\\TortoiseSVN\\bin\\notepad.exe"] }),
      ),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_TORTOISE_EXECUTABLE_NAME_INVALID",
      messageKey: "error.tortoise.executableNameInvalid",
      safeArgs: { setting: "subversionr.tortoise.executablePath" },
    });
  });

  it("rejects configured executable paths that are not Windows drive or UNC paths", async () => {
    await expect(
      detectTortoiseSvn(
        fakeConfiguration({ "tortoise.executablePath": "/usr/bin/TortoiseProc.exe" }),
        fakeHost({ files: ["/usr/bin/TortoiseProc.exe"] }),
      ),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_TORTOISE_EXECUTABLE_PATH_INVALID",
      messageKey: "error.tortoise.executablePathInvalid",
      safeArgs: { setting: "subversionr.tortoise.executablePath" },
    });
  });

  it("rejects configured executable paths with dot segments", async () => {
    await expect(
      detectTortoiseSvn(
        fakeConfiguration({ "tortoise.executablePath": "C:\\Tools\\..\\TortoiseSVN\\bin\\TortoiseProc.exe" }),
        fakeHost({ files: ["C:\\Tools\\..\\TortoiseSVN\\bin\\TortoiseProc.exe"] }),
      ),
    ).rejects.toMatchObject({
      code: "SUBVERSIONR_TORTOISE_EXECUTABLE_PATH_INVALID",
      messageKey: "error.tortoise.executablePathInvalid",
      safeArgs: { setting: "subversionr.tortoise.executablePath" },
    });
  });

  it("detects TortoiseProc.exe from registry before common directories and PATH", async () => {
    const host = fakeHost({
      files: [
        "C:\\Registry\\TortoiseSVN\\bin\\TortoiseProc.exe",
        "C:\\Program Files\\TortoiseSVN\\bin\\TortoiseProc.exe",
        "C:\\Path\\TortoiseSVN\\bin\\TortoiseProc.exe",
      ],
      registryValues: ["C:\\Registry\\TortoiseSVN\\bin\\TortoiseProc.exe"],
      commonDirectories: ["C:\\Program Files\\TortoiseSVN\\bin"],
      pathValue: "C:\\Path\\TortoiseSVN\\bin",
    });

    await expect(detectTortoiseSvn(fakeConfiguration({}), host)).resolves.toMatchObject({
      status: "available",
      executablePath: "C:\\Registry\\TortoiseSVN\\bin\\TortoiseProc.exe",
      source: "registry",
    });
  });

  it("detects TortoiseProc.exe from common directories before PATH", async () => {
    const host = fakeHost({
      files: [
        "C:\\Program Files\\TortoiseSVN\\bin\\TortoiseProc.exe",
        "C:\\Path\\TortoiseSVN\\bin\\TortoiseProc.exe",
      ],
      commonDirectories: ["C:\\Program Files\\TortoiseSVN\\bin"],
      pathValue: "C:\\Path\\TortoiseSVN\\bin",
    });

    await expect(detectTortoiseSvn(fakeConfiguration({}), host)).resolves.toMatchObject({
      status: "available",
      executablePath: "C:\\Program Files\\TortoiseSVN\\bin\\TortoiseProc.exe",
      source: "commonDirectory",
    });
  });

  it("detects TortoiseProc.exe from PATH as the last optional source", async () => {
    const host = fakeHost({
      files: ["C:\\Path\\TortoiseSVN\\bin\\TortoiseProc.exe"],
      pathValue: "C:\\Other;C:\\Path\\TortoiseSVN\\bin",
    });

    await expect(detectTortoiseSvn(fakeConfiguration({}), host)).resolves.toMatchObject({
      status: "available",
      executablePath: "C:\\Path\\TortoiseSVN\\bin\\TortoiseProc.exe",
      source: "path",
    });
  });

  it("ignores registry, common-directory, and PATH candidates that are not Windows-shaped executable paths", async () => {
    const host = fakeHost({
      files: [
        "relative\\TortoiseProc.exe",
        "/usr/bin/TortoiseProc.exe",
        "C:\\Tools\\..\\TortoiseSVN\\bin\\TortoiseProc.exe",
      ],
      registryValues: ["relative\\TortoiseProc.exe"],
      commonDirectories: ["/usr/bin"],
      pathValue: "C:\\Tools\\..\\TortoiseSVN\\bin",
    });

    await expect(detectTortoiseSvn(fakeConfiguration({}), host)).resolves.toEqual({
      status: "unavailable",
      reason: "notFound",
    });
  });

  it("reports unavailable without failing native workflows when TortoiseSVN is absent", async () => {
    await expect(detectTortoiseSvn(fakeConfiguration({}), fakeHost())).resolves.toEqual({
      status: "unavailable",
      reason: "notFound",
    });
  });
});

function fakeHost(options: {
  files?: string[];
  registryValues?: Array<string | undefined>;
  commonDirectories?: string[];
  pathValue?: string;
  workspaceTrusted?: boolean;
} = {}): TortoiseDetectionHost & {
  fileExists: ReturnType<typeof vi.fn<(path: string) => Promise<boolean>>>;
  readRegistryValue: ReturnType<typeof vi.fn<NonNullable<TortoiseDetectionHost["readRegistryValue"]>>>;
} {
  const files = new Set(options.files ?? []);
  return {
    platform: "win32",
    workspaceTrusted: options.workspaceTrusted ?? true,
    env: options.pathValue === undefined ? {} : { Path: options.pathValue },
    commonDirectories: options.commonDirectories ?? [],
    fileExists: vi.fn(async (path) => files.has(path)),
    readRegistryValue: vi.fn(async () => options.registryValues?.shift()),
  };
}

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
