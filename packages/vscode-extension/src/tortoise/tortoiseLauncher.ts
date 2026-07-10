import { EventEmitter } from "node:events";
import { spawn } from "node:child_process";

export type TortoiseIntent = "log" | "diff" | "revisiongraph" | "repobrowser" | "blame";
export type TortoiseLaunchErrorCategory = "input" | "lifecycle";

export interface TortoiseLaunchRequest {
  executablePath: string;
  intent: TortoiseIntent;
  path: string;
  configDirectory?: string;
}

export interface TortoiseSpawner {
  spawn(
    command: string,
    args: string[],
    options: {
      shell: false;
      stdio: "ignore";
      windowsHide: false;
    },
  ): Pick<EventEmitter, "once">;
}

export class TortoiseLaunchError extends Error {
  public constructor(
    public readonly code: string,
    public readonly category: TortoiseLaunchErrorCategory,
    public readonly messageKey: string,
    public readonly safeArgs: Record<string, unknown> = {},
    options?: ErrorOptions,
  ) {
    super(code, options);
    this.name = "TortoiseLaunchError";
  }
}

const COMMANDS: Record<TortoiseIntent, string> = {
  log: "log",
  diff: "diff",
  revisiongraph: "revisiongraph",
  repobrowser: "repobrowser",
  blame: "blame",
};

const DEFAULT_SPAWNER: TortoiseSpawner = {
  spawn: (command, args, options) => spawn(command, args, options),
};

export function buildTortoiseArgs(request: {
  intent: TortoiseIntent;
  path: string;
  configDirectory?: string;
}): string[] {
  const command = COMMANDS[request.intent];
  if (command === undefined) {
    throw new TortoiseLaunchError(
      "SUBVERSIONR_TORTOISE_INTENT_UNSUPPORTED",
      "input",
      "error.tortoise.intentUnsupported",
      { intent: String(request.intent) },
    );
  }
  assertSafeLocalPath(request.path, "path");
  if (request.configDirectory !== undefined) {
    assertSafeLocalPath(request.configDirectory, "configDirectory");
  }

  const args = [`/command:${command}`, `/path:${request.path}`];
  if (request.intent === "diff") {
    args.push("/ignoreprops");
  }
  if (request.configDirectory !== undefined) {
    args.push(`/configdir:${request.configDirectory}`);
  }
  return args;
}

export async function launchTortoise(
  request: TortoiseLaunchRequest,
  spawner: TortoiseSpawner = DEFAULT_SPAWNER,
): Promise<void> {
  assertSafeLocalPath(request.executablePath, "executablePath");
  const args = buildTortoiseArgs(request);

  await new Promise<void>((resolve, reject) => {
    const child = spawner.spawn(request.executablePath, args, {
      shell: false,
      stdio: "ignore",
      windowsHide: false,
    });
    child.once("spawn", () => resolve());
    child.once("error", (error) => {
      reject(
        new TortoiseLaunchError(
          "SUBVERSIONR_TORTOISE_LAUNCH_FAILED",
          "lifecycle",
          "error.tortoise.launchFailed",
          {},
          { cause: error },
        ),
      );
    });
  });
}

function assertSafeLocalPath(value: string, field: string): void {
  if (
    typeof value !== "string" ||
    value.trim().length === 0 ||
    value.includes("\0") ||
    value.includes("\r") ||
    value.includes("\n") ||
    value.includes("*") ||
    !isWindowsDriveOrUncPath(value)
  ) {
    throw new TortoiseLaunchError(
      "SUBVERSIONR_TORTOISE_PATH_INVALID",
      "input",
      "error.tortoise.pathInvalid",
      { field },
    );
  }
}

function isWindowsDriveOrUncPath(value: string): boolean {
  const normalized = value.replaceAll("/", "\\");
  return (
    !hasDotSegment(normalized) &&
    (/^[A-Za-z]:\\/u.test(normalized) || /^\\\\[^\\]+\\[^\\]+(?:\\|$)/u.test(normalized))
  );
}

function hasDotSegment(value: string): boolean {
  return value.split("\\").some((segment) => segment === "." || segment === "..");
}
