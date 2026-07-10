import { describe, expect, it } from "vitest";
import { historyOpenRevisionUriComponents } from "../src/history/historyOpenRevisionCommand";

describe("historyOpenRevisionUriComponents", () => {
  it("creates revision content URI components from a file-history revision command target", () => {
    expect(
      historyOpenRevisionUriComponents({
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        path: "src/main.c",
        revision: "r8",
        label: "src/main.c@r8",
      }),
    ).toEqual({
      scheme: "svn-r-revision",
      authority: "revision",
      path: "/",
      query: "repositoryId=repo-uuid%3AC%3A%2Fwc&epoch=7&path=src%2Fmain.c&revision=r8",
    });
  });

  it.each([
    ["empty repository id", { repositoryId: "" }],
    ["negative epoch", { epoch: -1 }],
    ["non-integer epoch", { epoch: 1.5 }],
    ["repository root path", { path: "." }],
    ["parent path", { path: "../outside.c" }],
    ["backslash path", { path: "src\\main.c" }],
    ["base revision", { revision: "base" }],
    ["head revision", { revision: "head" }],
    ["bare revision", { revision: "8" }],
    ["missing label", { label: "" }],
  ])("rejects spoofed %s", (_label, overrides) => {
    expect(() =>
      historyOpenRevisionUriComponents({
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        path: "src/main.c",
        revision: "r8",
        label: "src/main.c@r8",
        ...overrides,
      }),
    ).toThrow(
      expect.objectContaining({
        code: "SUBVERSIONR_HISTORY_OPEN_REVISION_TARGET_INVALID",
      }),
    );
  });
});
