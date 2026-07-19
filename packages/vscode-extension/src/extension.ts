import { randomUUID } from "node:crypto";
import { statSync } from "node:fs";
import { appendFile } from "node:fs/promises";
import * as nodePath from "node:path";
import { performance } from "node:perf_hooks";
import * as vscode from "vscode";
import { backendLaunchConfigFromPackageResources } from "./backend/backendConfiguration";
import { BackendLifecycleUiService } from "./backend/backendLifecycleUiService";
import { resolvePackagedBackendResources } from "./backend/backendPackageResolver";
import { BackendLaunchError, startBackendProcess } from "./backend/backendProcess";
import { BackendService, systemBackendLifecycleClock } from "./backend/backendService";
import { createInitializeCommandHandler } from "./backend/initializeCommandHandler";
import { createAuthRequestHandler } from "./auth/authRequestHandler";
import {
  createCertificateTrustController,
  type CertificateTrustDecision,
  type CertificateTrustRequest,
} from "./auth/certificateTrustController";
import {
  createCredentialController,
  discardCredentialOperationAfterBackendRequest,
  type CredentialController,
  type CredentialRequest,
  type CredentialPersistenceIntent,
} from "./auth/credentialController";
import { CacheCommandController } from "./cache/cacheCommandController";
import {
  CacheLifecycleService,
  type CacheClearStatus,
  type CacheStorageRoot,
  type CacheUri,
} from "./cache/cacheLifecycleService";
import { BaseContentDocumentProvider } from "./content/baseContentDocumentProvider";
import { BASE_CONTENT_URI_SCHEME } from "./content/baseContentUri";
import { BackendContentClient } from "./content/backendContentClient";
import { ActiveEditorContextService } from "./editor/activeEditorContextService";
import { HeadContentDocumentProvider } from "./content/headContentDocumentProvider";
import { HEAD_CONTENT_URI_SCHEME } from "./content/headContentUri";
import { RevisionContentDocumentProvider } from "./content/revisionContentDocumentProvider";
import { REVISION_CONTENT_URI_SCHEME } from "./content/revisionContentUri";
import { DiagnosticsCommandController } from "./diagnostics/diagnosticsCommandController";
import {
  DIAGNOSTICS_DOCUMENT_URI_SCHEME,
  DiagnosticsReadonlyDocumentProvider,
} from "./diagnostics/diagnosticsDocumentProvider";
import {
  collectDiagnosticsBundle,
  collectVersionReport,
  type DiagnosticsContext,
} from "./diagnostics/diagnosticsReportService";
import { collectInstalledRedactionReport } from "./diagnostics/installedRedactionReport";
import { collectInstalledCredentialLeaseReport } from "./diagnostics/installedCredentialLeaseReport";
import { collectInstalledRemoteWorkerReport } from "./diagnostics/installedRemoteWorkerReport";
import {
  collectInstalledSvnAnonymousReport,
  type InstalledSvnAnonymousAuthActivity,
} from "./diagnostics/installedSvnAnonymousReport";
import {
  collectInstalledSvnAnonymousStressCheckout,
  createInstalledSvnAnonymousStressSessionSha256,
} from "./diagnostics/installedSvnAnonymousStressCheckout";
import { collectInstalledSvnAnonymousNegativeReport } from "./diagnostics/installedSvnAnonymousNegativeReport";
import { collectInstalledSvnAnonymousAuthzDeniedReport } from "./diagnostics/installedSvnAnonymousAuthzDeniedReport";
import { collectInstalledSvnAnonymousStalledReadReport } from "./diagnostics/installedSvnAnonymousStalledReadReport";
import { InstalledSvnAnonymousLocalEventZeroNetworkObserver } from "./diagnostics/installedSvnAnonymousLocalEventZeroNetwork";
import { collectInstalledRepositoryHistoryReport } from "./diagnostics/installedRepositoryHistoryReport";
import { OperationDiagnostics } from "./diagnostics/operationDiagnostics";
import { collectInstalledCoreWorkflowReport as collectInstalledCoreWorkflowEvidence } from "./diagnostics/installedCoreWorkflowReport";
import {
  collectInstalledSourceControlSurfaceReport as collectInstalledSourceControlSurfaceEvidence,
  collectInstalledSourceControlUiE2eCurrentSurfaceReport,
  collectInstalledSourceControlUiE2eLazyExternalProviderReport,
  collectInstalledSourceControlUiE2eCloseReport,
  collectInstalledSourceControlUiE2eFreshnessReport,
  collectInstalledSourceControlUiE2eOpenReport,
} from "./diagnostics/installedSourceControlSurfaceReport";
import { InstalledSourceControlUiE2eStatusRefreshProbe } from "./diagnostics/installedSourceControlUiE2eStatusRefreshProbe";
import { recordInstalledSourceControlUiE2eDirtyEvent } from "./diagnostics/installedSourceControlUiE2eDirtyEvent";
import { collectInstalledRepositoryLifecycleReport } from "./diagnostics/installedRepositoryLifecycleReport";
import { BackendHistoryClient } from "./history/backendHistoryClient";
import {
  copyHistoryCommitMessage,
  copyHistoryRevisionNumber,
} from "./history/historyCopyCommand";
import {
  BLAME_DOCUMENT_URI_SCHEME,
  HistoryBlameDocumentProvider,
  createBlameDocumentUriComponents,
} from "./history/historyBlameDocument";
import { historyCompareRevisionUriComponents } from "./history/historyCompareRevisionCommand";
import { historyOpenRevisionUriComponents } from "./history/historyOpenRevisionCommand";
import { searchLoadedHistory } from "./history/historySearchCommand";
import {
  HistoryRevisionDetailsDocumentProvider,
  HistoryRevisionDetailsDocumentStore,
  REVISION_DETAILS_URI_SCHEME,
} from "./history/historyRevisionDetailsDocument";
import { readHistorySettings } from "./history/historySettings";
import { HistoryTreeDataProvider } from "./history/historyTreeDataProvider";
import { HistoryTreeViewController } from "./history/historyTreeViewController";
import { LineHistoryCommandController } from "./history/lineHistoryCommandController";
import { CurrentLineBlameHoverProvider } from "./lens/currentLineBlameHoverProvider";
import { CurrentLineBlameStatusBarService } from "./lens/currentLineBlameStatusBarService";
import { FileHeaderCodeLensProvider } from "./lens/fileHeaderCodeLensProvider";
import { readLensSettings } from "./lens/lensSettings";
import { SymbolHistoryCodeLensProvider } from "./lens/symbolHistoryCodeLensProvider";
import { BackendOperationClient } from "./operations/backendOperationClient";
import type { ResolveOperationChoice } from "./operations/operationRunRpcClient";
import { RepositoryOperationJournal } from "./operations/repositoryOperationJournal";
import { RepositoryOperationScheduler } from "./operations/repositoryOperationScheduler";
import { BackendPropertiesClient } from "./properties/backendPropertiesClient";
import type { PropertyEntry } from "./properties/propertiesListRpcClient";
import { commitAllRepositoryIdArgument } from "./repository/commitAllCommandArgument";
import {
  repositoryHistoryCommandArgument,
  repositoryHistoryCommandTarget,
  type RepositoryHistoryCommandTarget,
} from "./repository/repositoryHistoryCommandTarget";
import { BackendRepositoryCheckoutClient } from "./repository/backendRepositoryCheckoutClient";
import { suggestedCheckoutTargetPath } from "./repository/checkoutTargetSuggestion";
import { validateCheckoutUrl, type CheckoutUrlValidationResult } from "./repository/checkoutUrlValidation";
import { RepositoryCommitMessageHistory } from "./repository/repositoryCommitMessageHistory";
import {
  RepositoryCommandController,
  type RepositoryBranchCreateOptions,
  type RepositoryCheckoutOptions,
  type RepositoryCleanupOptions,
  type RepositoryCommandCancellationToken,
  type RepositoryLockOptions,
  type RepositoryMergeRangeOptions,
  type RepositoryPropertySetOptions,
  type RepositoryRelocateOptions,
  type RepositoryReviewCommitTarget,
  type RepositorySwitchOptions,
  type RepositoryUnlockOptions,
  type RepositoryUpdateOptions,
} from "./repository/repositoryCommandController";
import {
  mergeAncestryQuickPickItems,
  mergeForceDeleteQuickPickItems,
  mergeIgnoreMergeinfoQuickPickItems,
  mergeMixedRevisionsQuickPickItems,
  mergeRecordOnlyQuickPickItems,
} from "./repository/mergeRangePromptOptions";
import { parseUpdateRevisionInput } from "./repository/updateRevisionInput";
import {
  RepositoryDiscoveryService,
  type RepositoryDiscoveryCandidate,
} from "./repository/repositoryDiscoveryService";
import {
  RepositoryLifecycleService,
  type RepositoryAutoOpenTrigger,
} from "./repository/repositoryLifecycleService";
import { RepositoryLifecycleCoordinator } from "./repository/repositoryLifecycleCoordinator";
import { RepositoryLifecycleNotificationService } from "./repository/repositoryLifecycleNotificationService";
import { RepositorySessionService, type RepositorySession } from "./repository/repositorySessionService";
import {
  BackendCheckoutTargetRecoveryClient,
  type CheckoutTargetRecoveryEntry,
} from "./repository/checkoutTargetRecoveryRpcClient";
import { SourceControlProjectionService } from "./scm/sourceControlProjectionService";
import { SourceControlResourceStore } from "./scm/sourceControlResourceStore";
import { VscodeSourceControlPresenter } from "./scm/vscodeSourceControlPresenter";
import { BackendStatusRefreshClient } from "./status/backendStatusRefreshClient";
import { BackendStatusRemoteCheckClient } from "./status/backendStatusRemoteCheckClient";
import { BackendStatusSnapshotClient } from "./status/backendStatusSnapshotClient";
import { DirtyPathPipeline } from "./status/dirtyPathPipeline";
import { RepositoryRefreshService } from "./status/repositoryRefreshService";
import { RemoteStatusCheckService } from "./status/remoteStatusCheckService";
import { BackendRemoteRecoveryClient } from "./status/backendRemoteRecoveryClient";
import { RemoteRecoveryService } from "./status/remoteRecoveryService";
import { redriveRequiredRemoteRecoveries } from "./status/remoteRecoveryReconnect";
import { RepositoryWatcherService } from "./status/repositoryWatcherService";
import { StatusRefreshCoverageStore } from "./status/statusRefreshCoverageStore";
import { createStatusNotificationHandler } from "./status/statusStaleNotificationHandler";
import { readStatusSettings } from "./status/statusSettings";
import { StatusSnapshotStore } from "./status/statusSnapshotStore";
import type { PathCasePolicy, StatusRefreshDepth, StatusRefreshTarget } from "./status/types";
import { createVscodeRepositoryWatcherFactory } from "./status/vscodeWatcherFactory";
import { WatcherOverflowDiagnostics } from "./status/watcherOverflowDiagnostics";
import { RemoteConnectionStateStore } from "./status/remoteConnectionStateStore";
import { createRemoteConnectionNotificationHandler } from "./status/remoteConnectionNotificationHandler";
import {
  canonicalEndpointFromRepositoryUrl,
  readRemoteAccessProfiles,
  RemoteOperationEnvelopeFactory,
  RemoteProfileConfigurationError,
  selectRemoteAccessProfile,
} from "./security/remoteAccessProfile";
import { TortoiseCommandController } from "./tortoise/tortoiseCommandController";
import {
  createNodeTortoiseDetectionHost,
  detectTortoiseSvn,
} from "./tortoise/tortoiseDetector";
import { launchTortoise } from "./tortoise/tortoiseLauncher";

let backendService: BackendService | undefined;
let repositorySessionService: RepositorySessionService | undefined;
let repositoryWatcherService: RepositoryWatcherService | undefined;
let operationDiagnostics: OperationDiagnostics | undefined;
let repositoryCommandCancellationSource: vscode.CancellationTokenSource | undefined;

const HISTORY_COPY_MESSAGE_LEGACY_ALIASES = ["svn.itemlog.copymsg", "svn.repolog.copymsg"] as const;
const HISTORY_COPY_REVISION_LEGACY_ALIASES = [
  "svn.itemlog.copyrevision",
  "svn.repolog.copyrevision",
] as const;
const HISTORY_COMPARE_REVISIONS_LEGACY_ALIASES = ["svn.itemlog.openDiff", "svn.repolog.openDiff"] as const;
const HISTORY_SEARCH_LEGACY_ALIASES = ["svn.searchLogByText"] as const;
const HEAD_OPEN_LEGACY_ALIASES = ["svn.openHEADFile"] as const;
const HEAD_DIFF_LEGACY_ALIASES = ["svn.openChangeHead"] as const;
const PREVIOUS_DIFF_LEGACY_ALIASES = ["svn.openChangePrev"] as const;
const LOW_FREQUENCY_FULL_RECONCILE_INTERVAL_MS = 5 * 60 * 1000;
const BACKEND_RESTART_INITIAL_BACKOFF_MS = 1000;
const BACKEND_RESTART_MAX_BACKOFF_MS = 30 * 1000;
const BACKEND_HEARTBEAT_INTERVAL_MS = 30 * 1000;
const BACKEND_HEARTBEAT_TIMEOUT_MS = 5 * 1000;
const REMOTE_STATUS_CHECK_TIMEOUT_MS = 30 * 1000;
const REMOTE_OPERATION_TIMEOUT_MS = 5 * 60 * 1000;

interface MatchingCompletedRefreshCoverageRequest {
  repositoryId: string;
  epoch: number;
  target: StatusRefreshTarget;
}

interface InstalledSourceControlUiE2eExecuteResourceCommandRequest {
  command: "subversionr.lockResource" | "subversionr.unlockResource";
  repositoryId: string;
  epoch: number;
  groupId: string;
  path: string;
}

function parseInstalledSourceControlUiE2eExecuteResourceCommandRequest(
  rawRequest: unknown,
): InstalledSourceControlUiE2eExecuteResourceCommandRequest {
  if (typeof rawRequest !== "object" || rawRequest === null) {
    throw installedSourceControlUiE2eResourceCommandError(
      "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_RESOURCE_COMMAND_REQUEST_INVALID",
    );
  }
  const request = rawRequest as Record<string, unknown>;
  if (
    Object.keys(request).sort().join(",") !== "command,epoch,groupId,path,repositoryId" ||
    (request.command !== "subversionr.lockResource" && request.command !== "subversionr.unlockResource") ||
    typeof request.repositoryId !== "string" ||
    request.repositoryId.trim().length === 0 ||
    request.repositoryId !== request.repositoryId.trim() ||
    typeof request.epoch !== "number" ||
    !Number.isSafeInteger(request.epoch) ||
    request.epoch < 0 ||
    typeof request.groupId !== "string" ||
    request.groupId.trim().length === 0 ||
    request.groupId !== request.groupId.trim() ||
    typeof request.path !== "string" ||
    request.path.trim().length === 0 ||
    request.path !== request.path.trim()
  ) {
    throw installedSourceControlUiE2eResourceCommandError(
      "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_RESOURCE_COMMAND_REQUEST_INVALID",
    );
  }
  return request as unknown as InstalledSourceControlUiE2eExecuteResourceCommandRequest;
}

function installedSourceControlUiE2eResourceCommandError(code: string): Error & { code: string } {
  return Object.assign(new Error(code), { code });
}

function parseMatchingCompletedRefreshCoverageRequest(rawRequest: unknown): MatchingCompletedRefreshCoverageRequest {
  if (typeof rawRequest !== "object" || rawRequest === null) {
    throw new TypeError("Installed Source Control UI E2E matching refresh coverage request is required.");
  }
  const request = rawRequest as Record<string, unknown>;
  const target = request.target;
  if (
    Object.keys(request).sort().join(",") !== "epoch,repositoryId,target" ||
    typeof request.repositoryId !== "string" ||
    request.repositoryId.trim().length === 0 ||
    typeof request.epoch !== "number" ||
    !Number.isInteger(request.epoch) ||
    request.epoch < 0 ||
    typeof target !== "object" ||
    target === null
  ) {
    throw new TypeError("Installed Source Control UI E2E matching refresh coverage request is invalid.");
  }
  const targetRecord = target as Record<string, unknown>;
  const depth = targetRecord.depth;
  if (
    Object.keys(targetRecord).sort().join(",") !== "depth,path,reason" ||
    typeof targetRecord.path !== "string" ||
    targetRecord.path.length === 0 ||
    (depth !== "empty" && depth !== "files" && depth !== "immediates" && depth !== "infinity") ||
    typeof targetRecord.reason !== "string" ||
    targetRecord.reason.length === 0
  ) {
    throw new TypeError("Installed Source Control UI E2E matching refresh coverage target is invalid.");
  }
  return {
    repositoryId: request.repositoryId,
    epoch: request.epoch,
    target: {
      path: targetRecord.path,
      depth: depth as StatusRefreshDepth,
      reason: targetRecord.reason,
    },
  };
}

export async function activate(context: vscode.ExtensionContext): Promise<void> {
  const installedSvnAnonymousReportToken = consumeInstalledSvnAnonymousReportToken();
  const installedSvnAnonymousStressCheckoutToken = consumeInstalledSvnAnonymousStressCheckoutToken();
  const installedSvnAnonymousNegativeReportToken = consumeInstalledSvnAnonymousNegativeReportToken();
  const installedSvnAnonymousAuthzDeniedReportToken = consumeInstalledSvnAnonymousAuthzDeniedReportToken();
  const installedSvnAnonymousStalledReadReportToken = consumeInstalledSvnAnonymousStalledReadReportToken();
  const installedSvnAnonymousLocalEventZeroNetworkToken =
    consumeInstalledSvnAnonymousLocalEventZeroNetworkToken();
  const installedSvnAnonymousStressCheckoutContext =
    installedSvnAnonymousStressCheckoutToken === undefined
      ? undefined
      : {
          token: installedSvnAnonymousStressCheckoutToken,
          sessionSha256: createInstalledSvnAnonymousStressSessionSha256(
            installedSvnAnonymousStressCheckoutToken,
          ),
        };
  const installedSvnAnonymousAuthActivity: InstalledSvnAnonymousAuthActivity = {
    credentialRequests: 0,
    credentialSettlements: 0,
    certificateRequests: 0,
  };
  const remoteStateRoot = remoteStateRootPath(context);
  await vscode.workspace.fs.createDirectory(vscode.Uri.file(remoteStateRoot));
  const commandCancellationSource = new vscode.CancellationTokenSource();
  repositoryCommandCancellationSource = commandCancellationSource;
  context.subscriptions.push({
    dispose: () => {
      commandCancellationSource.cancel();
      commandCancellationSource.dispose();
    },
  });
  const operationLogChannel = vscode.window.createOutputChannel("SubversionR", { log: true });
  const diagnostics = new OperationDiagnostics(operationLogChannel);
  operationDiagnostics = diagnostics;
  const configuration = vscode.workspace.getConfiguration("subversionr");
  const statusSettings = readStatusSettings(configuration);
  let historySettings = readHistorySettings(configuration);
  let lensSettings = readLensSettings(configuration);
  const secretStorage = {
    get: async (key: string) => await context.secrets.get(key),
    store: async (key: string, value: string) => {
      await context.secrets.store(key, value);
    },
    delete: async (key: string) => {
      await context.secrets.delete(key);
    },
  };
  const credentialController = createCredentialController({
    workspaceTrusted: () => vscode.workspace.isTrusted,
    secretStorage,
    ui: {
      pickAccount: pickCredentialAccount,
      promptSecret: async (request, username) =>
        await showCredentialInputBox(request, {
          title: vscode.l10n.t("SVN Credentials"),
          prompt: credentialSecretPrompt(request, username),
          password: true,
          ignoreFocusOut: true,
        }),
      pickPersistence: pickCredentialPersistence,
      confirmLegacyClear: confirmLegacyCredentialClear,
    },
  });
  context.subscriptions.push({ dispose: () => credentialController.dispose() });
  const certificateTrustController = createCertificateTrustController({
    workspaceTrusted: () => vscode.workspace.isTrusted,
    secretStorage,
    ui: {
      pickTrust: pickCertificateTrust,
    },
  });
  const productionAuthRequestHandler = createAuthRequestHandler({
    credentialController,
    certificateTrustController,
  });
  const authRequestHandler = async (method: string, params: unknown): Promise<unknown> => {
    if (
      installedSvnAnonymousReportToken !== undefined ||
      installedSvnAnonymousStressCheckoutToken !== undefined ||
      installedSvnAnonymousNegativeReportToken !== undefined ||
      installedSvnAnonymousAuthzDeniedReportToken !== undefined ||
      installedSvnAnonymousStalledReadReportToken !== undefined ||
      installedSvnAnonymousLocalEventZeroNetworkToken !== undefined
    ) {
      if (method === "credentials/request") {
        installedSvnAnonymousAuthActivity.credentialRequests += 1;
      } else if (method === "credentials/settle") {
        installedSvnAnonymousAuthActivity.credentialSettlements += 1;
      } else if (method === "certificate/request") {
        installedSvnAnonymousAuthActivity.certificateRequests += 1;
      }
    }
    return await productionAuthRequestHandler(method, params);
  };
  const statusSnapshotStore = new StatusSnapshotStore();
  const remoteConnectionStateStore = new RemoteConnectionStateStore();
  const watcherOverflowDiagnostics = new WatcherOverflowDiagnostics();
  const sourceControlRepositoryIds = new WeakMap<object, string>();
  const sourceControlRepositoryHistoryTargets = new WeakMap<object, RepositoryHistoryCommandTarget>();
  const commitMessageHistory = new RepositoryCommitMessageHistory();
  const sourceControlPresenter = new VscodeSourceControlPresenter({
    createSourceControl: (id, label, rootUri, repositoryId, epoch) => {
      const sourceControl = vscode.scm.createSourceControl(id, label, rootUri as vscode.Uri);
      sourceControlRepositoryIds.set(sourceControl, repositoryId);
      sourceControlRepositoryHistoryTargets.set(
        sourceControl,
        repositoryHistoryCommandTarget(repositoryId, epoch),
      );
      return sourceControl;
    },
    updateSourceControlRepositorySession: (sourceControl, repositoryId, epoch) => {
      sourceControlRepositoryHistoryTargets.set(
        sourceControl,
        repositoryHistoryCommandTarget(repositoryId, epoch),
      );
    },
    uriFromComponents: (components) => vscode.Uri.from(components),
    uriFile: vscode.Uri.file,
    uriFsPath,
    workspaceTrusted: () => vscode.workspace.isTrusted,
    localize: vscode.l10n.t,
  });
  const sourceControlProjection = new SourceControlProjectionService(
    new SourceControlResourceStore({
      countPolicy: {
        countUnversioned: statusSettings.countUnversioned,
        ignoreChangelistsInCount: statusSettings.ignoreChangelistsInCount,
      },
    }),
    sourceControlPresenter,
  );
  const statusConfigurationChange = vscode.workspace.onDidChangeConfiguration((event) => {
    if (
      event.affectsConfiguration("subversionr.status.countUnversioned") ||
      event.affectsConfiguration("subversionr.status.ignoreChangelistsInCount")
    ) {
      sourceControlProjection.updateCountPolicy(readStatusSettings(vscode.workspace.getConfiguration("subversionr")));
    }
  });
  const statusNotificationHandler = createStatusNotificationHandler({
    statusSnapshotStore,
    sourceControlProjection,
    watcherOverflowDiagnostics,
  });
  let remoteRecoveryService: RemoteRecoveryService | undefined;
  const remoteConnectionNotificationHandler = createRemoteConnectionNotificationHandler({
    store: remoteConnectionStateStore,
    projection: sourceControlProjection,
    now: () => new Date().toISOString(),
    scheduleRecovery: async (target) => {
      if (!remoteRecoveryService) {
        throw new Error("SUBVERSIONR_REMOTE_RECOVERY_SERVICE_UNAVAILABLE");
      }
      await remoteRecoveryService.recover(target);
    },
    recordBackgroundRecoveryFailure: (error) => diagnostics.recordFailure("Remote Recovery", error),
  });
  const backendNotificationHandler = (method: string, params: unknown): void => {
    if (!remoteConnectionNotificationHandler(method, params)) {
      statusNotificationHandler(method, params);
    }
  };
  const service = new BackendService({
    readConfig: () =>
      backendLaunchConfigFromPackageResources(resolveBackendPackageResources(context), {
        clientName: "SubversionR",
        clientVersion: extensionVersion(context),
        locale: vscode.env.language,
        cacheRoot: cacheRootPath(context),
        remoteStateRoot,
        workspaceTrusted: vscode.workspace.isTrusted,
        baseEnv: process.env,
      }),
    start: (config) =>
      startBackendProcess(config, {
        requestHandler: authRequestHandler,
        notificationHandler: backendNotificationHandler,
        onRequestError: (method, error) => diagnostics.recordRpcFailure(method, error),
        onRequestSettled: (_method, params) => {
          discardCredentialOperationAfterBackendRequest(credentialController, params);
        },
      }),
    lifecycleClock: systemBackendLifecycleClock(),
    heartbeatPolicy: {
      kind: "enabled",
      intervalMs: BACKEND_HEARTBEAT_INTERVAL_MS,
      timeoutMs: BACKEND_HEARTBEAT_TIMEOUT_MS,
    },
    restartPolicy: {
      initialBackoffMs: BACKEND_RESTART_INITIAL_BACKOFF_MS,
      maxBackoffMs: BACKEND_RESTART_MAX_BACKOFF_MS,
    },
  });
  backendService = service;
  const checkoutTargetRecoveryClient = new BackendCheckoutTargetRecoveryClient(service);
  context.subscriptions.push(service.onDidChangeLifecycleState((event) => {
    if (event.status === "ready" || event.status === "recovered" || event.status === "degraded") {
      credentialController.invalidateBackendConnection();
    }
  }));
  const backendLifecycleUiService = new BackendLifecycleUiService({
    backend: service,
    api: {
      createStatusBarItem: () =>
        vscode.window.createStatusBarItem(
          "subversionr.backendLifecycle",
          vscode.StatusBarAlignment.Left,
          100,
        ),
      localize: vscode.l10n.t,
      setContext: async (key, value) => {
        await vscode.commands.executeCommand("setContext", key, value);
      },
    },
  });
  void backendLifecycleUiService.refresh();
  const createAnonymousSvnRemoteEnvelope = async (input: {
    operationId: string;
    repositoryRootUrl: string;
    timeoutMs: number;
  }) => {
    const expectedOrigin = canonicalEndpointFromRepositoryUrl(input.repositoryRootUrl);
    const remoteConfiguration = vscode.workspace.getConfiguration("subversionr");
    const profiles = readRemoteAccessProfiles({
      inspect: <T>(section: string) => remoteConfiguration.inspect(section) as T | undefined,
    });
    const profile = selectRemoteAccessProfile(profiles, expectedOrigin);
    const connection = await service.initialize();
    const factory = new RemoteOperationEnvelopeFactory({
      remoteSvnAnonymous: connection.initializeResult.capabilities.remoteSvnAnonymous,
      isRemoteSubmissionEnabled: () => connection.isRemoteSubmissionEnabled(),
      currentRemoteTrustEpoch: () => connection.currentRemoteTrustEpoch(),
    });
    return factory.createAnonymousSvn({
      operationId: input.operationId,
      intent: "foreground",
      interaction: "allowed",
      timeoutMs: input.timeoutMs,
      profile,
      expectedOrigin,
    });
  };
  const createOperationRemoteEnvelope = async (repositoryRootUrl: string) => {
    const scheme = new URL(repositoryRootUrl).protocol;
    if (scheme === "file:") {
      return undefined;
    }
    if (scheme !== "svn:") {
      throw new RemoteProfileConfigurationError(
        "SUBVERSIONR_REMOTE_SCHEME_UNSUPPORTED",
        "error.remote.schemeUnsupported",
        { scheme: scheme.slice(0, 32) },
      );
    }
    return await createAnonymousSvnRemoteEnvelope({
      operationId: randomUUID(),
      repositoryRootUrl,
      timeoutMs: REMOTE_OPERATION_TIMEOUT_MS,
    });
  };
  let sessionService: RepositorySessionService;
  const createOperationRemoteEnvelopeForSession = async (input: {
    repositoryId: string;
    epoch: number;
  }) => {
    const session = sessionService
      .listOpenSessions()
      .find((candidate) => candidate.repositoryId === input.repositoryId && candidate.epoch === input.epoch);
    if (!session) {
      throw new RemoteProfileConfigurationError(
        "SUBVERSIONR_REMOTE_SESSION_NOT_OPEN",
        "error.repository.notOpen",
        { repositoryId: input.repositoryId },
      );
    }
    return await createOperationRemoteEnvelope(session.identity.repositoryRootUrl);
  };
  const historyClient = new BackendHistoryClient(service);
  const baseContentDocumentProvider = vscode.workspace.registerTextDocumentContentProvider(
    BASE_CONTENT_URI_SCHEME,
    new BaseContentDocumentProvider({
      contentClient: new BackendContentClient(service),
      localize: vscode.l10n.t,
    }),
  );
  const headContentDocumentProvider = vscode.workspace.registerTextDocumentContentProvider(
    HEAD_CONTENT_URI_SCHEME,
    new HeadContentDocumentProvider({
      contentClient: new BackendContentClient(service),
      createRemoteEnvelope: createOperationRemoteEnvelopeForSession,
      workspaceTrusted: () => vscode.workspace.isTrusted,
      localize: vscode.l10n.t,
    }),
  );
  const revisionContentDocumentProvider = vscode.workspace.registerTextDocumentContentProvider(
    REVISION_CONTENT_URI_SCHEME,
    new RevisionContentDocumentProvider({
      contentClient: new BackendContentClient(service),
      createRemoteEnvelope: createOperationRemoteEnvelopeForSession,
      workspaceTrusted: () => vscode.workspace.isTrusted,
      localize: vscode.l10n.t,
    }),
  );
  const historyTreeDataProvider = new HistoryTreeDataProvider({
    historyClient,
    createRemoteEnvelope: createOperationRemoteEnvelopeForSession,
    settings: historySettings,
    workspaceTrusted: () => vscode.workspace.isTrusted,
    api: {
      collapsibleState: {
        none: vscode.TreeItemCollapsibleState.None,
        collapsed: vscode.TreeItemCollapsibleState.Collapsed,
        expanded: vscode.TreeItemCollapsibleState.Expanded,
      },
      createEventEmitter: () => new vscode.EventEmitter(),
    },
    localize: vscode.l10n.t,
  });
  const blameDocumentProvider = vscode.workspace.registerTextDocumentContentProvider(
    BLAME_DOCUMENT_URI_SCHEME,
    new HistoryBlameDocumentProvider({
      blameClient: historyClient,
      createRemoteEnvelope: createOperationRemoteEnvelopeForSession,
      workspaceTrusted: () => vscode.workspace.isTrusted,
      localize: vscode.l10n.t,
    }),
  );
  const revisionDetailsStore = new HistoryRevisionDetailsDocumentStore();
  const revisionDetailsDocumentProvider = vscode.workspace.registerTextDocumentContentProvider(
    REVISION_DETAILS_URI_SCHEME,
    new HistoryRevisionDetailsDocumentProvider({
      store: revisionDetailsStore,
      localize: vscode.l10n.t,
    }),
  );
  const revisionDetailsDocumentLifecycle = vscode.workspace.onDidCloseTextDocument((document) => {
    if (document.uri.scheme === REVISION_DETAILS_URI_SCHEME) {
      revisionDetailsStore.releaseDocument(document.uri);
    }
  });
  const historyTreeView = vscode.window.createTreeView("subversionr.history", {
    treeDataProvider: historyTreeDataProvider,
    canSelectMany: true,
  });
  const historyTreeViewController = new HistoryTreeViewController({
    provider: historyTreeDataProvider,
    treeView: historyTreeView,
  });
  const statusRefreshClient = new InstalledSourceControlUiE2eStatusRefreshProbe(
    new BackendStatusRefreshClient(service),
  );
  const statusRefreshCoverage = new StatusRefreshCoverageStore();
  const operationScheduler = new RepositoryOperationScheduler();
  const operationJournal = new RepositoryOperationJournal({ maxEntries: 50 });
  const dirtyPathPipeline = new DirtyPathPipeline(statusRefreshClient, statusSnapshotStore, sourceControlProjection, {
    fullReconcileIntervalMs: LOW_FREQUENCY_FULL_RECONCILE_INTERVAL_MS,
    coverageRecorder: statusRefreshCoverage,
  });
  const watcherService = new RepositoryWatcherService({
    pipeline: dirtyPathPipeline,
    createWatcher: createVscodeRepositoryWatcherFactory({
      uriFile: vscode.Uri.file,
      relativePattern: (base, pattern) => new vscode.RelativePattern(base as vscode.Uri, pattern),
      createFileSystemWatcher: (pattern, ignoreCreateEvents, ignoreChangeEvents, ignoreDeleteEvents) =>
        vscode.workspace.createFileSystemWatcher(
          pattern as vscode.GlobPattern,
          ignoreCreateEvents,
          ignoreChangeEvents,
          ignoreDeleteEvents,
        ),
    }),
  });
  repositoryWatcherService = watcherService;
  sessionService = new RepositorySessionService({
    backendService: service,
    watcherService,
    statusSnapshotClient: new BackendStatusSnapshotClient(service),
    statusSnapshotStore,
    sourceControlProjection,
  });
  repositorySessionService = sessionService;
  const diagnosticsDocumentProvider = new DiagnosticsReadonlyDocumentProvider({
    createEventEmitter: () => new vscode.EventEmitter<vscode.Uri>(),
    uriFromComponents: (components) => vscode.Uri.from(components),
    currentRepositoryEpoch: (repositoryId) =>
      sessionService.listOpenSessions().find((session) => session.repositoryId === repositoryId)?.epoch,
  });
  const fileHeaderCodeLensProvider = new FileHeaderCodeLensProvider<vscode.CodeLens>({
    settings: () => lensSettings,
    sessionService,
    sourceControlProjection,
    workspaceTrusted: () => vscode.workspace.isTrusted,
    api: {
      createEventEmitter: () => new vscode.EventEmitter<void>(),
      createRange: (startLine, startCharacter, endLine, endCharacter) =>
        new vscode.Range(startLine, startCharacter, endLine, endCharacter),
      createCodeLens: (range) => new vscode.CodeLens(range as vscode.Range),
      localize: vscode.l10n.t,
    },
  });
  const fileHeaderCodeLensRegistration = vscode.languages.registerCodeLensProvider(
    { scheme: "file" },
    fileHeaderCodeLensProvider,
  );
  const symbolHistoryCodeLensProvider = new SymbolHistoryCodeLensProvider<vscode.CodeLens>({
    settings: () => lensSettings,
    includeMergedRevisions: () => historySettings.includeMergedRevisions,
    historyClient,
    createRemoteEnvelope: createOperationRemoteEnvelopeForSession,
    sessionService,
    sourceControlProjection,
    workspaceTrusted: () => vscode.workspace.isTrusted,
    api: {
      createEventEmitter: () => new vscode.EventEmitter<void>(),
      createRange: (startLine, startCharacter, endLine, endCharacter) =>
        new vscode.Range(startLine, startCharacter, endLine, endCharacter),
      createCodeLens: (range) => new vscode.CodeLens(range as vscode.Range),
      executeDocumentSymbols: async (uri) =>
        vscode.commands.executeCommand("vscode.executeDocumentSymbolProvider", uri as vscode.Uri),
      localize: vscode.l10n.t,
    },
  });
  const symbolHistoryCodeLensRegistration = vscode.languages.registerCodeLensProvider(
    { scheme: "file" },
    symbolHistoryCodeLensProvider,
  );
  const currentLineBlameHoverProvider = new CurrentLineBlameHoverProvider<vscode.Hover, vscode.MarkdownString>({
    settings: () => lensSettings,
    includeMergedRevisions: () => historySettings.includeMergedRevisions,
    historyClient,
    createRemoteEnvelope: createOperationRemoteEnvelopeForSession,
    sessionService,
    sourceControlProjection,
    workspaceTrusted: () => vscode.workspace.isTrusted,
    api: {
      createMarkdownString: (value) => new vscode.MarkdownString(value),
      createHover: (contents) => new vscode.Hover(contents as vscode.MarkdownString[]),
      localize: vscode.l10n.t,
    },
  });
  const currentLineBlameHoverRegistration = vscode.languages.registerHoverProvider(
    { scheme: "file" },
    currentLineBlameHoverProvider,
  );
  const lensConfigurationChange = vscode.workspace.onDidChangeConfiguration((event) => {
    if (event.affectsConfiguration("subversionr.lens")) {
      lensSettings = readLensSettings(vscode.workspace.getConfiguration("subversionr"));
      fileHeaderCodeLensProvider.refresh();
      symbolHistoryCodeLensProvider.refresh();
      refreshActiveEditorContext();
      refreshCurrentLineBlame();
    }
  });
  const projectionCodeLensRefresh = sourceControlProjection.onDidChangeProjection(() => {
    fileHeaderCodeLensProvider.refresh();
    symbolHistoryCodeLensProvider.refresh();
  });
  const sessionCodeLensRefresh = sessionService.onDidChangeSessions((event) => {
    if (event.kind === "closed") {
      remoteConnectionStateStore.unregisterRepository(event.repositoryId);
    } else if (event.kind === "reopened") {
      const state = remoteConnectionStateStore.rebindRepository({
        repositoryId: event.repositoryId,
        epoch: event.epoch,
      });
      sourceControlProjection.updateRemoteConnectionState(state);
    } else {
      const session = sessionService.listOpenSessions().find((candidate) => candidate.repositoryId === event.repositoryId);
      if (!session) {
        throw new Error("SUBVERSIONR_REMOTE_STATE_SESSION_UNAVAILABLE");
      }
      const state = remoteConnectionStateStore.registerRepository({
        repositoryId: session.repositoryId,
        epoch: session.epoch,
      });
      sourceControlProjection.updateRemoteConnectionState(state);
    }
    fileHeaderCodeLensProvider.refresh();
    symbolHistoryCodeLensProvider.refresh();
  });
  const activeEditorContextService = new ActiveEditorContextService({
    settings: () => lensSettings,
    sessionService,
    sourceControlProjection,
    api: {
      activeTextDocument: () => vscode.window.activeTextEditor?.document,
      setContext: async (key, value) => {
        await vscode.commands.executeCommand("setContext", key, value);
      },
    },
  });
  const lineHistoryCommandController = new LineHistoryCommandController({
    settings: () => lensSettings,
    includeMergedRevisions: () => historySettings.includeMergedRevisions,
    historyClient,
    createRemoteEnvelope: createOperationRemoteEnvelopeForSession,
    sessionService,
    sourceControlProjection,
    workspaceTrusted: () => vscode.workspace.isTrusted,
    diagnostics,
    ui: {
      activeTextEditor: () => vscode.window.activeTextEditor,
      showLineHistory: async (target, entries) => {
        await historyTreeViewController.showLineHistory(target, entries);
      },
      showErrorMessage: async (message, ...actions) =>
        await vscode.window.showErrorMessage(message, ...actions),
    },
    localize: vscode.l10n.t,
  });
  const currentLineBlameStatusBarService = new CurrentLineBlameStatusBarService({
    settings: () => lensSettings,
    includeMergedRevisions: () => historySettings.includeMergedRevisions,
    historyClient,
    createRemoteEnvelope: createOperationRemoteEnvelopeForSession,
    sessionService,
    sourceControlProjection,
    workspaceTrusted: () => vscode.workspace.isTrusted,
    api: {
      activeTextEditor: () => vscode.window.activeTextEditor,
      createStatusBarItem: () =>
        vscode.window.createStatusBarItem(
          "subversionr.currentLineBlame",
          vscode.StatusBarAlignment.Right,
          100,
        ),
      localize: vscode.l10n.t,
      setTimeout: (callback, delayMs) => globalThis.setTimeout(callback, delayMs),
      clearTimeout: (handle) => globalThis.clearTimeout(handle as ReturnType<typeof globalThis.setTimeout>),
    },
  });
  const refreshCurrentLineBlame = () => {
    void currentLineBlameStatusBarService.refresh();
  };
  const historyConfigurationChange = vscode.workspace.onDidChangeConfiguration((event) => {
    if (event.affectsConfiguration("subversionr.history")) {
      historySettings = readHistorySettings(vscode.workspace.getConfiguration("subversionr"));
      void runHistoryCommand(() => historyTreeDataProvider.updateSettings(historySettings));
      symbolHistoryCodeLensProvider.refresh();
      refreshCurrentLineBlame();
    }
  });
  const refreshActiveEditorContext = () => {
    void activeEditorContextService.refresh();
  };
  const refreshWorkspaceTrustUi = () => {
    sourceControlPresenter.refreshWorkspaceTrust();
    fileHeaderCodeLensProvider.refresh();
    symbolHistoryCodeLensProvider.refresh();
    historyTreeDataProvider.refreshWorkspaceTrust();
    refreshActiveEditorContext();
    refreshCurrentLineBlame();
  };
  refreshActiveEditorContext();
  refreshCurrentLineBlame();
  const activeEditorChange = vscode.window.onDidChangeActiveTextEditor(refreshActiveEditorContext);
  const currentLineBlameActiveEditorChange = vscode.window.onDidChangeActiveTextEditor(refreshCurrentLineBlame);
  const currentLineBlameSelectionChange = vscode.window.onDidChangeTextEditorSelection((event) => {
    if (event.textEditor === vscode.window.activeTextEditor) {
      refreshCurrentLineBlame();
    }
  });
  const currentLineBlameDocumentChange = vscode.workspace.onDidChangeTextDocument((event) => {
    if (event.document === vscode.window.activeTextEditor?.document) {
      refreshActiveEditorContext();
      refreshCurrentLineBlame();
    }
  });
  const projectionActiveEditorRefresh = sourceControlProjection.onDidChangeProjection(refreshActiveEditorContext);
  const sessionActiveEditorRefresh = sessionService.onDidChangeSessions(refreshActiveEditorContext);
  const projectionCurrentLineBlameRefresh = sourceControlProjection.onDidChangeProjection(refreshCurrentLineBlame);
  const sessionCurrentLineBlameRefresh = sessionService.onDidChangeSessions(refreshCurrentLineBlame);
  const tortoiseDetector = {
    detect: () =>
      detectTortoiseSvn(
        vscode.workspace.getConfiguration("subversionr"),
        createNodeTortoiseDetectionHost(vscode.workspace.isTrusted),
      ),
  };
  const refreshTortoiseAvailability = () => {
    void (async () => {
      if (!vscode.workspace.isTrusted) {
        await vscode.commands.executeCommand("setContext", "subversionr.tortoiseAvailable", false);
        return;
      }
      try {
        const detection = await tortoiseDetector.detect();
        await vscode.commands.executeCommand(
          "setContext",
          "subversionr.tortoiseAvailable",
          detection.status === "available",
        );
      } catch {
        await vscode.commands.executeCommand("setContext", "subversionr.tortoiseAvailable", false);
      }
    })();
  };
  refreshTortoiseAvailability();
  const tortoiseConfigurationChange = vscode.workspace.onDidChangeConfiguration((event) => {
    if (event.affectsConfiguration("subversionr.tortoise")) {
      refreshTortoiseAvailability();
    }
  });
  const tortoiseCommandController = new TortoiseCommandController({
    detector: tortoiseDetector,
    launcher: launchTortoise,
    sessionService,
    ui: {
      workspaceTrusted: () => vscode.workspace.isTrusted,
      pickOpenRepository,
      showWarningMessage: async (message) => {
        await vscode.window.showWarningMessage(message);
      },
      showErrorMessage: async (message) => {
        await vscode.window.showErrorMessage(message);
      },
    },
    localize: vscode.l10n.t,
  });
  const repositoryDiscoveryService = new RepositoryDiscoveryService({
    backendService: service,
    sessionService,
  });
  const repositoryRefreshService = new RepositoryRefreshService({
    dirtyPathPipeline,
  });
  remoteRecoveryService = new RemoteRecoveryService({
    client: new BackendRemoteRecoveryClient(service),
    store: remoteConnectionStateStore,
    projection: sourceControlProjection,
    createOperationId: randomUUID,
    now: () => new Date().toISOString(),
    timeoutMs: REMOTE_STATUS_CHECK_TIMEOUT_MS,
  });
  const remoteStatusCheckService = new RemoteStatusCheckService({
    client: new BackendStatusRemoteCheckClient(service),
    statusSnapshotStore,
    sourceControlProjection,
    remoteStateProjection: sourceControlProjection,
    refreshPipeline: dirtyPathPipeline,
    remoteConnectionStateStore,
    now: () => new Date().toISOString(),
    createOperationId: randomUUID,
    createRemoteEnvelope: async (input) => {
      const scheme = new URL(input.repositoryRootUrl).protocol;
      if (scheme === "file:") {
        return undefined;
      }
      if (scheme !== "svn:") {
        throw new RemoteProfileConfigurationError(
          "SUBVERSIONR_REMOTE_SCHEME_UNSUPPORTED",
          "error.remote.schemeUnsupported",
          { scheme: scheme.slice(0, 32) },
        );
      }
      return await createAnonymousSvnRemoteEnvelope({
        ...input,
        timeoutMs: REMOTE_STATUS_CHECK_TIMEOUT_MS,
      });
    },
  });
  let reconcileRequestCount = 0;
  let remoteStatusRequestCount = 0;
  const repositoryCommandController = new RepositoryCommandController({
    discoveryService: repositoryDiscoveryService,
    sessionService,
    refreshService: {
      refreshRepository: async (repositoryId, options) => {
        reconcileRequestCount += 1;
        await repositoryRefreshService.refreshRepository(repositoryId, options);
      },
      fullReconcileRepository: async (target, options) => {
        reconcileRequestCount += 1;
        await repositoryRefreshService.fullReconcileRepository(target, options);
      },
      refreshResource: async (target) => {
        reconcileRequestCount += 1;
        await repositoryRefreshService.refreshResource(target);
      },
      refreshTargets: async (target, options) => {
        reconcileRequestCount += 1;
        await repositoryRefreshService.refreshTargets(target, options);
      },
    },
    remoteStatusCheckService: {
      checkRemoteChanges: async (request, options) => {
        remoteStatusRequestCount += 1;
        return await remoteStatusCheckService.checkRemoteChanges(request, options);
      },
    },
    remoteRecoveryService,
    operationClient: new BackendOperationClient(service),
    checkoutClient: new BackendRepositoryCheckoutClient(service),
    propertiesClient: new BackendPropertiesClient(service),
    operationJournal,
    diagnostics,
    historyClient,
    operationScheduler,
    sourceControlProjection,
    commandCancellation: commandCancellationSource.token,
    commitMessageHistory,
    includeMergedRevisions: () => historySettings.includeMergedRevisions,
    createRemoteEnvelope: createOperationRemoteEnvelope,
    createRequestId: randomUUID,
    now: () => new Date().toISOString(),
    monotonicNowMs: () => performance.now(),
    ui: {
      workspaceRoots: () => (vscode.workspace.workspaceFolders ?? []).map((folder) => folder.uri.fsPath),
      activeEditorResource: () => activeEditorContextService.commandTarget(),
      pathCasePolicy: () => pathCasePolicy(process.platform),
      pickRepositoryCandidate,
      pickOpenRepository,
      showInformationMessage: async (message) => {
        await vscode.window.showInformationMessage(message);
      },
      showWarningMessage: async (message) => {
        await vscode.window.showWarningMessage(message);
      },
      showErrorMessage: async (message, ...actions) =>
        await vscode.window.showErrorMessage(message, ...actions),
      openRemoteAccessSettings: async () => {
        await vscode.commands.executeCommand("workbench.action.openSettings", "subversionr.remote.profiles");
      },
      showTextDocument: async (document) => {
        const textDocument = await vscode.workspace.openTextDocument({
          content: document.content,
          language: document.language,
        });
        await vscode.window.showTextDocument(textDocument, { preview: false });
      },
      showReadonlyRepositoryReport: async (document) => {
        const uri = diagnosticsDocumentProvider.createOrUpdateRepositoryReport({
          kind: document.kind,
          repositoryId: document.repositoryId,
          epoch: document.epoch,
          path: document.path,
          content: document.content,
        });
        const textDocument = await vscode.workspace.openTextDocument(uri);
        if (textDocument.languageId !== document.language) {
          await vscode.languages.setTextDocumentLanguage(textDocument, document.language);
        }
        await vscode.commands.executeCommand("vscode.open", uri, { preview: false }, document.title);
      },
      confirmRevertResource: async (resourcePath) => {
        const confirm = vscode.l10n.t("Revert");
        const selected = await vscode.window.showWarningMessage(
          vscode.l10n.t("Revert local SVN changes to {0}? This cannot be undone.", resourcePath),
          confirm,
        );
        return selected === confirm;
      },
      confirmRemoveResource: async (resourcePath) => {
        const confirm = vscode.l10n.t("Remove");
        const selected = await vscode.window.showWarningMessage(
          vscode.l10n.t(
            "Remove SVN resource {0}? The local item will be deleted and scheduled for commit.",
            resourcePath,
          ),
          confirm,
        );
        return selected === confirm;
      },
      confirmRemoveResourceKeepLocal: async (resourcePath) => {
        const confirm = vscode.l10n.t("Remove");
        const selected = await vscode.window.showWarningMessage(
          vscode.l10n.t(
            "Remove SVN resource {0} from version control but keep the local item?",
            resourcePath,
          ),
          confirm,
        );
        return selected === confirm;
      },
      promptMoveDestination: async (sourcePath) =>
        await vscode.window.showInputBox({
          title: vscode.l10n.t("Move SVN resource"),
          prompt: vscode.l10n.t("Enter the repository-relative destination path for {0}.", sourcePath),
          value: sourcePath,
          ignoreFocusOut: true,
        }),
      confirmDeleteUnversionedResources: async (resourcePaths) => {
        const confirm = vscode.l10n.t("Delete");
        const message =
          resourcePaths.length === 1
            ? vscode.l10n.t("Delete unversioned SVN item {0}? This cannot be undone.", resourcePaths[0])
            : vscode.l10n.t("Delete {0} unversioned SVN items? This cannot be undone.", resourcePaths.length);
        const selected = await vscode.window.showWarningMessage(
          message,
          confirm,
        );
        return selected === confirm;
      },
      promptResolveChoice: promptResolveChoice,
      promptChangelistName: async (resourcePaths) =>
        await vscode.window.showInputBox({
          title: vscode.l10n.t("Set SVN changelist"),
          prompt:
            resourcePaths.length === 1
              ? vscode.l10n.t("Enter the SVN changelist name for {0}.", resourcePaths[0])
              : vscode.l10n.t("Enter the SVN changelist name for {0} resources.", resourcePaths.length),
          placeHolder: vscode.l10n.t("Changelist name"),
          ignoreFocusOut: true,
          validateInput: validateChangelistNameInput,
        }),
      promptLockOptions: promptLockOptions,
      promptUnlockOptions: promptUnlockOptions,
      promptCleanupOptions: promptCleanupOptions,
      promptUpdateOptions: promptUpdateOptions,
      promptCheckoutOptions: promptCheckoutOptions,
      promptBranchCreateOptions: promptBranchCreateOptions,
      promptSwitchOptions: promptSwitchOptions,
      promptRelocateOptions: promptRelocateOptions,
      promptMergeRangeOptions: promptMergeRangeOptions,
      promptPropertySetOptions: promptPropertySetOptions,
      promptPropertyDeleteName: promptPropertyDeleteName,
      promptExternalsPropertyValue: promptExternalsPropertyValue,
      promptReviewCommitTargets: promptReviewCommitTargets,
      promptCommitMessage: promptCommitMessage,
      promptCommitMessageHistory: promptCommitMessageHistory,
      runOperationWithProgress: async (title, task) => await runOperationWithProgress(title, task),
      workspaceTrusted: () => vscode.workspace.isTrusted,
      hasUnsavedTextDocument: (fsPath) =>
        vscode.workspace.textDocuments.some(
          (document) => document.isDirty && normalizedFsPath(document.uri.fsPath) === normalizedFsPath(fsPath),
        ),
      deleteLocalFile: async (fsPath, options) => {
        await vscode.workspace.fs.delete(vscode.Uri.file(fsPath), { recursive: options.recursive, useTrash: false });
      },
      commitMessage: (repositoryId) => sourceControlPresenter.commitMessage(repositoryId),
      setCommitMessage: (repositoryId, message) => sourceControlPresenter.setCommitMessage(repositoryId, message),
      clearCommitMessage: (repositoryId) => sourceControlPresenter.clearCommitMessage(repositoryId),
      uriFile: vscode.Uri.file,
      uriFromComponents: (components) => vscode.Uri.from(components),
      diffWithBase: async (left, right, title) => {
        await vscode.commands.executeCommand("vscode.diff", left, right, title);
      },
      openBase: async (uri, title) => {
        await vscode.commands.executeCommand("vscode.open", uri, { preview: false }, title);
      },
      diffWithHead: async (left, right, title) => {
        await vscode.commands.executeCommand("vscode.diff", left, right, title);
      },
      openHead: async (uri, title) => {
        await vscode.commands.executeCommand("vscode.open", uri, { preview: false }, title);
      },
      diffRevisions: async (left, right, title) => {
        await vscode.commands.executeCommand("vscode.diff", left, right, title);
      },
      showHistory: async (target) => {
        await historyTreeViewController.showHistory(target);
      },
      showBlame: async (target) => {
        const uri = vscode.Uri.from(createBlameDocumentUriComponents(target));
        await vscode.commands.executeCommand(
          "vscode.open",
          uri,
          { preview: false },
          vscode.l10n.t("SVN Blame: {0}", target.path),
        );
      },
    },
    localize: vscode.l10n.t,
  });
  let repositoryLifecycleService: RepositoryLifecycleService;
  let repositoryLifecycleCoordinator: RepositoryLifecycleCoordinator;
  const repositoryLifecycleNotifications = new RepositoryLifecycleNotificationService({
    ui: {
      showInformationMessage: async (message) => {
        await vscode.window.showInformationMessage(message);
      },
      showWarningMessage: async (message) => {
        await vscode.window.showWarningMessage(message);
      },
      showErrorMessage: async (message, ...actions) => await vscode.window.showErrorMessage(message, ...actions),
    },
    localize: vscode.l10n.t,
    recordFailure: (operation, error) => diagnostics.recordFailure(operation, error),
    retryDisappearedRepositoryCleanup: async (trigger) => {
      await repositoryLifecycleCoordinator.runExclusive(trigger, async () => {
        await repositoryLifecycleService.closeDisappearedRepositories(trigger);
      });
    },
    retryMovedRepositoryRecovery: async (trigger) => {
      await repositoryLifecycleCoordinator.runExclusive(trigger, async () => {
        await repositoryLifecycleService.recoverMovedRepositories(trigger);
      });
    },
    retryWorkspaceRepositoryOpen: async (trigger) => {
      await repositoryLifecycleCoordinator.runExclusive(trigger, async () => {
        await repositoryLifecycleService.autoOpenWorkspaceRepositories(trigger);
      });
    },
  });
  repositoryLifecycleService = new RepositoryLifecycleService({
    discoveryService: repositoryDiscoveryService,
    sessionService,
    workspaceRoots: workspaceRootsWithInstalledSourceControlUiE2eExtra,
    workspaceTrusted: () => vscode.workspace.isTrusted,
    pathCasePolicy: () => pathCasePolicy(process.platform),
    workingCopyExists: workingCopyRootExists,
    onEvent: (event) => {
      void repositoryLifecycleNotifications.handleEvent(event);
    },
  });
  repositoryLifecycleCoordinator = new RepositoryLifecycleCoordinator({
    lifecycleService: repositoryLifecycleService,
    sessionService,
    now: () => new Date().toISOString(),
    onBackendRestartStaleFailure: async (error) => {
      await vscode.window.showErrorMessage(
        vscode.l10n.t(
          "SubversionR could not mark SVN status stale after backend restart: {0}",
          extensionErrorCode(error),
        ),
      );
    },
  });
  const backendTerminationRecovery = service.onDidTerminate(() => {
    void repositoryLifecycleCoordinator.recoverBackendRestartedRepositories()
      .then(async () => {
        const recovery = remoteRecoveryService;
        if (!recovery) {
          throw new Error("SUBVERSIONR_REMOTE_RECOVERY_SERVICE_UNAVAILABLE");
        }
        await redriveRequiredRemoteRecoveries({
          sessions: sessionService,
          store: remoteConnectionStateStore,
          recovery,
          recordFailure: (error) => diagnostics.recordFailure("Remote Recovery", error),
        });
      })
      .catch((error: unknown) => diagnostics.recordFailure("Remote Recovery", error));
  });
  const workspaceTrustGrant = vscode.workspace.onDidGrantWorkspaceTrust(() => {
    void service
      .updateWorkspaceTrust(true)
      .then(async () => {
        refreshWorkspaceTrustUi();
        refreshTortoiseAvailability();
        await repositoryLifecycleCoordinator.reconcileWorkspaceRepositories("workspaceTrust");
      })
      .catch(async (error: unknown) => {
        await vscode.window.showErrorMessage(
          vscode.l10n.t(
            "SubversionR could not acknowledge the Workspace Trust update: {0}",
            extensionErrorCode(error),
          ),
        );
      });
  });
  const workspaceFolderChange = vscode.workspace.onDidChangeWorkspaceFolders(() => {
    void repositoryLifecycleCoordinator.reconcileWorkspaceRepositories("workspaceFolders");
  });
  await repositoryLifecycleCoordinator.reconcileWorkspaceRepositories("activation");
  const diagnosticsDocumentRegistration = vscode.workspace.registerTextDocumentContentProvider(
    DIAGNOSTICS_DOCUMENT_URI_SCHEME,
    diagnosticsDocumentProvider,
  );
  const diagnosticsDocumentLifecycle = vscode.workspace.onDidCloseTextDocument((document) => {
    if (document.uri.scheme === DIAGNOSTICS_DOCUMENT_URI_SCHEME) {
      diagnosticsDocumentProvider.releaseDocument(document.uri);
    }
  });
  const cacheLifecycle = new CacheLifecycleService({
    workspaceState: context.workspaceState,
    storageRoots: cacheStorageRoots(context),
    deleteTree: deleteCacheTree,
    now: () => new Date().toISOString(),
  });
  void cacheLifecycle.ensureCurrentSchema().catch(async (error) => {
    await vscode.window.showErrorMessage(
      vscode.l10n.t("SubversionR cache migration failed: {0}", extensionErrorCode(error)),
    );
  });
  const cacheCommandController = new CacheCommandController({
    cache: cacheLifecycle,
    ui: {
      createReadonlyDocument: (content) => diagnosticsDocumentProvider.createDocument(content),
      openReadonlyDocument: async (uri) => {
        await vscode.commands.executeCommand(
          "vscode.open",
          uri,
          { preview: false },
          vscode.l10n.t("SubversionR Migration Report"),
        );
      },
      showInformationMessage: async (message) => {
        await vscode.window.showInformationMessage(message);
      },
      showErrorMessage: async (message) => {
        await vscode.window.showErrorMessage(message);
      },
    },
    localize: vscode.l10n.t,
  });
  const diagnosticsController = new DiagnosticsCommandController({
    diagnostics: {
      collectDiagnosticsBundle: async () =>
        collectDiagnosticsBundle({
          context: diagnosticsContext(context),
          backendService: service,
          operationJournal,
          watcherOverflowDiagnostics,
        }),
      collectVersionReport: async () =>
        collectVersionReport({
          context: diagnosticsContext(context),
          backendService: service,
        }),
    },
    ui: {
      showSaveDialog: async (defaultFileName) =>
        vscode.window.showSaveDialog({
          defaultUri: defaultDiagnosticsUri(defaultFileName),
          filters: {
            JSON: ["json"],
          },
        }),
      writeFile: async (uri, content) => {
        await vscode.workspace.fs.writeFile(uri as vscode.Uri, content);
      },
      createReadonlyDocument: (content) => diagnosticsDocumentProvider.createDocument(content),
      openReadonlyDocument: async (uri) => {
        await vscode.commands.executeCommand(
          "vscode.open",
          uri,
          { preview: false },
          vscode.l10n.t("SubversionR Version Report"),
        );
      },
      showInformationMessage: async (message) => {
        await vscode.window.showInformationMessage(message);
      },
      showErrorMessage: async (message) => {
        await vscode.window.showErrorMessage(message);
      },
    },
    localize: vscode.l10n.t,
  });

  const initializeCommandHandler = createInitializeCommandHandler({
    initialize: () => service.initialize(),
    onReady: (connection) => {
      operationLogChannel.info(
        vscode.l10n.t("SubversionR backend ready. libsvn: {0}", connection.initializeResult.libsvnVersion),
      );
    },
    recordFailure: (error) => diagnostics.recordFailure("Initialize Backend", error),
    failureMessage: backendStartupMessage,
    showErrorMessage: async (message, action) => await vscode.window.showErrorMessage(message, action),
    showLogAction: vscode.l10n.t("Show Log"),
    showLog: () => diagnostics.show(),
    recordNotificationFailure: (error) => {
      console.error("SubversionR initialize notification failed.", error);
    },
  });
  const initializeCommand = vscode.commands.registerCommand("subversionr.initialize", initializeCommandHandler);
  const collectDiagnosticsCommand = vscode.commands.registerCommand("subversionr.diagnostics.collect", () =>
    diagnosticsController.collectDiagnostics(),
  );
  const versionReportCommand = vscode.commands.registerCommand("subversionr.diagnostics.versionReport", () =>
    diagnosticsController.showVersionReport(),
  );
  const installedRedactionReportToken = consumeInstalledRedactionReportToken();
  const installedRedactionReportCommand =
    installedRedactionReportToken === undefined
      ? undefined
      : vscode.commands.registerCommand("subversionr.diagnostics.installedRedactionReport", (request: unknown) =>
          collectInstalledRedactionReport({
            expectedToken: installedRedactionReportToken,
            request,
            operationDiagnostics: diagnostics,
            collectDiagnosticsBundle: async () =>
              collectDiagnosticsBundle({
                context: diagnosticsContext(context),
                backendService: service,
                operationJournal,
                watcherOverflowDiagnostics,
              }),
          }),
        );
  const installedRemoteWorkerReportToken = consumeInstalledRemoteWorkerReportToken();
  const installedRemoteWorkerReportCommand =
    installedRemoteWorkerReportToken === undefined
      ? undefined
      : vscode.commands.registerCommand("subversionr.diagnostics.installedRemoteWorkerReport", (request: unknown) =>
          collectInstalledRemoteWorkerReport({
            expectedToken: installedRemoteWorkerReportToken,
            request,
            targetPath: nodePath.join(context.globalStorageUri.fsPath, "installed-remote-worker-report-target"),
            initialize: () => service.initialize(),
            collectCredentialLeaseReport: () =>
              collectInstalledCredentialLeaseReport({
                expectedToken: installedRemoteWorkerReportToken,
                request,
                secretStorage,
              }),
          }),
        );
  const installedSvnAnonymousReportCommand =
    installedSvnAnonymousReportToken === undefined
      ? undefined
      : vscode.commands.registerCommand("subversionr.diagnostics.installedSvnAnonymousReport", (request: unknown) =>
          collectInstalledSvnAnonymousReport({
            expectedToken: installedSvnAnonymousReportToken,
            request,
            initialize: () => service.initialize(),
            openWorkingCopy: (path) => sessionService.openWorkingCopy({ path, pathCase: "case-insensitive" }),
            closeRepository: (repositoryId) => sessionService.closeRepository(repositoryId),
            applyRemoteStatusDelta: async (delta) => {
              await dirtyPathPipeline.runExclusive(delta.repositoryId, async () => {
                statusSnapshotStore.applyDelta(delta);
                sourceControlProjection.applyDelta(delta);
              });
            },
            fullReconcile: (repositoryId, epoch) =>
              repositoryRefreshService.fullReconcileRepository({ repositoryId, epoch }),
            getProjection: (repositoryId) => sourceControlProjection.getProjection(repositoryId),
            appendFile: async (path, data) => await appendFile(path, data, { encoding: "utf8" }),
            authActivity: () => ({ ...installedSvnAnonymousAuthActivity }),
          }),
        );
  const installedSvnAnonymousStressCheckoutCommand =
    installedSvnAnonymousStressCheckoutContext === undefined
      ? undefined
      : vscode.commands.registerCommand(
          "subversionr.diagnostics.installedSvnAnonymousStressCheckout",
          (request: unknown) =>
            collectInstalledSvnAnonymousStressCheckout({
              expectedToken: installedSvnAnonymousStressCheckoutContext.token,
              request,
              extensionHostSessionSha256: installedSvnAnonymousStressCheckoutContext.sessionSha256,
              initialize: () => service.initialize(),
              authActivity: () => ({ ...installedSvnAnonymousAuthActivity }),
            }),
        );
  const installedSvnAnonymousNegativeReportCommand =
    installedSvnAnonymousNegativeReportToken === undefined
      ? undefined
      : vscode.commands.registerCommand(
          "subversionr.diagnostics.installedSvnAnonymousNegativeReport",
          (request: unknown) =>
            collectInstalledSvnAnonymousNegativeReport({
              expectedToken: installedSvnAnonymousNegativeReportToken,
              request,
              initialize: () => service.initialize(),
              authActivity: () => ({ ...installedSvnAnonymousAuthActivity }),
            }),
        );
  const installedSvnAnonymousAuthzDeniedReportCommand =
    installedSvnAnonymousAuthzDeniedReportToken === undefined
      ? undefined
      : vscode.commands.registerCommand(
          "subversionr.diagnostics.installedSvnAnonymousAuthzDeniedReport",
          (request: unknown) =>
            collectInstalledSvnAnonymousAuthzDeniedReport({
              expectedToken: installedSvnAnonymousAuthzDeniedReportToken,
              request,
              initialize: () => service.initialize(),
              openWorkingCopy: (path) => sessionService.openWorkingCopy({ path, pathCase: "case-insensitive" }),
              closeRepository: (repositoryId) => sessionService.closeRepository(repositoryId),
              authActivity: () => ({ ...installedSvnAnonymousAuthActivity }),
            }),
        );
  const installedSvnAnonymousStalledReadReportCommand =
    installedSvnAnonymousStalledReadReportToken === undefined
      ? undefined
      : vscode.commands.registerCommand(
          "subversionr.diagnostics.installedSvnAnonymousStalledReadReport",
          (request: unknown) =>
            collectInstalledSvnAnonymousStalledReadReport({
              expectedToken: installedSvnAnonymousStalledReadReportToken,
              request,
              initialize: () => service.initialize(),
              openWorkingCopy: (path) => sessionService.openWorkingCopy({ path, pathCase: "case-insensitive" }),
              closeRepository: (repositoryId) => sessionService.closeRepository(repositoryId),
              authActivity: () => ({ ...installedSvnAnonymousAuthActivity }),
            }),
        );
  const installedSvnAnonymousLocalEventZeroNetworkObserver =
    installedSvnAnonymousLocalEventZeroNetworkToken === undefined
      ? undefined
      : new InstalledSvnAnonymousLocalEventZeroNetworkObserver({
          expectedToken: installedSvnAnonymousLocalEventZeroNetworkToken,
          workspaceTrusted: () => vscode.workspace.isTrusted,
          pathCase: pathCasePolicy(process.platform),
          sessionService,
          watcherService,
          statusRefreshCoverage,
          sourceControlSurface: sourceControlPresenter,
          counters: () => ({
            statusRefreshRequestCount: statusRefreshClient.requestCount(),
            remoteStatusRequestCount,
            reconcileRequestCount,
          }),
          authActivity: () => ({ ...installedSvnAnonymousAuthActivity }),
          collectDiagnostics: async () =>
            await (await service.initialize()).sendRequest<unknown>("diagnostics/get", {}),
        });
  const installedSvnAnonymousLocalEventZeroNetworkArmCommand =
    installedSvnAnonymousLocalEventZeroNetworkObserver === undefined
      ? undefined
      : vscode.commands.registerCommand(
          "subversionr.diagnostics.installedSvnAnonymousLocalEventZeroNetworkArm",
          (request: unknown) => installedSvnAnonymousLocalEventZeroNetworkObserver.arm(request),
        );
  const installedSvnAnonymousLocalEventZeroNetworkReportCommand =
    installedSvnAnonymousLocalEventZeroNetworkObserver === undefined
      ? undefined
      : vscode.commands.registerCommand(
          "subversionr.diagnostics.installedSvnAnonymousLocalEventZeroNetworkReport",
          async (request: unknown) =>
            await installedSvnAnonymousLocalEventZeroNetworkObserver.awaitReport(request),
        );
  const installedCoreWorkflowReportCommand = vscode.commands.registerCommand(
    "subversionr.diagnostics.installedCoreWorkflowReport",
    (request: unknown) =>
      collectInstalledCoreWorkflowEvidence(request, {
        generatedAt: () => new Date().toISOString(),
        extensionVersion: extensionVersion(context),
        pathCasePolicy: () => pathCasePolicy(process.platform),
        workspaceTrusted: () => vscode.workspace.isTrusted,
        sessionService,
        sourceControlProjection,
      }),
  );
  const installedSourceControlSurfaceReportCommand = vscode.commands.registerCommand(
    "subversionr.diagnostics.installedSourceControlSurfaceReport",
    (request: unknown) =>
      collectInstalledSourceControlSurfaceEvidence(request, {
        generatedAt: () => new Date().toISOString(),
        extensionVersion: extensionVersion(context),
        pathCasePolicy: () => pathCasePolicy(process.platform),
        workspaceTrusted: () => vscode.workspace.isTrusted,
        sessionService,
        sourceControlProjection,
        sourceControlSurface: sourceControlPresenter,
      }),
  );
  const installedSourceControlUiE2eOpenReportCommand = vscode.commands.registerCommand(
    "subversionr.diagnostics.installedSourceControlUiE2eOpenReport",
    (request: unknown) =>
      collectInstalledSourceControlUiE2eOpenReport(request, {
        generatedAt: () => new Date().toISOString(),
        extensionVersion: extensionVersion(context),
        pathCasePolicy: () => pathCasePolicy(process.platform),
        workspaceTrusted: () => vscode.workspace.isTrusted,
        sessionService,
        sourceControlProjection,
        sourceControlSurface: sourceControlPresenter,
      }),
  );
  const installedSourceControlUiE2eCurrentSurfaceReportCommand = vscode.commands.registerCommand(
    "subversionr.diagnostics.installedSourceControlUiE2eCurrentSurfaceReport",
    (request: unknown) =>
      collectInstalledSourceControlUiE2eCurrentSurfaceReport(request, {
        generatedAt: () => new Date().toISOString(),
        extensionVersion: extensionVersion(context),
        pathCasePolicy: () => pathCasePolicy(process.platform),
        workspaceTrusted: () => vscode.workspace.isTrusted,
        sessionService,
        sourceControlSurface: sourceControlPresenter,
      }),
  );
  const installedSourceControlUiE2eRepositoryHistoryReportCommand = vscode.commands.registerCommand(
    "subversionr.diagnostics.installedSourceControlUiE2eRepositoryHistoryReport",
    (request: unknown) =>
      collectInstalledRepositoryHistoryReport(request, {
        generatedAt: () => new Date().toISOString(),
        sessionService,
        historySnapshot: () => historyTreeDataProvider.currentSnapshot(),
        historyTreeViewSnapshot: () => {
          const selected = historyTreeView.selection[0];
          return {
            visible: historyTreeView.visible,
            selectionCount: historyTreeView.selection.length,
            selectedTargetLabel: selected?.kind === "target"
              ? historyTreeDataProvider.getTreeItem(selected).label
              : null,
          };
        },
        sourceControlSurface: sourceControlPresenter,
        lastCompletedRefresh: (repositoryId, epoch) =>
          statusRefreshCoverage.getLastCompletedRefresh(repositoryId, epoch),
        operationDiagnostics: diagnostics,
        activity: () => ({
          statusRefreshRequestCount: statusRefreshClient.requestCount(),
          reconcileRequestCount,
          remoteStatusRequestCount,
        }),
      }),
  );
  const installedSourceControlUiE2eFreshnessReportCommand = vscode.commands.registerCommand(
    "subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport",
    (request: unknown) =>
      collectInstalledSourceControlUiE2eFreshnessReport(request, {
        generatedAt: () => new Date().toISOString(),
        sessionService,
        statusSnapshotStore,
        sourceControlProjection,
        statusRefreshCoverage,
        sourceControlSurface: sourceControlPresenter,
      }),
  );
  const installedSourceControlUiE2eMatchingCompletedRefreshCoverageCommand = vscode.commands.registerCommand(
    "subversionr.diagnostics.installedSourceControlUiE2eMatchingCompletedRefreshCoverage",
    (rawRequest: unknown) => {
      const request = parseMatchingCompletedRefreshCoverageRequest(rawRequest);
      return statusRefreshCoverage.getLastCompletedRefreshMatchingTarget(
        request.repositoryId,
        request.epoch,
        request.target,
      );
    },
  );
  const installedSourceControlUiE2eArmFullReconcileCancellationCommand = vscode.commands.registerCommand(
    "subversionr.diagnostics.installedSourceControlUiE2eArmFullReconcileCancellation",
    (request: unknown) => statusRefreshClient.armNextManualFullReconcile(request),
  );
  const installedSourceControlUiE2eFullReconcileCancellationReportCommand = vscode.commands.registerCommand(
    "subversionr.diagnostics.installedSourceControlUiE2eFullReconcileCancellationReport",
    (request: unknown) => statusRefreshClient.report(request),
  );
  const installedSourceControlUiE2eArmDirtyGenerationCancellationCommand = vscode.commands.registerCommand(
    "subversionr.diagnostics.installedSourceControlUiE2eArmDirtyGenerationCancellation",
    (request: unknown) => statusRefreshClient.armNextDirtyGenerationCancellation(request),
  );
  const installedSourceControlUiE2eDirtyGenerationCancellationReportCommand = vscode.commands.registerCommand(
    "subversionr.diagnostics.installedSourceControlUiE2eDirtyGenerationCancellationReport",
    (request: unknown) => statusRefreshClient.dirtyGenerationCancellationReport(request),
  );
  const installedSourceControlUiE2eDirtyEventCommand = vscode.commands.registerCommand(
    "subversionr.diagnostics.installedSourceControlUiE2eDirtyEvent",
    (request: unknown) =>
      recordInstalledSourceControlUiE2eDirtyEvent(request, {
        generatedAt: () => new Date().toISOString(),
        dirtyPathPipeline,
      }),
  );
  const installedSourceControlUiE2eSetInputMessageCommand = vscode.commands.registerCommand(
    "subversionr.diagnostics.installedSourceControlUiE2eSetInputMessage",
    (request: unknown) => setInstalledSourceControlUiE2eInputMessage(request, sourceControlPresenter),
  );
  const installedSourceControlUiE2eShowOutputCommand = vscode.commands.registerCommand(
    "subversionr.diagnostics.installedSourceControlUiE2eShowOutput",
    () => operationLogChannel.show(true),
  );
  const installedSourceControlUiE2eCloseReportCommand = vscode.commands.registerCommand(
    "subversionr.diagnostics.installedSourceControlUiE2eCloseReport",
    (request: unknown) =>
      collectInstalledSourceControlUiE2eCloseReport(request, {
        generatedAt: () => new Date().toISOString(),
        sessionService,
      }),
  );
  const installedSourceControlUiE2eLazyExternalProviderReportCommand = vscode.commands.registerCommand(
    "subversionr.diagnostics.installedSourceControlUiE2eLazyExternalProviderReport",
    (request: unknown) =>
      collectInstalledSourceControlUiE2eLazyExternalProviderReport(request, {
        generatedAt: () => new Date().toISOString(),
        extensionVersion: extensionVersion(context),
        pathCasePolicy: () => pathCasePolicy(process.platform),
        workspaceTrusted: () => vscode.workspace.isTrusted,
        discoveryService: repositoryDiscoveryService,
        sessionService,
        sourceControlSurface: sourceControlPresenter,
      }),
  );
  const installedRepositoryLifecycleReportCommand = vscode.commands.registerCommand(
    "subversionr.diagnostics.installedRepositoryLifecycleReport",
    (request: unknown) =>
      collectInstalledRepositoryLifecycleReport(request, {
        generatedAt: () => new Date().toISOString(),
        extensionVersion: extensionVersion(context),
        pathCasePolicy: () => pathCasePolicy(process.platform),
        workspaceTrusted: () => vscode.workspace.isTrusted,
        lifecycleCoordinator: repositoryLifecycleCoordinator,
      }),
  );
  const clearCacheCommand = vscode.commands.registerCommand("subversionr.cache.clear", () =>
    cacheCommandController.clearCache(),
  );
  const clearSavedCredentialsCommand = vscode.commands.registerCommand("subversionr.credentials.clearSaved", async () =>
    clearSavedCredentials(credentialController),
  );
  const showMigrationReportCommand = vscode.commands.registerCommand("subversionr.migration.showReport", () =>
    cacheCommandController.showMigrationReport(),
  );
  const tortoiseOpenRepositoryLogCommand = vscode.commands.registerCommand(
    "subversionr.tortoise.openRepositoryLog",
    (commandArgument?: unknown) =>
      tortoiseCommandController.openRepositoryLog(
        commitAllRepositoryIdArgument(commandArgument, sourceControlRepositoryIds),
      ),
  );
  const tortoiseOpenResourceLogCommand = vscode.commands.registerCommand(
    "subversionr.tortoise.openResourceLog",
    (...resourceStates: unknown[]) => tortoiseCommandController.openResourceLog(...resourceStates),
  );
  const tortoiseDiffResourceCommand = vscode.commands.registerCommand(
    "subversionr.tortoise.diffResource",
    (...resourceStates: unknown[]) => tortoiseCommandController.diffResource(...resourceStates),
  );
  const tortoiseOpenRevisionGraphCommand = vscode.commands.registerCommand(
    "subversionr.tortoise.openRevisionGraph",
    (commandArgument?: unknown) =>
      tortoiseCommandController.openRepositoryRevisionGraph(
        commitAllRepositoryIdArgument(commandArgument, sourceControlRepositoryIds),
      ),
  );
  const tortoiseOpenRepositoryBrowserCommand = vscode.commands.registerCommand(
    "subversionr.tortoise.openRepositoryBrowser",
    (commandArgument?: unknown) =>
      tortoiseCommandController.openRepositoryBrowser(
        commitAllRepositoryIdArgument(commandArgument, sourceControlRepositoryIds),
      ),
  );
  const tortoiseBlameResourceCommand = vscode.commands.registerCommand(
    "subversionr.tortoise.blameResource",
    (...resourceStates: unknown[]) => tortoiseCommandController.blameResource(...resourceStates),
  );
  const openRepositoryCommand = vscode.commands.registerCommand("subversionr.openRepository", () =>
    repositoryLifecycleCoordinator.runExclusive("manualOpen", () => repositoryCommandController.openRepository()),
  );
  const checkoutRepositoryCommand = vscode.commands.registerCommand("subversionr.checkoutRepository", () =>
    repositoryLifecycleCoordinator.runExclusive("manualCheckout", () => repositoryCommandController.checkoutRepository()),
  );
  const closeRepositoryCommand = vscode.commands.registerCommand("subversionr.closeRepository", (commandArgument?: unknown) =>
    repositoryLifecycleCoordinator.runExclusive("manualClose", () =>
      repositoryCommandController.closeRepository(
        commitAllRepositoryIdArgument(commandArgument, sourceControlRepositoryIds),
      ),
    ),
  );
  const refreshRepositoryCommand = vscode.commands.registerCommand("subversionr.refreshRepository", (commandArgument?: unknown) =>
    repositoryCommandController.refreshRepository(
      commitAllRepositoryIdArgument(commandArgument, sourceControlRepositoryIds),
    ),
  );
  const checkRemoteChangesCommand = vscode.commands.registerCommand("subversionr.checkRemoteChanges", (commandArgument?: unknown) =>
    repositoryCommandController.checkRemoteChanges(
      commitAllRepositoryIdArgument(commandArgument, sourceControlRepositoryIds),
    ),
  );
  const retryRemoteRecoveryCommand = vscode.commands.registerCommand("subversionr.retryRemoteRecovery", (commandArgument?: unknown) =>
    repositoryCommandController.retryRemoteRecovery(
      commitAllRepositoryIdArgument(commandArgument, sourceControlRepositoryIds),
    ),
  );
  const resolveCheckoutTargetRecoveryCommand = vscode.commands.registerCommand(
    "subversionr.resolveCheckoutTargetRecovery",
    async () => {
      const blocked = (await checkoutTargetRecoveryClient.list()).filter(
        (entry): entry is CheckoutTargetRecoveryEntry & { state: "blocked" } => entry.state === "blocked",
      );
      if (blocked.length === 0) {
        await vscode.window.showInformationMessage(
          vscode.l10n.t("No blocked SVN checkout target requires review."),
        );
        return;
      }
      const selected = blocked.length === 1
        ? blocked[0]
        : (await vscode.window.showQuickPick(
            blocked.map((entry) => ({
              label: entry.targetPath,
              description: entry.originOperationId,
              entry,
            })),
            {
              title: vscode.l10n.t("Review blocked SVN checkout target"),
              placeHolder: vscode.l10n.t("Select the checkout target whose disposition you reviewed"),
            },
          ))?.entry;
      if (!selected) {
        return;
      }
      const releaseAction = vscode.l10n.t("Release checkout target block");
      const confirmation = await vscode.window.showWarningMessage(
        vscode.l10n.t(
          "Confirm that you reviewed and resolved the possibly changed SVN checkout target before releasing its safety block: {0}",
          selected.targetPath,
        ),
        { modal: true },
        releaseAction,
      );
      if (confirmation !== releaseAction) {
        return;
      }
      await checkoutTargetRecoveryClient.confirm({
        targetPath: selected.targetPath,
        targetSha256: selected.targetSha256,
        originOperationId: selected.originOperationId,
        confirmation: "reviewedAndResolved",
      });
      await vscode.window.showInformationMessage(
        vscode.l10n.t("SubversionR released the reviewed SVN checkout target: {0}", selected.targetPath),
      );
    },
  );
  void checkoutTargetRecoveryClient
    .list()
    .then(async (entries) => {
      if (!entries.some((entry) => entry.state === "blocked")) {
        return;
      }
      const reviewAction = vscode.l10n.t("Review checkout target");
      const selected = await vscode.window.showWarningMessage(
        vscode.l10n.t("A possibly changed SVN checkout target is blocked until you review its disposition."),
        reviewAction,
      );
      if (selected === reviewAction) {
        await vscode.commands.executeCommand("subversionr.resolveCheckoutTargetRecovery");
      }
    })
    .catch((error: unknown) => diagnostics.recordFailure("Checkout Target Recovery", error));
  const refreshResourceCommand = vscode.commands.registerCommand("subversionr.refreshResource", (...resourceStates: unknown[]) =>
    repositoryCommandController.refreshResource(...resourceStates),
  );
  const openConflictArtifactCommand = vscode.commands.registerCommand(
    "subversionr.openConflictArtifact",
    async (...resourceStateArgs: unknown[]) => {
      const resourceStates =
        resourceStateArgs.length === 1 && Array.isArray(resourceStateArgs[0])
          ? resourceStateArgs[0]
          : resourceStateArgs;
      const resourceUri =
        resourceStates.length === 1
          ? sourceControlPresenter.currentConflictArtifactResourceUri(resourceStates[0])
          : undefined;
      if (!(resourceUri instanceof vscode.Uri) || resourceUri.scheme !== "file") {
        throw new Error(vscode.l10n.t("The SVN conflict artifact is no longer available."));
      }
      await vscode.commands.executeCommand("vscode.open", resourceUri, { preview: true });
    },
  );
  const addResourceCommand = vscode.commands.registerCommand("subversionr.addResource", (...resourceStates: unknown[]) =>
    repositoryCommandController.addResource(...resourceStates),
  );
  const addToIgnoreResourceCommand = vscode.commands.registerCommand(
    "subversionr.addToIgnoreResource",
    (...resourceStates: unknown[]) => repositoryCommandController.addToIgnoreResource(...resourceStates),
  );
  const removeFromIgnoreResourceCommand = vscode.commands.registerCommand(
    "subversionr.removeFromIgnoreResource",
    (...resourceStates: unknown[]) => repositoryCommandController.removeFromIgnoreResource(...resourceStates),
  );
  const setResourceChangelistCommand = vscode.commands.registerCommand(
    "subversionr.setResourceChangelist",
    (...resourceStates: unknown[]) => repositoryCommandController.setResourceChangelist(...resourceStates),
  );
  const clearResourceChangelistCommand = vscode.commands.registerCommand(
    "subversionr.clearResourceChangelist",
    (...resourceStates: unknown[]) => repositoryCommandController.clearResourceChangelist(...resourceStates),
  );
  const lockResourceCommand = vscode.commands.registerCommand("subversionr.lockResource", (...resourceStates: unknown[]) =>
    repositoryCommandController.lockResource(...resourceStates),
  );
  const unlockResourceCommand = vscode.commands.registerCommand("subversionr.unlockResource", (...resourceStates: unknown[]) =>
    repositoryCommandController.unlockResource(...resourceStates),
  );
  const installedSourceControlUiE2eExecuteResourceCommand = isInstalledSourceControlUiE2eRun()
    ? vscode.commands.registerCommand(
        "subversionr.diagnostics.installedSourceControlUiE2eExecuteResourceCommand",
        async (rawRequest: unknown) => {
          const request = parseInstalledSourceControlUiE2eExecuteResourceCommandRequest(rawRequest);
          const resourceState = sourceControlPresenter.currentResourceState(
            request.repositoryId,
            request.epoch,
            request.groupId,
            request.path,
          );
          if (!resourceState) {
            throw installedSourceControlUiE2eResourceCommandError(
              "SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_RESOURCE_TARGET_NOT_CURRENT",
            );
          }
          await vscode.commands.executeCommand(request.command, resourceState);
          return {
            kind: "subversionr.installedSourceControlUiE2eExecuteResourceCommandReport" as const,
            command: request.command,
            repositoryId: request.repositoryId,
            epoch: request.epoch,
            groupId: request.groupId,
            path: request.path,
          };
        },
      )
    : undefined;
  const deleteUnversionedResourceCommand = vscode.commands.registerCommand(
    "subversionr.deleteUnversionedResource",
    (...resourceStates: unknown[]) => repositoryCommandController.deleteUnversionedResource(...resourceStates),
  );
  const deleteAllUnversionedResourcesCommand = vscode.commands.registerCommand(
    "subversionr.deleteAllUnversionedResources",
    (commandArgument?: unknown) => repositoryCommandController.deleteAllUnversionedResources(commandArgument),
  );
  const commitResourceCommand = vscode.commands.registerCommand("subversionr.commitResource", (...resourceStates: unknown[]) =>
    repositoryCommandController.commitResource(...resourceStates),
  );
  const commitAllCommand = vscode.commands.registerCommand("subversionr.commitAll", (commandArgument?: unknown) =>
    repositoryCommandController.commitAll(
      commitAllRepositoryIdArgument(commandArgument, sourceControlRepositoryIds),
    ),
  );
  const pickCommitMessageHistoryCommand = vscode.commands.registerCommand("subversionr.pickCommitMessageHistory", (commandArgument?: unknown) =>
    repositoryCommandController.pickCommitMessageHistory(
      commitAllRepositoryIdArgument(commandArgument, sourceControlRepositoryIds),
    ),
  );
  const reviewCommitCommand = vscode.commands.registerCommand("subversionr.reviewCommit", (commandArgument?: unknown) =>
    repositoryCommandController.reviewCommit(
      commitAllRepositoryIdArgument(commandArgument, sourceControlRepositoryIds),
    ),
  );
  const commitChangelistCommand = vscode.commands.registerCommand("subversionr.commitChangelist", (commandArgument?: unknown) =>
    repositoryCommandController.commitChangelist(commandArgument),
  );
  const revertChangelistCommand = vscode.commands.registerCommand("subversionr.revertChangelist", (commandArgument?: unknown) =>
    repositoryCommandController.revertChangelist(commandArgument),
  );
  const revertAllCommand = vscode.commands.registerCommand("subversionr.revertAll", (commandArgument?: unknown) =>
    repositoryCommandController.revertAll(
      commitAllRepositoryIdArgument(commandArgument, sourceControlRepositoryIds),
    ),
  );
  const removeResourceCommand = vscode.commands.registerCommand("subversionr.removeResource", (...resourceStates: unknown[]) =>
    repositoryCommandController.removeResource(...resourceStates),
  );
  const removeResourceKeepLocalCommand = vscode.commands.registerCommand(
    "subversionr.removeResourceKeepLocal",
    (...resourceStates: unknown[]) => repositoryCommandController.removeResourceKeepLocal(...resourceStates),
  );
  const moveResourceCommand = vscode.commands.registerCommand("subversionr.moveResource", (...resourceStates: unknown[]) =>
    repositoryCommandController.moveResource(...resourceStates),
  );
  const resolveResourceCommand = vscode.commands.registerCommand("subversionr.resolveResource", (...resourceStates: unknown[]) =>
    repositoryCommandController.resolveResource(...resourceStates),
  );
  const resolveAllCommand = vscode.commands.registerCommand("subversionr.resolveAll", (commandArgument?: unknown) =>
    repositoryCommandController.resolveAll(commandArgument),
  );
  const revertResourceCommand = vscode.commands.registerCommand("subversionr.revertResource", (...resourceStates: unknown[]) =>
    repositoryCommandController.revertResource(...resourceStates),
  );
  const cleanupRepositoryCommand = vscode.commands.registerCommand("subversionr.cleanupRepository", (commandArgument?: unknown) =>
    repositoryCommandController.cleanupRepository(
      commitAllRepositoryIdArgument(commandArgument, sourceControlRepositoryIds),
    ),
  );
  const upgradeWorkingCopyCommand = vscode.commands.registerCommand("subversionr.upgradeWorkingCopy", (commandArgument?: unknown) =>
    repositoryCommandController.upgradeWorkingCopy(
      commitAllRepositoryIdArgument(commandArgument, sourceControlRepositoryIds),
    ),
  );
  const updateRepositoryCommand = vscode.commands.registerCommand("subversionr.updateRepository", (commandArgument?: unknown) =>
    repositoryCommandController.updateRepository(
      commitAllRepositoryIdArgument(commandArgument, sourceControlRepositoryIds),
    ),
  );
  const updateToRevisionCommand = vscode.commands.registerCommand("subversionr.updateToRevision", (commandArgument?: unknown) =>
    repositoryCommandController.updateToRevision(
      commitAllRepositoryIdArgument(commandArgument, sourceControlRepositoryIds),
    ),
  );
  const branchCreateRepositoryCommand = vscode.commands.registerCommand("subversionr.branchCreateRepository", (commandArgument?: unknown) =>
    repositoryCommandController.branchCreateRepository(
      commitAllRepositoryIdArgument(commandArgument, sourceControlRepositoryIds),
    ),
  );
  const switchRepositoryCommand = vscode.commands.registerCommand("subversionr.switchRepository", (commandArgument?: unknown) =>
    repositoryCommandController.switchRepository(
      commitAllRepositoryIdArgument(commandArgument, sourceControlRepositoryIds),
    ),
  );
  const relocateRepositoryCommand = vscode.commands.registerCommand("subversionr.relocateRepository", (commandArgument?: unknown) =>
    repositoryCommandController.relocateRepository(
      commitAllRepositoryIdArgument(commandArgument, sourceControlRepositoryIds),
    ),
  );
  const mergeRangeRepositoryCommand = vscode.commands.registerCommand("subversionr.mergeRangeRepository", (commandArgument?: unknown) =>
    repositoryCommandController.mergeRangeRepository(
      commitAllRepositoryIdArgument(commandArgument, sourceControlRepositoryIds),
    ),
  );
  const previewMergeRangeRepositoryCommand = vscode.commands.registerCommand("subversionr.previewMergeRangeRepository", (commandArgument?: unknown) =>
    repositoryCommandController.previewMergeRangeRepository(
      commitAllRepositoryIdArgument(commandArgument, sourceControlRepositoryIds),
    ),
  );
  const showRepositoryMergeinfoCommand = vscode.commands.registerCommand("subversionr.showRepositoryMergeinfo", (commandArgument?: unknown) =>
    repositoryCommandController.showRepositoryMergeinfo(
      commitAllRepositoryIdArgument(commandArgument, sourceControlRepositoryIds),
    ),
  );
  const showRepositoryPropertiesCommand = vscode.commands.registerCommand("subversionr.showRepositoryProperties", (commandArgument?: unknown) =>
    repositoryCommandController.showRepositoryProperties(
      commitAllRepositoryIdArgument(commandArgument, sourceControlRepositoryIds),
    ),
  );
  const showResourceMergeinfoCommand = vscode.commands.registerCommand("subversionr.showResourceMergeinfo", (...resourceStates: unknown[]) =>
    repositoryCommandController.showResourceMergeinfo(...resourceStates),
  );
  const showResourcePropertiesCommand = vscode.commands.registerCommand("subversionr.showResourceProperties", (...resourceStates: unknown[]) =>
    repositoryCommandController.showResourceProperties(...resourceStates),
  );
  const setResourcePropertyCommand = vscode.commands.registerCommand("subversionr.setResourceProperty", (...resourceStates: unknown[]) =>
    repositoryCommandController.setResourceProperty(...resourceStates),
  );
  const deleteResourcePropertyCommand = vscode.commands.registerCommand("subversionr.deleteResourceProperty", (...resourceStates: unknown[]) =>
    repositoryCommandController.deleteResourceProperty(...resourceStates),
  );
  const editRepositoryExternalsCommand = vscode.commands.registerCommand("subversionr.editRepositoryExternals", (commandArgument?: unknown) =>
    repositoryCommandController.editRepositoryExternals(
      commitAllRepositoryIdArgument(commandArgument, sourceControlRepositoryIds),
    ),
  );
  const editResourceExternalsCommand = vscode.commands.registerCommand("subversionr.editResourceExternals", (...resourceStates: unknown[]) =>
    repositoryCommandController.editResourceExternals(...resourceStates),
  );
  const updateResourceCommand = vscode.commands.registerCommand("subversionr.updateResource", (...resourceStates: unknown[]) =>
    repositoryCommandController.updateResource(...resourceStates),
  );
  const updateAllIncomingCommand = vscode.commands.registerCommand("subversionr.updateAllIncoming", (commandArgument?: unknown) =>
    repositoryCommandController.updateAllIncoming(commandArgument),
  );
  const diffWithBaseCommand = vscode.commands.registerCommand("subversionr.diffWithBase", (...resourceStates: unknown[]) =>
    repositoryCommandController.diffWithBaseResource(...resourceStates),
  );
  const openBaseCommand = vscode.commands.registerCommand("subversionr.openBase", (...resourceStates: unknown[]) =>
    repositoryCommandController.openBaseResource(...resourceStates),
  );
  const diffWithHeadCommand = vscode.commands.registerCommand("subversionr.diffWithHead", (...resourceStates: unknown[]) =>
    repositoryCommandController.diffWithHeadResource(...resourceStates),
  );
  const openHeadCommand = vscode.commands.registerCommand("subversionr.openHead", (...resourceStates: unknown[]) =>
    repositoryCommandController.openHeadResource(...resourceStates),
  );
  const diffWithPreviousCommand = vscode.commands.registerCommand("subversionr.diffWithPrevious", (...resourceStates: unknown[]) =>
    repositoryCommandController.diffWithPreviousResource(...resourceStates),
  );
  const diffWithHeadAliasCommands = HEAD_DIFF_LEGACY_ALIASES.map((command) =>
    vscode.commands.registerCommand(command, (...resourceStates: unknown[]) =>
      repositoryCommandController.diffWithHeadResource(...resourceStates),
    ),
  );
  const openHeadAliasCommands = HEAD_OPEN_LEGACY_ALIASES.map((command) =>
    vscode.commands.registerCommand(command, (...resourceStates: unknown[]) =>
      repositoryCommandController.openHeadResource(...resourceStates),
    ),
  );
  const diffWithPreviousAliasCommands = PREVIOUS_DIFF_LEGACY_ALIASES.map((command) =>
    vscode.commands.registerCommand(command, (...resourceStates: unknown[]) =>
      repositoryCommandController.diffWithPreviousResource(...resourceStates),
    ),
  );
  const showRepositoryLogCommand = vscode.commands.registerCommand("subversionr.showRepositoryLog", (commandArgument?: unknown) =>
    repositoryCommandController.showRepositoryLog(
      repositoryHistoryCommandArgument(commandArgument, sourceControlRepositoryHistoryTargets),
    ),
  );
  const showFileHistoryCommand = vscode.commands.registerCommand("subversionr.showFileHistory", (...resourceStates: unknown[]) =>
    repositoryCommandController.showFileHistoryResource(...resourceStates),
  );
  const showLineHistoryCommand = vscode.commands.registerCommand("subversionr.showLineHistory", () =>
    lineHistoryCommandController.showLineHistory(),
  );
  const showBlameCommand = vscode.commands.registerCommand("subversionr.showBlame", (...resourceStates: unknown[]) =>
    repositoryCommandController.showBlameResource(...resourceStates),
  );
  const historyRefreshCommand = vscode.commands.registerCommand("subversionr.history.refresh", () =>
    runHistoryCommand(() => historyTreeDataProvider.refresh()),
  );
  const historySearchCommand = vscode.commands.registerCommand("subversionr.history.searchLoaded", () =>
    runHistoryCommand(() => searchHistoryLoaded(historyTreeDataProvider, historyTreeView)),
  );
  const historyLoadMoreCommand = vscode.commands.registerCommand("subversionr.history.loadMore", () =>
    runHistoryCommand(() => historyTreeDataProvider.loadMore()),
  );
  const historyOpenRevisionCommand = vscode.commands.registerCommand(
    "subversionr.history.openRevision",
    (element: unknown) => runHistoryCommand(() => openRevisionContent(historyTreeDataProvider, element)),
  );
  const historyCompareWithPreviousCommand = vscode.commands.registerCommand(
    "subversionr.history.compareWithPrevious",
    (element: unknown) => runHistoryCommand(() => compareHistoryRevisionWithPrevious(historyTreeDataProvider, element)),
  );
  const historyCompareRevisionsCommand = vscode.commands.registerCommand(
    "subversionr.history.compareRevisions",
    (element: unknown, selectedElements: unknown) =>
      runHistoryCommand(() => compareHistoryRevisions(historyTreeDataProvider, element, selectedElements)),
  );
  const historyOpenRevisionDetailsCommand = vscode.commands.registerCommand(
    "subversionr.history.openRevisionDetails",
    (element: unknown) =>
      runHistoryCommand(() => openRevisionDetails(historyTreeDataProvider, revisionDetailsStore, element)),
  );
  const historyCopyMessageCommand = vscode.commands.registerCommand("subversionr.history.copyMessage", (element: unknown) =>
    runHistoryCommand(() => copyHistoryMessage(historyTreeDataProvider, element)),
  );
  const historyCopyRevisionCommand = vscode.commands.registerCommand("subversionr.history.copyRevision", (element: unknown) =>
    runHistoryCommand(() => copyHistoryRevision(historyTreeDataProvider, element)),
  );
  // Explicitly reviewed legacy command aliases; public scope is recorded in the M5 plan.
  const historyCopyMessageAliasCommands = HISTORY_COPY_MESSAGE_LEGACY_ALIASES.map((command) =>
    vscode.commands.registerCommand(command, (element: unknown) =>
      runHistoryCommand(() => copyHistoryMessage(historyTreeDataProvider, element)),
    ),
  );
  const historyCopyRevisionAliasCommands = HISTORY_COPY_REVISION_LEGACY_ALIASES.map((command) =>
    vscode.commands.registerCommand(command, (element: unknown) =>
      runHistoryCommand(() => copyHistoryRevision(historyTreeDataProvider, element)),
    ),
  );
  const historyCompareRevisionsAliasCommands = HISTORY_COMPARE_REVISIONS_LEGACY_ALIASES.map((command) =>
    vscode.commands.registerCommand(command, (element: unknown, selectedElements: unknown) =>
      runHistoryCommand(() => compareHistoryRevisions(historyTreeDataProvider, element, selectedElements)),
    ),
  );
  const historySearchAliasCommands = HISTORY_SEARCH_LEGACY_ALIASES.map((command) =>
    vscode.commands.registerCommand(command, () =>
      runHistoryCommand(() => searchHistoryLoaded(historyTreeDataProvider, historyTreeView)),
    ),
  );
  const fullReconcileCommand = vscode.commands.registerCommand("subversionr.fullReconcile", (commandArgument?: unknown) =>
    repositoryCommandController.fullReconcileRepository(
      commitAllRepositoryIdArgument(commandArgument, sourceControlRepositoryIds),
    ),
  );

  context.subscriptions.push(
    operationLogChannel,
    initializeCommand,
    baseContentDocumentProvider,
    headContentDocumentProvider,
    revisionContentDocumentProvider,
    blameDocumentProvider,
    revisionDetailsDocumentProvider,
    revisionDetailsDocumentLifecycle,
    fileHeaderCodeLensProvider,
    symbolHistoryCodeLensProvider,
    backendLifecycleUiService,
    currentLineBlameStatusBarService,
    fileHeaderCodeLensRegistration,
    symbolHistoryCodeLensRegistration,
    currentLineBlameHoverRegistration,
    lensConfigurationChange,
    historyConfigurationChange,
    statusConfigurationChange,
    projectionCodeLensRefresh,
    sessionCodeLensRefresh,
    activeEditorChange,
    currentLineBlameActiveEditorChange,
    workspaceTrustGrant,
    workspaceFolderChange,
    tortoiseConfigurationChange,
    backendTerminationRecovery,
    currentLineBlameSelectionChange,
    currentLineBlameDocumentChange,
    projectionActiveEditorRefresh,
    sessionActiveEditorRefresh,
    projectionCurrentLineBlameRefresh,
    sessionCurrentLineBlameRefresh,
    historyTreeDataProvider,
    historyTreeView,
    diagnosticsDocumentProvider,
    diagnosticsDocumentRegistration,
    diagnosticsDocumentLifecycle,
    collectDiagnosticsCommand,
    versionReportCommand,
    installedCoreWorkflowReportCommand,
    installedSourceControlSurfaceReportCommand,
    installedSourceControlUiE2eOpenReportCommand,
    installedSourceControlUiE2eCurrentSurfaceReportCommand,
    installedSourceControlUiE2eRepositoryHistoryReportCommand,
    installedSourceControlUiE2eFreshnessReportCommand,
    installedSourceControlUiE2eMatchingCompletedRefreshCoverageCommand,
    installedSourceControlUiE2eArmFullReconcileCancellationCommand,
    installedSourceControlUiE2eFullReconcileCancellationReportCommand,
    installedSourceControlUiE2eArmDirtyGenerationCancellationCommand,
    installedSourceControlUiE2eDirtyGenerationCancellationReportCommand,
    installedSourceControlUiE2eDirtyEventCommand,
    installedSourceControlUiE2eSetInputMessageCommand,
    installedSourceControlUiE2eShowOutputCommand,
    installedSourceControlUiE2eCloseReportCommand,
    installedSourceControlUiE2eLazyExternalProviderReportCommand,
    installedRepositoryLifecycleReportCommand,
    clearCacheCommand,
    clearSavedCredentialsCommand,
    showMigrationReportCommand,
    tortoiseOpenRepositoryLogCommand,
    tortoiseOpenResourceLogCommand,
    tortoiseDiffResourceCommand,
    tortoiseOpenRevisionGraphCommand,
    tortoiseOpenRepositoryBrowserCommand,
    tortoiseBlameResourceCommand,
    openRepositoryCommand,
    checkoutRepositoryCommand,
    closeRepositoryCommand,
    refreshRepositoryCommand,
    checkRemoteChangesCommand,
    retryRemoteRecoveryCommand,
    resolveCheckoutTargetRecoveryCommand,
    refreshResourceCommand,
    openConflictArtifactCommand,
    addResourceCommand,
    addToIgnoreResourceCommand,
    removeFromIgnoreResourceCommand,
    setResourceChangelistCommand,
    clearResourceChangelistCommand,
    lockResourceCommand,
    unlockResourceCommand,
    deleteUnversionedResourceCommand,
    deleteAllUnversionedResourcesCommand,
    commitResourceCommand,
    commitAllCommand,
    pickCommitMessageHistoryCommand,
    reviewCommitCommand,
    commitChangelistCommand,
    revertChangelistCommand,
    revertAllCommand,
    removeResourceCommand,
    removeResourceKeepLocalCommand,
    moveResourceCommand,
    resolveResourceCommand,
    resolveAllCommand,
    revertResourceCommand,
    cleanupRepositoryCommand,
    upgradeWorkingCopyCommand,
    updateRepositoryCommand,
    updateToRevisionCommand,
    branchCreateRepositoryCommand,
    switchRepositoryCommand,
    relocateRepositoryCommand,
    mergeRangeRepositoryCommand,
    previewMergeRangeRepositoryCommand,
    showRepositoryMergeinfoCommand,
    showRepositoryPropertiesCommand,
    showResourceMergeinfoCommand,
    showResourcePropertiesCommand,
    setResourcePropertyCommand,
    deleteResourcePropertyCommand,
    editRepositoryExternalsCommand,
    editResourceExternalsCommand,
    updateResourceCommand,
    updateAllIncomingCommand,
    diffWithBaseCommand,
    openBaseCommand,
    diffWithHeadCommand,
    openHeadCommand,
    diffWithPreviousCommand,
    ...diffWithHeadAliasCommands,
    ...openHeadAliasCommands,
    ...diffWithPreviousAliasCommands,
    showRepositoryLogCommand,
    showFileHistoryCommand,
    showLineHistoryCommand,
    showBlameCommand,
    historyRefreshCommand,
    historySearchCommand,
    historyLoadMoreCommand,
    historyOpenRevisionCommand,
    historyCompareWithPreviousCommand,
    historyCompareRevisionsCommand,
    historyOpenRevisionDetailsCommand,
    historyCopyMessageCommand,
    historyCopyRevisionCommand,
    ...historyCopyMessageAliasCommands,
    ...historyCopyRevisionAliasCommands,
    ...historyCompareRevisionsAliasCommands,
    ...historySearchAliasCommands,
    fullReconcileCommand,
  );
  if (installedRedactionReportCommand !== undefined) {
    context.subscriptions.push(installedRedactionReportCommand);
  }
  if (installedRemoteWorkerReportCommand !== undefined) {
    context.subscriptions.push(installedRemoteWorkerReportCommand);
  }
  if (installedSvnAnonymousReportCommand !== undefined) {
    context.subscriptions.push(installedSvnAnonymousReportCommand);
  }
  if (installedSvnAnonymousStressCheckoutCommand !== undefined) {
    context.subscriptions.push(installedSvnAnonymousStressCheckoutCommand);
  }
  if (installedSvnAnonymousNegativeReportCommand !== undefined) {
    context.subscriptions.push(installedSvnAnonymousNegativeReportCommand);
  }
  if (installedSvnAnonymousAuthzDeniedReportCommand !== undefined) {
    context.subscriptions.push(installedSvnAnonymousAuthzDeniedReportCommand);
  }
  if (installedSvnAnonymousStalledReadReportCommand !== undefined) {
    context.subscriptions.push(installedSvnAnonymousStalledReadReportCommand);
  }
  if (
    installedSvnAnonymousLocalEventZeroNetworkObserver !== undefined &&
    installedSvnAnonymousLocalEventZeroNetworkArmCommand !== undefined &&
    installedSvnAnonymousLocalEventZeroNetworkReportCommand !== undefined
  ) {
    context.subscriptions.push(
      installedSvnAnonymousLocalEventZeroNetworkObserver,
      installedSvnAnonymousLocalEventZeroNetworkArmCommand,
      installedSvnAnonymousLocalEventZeroNetworkReportCommand,
    );
  }
  if (installedSourceControlUiE2eExecuteResourceCommand !== undefined) {
    context.subscriptions.push(installedSourceControlUiE2eExecuteResourceCommand);
  }
}

async function runHistoryCommand(command: () => Promise<void>): Promise<void> {
  try {
    await command();
  } catch (error) {
    operationDiagnostics?.recordFailure("History", error);
    const showLog = vscode.l10n.t("Show Log");
    const retry = vscode.l10n.t("Retry");
    const selected = await vscode.window.showErrorMessage(historyFailureMessage(error), showLog, retry);
    if (selected === showLog) {
      operationDiagnostics?.show();
    } else if (selected === retry) {
      await runHistoryCommand(command);
    }
  }
}

function historyFailureMessage(error: unknown): string {
  const credentialMessage = credentialOperationFailureMessage(error, vscode.l10n.t("History"));
  if (credentialMessage !== undefined) {
    return credentialMessage;
  }
  const cause = extensionOperationFailureCause(error);
  switch (cause) {
    case "authenticationFailed":
      return vscode.l10n.t("SVN {0} failed because authentication was rejected. Check the credentials and retry.", vscode.l10n.t("History"));
    case "authorizationDenied":
      return vscode.l10n.t("SVN {0} failed because the server denied authorization for this operation.", vscode.l10n.t("History"));
    case "authorizationConfigurationInvalid":
      return vscode.l10n.t("SVN {0} failed because the server authorization configuration is invalid.", vscode.l10n.t("History"));
    case "notWorkingCopy":
      return vscode.l10n.t("SVN {0} failed because the selected target is not a working copy.", vscode.l10n.t("History"));
    default:
      return vscode.l10n.t("SVN {0} failed. Open the SubversionR log for details.", vscode.l10n.t("History"));
  }
}

function credentialOperationFailureMessage(error: unknown, operation: string): string | undefined {
  switch (extensionErrorCode(error)) {
    case "SUBVERSIONR_CREDENTIAL_CANCELLED":
      return vscode.l10n.t("SVN {0} credential entry was cancelled.", operation);
    case "SUBVERSIONR_CREDENTIAL_TIMEOUT":
    case "SUBVERSIONR_CREDENTIAL_LEASE_EXPIRED":
      return vscode.l10n.t("SVN {0} authentication timed out. Retry the operation.", operation);
    case "SUBVERSIONR_CREDENTIAL_STORAGE_INTEGRITY":
      return vscode.l10n.t(
        "SubversionR blocked SVN {0} because saved credential storage failed an integrity check. Clear saved credentials before retrying.",
        operation,
      );
    case "SUBVERSIONR_CREDENTIAL_LEGACY_BLOCKED":
    case "SUBVERSIONR_CREDENTIAL_LEGACY_CLEAR_DECLINED":
      return vscode.l10n.t(
        "SubversionR blocked SVN {0} because legacy saved credentials must be cleared first. Run Clear Saved Credentials and retry.",
        operation,
      );
    case "SUBVERSIONR_CREDENTIAL_SECRET_INVALID":
      return vscode.l10n.t("Enter a non-empty SVN password no larger than 32768 UTF-8 bytes and retry {0}.", operation);
    case "SUBVERSIONR_CREDENTIAL_RETRY_INVALID":
    case "SUBVERSIONR_CREDENTIAL_LEASE_UNKNOWN":
    case "SUBVERSIONR_CREDENTIAL_LEASE_FOREIGN":
    case "SUBVERSIONR_CREDENTIAL_SETTLEMENT_CONFLICT":
      return vscode.l10n.t("SubversionR rejected an invalid SVN credential exchange for {0}. Retry the operation.", operation);
    default:
      return undefined;
  }
}

function extensionOperationFailureCause(error: unknown): string | undefined {
  if (typeof error !== "object" || error === null || !("diagnostics" in error)) {
    return undefined;
  }
  const diagnostics = (error as { diagnostics?: unknown }).diagnostics;
  if (typeof diagnostics !== "object" || diagnostics === null || !("cause" in diagnostics)) {
    return undefined;
  }
  const cause = (diagnostics as { cause?: unknown }).cause;
  return typeof cause === "string" ? cause : undefined;
}

async function clearSavedCredentials(credentialController: CredentialController): Promise<void> {
  try {
    const result = await credentialController.clearSavedCredentials();
    if (result.deleted === 0) {
      await vscode.window.showInformationMessage(vscode.l10n.t("SubversionR has no saved SVN credentials to clear."));
      return;
    }
    await vscode.window.showInformationMessage(
      vscode.l10n.t("SubversionR cleared {0} saved SVN credential(s).", result.deleted),
    );
  } catch (error) {
    await vscode.window.showErrorMessage(
      vscode.l10n.t("SubversionR could not clear saved SVN credentials: {0}", extensionErrorCode(error)),
    );
  }
}

async function pickCredentialAccount(
  request: CredentialRequest,
  storedAccounts: readonly string[],
): Promise<string | undefined> {
  const useAnother = vscode.l10n.t("Use another SVN account");
  const items: Array<vscode.QuickPickItem & { username?: string }> = [
    ...storedAccounts.map((username) => ({ label: username, username })),
    { label: useAnother },
  ];
  const selected = await withCredentialCancellation(request.timeoutMs, (token) =>
    vscode.window.showQuickPick(
      items,
      { placeHolder: vscode.l10n.t("Choose an SVN account for {0}", credentialEndpointLabel(request)) },
      token,
    ),
  );
  if (!selected) {
    return undefined;
  }
  if (selected.username !== undefined) {
    return selected.username;
  }
  return await showCredentialInputBox(request, {
    title: vscode.l10n.t("SVN Account"),
    prompt: vscode.l10n.t("Username for SVN server {0}", credentialEndpointLabel(request)),
    ignoreFocusOut: true,
  });
}

async function pickCredentialPersistence(
  request: CredentialRequest,
): Promise<CredentialPersistenceIntent | undefined> {
  const items: Array<vscode.QuickPickItem & { persistence: CredentialPersistenceIntent }> = [
    {
      label: vscode.l10n.t("Save in VS Code Secret Storage"),
      persistence: "secretStorage",
    },
    {
      label: vscode.l10n.t("Use for this session only"),
      persistence: "session",
    },
  ];
  const selected = await withCredentialCancellation(request.timeoutMs, (token) =>
    vscode.window.showQuickPick(
      items,
      {
        placeHolder: vscode.l10n.t("Choose how SubversionR should store this SVN credential"),
      },
      token,
    ),
  );
  return selected?.persistence;
}

async function showCredentialInputBox(
  request: CredentialRequest,
  options: vscode.InputBoxOptions,
): Promise<string | undefined> {
  return await withCredentialCancellation(request.timeoutMs, (token) => vscode.window.showInputBox(options, token));
}

function credentialSecretPrompt(request: CredentialRequest, username: string): string {
  return vscode.l10n.t("Password for SVN user {0} at {1}", username, credentialEndpointLabel(request));
}

function credentialEndpointLabel(request: CredentialRequest): string {
  return `${request.endpoint.scheme}://${request.endpoint.canonicalHost}:${request.endpoint.effectivePort}`;
}

async function confirmLegacyCredentialClear(_request: CredentialRequest, entryCount: number): Promise<boolean> {
  const clear = vscode.l10n.t("Clear Legacy Credentials");
  const selected = await vscode.window.showWarningMessage(
    vscode.l10n.t(
      "SubversionR found {0} legacy saved SVN credential(s). They must be cleared before remote password authentication can continue.",
      entryCount,
    ),
    { modal: true },
    clear,
  );
  return selected === clear;
}

async function pickCertificateTrust(
  request: CertificateTrustRequest,
): Promise<CertificateTrustDecision | undefined> {
  const details = certificateTrustDetails(request);
  const items: Array<vscode.QuickPickItem & { trust: CertificateTrustDecision }> = [
    {
      label: vscode.l10n.t("Reject"),
      trust: "reject",
      detail: details,
    },
    {
      label: vscode.l10n.t("Trust Once"),
      trust: "once",
      detail: details,
    },
  ];
  if (request.persistenceAllowed) {
    items.push({
      label: vscode.l10n.t("Trust Permanently"),
      trust: "permanent",
      detail: details,
    });
  }

  const selected = await withCertificateCancellation(request.timeoutMs, (token) =>
    vscode.window.showQuickPick(
      items,
      {
        title: vscode.l10n.t("SVN Server Certificate"),
        placeHolder: vscode.l10n.t("SVN server certificate for {0} failed validation.", request.host),
        ignoreFocusOut: true,
      },
      token,
    ),
  );
  return selected?.trust;
}

function certificateTrustDetails(request: CertificateTrustRequest): string {
  return [
    vscode.l10n.t("Fingerprint: {0} ({1})", request.fingerprint, request.fingerprintAlgorithm),
    vscode.l10n.t("Valid from {0} until {1}", request.validFrom, request.validTo),
    vscode.l10n.t("Certificate failures: {0}", request.failures.join(", ")),
    request.issuer ? vscode.l10n.t("Issuer: {0}", request.issuer) : undefined,
    request.subject ? vscode.l10n.t("Subject: {0}", request.subject) : undefined,
  ]
    .filter((line): line is string => line !== undefined)
    .join("\n");
}

async function withCertificateCancellation<T>(
  timeoutMs: number,
  run: (token: vscode.CancellationToken) => Thenable<T>,
): Promise<T> {
  return await withCredentialCancellation(timeoutMs, run);
}

async function runOperationWithProgress<T>(
  title: string,
  run: (signal: AbortSignal) => Promise<T>,
): Promise<T> {
  return await vscode.window.withProgress(
    {
      location: vscode.ProgressLocation.Notification,
      title,
      cancellable: true,
    },
    async (_progress, token) => {
      const cancellation = new AbortController();
      if (token.isCancellationRequested) {
        cancellation.abort();
      }
      const subscription = token.onCancellationRequested(() => {
        cancellation.abort();
      });
      try {
        return await run(cancellation.signal);
      } finally {
        subscription.dispose();
      }
    },
  );
}

async function withCredentialCancellation<T>(
  timeoutMs: number,
  run: (token: vscode.CancellationToken) => Thenable<T>,
): Promise<T> {
  const cancellation = new vscode.CancellationTokenSource();
  const timer = setTimeout(() => cancellation.cancel(), Math.max(timeoutMs, 0));
  try {
    return await run(cancellation.token);
  } finally {
    clearTimeout(timer);
    cancellation.dispose();
  }
}

async function openRevisionContent(
  historyTreeDataProvider: HistoryTreeDataProvider,
  element: unknown,
): Promise<void> {
  const uri = vscode.Uri.from(historyOpenRevisionUriComponents(historyTreeDataProvider.openRevisionTarget(element)));
  const document = await vscode.workspace.openTextDocument(uri);
  await vscode.window.showTextDocument(document, { preview: false });
}

async function compareHistoryRevisionWithPrevious(
  historyTreeDataProvider: HistoryTreeDataProvider,
  element: unknown,
): Promise<void> {
  const comparison = historyCompareRevisionUriComponents(historyTreeDataProvider.compareRevisionTarget(element));
  await vscode.commands.executeCommand(
    "vscode.diff",
    vscode.Uri.from(comparison.left),
    vscode.Uri.from(comparison.right),
    vscode.l10n.t("SVN Revision Compare: {0}", comparison.label),
  );
}

async function compareHistoryRevisions(
  historyTreeDataProvider: HistoryTreeDataProvider,
  element: unknown,
  selectedElements: unknown,
): Promise<void> {
  const comparison = historyCompareRevisionUriComponents(
    historyTreeDataProvider.compareRevisionsTarget(element, selectedElements),
  );
  await vscode.commands.executeCommand(
    "vscode.diff",
    vscode.Uri.from(comparison.left),
    vscode.Uri.from(comparison.right),
    vscode.l10n.t("SVN Revision Compare: {0}", comparison.label),
  );
}

async function searchHistoryLoaded(
  historyTreeDataProvider: HistoryTreeDataProvider,
  historyTreeView: vscode.TreeView<unknown>,
): Promise<void> {
  await searchLoadedHistory(historyTreeDataProvider, {
    showInputBox: async (options) => vscode.window.showInputBox(options),
    setTreeMessage: (message) => {
      historyTreeView.message = message;
    },
    localize: vscode.l10n.t,
  });
}

async function openRevisionDetails(
  historyTreeDataProvider: HistoryTreeDataProvider,
  revisionDetailsStore: HistoryRevisionDetailsDocumentStore,
  element: unknown,
): Promise<void> {
  const target = historyTreeDataProvider.revisionDetailsTarget(element);
  const uri = vscode.Uri.from(revisionDetailsStore.createDocumentUri(target));
  await vscode.commands.executeCommand(
    "vscode.open",
    uri,
    { preview: false },
    vscode.l10n.t("SVN Revision Details: {0}", target.revision),
  );
}

async function copyHistoryMessage(historyTreeDataProvider: HistoryTreeDataProvider, element: unknown): Promise<void> {
  await copyHistoryCommitMessage(historyTreeDataProvider, element, {
    writeText: async (value) => {
      await vscode.env.clipboard.writeText(value);
    },
    showInformationMessage: async (message) => {
      await vscode.window.showInformationMessage(message);
    },
    localize: vscode.l10n.t,
  });
}

async function copyHistoryRevision(historyTreeDataProvider: HistoryTreeDataProvider, element: unknown): Promise<void> {
  await copyHistoryRevisionNumber(historyTreeDataProvider, element, {
    writeText: async (value) => {
      await vscode.env.clipboard.writeText(value);
    },
    showInformationMessage: async (message) => {
      await vscode.window.showInformationMessage(message);
    },
    localize: vscode.l10n.t,
  });
}

async function workingCopyRootExists(path: string): Promise<boolean> {
  const e2eMissingWorkingCopyRoot = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_MISSING_WORKING_COPY_ROOT;
  if (
    isInstalledSourceControlUiE2eRun() &&
    typeof e2eMissingWorkingCopyRoot === "string" &&
    e2eMissingWorkingCopyRoot.trim().length > 0 &&
    normalizedFsPath(e2eMissingWorkingCopyRoot) === normalizedFsPath(path)
  ) {
    return false;
  }
  try {
    await vscode.workspace.fs.stat(vscode.Uri.file(path));
    return true;
  } catch (error) {
    if (isFileNotFoundError(error)) {
      return false;
    }
    throw error;
  }
}

function workspaceRootsWithInstalledSourceControlUiE2eExtra(): string[] {
  const roots = (vscode.workspace.workspaceFolders ?? []).map((folder) => folder.uri.fsPath);
  const extraRoot = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_EXTRA_WORKSPACE_ROOT;
  if (isInstalledSourceControlUiE2eRun() && typeof extraRoot === "string" && extraRoot.trim().length > 0) {
    return [...roots, extraRoot];
  }
  return roots;
}

function isInstalledSourceControlUiE2eRun(): boolean {
  const resultPath = process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_RESULT;
  return typeof resultPath === "string" && resultPath.trim().length > 0;
}

function setInstalledSourceControlUiE2eInputMessage(
  rawRequest: unknown,
  sourceControlPresenter: Pick<VscodeSourceControlPresenter, "setCommitMessage" | "commitMessage">,
): {
  kind: "subversionr.installedSourceControlUiE2eSetInputMessageReport";
  repositoryId: string;
  previousMessageLength: number;
  messageLength: number;
  inputMessageSet: true;
} {
  if (!isInstalledSourceControlUiE2eRun()) {
    throw new Error("SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_REQUIRED");
  }
  if (typeof rawRequest !== "object" || rawRequest === null || Array.isArray(rawRequest)) {
    throw new Error("SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SET_INPUT_REQUEST_INVALID");
  }
  const request = rawRequest as Record<string, unknown>;
  const fields = Object.keys(request);
  if (
    fields.length !== 2 ||
    !Object.prototype.hasOwnProperty.call(request, "repositoryId") ||
    !Object.prototype.hasOwnProperty.call(request, "message") ||
    typeof request.repositoryId !== "string" ||
    request.repositoryId.trim().length === 0 ||
    typeof request.message !== "string" ||
    request.message.trim().length === 0
  ) {
    throw new Error("SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SET_INPUT_REQUEST_INVALID");
  }
  const previousMessage = sourceControlPresenter.commitMessage(request.repositoryId);
  sourceControlPresenter.setCommitMessage(request.repositoryId, request.message);
  if (sourceControlPresenter.commitMessage(request.repositoryId) !== request.message) {
    throw new Error("SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_SET_INPUT_MESSAGE_MISMATCH");
  }
  return {
    kind: "subversionr.installedSourceControlUiE2eSetInputMessageReport",
    repositoryId: request.repositoryId,
    previousMessageLength: previousMessage.length,
    messageLength: request.message.length,
    inputMessageSet: true,
  };
}

function cacheRootPath(context: vscode.ExtensionContext): string {
  return vscode.Uri.joinPath(context.globalStorageUri, "cache").fsPath;
}

function remoteStateRootPath(context: vscode.ExtensionContext): string {
  return vscode.Uri.joinPath(context.globalStorageUri, "remote-state").fsPath;
}

function cacheStorageRoots(context: vscode.ExtensionContext): CacheStorageRoot[] {
  const roots: CacheStorageRoot[] = [];
  if (context.storageUri !== undefined) {
    roots.push({
      scope: "workspace",
      uri: vscode.Uri.joinPath(context.storageUri, "cache"),
    });
  }
  roots.push({
    scope: "global",
    uri: vscode.Uri.joinPath(context.globalStorageUri, "cache"),
  });
  return roots;
}

async function deleteCacheTree(uri: CacheUri): Promise<CacheClearStatus> {
  const vscodeUri = cacheVscodeUri(uri);
  try {
    await vscode.workspace.fs.delete(vscodeUri, { recursive: true, useTrash: false });
    return "deleted";
  } catch (error) {
    if (isFileNotFoundError(error)) {
      return "missing";
    }
    throw error;
  }
}

function cacheVscodeUri(uri: CacheUri): vscode.Uri {
  if (uri instanceof vscode.Uri) {
    return uri;
  }
  throw new ExtensionRuntimeError("SUBVERSIONR_CACHE_URI_INVALID", "error.cache.uriInvalid");
}

function isFileNotFoundError(error: unknown): boolean {
  return error instanceof vscode.FileSystemError && error.code === "FileNotFound";
}

function diagnosticsContext(context: vscode.ExtensionContext): DiagnosticsContext {
  return {
    generatedAt: new Date().toISOString(),
    extension: {
      name: "SubversionR",
      version: extensionVersion(context),
    },
    vscode: {
      version: vscode.version,
      appName: vscode.env.appName,
      uiKind: vscode.env.uiKind === vscode.UIKind.Web ? "web" : "desktop",
      remoteName: vscode.env.remoteName,
    },
    process: {
      platform: process.platform,
      arch: process.arch,
      nodeVersion: process.versions.node,
    },
    workspace: {
      trusted: vscode.workspace.isTrusted,
      workspaceFolders: (vscode.workspace.workspaceFolders ?? []).map((folder) => folder.uri.fsPath),
    },
  };
}

function resolveBackendPackageResources(context: vscode.ExtensionContext) {
  return resolvePackagedBackendResources({
    platform: process.platform,
    arch: process.arch,
    extensionResourcePath: (relativePath) => context.asAbsolutePath(relativePath),
    isFile: isExistingFile,
  });
}

function isExistingFile(candidate: string): boolean {
  try {
    return statSync(candidate).isFile();
  } catch {
    return false;
  }
}

function defaultDiagnosticsUri(defaultFileName: string): vscode.Uri {
  const firstWorkspaceFolder = vscode.workspace.workspaceFolders?.[0];
  if (firstWorkspaceFolder) {
    return vscode.Uri.joinPath(firstWorkspaceFolder.uri, defaultFileName);
  }
  return vscode.Uri.file(defaultFileName);
}

function uriFsPath(uri: unknown): string | undefined {
  if (uri instanceof vscode.Uri) {
    return uri.fsPath;
  }
  return undefined;
}

function normalizedFsPath(fsPath: string): string {
  const normalized = fsPath.replace(/\\/g, "/").replace(/\/+$/u, "");
  return process.platform === "win32" ? normalized.toLocaleLowerCase("en-US") : normalized;
}

export async function deactivate(): Promise<void> {
  const commandCancellationSource = repositoryCommandCancellationSource;
  const service = backendService;
  const sessionService = repositorySessionService;
  const watcherService = repositoryWatcherService;
  backendService = undefined;
  repositorySessionService = undefined;
  repositoryWatcherService = undefined;
  operationDiagnostics = undefined;
  repositoryCommandCancellationSource = undefined;
  commandCancellationSource?.cancel();
  sessionService?.dispose();
  watcherService?.dispose();
  try {
    await service?.shutdown();
  } finally {
    service?.dispose();
  }
}

function extensionVersion(context: vscode.ExtensionContext): string {
  const packageJson = context.extension.packageJSON as { version?: unknown };
  if (typeof packageJson.version !== "string" || packageJson.version.trim().length === 0) {
    throw new Error("SubversionR extension version is missing from package.json");
  }
  return packageJson.version;
}

async function pickRepositoryCandidate(
  candidates: RepositoryDiscoveryCandidate[],
): Promise<RepositoryDiscoveryCandidate | undefined> {
  const item = await vscode.window.showQuickPick(
    candidates.map((candidate) => ({
      label: candidate.identity.workingCopyRoot,
      description: candidate.identity.repositoryRootUrl,
      candidate,
    })),
    { placeHolder: vscode.l10n.t("Select an SVN working copy") },
  );
  return item?.candidate;
}

async function pickOpenRepository(sessions: RepositorySession[]): Promise<RepositorySession | undefined> {
  const item = await vscode.window.showQuickPick(
    sessions.map((session) => ({
      label: session.identity.workingCopyRoot,
      description: session.identity.repositoryRootUrl,
      session,
    })),
    { placeHolder: vscode.l10n.t("Select an SVN repository") },
  );
  return item?.session;
}

type UpdateDepth = RepositoryUpdateOptions["depth"];
type CheckoutDepth = RepositoryCheckoutOptions["depth"];
type SwitchDepth = RepositorySwitchOptions["depth"];
type MergeDepth = RepositoryMergeRangeOptions["depth"];

interface LockStealQuickPickItem extends vscode.QuickPickItem {
  stealLock: boolean;
}

interface UnlockBreakQuickPickItem extends vscode.QuickPickItem {
  breakLock: boolean;
}

interface UpdateDepthQuickPickItem extends vscode.QuickPickItem {
  depth: UpdateDepth;
}

interface UpdateStickyDepthQuickPickItem extends vscode.QuickPickItem {
  depthIsSticky: boolean;
}

interface UpdateExternalsQuickPickItem extends vscode.QuickPickItem {
  ignoreExternals: boolean;
}

interface CheckoutRevisionModeQuickPickItem extends vscode.QuickPickItem {
  mode: "head" | "revision";
}

interface CheckoutDepthQuickPickItem extends vscode.QuickPickItem {
  depth: CheckoutDepth;
}

interface CheckoutExternalsQuickPickItem extends vscode.QuickPickItem {
  ignoreExternals: boolean;
}

interface BranchCreateParentsQuickPickItem extends vscode.QuickPickItem {
  makeParents: boolean;
}

interface BranchCreateExternalsQuickPickItem extends vscode.QuickPickItem {
  ignoreExternals: boolean;
}

interface SwitchDepthQuickPickItem extends vscode.QuickPickItem {
  depth: SwitchDepth;
}

interface SwitchStickyDepthQuickPickItem extends vscode.QuickPickItem {
  depthIsSticky: boolean;
}

interface SwitchExternalsQuickPickItem extends vscode.QuickPickItem {
  ignoreExternals: boolean;
}

interface RelocateExternalsQuickPickItem extends vscode.QuickPickItem {
  ignoreExternals: boolean;
}

interface SwitchAncestryQuickPickItem extends vscode.QuickPickItem {
  ignoreAncestry: boolean;
}

interface MergeDepthQuickPickItem extends vscode.QuickPickItem {
  depth: MergeDepth;
}

interface ResolveChoiceQuickPickItem extends vscode.QuickPickItem {
  choice: ResolveOperationChoice;
}

async function promptResolveChoice(resourcePath: string): Promise<ResolveOperationChoice | undefined> {
  const items: ResolveChoiceQuickPickItem[] = [
    {
      label: vscode.l10n.t("Working copy"),
      description: vscode.l10n.t("Use the current working copy file"),
      choice: "working",
    },
    {
      label: vscode.l10n.t("Base"),
      description: vscode.l10n.t("Use the pre-conflict base file"),
      choice: "base",
    },
    {
      label: vscode.l10n.t("Mine full"),
      description: vscode.l10n.t("Use your full local file"),
      choice: "mineFull",
    },
    {
      label: vscode.l10n.t("Theirs full"),
      description: vscode.l10n.t("Use the full incoming file"),
      choice: "theirsFull",
    },
    {
      label: vscode.l10n.t("Mine conflict"),
      description: vscode.l10n.t("Use your local changes for conflicted hunks"),
      choice: "mineConflict",
    },
    {
      label: vscode.l10n.t("Theirs conflict"),
      description: vscode.l10n.t("Use incoming changes for conflicted hunks"),
      choice: "theirsConflict",
    },
  ];
  const picked = await vscode.window.showQuickPick(items, {
    title: vscode.l10n.t("Resolve SVN conflict"),
    placeHolder: vscode.l10n.t("Choose how to resolve {0}", resourcePath),
    ignoreFocusOut: true,
  });
  return picked?.choice;
}

async function promptLockOptions(
  resourcePaths: readonly string[],
  cancellation: RepositoryCommandCancellationToken,
): Promise<RepositoryLockOptions | undefined> {
  const commentText = await vscode.window.showInputBox({
    title: vscode.l10n.t("Lock SVN resource"),
    prompt:
      resourcePaths.length === 1
        ? vscode.l10n.t("Enter an SVN lock message for {0}.", resourcePaths[0])
        : vscode.l10n.t("Enter an SVN lock message for {0} resources.", resourcePaths.length),
    placeHolder: vscode.l10n.t("Lock message"),
    ignoreFocusOut: true,
    validateInput: validateLockCommentInput,
  }, cancellation);
  if (commentText === undefined) {
    return undefined;
  }
  const stealLock = await pickLockStealPolicy(cancellation);
  if (stealLock === undefined) {
    return undefined;
  }
  const comment = commentText.trim().length === 0 ? null : commentText;
  return {
    comment,
    stealLock,
  };
}

function validateLockCommentInput(value: string): string | undefined {
  if (value.includes("\0") || value.includes("\r") || value.includes("\n")) {
    return vscode.l10n.t("Enter an SVN lock message without line breaks.");
  }
  return undefined;
}

async function pickLockStealPolicy(cancellation: RepositoryCommandCancellationToken): Promise<boolean | undefined> {
  const items: LockStealQuickPickItem[] = [
    {
      label: vscode.l10n.t("Lock"),
      description: vscode.l10n.t("Create a normal SVN lock"),
      stealLock: false,
    },
    {
      label: vscode.l10n.t("Steal lock"),
      description: vscode.l10n.t("Break an existing SVN lock and create a new lock"),
      stealLock: true,
    },
  ];
  const item = await vscode.window.showQuickPick(items, {
    title: vscode.l10n.t("SVN lock mode"),
    placeHolder: vscode.l10n.t("Choose how SVN lock handles existing locks"),
    ignoreFocusOut: true,
  }, cancellation);
  return item?.stealLock;
}

async function promptUnlockOptions(
  _resourcePaths: readonly string[],
  cancellation: RepositoryCommandCancellationToken,
): Promise<RepositoryUnlockOptions | undefined> {
  const breakLock = await pickUnlockBreakPolicy(cancellation);
  if (breakLock === undefined) {
    return undefined;
  }
  return { breakLock };
}

async function promptCheckoutOptions(): Promise<RepositoryCheckoutOptions | undefined> {
  const url = await vscode.window.showInputBox({
    title: vscode.l10n.t("Checkout SVN repository"),
    prompt: vscode.l10n.t("Enter the SVN repository URL to checkout."),
    placeHolder: vscode.l10n.t("https://svn.example.com/project/trunk"),
    ignoreFocusOut: true,
    validateInput: validateCheckoutUrlInput,
  });
  if (url === undefined) {
    return undefined;
  }
  const targetPath = await vscode.window.showInputBox({
    title: vscode.l10n.t("SVN checkout target folder"),
    prompt: vscode.l10n.t("Enter the absolute local folder path for the checkout."),
    placeHolder: vscode.l10n.t("C:\\workspace\\project"),
    value: suggestedCheckoutTargetPath(
      url,
      (vscode.workspace.workspaceFolders ?? []).map((folder) => folder.uri.fsPath),
    ),
    ignoreFocusOut: true,
    validateInput: validateCheckoutTargetPathInput,
  });
  if (targetPath === undefined) {
    return undefined;
  }
  const revision = await pickCheckoutRevision();
  if (revision === undefined) {
    return undefined;
  }
  const depth = await pickCheckoutDepth();
  if (depth === undefined) {
    return undefined;
  }
  const ignoreExternals = await pickCheckoutExternalsPolicy();
  if (ignoreExternals === undefined) {
    return undefined;
  }
  return {
    url,
    targetPath,
    revision,
    depth,
    ignoreExternals,
  };
}

async function promptCleanupOptions(workingCopyRoot: string): Promise<RepositoryCleanupOptions | undefined> {
  type CleanupQuickPickItem = vscode.QuickPickItem & { option: keyof RepositoryCleanupOptions };
  const items: CleanupQuickPickItem[] = [
    {
      label: vscode.l10n.t("Break working-copy locks"),
      description: vscode.l10n.t("Release stale SVN working-copy locks before cleanup"),
      option: "breakLocks",
      picked: true,
    },
    {
      label: vscode.l10n.t("Fix recorded timestamps"),
      description: vscode.l10n.t("Refresh recorded SVN file timestamps during cleanup"),
      option: "fixRecordedTimestamps",
    },
    {
      label: vscode.l10n.t("Clear DAV cache"),
      description: vscode.l10n.t("Clear cached SVN HTTP/WebDAV state during cleanup"),
      option: "clearDavCache",
    },
    {
      label: vscode.l10n.t("Vacuum pristine copies"),
      description: vscode.l10n.t("Remove unused pristine SVN base files during cleanup"),
      option: "vacuumPristines",
    },
    {
      label: vscode.l10n.t("Include externals"),
      description: vscode.l10n.t("Run cleanup on SVN externals below this working copy"),
      option: "includeExternals",
    },
  ];
  const selected = await vscode.window.showQuickPick(items, {
    title: vscode.l10n.t("SVN cleanup options"),
    placeHolder: vscode.l10n.t("Choose cleanup options for {0}", workingCopyRoot),
    canPickMany: true,
    ignoreFocusOut: true,
  });
  if (selected === undefined) {
    return undefined;
  }
  const selectedOptions = new Set(selected.map((item) => item.option));
  return {
    breakLocks: selectedOptions.has("breakLocks"),
    fixRecordedTimestamps: selectedOptions.has("fixRecordedTimestamps"),
    clearDavCache: selectedOptions.has("clearDavCache"),
    vacuumPristines: selectedOptions.has("vacuumPristines"),
    includeExternals: selectedOptions.has("includeExternals"),
  };
}

async function promptBranchCreateOptions(workingCopyRoot: string): Promise<RepositoryBranchCreateOptions | undefined> {
  const sourceUrl = await vscode.window.showInputBox({
    title: vscode.l10n.t("Create SVN branch or tag"),
    prompt: vscode.l10n.t("Enter the SVN source URL for {0}.", workingCopyRoot),
    placeHolder: vscode.l10n.t("https://svn.example.com/project/trunk"),
    ignoreFocusOut: true,
    validateInput: validateCheckoutUrlInput,
  });
  if (sourceUrl === undefined) {
    return undefined;
  }
  const destinationUrl = await vscode.window.showInputBox({
    title: vscode.l10n.t("SVN branch or tag destination"),
    prompt: vscode.l10n.t("Enter the SVN destination URL."),
    placeHolder: vscode.l10n.t("https://svn.example.com/project/branches/feature"),
    ignoreFocusOut: true,
    validateInput: validateCheckoutUrlInput,
  });
  if (destinationUrl === undefined) {
    return undefined;
  }
  const revision = await pickBranchCreateRevision();
  if (revision === undefined) {
    return undefined;
  }
  const message = await vscode.window.showInputBox({
    title: vscode.l10n.t("SVN branch or tag log message"),
    prompt: vscode.l10n.t("Enter the SVN log message for the copy commit."),
    placeHolder: vscode.l10n.t("Create branch"),
    ignoreFocusOut: true,
    validateInput: validateBranchCreateMessageInput,
  });
  if (message === undefined) {
    return undefined;
  }
  const makeParents = await pickBranchCreateParentsPolicy();
  if (makeParents === undefined) {
    return undefined;
  }
  const ignoreExternals = await pickBranchCreateExternalsPolicy();
  if (ignoreExternals === undefined) {
    return undefined;
  }
  const switchAfterCreate = await pickBranchCreateSwitchPolicy();
  if (switchAfterCreate === undefined) {
    return undefined;
  }
  return {
    sourceUrl,
    destinationUrl,
    revision,
    message,
    makeParents,
    ignoreExternals,
    switchAfterCreate,
  };
}

async function promptSwitchOptions(workingCopyRoot: string): Promise<RepositorySwitchOptions | undefined> {
  const url = await vscode.window.showInputBox({
    title: vscode.l10n.t("Switch SVN working copy"),
    prompt: vscode.l10n.t("Enter the SVN URL to switch {0} to.", workingCopyRoot),
    placeHolder: vscode.l10n.t("https://svn.example.com/project/branches/feature"),
    ignoreFocusOut: true,
    validateInput: validateCheckoutUrlInput,
  });
  if (url === undefined) {
    return undefined;
  }
  const revision = await pickSwitchRevision();
  if (revision === undefined) {
    return undefined;
  }
  const depth = await pickSwitchDepth();
  if (depth === undefined) {
    return undefined;
  }
  const depthIsSticky = depth === "workingCopy" ? false : await pickSwitchStickyDepth();
  if (depthIsSticky === undefined) {
    return undefined;
  }
  const ignoreExternals = await pickSwitchExternalsPolicy();
  if (ignoreExternals === undefined) {
    return undefined;
  }
  const ignoreAncestry = await pickSwitchAncestryPolicy();
  if (ignoreAncestry === undefined) {
    return undefined;
  }
  return {
    url,
    revision,
    depth,
    depthIsSticky,
    ignoreExternals,
    ignoreAncestry,
  };
}

async function promptRelocateOptions(workingCopyRoot: string, fromUrl: string): Promise<RepositoryRelocateOptions | undefined> {
  const toUrl = await vscode.window.showInputBox({
    title: vscode.l10n.t("Relocate SVN working copy"),
    prompt: vscode.l10n.t("Enter the new SVN repository root URL for {0}. Current root: {1}", workingCopyRoot, fromUrl),
    placeHolder: vscode.l10n.t("https://svn.example.com/project"),
    ignoreFocusOut: true,
    validateInput: validateCheckoutUrlInput,
  });
  if (toUrl === undefined) {
    return undefined;
  }
  const ignoreExternals = await pickRelocateExternalsPolicy();
  if (ignoreExternals === undefined) {
    return undefined;
  }
  return {
    toUrl,
    ignoreExternals,
  };
}

async function promptMergeRangeOptions(workingCopyRoot: string): Promise<RepositoryMergeRangeOptions | undefined> {
  const sourceUrl = await vscode.window.showInputBox({
    title: vscode.l10n.t("Merge SVN revision range"),
    prompt: vscode.l10n.t("Enter the SVN source URL to merge into {0}.", workingCopyRoot),
    placeHolder: vscode.l10n.t("https://svn.example.com/project/branches/feature"),
    ignoreFocusOut: true,
    validateInput: validateCheckoutUrlInput,
  });
  if (sourceUrl === undefined) {
    return undefined;
  }
  const targetPath = await vscode.window.showInputBox({
    title: vscode.l10n.t("SVN merge target path"),
    prompt: vscode.l10n.t("Enter the repository-relative target path."),
    value: ".",
    placeHolder: ".",
    ignoreFocusOut: true,
    validateInput: validateRepositoryRelativePathInput,
  });
  if (targetPath === undefined) {
    return undefined;
  }
  const startRevisionText = await vscode.window.showInputBox({
    title: vscode.l10n.t("SVN merge start revision"),
    prompt: vscode.l10n.t("Enter the SVN revision where the merge range starts."),
    placeHolder: vscode.l10n.t("Revision number"),
    ignoreFocusOut: true,
    validateInput: validateMergeRevisionInput,
  });
  if (startRevisionText === undefined) {
    return undefined;
  }
  const endRevisionText = await vscode.window.showInputBox({
    title: vscode.l10n.t("SVN merge end revision"),
    prompt: vscode.l10n.t("Enter the SVN revision where the merge range ends."),
    placeHolder: vscode.l10n.t("Revision number"),
    ignoreFocusOut: true,
    validateInput: validateMergeRevisionInput,
  });
  if (endRevisionText === undefined) {
    return undefined;
  }
  const startRevision = parseMergeRevisionInput(startRevisionText);
  const endRevision = parseMergeRevisionInput(endRevisionText);
  if (startRevision === undefined || endRevision === undefined) {
    throw new Error("SubversionR merge revision input failed validation.");
  }
  if (startRevision === endRevision) {
    await vscode.window.showWarningMessage(
      vscode.l10n.t("Enter different SVN start and end revisions for merge."),
    );
    return undefined;
  }
  const depth = await pickMergeDepth();
  if (depth === undefined) {
    return undefined;
  }
  const recordOnly = await pickMergeRecordOnlyPolicy();
  if (recordOnly === undefined) {
    return undefined;
  }
  const ignoreMergeinfo = await pickMergeMergeinfoPolicy();
  if (ignoreMergeinfo === undefined) {
    return undefined;
  }
  const diffIgnoreAncestry = await pickMergeAncestryPolicy();
  if (diffIgnoreAncestry === undefined) {
    return undefined;
  }
  const allowMixedRevisions = await pickMergeMixedRevisionsPolicy();
  if (allowMixedRevisions === undefined) {
    return undefined;
  }
  const forceDelete = await pickMergeForceDeletePolicy();
  if (forceDelete === undefined) {
    return undefined;
  }
  return {
    sourceUrl,
    targetPath,
    startRevision,
    endRevision,
    depth,
    ignoreMergeinfo,
    diffIgnoreAncestry,
    forceDelete,
    recordOnly,
    dryRun: false,
    allowMixedRevisions,
  };
}

async function promptPropertySetOptions(path: string): Promise<RepositoryPropertySetOptions | undefined> {
  const name = await vscode.window.showInputBox({
    title: vscode.l10n.t("Set SVN property"),
    prompt: vscode.l10n.t("Enter the SVN property name for {0}.", path),
    placeHolder: "svn:eol-style",
    ignoreFocusOut: true,
    validateInput: validatePropertyNameInput,
  });
  if (name === undefined) {
    return undefined;
  }

  const value = await vscode.window.showInputBox({
    title: vscode.l10n.t("SVN property value"),
    prompt: vscode.l10n.t("Enter the SVN property value for {0}.", path),
    placeHolder: "LF",
    ignoreFocusOut: true,
    validateInput: validatePropertyValueInput,
  });
  if (value === undefined) {
    return undefined;
  }

  return { name, value };
}

async function promptPropertyDeleteName(
  path: string,
  properties: readonly PropertyEntry[],
): Promise<string | undefined> {
  const items: Array<vscode.QuickPickItem & { name: string }> = properties.map((property) => ({
    label: property.name,
    description: propertyValuePreview(property),
    name: property.name,
  }));
  const selected = await vscode.window.showQuickPick(items, {
    title: vscode.l10n.t("Delete SVN property"),
    placeHolder: vscode.l10n.t("Choose the SVN property to delete from {0}.", path),
    matchOnDescription: true,
    ignoreFocusOut: true,
  });
  return selected?.name;
}

async function promptExternalsPropertyValue(
  path: string,
  existingValue: string | undefined,
): Promise<string | undefined> {
  return await vscode.window.showInputBox({
    title: vscode.l10n.t("Edit svn:externals"),
    prompt: vscode.l10n.t("Enter the svn:externals value for {0}. Leave empty to clear it.", path),
    value: existingValue ?? "",
    ignoreFocusOut: true,
    validateInput: validatePropertyValueInput,
  });
}

function propertyValuePreview(property: PropertyEntry): string {
  const firstLine = property.value.split("\n", 1)[0] ?? "";
  return firstLine.length > 80 ? `${firstLine.slice(0, 77)}...` : firstLine;
}

function validatePropertyNameInput(value: string): string | undefined {
  if (value.length === 0 || value.includes("\0") || value.includes("\r") || value.includes("\n")) {
    return vscode.l10n.t("Enter an SVN property name without line breaks.");
  }
  return undefined;
}

function validatePropertyValueInput(value: string): string | undefined {
  if (value.includes("\0") || value.includes("\r")) {
    return vscode.l10n.t("Enter an SVN property value without carriage returns.");
  }
  return undefined;
}

async function promptReviewCommitTargets(
  targets: readonly RepositoryReviewCommitTarget[],
  preselectedPaths: ReadonlySet<string>,
): Promise<readonly RepositoryReviewCommitTarget[] | undefined> {
  const items: Array<vscode.QuickPickItem & { target: RepositoryReviewCommitTarget }> = targets.map((target) => ({
    label: target.path,
    description: reviewCommitTargetDescription(target),
    detail: reviewCommitTargetDetail(target),
    picked: preselectedPaths.has(target.path),
    target,
  }));
  const selected = await vscode.window.showQuickPick(items, {
    canPickMany: true,
    title: vscode.l10n.t("Review SVN commit"),
    placeHolder: vscode.l10n.t("Filter by path, changelist, status, or directory"),
    matchOnDescription: true,
    matchOnDetail: true,
    ignoreFocusOut: true,
  });
  return selected?.map((item) => item.target);
}

async function promptCommitMessage(pathSummary: string): Promise<string | undefined> {
  return await vscode.window.showInputBox({
    title: vscode.l10n.t("Commit SVN changes"),
    prompt: vscode.l10n.t("Enter an SVN commit message for {0}.", pathSummary),
    placeHolder: vscode.l10n.t("SVN commit message"),
    ignoreFocusOut: true,
    validateInput: validateCommitMessageInput,
  });
}

function validateCommitMessageInput(value: string): string | undefined {
  if (value.trim().length === 0 || value.includes("\0") || value.includes("\r")) {
    return vscode.l10n.t("Enter a non-empty SVN commit message without carriage returns.");
  }
  return undefined;
}

async function promptCommitMessageHistory(messages: readonly string[]): Promise<string | undefined> {
  const items: Array<vscode.QuickPickItem & { message: string }> = messages.map((message) => ({
    label: commitMessageHistoryPreview(message),
    detail: message,
    message,
  }));
  const selected = await vscode.window.showQuickPick(items, {
    title: vscode.l10n.t("SVN commit message history"),
    placeHolder: vscode.l10n.t("Choose an SVN commit message to reuse"),
    matchOnDetail: true,
    ignoreFocusOut: true,
  });
  return selected?.message;
}

function commitMessageHistoryPreview(message: string): string {
  const firstLine = message.split("\n", 1)[0]?.trim() ?? "";
  const preview = firstLine.length > 0 ? firstLine : message.replace(/\s+/gu, " ").trim();
  return preview.length > 80 ? `${preview.slice(0, 77)}...` : preview;
}

function reviewCommitTargetDescription(target: RepositoryReviewCommitTarget): string {
  if (target.changelist === null) {
    return vscode.l10n.t("No changelist");
  }
  return vscode.l10n.t("Changelist: {0}", target.changelist);
}

function reviewCommitTargetDetail(target: RepositoryReviewCommitTarget): string {
  return vscode.l10n.t("Status: {0} | Directory: {1}", reviewCommitStatusLabel(target.status), target.directory);
}

function reviewCommitStatusLabel(status: string): string {
  switch (status) {
    case "added":
      return vscode.l10n.t("Added");
    case "missing":
      return vscode.l10n.t("Missing");
    case "deleted":
      return vscode.l10n.t("Deleted");
    case "replaced":
      return vscode.l10n.t("Replaced");
    case "modified":
      return vscode.l10n.t("Modified");
    case "merged":
      return vscode.l10n.t("Merged");
    case "obstructed":
      return vscode.l10n.t("Obstructed");
    case "incomplete":
      return vscode.l10n.t("Incomplete");
    default:
      return status;
  }
}

async function pickUnlockBreakPolicy(cancellation: RepositoryCommandCancellationToken): Promise<boolean | undefined> {
  const items: UnlockBreakQuickPickItem[] = [
    {
      label: vscode.l10n.t("Unlock"),
      description: vscode.l10n.t("Release an SVN lock held by this working copy"),
      breakLock: false,
    },
    {
      label: vscode.l10n.t("Force unlock"),
      description: vscode.l10n.t("Break an SVN lock held elsewhere"),
      breakLock: true,
    },
  ];
  const item = await vscode.window.showQuickPick(items, {
    title: vscode.l10n.t("SVN unlock mode"),
    placeHolder: vscode.l10n.t("Choose how SVN unlock handles locks held elsewhere"),
    ignoreFocusOut: true,
  }, cancellation);
  return item?.breakLock;
}

async function pickCheckoutRevision(): Promise<RepositoryCheckoutOptions["revision"] | undefined> {
  const modeItems: CheckoutRevisionModeQuickPickItem[] = [
    {
      label: vscode.l10n.t("HEAD"),
      description: vscode.l10n.t("Checkout the latest repository revision"),
      mode: "head",
    },
    {
      label: vscode.l10n.t("Revision number"),
      description: vscode.l10n.t("Checkout a specific SVN revision"),
      mode: "revision",
    },
  ];
  const mode = await vscode.window.showQuickPick(modeItems, {
    title: vscode.l10n.t("SVN checkout revision"),
    placeHolder: vscode.l10n.t("Choose the SVN revision to checkout"),
    ignoreFocusOut: true,
  });
  if (mode === undefined) {
    return undefined;
  }
  if (mode.mode === "head") {
    return "head";
  }
  const revisionText = await vscode.window.showInputBox({
    title: vscode.l10n.t("Checkout SVN repository revision"),
    prompt: vscode.l10n.t("Enter the SVN revision number to checkout."),
    placeHolder: vscode.l10n.t("Revision number"),
    ignoreFocusOut: true,
    validateInput: validateUpdateRevisionInput,
  });
  if (revisionText === undefined) {
    return undefined;
  }
  const revision = parseUpdateRevisionInput(revisionText);
  if (revision === undefined) {
    throw new Error("SubversionR checkout revision input failed validation.");
  }
  return revision;
}

async function pickCheckoutDepth(): Promise<CheckoutDepth | undefined> {
  const items: CheckoutDepthQuickPickItem[] = [
    {
      label: vscode.l10n.t("Empty"),
      description: vscode.l10n.t("Checkout only the target directory metadata"),
      depth: "empty",
    },
    {
      label: vscode.l10n.t("Files"),
      description: vscode.l10n.t("Checkout the target and its immediate file children"),
      depth: "files",
    },
    {
      label: vscode.l10n.t("Immediates"),
      description: vscode.l10n.t("Checkout the target and its immediate children"),
      depth: "immediates",
    },
    {
      label: vscode.l10n.t("Infinity"),
      description: vscode.l10n.t("Checkout the full subtree"),
      depth: "infinity",
    },
  ];
  const item = await vscode.window.showQuickPick(items, {
    title: vscode.l10n.t("SVN checkout depth"),
    placeHolder: vscode.l10n.t("Choose the SVN depth for checkout"),
    ignoreFocusOut: true,
  });
  return item?.depth;
}

async function pickCheckoutExternalsPolicy(): Promise<boolean | undefined> {
  const items: CheckoutExternalsQuickPickItem[] = [
    {
      label: vscode.l10n.t("Ignore externals"),
      description: vscode.l10n.t("Skip SVN externals during checkout"),
      ignoreExternals: true,
    },
    {
      label: vscode.l10n.t("Include externals"),
      description: vscode.l10n.t("Allow libsvn to checkout SVN externals"),
      ignoreExternals: false,
    },
  ];
  const item = await vscode.window.showQuickPick(items, {
    title: vscode.l10n.t("SVN checkout externals"),
    placeHolder: vscode.l10n.t("Choose how SVN externals are handled"),
    ignoreFocusOut: true,
  });
  return item?.ignoreExternals;
}

async function pickBranchCreateRevision(): Promise<RepositoryBranchCreateOptions["revision"] | undefined> {
  const mode = await pickRevisionMode(
    vscode.l10n.t("SVN branch or tag source revision"),
    vscode.l10n.t("Choose the SVN source revision"),
    vscode.l10n.t("Copy the latest repository revision"),
  );
  if (mode === undefined) {
    return undefined;
  }
  if (mode === "head") {
    return "head";
  }
  return await promptNumericRevision(
    vscode.l10n.t("SVN branch or tag source revision"),
    vscode.l10n.t("Enter the SVN source revision number."),
  );
}

async function pickBranchCreateSwitchPolicy(): Promise<boolean | undefined> {
  const item = await vscode.window.showQuickPick(
    [
      {
        label: vscode.l10n.t("Stay on the current SVN URL"),
        description: vscode.l10n.t("Create the branch or tag without switching this working copy"),
        switchAfterCreate: false,
      },
      {
        label: vscode.l10n.t("Switch this working copy to the new branch/tag"),
        description: vscode.l10n.t("Create the branch or tag, then switch this working copy to the destination URL"),
        switchAfterCreate: true,
      },
    ],
    {
      title: vscode.l10n.t("SVN branch/tag switch"),
      placeHolder: vscode.l10n.t("Choose whether to switch after creating the branch or tag"),
      ignoreFocusOut: true,
    },
  );
  return item?.switchAfterCreate;
}

async function pickSwitchRevision(): Promise<RepositorySwitchOptions["revision"] | undefined> {
  const mode = await pickRevisionMode(
    vscode.l10n.t("SVN switch revision"),
    vscode.l10n.t("Choose the SVN revision to switch to"),
    vscode.l10n.t("Switch to the latest repository revision"),
  );
  if (mode === undefined) {
    return undefined;
  }
  if (mode === "head") {
    return "head";
  }
  return await promptNumericRevision(
    vscode.l10n.t("SVN switch revision"),
    vscode.l10n.t("Enter the SVN revision number to switch to."),
  );
}

async function pickRevisionMode(
  title: string,
  placeHolder: string,
  headDescription: string,
): Promise<"head" | "revision" | undefined> {
  const modeItems: CheckoutRevisionModeQuickPickItem[] = [
    {
      label: vscode.l10n.t("HEAD"),
      description: headDescription,
      mode: "head",
    },
    {
      label: vscode.l10n.t("Revision number"),
      description: vscode.l10n.t("Use a specific SVN revision"),
      mode: "revision",
    },
  ];
  const mode = await vscode.window.showQuickPick(modeItems, {
    title,
    placeHolder,
    ignoreFocusOut: true,
  });
  return mode?.mode;
}

async function promptNumericRevision(
  title: string,
  prompt: string,
): Promise<RepositoryBranchCreateOptions["revision"] | undefined> {
  const revisionText = await vscode.window.showInputBox({
    title,
    prompt,
    placeHolder: vscode.l10n.t("Revision number"),
    ignoreFocusOut: true,
    validateInput: validateUpdateRevisionInput,
  });
  if (revisionText === undefined) {
    return undefined;
  }
  const revision = parseUpdateRevisionInput(revisionText);
  if (revision === undefined) {
    throw new Error("SubversionR revision input failed validation.");
  }
  return revision;
}

async function pickBranchCreateParentsPolicy(): Promise<boolean | undefined> {
  const items: BranchCreateParentsQuickPickItem[] = [
    {
      label: vscode.l10n.t("Require destination parent"),
      description: vscode.l10n.t("Fail if the branch or tag parent URL does not exist"),
      makeParents: false,
    },
    {
      label: vscode.l10n.t("Create destination parents"),
      description: vscode.l10n.t("Allow libsvn to create missing parent folders"),
      makeParents: true,
    },
  ];
  const item = await vscode.window.showQuickPick(items, {
    title: vscode.l10n.t("SVN branch or tag parents"),
    placeHolder: vscode.l10n.t("Choose how missing destination parents are handled"),
    ignoreFocusOut: true,
  });
  return item?.makeParents;
}

async function pickBranchCreateExternalsPolicy(): Promise<boolean | undefined> {
  const items: BranchCreateExternalsQuickPickItem[] = [
    {
      label: vscode.l10n.t("Ignore externals"),
      description: vscode.l10n.t("Do not copy SVN externals"),
      ignoreExternals: true,
    },
    {
      label: vscode.l10n.t("Include externals"),
      description: vscode.l10n.t("Allow libsvn to include SVN externals"),
      ignoreExternals: false,
    },
  ];
  const item = await vscode.window.showQuickPick(items, {
    title: vscode.l10n.t("SVN branch or tag externals"),
    placeHolder: vscode.l10n.t("Choose how SVN externals are handled"),
    ignoreFocusOut: true,
  });
  return item?.ignoreExternals;
}

async function pickSwitchDepth(): Promise<SwitchDepth | undefined> {
  const items: SwitchDepthQuickPickItem[] = [
    {
      label: vscode.l10n.t("Working copy depth"),
      description: vscode.l10n.t("Use each node's current SVN working copy depth"),
      depth: "workingCopy",
    },
    {
      label: vscode.l10n.t("Empty"),
      description: vscode.l10n.t("Switch only the target node"),
      depth: "empty",
    },
    {
      label: vscode.l10n.t("Files"),
      description: vscode.l10n.t("Switch the target and its immediate file children"),
      depth: "files",
    },
    {
      label: vscode.l10n.t("Immediates"),
      description: vscode.l10n.t("Switch the target and its immediate children"),
      depth: "immediates",
    },
    {
      label: vscode.l10n.t("Infinity"),
      description: vscode.l10n.t("Switch the full subtree"),
      depth: "infinity",
    },
  ];
  const item = await vscode.window.showQuickPick(items, {
    title: vscode.l10n.t("SVN switch depth"),
    placeHolder: vscode.l10n.t("Choose the SVN depth for switch"),
    ignoreFocusOut: true,
  });
  return item?.depth;
}

async function pickMergeDepth(): Promise<MergeDepth | undefined> {
  const items: MergeDepthQuickPickItem[] = [
    {
      label: vscode.l10n.t("Empty"),
      description: vscode.l10n.t("Merge only the target node"),
      depth: "empty",
    },
    {
      label: vscode.l10n.t("Files"),
      description: vscode.l10n.t("Merge the target and its immediate file children"),
      depth: "files",
    },
    {
      label: vscode.l10n.t("Immediates"),
      description: vscode.l10n.t("Merge the target and its immediate children"),
      depth: "immediates",
    },
    {
      label: vscode.l10n.t("Infinity"),
      description: vscode.l10n.t("Merge the full subtree"),
      depth: "infinity",
    },
  ];
  const item = await vscode.window.showQuickPick(items, {
    title: vscode.l10n.t("SVN merge depth"),
    placeHolder: vscode.l10n.t("Choose the SVN depth for merge"),
    ignoreFocusOut: true,
  });
  return item?.depth;
}

async function pickMergeRecordOnlyPolicy(): Promise<boolean | undefined> {
  const item = await vscode.window.showQuickPick(mergeRecordOnlyQuickPickItems(vscode.l10n.t), {
    title: vscode.l10n.t("SVN merge record-only mode"),
    placeHolder: vscode.l10n.t("Choose whether SVN merge changes files or only records mergeinfo"),
    ignoreFocusOut: true,
  });
  return item?.recordOnly;
}

async function pickMergeMergeinfoPolicy(): Promise<boolean | undefined> {
  const item = await vscode.window.showQuickPick(mergeIgnoreMergeinfoQuickPickItems(vscode.l10n.t), {
    title: vscode.l10n.t("SVN mergeinfo filtering"),
    placeHolder: vscode.l10n.t("Choose whether SVN merge uses svn:mergeinfo to filter revisions"),
    ignoreFocusOut: true,
  });
  return item?.ignoreMergeinfo;
}

async function pickMergeAncestryPolicy(): Promise<boolean | undefined> {
  const item = await vscode.window.showQuickPick(mergeAncestryQuickPickItems(vscode.l10n.t), {
    title: vscode.l10n.t("SVN merge ancestry"),
    placeHolder: vscode.l10n.t("Choose how SVN merge checks ancestry"),
    ignoreFocusOut: true,
  });
  return item?.diffIgnoreAncestry;
}

async function pickMergeMixedRevisionsPolicy(): Promise<boolean | undefined> {
  const item = await vscode.window.showQuickPick(mergeMixedRevisionsQuickPickItems(vscode.l10n.t), {
    title: vscode.l10n.t("SVN merge mixed revisions"),
    placeHolder: vscode.l10n.t("Choose whether SVN merge allows mixed working copy revisions"),
    ignoreFocusOut: true,
  });
  return item?.allowMixedRevisions;
}

async function pickMergeForceDeletePolicy(): Promise<boolean | undefined> {
  const item = await vscode.window.showQuickPick(mergeForceDeleteQuickPickItems(vscode.l10n.t), {
    title: vscode.l10n.t("SVN merge forced deletes"),
    placeHolder: vscode.l10n.t("Choose whether SVN merge can force deletes"),
    ignoreFocusOut: true,
  });
  return item?.forceDelete;
}

async function pickSwitchStickyDepth(): Promise<boolean | undefined> {
  const items: SwitchStickyDepthQuickPickItem[] = [
    {
      label: vscode.l10n.t("Keep depth non-sticky"),
      description: vscode.l10n.t("Do not change the working copy ambient depth"),
      depthIsSticky: false,
    },
    {
      label: vscode.l10n.t("Make depth sticky"),
      description: vscode.l10n.t("Set the selected depth as the working copy ambient depth"),
      depthIsSticky: true,
    },
  ];
  const item = await vscode.window.showQuickPick(items, {
    title: vscode.l10n.t("SVN switch sticky depth"),
    placeHolder: vscode.l10n.t("Choose whether switch changes the ambient depth"),
    ignoreFocusOut: true,
  });
  return item?.depthIsSticky;
}

async function pickSwitchExternalsPolicy(): Promise<boolean | undefined> {
  const items: SwitchExternalsQuickPickItem[] = [
    {
      label: vscode.l10n.t("Ignore externals"),
      description: vscode.l10n.t("Skip SVN externals during switch"),
      ignoreExternals: true,
    },
    {
      label: vscode.l10n.t("Include externals"),
      description: vscode.l10n.t("Allow libsvn to switch SVN externals"),
      ignoreExternals: false,
    },
  ];
  const item = await vscode.window.showQuickPick(items, {
    title: vscode.l10n.t("SVN switch externals"),
    placeHolder: vscode.l10n.t("Choose how SVN externals are handled"),
    ignoreFocusOut: true,
  });
  return item?.ignoreExternals;
}

async function pickRelocateExternalsPolicy(): Promise<boolean | undefined> {
  const items: RelocateExternalsQuickPickItem[] = [
    {
      label: vscode.l10n.t("Ignore externals"),
      description: vscode.l10n.t("Skip SVN externals during relocate"),
      ignoreExternals: true,
    },
    {
      label: vscode.l10n.t("Include externals"),
      description: vscode.l10n.t("Allow libsvn to relocate SVN externals"),
      ignoreExternals: false,
    },
  ];
  const item = await vscode.window.showQuickPick(items, {
    title: vscode.l10n.t("SVN relocate externals"),
    placeHolder: vscode.l10n.t("Choose how SVN externals are handled"),
    ignoreFocusOut: true,
  });
  return item?.ignoreExternals;
}

async function pickSwitchAncestryPolicy(): Promise<boolean | undefined> {
  const items: SwitchAncestryQuickPickItem[] = [
    {
      label: vscode.l10n.t("Check ancestry"),
      description: vscode.l10n.t("Require a shared SVN ancestry for switch"),
      ignoreAncestry: false,
    },
    {
      label: vscode.l10n.t("Ignore ancestry"),
      description: vscode.l10n.t("Allow switch without checking SVN ancestry"),
      ignoreAncestry: true,
    },
  ];
  const item = await vscode.window.showQuickPick(items, {
    title: vscode.l10n.t("SVN switch ancestry"),
    placeHolder: vscode.l10n.t("Choose how SVN switch checks ancestry"),
    ignoreFocusOut: true,
  });
  return item?.ignoreAncestry;
}

async function promptUpdateOptions(workingCopyRoot: string): Promise<RepositoryUpdateOptions | undefined> {
  const revisionText = await vscode.window.showInputBox({
    title: vscode.l10n.t("Update SVN working copy to revision"),
    prompt: vscode.l10n.t("Enter the SVN revision number for {0}.", workingCopyRoot),
    placeHolder: vscode.l10n.t("Revision number"),
    ignoreFocusOut: true,
    validateInput: validateUpdateRevisionInput,
  });
  if (revisionText === undefined) {
    return undefined;
  }
  const depth = await pickUpdateDepth();
  if (depth === undefined) {
    return undefined;
  }
  const depthIsSticky = depth === "workingCopy" ? false : await pickUpdateStickyDepth();
  if (depthIsSticky === undefined) {
    return undefined;
  }
  const ignoreExternals = await pickUpdateExternalsPolicy();
  if (ignoreExternals === undefined) {
    return undefined;
  }
  const revision = parseUpdateRevisionInput(revisionText);
  if (revision === undefined) {
    throw new Error("SubversionR update revision input failed validation.");
  }
  return {
    revision,
    depth,
    depthIsSticky,
    ignoreExternals,
  };
}

function validateUpdateRevisionInput(value: string): string | undefined {
  if (parseUpdateRevisionInput(value) === undefined) {
    return vscode.l10n.t("Enter an SVN revision number from 0 to 2147483647.");
  }
  return undefined;
}

function validateMergeRevisionInput(value: string): string | undefined {
  return validateUpdateRevisionInput(value);
}

function parseMergeRevisionInput(value: string): number | undefined {
  return parseUpdateRevisionInput(value);
}

function validateCheckoutUrlInput(value: string): string | undefined {
  const result = validateCheckoutUrl(value);
  if (!result.valid) {
    return checkoutUrlValidationMessage(result);
  }
  return undefined;
}

function checkoutUrlValidationMessage(result: Exclude<CheckoutUrlValidationResult, { valid: true }>): string {
  switch (result.reason) {
    case "emptyOrControl":
      return vscode.l10n.t("Enter an SVN repository URL without line breaks.");
    case "invalidUrl":
      return vscode.l10n.t("Enter a valid SVN repository URL.");
    case "unsupportedScheme":
      return vscode.l10n.t("Use an SVN URL with file, http, https, svn, or svn+<tunnel>.");
    case "embeddedSecret":
      return vscode.l10n.t("Enter SVN passwords through the credential prompt, not in the URL.");
  }
}

function validateRepositoryRelativePathInput(value: string): string | undefined {
  if (!isRepositoryRelativePath(value)) {
    return vscode.l10n.t("Enter a repository-relative SVN path.");
  }
  return undefined;
}

function isRepositoryRelativePath(path: string): boolean {
  if (path === ".") {
    return true;
  }
  const normalized = path.replace(/\\/g, "/");
  if (
    path.includes("\\") ||
    normalized.startsWith("/") ||
    normalized.includes(":") ||
    normalized.includes("\0")
  ) {
    return false;
  }
  return normalized.split("/").every((part) => part.length > 0 && part !== "." && part !== "..");
}

function validateBranchCreateMessageInput(value: string): string | undefined {
  if (value.trim().length === 0 || value.includes("\0") || value.includes("\r")) {
    return vscode.l10n.t("Enter an SVN log message without carriage returns.");
  }
  return undefined;
}

function validateCheckoutTargetPathInput(value: string): string | undefined {
  if (
    value.trim().length === 0 ||
    value.includes("\0") ||
    value.includes("\r") ||
    value.includes("\n") ||
    !isAbsoluteCheckoutPath(value)
  ) {
    return vscode.l10n.t("Enter an absolute local folder path.");
  }
  return undefined;
}

function validateChangelistNameInput(value: string): string | undefined {
  if (value.trim().length === 0 || value.includes("\0") || value.includes("\r") || value.includes("\n")) {
    return vscode.l10n.t("Enter an SVN changelist name without line breaks.");
  }
  return undefined;
}

async function pickUpdateDepth(): Promise<UpdateDepth | undefined> {
  const items: UpdateDepthQuickPickItem[] = [
    {
      label: vscode.l10n.t("Working copy depth"),
      description: vscode.l10n.t("Use each node's current SVN working copy depth"),
      depth: "workingCopy",
    },
    {
      label: vscode.l10n.t("Empty"),
      description: vscode.l10n.t("Update only the target node"),
      depth: "empty",
    },
    {
      label: vscode.l10n.t("Files"),
      description: vscode.l10n.t("Update the target and its immediate file children"),
      depth: "files",
    },
    {
      label: vscode.l10n.t("Immediates"),
      description: vscode.l10n.t("Update the target and its immediate children"),
      depth: "immediates",
    },
    {
      label: vscode.l10n.t("Infinity"),
      description: vscode.l10n.t("Update the full subtree"),
      depth: "infinity",
    },
  ];
  const item = await vscode.window.showQuickPick(items, {
    title: vscode.l10n.t("SVN update depth"),
    placeHolder: vscode.l10n.t("Choose the SVN depth for update"),
    ignoreFocusOut: true,
  });
  return item?.depth;
}

async function pickUpdateStickyDepth(): Promise<boolean | undefined> {
  const items: UpdateStickyDepthQuickPickItem[] = [
    {
      label: vscode.l10n.t("Keep depth non-sticky"),
      description: vscode.l10n.t("Do not change the working copy ambient depth"),
      depthIsSticky: false,
    },
    {
      label: vscode.l10n.t("Make depth sticky"),
      description: vscode.l10n.t("Set the selected depth as the working copy ambient depth"),
      depthIsSticky: true,
    },
  ];
  const item = await vscode.window.showQuickPick(items, {
    title: vscode.l10n.t("SVN update sticky depth"),
    placeHolder: vscode.l10n.t("Choose whether update changes the ambient depth"),
    ignoreFocusOut: true,
  });
  return item?.depthIsSticky;
}

async function pickUpdateExternalsPolicy(): Promise<boolean | undefined> {
  const items: UpdateExternalsQuickPickItem[] = [
    {
      label: vscode.l10n.t("Ignore externals"),
      description: vscode.l10n.t("Skip SVN externals during update"),
      ignoreExternals: true,
    },
    {
      label: vscode.l10n.t("Include externals"),
      description: vscode.l10n.t("Allow libsvn to update SVN externals"),
      ignoreExternals: false,
    },
  ];
  const item = await vscode.window.showQuickPick(items, {
    title: vscode.l10n.t("SVN update externals"),
    placeHolder: vscode.l10n.t("Choose how SVN externals are handled"),
    ignoreFocusOut: true,
  });
  return item?.ignoreExternals;
}

function pathCasePolicy(platform: NodeJS.Platform): PathCasePolicy {
  if (platform === "win32") {
    return "case-insensitive";
  }
  throw new ExtensionRuntimeError(
    "SUBVERSIONR_REPOSITORY_PATH_CASE_UNSUPPORTED",
    "error.repository.pathCaseUnsupported",
  );
}

function isAbsoluteCheckoutPath(value: string): boolean {
  return nodePath.isAbsolute(value) || nodePath.win32.isAbsolute(value) || nodePath.posix.isAbsolute(value);
}

function consumeInstalledRedactionReportToken(): string | undefined {
  const token = process.env.SUBVERSIONR_INSTALLED_E2E_REDACTION_REPORT_TOKEN;
  delete process.env.SUBVERSIONR_INSTALLED_E2E_REDACTION_REPORT_TOKEN;
  return typeof token === "string" && token.length > 0 ? token : undefined;
}

function consumeInstalledRemoteWorkerReportToken(): string | undefined {
  const token = process.env.SUBVERSIONR_INSTALLED_E2E_REMOTE_WORKER_REPORT_TOKEN;
  delete process.env.SUBVERSIONR_INSTALLED_E2E_REMOTE_WORKER_REPORT_TOKEN;
  return typeof token === "string" && token.length > 0 ? token : undefined;
}

function consumeInstalledSvnAnonymousReportToken(): string | undefined {
  const token = process.env.SUBVERSIONR_INSTALLED_E2E_SVN_ANONYMOUS_REPORT_TOKEN;
  delete process.env.SUBVERSIONR_INSTALLED_E2E_SVN_ANONYMOUS_REPORT_TOKEN;
  return typeof token === "string" && token.length > 0 ? token : undefined;
}

function consumeInstalledSvnAnonymousStressCheckoutToken(): string | undefined {
  const token = process.env.SUBVERSIONR_INSTALLED_E2E_SVN_ANONYMOUS_STRESS_CHECKOUT_TOKEN;
  delete process.env.SUBVERSIONR_INSTALLED_E2E_SVN_ANONYMOUS_STRESS_CHECKOUT_TOKEN;
  return typeof token === "string" && token.length > 0 ? token : undefined;
}

function consumeInstalledSvnAnonymousNegativeReportToken(): string | undefined {
  const token = process.env.SUBVERSIONR_INSTALLED_E2E_SVN_ANONYMOUS_NEGATIVE_REPORT_TOKEN;
  delete process.env.SUBVERSIONR_INSTALLED_E2E_SVN_ANONYMOUS_NEGATIVE_REPORT_TOKEN;
  return typeof token === "string" && token.length > 0 ? token : undefined;
}

function consumeInstalledSvnAnonymousAuthzDeniedReportToken(): string | undefined {
  const token = process.env.SUBVERSIONR_INSTALLED_E2E_SVN_ANONYMOUS_AUTHZ_DENIED_REPORT_TOKEN;
  delete process.env.SUBVERSIONR_INSTALLED_E2E_SVN_ANONYMOUS_AUTHZ_DENIED_REPORT_TOKEN;
  return typeof token === "string" && token.length > 0 ? token : undefined;
}

function consumeInstalledSvnAnonymousStalledReadReportToken(): string | undefined {
  const token = process.env.SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_STALLED_READ_REPORT_TOKEN;
  delete process.env.SUBVERSIONR_INSTALLED_SVN_ANONYMOUS_STALLED_READ_REPORT_TOKEN;
  return typeof token === "string" && token.length > 0 ? token : undefined;
}

function consumeInstalledSvnAnonymousLocalEventZeroNetworkToken(): string | undefined {
  const token = process.env.SUBVERSIONR_INSTALLED_E2E_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_TOKEN;
  delete process.env.SUBVERSIONR_INSTALLED_E2E_SVN_ANONYMOUS_LOCAL_EVENT_ZERO_NETWORK_TOKEN;
  return typeof token === "string" && token.length > 0 ? token : undefined;
}

function backendStartupMessage(error: unknown): string {
  if (error instanceof BackendLaunchError) {
    switch (error.messageKey) {
      case "error.backend.configRequired":
        return vscode.l10n.t("SubversionR backend setting is required: {0}", String(error.safeArgs.field));
      case "error.backend.packageUnsupportedTarget":
        return vscode.l10n.t(
          "SubversionR packaged backend does not support this host: {0}/{1}.",
          String(error.safeArgs.platform),
          String(error.safeArgs.arch),
        );
      case "error.backend.packageResourceMissing":
        return vscode.l10n.t(
          "SubversionR packaged backend resource is missing: {0} for {1}.",
          String(error.safeArgs.resource),
          String(error.safeArgs.target),
        );
      case "error.backend.packagePathNotAbsolute":
        return vscode.l10n.t(
          "SubversionR packaged backend resource path is invalid: {0} for {1}.",
          String(error.safeArgs.resource),
          String(error.safeArgs.target),
        );
      case "error.backend.executablePathNotAbsolute":
        return vscode.l10n.t("SubversionR backend executable path must be absolute.");
      case "error.backend.bridgeDllPathNotAbsolute":
        return vscode.l10n.t("SubversionR bridge DLL path must be absolute.");
      case "error.backend.cacheRootNotAbsolute":
        return vscode.l10n.t("SubversionR backend cache root path must be absolute.");
      case "error.backend.protocolMajorUnsupported":
        return vscode.l10n.t(
          "SubversionR backend protocol major version is unsupported: expected {0}, got {1}.",
          String(error.safeArgs.expected),
          String(error.safeArgs.actual),
        );
      case "error.backend.protocolMinorUnsupported":
        return vscode.l10n.t(
          "SubversionR backend protocol version is too old: expected at least 1.{0}, got 1.{1}.",
          String(error.safeArgs.expectedMinimum),
          String(error.safeArgs.actual),
        );
      case "error.backend.cacheSchemaUnsupported":
        return vscode.l10n.t(
          "SubversionR backend cache schema is unsupported: {0} version {1} rollback {2}.",
          String(error.safeArgs.schemaId),
          String(error.safeArgs.version),
          String(error.safeArgs.rollback),
        );
      default:
        return vscode.l10n.t("SubversionR backend startup failed. Open the SubversionR log for details.");
    }
  }

  return vscode.l10n.t("SubversionR backend startup failed.");
}

function extensionErrorCode(error: unknown): string {
  if (typeof error === "object" && error !== null && "code" in error) {
    const code = (error as { code?: unknown }).code;
    if (typeof code === "string" && code.trim().length > 0) {
      return code;
    }
  }
  return "SUBVERSIONR_EXTENSION_COMMAND_FAILED";
}

class ExtensionRuntimeError extends Error {
  public constructor(
    public readonly code: string,
    public readonly messageKey: string,
  ) {
    super(code);
    this.name = "ExtensionRuntimeError";
  }
}
