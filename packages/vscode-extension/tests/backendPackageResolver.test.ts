import { describe, expect, it } from "vitest";
import { resolvePackagedBackendResources } from "../src/backend/backendPackageResolver";

describe("resolvePackagedBackendResources", () => {
  it("resolves Windows x64 packaged sidecar and bridge paths inside the extension", () => {
    const resources = resolvePackagedBackendResources({
      platform: "win32",
      arch: "x64",
      extensionResourcePath: windowsExtensionPath,
      isFile: () => true,
    });

    expect(resources).toEqual({
      target: "win32-x64",
      executablePath: "C:\\SubversionR\\extension\\resources\\backend\\win32-x64\\subversionr-daemon.exe",
      bridgeDllPath: "C:\\SubversionR\\extension\\resources\\backend\\win32-x64\\subversionr_svn_bridge.dll",
    });
  });

  it("rejects unsupported packaged backend targets without probing alternate locations", () => {
    expect(() =>
      resolvePackagedBackendResources({
        platform: "linux",
        arch: "x64",
        extensionResourcePath: (relativePath) => `/ext/${relativePath}`,
        isFile: () => true,
      }),
    ).toThrowError(
      expect.objectContaining({
        code: "SUBVERSIONR_BACKEND_PACKAGE_UNSUPPORTED_TARGET",
        category: "configuration",
        messageKey: "error.backend.packageUnsupportedTarget",
        safeArgs: { platform: "linux", arch: "x64" },
      }),
    );
  });

  it("fails fast when a packaged backend resource is missing without leaking the absolute path", () => {
    expect(() =>
      resolvePackagedBackendResources({
        platform: "win32",
        arch: "x64",
        extensionResourcePath: windowsExtensionPath,
        isFile: (candidate) => !candidate.endsWith("subversionr-daemon.exe"),
      }),
    ).toThrowError(
      expect.objectContaining({
        code: "SUBVERSIONR_BACKEND_PACKAGE_RESOURCE_MISSING",
        category: "configuration",
        messageKey: "error.backend.packageResourceMissing",
        safeArgs: { resource: "executablePath", target: "win32-x64" },
      }),
    );
  });

  it("rejects non-absolute packaged resource resolver output", () => {
    expect(() =>
      resolvePackagedBackendResources({
        platform: "win32",
        arch: "x64",
        extensionResourcePath: (relativePath) => relativePath,
        isFile: () => true,
      }),
    ).toThrowError(
      expect.objectContaining({
        code: "SUBVERSIONR_BACKEND_PACKAGE_PATH_NOT_ABSOLUTE",
        category: "configuration",
        messageKey: "error.backend.packagePathNotAbsolute",
        safeArgs: { resource: "executablePath", target: "win32-x64" },
      }),
    );
  });
});

function windowsExtensionPath(relativePath: string): string {
  return `C:\\SubversionR\\extension\\${relativePath.replace(/\//gu, "\\")}`;
}
