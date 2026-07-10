import { describe, expect, it } from "vitest";
import { readStatusSettings } from "../src/status/statusSettings";

describe("readStatusSettings", () => {
  it("reads the SCM count policy from the SubversionR status configuration section", () => {
    const settings = readStatusSettings({
      get: <T>(key: string): T | undefined => {
        const values: Record<string, unknown> = {
          "status.countUnversioned": true,
          "status.ignoreChangelistsInCount": ["ignore-on-commit"],
        };
        return values[key] as T | undefined;
      },
    });

    expect(settings).toEqual({
      countUnversioned: true,
      ignoreChangelistsInCount: ["ignore-on-commit"],
    });
  });

  it("fails fast when the countUnversioned setting is missing or invalid", () => {
    expect(() =>
      readStatusSettings({
        get: () => undefined,
      }),
    ).toThrowError(
      expect.objectContaining({
        code: "SUBVERSIONR_STATUS_CONFIG_INVALID",
        category: "configuration",
        messageKey: "error.status.configInvalid",
        safeArgs: { field: "status.countUnversioned" },
      }),
    );
  });

  it("fails fast when ignored changelist entries are not non-empty strings", () => {
    expect(() =>
      readStatusSettings({
        get: <T>(key: string): T | undefined => {
          const values: Record<string, unknown> = {
            "status.countUnversioned": false,
            "status.ignoreChangelistsInCount": ["ignore-on-commit", ""],
          };
          return values[key] as T | undefined;
        },
      }),
    ).toThrowError(
      expect.objectContaining({
        code: "SUBVERSIONR_STATUS_CONFIG_INVALID",
        category: "configuration",
        messageKey: "error.status.configInvalid",
        safeArgs: { field: "status.ignoreChangelistsInCount.1" },
      }),
    );
  });
});
