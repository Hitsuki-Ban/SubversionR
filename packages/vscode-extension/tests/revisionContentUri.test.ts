import { describe, expect, it } from "vitest";
import {
  REVISION_CONTENT_URI_SCHEME,
  createRevisionContentUriComponents,
  parseRevisionContentUri,
} from "../src/content/revisionContentUri";

describe("revision content URI helpers", () => {
  it("encodes explicit revision content identity into a custom URI without exposing local filesystem paths", () => {
    const uri = createRevisionContentUriComponents({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src/main.c",
      revision: "r8",
    });

    expect(uri).toEqual({
      scheme: REVISION_CONTENT_URI_SCHEME,
      authority: "revision",
      path: "/",
      query: "repositoryId=repo-uuid%3AC%3A%2Fwc&epoch=7&path=src%2Fmain.c&revision=r8",
    });
  });

  it("parses an explicit revision content URI into a content/get request", () => {
    const request = parseRevisionContentUri({
      scheme: REVISION_CONTENT_URI_SCHEME,
      authority: "revision",
      path: "/",
      query: "repositoryId=repo-uuid%3AC%3A%2Fwc&epoch=7&path=src%2Fmain.c&revision=r8",
    });

    expect(request).toEqual({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      path: "src/main.c",
      revision: "r8",
    });
  });

  it("rejects malformed revision content URIs", () => {
    expect(() =>
      parseRevisionContentUri({
        scheme: "file",
        authority: "revision",
        path: "/",
        query: "repositoryId=repo-uuid%3AC%3A%2Fwc&epoch=7&path=src%2Fmain.c&revision=r8",
      }),
    ).toThrow("SUBVERSIONR_REVISION_CONTENT_URI_INVALID");
  });

  it("rejects duplicated identity query keys", () => {
    expect(() =>
      parseRevisionContentUri({
        scheme: REVISION_CONTENT_URI_SCHEME,
        authority: "revision",
        path: "/",
        query: "repositoryId=repo-uuid%3AC%3A%2Fwc&repositoryId=other&epoch=7&path=src%2Fmain.c&revision=r8",
      }),
    ).toThrow("SUBVERSIONR_REVISION_CONTENT_URI_INVALID");
  });

  it.each(["", ".", "src\\main.c", "../outside.c", "/trunk/main.c", "C:/wc/main.c", "src//main.c"])(
    "rejects invalid revision content path %j",
    (path) => {
      expect(() =>
        createRevisionContentUriComponents({
          repositoryId: "repo-uuid:C:/wc",
          epoch: 7,
          path,
          revision: "r8",
        }),
      ).toThrow("SUBVERSIONR_REVISION_CONTENT_URI_INVALID");
    },
  );

  it.each(["base", "head", "r", "r-1", "r01", "r2147483648"])(
    "rejects unsupported revision identity %j",
    (revision) => {
      expect(() =>
        createRevisionContentUriComponents({
          repositoryId: "repo-uuid:C:/wc",
          epoch: 7,
          path: "src/main.c",
          revision,
        }),
      ).toThrow("SUBVERSIONR_REVISION_CONTENT_URI_INVALID");
    },
  );
});
