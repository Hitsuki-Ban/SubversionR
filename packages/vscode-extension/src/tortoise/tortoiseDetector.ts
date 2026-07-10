import { execFile } from "node:child_process";
import { stat } from "node:fs/promises";
import path from "node:path";
import {
  assertExternalToolSettingsTrusted,
  normalizeExternalToolPath,
  readExternalToolSettings,
  requireExternalToolExecutionTrusted,
  type ExternalToolConfigurationReader,
} from "../security/externalToolConfiguration";

export type TortoiseDetectionSource = "configured" | "registry" | "commonDirectory" | "path";

export type TortoiseDetectionResult =
  | {
      status: "available";
      executablePath: string;
      source: TortoiseDetectionSource;
      configDirectory?: string;
    }
  | {
      status: "unavailable";
      reason: "notFound" | "unsupportedPlatform";
    };

export interface TortoiseDetectionHost {
  platform: string;
  workspaceTrusted: boolean;
  env: Record<string, string | undefined>;
  commonDirectories?: string[];
  fileExists(path: string): Promise<boolean>;
  readRegistryValue?(hive: string, key: string, valueName: string): Promise<string | undefined>;
}

export type TortoiseDetectionErrorCategory = "configuration" | "lifecycle";

export class TortoiseDetectionError extends Error {
  public constructor(
    public readonly code: string,
    public readonly category: TortoiseDetectionErrorCategory,
    public readonly messageKey: string,
    public readonly safeArgs: Record<string, unknown> = {},
  ) {
    super(code);
    this.name = "TortoiseDetectionError";
  }
}

const TORTOISE_PROC_EXE = "TortoiseProc.exe";

const REGISTRY_QUERIES: ReadonlyArray<{
  readonly hive: string;
  readonly key: string;
  readonly valueName: string;
}> = [
  {
    hive: "HKCU",
    key: "Software\\Microsoft\\Windows\\CurrentVersion\\App Paths\\TortoiseProc.exe",
    valueName: "",
  },
  {
    hive: "HKLM",
    key: "Software\\Microsoft\\Windows\\CurrentVersion\\App Paths\\TortoiseProc.exe",
    valueName: "",
  },
  {
    hive: "HKLM",
    key: "Software\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\App Paths\\TortoiseProc.exe",
    valueName: "",
  },
];

export async function detectTortoiseSvn(
  configuration: ExternalToolConfigurationReader,
  host: TortoiseDetectionHost,
): Promise<TortoiseDetectionResult> {
  requireExternalToolExecutionTrusted(host.workspaceTrusted, "tortoise");
  assertExternalToolSettingsTrusted(configuration, host.workspaceTrusted);

  const settings = readExternalToolSettings(configuration);
  const configuredExecutablePath = normalizeExternalToolPath(
    "subversionr.tortoise.executablePath",
    settings.tortoiseExecutablePath,
  );
  const configDirectory = normalizeExternalToolPath(
    "subversionr.tortoise.configDirectory",
    settings.tortoiseConfigDirectory,
  );

  if (configuredExecutablePath !== undefined) {
    assertWindowsDriveOrUncPath(configuredExecutablePath, "subversionr.tortoise.executablePath");
    assertTortoiseProcExecutableName(configuredExecutablePath, "subversionr.tortoise.executablePath");
    if (!(await host.fileExists(configuredExecutablePath))) {
      throw new TortoiseDetectionError(
        "SUBVERSIONR_TORTOISE_EXECUTABLE_NOT_FOUND",
        "configuration",
        "error.tortoise.executableNotFound",
        { setting: "subversionr.tortoise.executablePath" },
      );
    }
    return {
      status: "available",
      executablePath: configuredExecutablePath,
      source: "configured",
      ...(configDirectory ? { configDirectory } : {}),
    };
  }

  if (host.platform !== "win32") {
    return { status: "unavailable", reason: "unsupportedPlatform" };
  }

  const registryCandidate = await detectFromRegistry(host);
  if (registryCandidate !== undefined) {
    return available(registryCandidate, "registry", configDirectory);
  }

  const commonDirectoryCandidate = await detectFromCommonDirectories(host);
  if (commonDirectoryCandidate !== undefined) {
    return available(commonDirectoryCandidate, "commonDirectory", configDirectory);
  }

  const pathCandidate = await detectFromPath(host);
  if (pathCandidate !== undefined) {
    return available(pathCandidate, "path", configDirectory);
  }

  return { status: "unavailable", reason: "notFound" };
}

export function createNodeTortoiseDetectionHost(workspaceTrusted: boolean): TortoiseDetectionHost {
  return {
    platform: process.platform,
    workspaceTrusted,
    env: process.env,
    commonDirectories: defaultCommonDirectories(process.env),
    fileExists: async (candidate) => {
      try {
        return (await stat(candidate)).isFile();
      } catch {
        return false;
      }
    },
    readRegistryValue: readWindowsRegistryValue,
  };
}

async function detectFromRegistry(host: TortoiseDetectionHost): Promise<string | undefined> {
  if (!host.readRegistryValue) {
    return undefined;
  }
  for (const query of REGISTRY_QUERIES) {
    const value = await host.readRegistryValue(query.hive, query.key, query.valueName);
    const candidate = registryValueToExecutablePath(value);
    if (
      candidate !== undefined &&
      isWindowsDriveOrUncPath(candidate) &&
      isTortoiseProcExecutableName(candidate) &&
      (await host.fileExists(candidate))
    ) {
      return candidate;
    }
  }
  return undefined;
}

async function detectFromCommonDirectories(host: TortoiseDetectionHost): Promise<string | undefined> {
  for (const directory of host.commonDirectories ?? []) {
    if (directory.trim().length === 0) {
      continue;
    }
    const candidate = path.win32.join(stripWrappingQuotes(directory.trim()), TORTOISE_PROC_EXE);
    if (isWindowsDriveOrUncPath(candidate) && (await host.fileExists(candidate))) {
      return candidate;
    }
  }
  return undefined;
}

async function detectFromPath(host: TortoiseDetectionHost): Promise<string | undefined> {
  for (const directory of pathDirectories(host.env)) {
    const candidate = path.win32.join(directory, TORTOISE_PROC_EXE);
    if (isWindowsDriveOrUncPath(candidate) && (await host.fileExists(candidate))) {
      return candidate;
    }
  }
  return undefined;
}

function available(
  executablePath: string,
  source: TortoiseDetectionSource,
  configDirectory: string | undefined,
): TortoiseDetectionResult {
  return {
    status: "available",
    executablePath,
    source,
    ...(configDirectory ? { configDirectory } : {}),
  };
}

function assertTortoiseProcExecutableName(pathValue: string, setting: string): void {
  if (!isTortoiseProcExecutableName(pathValue)) {
    throw new TortoiseDetectionError(
      "SUBVERSIONR_TORTOISE_EXECUTABLE_NAME_INVALID",
      "configuration",
      "error.tortoise.executableNameInvalid",
      { setting },
    );
  }
}

function assertWindowsDriveOrUncPath(pathValue: string, setting: string): void {
  if (!isWindowsDriveOrUncPath(pathValue)) {
    throw new TortoiseDetectionError(
      "SUBVERSIONR_TORTOISE_EXECUTABLE_PATH_INVALID",
      "configuration",
      "error.tortoise.executablePathInvalid",
      { setting },
    );
  }
}

function isWindowsDriveOrUncPath(pathValue: string): boolean {
  const normalized = pathValue.replaceAll("/", "\\");
  return (
    !hasDotSegment(normalized) &&
    (/^[A-Za-z]:\\/u.test(normalized) || /^\\\\[^\\]+\\[^\\]+(?:\\|$)/u.test(normalized))
  );
}

function isTortoiseProcExecutableName(pathValue: string): boolean {
  return path.win32.basename(pathValue).toLocaleLowerCase("en-US") === TORTOISE_PROC_EXE.toLocaleLowerCase("en-US");
}

function hasDotSegment(pathValue: string): boolean {
  return pathValue.split("\\").some((segment) => segment === "." || segment === "..");
}

function registryValueToExecutablePath(value: string | undefined): string | undefined {
  if (value === undefined || value.trim().length === 0) {
    return undefined;
  }
  const trimmed = stripWrappingQuotes(value.trim());
  if (isTortoiseProcExecutableName(trimmed)) {
    return trimmed;
  }
  return path.win32.join(trimmed, "bin", TORTOISE_PROC_EXE);
}

function pathDirectories(env: Record<string, string | undefined>): string[] {
  const rawPath = env.Path ?? env.PATH;
  if (rawPath === undefined || rawPath.trim().length === 0) {
    return [];
  }
  return rawPath
    .split(";")
    .map((part) => stripWrappingQuotes(part.trim()))
    .filter((part) => part.length > 0);
}

function defaultCommonDirectories(env: Record<string, string | undefined>): string[] {
  return [env.ProgramFiles, env["ProgramFiles(x86)"]]
    .filter((value): value is string => typeof value === "string" && value.trim().length > 0)
    .map((root) => path.win32.join(root, "TortoiseSVN", "bin"));
}

function stripWrappingQuotes(value: string): string {
  if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
    return value.slice(1, -1);
  }
  return value;
}

async function readWindowsRegistryValue(
  hive: string,
  key: string,
  valueName: string,
): Promise<string | undefined> {
  if (process.platform !== "win32") {
    return undefined;
  }
  const args = ["query", `${hive}\\${key}`, valueName.length === 0 ? "/ve" : "/v", valueName.length === 0 ? "" : valueName]
    .filter((arg) => arg.length > 0);

  return await new Promise((resolve) => {
    execFile("reg.exe", args, { windowsHide: true, maxBuffer: 64 * 1024 }, (error, stdout) => {
      if (error) {
        resolve(undefined);
        return;
      }
      resolve(parseRegistryQueryOutput(stdout, valueName));
    });
  });
}

function parseRegistryQueryOutput(output: string, valueName: string): string | undefined {
  const expectedName = valueName.length === 0 ? "(Default)" : valueName;
  for (const line of output.split(/\r?\n/u)) {
    const trimmed = line.trim();
    if (!trimmed.startsWith(expectedName)) {
      continue;
    }
    const match = /\sREG_\w+\s(.+)$/u.exec(trimmed);
    if (match?.[1]) {
      return match[1].trim();
    }
  }
  return undefined;
}
