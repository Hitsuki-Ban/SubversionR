import { createHash } from "node:crypto";

export type OperationJournalKind =
  | "add"
  | "branchCreate"
  | "changelistClear"
  | "changelistSet"
  | "cleanup"
  | "commit"
  | "lock"
  | "merge"
  | "mergePreview"
  | "move"
  | "propertyDelete"
  | "propertySet"
  | "relocate"
  | "remove"
  | "resolve"
  | "revert"
  | "switch"
  | "unlock"
  | "upgrade"
  | "update";
export type OperationJournalResultCategory =
  | "succeeded"
  | "cancelled"
  | "inputRejected"
  | "lifecycleRejected"
  | "protocolFailed"
  | "failed";
export type OperationJournalScanPlan = "none" | "targeted" | "full" | "unknown";

export interface OperationJournalEntry {
  kind: OperationJournalKind;
  repositoryHash: string;
  startedAt: string;
  endedAt: string;
  durationMs: number;
  resultCategory: OperationJournalResultCategory;
  scanPlan: OperationJournalScanPlan;
  touchedCount: number;
  retryCount: number;
  cancelled: boolean;
}

export interface OperationJournalRecord {
  kind: OperationJournalKind;
  repositoryId: string;
  startedAt: string;
  endedAt: string;
  durationMs: number;
  resultCategory: OperationJournalResultCategory;
  scanPlan: OperationJournalScanPlan;
  touchedCount: number;
  retryCount: number;
  cancelled: boolean;
}

export interface OperationJournalDiagnosticsSnapshot {
  entries: OperationJournalEntry[];
  recordingFailures: {
    count: number;
    lastCode: string | null;
  };
}

export class RepositoryOperationJournal {
  private readonly entries: OperationJournalEntry[] = [];
  private recordingFailureCount = 0;
  private lastRecordingFailureCode: string | null = null;

  public constructor(private readonly options: { maxEntries: number }) {
    if (!Number.isInteger(options.maxEntries) || options.maxEntries < 1) {
      throw new OperationJournalError(
        "SUBVERSIONR_OPERATION_JOURNAL_MAX_ENTRIES_INVALID",
        "error.operationJournal.maxEntriesInvalid",
      );
    }
  }

  public record(record: OperationJournalRecord): void {
    validateTimestamp(record.startedAt);
    validateTimestamp(record.endedAt);
    if (record.repositoryId.trim().length === 0) {
      throw new OperationJournalError(
        "SUBVERSIONR_OPERATION_JOURNAL_REPOSITORY_ID_INVALID",
        "error.operationJournal.repositoryIdInvalid",
      );
    }
    if (!Number.isInteger(record.durationMs) || record.durationMs < 0) {
      throw new OperationJournalError(
        "SUBVERSIONR_OPERATION_JOURNAL_DURATION_INVALID",
        "error.operationJournal.durationInvalid",
      );
    }
    if (!Number.isInteger(record.touchedCount) || record.touchedCount < 0) {
      throw new OperationJournalError(
        "SUBVERSIONR_OPERATION_JOURNAL_TOUCHED_COUNT_INVALID",
        "error.operationJournal.touchedCountInvalid",
      );
    }
    if (!Number.isInteger(record.retryCount) || record.retryCount < 0) {
      throw new OperationJournalError(
        "SUBVERSIONR_OPERATION_JOURNAL_RETRY_COUNT_INVALID",
        "error.operationJournal.retryCountInvalid",
      );
    }

    this.entries.push({
      kind: record.kind,
      repositoryHash: repositoryHash(record.repositoryId),
      startedAt: record.startedAt,
      endedAt: record.endedAt,
      durationMs: record.durationMs,
      resultCategory: record.resultCategory,
      scanPlan: record.scanPlan,
      touchedCount: record.touchedCount,
      retryCount: record.retryCount,
      cancelled: record.cancelled,
    });

    while (this.entries.length > this.options.maxEntries) {
      this.entries.shift();
    }
  }

  public snapshot(): OperationJournalEntry[] {
    return this.entries.map((entry) => ({ ...entry }));
  }

  public tryRecord(record: OperationJournalRecord): void {
    try {
      this.record(record);
    } catch (error) {
      this.recordingFailureCount += 1;
      this.lastRecordingFailureCode = operationJournalErrorCode(error);
    }
  }

  public diagnosticsSnapshot(): OperationJournalDiagnosticsSnapshot {
    return {
      entries: this.snapshot(),
      recordingFailures: {
        count: this.recordingFailureCount,
        lastCode: this.lastRecordingFailureCode,
      },
    };
  }
}

export class OperationJournalError extends Error {
  public readonly category = "diagnostics";

  public constructor(
    public readonly code: string,
    public readonly messageKey: string,
  ) {
    super(code);
    this.name = "OperationJournalError";
  }
}

function validateTimestamp(value: string): void {
  const parsed = Date.parse(value);
  if (!Number.isFinite(parsed)) {
    throw new OperationJournalError(
      "SUBVERSIONR_OPERATION_JOURNAL_TIMESTAMP_INVALID",
      "error.operationJournal.timestampInvalid",
    );
  }
}

function repositoryHash(repositoryId: string): string {
  return createHash("sha256").update(repositoryId, "utf8").digest("hex").slice(0, 16);
}

function operationJournalErrorCode(error: unknown): string {
  if (error instanceof OperationJournalError) {
    return error.code;
  }
  if (typeof error === "object" && error !== null && "code" in error) {
    const code = (error as { code?: unknown }).code;
    if (typeof code === "string" && code.trim().length > 0) {
      return code;
    }
  }
  return "SUBVERSIONR_OPERATION_JOURNAL_RECORD_FAILED";
}
