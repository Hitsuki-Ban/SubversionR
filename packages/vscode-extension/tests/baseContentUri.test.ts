import { describe, expect, it } from "vitest";
import {
  BASE_CONTENT_URI_SCHEME,
  createBaseContentUriComponents,
  parseBaseContentUri,
} from "../src/content/baseContentUri";

describe("base content URI helpers", () => {
  it("encodes BASE content identity into a custom URI without exposing local filesystem paths", () => {
    const uri = createBaseContentUriComponents({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      generation: 11,
      path: "src/main.c",
      revision: "base",
    });

    expect(uri).toEqual({
      scheme: BASE_CONTENT_URI_SCHEME,
      authority: "base",
      path: "/",
      query:
        "repositoryId=repo-uuid%3AC%3A%2Fwc&epoch=7&generation=11&path=src%2Fmain.c&revision=base",
    });
  });

  it("parses a BASE content URI into a content/get request", () => {
    const request = parseBaseContentUri({
      scheme: BASE_CONTENT_URI_SCHEME,
      authority: "base",
      path: "/",
      query:
        "repositoryId=repo-uuid%3AC%3A%2Fwc&epoch=7&generation=11&path=src%2Fmain.c&revision=base",
    });

    expect(request).toEqual({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      generation: 11,
      path: "src/main.c",
      revision: "base",
    });
  });

  it("rejects malformed base content URIs", () => {
    expect(() =>
      parseBaseContentUri({
        scheme: "file",
        authority: "base",
        path: "/",
        query:
          "repositoryId=repo-uuid%3AC%3A%2Fwc&epoch=7&generation=11&path=src%2Fmain.c&revision=base",
      }),
    ).toThrow("SUBVERSIONR_BASE_CONTENT_URI_INVALID");
  });

  it("rejects duplicated identity query keys", () => {
    expect(() =>
      parseBaseContentUri({
        scheme: BASE_CONTENT_URI_SCHEME,
        authority: "base",
        path: "/",
        query:
          "repositoryId=repo-uuid%3AC%3A%2Fwc&repositoryId=other&epoch=7&generation=11&path=src%2Fmain.c&revision=base",
      }),
    ).toThrow("SUBVERSIONR_BASE_CONTENT_URI_INVALID");
  });

  it("rejects non-BASE revisions in BASE content URIs", () => {
    expect(() =>
      parseBaseContentUri({
        scheme: BASE_CONTENT_URI_SCHEME,
        authority: "base",
        path: "/",
        query:
          "repositoryId=repo-uuid%3AC%3A%2Fwc&epoch=7&generation=11&path=src%2Fmain.c&revision=head",
      }),
    ).toThrow("SUBVERSIONR_BASE_CONTENT_URI_INVALID");
  });
});
