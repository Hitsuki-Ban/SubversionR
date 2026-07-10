import { describe, expect, it } from "vitest";
import {
  HEAD_CONTENT_URI_SCHEME,
  createHeadContentUriComponents,
  parseHeadContentUri,
} from "../src/content/headContentUri";

describe("HEAD content URI helpers", () => {
  it("encodes mutable HEAD content identity with a per-request id", () => {
    const uri = createHeadContentUriComponents({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      generation: 11,
      path: "src/main.c",
      revision: "head",
      requestId: "11111111-1111-4111-8111-111111111111",
    });

    expect(uri).toEqual({
      scheme: HEAD_CONTENT_URI_SCHEME,
      authority: "head",
      path: "/",
      query:
        "repositoryId=repo-uuid%3AC%3A%2Fwc&epoch=7&generation=11&path=src%2Fmain.c&revision=head&requestId=11111111-1111-4111-8111-111111111111",
    });
  });

  it("parses a HEAD content URI into its strict request identity", () => {
    const request = parseHeadContentUri({
      scheme: HEAD_CONTENT_URI_SCHEME,
      authority: "head",
      path: "/",
      query:
        "repositoryId=repo-uuid%3AC%3A%2Fwc&epoch=7&generation=11&path=src%2Fmain.c&revision=head&requestId=11111111-1111-4111-8111-111111111111",
    });

    expect(request).toEqual({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      generation: 11,
      path: "src/main.c",
      revision: "head",
      requestId: "11111111-1111-4111-8111-111111111111",
    });
  });

  it("rejects malformed HEAD content URIs", () => {
    expect(() =>
      parseHeadContentUri({
        scheme: "file",
        authority: "head",
        path: "/",
        query:
          "repositoryId=repo-uuid%3AC%3A%2Fwc&epoch=7&generation=11&path=src%2Fmain.c&revision=head&requestId=11111111-1111-4111-8111-111111111111",
      }),
    ).toThrow("SUBVERSIONR_HEAD_CONTENT_URI_INVALID");
  });

  it("rejects duplicated identity query keys", () => {
    expect(() =>
      parseHeadContentUri({
        scheme: HEAD_CONTENT_URI_SCHEME,
        authority: "head",
        path: "/",
        query:
          "repositoryId=repo-uuid%3AC%3A%2Fwc&repositoryId=other&epoch=7&generation=11&path=src%2Fmain.c&revision=head&requestId=11111111-1111-4111-8111-111111111111",
      }),
    ).toThrow("SUBVERSIONR_HEAD_CONTENT_URI_INVALID");
  });

  it.each(["", ".", "src\\main.c", "../outside.c", "/trunk/main.c", "C:/wc/main.c", "src//main.c"])(
    "rejects invalid HEAD content path %j",
    (path) => {
      expect(() =>
        createHeadContentUriComponents({
          repositoryId: "repo-uuid:C:/wc",
          epoch: 7,
          generation: 11,
          path,
          revision: "head",
          requestId: "11111111-1111-4111-8111-111111111111",
        }),
      ).toThrow("SUBVERSIONR_HEAD_CONTENT_URI_INVALID");
    },
  );

  it.each(["base", "r8", "HEAD", ""])("rejects unsupported HEAD revision identity %j", (revision) => {
    expect(() =>
      createHeadContentUriComponents({
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        generation: 11,
        path: "src/main.c",
        revision: revision as never,
        requestId: "11111111-1111-4111-8111-111111111111",
      }),
    ).toThrow("SUBVERSIONR_HEAD_CONTENT_URI_INVALID");
  });

  it.each(["", "request-1", "11111111-1111-1111-1111-111111111111"])(
    "rejects invalid HEAD request id %j",
    (requestId) => {
      expect(() =>
        createHeadContentUriComponents({
          repositoryId: "repo-uuid:C:/wc",
          epoch: 7,
          generation: 11,
          path: "src/main.c",
          revision: "head",
          requestId,
        }),
      ).toThrow("SUBVERSIONR_HEAD_CONTENT_URI_INVALID");
    },
  );
});
