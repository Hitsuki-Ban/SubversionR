const REDACTION_MARKERS = new Set([
  "[REDACTED:secret]",
  "[REDACTED:repository-log]",
  "[REDACTED:source-content]",
]);

const SENSITIVE_KEY_PATTERN =
  /(?:password|passwd|passphrase|secret|token|authorization|cookie|credential|clientcertpassword)/iu;
const LOG_MESSAGE_KEY_PATTERN = /(?:logmessage|commitmessage|repositorylogmessage)/iu;
const SOURCE_CONTENT_KEY_PATTERN = /(?:sourcecontent|content|contentbase64|linebase64)/iu;
const REMOTE_AUTHORITY_KEY_PATTERN = /(?:remoteauthority|remotename|remotehost)/iu;

export function redactDiagnosticValue(value: unknown): unknown {
  return redactValue(value, "");
}

export function redactDiagnosticText(text: string): string {
  if (isRedactionMarker(text)) {
    return text;
  }
  let redacted = text;
  redacted = redacted.replace(urlPattern(), (match) => `[REDACTED:url:${hashToken(match)}]`);
  redacted = redacted.replace(windowsLongPathPattern(), (match) => `[REDACTED:path:${hashToken(match)}]`);
  redacted = redacted.replace(windowsSlashPathPattern(), (match) => `[REDACTED:path:${hashToken(match)}]`);
  redacted = redacted.replace(windowsDrivePathPattern(), (match) => `[REDACTED:path:${hashToken(match)}]`);
  redacted = redacted.replace(uncPathPattern(), (match) => `[REDACTED:path:${hashToken(match)}]`);
  redacted = redacted.replace(posixPathPattern(), (match) => `[REDACTED:path:${hashToken(match)}]`);
  redacted = redacted.replace(authorizationHeaderPattern(), "$1 [REDACTED:secret]");
  redacted = redacted.replace(cliSecretOptionPattern(), "$1 [REDACTED:secret]");
  redacted = redacted.replace(secretAssignmentPattern(), "$1=[REDACTED:secret]");
  return redacted;
}

function redactValue(value: unknown, key: string): unknown {
  if (typeof value === "string") {
    if (isPolicyWord(value)) {
      return value;
    }
    if (REMOTE_AUTHORITY_KEY_PATTERN.test(key) && value.trim().length > 0) {
      return `[REDACTED:remote:${hashToken(value)}]`;
    }
    if (SENSITIVE_KEY_PATTERN.test(key)) {
      return "[REDACTED:secret]";
    }
    if (LOG_MESSAGE_KEY_PATTERN.test(key)) {
      return "[REDACTED:repository-log]";
    }
    if (SOURCE_CONTENT_KEY_PATTERN.test(key)) {
      return "[REDACTED:source-content]";
    }
    return redactDiagnosticText(value);
  }
  if (Array.isArray(value)) {
    return value.map((item) => redactValue(item, key));
  }
  if (isRecord(value)) {
    const result: Record<string, unknown> = {};
    for (const [entryKey, entryValue] of Object.entries(value)) {
      result[entryKey] = redactValue(entryValue, entryKey);
    }
    return result;
  }
  return value;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function isRedactionMarker(value: string): boolean {
  return REDACTION_MARKERS.has(value) || /^\[REDACTED:(?:url|path|remote):[0-9a-f]{8}\]$/u.test(value);
}

function isPolicyWord(value: string): boolean {
  return value === "redacted" || value === "omitted";
}

function urlPattern(): RegExp {
  return /\b(?:https?|svn(?:\+ssh)?|ssh|file):\/\/[^\s"'<>]+/giu;
}

function windowsLongPathPattern(): RegExp {
  return /\\\\\?\\[A-Za-z]:\\[^\s"'<>]+/gu;
}

function windowsDrivePathPattern(): RegExp {
  return /\b[A-Za-z]:\\[^\s"'<>]+/gu;
}

function windowsSlashPathPattern(): RegExp {
  return /\b[A-Za-z]:\/[^\s"'<>]+/gu;
}

function uncPathPattern(): RegExp {
  return /\\\\[A-Za-z0-9._$ -]+\\[^\s"'<>]+/gu;
}

function posixPathPattern(): RegExp {
  return /(?:^|[\s("])\/(?:Users|home|var|tmp|private|workspace|workspaces|srv|opt)\/[^\s"'<>]+/gu;
}

function secretAssignmentPattern(): RegExp {
  return /\b(password|passwd|passphrase|token|secret|authorization|cookie)\s*[:=]\s*[^\s"',;]+/giu;
}

function authorizationHeaderPattern(): RegExp {
  return /\b(authorization\s*:)\s*(?:bearer|basic)\s+[^\s"',;]+/giu;
}

function cliSecretOptionPattern(): RegExp {
  return /(--(?:password|passwd|passphrase|token|secret))\s+[^\s"',;]+/giu;
}

function hashToken(value: string): string {
  let hash = 0x811c9dc5;
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193);
  }
  return (hash >>> 0).toString(16).padStart(8, "0");
}
