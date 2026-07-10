import path from "node:path";
import { BackendLaunchError } from "./backendProcess";

export interface BackendPackageResources {
  target: string;
  executablePath: string;
  bridgeDllPath: string;
}

export interface BackendPackageResolverContext {
  platform: NodeJS.Platform | string;
  arch: string;
  extensionResourcePath(relativePath: string): string;
  isFile(absolutePath: string): boolean;
}

type BackendPackageResourceName = "executablePath" | "bridgeDllPath";

const WINDOWS_X64_TARGET = "win32-x64";

export function resolvePackagedBackendResources(context: BackendPackageResolverContext): BackendPackageResources {
  const target = packagedBackendTarget(context.platform, context.arch);
  return {
    target,
    executablePath: resolvePackagedResource(context, target, "executablePath", "subversionr-daemon.exe"),
    bridgeDllPath: resolvePackagedResource(context, target, "bridgeDllPath", "subversionr_svn_bridge.dll"),
  };
}

function packagedBackendTarget(platform: NodeJS.Platform | string, arch: string): string {
  if (platform === "win32" && arch === "x64") {
    return WINDOWS_X64_TARGET;
  }
  throw new BackendLaunchError(
    "SUBVERSIONR_BACKEND_PACKAGE_UNSUPPORTED_TARGET",
    "configuration",
    "error.backend.packageUnsupportedTarget",
    { platform, arch },
  );
}

function resolvePackagedResource(
  context: BackendPackageResolverContext,
  target: string,
  resource: BackendPackageResourceName,
  fileName: string,
): string {
  const absolutePath = context.extensionResourcePath(`resources/backend/${target}/${fileName}`);
  if (!isAbsolutePath(absolutePath)) {
    throw packagedResourceError(
      "SUBVERSIONR_BACKEND_PACKAGE_PATH_NOT_ABSOLUTE",
      "error.backend.packagePathNotAbsolute",
      resource,
      target,
    );
  }
  if (!context.isFile(absolutePath)) {
    throw packagedResourceError(
      "SUBVERSIONR_BACKEND_PACKAGE_RESOURCE_MISSING",
      "error.backend.packageResourceMissing",
      resource,
      target,
    );
  }
  return absolutePath;
}

function packagedResourceError(
  code: string,
  messageKey: string,
  resource: BackendPackageResourceName,
  target: string,
): BackendLaunchError {
  return new BackendLaunchError(code, "configuration", messageKey, { resource, target });
}

function isAbsolutePath(candidate: string): boolean {
  return path.isAbsolute(candidate) || path.win32.isAbsolute(candidate) || path.posix.isAbsolute(candidate);
}
