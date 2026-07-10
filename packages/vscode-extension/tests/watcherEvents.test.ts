import { describe, expect, it } from "vitest";
import { normalizeWatcherEvent } from "../src/status/watcherEvents";
import type { RepositoryWatchScope } from "../src/status/types";

const scope: RepositoryWatchScope = {
  repositoryId: "repo-uuid:C:/wc",
  epoch: 7,
  workingCopyRoot: "C:/wc",
  pathCase: "case-insensitive",
};

describe("normalizeWatcherEvent", () => {
  it("normalizes Windows separators and maps raw event kinds", () => {
    expect(
      normalizeWatcherEvent(scope, {
        fsPath: "C:\\wc\\src\\main.c",
        kind: "changed",
        timestamp: 100,
      }),
    ).toEqual({
      path: "C:/wc/src/main.c",
      kind: "change",
      timestamp: 100,
    });
  });

  it("accepts POSIX absolute paths", () => {
    expect(
      normalizeWatcherEvent(
        {
          repositoryId: "repo-uuid:/home/u/wc",
          epoch: 7,
          workingCopyRoot: "/home/u/wc",
          pathCase: "case-sensitive",
        },
        {
          fsPath: "/home/u/wc/src/main.c",
          kind: "changed",
          timestamp: 100,
        },
      ),
    ).toEqual({
      path: "/home/u/wc/src/main.c",
      kind: "change",
      timestamp: 100,
    });
  });

  it("accepts UNC absolute paths", () => {
    expect(
      normalizeWatcherEvent(
        {
          repositoryId: "repo-uuid://server/share/wc",
          epoch: 7,
          workingCopyRoot: "//server/share/wc",
          pathCase: "case-insensitive",
        },
        {
          fsPath: "\\\\server\\share\\wc\\src\\main.c",
          kind: "changed",
          timestamp: 100,
        },
      ),
    ).toEqual({
      path: "//server/share/wc/src/main.c",
      kind: "change",
      timestamp: 100,
    });
  });

  it("drops repository-external and .svn internal paths", () => {
    expect(
      normalizeWatcherEvent(scope, {
        fsPath: "C:/other/main.c",
        kind: "changed",
        timestamp: 100,
      }),
    ).toBeNull();
    expect(
      normalizeWatcherEvent(scope, {
        fsPath: "C:/wc/.SVN/tmp/wc.db",
        kind: "changed",
        timestamp: 100,
      }),
    ).toBeNull();
  });

  it("drops paths containing dot or parent traversal segments", () => {
    expect(
      normalizeWatcherEvent(scope, {
        fsPath: "C:/wc/../outside.c",
        kind: "changed",
        timestamp: 100,
      }),
    ).toBeNull();
    expect(
      normalizeWatcherEvent(scope, {
        fsPath: "C:/wc/src/../.svn/wc.db",
        kind: "changed",
        timestamp: 100,
      }),
    ).toBeNull();
    expect(
      normalizeWatcherEvent(scope, {
        fsPath: "C:/wc/src/./main.c",
        kind: "changed",
        timestamp: 100,
      }),
    ).toBeNull();
  });

  it("drops configured repository boundaries", () => {
    expect(
      normalizeWatcherEvent(
        { ...scope, boundaryRoots: ["C:/wc/vendor/external"] },
        {
          fsPath: "C:/wc/vendor/external/main.c",
          kind: "deleted",
          timestamp: 100,
        },
      ),
    ).toBeNull();
  });
});
