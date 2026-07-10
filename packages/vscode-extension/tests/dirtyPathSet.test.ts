import { describe, expect, it } from "vitest";
import { DirtyPathSet } from "../src/status/dirtyPathSet";
import type { RepositoryWatchScope } from "../src/status/types";

const scope: RepositoryWatchScope = {
  repositoryId: "repo-uuid:C:/wc",
  epoch: 7,
  workingCopyRoot: "C:/wc",
  pathCase: "case-insensitive",
};

describe("DirtyPathSet", () => {
  it("coalesces duplicate file changes into one empty-depth refresh target", () => {
    const dirty = new DirtyPathSet(scope);

    dirty.record({ path: "C:/wc/src/main.c", kind: "change", timestamp: 100 });
    dirty.record({ path: "C:/WC/src/main.c", kind: "change", timestamp: 125 });

    expect(dirty.size).toBe(1);
    expect(dirty.toRefreshTargets()).toEqual([
      { path: "src/main.c", depth: "empty", reason: "fileChanged" },
    ]);
  });

  it("does not use case-insensitive keys for case-sensitive repositories", () => {
    const dirty = new DirtyPathSet({ ...scope, pathCase: "case-sensitive" });

    dirty.record({ path: "C:/wc/src/main.c", kind: "change", timestamp: 100 });
    dirty.record({ path: "C:/wc/src/Main.c", kind: "change", timestamp: 125 });

    expect(dirty.size).toBe(2);
    expect(dirty.toRefreshTargets()).toEqual([
      { path: "src/Main.c", depth: "empty", reason: "fileChanged" },
      { path: "src/main.c", depth: "empty", reason: "fileChanged" },
    ]);
  });

  it("accepts POSIX and UNC absolute paths", () => {
    const posix = new DirtyPathSet({
      repositoryId: "repo-uuid:/home/u/wc",
      epoch: 7,
      workingCopyRoot: "/home/u/wc",
      pathCase: "case-sensitive",
    });
    const unc = new DirtyPathSet({
      repositoryId: "repo-uuid://server/share/wc",
      epoch: 7,
      workingCopyRoot: "//server/share/wc",
      pathCase: "case-insensitive",
    });

    expect(posix.record({ path: "/home/u/wc/src/main.c", kind: "change", timestamp: 100 })).toBe(true);
    expect(unc.record({ path: "\\\\server\\share\\wc\\src\\main.c", kind: "change", timestamp: 100 })).toBe(
      true,
    );

    expect(posix.toRefreshTargets()).toEqual([
      { path: "src/main.c", depth: "empty", reason: "fileChanged" },
    ]);
    expect(unc.toRefreshTargets()).toEqual([
      { path: "src/main.c", depth: "empty", reason: "fileChanged" },
    ]);
  });

  it("ignores .svn internals, paths outside the working copy, and configured boundaries", () => {
    const dirty = new DirtyPathSet({
      ...scope,
      boundaryRoots: ["C:/wc/vendor/external"],
    });

    expect(dirty.record({ path: "C:/wc/.svn/wc.db", kind: "change", timestamp: 100 })).toBe(false);
    expect(dirty.record({ path: "C:/wc/.SVN/wc.db", kind: "change", timestamp: 100 })).toBe(false);
    expect(dirty.record({ path: "C:/other/main.c", kind: "change", timestamp: 100 })).toBe(false);
    expect(
      dirty.record({ path: "C:/wc/vendor/external/file.c", kind: "change", timestamp: 100 }),
    ).toBe(false);

    expect(dirty.size).toBe(0);
    expect(dirty.toRefreshTargets()).toEqual([]);
  });

  it("rejects dot and parent traversal segments before target generation", () => {
    const dirty = new DirtyPathSet(scope);

    expect(dirty.record({ path: "C:/wc/../outside.c", kind: "change", timestamp: 100 })).toBe(false);
    expect(dirty.record({ path: "C:/wc/src/../.svn/wc.db", kind: "change", timestamp: 100 })).toBe(false);
    expect(dirty.record({ path: "C:/wc/src/./main.c", kind: "change", timestamp: 100 })).toBe(false);

    expect(dirty.toRefreshTargets()).toEqual([]);
  });

  it("adds parent immediates coverage for delete events", () => {
    const dirty = new DirtyPathSet(scope);

    dirty.record({ path: "C:/wc/src/main.c", kind: "delete", timestamp: 100 });

    expect(dirty.toRefreshTargets()).toEqual([
      { path: "src", depth: "immediates", reason: "childDeleted" },
      { path: "src/main.c", depth: "empty", reason: "fileDeleted" },
    ]);
  });

  it("collapses create then delete on the same path to parent verification", () => {
    const dirty = new DirtyPathSet(scope);

    dirty.record({ path: "C:/wc/src/transient.c", kind: "create", timestamp: 100 });
    dirty.record({ path: "C:/wc/src/transient.c", kind: "delete", timestamp: 101 });

    expect(dirty.toRefreshTargets()).toEqual([
      { path: "src", depth: "immediates", reason: "childDeleted" },
    ]);
  });

  it("preserves delete then create on the same path as a replacement refresh", () => {
    const dirty = new DirtyPathSet(scope);

    dirty.record({ path: "C:/wc/src/replaced.c", kind: "delete", timestamp: 100 });
    dirty.record({ path: "C:/wc/src/replaced.c", kind: "create", timestamp: 101 });

    expect(dirty.toRefreshTargets()).toEqual([
      { path: "src", depth: "immediates", reason: "childReplaced" },
      { path: "src/replaced.c", depth: "empty", reason: "fileReplaced" },
    ]);
  });

  it("uses receive order rather than wall-clock timestamps for replacement refreshes", () => {
    const dirty = new DirtyPathSet(scope);

    dirty.record({ path: "C:/wc/src/replaced.c", kind: "delete", timestamp: 101 });
    dirty.record({ path: "C:/wc/src/replaced.c", kind: "create", timestamp: 100 });

    expect(dirty.toRefreshTargets()).toEqual([
      { path: "src", depth: "immediates", reason: "childReplaced" },
      { path: "src/replaced.c", depth: "empty", reason: "fileReplaced" },
    ]);
  });

  it("folds a sibling change storm into one directory files refresh target before root overflow", () => {
    const dirty = new DirtyPathSet(scope, { maxDirtyPaths: 4 });

    for (let index = 0; index < 5; index += 1) {
      dirty.record({ path: `C:/wc/generated/file-${index}.txt`, kind: "change", timestamp: 100 + index });
    }

    expect(dirty.isOverflowed).toBe(false);
    expect(dirty.size).toBe(1);
    expect(dirty.toRefreshTargets()).toEqual([
      { path: "generated", depth: "files", reason: "dirtyPathFold" },
    ]);
  });

  it("folds a sibling create and delete storm into one directory immediates refresh target", () => {
    const dirty = new DirtyPathSet(scope, { maxDirtyPaths: 4 });

    for (let index = 0; index < 5; index += 1) {
      dirty.record({
        path: `C:/wc/generated/file-${index}.txt`,
        kind: index % 2 === 0 ? "create" : "delete",
        timestamp: 100 + index,
      });
    }

    expect(dirty.isOverflowed).toBe(false);
    expect(dirty.size).toBe(1);
    expect(dirty.toRefreshTargets()).toEqual([
      { path: "generated", depth: "immediates", reason: "dirtyPathFold" },
    ]);
  });

  it("folds unrelated dirty path storms into a root full refresh target", () => {
    const dirty = new DirtyPathSet(scope, { maxDirtyPaths: 2 });

    dirty.record({ path: "C:/wc/src/a.c", kind: "change", timestamp: 100 });
    dirty.record({ path: "C:/wc/test/b.c", kind: "change", timestamp: 101 });
    dirty.record({ path: "C:/wc/docs/c.c", kind: "change", timestamp: 102 });

    expect(dirty.toRefreshTargets()).toEqual([
      { path: ".", depth: "infinity", reason: "watcherOverflow" },
    ]);
  });

  it("keeps applying backpressure after an existing folded target consumes part of the budget", () => {
    const dirty = new DirtyPathSet(scope, { maxDirtyPaths: 4 });

    for (let index = 0; index < 5; index += 1) {
      dirty.record({ path: `C:/wc/generated/file-${index}.txt`, kind: "change", timestamp: 100 + index });
    }
    dirty.record({ path: "C:/wc/src/a.c", kind: "change", timestamp: 200 });
    dirty.record({ path: "C:/wc/test/b.c", kind: "change", timestamp: 201 });
    dirty.record({ path: "C:/wc/docs/c.c", kind: "change", timestamp: 202 });
    dirty.record({ path: "C:/wc/tools/d.c", kind: "change", timestamp: 203 });

    expect(dirty.toRefreshTargets()).toEqual([
      { path: ".", depth: "infinity", reason: "watcherOverflow" },
    ]);
  });

  it("folds a nested directory storm into one subtree refresh target before root overflow", () => {
    const dirty = new DirtyPathSet(scope, { maxDirtyPaths: 4 });

    for (let index = 0; index < 5; index += 1) {
      dirty.record({
        path: `C:/wc/generated/module-${index}/src/file.txt`,
        kind: "change",
        timestamp: 100 + index,
      });
    }

    expect(dirty.isOverflowed).toBe(false);
    expect(dirty.size).toBe(1);
    expect(dirty.toRefreshTargets()).toEqual([
      { path: "generated", depth: "infinity", reason: "dirtyPathSubtreeFold" },
    ]);
  });

  it("preserves display casing when subtree folding case-insensitive paths", () => {
    const dirty = new DirtyPathSet(scope, { maxDirtyPaths: 4 });

    for (let index = 0; index < 5; index += 1) {
      dirty.record({
        path: `C:/wc/Generated/Module-${index}/src/file.txt`,
        kind: "change",
        timestamp: 100 + index,
      });
    }

    expect(dirty.toRefreshTargets()).toEqual([
      { path: "Generated", depth: "infinity", reason: "dirtyPathSubtreeFold" },
    ]);
  });

  it("prefers the deepest subtree fold that brings the dirty queue within budget", () => {
    const dirty = new DirtyPathSet(scope, { maxDirtyPaths: 3 });

    dirty.record({ path: "C:/wc/src/deep/a/file.txt", kind: "change", timestamp: 100 });
    dirty.record({ path: "C:/wc/src/deep/b/file.txt", kind: "change", timestamp: 101 });
    dirty.record({ path: "C:/wc/src/other/c/file.txt", kind: "change", timestamp: 102 });
    dirty.record({ path: "C:/wc/docs/readme.txt", kind: "change", timestamp: 103 });

    expect(dirty.toRefreshTargets()).toEqual([
      { path: "docs/readme.txt", depth: "empty", reason: "fileChanged" },
      { path: "src/deep", depth: "infinity", reason: "dirtyPathSubtreeFold" },
      { path: "src/other/c/file.txt", depth: "empty", reason: "fileChanged" },
    ]);
  });

  it("merges later descendants into an existing subtree refresh target", () => {
    const dirty = new DirtyPathSet(scope, { maxDirtyPaths: 4 });

    for (let index = 0; index < 5; index += 1) {
      dirty.record({
        path: `C:/wc/generated/module-${index}/src/file.txt`,
        kind: "change",
        timestamp: 100 + index,
      });
    }
    dirty.record({ path: "C:/wc/generated/new-module/deep/file.txt", kind: "create", timestamp: 200 });

    expect(dirty.size).toBe(1);
    expect(dirty.toRefreshTargets()).toEqual([
      { path: "generated", depth: "infinity", reason: "dirtyPathSubtreeFold" },
    ]);
  });

  it("does not use boundary descendants when deciding subtree folds", () => {
    const dirty = new DirtyPathSet({
      ...scope,
      boundaryRoots: ["C:/wc/generated/module-4"],
    }, { maxDirtyPaths: 4 });

    for (let index = 0; index < 5; index += 1) {
      dirty.record({
        path: `C:/wc/generated/module-${index}/src/file.txt`,
        kind: "change",
        timestamp: 100 + index,
      });
    }

    expect(dirty.isOverflowed).toBe(false);
    expect(dirty.size).toBe(4);
    expect(dirty.toRefreshTargets()).toEqual([
      { path: "generated/module-0/src/file.txt", depth: "empty", reason: "fileChanged" },
      { path: "generated/module-1/src/file.txt", depth: "empty", reason: "fileChanged" },
      { path: "generated/module-2/src/file.txt", depth: "empty", reason: "fileChanged" },
      { path: "generated/module-3/src/file.txt", depth: "empty", reason: "fileChanged" },
    ]);
  });
});
