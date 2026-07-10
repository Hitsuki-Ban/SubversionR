import { describe, expect, it } from "vitest";
import {
  mergeAncestryQuickPickItems,
  mergeForceDeleteQuickPickItems,
  mergeIgnoreMergeinfoQuickPickItems,
  mergeMixedRevisionsQuickPickItems,
  mergeRecordOnlyQuickPickItems,
} from "../src/repository/mergeRangePromptOptions";

describe("merge range prompt options", () => {
  it("offers SVN merge apply and record-only modes", () => {
    const items = mergeRecordOnlyQuickPickItems((message) => message);

    expect(items).toEqual([
      {
        label: "Apply merge",
        description: "Apply file and property changes during merge",
        recordOnly: false,
      },
      {
        label: "Record only",
        description: "Record mergeinfo without applying file changes",
        recordOnly: true,
      },
    ]);
  });

  it("offers SVN mergeinfo filtering modes", () => {
    const items = mergeIgnoreMergeinfoQuickPickItems((message) => message);

    expect(items).toEqual([
      {
        label: "Use mergeinfo",
        description: "Let libsvn skip revisions already recorded in mergeinfo",
        ignoreMergeinfo: false,
      },
      {
        label: "Ignore mergeinfo",
        description: "Merge the requested revision range without mergeinfo filtering",
        ignoreMergeinfo: true,
      },
    ]);
  });

  it("offers SVN merge ancestry modes", () => {
    const items = mergeAncestryQuickPickItems((message) => message);

    expect(items).toEqual([
      {
        label: "Check ancestry",
        description: "Require shared SVN ancestry during merge",
        diffIgnoreAncestry: false,
      },
      {
        label: "Ignore ancestry",
        description: "Allow merge without checking SVN ancestry",
        diffIgnoreAncestry: true,
      },
    ]);
  });

  it("offers SVN merge mixed-revisions modes", () => {
    const items = mergeMixedRevisionsQuickPickItems((message) => message);

    expect(items).toEqual([
      {
        label: "Require uniform revisions",
        description: "Reject merge targets with mixed working copy revisions",
        allowMixedRevisions: false,
      },
      {
        label: "Allow mixed revisions",
        description: "Allow merge targets with mixed working copy revisions",
        allowMixedRevisions: true,
      },
    ]);
  });

  it("offers SVN merge forced-delete modes", () => {
    const items = mergeForceDeleteQuickPickItems((message) => message);

    expect(items).toEqual([
      {
        label: "Prevent forced deletes",
        description: "Reject merge deletes that require libsvn force-delete",
        forceDelete: false,
      },
      {
        label: "Allow forced deletes",
        description: "Allow libsvn force-delete behavior during merge",
        forceDelete: true,
      },
    ]);
  });
});
