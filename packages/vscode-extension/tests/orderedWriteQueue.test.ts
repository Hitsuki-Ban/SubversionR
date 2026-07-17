import { PassThrough } from "node:stream";
import { describe, expect, it, vi } from "vitest";
import { OrderedWriteQueue } from "../src/transport/orderedWriteQueue";

describe("OrderedWriteQueue", () => {
  it("waits for drain after write returns false and preserves frame order", async () => {
    const writable = new PassThrough();
    const write = vi.spyOn(writable, "write").mockReturnValueOnce(false).mockReturnValue(true);
    const onTerminalError = vi.fn();
    const queue = new OrderedWriteQueue(writable, onTerminalError);

    const first = queue.write("frame-1");
    const second = queue.write("frame-2");
    const third = queue.write("frame-3");

    let firstSettled = false;
    void first.finally(() => {
      firstSettled = true;
    });
    await Promise.resolve();
    expect(firstSettled).toBe(false);
    expect(write.mock.calls.map(([frame]) => frame)).toEqual(["frame-1"]);

    writable.emit("drain");

    await expect(first).resolves.toBeUndefined();
    await expect(second).resolves.toBeUndefined();
    await expect(third).resolves.toBeUndefined();
    expect(write.mock.calls.map(([frame]) => frame)).toEqual(["frame-1", "frame-2", "frame-3"]);
    expect(onTerminalError).not.toHaveBeenCalled();
    queue.dispose(new Error("test complete"));
  });

  it("rejects queued and future frames with the first writable error", async () => {
    const writable = new PassThrough();
    const write = vi.spyOn(writable, "write").mockReturnValue(false);
    const onTerminalError = vi.fn();
    const queue = new OrderedWriteQueue(writable, onTerminalError);
    const failure = new Error("stdin failed");

    const written = queue.write("frame-1");
    const queued = queue.write("frame-2");
    writable.emit("error", failure);

    await expect(written).rejects.toBe(failure);
    await expect(queued).rejects.toBe(failure);
    await expect(queue.write("frame-3")).rejects.toBe(failure);
    expect(onTerminalError).toHaveBeenCalledTimes(1);
    expect(onTerminalError).toHaveBeenCalledWith(failure);

    writable.emit("drain");
    expect(write.mock.calls.map(([frame]) => frame)).toEqual(["frame-1"]);
  });

  it("rejects queued and future frames deterministically when the writable closes", async () => {
    const writable = new PassThrough();
    const write = vi.spyOn(writable, "write").mockReturnValue(false);
    const onTerminalError = vi.fn();
    const queue = new OrderedWriteQueue(writable, onTerminalError);

    const written = queue.write("frame-1");
    const queued = queue.write("frame-2");
    writable.emit("close");

    await expect(written).rejects.toThrow("JSON-RPC stream closed");
    await expect(queued).rejects.toThrow("JSON-RPC stream closed");
    await expect(queue.write("frame-3")).rejects.toThrow("JSON-RPC stream closed");
    expect(onTerminalError).toHaveBeenCalledTimes(1);
    expect(onTerminalError).toHaveBeenCalledWith(
      expect.objectContaining({ message: "JSON-RPC stream closed" }),
    );
    expect(write.mock.calls.map(([frame]) => frame)).toEqual(["frame-1"]);
  });

  it("turns a synchronous write failure into the terminal queue error", async () => {
    const writable = new PassThrough();
    const failure = new Error("write threw");
    vi.spyOn(writable, "write").mockImplementation(() => {
      throw failure;
    });
    const onTerminalError = vi.fn();
    const queue = new OrderedWriteQueue(writable, onTerminalError);

    await expect(queue.write("frame-1")).rejects.toBe(failure);
    await expect(queue.write("frame-2")).rejects.toBe(failure);
    expect(onTerminalError).toHaveBeenCalledTimes(1);
    expect(onTerminalError).toHaveBeenCalledWith(failure);
  });
});
