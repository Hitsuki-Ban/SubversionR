export type CheckoutUrlValidationResult =
  | { valid: true }
  | {
      valid: false;
      reason: "emptyOrControl" | "invalidUrl" | "unsupportedScheme" | "embeddedSecret";
    };

const SUPPORTED_CHECKOUT_PROTOCOLS = new Set(["file:", "http:", "https:", "svn:"]);

export function validateCheckoutUrl(value: string): CheckoutUrlValidationResult {
  const trimmed = value.trim();
  if (trimmed.length === 0 || /[\u0000-\u001F]/u.test(value)) {
    return { valid: false, reason: "emptyOrControl" };
  }
  if (isWindowsLocalPath(trimmed)) {
    return { valid: false, reason: "invalidUrl" };
  }
  let url: URL;
  try {
    url = new URL(trimmed);
  } catch {
    return { valid: false, reason: "invalidUrl" };
  }
  if (!isSupportedCheckoutProtocol(url.protocol)) {
    return { valid: false, reason: "unsupportedScheme" };
  }
  if (url.password.length > 0) {
    return { valid: false, reason: "embeddedSecret" };
  }
  return { valid: true };
}

function isSupportedCheckoutProtocol(protocol: string): boolean {
  return (
    SUPPORTED_CHECKOUT_PROTOCOLS.has(protocol) || (protocol.startsWith("svn+") && protocol.length > "svn+:".length)
  );
}

function isWindowsLocalPath(value: string): boolean {
  return /^[A-Za-z]:[\\/]/u.test(value) || /^\\\\/u.test(value);
}
