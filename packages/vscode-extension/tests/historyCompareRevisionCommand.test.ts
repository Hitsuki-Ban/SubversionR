import { describe, expect, it } from "vitest";
import { historyCompareRevisionUriComponents } from "../src/history/historyCompareRevisionCommand";

describe("historyCompareRevisionUriComponents", () => {
  it("creates revision content URI components for a file-history previous comparison target", () => {
    expect(
      historyCompareRevisionUriComponents({
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        path: "src/main.c",
        leftRevision: "r5",
        rightRevision: "r8",
        label: "src/main.c r5..r8",
      }),
    ).toEqual({
      left: {
        scheme: "svn-r-revision",
        authority: "revision",
        path: "/",
        query: "repositoryId=repo-uuid%3AC%3A%2Fwc&epoch=7&path=src%2Fmain.c&revision=r5",
      },
      right: {
        scheme: "svn-r-revision",
        authority: "revision",
        path: "/",
        query: "repositoryId=repo-uuid%3AC%3A%2Fwc&epoch=7&path=src%2Fmain.c&revision=r8",
      },
      label: "src/main.c r5..r8",
    });
  });

  it.each([
    ["empty repository id", { repositoryId: "" }],
    ["negative epoch", { epoch: -1 }],
    ["non-integer epoch", { epoch: 1.5 }],
    ["repository root path", { path: "." }],
    ["parent path", { path: "../outside.c" }],
    ["backslash path", { path: "src\\main.c" }],
    ["base left revision", { leftRevision: "base" }],
    ["head right revision", { rightRevision: "head" }],
    ["bare left revision", { leftRevision: "5" }],
    ["bare right revision", { rightRevision: "8" }],
    ["same revision", { leftRevision: "r8", rightRevision: "r8" }],
    ["newer left revision", { leftRevision: "r8", rightRevision: "r5" }],
    ["missing label", { label: "" }],
  ])("rejects spoofed %s", (_label, overrides) => {
    expect(() =>
      historyCompareRevisionUriComponents({
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        path: "src/main.c",
        leftRevision: "r5",
        rightRevision: "r8",
        label: "src/main.c r5..r8",
        ...overrides,
      }),
    ).toThrow(
      expect.objectContaining({
        code: "SUBVERSIONR_HISTORY_COMPARE_PREVIOUS_TARGET_INVALID",
      }),
    );
  });
});
