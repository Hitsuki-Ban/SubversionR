import type { CompletedStatusRefreshCoverage } from "./statusRefreshScheduler";

export class StatusRefreshCoverageStore {
  private readonly records = new Map<string, CompletedStatusRefreshCoverage>();

  public recordCompletedStatusRefreshCoverage(record: CompletedStatusRefreshCoverage): void {
    this.records.set(record.repositoryId, cloneCompletedRefreshCoverage(record));
  }

  public getLastCompletedRefresh(
    repositoryId: string,
    epoch: number,
  ): CompletedStatusRefreshCoverage | undefined {
    const record = this.records.get(repositoryId);
    if (!record || record.epoch !== epoch) {
      return undefined;
    }
    return cloneCompletedRefreshCoverage(record);
  }
}

function cloneCompletedRefreshCoverage(record: CompletedStatusRefreshCoverage): CompletedStatusRefreshCoverage {
  return {
    repositoryId: record.repositoryId,
    epoch: record.epoch,
    generation: record.generation,
    targets: record.targets.map((target) => ({ ...target })),
    coverage: record.coverage.map((scope) => ({ ...scope })),
    completeness: record.completeness,
    timestamp: record.timestamp,
    source: record.source,
  };
}
