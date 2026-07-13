import { describe, expect, it } from "vitest";
import {
  classifyLocalStatusEntry,
  classifyRemoteStatusEntry,
} from "../src/scm/resourceStateClassifier";
import type { StatusEntry } from "../src/status/statusSnapshotRpcClient";

describe("resourceStateClassifier", () => {
  it.each([
    [
      "conflict metadata",
      statusEntry({ path: "src/conflict.c", conflict: "tree-conflict", localStatus: "unversioned", external: true }),
      "conflicts",
      "subversionr.conflicted",
      "scm.resource.conflicted",
    ],
    [
      "conflicted status token",
      statusEntry({ path: "src/token.c", conflict: null, localStatus: "conflicted" }),
      "conflicts",
      "subversionr.conflicted",
      "scm.resource.conflicted",
    ],
    [
      "external marker",
      statusEntry({ path: "vendor/lib", kind: "dir", localStatus: "normal", external: true }),
      "externals",
      "subversionr.external",
      "scm.resource.external",
    ],
    [
      "ignored entry",
      statusEntry({ path: "target/out.log", localStatus: "ignored" }),
      "ignored",
      "subversionr.ignored",
      "scm.resource.ignored",
    ],
    [
      "unversioned entry",
      statusEntry({ path: "notes.txt", localStatus: "unversioned" }),
      "unversioned",
      "subversionr.unversioned",
      "scm.resource.unversioned",
    ],
    [
      "property-only change",
      statusEntry({ path: "src/props.c", localStatus: "normal", propertyStatus: "modified" }),
      "changes",
      "subversionr.changedFile",
      "scm.resource.changed",
    ],
    [
      "directory property-only change",
      statusEntry({ path: "src", kind: "dir", localStatus: "normal", propertyStatus: "modified" }),
      "changes",
      "subversionr.changedDirectory",
      "scm.resource.changed",
    ],
    [
      "future local status token",
      statusEntry({ path: "src/future.c", localStatus: "future-status" }),
      "changes",
      "subversionr.changedUnknown",
      "scm.resource.changedUnknown",
    ],
    [
      "switched metadata-only node",
      statusEntry({ path: "branches/feature", kind: "dir", switched: true }),
      "metadata",
      "subversionr.workingCopyMetadata",
      "scm.resource.workingCopyMetadata",
    ],
    [
      "sparse metadata-only node",
      statusEntry({ path: "src/sparse", kind: "dir", depth: "files" }),
      "metadata",
      "subversionr.workingCopyMetadata",
      "scm.resource.workingCopyMetadata",
    ],
    [
      "needs-lock metadata-only file",
      statusEntry({ path: "src/lockable.c", needsLock: true }),
      "metadata",
      "subversionr.workingCopyMetadata",
      "scm.resource.workingCopyMetadata",
    ],
    [
      "locked metadata-only file",
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
      "metadata",
      "subversionr.workingCopyMetadata",
      "scm.resource.workingCopyMetadata",
    ],
  ])("classifies local %s", (_label, entry, groupId, contextValue, tooltipKey) => {
    expect(classifyLocalStatusEntry(entry)).toEqual({
      groupId,
      contextValue,
      tooltipKey,
    });
  });

  it("does not project neutral local entries", () => {
    expect(classifyLocalStatusEntry(statusEntry())).toBeUndefined();
  });

  it.each([
    ["modified remote status", statusEntry({ path: "src/remote.c", remoteStatus: "modified" })],
    ["future remote status", statusEntry({ path: "src/future-remote.c", remoteStatus: "future-remote" })],
  ])("classifies incoming file %s with file-only context", (_label, entry) => {
    expect(classifyRemoteStatusEntry(entry)).toEqual({
      groupId: "incoming",
      contextValue: "subversionr.incomingFile",
      tooltipKey: "scm.resource.incoming",
    });
  });

  it("classifies incoming directories without the file-only context", () => {
    expect(classifyRemoteStatusEntry(statusEntry({ path: "src", kind: "dir", remoteStatus: "modified" }))).toEqual({
      groupId: "incoming",
      contextValue: "subversionr.incoming",
      tooltipKey: "scm.resource.incoming",
    });
  });

  it.each(["none", "normal", "notChecked"])("does not project neutral remote status: %s", (remoteStatus) => {
    expect(classifyRemoteStatusEntry(statusEntry({ remoteStatus }))).toBeUndefined();
  });
});

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
