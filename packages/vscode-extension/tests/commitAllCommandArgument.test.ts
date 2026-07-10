import { describe, expect, it } from "vitest";
import { commitAllRepositoryIdArgument } from "../src/repository/commitAllCommandArgument";

describe("commitAllRepositoryIdArgument", () => {
  it("maps VS Code SCM title SourceControl objects to their registered repository id", () => {
    const sourceControlRepositoryIds = new WeakMap<object, string>();
    const sourceControl = {};
    sourceControlRepositoryIds.set(sourceControl, "repo-uuid:C:/workspace");

    expect(commitAllRepositoryIdArgument(sourceControl, sourceControlRepositoryIds)).toBe(
      "repo-uuid:C:/workspace",
    );
  });

  it("keeps input-accept repository ids and unknown arguments for the command controller", () => {
    const sourceControlRepositoryIds = new WeakMap<object, string>();
    const unknownObject = {};

    expect(commitAllRepositoryIdArgument("repo-uuid:C:/workspace", sourceControlRepositoryIds)).toBe(
      "repo-uuid:C:/workspace",
    );
    expect(commitAllRepositoryIdArgument(undefined, sourceControlRepositoryIds)).toBeUndefined();
    expect(commitAllRepositoryIdArgument(unknownObject, sourceControlRepositoryIds)).toBe(unknownObject);
  });
});
