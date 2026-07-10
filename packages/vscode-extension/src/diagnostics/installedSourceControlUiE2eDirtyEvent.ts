import type { DirtyPathPipeline } from "../status/dirtyPathPipeline";
import type { RawWatcherEvent } from "../status/types";

export interface InstalledSourceControlUiE2eDirtyEventRequest {
  repositoryId: string;
  fsPath: string;
  kind: RawWatcherEvent["kind"];
  timestamp: number;
}

export interface InstalledSourceControlUiE2eDirtyEventReport {
  kind: "subversionr.installedSourceControlUiE2eDirtyEventReport";
  generatedAt: string;
  repositoryId: string;
  event: RawWatcherEvent;
  accepted: boolean;
  assertions: {
    dirtyEventAccepted: boolean;
  };
}

export class InstalledSourceControlUiE2eDirtyEventError extends Error {
  public constructor(
    public readonly code: string,
    public readonly category: "input",
    public readonly messageKey: string,
    public readonly safeArgs: Record<string, unknown> = {},
  ) {
    super(code);
    this.name = "InstalledSourceControlUiE2eDirtyEventError";
  }
}

export function recordInstalledSourceControlUiE2eDirtyEvent(
  rawRequest: unknown,
  deps: {
    generatedAt(): string;
    dirtyPathPipeline: Pick<DirtyPathPipeline, "accept">;
  },
): InstalledSourceControlUiE2eDirtyEventReport {
  const request = parseRequest(rawRequest);
  const event: RawWatcherEvent = {
    fsPath: request.fsPath,
    kind: request.kind,
    timestamp: request.timestamp,
  };
  const accepted = deps.dirtyPathPipeline.accept(request.repositoryId, event);
  return {
    kind: "subversionr.installedSourceControlUiE2eDirtyEventReport",
    generatedAt: deps.generatedAt(),
    repositoryId: request.repositoryId,
    event,
    accepted,
    assertions: {
      dirtyEventAccepted: accepted,
    },
  };
}

function parseRequest(rawRequest: unknown): InstalledSourceControlUiE2eDirtyEventRequest {
  if (!rawRequest || typeof rawRequest !== "object") {
    throw requestError("SUBVERSIONR_INSTALLED_UI_E2E_DIRTY_EVENT_REQUEST_REQUIRED");
  }
  const request = rawRequest as Record<string, unknown>;
  return {
    repositoryId: nonEmptyString(request.repositoryId, "repositoryId"),
    fsPath: nonEmptyString(request.fsPath, "fsPath"),
    kind: rawWatcherEventKind(request.kind, "kind"),
    timestamp: positiveInteger(request.timestamp, "timestamp"),
  };
}

function nonEmptyString(value: unknown, field: string): string {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw invalidRequest(field);
  }
  return value;
}

function positiveInteger(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value <= 0) {
    throw invalidRequest(field);
  }
  return value;
}

function rawWatcherEventKind(value: unknown, field: string): RawWatcherEvent["kind"] {
  if (value === "created" || value === "changed" || value === "deleted") {
    return value;
  }
  throw invalidRequest(field);
}

function invalidRequest(field: string): InstalledSourceControlUiE2eDirtyEventError {
  return requestError("SUBVERSIONR_INSTALLED_UI_E2E_DIRTY_EVENT_REQUEST_INVALID", field);
}

function requestError(code: string, field?: string): InstalledSourceControlUiE2eDirtyEventError {
  return new InstalledSourceControlUiE2eDirtyEventError(
    code,
    "input",
    "error.diagnostics.installedSourceControlUiE2eDirtyEventRequestInvalid",
    field ? { field } : {},
  );
}
