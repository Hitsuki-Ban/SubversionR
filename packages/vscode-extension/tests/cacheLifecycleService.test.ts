import { describe, expect, it, vi } from "vitest";
import {
  CURRENT_CACHE_SCHEMA_VERSION,
  CacheLifecycleService,
  type CacheStorageRoot,
} from "../src/cache/cacheLifecycleService";

describe("CacheLifecycleService", () => {
  it("initializes missing cache schema metadata without deleting storage", async () => {
    const state = new FakeMemento();
    const files = new FakeCacheFiles();
    const service = createService({ state, files });

    const report = await service.ensureCurrentSchema();

    expect(state.get("subversionr.cache.schemaVersion")).toBe(CURRENT_CACHE_SCHEMA_VERSION);
    expect(files.deletedPaths()).toEqual([]);
    expect(report.action).toBe("initialized");
    expect(report.reason).toBe("missing-schema");
    expect(report.workingCopyMutation).toBe("none");
  });

  it("clears only extension-owned cache roots for stale schema metadata", async () => {
    const state = new FakeMemento([["subversionr.cache.schemaVersion", 0]]);
    const files = new FakeCacheFiles([
      "/workspace/.svn/wc.db",
      "/workspace/file.txt",
      "/vscode/workspace-storage/cache/status.json",
      "/vscode/global-storage/cache/history.json",
    ]);
    const service = createService({ state, files });

    const report = await service.ensureCurrentSchema();

    expect(state.get("subversionr.cache.schemaVersion")).toBe(CURRENT_CACHE_SCHEMA_VERSION);
    expect(files.exists("/workspace/.svn/wc.db")).toBe(true);
    expect(files.exists("/workspace/file.txt")).toBe(true);
    expect(files.exists("/vscode/workspace-storage/cache/status.json")).toBe(false);
    expect(files.exists("/vscode/global-storage/cache/history.json")).toBe(false);
    expect(files.deletedPaths()).toEqual([
      "/vscode/workspace-storage/cache",
      "/vscode/global-storage/cache",
    ]);
    expect(report.action).toBe("schema-reset");
    expect(report.reason).toBe("stale-schema");
    expect(JSON.stringify(report)).not.toContain("/workspace");
    expect(JSON.stringify(report)).not.toContain(".svn");
  });

  it("treats a future schema as an unsupported cache and converges by deleting extension cache", async () => {
    const state = new FakeMemento([["subversionr.cache.schemaVersion", CURRENT_CACHE_SCHEMA_VERSION + 1]]);
    const files = new FakeCacheFiles(["/vscode/workspace-storage/cache/status.json"]);
    const service = createService({ state, files });

    const report = await service.ensureCurrentSchema();

    expect(state.get("subversionr.cache.schemaVersion")).toBe(CURRENT_CACHE_SCHEMA_VERSION);
    expect(files.exists("/vscode/workspace-storage/cache/status.json")).toBe(false);
    expect(report.action).toBe("schema-reset");
    expect(report.reason).toBe("future-schema");
  });

  it("manually clears cache idempotently and stores a user-visible report", async () => {
    const state = new FakeMemento([["subversionr.cache.schemaVersion", CURRENT_CACHE_SCHEMA_VERSION]]);
    const files = new FakeCacheFiles(["/vscode/workspace-storage/cache/status.json"]);
    const service = createService({ state, files });

    const first = await service.clearCache("manual-clear");
    const second = await service.clearCache("manual-clear");

    expect(first.action).toBe("cleared");
    expect(first.storageRoots.map((root) => root.status)).toEqual(["deleted", "missing"]);
    expect(second.action).toBe("cleared");
    expect(second.storageRoots.map((root) => root.status)).toEqual(["missing", "missing"]);
    expect(state.get("subversionr.cache.schemaVersion")).toBe(CURRENT_CACHE_SCHEMA_VERSION);
    expect(service.lastMigrationReport()).toEqual(second);
  });

  it("fails fast when persisted schema metadata is not numeric", async () => {
    const state = new FakeMemento([["subversionr.cache.schemaVersion", "1"]]);
    const service = createService({ state, files: new FakeCacheFiles() });

    await expect(service.ensureCurrentSchema()).rejects.toMatchObject({
      code: "SUBVERSIONR_CACHE_SCHEMA_METADATA_INVALID",
      messageKey: "error.cache.schemaMetadataInvalid",
    });
  });
});

function createService(options: { state: FakeMemento; files: FakeCacheFiles }) {
  const workspaceRoot: CacheStorageRoot = {
    scope: "workspace",
    uri: { scheme: "file", path: "/vscode/workspace-storage/cache" },
  };
  const globalRoot: CacheStorageRoot = {
    scope: "global",
    uri: { scheme: "file", path: "/vscode/global-storage/cache" },
  };
  return new CacheLifecycleService({
    workspaceState: options.state,
    storageRoots: [workspaceRoot, globalRoot],
    deleteTree: async (uri) => options.files.deleteTree(uri.path),
    now: () => "2026-06-24T00:00:00.000Z",
  });
}

class FakeMemento {
  private readonly values = new Map<string, unknown>();

  public constructor(entries: Array<[string, unknown]> = []) {
    for (const [key, value] of entries) {
      this.values.set(key, value);
    }
  }

  public get<T>(key: string): T | undefined {
    return this.values.get(key) as T | undefined;
  }

  public async update(key: string, value: unknown): Promise<void> {
    if (value === undefined) {
      this.values.delete(key);
      return;
    }
    this.values.set(key, value);
  }
}

class FakeCacheFiles {
  private readonly paths = new Set<string>();
  private readonly deleteCalls: string[] = [];

  public constructor(paths: string[] = []) {
    for (const path of paths) {
      this.paths.add(path);
    }
  }

  public exists(path: string): boolean {
    return this.paths.has(path);
  }

  public deletedPaths(): string[] {
    return this.deleteCalls;
  }

  public async deleteTree(root: string): Promise<"deleted" | "missing"> {
    this.deleteCalls.push(root);
    let deleted = false;
    for (const path of [...this.paths]) {
      if (path === root || path.startsWith(`${root}/`)) {
        this.paths.delete(path);
        deleted = true;
      }
    }
    return deleted ? "deleted" : "missing";
  }
}
