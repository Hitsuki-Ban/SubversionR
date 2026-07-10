import { BackendLaunchError, type BackendConnection, type InitializeResult } from "../backend/backendProcess";
import type { BackendLifecycleState } from "../backend/backendService";
import type { RepositoryOperationJournal } from "../operations/repositoryOperationJournal";
import type { WatcherOverflowDiagnostics } from "../status/watcherOverflowDiagnostics";
import { redactDiagnosticValue } from "./diagnosticsRedaction";

export interface DiagnosticsBackendService {
  initialize(): Promise<BackendConnection>;
  getLifecycleState(): BackendLifecycleState;
}

export interface DiagnosticsContext {
  generatedAt: string;
  extension: {
    name: string;
    version: string;
  };
  vscode: {
    version: string;
    appName: string;
    uiKind: string;
    remoteName: string | undefined;
  };
  process: {
    platform: NodeJS.Platform | string;
    arch: string;
    nodeVersion: string;
  };
  workspace: {
    trusted: boolean;
    workspaceFolders: readonly string[];
  };
}

export interface DiagnosticsVersionReportDependencies {
  context: DiagnosticsContext;
  backendService: DiagnosticsBackendService;
}

export interface DiagnosticsBundleDependencies extends DiagnosticsVersionReportDependencies {
  operationJournal: Pick<RepositoryOperationJournal, "diagnosticsSnapshot">;
  watcherOverflowDiagnostics: Pick<WatcherOverflowDiagnostics, "diagnosticsSnapshot">;
}

export async function collectVersionReport(deps: DiagnosticsVersionReportDependencies): Promise<Record<string, unknown>> {
  const backend = {
    ...(await backendVersionReport(deps.backendService)),
    lifecycle: deps.backendService.getLifecycleState(),
  };
  return redactReport({
    kind: "subversionr.versionReport",
    generatedAt: deps.context.generatedAt,
    extension: deps.context.extension,
    vscode: deps.context.vscode,
    process: deps.context.process,
    workspace: {
      trusted: deps.context.workspace.trusted,
    },
    backend,
  });
}

export async function collectDiagnosticsBundle(deps: DiagnosticsBundleDependencies): Promise<Record<string, unknown>> {
  const versionReport = await collectVersionReport(deps);
  const daemonDiagnostics = await backendDiagnostics(deps.backendService);
  const operationJournal = deps.operationJournal.diagnosticsSnapshot();
  const watcherOverflowDiagnostics = deps.watcherOverflowDiagnostics.diagnosticsSnapshot();
  const report: Record<string, unknown> = {
    kind: "subversionr.diagnosticsBundle",
    generatedAt: deps.context.generatedAt,
    redaction: {
      mode: "default",
      paths: "redacted",
      urls: "redacted",
      secrets: "redacted",
      repositoryLogs: "omitted",
      sourceContent: "omitted",
    },
    extension: versionReport.extension,
    vscode: versionReport.vscode,
    process: versionReport.process,
    workspace: {
      trusted: deps.context.workspace.trusted,
      folderCount: deps.context.workspace.workspaceFolders.length,
    },
    backend: versionReport.backend,
    settings: {
      backend: {
        source: "packaged",
      },
    },
    operationJournal: {
      entries: operationJournal.entries,
      recordingFailures: operationJournal.recordingFailures,
      omittedFields: ["paths", "urls", "repositoryLogMessages", "sourceContent", "credentials"],
    },
    metrics: {
      queue: {},
      watcher: watcherOverflowDiagnostics,
      cache: {},
    },
    errorChain: daemonDiagnostics.error === undefined ? [] : [daemonDiagnostics.error],
  };
  if (daemonDiagnostics.repositorySummary !== undefined) {
    report.repositorySummary = daemonDiagnostics.repositorySummary;
  }
  if (daemonDiagnostics.backendStderr !== undefined) {
    report.backendStderr = daemonDiagnostics.backendStderr;
  }
  return redactReport(report);
}

async function backendVersionReport(backendService: DiagnosticsBackendService): Promise<Record<string, unknown>> {
  try {
    const connection = await backendService.initialize();
    return initializedBackend(connection.initializeResult);
  } catch (error) {
    return unavailableBackend(error);
  }
}

async function backendDiagnostics(backendService: DiagnosticsBackendService): Promise<Record<string, unknown>> {
  try {
    const connection = await backendService.initialize();
    const result = await connection.sendRequest<Record<string, unknown>>("diagnostics/get", {});
    return result;
  } catch (error) {
    return {
      error: diagnosticsRpcFailure(error),
    };
  }
}

function initializedBackend(result: InitializeResult): Record<string, unknown> {
  return {
    status: "initialized",
    backendVersion: result.backendVersion,
    bridgeVersion: result.bridgeVersion,
    libsvnVersion: result.libsvnVersion,
    protocol: result.protocol,
    platform: result.platform,
    cacheSchema: result.cacheSchema,
    capabilities: result.capabilities,
  };
}

function unavailableBackend(error: unknown): Record<string, unknown> {
  if (error instanceof BackendLaunchError) {
    return {
      status: "unavailable",
      error: {
        code: error.code,
        category: error.category,
        messageKey: error.messageKey,
        safeArgs: error.safeArgs,
      },
    };
  }
  return {
    status: "unavailable",
    error: {
      code: "SUBVERSIONR_BACKEND_DIAGNOSTICS_UNAVAILABLE",
      category: "process",
      messageKey: "error.diagnostics.backendUnavailable",
      safeArgs: {},
    },
  };
}

function diagnosticsRpcFailure(error: unknown): Record<string, unknown> {
  const errorReport = unavailableBackend(error);
  const nestedError = errorReport.error;
  if (isRecord(nestedError)) {
    return {
      ...nestedError,
      code: "SUBVERSIONR_BACKEND_DIAGNOSTICS_RPC_FAILED",
    };
  }
  return {
    code: "SUBVERSIONR_BACKEND_DIAGNOSTICS_RPC_FAILED",
    category: "protocol",
    messageKey: "error.diagnostics.rpcFailed",
    safeArgs: { message: error instanceof Error ? error.message : String(error) },
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function redactReport(report: Record<string, unknown>): Record<string, unknown> {
  return redactDiagnosticValue(report) as Record<string, unknown>;
}
