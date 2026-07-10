import { describe, expect, it } from "vitest";
import { validateCheckoutUrl } from "../src/repository/checkoutUrlValidation";

describe("checkoutUrlValidation", () => {
  it.each([
    "file:///C:/repo/trunk",
    "http://svn.example.com/project/trunk",
    "https://svn.example.com/project/trunk",
    "svn://svn.example.com/project/trunk",
    "svn+ssh://svn.example.com/project/trunk",
    "svn+ssh://alice@svn.example.com/project/trunk",
    "svn+rsh://svn.example.com/project/trunk",
    "svn+joessh://alice@svn.example.com/project/trunk",
  ])("accepts supported SVN checkout URL: %s", (url) => {
    expect(validateCheckoutUrl(url)).toEqual({ valid: true });
  });

  it.each(["", "   ", "https://svn.example.com/project\ntrunk", "https://svn.example.com/project\0trunk"])(
    "rejects empty or control-character checkout URL input: %s",
    (url) => {
      expect(validateCheckoutUrl(url)).toEqual({ valid: false, reason: "emptyOrControl" });
    },
  );

  it.each(["trunk", "C:\\repo\\trunk", "not a url"])("rejects checkout URL input that cannot be parsed: %s", (url) => {
    expect(validateCheckoutUrl(url)).toEqual({ valid: false, reason: "invalidUrl" });
  });

  it.each(["ssh://svn.example.com/project/trunk", "ftp://svn.example.com/project/trunk"])(
    "rejects unsupported checkout URL scheme: %s",
    (url) => {
      expect(validateCheckoutUrl(url)).toEqual({ valid: false, reason: "unsupportedScheme" });
    },
  );

  it.each([
    "https://alice:secret@svn.example.com/project/trunk",
    "svn://alice:secret@svn.example.com/project/trunk",
    "svn+ssh://alice:secret@svn.example.com/project/trunk",
    "svn+rsh://alice:secret@svn.example.com/project/trunk",
  ])("rejects checkout URLs with embedded secrets: %s", (url) => {
    expect(validateCheckoutUrl(url)).toEqual({ valid: false, reason: "embeddedSecret" });
  });
});
