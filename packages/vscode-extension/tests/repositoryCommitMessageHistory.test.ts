import { describe, expect, it } from "vitest";
import { RepositoryCommitMessageHistory } from "../src/repository/repositoryCommitMessageHistory";

describe("RepositoryCommitMessageHistory", () => {
  it("keeps recent commit messages per repository with most-recent-first de-duplication", () => {
    const history = new RepositoryCommitMessageHistory({ maxMessages: 3 });

    history.record("repo-uuid:C:/wc", "first message");
    history.record("repo-uuid:C:/wc", "second message");
    history.record("repo-uuid:D:/other", "other repository message");
    history.record("repo-uuid:C:/wc", "first message");
    history.record("repo-uuid:C:/wc", "third message");
    history.record("repo-uuid:C:/wc", "fourth message");

    expect(history.messages("repo-uuid:C:/wc")).toEqual([
      "fourth message",
      "third message",
      "first message",
    ]);
    expect(history.messages("repo-uuid:D:/other")).toEqual(["other repository message"]);
  });

  it("does not record blank commit messages", () => {
    const history = new RepositoryCommitMessageHistory();

    history.record("repo-uuid:C:/wc", "  \n  ");

    expect(history.messages("repo-uuid:C:/wc")).toEqual([]);
  });
});
