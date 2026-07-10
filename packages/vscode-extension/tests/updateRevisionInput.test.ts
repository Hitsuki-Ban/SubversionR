import { describe, expect, it } from "vitest";
import { parseUpdateRevisionInput } from "../src/repository/updateRevisionInput";

describe("parseUpdateRevisionInput", () => {
  it("accepts canonical SVN revision numbers inside the supported range", () => {
    expect(parseUpdateRevisionInput("0")).toBe(0);
    expect(parseUpdateRevisionInput("42")).toBe(42);
    expect(parseUpdateRevisionInput(" 2147483647 ")).toBe(2_147_483_647);
  });

  it("rejects non-canonical or unsupported update revision input", () => {
    expect(parseUpdateRevisionInput("")).toBeUndefined();
    expect(parseUpdateRevisionInput("head")).toBeUndefined();
    expect(parseUpdateRevisionInput("r42")).toBeUndefined();
    expect(parseUpdateRevisionInput("00042")).toBeUndefined();
    expect(parseUpdateRevisionInput("01")).toBeUndefined();
    expect(parseUpdateRevisionInput("-1")).toBeUndefined();
    expect(parseUpdateRevisionInput("2147483648")).toBeUndefined();
  });
});
