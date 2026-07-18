import { PassThrough } from "node:stream";
import { describe, expect, it, vi } from "vitest";
import { decodeContentLengthFrame, encodeContentLengthFrame } from "../src/transport/framing";
import {
  JsonRpcRequestCancelledError,
  JsonRpcStreamClient,
  JsonRpcStreamError,
} from "../src/transport/jsonRpcStreamClient";

describe("JsonRpcStreamClient", () => {
  it("writes content-length framed requests and resolves matching responses", async () => {
    const { client, stdin, stdout } = createClient();
    const request = client.sendRequest<{ accepted: boolean }>("shutdown", {});
    const frame = await readFrame(stdin);

    expect(JSON.parse(frame)).toEqual({
      jsonrpc: "2.0",
      id: 1,
      method: "shutdown",
      params: {},
    });

    stdout.write(framePayload({ jsonrpc: "2.0", id: 1, result: { accepted: true } }));

    await expect(request).resolves.toEqual({ accepted: true });
  });

  it("matches out-of-order responses by id", async () => {
    const { client, stdout } = createClient();

    const first = client.sendRequest<string>("first", {});
    const second = client.sendRequest<string>("second", {});
    stdout.write(framePayload({ jsonrpc: "2.0", id: 2, result: "second-result" }));
    stdout.write(framePayload({ jsonrpc: "2.0", id: 1, result: "first-result" }));

    await expect(second).resolves.toBe("second-result");
    await expect(first).resolves.toBe("first-result");
  });

  it("serializes outbound frames behind writable backpressure", async () => {
    const stdin = new PassThrough();
    const stdout = new PassThrough();
    const write = vi.spyOn(stdin, "write").mockReturnValueOnce(false).mockReturnValue(true);
    const client = new JsonRpcStreamClient({ readable: stdout, writable: stdin });

    const first = client.sendRequest<string>("first", {});
    const second = client.sendRequest<string>("second", {});

    expect(outboundMessages(write)).toEqual([{ jsonrpc: "2.0", id: 1, method: "first", params: {} }]);

    stdin.emit("drain");

    expect(outboundMessages(write)).toEqual([
      { jsonrpc: "2.0", id: 1, method: "first", params: {} },
      { jsonrpc: "2.0", id: 2, method: "second", params: {} },
    ]);
    stdout.write(framePayload({ jsonrpc: "2.0", id: 1, result: "first-result" }));
    stdout.write(framePayload({ jsonrpc: "2.0", id: 2, result: "second-result" }));
    await expect(first).resolves.toBe("first-result");
    await expect(second).resolves.toBe("second-result");
    client.dispose();
  });

  it("preserves request and cancellation frame order while backpressured", async () => {
    const stdin = new PassThrough();
    const stdout = new PassThrough();
    const write = vi.spyOn(stdin, "write").mockReturnValueOnce(false).mockReturnValue(true);
    const client = new JsonRpcStreamClient({ readable: stdout, writable: stdin });
    const controller = new AbortController();

    const request = client.sendRequest("status/refresh", {}, { signal: controller.signal });
    controller.abort();
    const followUp = client.sendRequest("shutdown", {});
    await expect(request).rejects.toBeInstanceOf(JsonRpcRequestCancelledError);

    expect(outboundMessages(write)).toEqual([
      { jsonrpc: "2.0", id: 1, method: "status/refresh", params: {} },
    ]);

    stdin.emit("drain");

    expect(outboundMessages(write)).toEqual([
      { jsonrpc: "2.0", id: 1, method: "status/refresh", params: {} },
      { jsonrpc: "2.0", method: "$/cancelRequest", params: { id: 1 } },
      { jsonrpc: "2.0", id: 2, method: "shutdown", params: {} },
    ]);
    stdout.write(framePayload({ jsonrpc: "2.0", id: 2, result: { accepted: true } }));
    await expect(followUp).resolves.toEqual({ accepted: true });
    client.dispose();
  });

  it("queues daemon initiated responses behind earlier backpressured frames", async () => {
    const stdin = new PassThrough();
    const stdout = new PassThrough();
    const write = vi.spyOn(stdin, "write").mockReturnValueOnce(false).mockReturnValue(true);
    const client = new JsonRpcStreamClient({
      readable: stdout,
      writable: stdin,
      requestHandler: () => ({ action: "cancel" }),
    });

    const blocker = client.sendRequest("initialize", {});
    stdout.write(
      framePayload({
        jsonrpc: "2.0",
        id: 9,
        method: "credentials/request",
        params: { requestId: "cred-1" },
      }),
    );
    await flushMicrotasks();

    expect(outboundMessages(write)).toEqual([
      { jsonrpc: "2.0", id: 1, method: "initialize", params: {} },
    ]);

    stdin.emit("drain");

    expect(outboundMessages(write)).toEqual([
      { jsonrpc: "2.0", id: 1, method: "initialize", params: {} },
      { jsonrpc: "2.0", id: 9, result: { action: "cancel" } },
    ]);
    client.dispose(new Error("test complete"));
    await expect(blocker).rejects.toThrow("test complete");
  });

  it("sends a cancel notification and ignores a later response when an outbound request is aborted", async () => {
    const { client, stdin, stdout } = createClient();
    const controller = new AbortController();
    const request = client.sendRequest<{ accepted: boolean }>("status/refresh", { repositoryId: "repo-1" }, {
      signal: controller.signal,
    });
    const requestFrame = await readFrame(stdin);
    expect(JSON.parse(requestFrame)).toEqual({
      jsonrpc: "2.0",
      id: 1,
      method: "status/refresh",
      params: { repositoryId: "repo-1" },
    });

    controller.abort();
    const cancelFrame = await readFrame(stdin);

    expect(JSON.parse(cancelFrame)).toEqual({
      jsonrpc: "2.0",
      method: "$/cancelRequest",
      params: { id: 1 },
    });
    await expect(request).rejects.toBeInstanceOf(JsonRpcRequestCancelledError);

    stdout.write(framePayload({ jsonrpc: "2.0", id: 1, result: { accepted: true } }));
    const followUp = client.sendRequest("shutdown", {});
    stdout.write(framePayload({ jsonrpc: "2.0", id: 2, result: { accepted: true } }));
    await expect(followUp).resolves.toEqual({ accepted: true });
  });

  it("answers daemon initiated requests with the registered handler result", async () => {
    const { client, stdin, stdout } = createClient({
      requestHandler: async (method, params) => {
        expect(method).toBe("credentials/request");
        expect(params).toEqual({ requestId: "cred-1", realm: "svn://example", kind: "usernamePassword" });
        return { requestId: "cred-1", action: "cancel" };
      },
    });

    stdout.write(
      framePayload({
        jsonrpc: "2.0",
        id: 9,
        method: "credentials/request",
        params: { requestId: "cred-1", realm: "svn://example", kind: "usernamePassword" },
      }),
    );

    const response = await readFrame(stdin);
    expect(JSON.parse(response)).toEqual({
      jsonrpc: "2.0",
      id: 9,
      result: { requestId: "cred-1", action: "cancel" },
    });

    client.dispose();
  });

  it("returns a structured method-not-found error for unhandled daemon initiated requests", async () => {
    const { client, stdin, stdout } = createClient();

    stdout.write(
      framePayload({
        jsonrpc: "2.0",
        id: 10,
        method: "credentials/request",
        params: { requestId: "cred-1" },
      }),
    );

    const response = await readFrame(stdin);
    expect(JSON.parse(response)).toEqual({
      jsonrpc: "2.0",
      id: 10,
      error: {
        code: "RPC_METHOD_NOT_FOUND",
        category: "unsupported",
        messageKey: "error.rpc.methodNotFound",
        args: { method: "credentials/request" },
        retryable: false,
        diagnostics: null,
      },
    });

    client.dispose();
  });

  it("dispatches daemon initiated notifications without writing a response", async () => {
    const notifications: unknown[] = [];
    const { client, stdin, stdout } = createClient({
      notificationHandler: (method, params) => {
        notifications.push({ method, params });
      },
    });

    stdout.write(
      framePayload({
        jsonrpc: "2.0",
        method: "status/stale",
        params: { repositoryId: "repo-uuid:C:/wc", epoch: 7, reason: "backendRestart" },
      }),
    );
    await flushMicrotasks();

    expect(notifications).toEqual([
      {
        method: "status/stale",
        params: { repositoryId: "repo-uuid:C:/wc", epoch: 7, reason: "backendRestart" },
      },
    ]);
    expect(stdin.readableLength).toBe(0);

    client.dispose();
  });

  it("disposes the stream when daemon initiated notifications have no handler", async () => {
    const { client, stdout } = createClient();

    const request = client.sendRequest("initialize", {});
    stdout.write(
      framePayload({
        jsonrpc: "2.0",
        method: "status/stale",
        params: { repositoryId: "repo-uuid:C:/wc", epoch: 7, reason: "backendRestart" },
      }),
    );
    const rejection = await captureImmediateRejection(request);

    expect(rejection).toMatchObject({
      message: "JSON-RPC notification handler is not configured for status/stale",
    });
    await expect(client.sendRequest("shutdown", {})).rejects.toThrow("JSON-RPC stream client is disposed");
  });

  it("does not forward arbitrary handler error args without safeArgs", async () => {
    const { client, stdin, stdout } = createClient({
      requestHandler: async () => {
        throw {
          code: "AUTH_FAILED",
          category: "auth",
          messageKey: "error.auth.failed",
          args: { password: "hunter2", path: "C:/secret/wc" },
        };
      },
    });

    stdout.write(
      framePayload({
        jsonrpc: "2.0",
        id: 11,
        method: "credentials/request",
        params: { requestId: "cred-1" },
      }),
    );

    const response = await readFrame(stdin);
    expect(JSON.parse(response)).toEqual({
      jsonrpc: "2.0",
      id: 11,
      error: {
        code: "AUTH_FAILED",
        category: "auth",
        messageKey: "error.auth.failed",
        args: {},
        retryable: false,
        diagnostics: null,
      },
    });

    client.dispose();
  });

  it("rejects JSON-RPC error responses with the structured error object", async () => {
    const { client, stdout } = createClient();

    const request = client.sendRequest("repository/open", { path: "C:/missing" });
    stdout.write(
      framePayload({
        jsonrpc: "2.0",
        id: 1,
        error: {
          code: "SVN_WC_NOT_FOUND",
          category: "native",
          messageKey: "error.native.workingCopyNotFound",
          args: { path: "C:/missing" },
          retryable: false,
          diagnostics: null,
        },
      }),
    );

    await expect(request).rejects.toMatchObject({
      code: "SVN_WC_NOT_FOUND",
      category: "native",
      messageKey: "error.native.workingCopyNotFound",
      safeArgs: { path: "C:/missing" },
      retryable: false,
      diagnostics: null,
      error: {
        code: "SVN_WC_NOT_FOUND",
        category: "native",
      },
    });
  });

  it("rejects and terminates the connection when an error response violates the structured contract", async () => {
    const onProtocolFault = vi.fn();
    const { client, stdout } = createClient({ onProtocolFault });

    const request = client.sendRequest("repository/open", { path: "C:/missing" });
    stdout.write(
      framePayload({
        jsonrpc: "2.0",
        id: 1,
        error: {
          code: "SVN_WC_NOT_FOUND",
          category: "native",
          messageKey: "error.native.workingCopyNotFound",
          args: {},
          retryable: false,
          diagnostics: {
            cause: "notWorkingCopy",
            svn: {
              entries: [{ code: 155007, name: "C:\\Users\\Alice\\secret" }],
              truncated: false,
            },
          },
        },
      }),
    );

    await expect(request).rejects.toThrow("SVN diagnostic entry is invalid");
    expect(onProtocolFault).toHaveBeenCalledWith(
      expect.objectContaining({ message: expect.stringContaining("SVN diagnostic entry is invalid") }),
    );
    await expect(client.sendRequest("shutdown", {})).rejects.toThrow("JSON-RPC stream client is disposed");
  });

  it("accepts the reviewed remote-origin diagnostic and rejects other custom diagnostic names", async () => {
    const accepted = createClient();
    const acceptedRequest = accepted.client.sendRequest("repository/checkout", {});
    accepted.stdout.write(
      framePayload({
        jsonrpc: "2.0",
        id: 1,
        error: {
          code: "SUBVERSIONR_REMOTE_ORIGIN_MISMATCH",
          category: "configuration",
          messageKey: "error.remote.originMismatch",
          args: {},
          retryable: false,
          diagnostics: {
            cause: "unknownNative",
            svn: {
              entries: [{ code: 170000, name: "SUBVERSIONR_ERR_REMOTE_ORIGIN_MISMATCH" }],
              truncated: false,
            },
          },
        },
      }),
    );
    await expect(acceptedRequest).rejects.toMatchObject({
      code: "SUBVERSIONR_REMOTE_ORIGIN_MISMATCH",
      diagnostics: {
        svn: { entries: [{ code: 170000, name: "SUBVERSIONR_ERR_REMOTE_ORIGIN_MISMATCH" }] },
      },
    });

    const rejected = createClient();
    const rejectedRequest = rejected.client.sendRequest("repository/checkout", {});
    rejected.stdout.write(
      framePayload({
        jsonrpc: "2.0",
        id: 1,
        error: {
          code: "SUBVERSIONR_REMOTE_ORIGIN_MISMATCH",
          category: "configuration",
          messageKey: "error.remote.originMismatch",
          args: {},
          retryable: false,
          diagnostics: {
            cause: "unknownNative",
            svn: {
              entries: [{ code: 170000, name: "SUBVERSIONR_ERR_UNREVIEWED" }],
              truncated: false,
            },
          },
        },
      }),
    );
    await expect(rejectedRequest).rejects.toThrow("SVN diagnostic entry is invalid");
  });

  it("settles an error response even when the request-error observer throws", async () => {
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => undefined);
    const { client, stdout } = createClient({
      onRequestError: () => {
        throw new Error("observer failed");
      },
    });

    const request = client.sendRequest("repository/open", { path: "C:/missing" });
    stdout.write(
      framePayload({
        jsonrpc: "2.0",
        id: 1,
        error: {
          code: "SVN_WC_NOT_FOUND",
          category: "native",
          messageKey: "error.native.workingCopyNotFound",
          args: {},
          retryable: false,
          diagnostics: null,
        },
      }),
    );

    await expect(request).rejects.toBeInstanceOf(JsonRpcStreamError);
    expect(consoleError).toHaveBeenCalledWith(
      "SubversionR JSON-RPC request-error observer failed.",
      expect.objectContaining({ message: "observer failed" }),
    );
    client.dispose();
    consoleError.mockRestore();
  });

  it("rejects pending requests when disposed", async () => {
    const { client } = createClient();

    const request = client.sendRequest("initialize", {});
    client.dispose(new Error("backend exited"));

    await expect(request).rejects.toThrow("backend exited");
  });

  it("rejects pending requests when inbound framing is malformed", async () => {
    const { client, stdout } = createClient();

    const request = client.sendRequest("initialize", {});
    stdout.write("Bad-Header: 1\r\n\r\n{}");

    await expect(request).rejects.toThrow("Invalid Content-Length header");
  });

  it("rejects pending requests when inbound JSON is malformed", async () => {
    const { client, stdout } = createClient();

    const request = client.sendRequest("initialize", {});
    stdout.write(encodeContentLengthFrame("{"));

    await expect(request).rejects.toThrow();
  });

  it("rejects pending requests when readable stream closes", async () => {
    const { client, stdout } = createClient();

    const request = client.sendRequest("initialize", {});
    stdout.emit("close");

    await expect(request).rejects.toThrow("JSON-RPC stream closed");
  });

  it("rejects pending requests when writable stream errors", async () => {
    const { client, stdin } = createClient();

    const request = client.sendRequest("initialize", {});
    stdin.emit("error", new Error("stdin failed"));

    await expect(request).rejects.toThrow("stdin failed");
  });

  it("removes stream listeners when disposed", () => {
    const { client, stdin, stdout } = createClient();

    client.dispose();

    expect(stdout.listenerCount("data")).toBe(0);
    expect(stdout.listenerCount("error")).toBe(0);
    expect(stdout.listenerCount("close")).toBe(0);
    expect(stdout.listenerCount("end")).toBe(0);
    expect(stdin.listenerCount("error")).toBe(0);
    expect(stdin.listenerCount("close")).toBe(0);
  });
});

function createClient(options: Partial<ConstructorParameters<typeof JsonRpcStreamClient>[0]> = {}): {
  client: JsonRpcStreamClient;
  stdin: PassThrough;
  stdout: PassThrough;
} {
  const stdin = new PassThrough();
  const stdout = new PassThrough();
  const client = new JsonRpcStreamClient({ readable: stdout, writable: stdin, ...options });
  return { client, stdin, stdout };
}

async function readFrame(stream: PassThrough): Promise<string> {
  const chunk = await new Promise<Buffer>((resolve) => {
    stream.once("data", (data: Buffer) => resolve(data));
  });
  const frame = chunk.toString("utf8");
  const payload = frame.slice(frame.indexOf("\r\n\r\n") + 4);
  return payload;
}

function framePayload(payload: unknown): string {
  return encodeContentLengthFrame(JSON.stringify(payload));
}

function outboundMessages(write: ReturnType<typeof vi.spyOn>): unknown[] {
  return write.mock.calls.map((call: unknown[]) =>
    JSON.parse(decodeContentLengthFrame(String(call[0]))) as unknown,
  );
}

async function flushMicrotasks(): Promise<void> {
  await new Promise<void>((resolve) => setImmediate(resolve));
}

async function captureImmediateRejection(promise: Promise<unknown>): Promise<Error | undefined> {
  return await Promise.race([
    promise.then(
      () => undefined,
      (error: unknown) => (error instanceof Error ? error : new Error(String(error))),
    ),
    new Promise<undefined>((resolve) => setImmediate(() => resolve(undefined))),
  ]);
}
