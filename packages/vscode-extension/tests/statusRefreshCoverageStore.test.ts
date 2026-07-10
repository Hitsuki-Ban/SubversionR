import { describe, expect, it } from "vitest";
import { StatusRefreshCoverageStore } from "../src/status/statusRefreshCoverageStore";
import type { CompletedStatusRefreshCoverage } from "../src/status/statusRefreshScheduler";

describe("StatusRefreshCoverageStore", () => {
  it("returns cloned completed refresh coverage records", () => {
    const store = new StatusRefreshCoverageStore();
    const record = coverageRecord();

    store.recordCompletedStatusRefreshCoverage(record);
    record.targets[0].path = "mutated-target.txt";
    record.coverage[0].path = "mutated-coverage.txt";
    const firstRead = store.getLastCompletedRefresh("repo-uuid:C:/wc", 7);
    firstRead!.targets[0].path = "mutated-read-target.txt";
    firstRead!.coverage[0].path = "mutated-read-coverage.txt";

    expect(store.getLastCompletedRefresh("repo-uuid:C:/wc", 7)).toEqual(coverageRecord());
  });

  it("replaces the latest coverage record per repository", () => {
    const store = new StatusRefreshCoverageStore();

    store.recordCompletedStatusRefreshCoverage(coverageRecord({ generation: 11, path: "src/first.c" }));
    store.recordCompletedStatusRefreshCoverage(coverageRecord({ generation: 12, path: "src/second.c" }));

    expect(store.getLastCompletedRefresh("repo-uuid:C:/wc", 7)).toEqual(
      coverageRecord({ generation: 12, path: "src/second.c" }),
    );
  });

  it("suppresses stale epoch coverage records", () => {
    const store = new StatusRefreshCoverageStore();

    store.recordCompletedStatusRefreshCoverage(coverageRecord({ epoch: 7 }));

    expect(store.getLastCompletedRefresh("repo-uuid:C:/wc", 8)).toBeUndefined();
  });
});

function coverageRecord(
  options: {
    repositoryId?: string;
    epoch?: number;
    generation?: number;
    path?: string;
  } = {},
): CompletedStatusRefreshCoverage {
  const repositoryId = options.repositoryId ?? "repo-uuid:C:/wc";
  const epoch = options.epoch ?? 7;
  const generation = options.generation ?? 11;
  const path = options.path ?? "load/modified-001.txt";
  return {
    repositoryId,
    epoch,
    generation,
    targets: [{ path, depth: "empty", reason: "resourceRefresh" }],
    coverage: [{ path, depth: "empty", generation, reason: "resourceRefresh" }],
    completeness: "partial",
    timestamp: "2026-06-25T00:00:12Z",
    source: "libsvn-local",
  };
}
