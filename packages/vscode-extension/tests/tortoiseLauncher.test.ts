import { EventEmitter } from "node:events";
import { describe, expect, it, vi } from "vitest";
import {
  TortoiseLaunchError,
  buildTortoiseArgs,
  launchTortoise,
  type TortoiseSpawner,
} from "../src/tortoise/tortoiseLauncher";

describe("TortoiseSVN launcher", () => {
  it("builds allowlisted log arguments with separate path and configdir parameters", () => {
    expect(
      buildTortoiseArgs({
        intent: "log",
        path: "C:\\workspace",
        configDirectory: "C:\\Users\\Alice\\AppData\\Roaming\\Subversion",
      }),
    ).toEqual([
      "/command:log",
      "/path:C:\\workspace",
      "/configdir:C:\\Users\\Alice\\AppData\\Roaming\\Subversion",
    ]);
  });

  it("builds read-only file intent arguments without output or log-message switches", () => {
    expect(buildTortoiseArgs({ intent: "diff", path: "C:\\workspace\\src\\main.c" })).toEqual([
      "/command:diff",
      "/path:C:\\workspace\\src\\main.c",
      "/ignoreprops",
    ]);
    expect(buildTortoiseArgs({ intent: "revisiongraph", path: "C:\\workspace" })).toEqual([
      "/command:revisiongraph",
      "/path:C:\\workspace",
    ]);
    expect(buildTortoiseArgs({ intent: "repobrowser", path: "C:\\workspace" })).toEqual([
      "/command:repobrowser",
      "/path:C:\\workspace",
    ]);
    expect(buildTortoiseArgs({ intent: "blame", path: "C:\\workspace\\src\\main.c" })).toEqual([
      "/command:blame",
      "/path:C:\\workspace\\src\\main.c",
    ]);
  });

  it("rejects unsupported mutating Tortoise commands", () => {
    expect(() =>
      buildTortoiseArgs({ intent: "commit" as "log", path: "C:\\workspace" }),
    ).toThrowError(
      expect.objectContaining({
        code: "SUBVERSIONR_TORTOISE_INTENT_UNSUPPORTED",
        messageKey: "error.tortoise.intentUnsupported",
      }),
    );
  });

  it("rejects path separators that would be interpreted as multi-path command syntax", () => {
    expect(() => buildTortoiseArgs({ intent: "log", path: "C:\\workspace*D:\\other" })).toThrowError(
      expect.objectContaining({
        code: "SUBVERSIONR_TORTOISE_PATH_INVALID",
        safeArgs: { field: "path" },
      }),
    );
  });

  it("rejects root-relative and POSIX-shaped paths before passing them to TortoiseProc.exe", () => {
    expect(() => buildTortoiseArgs({ intent: "log", path: "/tmp/workspace" })).toThrowError(
      expect.objectContaining({
        code: "SUBVERSIONR_TORTOISE_PATH_INVALID",
        safeArgs: { field: "path" },
      }),
    );
    expect(() => buildTortoiseArgs({ intent: "log", path: "\\workspace" })).toThrowError(
      expect.objectContaining({
        code: "SUBVERSIONR_TORTOISE_PATH_INVALID",
        safeArgs: { field: "path" },
      }),
    );
  });

  it("rejects dot-segment paths before passing them to TortoiseProc.exe", () => {
    expect(() => buildTortoiseArgs({ intent: "log", path: "C:\\workspace\\..\\outside" })).toThrowError(
      expect.objectContaining({
        code: "SUBVERSIONR_TORTOISE_PATH_INVALID",
        safeArgs: { field: "path" },
      }),
    );
  });

  it("spawns TortoiseProc.exe with shell disabled and no command-line string concatenation", async () => {
    const spawner = fakeSpawner();

    await launchTortoise(
      {
        executablePath: "C:\\Tools\\TortoiseSVN\\bin\\TortoiseProc.exe",
        intent: "log",
        path: "C:\\workspace",
      },
      spawner,
    );

    expect(spawner.spawn).toHaveBeenCalledWith(
      "C:\\Tools\\TortoiseSVN\\bin\\TortoiseProc.exe",
      ["/command:log", "/path:C:\\workspace"],
      {
        shell: false,
        stdio: "ignore",
        windowsHide: false,
      },
    );
  });

  it("surfaces spawn errors with a stable Tortoise launch code", async () => {
    const spawner = fakeSpawner(new Error("spawn failed"));

    await expect(
      launchTortoise(
        {
          executablePath: "C:\\Tools\\TortoiseSVN\\bin\\TortoiseProc.exe",
          intent: "log",
          path: "C:\\workspace",
        },
        spawner,
      ),
    ).rejects.toBeInstanceOf(TortoiseLaunchError);
  });
});

function fakeSpawner(error?: Error): TortoiseSpawner & {
  spawn: ReturnType<typeof vi.fn<TortoiseSpawner["spawn"]>>;
} {
  return {
    spawn: vi.fn(() => {
      const child = new EventEmitter();
      queueMicrotask(() => {
        if (error) {
          child.emit("error", error);
          return;
        }
        child.emit("spawn");
      });
      return child;
    }),
  };
}
