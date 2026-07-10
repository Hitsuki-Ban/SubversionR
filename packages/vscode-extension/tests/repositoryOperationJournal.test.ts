import { describe, expect, it } from "vitest";
import { RepositoryOperationJournal } from "../src/operations/repositoryOperationJournal";

describe("RepositoryOperationJournal", () => {
  it("stores bounded sanitized operation entries with repository hashes", () => {
    const journal = new RepositoryOperationJournal({ maxEntries: 2 });

    journal.record({
      kind: "revert",
      repositoryId: "repo-uuid:C:/Users/Alice/checkout",
      startedAt: "2026-06-25T00:00:00.000Z",
      endedAt: "2026-06-25T00:00:00.250Z",
      durationMs: 250,
      resultCategory: "succeeded",
      scanPlan: "targeted",
      touchedCount: 1,
      retryCount: 0,
      cancelled: false,
    });
    journal.record({
      kind: "update",
      repositoryId: "repo-uuid:C:/Users/Alice/checkout",
      startedAt: "2026-06-25T00:00:01.000Z",
      endedAt: "2026-06-25T00:00:02.500Z",
      durationMs: 1500,
      resultCategory: "succeeded",
      scanPlan: "full",
      touchedCount: 3,
      retryCount: 0,
      cancelled: false,
    });
    journal.record({
      kind: "commit",
      repositoryId: "repo-uuid:C:/Users/Alice/checkout",
      startedAt: "2026-06-25T00:00:03.000Z",
      endedAt: "2026-06-25T00:00:03.100Z",
      durationMs: 100,
      resultCategory: "cancelled",
      scanPlan: "unknown",
      touchedCount: 2,
      retryCount: 0,
      cancelled: true,
    });

    const entries = journal.snapshot();

    expect(entries).toHaveLength(2);
    expect(entries[0]).toMatchObject({
      kind: "update",
      startedAt: "2026-06-25T00:00:01.000Z",
      endedAt: "2026-06-25T00:00:02.500Z",
      durationMs: 1500,
      resultCategory: "succeeded",
      scanPlan: "full",
      touchedCount: 3,
      retryCount: 0,
      cancelled: false,
    });
    expect(entries[1]).toMatchObject({
      kind: "commit",
      durationMs: 100,
      resultCategory: "cancelled",
      cancelled: true,
    });
    expect(entries[0]?.repositoryHash).toMatch(/^[0-9a-f]{16}$/u);
    expect(entries[0]?.repositoryHash).toBe(entries[1]?.repositoryHash);
    const json = JSON.stringify(entries);
    expect(json).not.toContain("repo-uuid");
    expect(json).not.toContain("Alice");
    expect(json).not.toContain("checkout");
  });

  it("uses explicit monotonic durations even when wall-clock timestamps move backward", () => {
    const journal = new RepositoryOperationJournal({ maxEntries: 1 });

    journal.record({
      kind: "update",
      repositoryId: "repo-uuid:C:/workspace",
      startedAt: "2026-06-25T00:00:02.000Z",
      endedAt: "2026-06-25T00:00:01.000Z",
      durationMs: 25,
      resultCategory: "succeeded",
      scanPlan: "full",
      touchedCount: 1,
      retryCount: 0,
      cancelled: false,
    });

    expect(journal.snapshot()).toEqual([
      expect.objectContaining({
        durationMs: 25,
        startedAt: "2026-06-25T00:00:02.000Z",
        endedAt: "2026-06-25T00:00:01.000Z",
      }),
    ]);
  });

  it("records branchCreate and switch operation kinds", () => {
    const journal = new RepositoryOperationJournal({ maxEntries: 2 });

    journal.record({
      kind: "branchCreate",
      repositoryId: "repo-uuid:C:/workspace",
      startedAt: "2026-06-25T00:00:00.000Z",
      endedAt: "2026-06-25T00:00:01.000Z",
      durationMs: 1000,
      resultCategory: "succeeded",
      scanPlan: "none",
      touchedCount: 0,
      retryCount: 0,
      cancelled: false,
    });
    journal.record({
      kind: "switch",
      repositoryId: "repo-uuid:C:/workspace",
      startedAt: "2026-06-25T00:00:02.000Z",
      endedAt: "2026-06-25T00:00:03.000Z",
      durationMs: 1000,
      resultCategory: "succeeded",
      scanPlan: "full",
      touchedCount: 1,
      retryCount: 0,
      cancelled: false,
    });

    expect(journal.snapshot().map((entry) => entry.kind)).toEqual(["branchCreate", "switch"]);
  });

  it("fails fast for invalid journal bounds and timestamps", () => {
    expect(() => new RepositoryOperationJournal({ maxEntries: 0 })).toThrow(
      "SUBVERSIONR_OPERATION_JOURNAL_MAX_ENTRIES_INVALID",
    );

    const journal = new RepositoryOperationJournal({ maxEntries: 1 });
    expect(() =>
      journal.record({
        kind: "cleanup",
        repositoryId: "repo-uuid:C:/workspace",
        startedAt: "invalid",
        endedAt: "2026-06-25T00:00:00.000Z",
        durationMs: 1,
        resultCategory: "failed",
        scanPlan: "unknown",
        touchedCount: 1,
        retryCount: 0,
        cancelled: false,
      }),
    ).toThrow("SUBVERSIONR_OPERATION_JOURNAL_TIMESTAMP_INVALID");

    expect(() =>
      journal.record({
        kind: "cleanup",
        repositoryId: "repo-uuid:C:/workspace",
        startedAt: "2026-06-25T00:00:00.000Z",
        endedAt: "2026-06-25T00:00:01.000Z",
        durationMs: -1,
        resultCategory: "failed",
        scanPlan: "unknown",
        touchedCount: 1,
        retryCount: 0,
        cancelled: false,
      }),
    ).toThrow("SUBVERSIONR_OPERATION_JOURNAL_DURATION_INVALID");
  });

  it("tracks failed best-effort writes for diagnostics", () => {
    const journal = new RepositoryOperationJournal({ maxEntries: 1 });

    journal.tryRecord({
      kind: "cleanup",
      repositoryId: "repo-uuid:C:/workspace",
      startedAt: "2026-06-25T00:00:00.000Z",
      endedAt: "2026-06-25T00:00:01.000Z",
      durationMs: -1,
      resultCategory: "failed",
      scanPlan: "unknown",
      touchedCount: 1,
      retryCount: 0,
      cancelled: false,
    });

    expect(journal.diagnosticsSnapshot()).toEqual({
      entries: [],
      recordingFailures: {
        count: 1,
        lastCode: "SUBVERSIONR_OPERATION_JOURNAL_DURATION_INVALID",
      },
    });
  });
});
