import { describe, expect, it } from "vitest";
import { readHistorySettings } from "../src/history/historySettings";

describe("readHistorySettings", () => {
  it("reads bounded history view settings from the SubversionR configuration section", () => {
    const settings = readHistorySettings({
      get: <T>(key: string): T | undefined => {
        const values: Record<string, unknown> = {
          "history.pageSize": 100,
          "history.includeMergedRevisions": true,
        };
        return values[key] as T | undefined;
      },
    });

    expect(settings).toEqual({
      pageSize: 100,
      includeMergedRevisions: true,
    });
  });

  it.each([0, 501, 1.5, Number.NaN])("fails fast for invalid history page size %j", (pageSize) => {
    expect(() =>
      readHistorySettings({
        get: <T>(key: string): T | undefined => {
          const values: Record<string, unknown> = {
            "history.pageSize": pageSize,
            "history.includeMergedRevisions": false,
          };
          return values[key] as T | undefined;
        },
      }),
    ).toThrowError(
      expect.objectContaining({
        code: "SUBVERSIONR_HISTORY_CONFIG_INVALID",
        category: "configuration",
        messageKey: "error.history.configInvalid",
        safeArgs: { field: "history.pageSize" },
      }),
    );
  });

  it("fails fast when includeMergedRevisions is missing or invalid", () => {
    expect(() =>
      readHistorySettings({
        get: <T>(key: string): T | undefined => {
          const values: Record<string, unknown> = {
            "history.pageSize": 100,
            "history.includeMergedRevisions": "false",
          };
          return values[key] as T | undefined;
        },
      }),
    ).toThrowError(
      expect.objectContaining({
        code: "SUBVERSIONR_HISTORY_CONFIG_INVALID",
        category: "configuration",
        messageKey: "error.history.configInvalid",
        safeArgs: { field: "history.includeMergedRevisions" },
      }),
    );
  });
});
