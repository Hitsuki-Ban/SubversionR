import { createHash } from "node:crypto";

export type WatcherOverflowSource = "native-watcher" | "vscode-watcher";

export interface WatcherOverflowRecord {
  repositoryId: string;
  epoch: number;
  timestamp: string;
  source: WatcherOverflowSource;
}

export interface WatcherOverflowDiagnosticsEntry {
  repositoryHash: string;
  epoch: number;
  timestamp: string;
  source: WatcherOverflowSource;
}

export interface WatcherOverflowDiagnosticsSnapshot {
  overflowCount: number;
  lastOverflow: WatcherOverflowDiagnosticsEntry | null;
}

export class WatcherOverflowDiagnostics {
  private overflowCount = 0;
  private lastOverflow: WatcherOverflowDiagnosticsEntry | null = null;

  public recordOverflow(record: WatcherOverflowRecord): void {
    requireNonEmptyString(record.repositoryId, "repositoryId");
    requireEpoch(record.epoch);
    requireTimestamp(record.timestamp);
    requireWatcherOverflowSource(record.source);

    this.overflowCount += 1;
    this.lastOverflow = {
      repositoryHash: repositoryHash(record.repositoryId),
      epoch: record.epoch,
      timestamp: record.timestamp,
      source: record.source,
    };
  }

  public diagnosticsSnapshot(): WatcherOverflowDiagnosticsSnapshot {
    return {
      overflowCount: this.overflowCount,
      lastOverflow: this.lastOverflow === null ? null : { ...this.lastOverflow },
    };
  }
}

export class WatcherOverflowDiagnosticsError extends Error {
  public readonly category = "diagnostics";

  public constructor(
    public readonly code: string,
    public readonly messageKey: string,
    public readonly safeArgs: Record<string, unknown> = {},
  ) {
    super(code);
    this.name = "WatcherOverflowDiagnosticsError";
  }
}

function requireNonEmptyString(value: string, field: string): void {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw watcherOverflowDiagnosticsError("SUBVERSIONR_WATCHER_OVERFLOW_DIAGNOSTICS_FIELD_INVALID", field);
  }
}

function requireEpoch(value: number): void {
  if (!Number.isSafeInteger(value) || value < 0) {
    throw watcherOverflowDiagnosticsError("SUBVERSIONR_WATCHER_OVERFLOW_DIAGNOSTICS_FIELD_INVALID", "epoch");
  }
}

function requireTimestamp(value: string): void {
  requireNonEmptyString(value, "timestamp");
  if (!Number.isFinite(Date.parse(value))) {
    throw watcherOverflowDiagnosticsError("SUBVERSIONR_WATCHER_OVERFLOW_DIAGNOSTICS_FIELD_INVALID", "timestamp");
  }
}

function requireWatcherOverflowSource(value: string): asserts value is WatcherOverflowSource {
  if (value !== "native-watcher" && value !== "vscode-watcher") {
    throw watcherOverflowDiagnosticsError("SUBVERSIONR_WATCHER_OVERFLOW_DIAGNOSTICS_FIELD_INVALID", "source");
  }
}

function watcherOverflowDiagnosticsError(code: string, field: string): WatcherOverflowDiagnosticsError {
  return new WatcherOverflowDiagnosticsError(code, "error.status.watcherOverflowDiagnosticsInvalid", { field });
}

function repositoryHash(repositoryId: string): string {
  return createHash("sha256").update(repositoryId, "utf8").digest("hex").slice(0, 16);
}
