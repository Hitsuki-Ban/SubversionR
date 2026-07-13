import { describe, expect, it } from "vitest";
import {
  SCM_RESOURCE_GROUP_IDS,
  SourceControlResourceStore,
} from "../src/scm/sourceControlResourceStore";
import type { StatusDelta } from "../src/status/statusRefreshRpcClient";
import type { StatusEntry, StatusSnapshot } from "../src/status/statusSnapshotRpcClient";

describe("SourceControlResourceStore", () => {
  it("seeds fixed SCM groups from a status snapshot", () => {
    const store = sourceControlResourceStore();
    store.registerRepository(repository());

    const projection = store.applySnapshot(
      snapshotResponse({
        localEntries: [
          statusEntry({ path: "src/conflict.c", conflict: "tree-conflict" }),
          statusEntry({ path: "src/modified.c", localStatus: "modified" }),
          statusEntry({ path: "notes.txt", localStatus: "unversioned" }),
          statusEntry({ path: "vendor/lib", kind: "dir", external: true }),
          statusEntry({ path: "target/out.log", localStatus: "ignored" }),
        ],
        remoteEntries: [statusEntry({ path: "src/incoming.c", remoteStatus: "modified" })],
      }),
    );

    expect(projection.groups.map((group) => group.id)).toEqual(SCM_RESOURCE_GROUP_IDS);
    expect(groupPaths(projection, "conflicts")).toEqual(["src/conflict.c"]);
    expect(groupPaths(projection, "changes")).toEqual(["src/modified.c"]);
    expect(groupContexts(projection, "changes")).toEqual(["subversionr.changedFile"]);
    expect(groupPaths(projection, "unversioned")).toEqual(["notes.txt"]);
    expect(groupPaths(projection, "incoming")).toEqual(["src/incoming.c"]);
    expect(groupContexts(projection, "incoming")).toEqual(["subversionr.incomingFile"]);
    expect(groupPaths(projection, "externals")).toEqual(["vendor/lib"]);
    expect(groupPaths(projection, "ignored")).toEqual(["target/out.log"]);
  });

  it("counts committable local resources while excluding ignored, incoming, external, and ignored changelists", () => {
    const store = new SourceControlResourceStore({
      countPolicy: {
        countUnversioned: false,
        ignoreChangelistsInCount: ["ignore-on-commit"],
      },
    });
    store.registerRepository(repository());

    const projection = store.applySnapshot(
      snapshotResponse({
        localEntries: [
          statusEntry({ path: "src/conflict.c", conflict: "tree-conflict" }),
          statusEntry({ path: "src/modified.c", localStatus: "modified" }),
          statusEntry({ path: "src/properties.c", propertyStatus: "modified" }),
          statusEntry({ path: "src/ignored-changelist.c", localStatus: "modified", changelist: "ignore-on-commit" }),
          statusEntry({ path: "notes.txt", localStatus: "unversioned" }),
          statusEntry({ path: "vendor/lib", kind: "dir", external: true }),
          statusEntry({ path: "target/out.log", localStatus: "ignored" }),
        ],
        remoteEntries: [statusEntry({ path: "src/incoming.c", remoteStatus: "modified" })],
      }),
    );

    expect(groupPaths(projection, "changelist:ignore-on-commit")).toEqual(["src/ignored-changelist.c"]);
    expect(projection.count).toBe(3);
  });

  it("projects changed resources into deterministic changelist SCM groups", () => {
    const store = sourceControlResourceStore();
    store.registerRepository(repository());

    const projection = store.applySnapshot(
      snapshotResponse({
        localEntries: [
          statusEntry({ path: "src/conflict.c", conflict: "tree-conflict", changelist: "review" }),
          statusEntry({ path: "src/b.c", localStatus: "modified", changelist: "review" }),
          statusEntry({ path: "src/a.c", localStatus: "modified", changelist: "shelved" }),
          statusEntry({ path: "src/main.c", localStatus: "modified" }),
        ],
      }),
    );

    expect(projection.groups.map((group) => group.id)).toEqual([
      "conflicts",
      "changelist:review",
      "changelist:shelved",
      "changes",
      "unversioned",
      "metadata",
      "incoming",
      "externals",
      "ignored",
    ]);
    expect(groupPaths(projection, "conflicts")).toEqual(["src/conflict.c"]);
    expect(groupPaths(projection, "changelist:review")).toEqual(["src/b.c"]);
    expect(groupPaths(projection, "changelist:shelved")).toEqual(["src/a.c"]);
    expect(groupPaths(projection, "changes")).toEqual(["src/main.c"]);
  });

  it("projects clean working-copy metadata into its own non-committable group", () => {
    const store = sourceControlResourceStore();
    store.registerRepository(repository());

    const projection = store.applySnapshot(
      snapshotResponse({
        localEntries: [
          statusEntry({ path: "branches/feature", kind: "dir", switched: true }),
          statusEntry({ path: "src/sparse", kind: "dir", depth: "files" }),
          statusEntry({ path: "src/needs-lock.c", needsLock: true }),
          statusEntry({
            path: "src/locked.c",
            lock: {
              token: "opaquelocktoken:1",
              owner: "alice",
              comment: null,
              createdDate: "2026-06-22T00:00:00Z",
              expiresDate: null,
              isRemote: false,
            },
          }),
        ],
      }),
    );

    expect(groupPaths(projection, "changes")).toEqual([]);
    expect(groupPaths(projection, "metadata")).toEqual([
      "branches/feature",
      "src/locked.c",
      "src/needs-lock.c",
      "src/sparse",
    ]);
    expect(groupContexts(projection, "metadata")).toEqual([
      "subversionr.workingCopyMetadata",
      "subversionr.workingCopyMetadata",
      "subversionr.workingCopyMetadata",
      "subversionr.workingCopyMetadata",
    ]);
    expect(projection.count).toBe(0);
    expect(store.getCommitAllTargets("repo-uuid:C:/wc")?.targets).toEqual([]);
  });

  it("atomically reprojects both count settings without changing snapshot or incoming state", () => {
    const store = sourceControlResourceStore();
    store.registerRepository(repository());
    const initial = store.applySnapshot(
      snapshotResponse({
        localEntries: [
          statusEntry({ path: "src/main.c", localStatus: "modified" }),
          statusEntry({ path: "src/review.c", localStatus: "modified", changelist: "review" }),
          statusEntry({ path: "notes.txt", localStatus: "unversioned" }),
          statusEntry({ path: "src/needs-lock.c", needsLock: true }),
        ],
        remoteEntries: [statusEntry({ path: "src/incoming.c", remoteStatus: "modified" })],
      }),
    );
    expect(initial.count).toBe(2);

    const [countUnversioned] = store.updateCountPolicy({
      countUnversioned: true,
      ignoreChangelistsInCount: ["ignore-on-commit"],
    });
    expect(countUnversioned.count).toBe(3);
    expect(countUnversioned.epoch).toBe(initial.epoch);
    expect(countUnversioned.generation).toBe(initial.generation);
    expect(countUnversioned.freshness).toEqual(initial.freshness);
    expect(groupPaths(countUnversioned, "incoming")).toEqual(["src/incoming.c"]);
    expect(groupPaths(countUnversioned, "metadata")).toEqual(["src/needs-lock.c"]);

    const [ignoreReview] = store.updateCountPolicy({
      countUnversioned: true,
      ignoreChangelistsInCount: ["review"],
    });
    expect(ignoreReview.count).toBe(2);
    expect(store.getCommitAllTargets("repo-uuid:C:/wc")?.targets.map((target) => target.path)).toEqual([
      "src/main.c",
    ]);
    expect(groupPaths(ignoreReview, "incoming")).toEqual(["src/incoming.c"]);

    const [restored] = store.updateCountPolicy({
      countUnversioned: false,
      ignoreChangelistsInCount: [],
    });
    expect(restored.count).toBe(2);
    expect(store.getCommitAllTargets("repo-uuid:C:/wc")?.targets.map((target) => target.path)).toEqual([
      "src/main.c",
      "src/review.c",
    ]);
  });

  it("keeps changed switched sparse and needs-lock files committable instead of downgrading them", () => {
    const store = sourceControlResourceStore();
    store.registerRepository(repository());

    const projection = store.applySnapshot(
      snapshotResponse({
        localEntries: [
          statusEntry({
            path: "src/switched-sparse.c",
            localStatus: "modified",
            switched: true,
            depth: "files",
          }),
          statusEntry({
            path: "src/needs-lock.c",
            localStatus: "modified",
            needsLock: true,
          }),
        ],
      }),
    );

    expect(groupPaths(projection, "changes")).toEqual(["src/needs-lock.c", "src/switched-sparse.c"]);
    expect(groupContexts(projection, "changes")).toEqual([
      "subversionr.changedFile",
      "subversionr.changedFile",
    ]);
    expect(projection.count).toBe(2);
    expect(store.getCommitAllTargets("repo-uuid:C:/wc")?.targets).toEqual([
      { path: "src/needs-lock.c", changelist: null, status: "modified", directory: "src" },
      { path: "src/switched-sparse.c", changelist: null, status: "modified", directory: "src" },
    ]);
  });

  it("derives Commit All file targets from current local changes while honoring ignored changelists", () => {
    const store = new SourceControlResourceStore({
      countPolicy: {
        countUnversioned: false,
        ignoreChangelistsInCount: ["ignore-on-commit"],
      },
    });
    store.registerRepository(repository());
    store.applySnapshot(
      snapshotResponse({
        localEntries: [
          statusEntry({ path: "src/b.c", localStatus: "modified" }),
          statusEntry({ path: "src/a.c", propertyStatus: "modified" }),
          statusEntry({ path: "docs/new.md", localStatus: "added" }),
          statusEntry({ path: "src/ignored-changelist.c", localStatus: "modified", changelist: "ignore-on-commit" }),
          statusEntry({ path: "src/dir", kind: "dir", localStatus: "modified" }),
          statusEntry({ path: "notes.txt", localStatus: "unversioned" }),
          statusEntry({ path: "vendor/lib.c", localStatus: "modified", external: true }),
          statusEntry({ path: "target/out.log", localStatus: "ignored" }),
        ],
        remoteEntries: [statusEntry({ path: "src/incoming.c", remoteStatus: "modified" })],
      }),
    );

    expect(groupPaths(store.getProjection("repo-uuid:C:/wc")!, "changelist:ignore-on-commit")).toEqual([
      "src/ignored-changelist.c",
    ]);
    expect(store.getCommitAllTargets("repo-uuid:C:/wc")).toEqual({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      workingCopyRoot: "C:/wc",
      generation: 11,
      hasConflicts: false,
      targets: [
        { path: "docs/new.md", changelist: null, status: "added", directory: "docs" },
        { path: "src/a.c", changelist: null, status: "modified", directory: "src" },
        { path: "src/b.c", changelist: null, status: "modified", directory: "src" },
      ],
    });
  });

  it("returns a single projected local resource without building a full projection", () => {
    const store = sourceControlResourceStore();
    store.registerRepository(repository());
    store.applySnapshot(
      snapshotResponse({
        localEntries: [
          statusEntry({ path: "src/main.c", localStatus: "modified", changedRevision: 9 }),
          statusEntry({ path: "notes.txt", localStatus: "unversioned" }),
        ],
        remoteEntries: [statusEntry({ path: "src/incoming.c", remoteStatus: "modified" })],
      }),
    );

    expect(store.getProjectedResource("repo-uuid:C:/wc", "SRC/MAIN.C", "case-insensitive")).toEqual({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      workingCopyRoot: "C:/wc",
      generation: 11,
      resource: expect.objectContaining({
        path: "src/main.c",
        source: "local",
        groupId: "changes",
        entry: expect.objectContaining({
          changedRevision: 9,
        }),
      }),
    });
    expect(store.getProjectedResource("repo-uuid:C:/wc", "src/incoming.c", "case-insensitive")).toBeUndefined();
    expect(store.getProjectedResource("repo-uuid:C:/wc", "../bad.c", "case-insensitive")).toBeUndefined();
  });

  it("returns projection groups with independent lock info clones", () => {
    const store = sourceControlResourceStore();
    store.registerRepository(repository());
    const projection = store.applySnapshot(
      snapshotResponse({
        localEntries: [
          statusEntry({
            path: "src/locked.c",
            lock: {
              token: "opaquelocktoken:1",
              owner: "alice",
              comment: "editing",
              createdDate: "2026-06-25T00:00:00Z",
              expiresDate: null,
              isRemote: false,
            },
          }),
        ],
      }),
    );

    const projectedLock = projection.groups.find((group) => group.id === "metadata")?.resources[0]?.entry.lock;
    expect(projectedLock?.owner).toBe("alice");
    projectedLock!.owner = "mallory";

    const currentLock = store.getProjection("repo-uuid:C:/wc")?.groups.find((group) => group.id === "metadata")?.resources[0]?.entry.lock;
    expect(currentLock?.owner).toBe("alice");
  });

  it("updates the case-insensitive projected resource index as local resources change", () => {
    const store = sourceControlResourceStore();
    store.registerRepository(repository());
    store.applySnapshot(
      snapshotResponse({
        generation: 11,
        localEntries: [statusEntry({ path: "src/main.c", localStatus: "modified", generation: 11 })],
      }),
    );

    expect(store.getProjectedResource("repo-uuid:C:/wc", "SRC/MAIN.C", "case-insensitive")?.resource.path).toBe(
      "src/main.c",
    );

    store.applyDelta(
      deltaResponse({
        generation: 12,
        remove: ["src/main.c"],
        upsert: [statusEntry({ path: "lib/main.c", localStatus: "modified", generation: 12 })],
      }),
    );

    expect(store.getProjectedResource("repo-uuid:C:/wc", "SRC/MAIN.C", "case-insensitive")).toBeUndefined();
    expect(store.getProjectedResource("repo-uuid:C:/wc", "LIB/MAIN.C", "case-insensitive")?.resource.path).toBe(
      "lib/main.c",
    );
    expect(store.getProjectedResource("repo-uuid:C:/wc", "LIB/MAIN.C", "case-sensitive")).toBeUndefined();
  });

  it("reports unresolved conflicts separately for Commit All target derivation", () => {
    const store = sourceControlResourceStore();
    store.registerRepository(repository());
    store.applySnapshot(
      snapshotResponse({
        localEntries: [
          statusEntry({ path: "src/conflict.c", conflict: "tree-conflict" }),
          statusEntry({ path: "src/main.c", localStatus: "modified" }),
        ],
      }),
    );

    expect(store.getCommitAllTargets("repo-uuid:C:/wc")).toMatchObject({
      hasConflicts: true,
      targets: [{ path: "src/main.c", changelist: null }],
    });
  });

  it("fails fast when an eligible Commit All target has a malformed repository-relative path", () => {
    const store = sourceControlResourceStore();
    store.registerRepository(repository());
    store.applySnapshot(
      snapshotResponse({
        localEntries: [statusEntry({ path: "src/../bad.c", localStatus: "modified" })],
      }),
    );

    expect(() => store.getCommitAllTargets("repo-uuid:C:/wc")).toThrow(
      "SUBVERSIONR_SCM_PROJECTION_COMMIT_ALL_TARGET_INVALID",
    );
  });

  it("counts unversioned resources only when the count policy opts in", () => {
    const store = new SourceControlResourceStore({
      countPolicy: {
        countUnversioned: true,
        ignoreChangelistsInCount: [],
      },
    });
    store.registerRepository(repository());

    const projection = store.applySnapshot(
      snapshotResponse({
        localEntries: [
          statusEntry({ path: "src/modified.c", localStatus: "modified" }),
          statusEntry({ path: "notes.txt", localStatus: "unversioned" }),
        ],
      }),
    );

    expect(projection.count).toBe(2);
  });

  it("excludes external and ignored resources from the badge count even when they are conflicted", () => {
    const store = sourceControlResourceStore();
    store.registerRepository(repository());

    const projection = store.applySnapshot(
      snapshotResponse({
        localEntries: [
          statusEntry({ path: "src/conflict.c", conflict: "tree-conflict" }),
          statusEntry({ path: "vendor/conflict.c", conflict: "tree-conflict", external: true }),
          statusEntry({ path: "target/conflict.log", conflict: "tree-conflict", localStatus: "ignored" }),
        ],
      }),
    );

    expect(groupPaths(projection, "conflicts")).toEqual([
      "src/conflict.c",
      "target/conflict.log",
      "vendor/conflict.c",
    ]);
    expect(projection.count).toBe(1);
  });

  it("applies local refresh deltas without changing incoming remote resources", () => {
    const store = sourceControlResourceStore();
    store.registerRepository(repository());
    store.applySnapshot(
      snapshotResponse({
        generation: 11,
        localEntries: [
          statusEntry({ path: "src/old.c", localStatus: "modified", generation: 11 }),
          statusEntry({ path: "src/unchanged.c", localStatus: "modified", generation: 11 }),
        ],
        remoteEntries: [statusEntry({ path: "src/old.c", remoteStatus: "modified", generation: 11 })],
      }),
    );

    const projection = store.applyDelta(
      deltaResponse({
        generation: 12,
        upsert: [statusEntry({ path: "src/new.c", localStatus: "unversioned", generation: 12 })],
        remove: ["src/old.c"],
      }),
    );

    expect(groupPaths(projection, "changes")).toEqual(["src/unchanged.c"]);
    expect(groupPaths(projection, "unversioned")).toEqual(["src/new.c"]);
    expect(groupPaths(projection, "incoming")).toEqual(["src/old.c"]);
    expect(projection.count).toBe(1);
  });

  it("applies remote refresh deltas to the incoming group without changing local resources", () => {
    const store = sourceControlResourceStore();
    store.registerRepository(repository());
    store.applySnapshot(
      snapshotResponse({
        generation: 11,
        localEntries: [statusEntry({ path: "src/local.c", localStatus: "modified", generation: 11 })],
        remoteEntries: [statusEntry({ path: "src/old-incoming.c", remoteStatus: "modified", generation: 11 })],
      }),
    );

    const projection = store.applyDelta(
      deltaResponse({
        generation: 12,
        remoteUpsert: [
          statusEntry({ path: "src/new-incoming.c", remoteStatus: "modified", generation: 12 }),
          statusEntry({ path: "src/zz-incoming-dir", kind: "dir", remoteStatus: "modified", generation: 12 }),
        ],
        remoteRemove: ["src/old-incoming.c"],
      }),
    );

    expect(groupPaths(projection, "changes")).toEqual(["src/local.c"]);
    expect(groupPaths(projection, "incoming")).toEqual(["src/new-incoming.c", "src/zz-incoming-dir"]);
    expect(groupContexts(projection, "incoming")).toEqual(["subversionr.incomingFile", "subversionr.incoming"]);
    expect(projection.count).toBe(1);
  });

  it("keeps repository completeness after a targeted partial delta while recording last refresh freshness", () => {
    const store = sourceControlResourceStore();
    store.registerRepository(repository());
    store.applySnapshot(
      snapshotResponse({
        generation: 11,
        completeness: "complete",
        localEntries: [statusEntry({ path: "src/old.c", localStatus: "modified", generation: 11 })],
      }),
    );

    const projection = store.applyDelta(
      deltaResponse({
        generation: 12,
        completeness: "partial",
        upsert: [statusEntry({ path: "src/new.c", localStatus: "modified", generation: 12 })],
        remove: ["src/old.c"],
      }),
    );

    expect((projection as { freshness?: unknown }).freshness).toEqual({
      repositoryCompleteness: "complete",
      lastRefreshCompleteness: "partial",
      lastRefreshKind: "delta",
    });
  });

  it("promotes repository completeness when a full reconcile delta is complete", () => {
    const store = sourceControlResourceStore();
    store.registerRepository(repository());
    store.applySnapshot(
      snapshotResponse({
        generation: 11,
        completeness: "partial",
        localEntries: [statusEntry({ path: "src/old.c", localStatus: "modified", generation: 11 })],
      }),
    );

    const projection = store.applyDelta(
      deltaResponse({
        generation: 12,
        completeness: "complete",
        coverage: [{ path: ".", depth: "infinity", generation: 12, reason: "manualFullReconcile" }],
        upsert: [statusEntry({ path: "src/current.c", localStatus: "modified", generation: 12 })],
        remove: ["src/old.c"],
      }),
    );

    expect((projection as { freshness?: unknown }).freshness).toEqual({
      repositoryCompleteness: "complete",
      lastRefreshCompleteness: "complete",
      lastRefreshKind: "delta",
    });
  });

  it("marks an initialized projection stale without changing resources or generation", () => {
    const store = sourceControlResourceStore();
    store.registerRepository(repository());
    store.applySnapshot(
      snapshotResponse({
        generation: 12,
        completeness: "complete",
        localEntries: [statusEntry({ path: "src/current.c", localStatus: "modified", generation: 12 })],
        remoteEntries: [statusEntry({ path: "src/incoming.c", remoteStatus: "modified", generation: 12 })],
      }),
    );

    const projection = store.markStale({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      reason: "backendRestart",
      timestamp: "2026-06-22T00:03:00Z",
      source: "daemon-status-stale",
    });

    expect(projection.generation).toBe(12);
    expect(projection.freshness).toEqual({
      repositoryCompleteness: "stale",
      lastRefreshCompleteness: "stale",
      lastRefreshKind: "stale",
    });
    expect(groupPaths(projection, "changes")).toEqual(["src/current.c"]);
    expect(groupPaths(projection, "incoming")).toEqual(["src/incoming.c"]);
  });

  it("moves a local resource between groups when a delta changes its status", () => {
    const store = sourceControlResourceStore();
    store.registerRepository(repository());
    store.applySnapshot(
      snapshotResponse({
        generation: 11,
        localEntries: [statusEntry({ path: "src/main.c", localStatus: "modified", generation: 11 })],
      }),
    );

    const projection = store.applyDelta(
      deltaResponse({
        generation: 12,
        upsert: [statusEntry({ path: "src/main.c", conflict: "text-conflict", generation: 12 })],
      }),
    );

    expect(groupPaths(projection, "changes")).toEqual([]);
    expect(groupPaths(projection, "conflicts")).toEqual(["src/main.c"]);
  });

  it("rejects stale local deltas without changing the projection", () => {
    const store = sourceControlResourceStore();
    store.registerRepository(repository());
    store.applySnapshot(
      snapshotResponse({
        generation: 12,
        localEntries: [statusEntry({ path: "src/current.c", localStatus: "modified", generation: 12 })],
      }),
    );

    expect(() =>
      store.applyDelta(
        deltaResponse({
          generation: 12,
          upsert: [statusEntry({ path: "src/replayed.c", localStatus: "modified", generation: 12 })],
        }),
      ),
    ).toThrow("SUBVERSIONR_SCM_PROJECTION_DELTA_GENERATION_STALE");
    expect(groupPaths(store.getProjection("repo-uuid:C:/wc")!, "changes")).toEqual(["src/current.c"]);
  });
});

function sourceControlResourceStore(): SourceControlResourceStore {
  return new SourceControlResourceStore({
    countPolicy: {
      countUnversioned: false,
      ignoreChangelistsInCount: ["ignore-on-commit"],
    },
  });
}

function groupPaths(
  projection: ReturnType<SourceControlResourceStore["applySnapshot"]>,
  groupId: string,
): string[] {
  return projection.groups.find((group) => group.id === groupId)?.resources.map((resource) => resource.path) ?? [];
}

function groupContexts(
  projection: ReturnType<SourceControlResourceStore["applySnapshot"]>,
  groupId: string,
): string[] {
  return projection.groups.find((group) => group.id === groupId)?.resources.map((resource) => resource.contextValue) ?? [];
}

function repository() {
  return {
    repositoryId: "repo-uuid:C:/wc",
    epoch: 7,
    workingCopyRoot: "C:/wc",
  };
}

function snapshotResponse(options: Partial<StatusSnapshot> = {}): StatusSnapshot {
  return {
    repositoryId: "repo-uuid:C:/wc",
    epoch: 7,
    generation: 11,
    completeness: "complete",
    identity: {
      repositoryUuid: "repo-uuid",
      repositoryRootUrl: "file:///C:/repo",
      workingCopyRoot: "C:/wc",
      workspaceScopeRoot: "C:/workspace",
      format: 31,
    },
    localEntries: [],
    remoteEntries: [],
    summary: {
      localChanges: 0,
      remoteChanges: 0,
      conflicts: 0,
      unversioned: 0,
    },
    timestamp: "2026-06-22T00:00:00Z",
    source: "libsvn-local",
    ...options,
  };
}

function deltaResponse(options: Partial<StatusDelta> = {}): StatusDelta {
  const generation = options.generation ?? 12;
  return {
    repositoryId: "repo-uuid:C:/wc",
    epoch: 7,
    generation,
    coverage: [{ path: "src", depth: "files", generation, reason: "directoryChanged" }],
    upsert: [],
    remove: [],
    remoteUpsert: [],
    remoteRemove: [],
    summaryDelta: {
      localChanges: 0,
      remoteChanges: 0,
      conflicts: 0,
      unversioned: 0,
    },
    completeness: "partial",
    timestamp: "2026-06-22T00:02:00Z",
    source: "libsvn-local",
    ...options,
  };
}

function statusEntry(overrides: Partial<StatusEntry> = {}): StatusEntry {
  return {
    path: "src/main.c",
    kind: "file",
    nodeStatus: "normal",
    textStatus: "normal",
    propertyStatus: "normal",
    localStatus: "normal",
    remoteStatus: "notChecked",
    revision: 7,
    changedRevision: 7,
    changedAuthor: "alice",
    changedDate: "2026-06-22T00:00:00Z",
    changelist: null,
    lock: null,
    needsLock: false,
    copy: null,
    move: null,
    switched: false,
    depth: "infinity",
    conflict: null,
    external: false,
    generation: 11,
    ...overrides,
  };
}
