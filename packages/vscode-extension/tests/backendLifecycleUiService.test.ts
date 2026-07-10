import { describe, expect, it, vi } from "vitest";
import type { BackendLifecycleEvent, BackendLifecycleState } from "../src/backend/backendService";
import {
  BACKEND_DEGRADED_CONTEXT,
  BACKEND_DEGRADED_REASON_CONTEXT,
  BACKEND_LIFECYCLE_STATE_CONTEXT,
  BackendLifecycleUiService,
} from "../src/backend/backendLifecycleUiService";

describe("BackendLifecycleUiService", () => {
  it("publishes ready lifecycle context and hides the degraded status item", async () => {
    const statusItem = fakeStatusItem();
    const api = fakeApi(statusItem);
    const source = new FakeBackendLifecycleSource({ status: "ready", since: 10 });
    const service = new BackendLifecycleUiService({ backend: source, api });

    await service.refresh();

    expect(api.setContext).toHaveBeenCalledWith(BACKEND_LIFECYCLE_STATE_CONTEXT, "ready");
    expect(api.setContext).toHaveBeenCalledWith(BACKEND_DEGRADED_CONTEXT, false);
    expect(api.setContext).toHaveBeenCalledWith(BACKEND_DEGRADED_REASON_CONTEXT, undefined);
    expect(statusItem.hide).toHaveBeenCalledTimes(1);
    expect(statusItem.show).not.toHaveBeenCalled();
  });

  it("shows degraded context and a localized status bar action", async () => {
    const statusItem = fakeStatusItem();
    const api = fakeApi(statusItem);
    const source = new FakeBackendLifecycleSource({ status: "idle" });
    const service = new BackendLifecycleUiService({ backend: source, api });

    source.emit({
      status: "degraded",
      reason: "heartbeatFailed",
      since: 20,
      consecutiveFailures: 2,
      restartAfter: 40,
      lastErrorCode: "SUBVERSIONR_BACKEND_HEARTBEAT_TIMEOUT",
    });
    await flushMicrotasks();

    expect(api.setContext).toHaveBeenCalledWith(BACKEND_LIFECYCLE_STATE_CONTEXT, "degraded");
    expect(api.setContext).toHaveBeenCalledWith(BACKEND_DEGRADED_CONTEXT, true);
    expect(api.setContext).toHaveBeenCalledWith(BACKEND_DEGRADED_REASON_CONTEXT, "heartbeatFailed");
    expect(statusItem.text).toBe("$(warning) l10n:SVN backend");
    expect(statusItem.tooltip).toBe(
      "l10n:SubversionR backend degraded: l10n:backend heartbeat failed (SUBVERSIONR_BACKEND_HEARTBEAT_TIMEOUT)\n" +
        "l10n:Open SubversionR version report",
    );
    expect(statusItem.command).toEqual({
      command: "subversionr.diagnostics.versionReport",
      title: "l10n:Open SubversionR version report",
    });
    expect(statusItem.accessibilityInformation).toEqual({
      label:
        "l10n:SubversionR backend degraded: l10n:backend heartbeat failed (SUBVERSIONR_BACKEND_HEARTBEAT_TIMEOUT)",
      role: "status",
    });
    expect(statusItem.show).toHaveBeenCalledTimes(1);
  });

  it("labels daemon protocol fault degradation distinctly", async () => {
    const statusItem = fakeStatusItem();
    const api = fakeApi(statusItem);
    const source = new FakeBackendLifecycleSource({ status: "idle" });
    const service = new BackendLifecycleUiService({ backend: source, api });

    source.emit({
      status: "degraded",
      reason: "protocolFault",
      since: 25,
      consecutiveFailures: 1,
      restartAfter: 75,
      lastErrorCode: "SUBVERSIONR_STATUS_STALE_NOTIFICATION_INVALID",
    });
    await flushMicrotasks();

    expect(api.setContext).toHaveBeenCalledWith(BACKEND_DEGRADED_REASON_CONTEXT, "protocolFault");
    expect(statusItem.tooltip).toBe(
      "l10n:SubversionR backend degraded: l10n:backend protocol fault (SUBVERSIONR_STATUS_STALE_NOTIFICATION_INVALID)\n" +
        "l10n:Open SubversionR version report",
    );
    expect(statusItem.accessibilityInformation).toEqual({
      label:
        "l10n:SubversionR backend degraded: l10n:backend protocol fault (SUBVERSIONR_STATUS_STALE_NOTIFICATION_INVALID)",
      role: "status",
    });
  });

  it("clears degraded UI when the backend recovers", async () => {
    const statusItem = fakeStatusItem();
    const api = fakeApi(statusItem);
    const source = new FakeBackendLifecycleSource({
      status: "degraded",
      reason: "startupFailed",
      since: 20,
      consecutiveFailures: 1,
      restartAfter: 30,
      lastErrorCode: "SUBVERSIONR_BACKEND_STARTUP_FAILED",
    });
    const service = new BackendLifecycleUiService({ backend: source, api });
    await service.refresh();
    vi.clearAllMocks();

    source.emit({
      status: "recovered",
      since: 50,
      recoveredFrom: "startupFailed",
      consecutiveFailures: 1,
    });
    await flushMicrotasks();

    expect(api.setContext).toHaveBeenCalledWith(BACKEND_LIFECYCLE_STATE_CONTEXT, "ready");
    expect(api.setContext).toHaveBeenCalledWith(BACKEND_DEGRADED_CONTEXT, false);
    expect(api.setContext).toHaveBeenCalledWith(BACKEND_DEGRADED_REASON_CONTEXT, undefined);
    expect(statusItem.hide).toHaveBeenCalledTimes(1);
  });

  it("disposes the lifecycle listener and status item", () => {
    const statusItem = fakeStatusItem();
    const source = new FakeBackendLifecycleSource({ status: "idle" });
    const service = new BackendLifecycleUiService({ backend: source, api: fakeApi(statusItem) });

    service.dispose();
    source.emit({
      status: "degraded",
      reason: "terminated",
      since: 20,
      consecutiveFailures: 1,
      restartAfter: 30,
      lastErrorCode: "SUBVERSIONR_BACKEND_TERMINATED",
    });

    expect(source.listenerCount()).toBe(0);
    expect(statusItem.dispose).toHaveBeenCalledTimes(1);
    expect(statusItem.show).not.toHaveBeenCalled();
  });
});

interface FakeApi {
  createStatusBarItem: ReturnType<typeof vi.fn<() => FakeStatusItem>>;
  localize: ReturnType<typeof vi.fn<(message: string, ...args: unknown[]) => string>>;
  setContext: ReturnType<typeof vi.fn<(key: string, value: unknown) => Promise<void>>>;
}

interface FakeStatusItem {
  text?: string;
  tooltip?: unknown;
  command?: unknown;
  accessibilityInformation?: unknown;
  show: ReturnType<typeof vi.fn<() => void>>;
  hide: ReturnType<typeof vi.fn<() => void>>;
  dispose: ReturnType<typeof vi.fn<() => void>>;
}

class FakeBackendLifecycleSource {
  private readonly listeners = new Set<(event: BackendLifecycleEvent) => void>();

  public constructor(private state: BackendLifecycleState) {}

  public getLifecycleState(): BackendLifecycleState {
    return this.state;
  }

  public onDidChangeLifecycleState(listener: (event: BackendLifecycleEvent) => void): { dispose(): void } {
    this.listeners.add(listener);
    return {
      dispose: () => {
        this.listeners.delete(listener);
      },
    };
  }

  public emit(event: BackendLifecycleEvent): void {
    if (event.status === "recovered") {
      this.state = { status: "ready", since: event.since };
    } else {
      this.state = event;
    }
    for (const listener of this.listeners) {
      listener(event);
    }
  }

  public listenerCount(): number {
    return this.listeners.size;
  }
}

function fakeApi(statusItem: FakeStatusItem): FakeApi {
  return {
    createStatusBarItem: vi.fn(() => statusItem),
    localize: vi.fn((message, ...args) => `l10n:${format(message, args)}`),
    setContext: vi.fn(async () => undefined),
  };
}

function fakeStatusItem(): FakeStatusItem {
  return {
    show: vi.fn(),
    hide: vi.fn(),
    dispose: vi.fn(),
  };
}

function format(message: string, args: unknown[]): string {
  return args.reduce<string>((value, arg, index) => value.replace(`{${index}}`, String(arg)), message);
}

async function flushMicrotasks(): Promise<void> {
  await Promise.resolve();
  await Promise.resolve();
}
