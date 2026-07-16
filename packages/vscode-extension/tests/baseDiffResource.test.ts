import { describe, expect, it } from "vitest";
import { isBaseDiffableProjectedResource } from "../src/scm/baseDiffResource";
import type { ScmProjectedResource } from "../src/scm/sourceControlResourceStore";
import type { StatusEntry } from "../src/status/statusSnapshotRpcClient";

describe("baseDiffResource", () => {
  it.each(["modified", "merged", "replaced"])("allows %s file changes with BASE content", (status) => {
    expect(isBaseDiffableProjectedResource(projectedResource(statusEntry({ localStatus: status })))).toBe(true);
  });

  it.each(["added", "deleted", "missing", "obstructed", "incomplete"])(
    "rejects %s file changes until safe rendering is supported",
    (status) => {
      expect(
        isBaseDiffableProjectedResource(
          projectedResource(statusEntry({ localStatus: status, nodeStatus: status })),
        ),
      ).toBe(false);
    },
  );

  it("allows the libsvn property-only file shape for BASE text content", () => {
    expect(
      isBaseDiffableProjectedResource(
        projectedResource(
          statusEntry({
            localStatus: "modified",
            nodeStatus: "modified",
            textStatus: "normal",
            propertyStatus: "modified",
          }),
        ),
      ),
    ).toBe(true);
  });

  it("rejects non-local files, directories, externals, and non-changed contexts", () => {
    expect(isBaseDiffableProjectedResource(projectedResource(statusEntry(), { source: "remote" }))).toBe(false);
    expect(isBaseDiffableProjectedResource(projectedResource(statusEntry({ kind: "dir" })))).toBe(false);
    expect(isBaseDiffableProjectedResource(projectedResource(statusEntry({ external: true })))).toBe(false);
    expect(isBaseDiffableProjectedResource(projectedResource(statusEntry(), { contextValue: "subversionr.changedUnknown" }))).toBe(false);
  });
});

function projectedResource(
  entry: StatusEntry,
  overrides: Partial<Pick<ScmProjectedResource, "source" | "groupId" | "contextValue">> = {},
): ScmProjectedResource {
  return {
    key: `local:${entry.path}`,
    repositoryId: "repo-uuid:C:/wc",
    path: entry.path,
    source: overrides.source ?? "local",
    groupId: overrides.groupId ?? "changes",
    contextValue: overrides.contextValue ?? "subversionr.changedFile",
    tooltipKey: "scm.resource.changed",
    entry,
  };
}

function statusEntry(overrides: Partial<StatusEntry> = {}): StatusEntry {
  return {
    path: "src/main.c",
    kind: "file",
    nodeStatus: "normal",
    textStatus: "normal",
    propertyStatus: "normal",
    localStatus: "modified",
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
