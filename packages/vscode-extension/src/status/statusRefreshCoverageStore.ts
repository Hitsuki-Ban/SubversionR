import type { CompletedStatusRefreshCoverage } from "./statusRefreshScheduler";
import type { StatusRefreshTarget } from "./types";

const MAX_COMPLETED_REFRESH_RECORDS_PER_REPOSITORY = 32;

export class StatusRefreshCoverageStore {
  private readonly records = new Map<string, CompletedStatusRefreshCoverage[]>();
  private readonly listeners = new Set<(record: CompletedStatusRefreshCoverage) => void>();

  public recordCompletedStatusRefreshCoverage(record: CompletedStatusRefreshCoverage): void {
    const records = this.records.get(record.repositoryId) ?? [];
    records.push(cloneCompletedRefreshCoverage(record));
    if (records.length > MAX_COMPLETED_REFRESH_RECORDS_PER_REPOSITORY) {
      records.splice(0, records.length - MAX_COMPLETED_REFRESH_RECORDS_PER_REPOSITORY);
    }
    this.records.set(record.repositoryId, records);
    for (const listener of this.listeners) {
      listener(cloneCompletedRefreshCoverage(record));
    }
  }

  public onDidRecordCompletedStatusRefreshCoverage(
    listener: (record: CompletedStatusRefreshCoverage) => void,
  ): { dispose(): void } {
    this.listeners.add(listener);
    return {
      dispose: () => {
        this.listeners.delete(listener);
      },
    };
  }

  public getLastCompletedRefresh(
    repositoryId: string,
    epoch: number,
  ): CompletedStatusRefreshCoverage | undefined {
    const record = findLastRecord(this.records.get(repositoryId), (candidate) => candidate.epoch === epoch);
    if (!record) {
      return undefined;
    }
    return cloneCompletedRefreshCoverage(record);
  }

  public getLastCompletedRefreshMatchingTarget(
    repositoryId: string,
    epoch: number,
    target: StatusRefreshTarget,
  ): CompletedStatusRefreshCoverage | undefined {
    const record = findLastRecord(
      this.records.get(repositoryId),
      (candidate) =>
        candidate.epoch === epoch &&
        candidate.targets.some(
          (candidateTarget) =>
            candidateTarget.path === target.path &&
            candidateTarget.depth === target.depth &&
            candidateTarget.reason === target.reason,
        ),
    );
    return record ? cloneCompletedRefreshCoverage(record) : undefined;
  }
}

function findLastRecord(
  records: readonly CompletedStatusRefreshCoverage[] | undefined,
  predicate: (record: CompletedStatusRefreshCoverage) => boolean,
): CompletedStatusRefreshCoverage | undefined {
  if (!records) {
    return undefined;
  }
  for (let index = records.length - 1; index >= 0; index -= 1) {
    const record = records[index];
    if (record && predicate(record)) {
      return record;
    }
  }
  return undefined;
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
