import { describe, expect, it } from "vitest";
import { LensSettingsError, readLensSettings } from "../src/lens/lensSettings";

describe("lens settings", () => {
  it("reads explicit SVN Lens defaults from the SubversionR configuration namespace", () => {
    const settings = readLensSettings(fakeConfiguration({}));

    expect(settings).toEqual({
      enabled: true,
      fileHeader: true,
      currentLine: true,
      hover: true,
      symbols: false,
      maxFileLines: 20000,
    });
  });

  it("fails fast on malformed SVN Lens settings", () => {
    expect(() => readLensSettings(fakeConfiguration({ "lens.enabled": "yes" }))).toThrow(LensSettingsError);
    expect(() => readLensSettings(fakeConfiguration({ "lens.fileHeader": "yes" }))).toThrow(LensSettingsError);
    expect(() => readLensSettings(fakeConfiguration({ "lens.currentLine": "yes" }))).toThrow(LensSettingsError);
    expect(() => readLensSettings(fakeConfiguration({ "lens.hover": "yes" }))).toThrow(LensSettingsError);
    expect(() => readLensSettings(fakeConfiguration({ "lens.symbols": "yes" }))).toThrow(LensSettingsError);
    expect(() => readLensSettings(fakeConfiguration({ "lens.maxFileLines": 0 }))).toThrow(LensSettingsError);
    expect(() => readLensSettings(fakeConfiguration({ "lens.maxFileLines": 20000.5 }))).toThrow(LensSettingsError);
  });

  it("does not read legacy or svnNative setting aliases", () => {
    const settings = readLensSettings(
      fakeConfiguration({
        "svnNative.lens.enabled": false,
        "svn.lens.enabled": false,
        "svnNative.lens.currentLine": false,
        "svnNative.lens.hover": false,
        "svnNative.lens.symbols": true,
        "svn.lens.currentLine": false,
        "svn.lens.hover": false,
        "svn.lens.symbols": true,
      }),
    );

    expect(settings.enabled).toBe(true);
    expect(settings.currentLine).toBe(true);
    expect(settings.hover).toBe(true);
    expect(settings.symbols).toBe(false);
  });
});

function fakeConfiguration(values: Record<string, unknown>) {
  return {
    get: (key: string, defaultValue?: unknown) => (key in values ? values[key] : defaultValue),
  };
}
