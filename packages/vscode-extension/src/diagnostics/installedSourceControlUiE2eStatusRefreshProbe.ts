import type { StatusDelta } from "../status/statusRefreshRpcClient";
import type {
  StatusRefreshClient,
  StatusRefreshClientOptions,
  StatusRefreshDepth,
  StatusRefreshRequest,
  StatusRefreshTarget,
} from "../status/types";

export interface InstalledSourceControlUiE2eFullReconcileCancellationArmRequest {
  repositoryId: string;
  epoch: number;
  timeoutMs: number;
}

export interface InstalledSourceControlUiE2eFullReconcileCancellationArmReport {
  kind: "subversionr.installedSourceControlUiE2eFullReconcileCancellationArmReport";
  generatedAt: string;
  holdId: string;
  repositoryId: string;
  epoch: number;
  timeoutMs: number;
  target: StatusRefreshTarget;
  armed: true;
}

export interface InstalledSourceControlUiE2eDirtyGenerationCancellationArmRequest {
  repositoryId: string;
  epoch: number;
  timeoutMs: number;
  target: StatusRefreshTarget;
}

export interface InstalledSourceControlUiE2eDirtyGenerationCancellationArmReport {
  kind: "subversionr.installedSourceControlUiE2eDirtyGenerationCancellationArmReport";
  generatedAt: string;
  holdId: string;
  repositoryId: string;
  epoch: number;
  timeoutMs: number;
  target: StatusRefreshTarget;
  armed: true;
}

export interface InstalledSourceControlUiE2eFullReconcileCancellationReportRequest {
  holdId: string;
}

export interface InstalledSourceControlUiE2eDirtyGenerationCancellationReportRequest {
  holdId: string;
}

export interface InstalledSourceControlUiE2eFullReconcileCancellationReport {
  kind: "subversionr.installedSourceControlUiE2eFullReconcileCancellationReport";
  generatedAt: string;
  holdId: string;
  repositoryId: string;
  epoch: number;
  target: StatusRefreshTarget;
  observed: boolean;
  cancellationObserved: boolean;
  refreshStatusSignalProvided: boolean;
  signalAborted: boolean;
  assertions: {
    matchedManualFullReconcile: boolean;
    signalProvided: boolean;
    signalAborted: boolean;
    cancellationObserved: boolean;
  };
}

export interface InstalledSourceControlUiE2eDirtyGenerationCancellationReport {
  kind: "subversionr.installedSourceControlUiE2eDirtyGenerationCancellationReport";
  generatedAt: string;
  holdId: string;
  repositoryId: string;
  epoch: number;
  target: StatusRefreshTarget;
  observed: boolean;
  cancellationObserved: boolean;
  refreshStatusSignalProvided: boolean;
  signalAborted: boolean;
  assertions: {
    matchedDirtyGenerationTarget: boolean;
    signalProvided: boolean;
    signalAborted: boolean;
    cancellationObserved: boolean;
  };
}

export class InstalledSourceControlUiE2eStatusRefreshProbeError extends Error {
  public constructor(
    public readonly code: string,
    public readonly category: "input" | "lifecycle",
    public readonly messageKey: string,
    public readonly safeArgs: Record<string, unknown> = {},
  ) {
    super(code);
    this.name = "InstalledSourceControlUiE2eStatusRefreshProbeError";
  }
}

interface ProbeRuntime {
  generatedAt(): string;
  setTimeout(callback: () => void, ms: number): ReturnType<typeof setTimeout>;
  clearTimeout(timer: ReturnType<typeof setTimeout>): void;
}

interface ActiveHoldBase {
  holdId: string;
  repositoryId: string;
  epoch: number;
  timeoutMs: number;
  target: StatusRefreshTarget;
}

interface ManualFullReconcileHold extends ActiveHoldBase {
  mode: "manualFullReconcile";
}

interface DirtyGenerationCancellationHold extends ActiveHoldBase {
  mode: "dirtyGenerationCancellation";
}

type ActiveHold = ManualFullReconcileHold | DirtyGenerationCancellationHold;

interface ProbeReportFields {
  observed: boolean;
  cancellationObserved: boolean;
  refreshStatusSignalProvided: boolean;
  signalAborted: boolean;
}

const STATUS_REFRESH_DEPTHS: readonly StatusRefreshDepth[] = ["empty", "files", "immediates", "infinity"];

export class InstalledSourceControlUiE2eStatusRefreshProbe implements StatusRefreshClient {
  private activeHold: ActiveHold | undefined;
  private fullReconcileReports = new Map<string, InstalledSourceControlUiE2eFullReconcileCancellationReport>();
  private dirtyGenerationReports = new Map<string, InstalledSourceControlUiE2eDirtyGenerationCancellationReport>();
  private sequence = 0;
  private refreshRequestCount = 0;
  private readonly runtime: ProbeRuntime;

  public constructor(
    private readonly inner: StatusRefreshClient,
    runtime: Partial<ProbeRuntime> = {},
  ) {
    this.runtime = {
      generatedAt: runtime.generatedAt ?? (() => new Date().toISOString()),
      setTimeout: runtime.setTimeout ?? ((callback, ms) => setTimeout(callback, ms)),
      clearTimeout: runtime.clearTimeout ?? ((timer) => clearTimeout(timer)),
    };
  }

  public armNextManualFullReconcile(
    rawRequest: unknown,
  ): InstalledSourceControlUiE2eFullReconcileCancellationArmReport {
    this.requireNoActiveHold(
      "SUBVERSIONR_INSTALLED_UI_E2E_FULL_RECONCILE_HOLD_ALREADY_ARMED",
      "error.diagnostics.installedSourceControlUiE2eFullReconcileHoldAlreadyArmed",
    );
    const request = parseFullReconcileArmRequest(rawRequest);
    const holdId = `manual-full-reconcile-${++this.sequence}`;
    const target = manualFullReconcileTarget();
    this.activeHold = {
      mode: "manualFullReconcile",
      holdId,
      repositoryId: request.repositoryId,
      epoch: request.epoch,
      timeoutMs: request.timeoutMs,
      target,
    };
    return {
      kind: "subversionr.installedSourceControlUiE2eFullReconcileCancellationArmReport",
      generatedAt: this.runtime.generatedAt(),
      holdId,
      repositoryId: request.repositoryId,
      epoch: request.epoch,
      timeoutMs: request.timeoutMs,
      target,
      armed: true,
    };
  }

  public armNextDirtyGenerationCancellation(
    rawRequest: unknown,
  ): InstalledSourceControlUiE2eDirtyGenerationCancellationArmReport {
    this.requireNoActiveHold(
      "SUBVERSIONR_INSTALLED_UI_E2E_DIRTY_GENERATION_HOLD_ALREADY_ARMED",
      "error.diagnostics.installedSourceControlUiE2eDirtyGenerationHoldAlreadyArmed",
    );
    const request = parseDirtyGenerationArmRequest(rawRequest);
    const holdId = `dirty-generation-${++this.sequence}`;
    this.activeHold = {
      mode: "dirtyGenerationCancellation",
      holdId,
      repositoryId: request.repositoryId,
      epoch: request.epoch,
      timeoutMs: request.timeoutMs,
      target: cloneRefreshTarget(request.target),
    };
    return {
      kind: "subversionr.installedSourceControlUiE2eDirtyGenerationCancellationArmReport",
      generatedAt: this.runtime.generatedAt(),
      holdId,
      repositoryId: request.repositoryId,
      epoch: request.epoch,
      timeoutMs: request.timeoutMs,
      target: cloneRefreshTarget(request.target),
      armed: true,
    };
  }

  public report(rawRequest: unknown): InstalledSourceControlUiE2eFullReconcileCancellationReport {
    const request = parseFullReconcileReportRequest(rawRequest);
    const report = this.fullReconcileReports.get(request.holdId);
    if (!report) {
      throw new InstalledSourceControlUiE2eStatusRefreshProbeError(
        "SUBVERSIONR_INSTALLED_UI_E2E_FULL_RECONCILE_HOLD_REPORT_MISSING",
        "lifecycle",
        "error.diagnostics.installedSourceControlUiE2eFullReconcileHoldReportMissing",
        { holdId: request.holdId },
      );
    }
    return report;
  }

  public dirtyGenerationCancellationReport(
    rawRequest: unknown,
  ): InstalledSourceControlUiE2eDirtyGenerationCancellationReport {
    const request = parseDirtyGenerationReportRequest(rawRequest);
    const report = this.dirtyGenerationReports.get(request.holdId);
    if (!report) {
      throw new InstalledSourceControlUiE2eStatusRefreshProbeError(
        "SUBVERSIONR_INSTALLED_UI_E2E_DIRTY_GENERATION_HOLD_REPORT_MISSING",
        "lifecycle",
        "error.diagnostics.installedSourceControlUiE2eDirtyGenerationHoldReportMissing",
        { holdId: request.holdId },
      );
    }
    return report;
  }

  public async refreshStatus(
    request: StatusRefreshRequest,
    options?: StatusRefreshClientOptions,
  ): Promise<StatusDelta> {
    this.refreshRequestCount += 1;
    const hold = this.activeHold;
    if (!hold || !matchesHold(hold, request)) {
      return await this.inner.refreshStatus(request, options);
    }

    this.activeHold = undefined;
    const signal = options?.signal;
    if (!signal) {
      this.recordReport(hold, {
        observed: true,
        cancellationObserved: false,
        refreshStatusSignalProvided: false,
        signalAborted: false,
      });
      throw new InstalledSourceControlUiE2eStatusRefreshProbeError(
        signalMissingCode(hold),
        "lifecycle",
        signalMissingMessageKey(hold),
        { holdId: hold.holdId },
      );
    }

    if (hold.mode === "dirtyGenerationCancellation") {
      this.recordDirtyGenerationReport(hold, {
        observed: true,
        cancellationObserved: false,
        refreshStatusSignalProvided: true,
        signalAborted: signal.aborted,
      });
    }

    return await new Promise<StatusDelta>((_resolve, reject) => {
      let completed = false;
      let timeout: ReturnType<typeof setTimeout> | undefined;
      const finish = (report: ProbeReportFields, error: Error): void => {
        if (completed) {
          return;
        }
        completed = true;
        if (timeout) {
          this.runtime.clearTimeout(timeout);
        }
        signal.removeEventListener("abort", cancel);
        this.recordReport(hold, report);
        reject(error);
      };
      const cancel = (): void => {
        finish(
          {
            observed: true,
            cancellationObserved: true,
            refreshStatusSignalProvided: true,
            signalAborted: signal.aborted,
          },
          new Error(cancelledErrorCode(hold)),
        );
      };
      timeout = this.runtime.setTimeout(() => {
        finish(
          {
            observed: true,
            cancellationObserved: false,
            refreshStatusSignalProvided: true,
            signalAborted: signal.aborted,
          },
          new Error(cancelTimeoutErrorCode(hold)),
        );
      }, hold.timeoutMs);

      if (signal.aborted) {
        cancel();
      } else {
        signal.addEventListener("abort", cancel, { once: true });
      }
    });
  }

  public requestCount(): number {
    return this.refreshRequestCount;
  }

  private requireNoActiveHold(code: string, messageKey: string): void {
    if (this.activeHold) {
      throw new InstalledSourceControlUiE2eStatusRefreshProbeError(
        code,
        "lifecycle",
        messageKey,
        { holdId: this.activeHold.holdId },
      );
    }
  }

  private recordReport(hold: ActiveHold, report: ProbeReportFields): void {
    if (hold.mode === "manualFullReconcile") {
      this.recordFullReconcileReport(hold, report);
      return;
    }
    this.recordDirtyGenerationReport(hold, report);
  }

  private recordFullReconcileReport(hold: ManualFullReconcileHold, report: ProbeReportFields): void {
    this.fullReconcileReports.set(hold.holdId, {
      kind: "subversionr.installedSourceControlUiE2eFullReconcileCancellationReport",
      generatedAt: this.runtime.generatedAt(),
      holdId: hold.holdId,
      repositoryId: hold.repositoryId,
      epoch: hold.epoch,
      target: hold.target,
      ...report,
      assertions: {
        matchedManualFullReconcile: report.observed,
        signalProvided: report.refreshStatusSignalProvided,
        signalAborted: report.signalAborted,
        cancellationObserved: report.cancellationObserved,
      },
    });
  }

  private recordDirtyGenerationReport(
    hold: DirtyGenerationCancellationHold,
    report: ProbeReportFields,
  ): void {
    this.dirtyGenerationReports.set(hold.holdId, {
      kind: "subversionr.installedSourceControlUiE2eDirtyGenerationCancellationReport",
      generatedAt: this.runtime.generatedAt(),
      holdId: hold.holdId,
      repositoryId: hold.repositoryId,
      epoch: hold.epoch,
      target: hold.target,
      ...report,
      assertions: {
        matchedDirtyGenerationTarget: report.observed,
        signalProvided: report.refreshStatusSignalProvided,
        signalAborted: report.signalAborted,
        cancellationObserved: report.cancellationObserved,
      },
    });
  }
}

function parseFullReconcileArmRequest(rawRequest: unknown): InstalledSourceControlUiE2eFullReconcileCancellationArmRequest {
  if (!rawRequest || typeof rawRequest !== "object") {
    throw fullReconcileRequestError("SUBVERSIONR_INSTALLED_UI_E2E_FULL_RECONCILE_HOLD_REQUEST_REQUIRED");
  }
  const request = rawRequest as Record<string, unknown>;
  const repositoryId = nonEmptyString(request.repositoryId, "repositoryId", fullReconcileInvalidRequest);
  const epoch = positiveInteger(request.epoch, "epoch", fullReconcileInvalidRequest);
  const timeoutMs = positiveInteger(request.timeoutMs, "timeoutMs", fullReconcileInvalidRequest);
  return { repositoryId, epoch, timeoutMs };
}

function parseDirtyGenerationArmRequest(rawRequest: unknown): InstalledSourceControlUiE2eDirtyGenerationCancellationArmRequest {
  if (!rawRequest || typeof rawRequest !== "object") {
    throw dirtyGenerationRequestError("SUBVERSIONR_INSTALLED_UI_E2E_DIRTY_GENERATION_HOLD_REQUEST_REQUIRED");
  }
  const request = rawRequest as Record<string, unknown>;
  const repositoryId = nonEmptyString(request.repositoryId, "repositoryId", dirtyGenerationInvalidRequest);
  const epoch = positiveInteger(request.epoch, "epoch", dirtyGenerationInvalidRequest);
  const timeoutMs = positiveInteger(request.timeoutMs, "timeoutMs", dirtyGenerationInvalidRequest);
  const target = parseRefreshTarget(request.target, "target");
  return { repositoryId, epoch, timeoutMs, target };
}

function parseFullReconcileReportRequest(rawRequest: unknown): InstalledSourceControlUiE2eFullReconcileCancellationReportRequest {
  if (!rawRequest || typeof rawRequest !== "object") {
    throw fullReconcileRequestError("SUBVERSIONR_INSTALLED_UI_E2E_FULL_RECONCILE_HOLD_REPORT_REQUEST_REQUIRED");
  }
  const request = rawRequest as Record<string, unknown>;
  return { holdId: nonEmptyString(request.holdId, "holdId", fullReconcileInvalidRequest) };
}

function parseDirtyGenerationReportRequest(rawRequest: unknown): InstalledSourceControlUiE2eDirtyGenerationCancellationReportRequest {
  if (!rawRequest || typeof rawRequest !== "object") {
    throw dirtyGenerationRequestError("SUBVERSIONR_INSTALLED_UI_E2E_DIRTY_GENERATION_HOLD_REPORT_REQUEST_REQUIRED");
  }
  const request = rawRequest as Record<string, unknown>;
  return { holdId: nonEmptyString(request.holdId, "holdId", dirtyGenerationInvalidRequest) };
}

function parseRefreshTarget(value: unknown, field: string): StatusRefreshTarget {
  if (!value || typeof value !== "object") {
    throw dirtyGenerationInvalidRequest(field);
  }
  const target = value as Record<string, unknown>;
  return {
    path: nonEmptyString(target.path, `${field}.path`, dirtyGenerationInvalidRequest),
    depth: statusRefreshDepth(target.depth, `${field}.depth`),
    reason: nonEmptyString(target.reason, `${field}.reason`, dirtyGenerationInvalidRequest),
  };
}

function nonEmptyString(
  value: unknown,
  field: string,
  error: (field: string) => InstalledSourceControlUiE2eStatusRefreshProbeError,
): string {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw error(field);
  }
  return value;
}

function positiveInteger(
  value: unknown,
  field: string,
  error: (field: string) => InstalledSourceControlUiE2eStatusRefreshProbeError,
): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value <= 0) {
    throw error(field);
  }
  return value;
}

function statusRefreshDepth(value: unknown, field: string): StatusRefreshDepth {
  if (typeof value !== "string" || !STATUS_REFRESH_DEPTHS.includes(value as StatusRefreshDepth)) {
    throw dirtyGenerationInvalidRequest(field);
  }
  return value as StatusRefreshDepth;
}

function fullReconcileInvalidRequest(field: string): InstalledSourceControlUiE2eStatusRefreshProbeError {
  return fullReconcileRequestError("SUBVERSIONR_INSTALLED_UI_E2E_FULL_RECONCILE_HOLD_REQUEST_INVALID", field);
}

function dirtyGenerationInvalidRequest(field: string): InstalledSourceControlUiE2eStatusRefreshProbeError {
  return dirtyGenerationRequestError("SUBVERSIONR_INSTALLED_UI_E2E_DIRTY_GENERATION_HOLD_REQUEST_INVALID", field);
}

function fullReconcileRequestError(
  code: string,
  field?: string,
): InstalledSourceControlUiE2eStatusRefreshProbeError {
  return new InstalledSourceControlUiE2eStatusRefreshProbeError(
    code,
    "input",
    "error.diagnostics.installedSourceControlUiE2eFullReconcileHoldRequestInvalid",
    field ? { field } : {},
  );
}

function dirtyGenerationRequestError(
  code: string,
  field?: string,
): InstalledSourceControlUiE2eStatusRefreshProbeError {
  return new InstalledSourceControlUiE2eStatusRefreshProbeError(
    code,
    "input",
    "error.diagnostics.installedSourceControlUiE2eDirtyGenerationHoldRequestInvalid",
    field ? { field } : {},
  );
}

function matchesHold(hold: ActiveHold, request: StatusRefreshRequest): boolean {
  return request.repositoryId === hold.repositoryId &&
    request.epoch === hold.epoch &&
    request.targets.length === 1 &&
    request.targets[0]?.path === hold.target.path &&
    request.targets[0]?.depth === hold.target.depth &&
    request.targets[0]?.reason === hold.target.reason;
}

function manualFullReconcileTarget(): StatusRefreshTarget {
  return { path: ".", depth: "infinity", reason: "manualFullReconcile" };
}

function cloneRefreshTarget(target: StatusRefreshTarget): StatusRefreshTarget {
  return {
    path: target.path,
    depth: target.depth,
    reason: target.reason,
  };
}

function signalMissingCode(hold: ActiveHold): string {
  return hold.mode === "manualFullReconcile"
    ? "SUBVERSIONR_INSTALLED_UI_E2E_FULL_RECONCILE_SIGNAL_MISSING"
    : "SUBVERSIONR_INSTALLED_UI_E2E_DIRTY_GENERATION_SIGNAL_MISSING";
}

function signalMissingMessageKey(hold: ActiveHold): string {
  return hold.mode === "manualFullReconcile"
    ? "error.diagnostics.installedSourceControlUiE2eFullReconcileSignalMissing"
    : "error.diagnostics.installedSourceControlUiE2eDirtyGenerationSignalMissing";
}

function cancelledErrorCode(hold: ActiveHold): string {
  return hold.mode === "manualFullReconcile"
    ? "SUBVERSIONR_INSTALLED_UI_E2E_MANUAL_FULL_RECONCILE_CANCELLED"
    : "SUBVERSIONR_INSTALLED_UI_E2E_DIRTY_GENERATION_CANCELLED";
}

function cancelTimeoutErrorCode(hold: ActiveHold): string {
  return hold.mode === "manualFullReconcile"
    ? "SUBVERSIONR_INSTALLED_UI_E2E_MANUAL_FULL_RECONCILE_CANCEL_TIMEOUT"
    : "SUBVERSIONR_INSTALLED_UI_E2E_DIRTY_GENERATION_CANCEL_TIMEOUT";
}
