import * as nodePath from "node:path";

export function suggestedCheckoutTargetPath(
  repositoryUrl: string,
  workspaceRoots: readonly string[],
  platform: NodeJS.Platform = process.platform,
): string | undefined {
  const [workspaceRoot] = workspaceRoots;
  if (workspaceRoot === undefined || workspaceRoot.trim().length === 0) {
    return undefined;
  }
  const targetName = checkoutTargetName(repositoryUrl, platform);
  if (targetName === undefined) {
    return undefined;
  }
  return pathModule(platform).join(workspaceRoot, targetName);
}

function checkoutTargetName(repositoryUrl: string, platform: NodeJS.Platform): string | undefined {
  let parsed: URL;
  try {
    parsed = new URL(repositoryUrl.trim());
  } catch {
    return undefined;
  }
  const leaf = parsed.pathname
    .split("/")
    .filter((part) => part.length > 0)
    .at(-1);
  if (leaf === undefined) {
    return undefined;
  }
  let decodedLeaf: string;
  try {
    decodedLeaf = decodeURIComponent(leaf);
  } catch {
    return undefined;
  }
  const sanitized = sanitizeTargetName(decodedLeaf, platform);
  return sanitized.length > 0 ? sanitized : undefined;
}

function sanitizeTargetName(value: string, platform: NodeJS.Platform): string {
  const reservedNamePattern = platform === "win32" ? /[<>:"/\\|?*\u0000-\u001F]+/gu : /[\/\u0000]+/gu;
  const sanitized = value.replace(reservedNamePattern, "-").replace(/[. ]+$/gu, "").trim();
  if (platform === "win32" && isWindowsReservedDeviceName(sanitized)) {
    return withWindowsDeviceNameSuffix(sanitized);
  }
  return sanitized;
}

function pathModule(platform: NodeJS.Platform): typeof nodePath.win32 | typeof nodePath.posix {
  return platform === "win32" ? nodePath.win32 : nodePath.posix;
}

function isWindowsReservedDeviceName(value: string): boolean {
  const stem = value.split(".")[0]?.toLocaleUpperCase("en-US");
  return (
    stem === "CON" ||
    stem === "PRN" ||
    stem === "AUX" ||
    stem === "NUL" ||
    /^COM[1-9]$/u.test(stem ?? "") ||
    /^LPT[1-9]$/u.test(stem ?? "")
  );
}

function withWindowsDeviceNameSuffix(value: string): string {
  const extensionStart = value.indexOf(".");
  if (extensionStart === -1) {
    return `${value}-wc`;
  }
  return `${value.slice(0, extensionStart)}-wc${value.slice(extensionStart)}`;
}
