export const CURRENT_CACHE_SCHEMA_VERSION = 1;

const CACHE_SCHEMA_VERSION_KEY = "subversionr.cache.schemaVersion";
const CACHE_MIGRATION_REPORT_KEY = "subversionr.cache.lastMigrationReport";

export interface CacheMemento {
  get<T>(key: string): T | undefined;
  update(key: string, value: unknown): Thenable<void>;
}

export interface CacheUri {
  scheme: string;
  path: string;
}

export interface CacheStorageRoot {
  scope: "workspace" | "global";
  uri: CacheUri;
}

export type CacheClearStatus = "deleted" | "missing";

export interface CacheLifecycleServiceOptions {
  workspaceState: CacheMemento;
  storageRoots: readonly CacheStorageRoot[];
  deleteTree(uri: CacheUri): Promise<CacheClearStatus>;
  now(): string;
}

export interface CacheMigrationReport {
  kind: "subversionr.cacheMigrationReport";
  generatedAt: string;
  currentSchemaVersion: number;
  previousSchemaVersion: number | undefined;
  action: "initialized" | "unchanged" | "schema-reset" | "cleared";
  reason:
    | "missing-schema"
    | "current-schema"
    | "stale-schema"
    | "future-schema"
    | "manual-clear";
  workingCopyMutation: "none";
  storageRoots: CacheMigrationStorageRoot[];
  releaseTraceIds: ["MIG-008", "MIG-010", "MIG-011", "SEC-013"];
}

export interface CacheMigrationStorageRoot {
  scope: "workspace" | "global";
  uriScheme: string;
  status: CacheClearStatus;
}

export class CacheLifecycleService {
  public constructor(private readonly options: CacheLifecycleServiceOptions) {}

  public async ensureCurrentSchema(): Promise<CacheMigrationReport> {
    const previousSchemaVersion = this.readPersistedSchemaVersion();
    if (previousSchemaVersion === CURRENT_CACHE_SCHEMA_VERSION) {
      const report = this.createReport({
        action: "unchanged",
        reason: "current-schema",
        previousSchemaVersion,
        storageRoots: [],
      });
      await this.storeReport(report);
      return report;
    }

    if (previousSchemaVersion === undefined) {
      await this.persistCurrentSchemaVersion();
      const report = this.createReport({
        action: "initialized",
        reason: "missing-schema",
        previousSchemaVersion,
        storageRoots: [],
      });
      await this.storeReport(report);
      return report;
    }

    const reason = previousSchemaVersion < CURRENT_CACHE_SCHEMA_VERSION ? "stale-schema" : "future-schema";
    const storageRoots = await this.deleteCacheRoots();
    await this.persistCurrentSchemaVersion();
    const report = this.createReport({
      action: "schema-reset",
      reason,
      previousSchemaVersion,
      storageRoots,
    });
    await this.storeReport(report);
    return report;
  }

  public async clearCache(reason: "manual-clear"): Promise<CacheMigrationReport> {
    const previousSchemaVersion = this.readPersistedSchemaVersion();
    const storageRoots = await this.deleteCacheRoots();
    await this.persistCurrentSchemaVersion();
    const report = this.createReport({
      action: "cleared",
      reason,
      previousSchemaVersion,
      storageRoots,
    });
    await this.storeReport(report);
    return report;
  }

  public lastMigrationReport(): CacheMigrationReport | undefined {
    return this.options.workspaceState.get<CacheMigrationReport>(CACHE_MIGRATION_REPORT_KEY);
  }

  private async deleteCacheRoots(): Promise<CacheMigrationStorageRoot[]> {
    const results: CacheMigrationStorageRoot[] = [];
    for (const root of this.options.storageRoots) {
      const status = await this.options.deleteTree(root.uri);
      results.push({
        scope: root.scope,
        uriScheme: root.uri.scheme,
        status,
      });
    }
    return results;
  }

  private readPersistedSchemaVersion(): number | undefined {
    const version = this.options.workspaceState.get<unknown>(CACHE_SCHEMA_VERSION_KEY);
    if (version === undefined) {
      return undefined;
    }
    if (typeof version !== "number" || !Number.isInteger(version)) {
      throw new CacheLifecycleError(
        "SUBVERSIONR_CACHE_SCHEMA_METADATA_INVALID",
        "error.cache.schemaMetadataInvalid",
      );
    }
    return version;
  }

  private async persistCurrentSchemaVersion(): Promise<void> {
    await this.options.workspaceState.update(CACHE_SCHEMA_VERSION_KEY, CURRENT_CACHE_SCHEMA_VERSION);
  }

  private async storeReport(report: CacheMigrationReport): Promise<void> {
    await this.options.workspaceState.update(CACHE_MIGRATION_REPORT_KEY, report);
  }

  private createReport(fields: {
    action: CacheMigrationReport["action"];
    reason: CacheMigrationReport["reason"];
    previousSchemaVersion: number | undefined;
    storageRoots: CacheMigrationStorageRoot[];
  }): CacheMigrationReport {
    return {
      kind: "subversionr.cacheMigrationReport",
      generatedAt: this.options.now(),
      currentSchemaVersion: CURRENT_CACHE_SCHEMA_VERSION,
      previousSchemaVersion: fields.previousSchemaVersion,
      action: fields.action,
      reason: fields.reason,
      workingCopyMutation: "none",
      storageRoots: fields.storageRoots,
      releaseTraceIds: ["MIG-008", "MIG-010", "MIG-011", "SEC-013"],
    };
  }
}

export class CacheLifecycleError extends Error {
  public readonly category = "cache";

  public constructor(
    public readonly code: string,
    public readonly messageKey: string,
  ) {
    super(code);
    this.name = "CacheLifecycleError";
  }
}
