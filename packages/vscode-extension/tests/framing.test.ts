import { describe, expect, it } from "vitest";
import {
  ContentLengthFrameDecoder,
  decodeContentLengthFrame,
  encodeContentLengthFrame,
} from "../src/transport/framing";

describe("Content-Length framing", () => {
  it("round-trips a JSON-RPC payload", () => {
    const payload = JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize" });

    const frame = encodeContentLengthFrame(payload);
    const decoded = decodeContentLengthFrame(frame);

    expect(frame.startsWith("Content-Length: ")).toBe(true);
    expect(decoded).toBe(payload);
  });

  it("rejects frames without a Content-Length header", () => {
    expect(() => decodeContentLengthFrame("{}")).toThrow("Missing Content-Length header");
  });

  it("decodes chunked frames and multiple frames", () => {
    const decoder = new ContentLengthFrameDecoder();
    const first = encodeContentLengthFrame(JSON.stringify({ jsonrpc: "2.0", id: 1, result: "ok" }));
    const second = encodeContentLengthFrame(JSON.stringify({ jsonrpc: "2.0", id: 2, result: "done" }));
    const joined = Buffer.from(first + second, "utf8");

    expect(decoder.push(joined.subarray(0, 5))).toEqual([]);
    const decoded = decoder.push(joined.subarray(5));

    expect(decoded).toEqual([
      JSON.stringify({ jsonrpc: "2.0", id: 1, result: "ok" }),
      JSON.stringify({ jsonrpc: "2.0", id: 2, result: "done" }),
    ]);
  });

  it("uses byte lengths for UTF-8 payloads", () => {
    const payload = JSON.stringify({ jsonrpc: "2.0", id: 3, result: "日本語" });
    const decoder = new ContentLengthFrameDecoder();

    expect(decoder.push(Buffer.from(encodeContentLengthFrame(payload), "utf8"))).toEqual([payload]);
  });
});
