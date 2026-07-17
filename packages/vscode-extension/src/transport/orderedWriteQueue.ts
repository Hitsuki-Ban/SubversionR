import type { Writable } from "node:stream";

interface QueuedWrite {
  frame: string;
  resolve(): void;
  reject(error: Error): void;
}

export class OrderedWriteQueue {
  private readonly queued: QueuedWrite[] = [];
  private active = true;
  private waitingForDrain = false;
  private terminalError: Error | undefined;

  public constructor(
    private readonly writable: Writable,
    private readonly onTerminalError: (error: Error) => void,
  ) {
    this.writable.on("drain", this.handleDrain);
    this.writable.on("error", this.handleError);
    this.writable.on("close", this.handleClose);
  }

  public write(frame: string): Promise<void> {
    if (!this.active) {
      return Promise.reject(this.requireTerminalError());
    }

    return new Promise<void>((resolve, reject) => {
      this.queued.push({ frame, resolve, reject });
      this.flush();
    });
  }

  public dispose(error: Error): void {
    if (!this.active) {
      return;
    }
    this.stop(error);
  }

  private flush(): void {
    while (this.active && !this.waitingForDrain && this.queued.length > 0) {
      const item = this.queued[0];
      let accepted: boolean;
      try {
        accepted = this.writable.write(item.frame, "utf8");
      } catch (error) {
        this.fail(error instanceof Error ? error : new Error(String(error)));
        return;
      }

      if (!this.active) {
        return;
      }
      if (!accepted) {
        this.waitingForDrain = true;
        return;
      }
      this.queued.shift();
      item.resolve();
    }
  }

  private readonly handleDrain = (): void => {
    if (!this.active || !this.waitingForDrain) {
      return;
    }
    this.waitingForDrain = false;
    const written = this.queued.shift();
    written?.resolve();
    this.flush();
  };

  private readonly handleError = (error: Error): void => {
    this.fail(error);
  };

  private readonly handleClose = (): void => {
    this.fail(new Error("JSON-RPC stream closed"));
  };

  private fail(error: Error): void {
    if (!this.active) {
      return;
    }
    this.stop(error);
    this.onTerminalError(error);
  }

  private stop(error: Error): void {
    this.active = false;
    this.terminalError = error;
    this.waitingForDrain = false;
    this.writable.off("drain", this.handleDrain);
    this.writable.off("error", this.handleError);
    this.writable.off("close", this.handleClose);

    const queued = this.queued.splice(0);
    for (const item of queued) {
      item.reject(error);
    }
  }

  private requireTerminalError(): Error {
    if (!this.terminalError) {
      throw new Error("Ordered write queue stopped without a terminal error");
    }
    return this.terminalError;
  }
}
