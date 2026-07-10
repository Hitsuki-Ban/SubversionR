import type { BackendDegradedReason, BackendLifecycleEvent, BackendLifecycleState } from "./backendService";

export const BACKEND_LIFECYCLE_STATE_CONTEXT = "subversionr.backendLifecycleState";
export const BACKEND_DEGRADED_CONTEXT = "subversionr.backendDegraded";
export const BACKEND_DEGRADED_REASON_CONTEXT = "subversionr.backendDegradedReason";

const VERSION_REPORT_COMMAND = "subversionr.diagnostics.versionReport";

export interface BackendLifecycleUiServiceOptions {
  backend: BackendLifecycleSource;
  api: BackendLifecycleUiApi;
}

export interface BackendLifecycleSource {
  getLifecycleState(): BackendLifecycleState;
  onDidChangeLifecycleState(listener: (event: BackendLifecycleEvent) => void): BackendLifecycleSubscription;
}

export interface BackendLifecycleSubscription {
  dispose(): void;
}

export interface BackendLifecycleUiApi {
  createStatusBarItem(): BackendLifecycleStatusItem;
  localize(message: string, ...args: unknown[]): string;
  setContext(key: string, value: unknown): Promise<void> | void;
}

export interface BackendLifecycleStatusItem {
  text?: string;
  tooltip?: unknown;
  command?: unknown;
  accessibilityInformation?: unknown;
  show(): void;
  hide(): void;
  dispose(): void;
}

export class BackendLifecycleUiService {
  private readonly statusItem: BackendLifecycleStatusItem;
  private readonly lifecycleSubscription: BackendLifecycleSubscription;
  private disposed = false;

  public constructor(private readonly options: BackendLifecycleUiServiceOptions) {
    this.statusItem = options.api.createStatusBarItem();
    this.lifecycleSubscription = options.backend.onDidChangeLifecycleState((event) => {
      void this.publishState(this.stateFromEvent(event));
    });
  }

  public refresh(): Promise<void> {
    return this.publishState(this.options.backend.getLifecycleState());
  }

  public dispose(): void {
    this.disposed = true;
    this.lifecycleSubscription.dispose();
    this.statusItem.dispose();
  }

  private stateFromEvent(event: BackendLifecycleEvent): BackendLifecycleState {
    if (event.status === "recovered") {
      return this.options.backend.getLifecycleState();
    }
    return event;
  }

  private async publishState(state: BackendLifecycleState): Promise<void> {
    await Promise.all([
      this.options.api.setContext(BACKEND_LIFECYCLE_STATE_CONTEXT, state.status),
      this.options.api.setContext(BACKEND_DEGRADED_CONTEXT, state.status === "degraded"),
      this.options.api.setContext(
        BACKEND_DEGRADED_REASON_CONTEXT,
        state.status === "degraded" ? state.reason : undefined,
      ),
    ]);
    if (this.disposed) {
      return;
    }
    this.renderState(state);
  }

  private renderState(state: BackendLifecycleState): void {
    if (state.status !== "degraded") {
      this.statusItem.text = undefined;
      this.statusItem.tooltip = undefined;
      this.statusItem.command = undefined;
      this.statusItem.accessibilityInformation = undefined;
      this.statusItem.hide();
      return;
    }

    const actionTitle = this.options.api.localize("Open SubversionR version report");
    const message = this.options.api.localize(
      "SubversionR backend degraded: {0} ({1})",
      degradedReasonLabel(this.options.api.localize, state.reason),
      state.lastErrorCode,
    );
    this.statusItem.text = `$(warning) ${this.options.api.localize("SVN backend")}`;
    this.statusItem.tooltip = `${message}\n${actionTitle}`;
    this.statusItem.command = {
      command: VERSION_REPORT_COMMAND,
      title: actionTitle,
    };
    this.statusItem.accessibilityInformation = {
      label: message,
      role: "status",
    };
    this.statusItem.show();
  }
}

function degradedReasonLabel(
  localize: BackendLifecycleUiApi["localize"],
  reason: BackendDegradedReason,
): string {
  switch (reason) {
    case "startupFailed":
      return localize("backend startup failed");
    case "terminated":
      return localize("backend process terminated");
    case "heartbeatFailed":
      return localize("backend heartbeat failed");
    case "protocolFault":
      return localize("backend protocol fault");
  }
}
