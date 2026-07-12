import { Buffer } from "node:buffer";
import { redactDiagnosticValue } from "./diagnosticsRedaction";

const MAX_DIAGNOSTIC_DEPTH = 5;
const MAX_DIAGNOSTIC_KEYS = 24;
const MAX_DIAGNOSTIC_ITEMS = 24;
const MAX_DIAGNOSTIC_STRING_LENGTH = 512;
const MAX_DIAGNOSTIC_LINE_BYTES = 4096;
const MAX_DIAGNOSTIC_LINES = 100;

export interface OperationLogChannel {
  clear(): void;
  error(message: string): void;
  show(preserveFocus?: boolean): void;
}

export interface StructuredOperationError {
  code: string;
  category: string;
  messageKey: string;
  safeArgs: Record<string, unknown>;
  retryable: boolean;
  diagnostics: unknown;
}

export class OperationDiagnostics {
  private readonly recordedErrors = new WeakSet<object>();
  private readonly lines: string[] = [];

  public constructor(private readonly channel: OperationLogChannel) {}

  public recordRpcFailure(method: string, error: unknown): void {
    this.recordFailure(`rpc:${boundedString(method)}`, error);
  }

  public recordFailure(operation: string, error: unknown): void {
    if (typeof error === "object" && error !== null) {
      if (this.recordedErrors.has(error)) {
        return;
      }
      this.recordedErrors.add(error);
    }

    const structured = structuredOperationError(error);
    const diagnostic = boundedDiagnosticValue(
      redactDiagnosticValue(
        {
          operation: boundedString(operation),
          ...(structured
            ? {
                code: structured.code,
                category: structured.category,
                messageKey: structured.messageKey,
                retryable: structured.retryable,
                args: structured.safeArgs,
                diagnostics: structured.diagnostics,
              }
            : {
                code: errorCode(error),
                category: "unstructured",
              }),
        },
      ),
    );
    const line = boundedUtf8String(JSON.stringify(diagnostic), MAX_DIAGNOSTIC_LINE_BYTES);
    this.lines.push(line);
    if (this.lines.length > MAX_DIAGNOSTIC_LINES) {
      this.lines.shift();
      this.channel.clear();
      for (const retainedLine of this.lines) {
        this.channel.error(retainedLine);
      }
      return;
    }
    this.channel.error(line);
  }

  public show(): void {
    this.channel.show(true);
  }

  public snapshot(): readonly string[] {
    return [...this.lines];
  }
}

export function structuredOperationError(error: unknown): StructuredOperationError | undefined {
  if (typeof error !== "object" || error === null) {
    return undefined;
  }
  const value = error as Record<string, unknown>;
  if (
    typeof value.code !== "string" ||
    value.code.trim().length === 0 ||
    typeof value.category !== "string" ||
    value.category.trim().length === 0 ||
    typeof value.messageKey !== "string" ||
    value.messageKey.trim().length === 0 ||
    typeof value.safeArgs !== "object" ||
    value.safeArgs === null ||
    Array.isArray(value.safeArgs) ||
    typeof value.retryable !== "boolean"
  ) {
    return undefined;
  }
  return {
    code: value.code,
    category: value.category,
    messageKey: value.messageKey,
    safeArgs: value.safeArgs as Record<string, unknown>,
    retryable: value.retryable,
    diagnostics: "diagnostics" in value ? value.diagnostics : null,
  };
}

function boundedDiagnosticValue(value: unknown, depth = 0): unknown {
  if (typeof value === "string") {
    return boundedString(value);
  }
  if (value === null || typeof value === "number" || typeof value === "boolean") {
    return value;
  }
  if (depth >= MAX_DIAGNOSTIC_DEPTH) {
    return "[TRUNCATED:depth]";
  }
  if (Array.isArray(value)) {
    const items = value
      .slice(0, MAX_DIAGNOSTIC_ITEMS)
      .map((item) => boundedDiagnosticValue(item, depth + 1));
    if (value.length > MAX_DIAGNOSTIC_ITEMS) {
      items.push(`[TRUNCATED:${value.length - MAX_DIAGNOSTIC_ITEMS} items]`);
    }
    return items;
  }
  if (typeof value === "object") {
    const entries = Object.entries(value as Record<string, unknown>);
    const result: Record<string, unknown> = {};
    for (const [key, entryValue] of entries.slice(0, MAX_DIAGNOSTIC_KEYS)) {
      result[boundedString(key, 128)] = boundedDiagnosticValue(entryValue, depth + 1);
    }
    if (entries.length > MAX_DIAGNOSTIC_KEYS) {
      result.truncatedKeys = entries.length - MAX_DIAGNOSTIC_KEYS;
    }
    return result;
  }
  return `[OMITTED:${typeof value}]`;
}

function boundedString(value: string, limit = MAX_DIAGNOSTIC_STRING_LENGTH): string {
  if (value.length <= limit) {
    return value;
  }
  return `${value.slice(0, limit)}[TRUNCATED:${value.length - limit}]`;
}

function boundedUtf8String(value: string, limitBytes: number): string {
  if (Buffer.byteLength(value, "utf8") <= limitBytes) {
    return value;
  }
  const marker = "[TRUNCATED]";
  const contentLimit = limitBytes - Buffer.byteLength(marker, "utf8");
  let content = "";
  let contentBytes = 0;
  for (const character of value) {
    const characterBytes = Buffer.byteLength(character, "utf8");
    if (contentBytes + characterBytes > contentLimit) {
      break;
    }
    content += character;
    contentBytes += characterBytes;
  }
  return `${content}${marker}`;
}

function errorCode(error: unknown): string {
  if (typeof error === "object" && error !== null && "code" in error) {
    const code = (error as { code?: unknown }).code;
    if (typeof code === "string" && code.trim().length > 0) {
      return boundedString(code, 128);
    }
  }
  return "SUBVERSIONR_OPERATION_FAILED";
}
