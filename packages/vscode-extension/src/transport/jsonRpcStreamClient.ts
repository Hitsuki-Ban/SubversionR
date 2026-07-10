import type { Readable, Writable } from "node:stream";
import type { JsonRpcRequestOptions, JsonRpcSender } from "../status/types";
import { ContentLengthFrameDecoder, encodeContentLengthFrame } from "./framing";

export interface JsonRpcStreamClientOptions {
  readable: Readable;
  writable: Writable;
  requestHandler?: JsonRpcRequestHandler;
  notificationHandler?: JsonRpcNotificationHandler;
  onProtocolFault?: (error: Error) => void;
}

export type JsonRpcRequestHandler = (method: string, params: unknown) => Promise<unknown> | unknown;
export type JsonRpcNotificationHandler = (method: string, params: unknown) => Promise<void> | void;

interface PendingRequest {
  cleanup(): void;
  resolve(value: unknown): void;
  reject(error: Error): void;
}

interface JsonRpcResponse {
  jsonrpc: "2.0";
  id: number | string;
  result?: unknown;
  error?: unknown;
}

interface JsonRpcInboundRequest {
  jsonrpc: "2.0";
  id: number | string;
  method: string;
  params?: unknown;
}

interface JsonRpcInboundNotification {
  jsonrpc: "2.0";
  method: string;
  params?: unknown;
}

export class JsonRpcStreamError extends Error {
  public constructor(public readonly error: unknown) {
    super(errorMessage(error));
  }
}

export class JsonRpcRequestCancelledError extends Error {
  public readonly code = "JSON_RPC_REQUEST_CANCELLED";

  public constructor(public readonly requestId: number) {
    super("JSON-RPC request cancelled");
    this.name = "JsonRpcRequestCancelledError";
  }
}

export class JsonRpcStreamClient implements JsonRpcSender {
  private readonly decoder = new ContentLengthFrameDecoder();
  private readonly pending = new Map<number, PendingRequest>();
  private nextId = 1;
  private disposed = false;

  public constructor(private readonly options: JsonRpcStreamClientOptions) {
    this.options.readable.on("data", this.handleData);
    this.options.readable.on("error", this.handleStreamError);
    this.options.readable.on("close", this.handleClose);
    this.options.readable.on("end", this.handleClose);
    this.options.writable.on("error", this.handleStreamError);
    this.options.writable.on("close", this.handleClose);
  }

  public sendRequest<T>(method: string, params: unknown, options: JsonRpcRequestOptions = {}): Promise<T> {
    if (this.disposed) {
      return Promise.reject(new Error("JSON-RPC stream client is disposed"));
    }
    if (options.signal?.aborted) {
      return Promise.reject(new JsonRpcRequestCancelledError(this.nextId));
    }

    const id = this.nextId;
    this.nextId += 1;
    const payload = JSON.stringify({
      jsonrpc: "2.0",
      id,
      method,
      params,
    });

    return new Promise<T>((resolve, reject) => {
      const abortListener = () => {
        const pending = this.pending.get(id);
        if (!pending) {
          return;
        }
        this.pending.delete(id);
        pending.cleanup();
        this.writeCancelNotification(id);
        pending.reject(new JsonRpcRequestCancelledError(id));
      };
      const cleanup = () => {
        options.signal?.removeEventListener("abort", abortListener);
      };
      this.pending.set(id, {
        cleanup,
        resolve: (value) => resolve(value as T),
        reject,
      });
      options.signal?.addEventListener("abort", abortListener, { once: true });
      try {
        this.options.writable.write(encodeContentLengthFrame(payload), "utf8");
      } catch (error) {
        this.pending.delete(id);
        cleanup();
        reject(error instanceof Error ? error : new Error(String(error)));
      }
    });
  }

  public dispose(reason = new Error("JSON-RPC stream client disposed")): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.options.readable.off("data", this.handleData);
    this.options.readable.off("error", this.handleStreamError);
    this.options.readable.off("close", this.handleClose);
    this.options.readable.off("end", this.handleClose);
    this.options.writable.off("error", this.handleStreamError);
    this.options.writable.off("close", this.handleClose);
    this.rejectPending(reason);
  }

  private readonly handleData = (chunk: Buffer | string): void => {
    try {
      const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk, "utf8");
      for (const payload of this.decoder.push(bytes)) {
        this.handlePayload(payload);
      }
    } catch (error) {
      this.disposeForProtocolFault(error instanceof Error ? error : new Error(String(error)));
    }
  };

  private handlePayload(payload: string): void {
    const message = JSON.parse(payload) as JsonRpcResponse | JsonRpcInboundRequest | JsonRpcInboundNotification;
    if (isInboundNotification(message)) {
      void this.handleInboundNotification(message);
      return;
    }
    if (isInboundRequest(message)) {
      void this.handleInboundRequest(message);
      return;
    }

    const response = message;
    if (typeof response.id !== "number") {
      return;
    }
    const pending = this.pending.get(response.id);
    if (!pending) {
      return;
    }

    this.pending.delete(response.id);
    pending.cleanup();
    if (response.error !== undefined) {
      pending.reject(new JsonRpcStreamError(response.error));
      return;
    }
    pending.resolve(response.result);
  }

  private async handleInboundRequest(request: JsonRpcInboundRequest): Promise<void> {
    if (!this.options.requestHandler) {
      this.writeJsonRpcMessage({
        jsonrpc: "2.0",
        id: request.id,
        error: rpcError("RPC_METHOD_NOT_FOUND", "unsupported", "error.rpc.methodNotFound", {
          method: request.method,
        }),
      });
      return;
    }

    try {
      const result = await this.options.requestHandler(request.method, request.params);
      this.writeJsonRpcMessage({
        jsonrpc: "2.0",
        id: request.id,
        result,
      });
    } catch (error) {
      this.writeJsonRpcMessage({
        jsonrpc: "2.0",
        id: request.id,
        error: requestHandlerError(request.method, error),
      });
    }
  }

  private async handleInboundNotification(notification: JsonRpcInboundNotification): Promise<void> {
    if (!this.options.notificationHandler) {
      this.disposeForProtocolFault(
        new Error(`JSON-RPC notification handler is not configured for ${notification.method}`),
      );
      return;
    }

    try {
      await this.options.notificationHandler(notification.method, notification.params);
    } catch (error) {
      this.disposeForProtocolFault(error instanceof Error ? error : new Error(String(error)));
    }
  }

  private disposeForProtocolFault(error: Error): void {
    this.dispose(error);
    this.options.onProtocolFault?.(error);
  }

  private writeJsonRpcMessage(message: unknown): void {
    if (this.disposed) {
      return;
    }
    this.options.writable.write(encodeContentLengthFrame(JSON.stringify(message)), "utf8");
  }

  private writeCancelNotification(id: number): void {
    this.writeJsonRpcMessage({
      jsonrpc: "2.0",
      method: "$/cancelRequest",
      params: { id },
    });
  }

  private readonly handleStreamError = (error: Error): void => {
    this.dispose(error);
  };

  private readonly handleClose = (): void => {
    this.dispose(new Error("JSON-RPC stream closed"));
  };

  private rejectPending(error: Error): void {
    const pending = Array.from(this.pending.values());
    this.pending.clear();
    for (const request of pending) {
      request.cleanup();
      request.reject(error);
    }
  }
}

function errorMessage(error: unknown): string {
  if (typeof error === "object" && error && "code" in error) {
    return String(error.code);
  }
  return "JSON-RPC request failed";
}

function isInboundRequest(
  message: JsonRpcResponse | JsonRpcInboundRequest | JsonRpcInboundNotification,
): message is JsonRpcInboundRequest {
  return typeof (message as JsonRpcInboundRequest).method === "string" && "id" in message;
}

function isInboundNotification(
  message: JsonRpcResponse | JsonRpcInboundRequest | JsonRpcInboundNotification,
): message is JsonRpcInboundNotification {
  return typeof (message as JsonRpcInboundNotification).method === "string" && !("id" in message);
}

function rpcError(
  code: string,
  category: string,
  messageKey: string,
  args: Record<string, unknown>,
): Record<string, unknown> {
  return {
    code,
    category,
    messageKey,
    args,
    retryable: false,
  };
}

function requestHandlerError(method: string, error: unknown): Record<string, unknown> {
  if (typeof error === "object" && error !== null && "code" in error && "messageKey" in error) {
    const structured = error as {
      code: unknown;
      category?: unknown;
      messageKey: unknown;
      safeArgs?: unknown;
      retryable?: unknown;
    };
    return {
      code: String(structured.code),
      category: typeof structured.category === "string" ? structured.category : "internal",
      messageKey: String(structured.messageKey),
      args: typeof structured.safeArgs === "object" && structured.safeArgs !== null ? structured.safeArgs : {},
      retryable: structured.retryable === true,
    };
  }

  return rpcError("RPC_REQUEST_HANDLER_FAILED", "internal", "error.rpc.requestHandlerFailed", { method });
}
