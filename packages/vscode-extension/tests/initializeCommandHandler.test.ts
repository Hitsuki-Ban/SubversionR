import { describe, expect, it, vi } from "vitest";
import { createInitializeCommandHandler } from "../src/backend/initializeCommandHandler";

describe("initialize command handler", () => {
  it("settles the successful initialize command exactly once", async () => {
    const connection = { libsvnVersion: "1.14.5" };
    const options = initializeOptions();
    options.initialize.mockResolvedValue(connection);
    const handler = createInitializeCommandHandler(options);

    await expect(withTestTimeout(handler(), 50)).resolves.toBeUndefined();

    expect(options.initialize).toHaveBeenCalledTimes(1);
    expect(options.onReady).toHaveBeenCalledTimes(1);
    expect(options.onReady).toHaveBeenCalledWith(connection);
    expect(options.recordFailure).not.toHaveBeenCalled();
    expect(options.showErrorMessage).not.toHaveBeenCalled();
  });

  it("settles failure without awaiting a notification that remains open", async () => {
    const startupFailure = new Error("startup failed");
    const options = initializeOptions();
    options.initialize.mockRejectedValue(startupFailure);
    options.showErrorMessage.mockImplementation(() => new Promise(() => undefined));
    const handler = createInitializeCommandHandler(options);

    await expect(withTestTimeout(handler(), 50)).resolves.toBeUndefined();

    expect(options.initialize).toHaveBeenCalledTimes(1);
    expect(options.recordFailure).toHaveBeenCalledTimes(1);
    expect(options.recordFailure).toHaveBeenCalledWith(startupFailure);
    expect(options.onReady).not.toHaveBeenCalled();
    await vi.waitFor(() => expect(options.showErrorMessage).toHaveBeenCalledTimes(1));
  });

  it("settles a disposal rejection and contains notification failures", async () => {
    const options = initializeOptions();
    const disposalFailure = new Error("backend service disposed");
    const notificationFailure = new Error("notification host disposed");
    options.initialize.mockRejectedValue(disposalFailure);
    options.showErrorMessage.mockRejectedValue(notificationFailure);
    const handler = createInitializeCommandHandler(options);

    await expect(withTestTimeout(handler(), 50)).resolves.toBeUndefined();

    expect(options.recordFailure).toHaveBeenCalledTimes(1);
    await vi.waitFor(() => {
      expect(options.recordNotificationFailure).toHaveBeenCalledTimes(1);
    });
    expect(options.recordNotificationFailure).toHaveBeenCalledWith(notificationFailure);
  });
});

function initializeOptions() {
  return {
    initialize: vi.fn<() => Promise<{ libsvnVersion: string }>>(),
    onReady: vi.fn<(connection: { libsvnVersion: string }) => void>(),
    recordFailure: vi.fn<(error: unknown) => void>(),
    failureMessage: vi.fn(() => "SubversionR backend startup failed."),
    showErrorMessage: vi.fn<(message: string, action: string) => Promise<string | undefined>>(),
    showLogAction: "Show Log",
    showLog: vi.fn<() => void>(),
    recordNotificationFailure: vi.fn<(error: unknown) => void>(),
  };
}

function withTestTimeout<T>(promise: Promise<T>, timeoutMs: number): Promise<T> {
  return Promise.race([
    promise,
    new Promise<never>((_resolve, reject) => {
      setTimeout(() => reject(new Error(`initialize command did not settle within ${timeoutMs}ms`)), timeoutMs);
    }),
  ]);
}
