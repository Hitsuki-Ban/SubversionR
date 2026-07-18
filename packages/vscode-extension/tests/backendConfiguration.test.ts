import { describe, expect, it } from "vitest";
import { backendLaunchConfigFromPackageResources } from "../src/backend/backendConfiguration";

describe("backendLaunchConfigFromPackageResources", () => {
  it("creates the launch config from packaged resources in an untrusted workspace", () => {
    const config = backendLaunchConfigFromPackageResources(packagedResources(), {
      ...trustedContext(),
      workspaceTrusted: false,
    });

    expect(config).toEqual({
      executablePath: "C:\\SubversionR\\extension\\resources\\backend\\win32-x64\\subversionr-daemon.exe",
      bridgeDllPath: "C:\\SubversionR\\extension\\resources\\backend\\win32-x64\\subversionr_svn_bridge.dll",
      cacheRoot: "C:\\Users\\Alice\\AppData\\Roaming\\Code\\User\\globalStorage\\subversionr\\cache",
      remoteStateRoot: "C:\\Users\\Alice\\AppData\\Roaming\\Code\\User\\globalStorage\\subversionr\\remote-state",
      clientName: "SubversionR",
      clientVersion: "0.1.0",
      locale: "en",
      workspaceTrust: "untrusted",
      baseEnv: {
        Path: "C:\\Windows\\System32",
      },
    });
  });

  it("requires an explicit client name", () => {
    expect(() =>
      backendLaunchConfigFromPackageResources(packagedResources(), {
        ...trustedContext(),
        clientName: "",
      }),
    ).toThrowError(
      expect.objectContaining({
        code: "SUBVERSIONR_BACKEND_CONFIG_REQUIRED",
        category: "configuration",
        messageKey: "error.backend.configRequired",
        safeArgs: { field: "clientName" },
      }),
    );
  });

  it("requires an explicit locale", () => {
    expect(() =>
      backendLaunchConfigFromPackageResources(packagedResources(), {
        ...trustedContext(),
        locale: "",
      }),
    ).toThrowError(
      expect.objectContaining({
        code: "SUBVERSIONR_BACKEND_CONFIG_REQUIRED",
        category: "configuration",
        messageKey: "error.backend.configRequired",
        safeArgs: { field: "locale" },
      }),
    );
  });

  it("requires an explicit cache root", () => {
    expect(() =>
      backendLaunchConfigFromPackageResources(packagedResources(), {
        ...trustedContext(),
        cacheRoot: "",
      }),
    ).toThrowError(
      expect.objectContaining({
        code: "SUBVERSIONR_BACKEND_CONFIG_REQUIRED",
        category: "configuration",
        messageKey: "error.backend.configRequired",
        safeArgs: { field: "cacheRoot" },
      }),
    );
  });

  it("requires an explicit remote state root", () => {
    expect(() =>
      backendLaunchConfigFromPackageResources(packagedResources(), {
        ...trustedContext(),
        remoteStateRoot: "",
      }),
    ).toThrowError(
      expect.objectContaining({
        code: "SUBVERSIONR_BACKEND_CONFIG_REQUIRED",
        category: "configuration",
        messageKey: "error.backend.configRequired",
        safeArgs: { field: "remoteStateRoot" },
      }),
    );
  });
});

function packagedResources() {
  return {
    target: "win32-x64",
    executablePath: "C:\\SubversionR\\extension\\resources\\backend\\win32-x64\\subversionr-daemon.exe",
    bridgeDllPath: "C:\\SubversionR\\extension\\resources\\backend\\win32-x64\\subversionr_svn_bridge.dll",
  };
}

function trustedContext() {
  return {
    clientName: "SubversionR",
    clientVersion: "0.1.0",
    locale: "en",
    cacheRoot: "C:\\Users\\Alice\\AppData\\Roaming\\Code\\User\\globalStorage\\subversionr\\cache",
    remoteStateRoot: "C:\\Users\\Alice\\AppData\\Roaming\\Code\\User\\globalStorage\\subversionr\\remote-state",
    workspaceTrusted: true,
    baseEnv: {
      Path: "C:\\Windows\\System32",
    },
  };
}
