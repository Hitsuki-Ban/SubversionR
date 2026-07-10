import { describe, expect, it } from "vitest";
import { suggestedCheckoutTargetPath } from "../src/repository/checkoutTargetSuggestion";

describe("checkoutTargetSuggestion", () => {
  it("suggests a checkout target under the first workspace root from the SVN URL leaf", () => {
    expect(
      suggestedCheckoutTargetPath("https://svn.example.com/project/trunk", ["C:\\workspace"], "win32"),
    ).toBe("C:\\workspace\\trunk");
  });

  it("decodes the SVN URL leaf before building the suggested target path", () => {
    expect(
      suggestedCheckoutTargetPath(
        "svn+ssh://svn.example.com/project/branches/feature%20alpha/",
        ["C:\\workspace"],
        "win32",
      ),
    ).toBe("C:\\workspace\\feature alpha");
  });

  it("does not suggest a checkout target when no workspace root is open", () => {
    expect(suggestedCheckoutTargetPath("https://svn.example.com/project/trunk", [], "win32")).toBeUndefined();
  });

  it("does not suggest a checkout target when the SVN URL has no path leaf", () => {
    expect(suggestedCheckoutTargetPath("https://svn.example.com/", ["C:\\workspace"], "win32")).toBeUndefined();
  });

  it("keeps suggested Windows target names valid when the SVN URL leaf contains reserved characters", () => {
    expect(
      suggestedCheckoutTargetPath("https://svn.example.com/project/feature%3Aalpha%3Fbeta", ["C:\\workspace"], "win32"),
    ).toBe("C:\\workspace\\feature-alpha-beta");
  });

  it.each([
    ["CON", "CON-wc"],
    ["prn", "prn-wc"],
    ["LPT1", "LPT1-wc"],
    ["com9.txt", "com9-wc.txt"],
  ])(
    "keeps suggested Windows target names valid when the SVN URL leaf is a reserved device name: %s",
    (targetName, sanitizedName) => {
      expect(suggestedCheckoutTargetPath(`https://svn.example.com/project/${targetName}`, ["C:\\workspace"], "win32"))
        .toBe(`C:\\workspace\\${sanitizedName}`);
    },
  );
});
