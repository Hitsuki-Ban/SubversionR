import { describe, expect, it } from "vitest";
import {
  repositoryHistoryCommandArgument,
  repositoryHistoryCommandTarget,
} from "../src/repository/repositoryHistoryCommandTarget";

describe("repository history command target", () => {
  it("maps a registered VS Code SourceControl object to its exact repository session", () => {
    const targets = new WeakMap<object, ReturnType<typeof repositoryHistoryCommandTarget>>();
    const sourceControl = {};
    const target = repositoryHistoryCommandTarget("repo-uuid:C:/workspace", 7);
    targets.set(sourceControl, target);

    expect(repositoryHistoryCommandArgument(sourceControl, targets)).toBe(target);
  });

  it("leaves palette and unknown arguments for strict controller validation", () => {
    const targets = new WeakMap<object, ReturnType<typeof repositoryHistoryCommandTarget>>();
    const unknown = {};

    expect(repositoryHistoryCommandArgument(undefined, targets)).toBeUndefined();
    expect(repositoryHistoryCommandArgument(unknown, targets)).toBe(unknown);
  });
});
