import * as nodePath from "node:path";
import type {
  RepositoryDiscoveryCandidate,
  RepositoryDiscoveryService,
} from "./repositoryDiscoveryService";
import type { RepositoryCommitMessageHistory } from "./repositoryCommitMessageHistory";
import type { RepositorySession, RepositorySessionService } from "./repositorySessionService";
import {
  REPOSITORY_HISTORY_COMMAND_TARGET_KIND,
  type RepositoryHistoryCommandTarget,
} from "./repositoryHistoryCommandTarget";
import {
  discoveryBoundaryRoots,
  REPOSITORY_DISCOVERY_DEPTH,
  unopenedDiscoveryCandidates,
} from "./repositoryDiscoveryPlanning";
import type { HistoryBlameViewTarget } from "../history/historyBlameViewTarget";
import { historyCompareRevisionUriComponents } from "../history/historyCompareRevisionCommand";
import type { HistoryClient } from "../history/historyLogRpcClient";
import type { HistoryViewTarget } from "../history/historyViewTarget";
import type { RepositoryRefreshService, RepositoryResourceRefreshTarget } from "../status/repositoryRefreshService";
import type { RemoteStatusCheckService } from "../status/remoteStatusCheckService";
import type {
  OperationClient,
  OperationRunClientOptions,
  OperationRunResponse,
  OperationWarning,
  MergeRangeOperationRequest,
  ResolveOperationChoice,
  UpdateOperationDepth,
  UpdateOperationRevision,
} from "../operations/operationRunRpcClient";
import type {
  RepositoryCheckoutClient,
  RepositoryCheckoutClientOptions,
  RepositoryCheckoutDepth,
  RepositoryCheckoutRevision,
} from "./repositoryCheckoutRpcClient";
import type { PropertiesClient, PropertiesListResponse, PropertyEntry } from "../properties/propertiesListRpcClient";
import type {
  OperationJournalKind,
  OperationJournalResultCategory,
  OperationJournalScanPlan,
  RepositoryOperationJournal,
} from "../operations/repositoryOperationJournal";
import type { RepositoryOperationScheduler } from "../operations/repositoryOperationScheduler";
import type { SourceControlProjectionService } from "../scm/sourceControlProjectionService";
import type { ScmProjectedResource, ScmRepositoryProjection } from "../scm/sourceControlResourceStore";
import type { PathCasePolicy } from "../status/types";
import {
  BASE_DIFFABLE_FILE_CONTEXT_VALUE,
  isBaseDiffableProjectedResource,
} from "../scm/baseDiffResource";
import { isChangelistResourceGroupId } from "../scm/resourceStateClassifier";
import {
  createBaseContentUriComponents,
  type BaseContentUriComponents,
} from "../content/baseContentUri";
import {
  createHeadContentUriComponents,
  type HeadContentUriComponents,
} from "../content/headContentUri";
import type { RevisionContentUriComponents } from "../content/revisionContentUri";
import { requireTrustedWorkspace as requireTrustedWorkspaceState } from "../security/workspaceTrust";

export interface RepositoryCommandUi {
  workspaceRoots(): string[];
  pathCasePolicy(): PathCasePolicy;
  pickRepositoryCandidate(candidates: RepositoryDiscoveryCandidate[]): Promise<RepositoryDiscoveryCandidate | undefined>;
  pickOpenRepository(sessions: RepositorySession[]): Promise<RepositorySession | undefined>;
  showInformationMessage(message: string): Promise<void>;
  showWarningMessage(message: string): Promise<void>;
  showErrorMessage(message: string, ...actions: string[]): Promise<unknown>;
  showTextDocument(document: { title: string; content: string; language: string }): Promise<void>;
  confirmRevertResource(path: string): Promise<boolean>;
  confirmRemoveResource(path: string): Promise<boolean>;
  confirmRemoveResourceKeepLocal(path: string): Promise<boolean>;
  promptMoveDestination(sourcePath: string): Promise<string | undefined>;
  confirmDeleteUnversionedResources(paths: readonly string[]): Promise<boolean>;
  promptResolveChoice(path: string): Promise<ResolveOperationChoice | undefined>;
  promptChangelistName(paths: readonly string[]): Promise<string | undefined>;
  promptLockOptions(paths: readonly string[]): Promise<RepositoryLockOptions | undefined>;
  promptUnlockOptions(paths: readonly string[]): Promise<RepositoryUnlockOptions | undefined>;
  promptCleanupOptions(workingCopyRoot: string): Promise<RepositoryCleanupOptions | undefined>;
  promptUpdateOptions(workingCopyRoot: string): Promise<RepositoryUpdateOptions | undefined>;
  promptCheckoutOptions(): Promise<RepositoryCheckoutOptions | undefined>;
  promptBranchCreateOptions(workingCopyRoot: string): Promise<RepositoryBranchCreateOptions | undefined>;
  promptSwitchOptions(workingCopyRoot: string): Promise<RepositorySwitchOptions | undefined>;
  promptRelocateOptions(workingCopyRoot: string, fromUrl: string): Promise<RepositoryRelocateOptions | undefined>;
  promptMergeRangeOptions(workingCopyRoot: string): Promise<RepositoryMergeRangeOptions | undefined>;
  promptPropertySetOptions(path: string): Promise<RepositoryPropertySetOptions | undefined>;
  promptPropertyDeleteName(path: string, properties: readonly PropertyEntry[]): Promise<string | undefined>;
  promptExternalsPropertyValue(path: string, existingValue: string | undefined): Promise<string | undefined>;
  promptReviewCommitTargets(
    targets: readonly RepositoryReviewCommitTarget[],
    preselectedPaths: ReadonlySet<string>,
  ): Promise<readonly RepositoryReviewCommitTarget[] | undefined>;
  runOperationWithProgress<T>(
    title: string,
    task: (signal: AbortSignal | undefined) => Promise<T>,
  ): Promise<T>;
  workspaceTrusted(): boolean;
  hasUnsavedTextDocument(fsPath: string): boolean;
  deleteLocalFile(fsPath: string, options: { recursive: boolean }): Promise<void>;
  commitMessage(repositoryId: string): string;
  setCommitMessage(repositoryId: string, message: string): void;
  clearCommitMessage(repositoryId: string): void;
  promptCommitMessageHistory(messages: readonly string[]): Promise<string | undefined>;
  uriFile(fsPath: string): unknown;
  uriFromComponents(components: BaseContentUriComponents | HeadContentUriComponents | RevisionContentUriComponents): unknown;
  diffWithBase(left: unknown, right: unknown, title: string): Promise<void>;
  openBase(uri: unknown, title: string): Promise<void>;
  diffWithHead(left: unknown, right: unknown, title: string): Promise<void>;
  openHead(uri: unknown, title: string): Promise<void>;
  diffRevisions(left: unknown, right: unknown, title: string): Promise<void>;
  showHistory(target: HistoryViewTarget): Promise<void>;
  showBlame(target: HistoryBlameViewTarget): Promise<void>;
}

export interface RepositoryUpdateOptions {
  revision: UpdateOperationRevision;
  depth: UpdateOperationDepth;
  depthIsSticky: boolean;
  ignoreExternals: boolean;
}

export interface RepositoryCleanupOptions {
  breakLocks: boolean;
  fixRecordedTimestamps: boolean;
  clearDavCache: boolean;
  vacuumPristines: boolean;
  includeExternals: boolean;
}

export interface RepositoryCheckoutOptions {
  url: string;
  targetPath: string;
  revision: RepositoryCheckoutRevision;
  depth: RepositoryCheckoutDepth;
  ignoreExternals: boolean;
}

export interface RepositoryBranchCreateOptions {
  sourceUrl: string;
  destinationUrl: string;
  revision: UpdateOperationRevision;
  message: string;
  makeParents: boolean;
  ignoreExternals: boolean;
  switchAfterCreate: boolean;
}

export interface RepositorySwitchOptions {
  url: string;
  revision: UpdateOperationRevision;
  depth: UpdateOperationDepth;
  depthIsSticky: boolean;
  ignoreExternals: boolean;
  ignoreAncestry: boolean;
}

export interface RepositoryRelocateOptions {
  toUrl: string;
  ignoreExternals: boolean;
}

export interface RepositoryMergeRangeOptions {
  sourceUrl: string;
  targetPath: string;
  startRevision: number;
  endRevision: number;
  depth: MergeRangeOperationRequest["depth"];
  ignoreMergeinfo: boolean;
  diffIgnoreAncestry: boolean;
  forceDelete: boolean;
  recordOnly: boolean;
  dryRun: boolean;
  allowMixedRevisions: boolean;
}

export interface RepositoryReviewCommitTarget {
  path: string;
  changelist: string | null;
  status: string;
  directory: string;
}

export interface RepositoryPropertySetOptions {
  name: string;
  value: string;
}

export interface RepositoryLockOptions {
  comment: string | null;
  stealLock: boolean;
}

export interface RepositoryUnlockOptions {
  breakLock: boolean;
}

export interface RepositoryCommandControllerOptions {
  discoveryService: Pick<RepositoryDiscoveryService, "discoverRepositories" | "openDiscoveredRepository">;
  sessionService: Pick<
    RepositorySessionService,
    "closeRepository" | "listOpenSessions" | "openWorkingCopy" | "refreshSessionIdentityFromSnapshot"
  >;
  refreshService: Pick<
    RepositoryRefreshService,
    "refreshRepository" | "fullReconcileRepository" | "refreshResource" | "refreshTargets"
  >;
  remoteStatusCheckService: Pick<RemoteStatusCheckService, "checkRemoteChanges">;
  operationClient: Pick<
    OperationClient,
    | "add"
    | "branchCreate"
    | "changelistClear"
    | "changelistSet"
    | "cleanup"
    | "commit"
    | "lock"
    | "merge"
    | "move"
    | "propertyDelete"
    | "propertySet"
    | "remove"
    | "relocate"
    | "resolve"
    | "revert"
    | "switch"
    | "unlock"
    | "upgrade"
    | "update"
  >;
  checkoutClient: Pick<RepositoryCheckoutClient, "checkout">;
  propertiesClient: Pick<PropertiesClient, "listProperties">;
  operationJournal: Pick<RepositoryOperationJournal, "tryRecord">;
  diagnostics: {
    recordFailure(operation: string, error: unknown): void;
    show(): void;
  };
  historyClient: Pick<HistoryClient, "getLog">;
  operationScheduler: Pick<RepositoryOperationScheduler, "run">;
  sourceControlProjection: Pick<SourceControlProjectionService, "getCommitAllTargets" | "getProjection">;
  commitMessageHistory: Pick<RepositoryCommitMessageHistory, "messages" | "record">;
  includeMergedRevisions(): boolean;
  createRequestId(): string;
  now(): string;
  monotonicNowMs(): number;
  ui: RepositoryCommandUi;
  localize(message: string, ...args: unknown[]): string;
}

const SVN_INTERNAL_PATH = ".svn";
const LOCAL_CONFLICTED_LOCKED_CONTEXT_VALUES = [
  "subversionr.conflicted.locked",
  "subversionr.conflicted.changelisted.locked",
];
const LOCAL_CHANGED_FILE_LOCKED_CONTEXT_VALUES = [
  "subversionr.changedFile.locked",
  "subversionr.changedFile.changelisted.locked",
  "subversionr.changedFile.baseDiffable.locked",
  "subversionr.changedFile.baseDiffable.changelisted.locked",
];
const LOCAL_WORKING_COPY_METADATA_CONTEXT_VALUE = "subversionr.workingCopyMetadata";
const LOCAL_WORKING_COPY_METADATA_FILE_CONTEXT_VALUE = "subversionr.workingCopyMetadataFile";
const LOCAL_WORKING_COPY_METADATA_FILE_LOCKED_CONTEXT_VALUE = "subversionr.workingCopyMetadataFile.locked";
const LOCAL_LOCKED_CONTEXT_VALUES = [
  ...LOCAL_CONFLICTED_LOCKED_CONTEXT_VALUES,
  ...LOCAL_CHANGED_FILE_LOCKED_CONTEXT_VALUES,
  LOCAL_WORKING_COPY_METADATA_FILE_LOCKED_CONTEXT_VALUE,
];
const LOCAL_REFRESHABLE_CONTEXT_VALUES = new Set([
  "subversionr.conflicted",
  "subversionr.changedFile",
  BASE_DIFFABLE_FILE_CONTEXT_VALUE,
  "subversionr.changedDirectory",
  "subversionr.conflicted.changelisted",
  "subversionr.changedFile.changelisted",
  "subversionr.changedFile.baseDiffable.changelisted",
  "subversionr.changedDirectory.changelisted",
  "subversionr.changedUnknown",
  LOCAL_WORKING_COPY_METADATA_CONTEXT_VALUE,
  LOCAL_WORKING_COPY_METADATA_FILE_CONTEXT_VALUE,
  "subversionr.unversioned",
  "subversionr.external",
  "subversionr.ignored",
  ...LOCAL_LOCKED_CONTEXT_VALUES,
]);
const LOCAL_REVERTABLE_CONTEXT_VALUES = new Set([
  "subversionr.conflicted",
  "subversionr.changedFile",
  BASE_DIFFABLE_FILE_CONTEXT_VALUE,
  "subversionr.changedDirectory",
  "subversionr.conflicted.changelisted",
  "subversionr.changedFile.changelisted",
  "subversionr.changedFile.baseDiffable.changelisted",
  "subversionr.changedDirectory.changelisted",
  ...LOCAL_CONFLICTED_LOCKED_CONTEXT_VALUES,
  ...LOCAL_CHANGED_FILE_LOCKED_CONTEXT_VALUES,
]);
const LOCAL_ADDABLE_CONTEXT_VALUES = new Set(["subversionr.unversioned"]);
const LOCAL_IGNORABLE_CONTEXT_VALUES = new Set(["subversionr.unversioned"]);
const LOCAL_IGNORE_REMOVABLE_CONTEXT_VALUES = new Set(["subversionr.ignored"]);
const LOCAL_UNVERSIONED_DELETABLE_CONTEXT_VALUES = new Set(["subversionr.unversioned"]);
const LOCAL_CHANGELISTABLE_CONTEXT_VALUES = new Set([
  "subversionr.conflicted",
  "subversionr.changedFile",
  BASE_DIFFABLE_FILE_CONTEXT_VALUE,
  "subversionr.changedDirectory",
  "subversionr.conflicted.changelisted",
  "subversionr.changedFile.changelisted",
  "subversionr.changedFile.baseDiffable.changelisted",
  "subversionr.changedDirectory.changelisted",
  ...LOCAL_CONFLICTED_LOCKED_CONTEXT_VALUES,
  ...LOCAL_CHANGED_FILE_LOCKED_CONTEXT_VALUES,
]);
const LOCAL_LOCKABLE_CONTEXT_VALUES = new Set([
  "subversionr.conflicted",
  "subversionr.changedFile",
  BASE_DIFFABLE_FILE_CONTEXT_VALUE,
  "subversionr.conflicted.changelisted",
  "subversionr.changedFile.changelisted",
  "subversionr.changedFile.baseDiffable.changelisted",
  LOCAL_WORKING_COPY_METADATA_FILE_CONTEXT_VALUE,
]);
const LOCAL_LOCKABLE_PROJECTED_CONTEXT_VALUES = new Set([
  ...LOCAL_LOCKABLE_CONTEXT_VALUES,
  LOCAL_WORKING_COPY_METADATA_CONTEXT_VALUE,
]);
const LOCAL_UNLOCKABLE_CONTEXT_VALUES = new Set(LOCAL_LOCKED_CONTEXT_VALUES);
const LOCAL_COMMITTABLE_FILE_CONTEXT_VALUES = new Set([
  "subversionr.changedFile",
  BASE_DIFFABLE_FILE_CONTEXT_VALUE,
  "subversionr.changedFile.changelisted",
  "subversionr.changedFile.baseDiffable.changelisted",
  ...LOCAL_CHANGED_FILE_LOCKED_CONTEXT_VALUES,
]);
const LOCAL_COMMITTABLE_DIRECTORY_CONTEXT_VALUES = new Set([
  "subversionr.changedDirectory",
  "subversionr.changedDirectory.changelisted",
]);
const LOCAL_COMMITTABLE_CONTEXT_VALUES = new Set([
  ...LOCAL_COMMITTABLE_FILE_CONTEXT_VALUES,
  ...LOCAL_COMMITTABLE_DIRECTORY_CONTEXT_VALUES,
]);
const LOCAL_BASE_DIFFABLE_CONTEXT_VALUES = new Set([
  BASE_DIFFABLE_FILE_CONTEXT_VALUE,
  "subversionr.changedFile.baseDiffable.changelisted",
  "subversionr.changedFile.baseDiffable.locked",
  "subversionr.changedFile.baseDiffable.changelisted.locked",
]);
const HEAD_CONTENT_CONTEXT_VALUES = new Set([
  ...LOCAL_BASE_DIFFABLE_CONTEXT_VALUES,
  "subversionr.incomingFile",
  "subversionr.incomingFile.locked",
]);
const LOCAL_HISTORY_FILE_CONTEXT_VALUES = new Set([
  "subversionr.conflicted",
  "subversionr.changedFile",
  BASE_DIFFABLE_FILE_CONTEXT_VALUE,
  "subversionr.conflicted.changelisted",
  "subversionr.changedFile.changelisted",
  "subversionr.changedFile.baseDiffable.changelisted",
  ...LOCAL_CONFLICTED_LOCKED_CONTEXT_VALUES,
  ...LOCAL_CHANGED_FILE_LOCKED_CONTEXT_VALUES,
]);
const LOCAL_MERGEINFO_CONTEXT_VALUES = new Set([
  "subversionr.conflicted",
  "subversionr.conflicted.changelisted",
  "subversionr.changedFile",
  "subversionr.changedFile.changelisted",
  BASE_DIFFABLE_FILE_CONTEXT_VALUE,
  "subversionr.changedFile.baseDiffable.changelisted",
  "subversionr.changedDirectory",
  "subversionr.changedDirectory.changelisted",
  LOCAL_WORKING_COPY_METADATA_CONTEXT_VALUE,
  LOCAL_WORKING_COPY_METADATA_FILE_CONTEXT_VALUE,
  ...LOCAL_CONFLICTED_LOCKED_CONTEXT_VALUES,
  ...LOCAL_CHANGED_FILE_LOCKED_CONTEXT_VALUES,
  LOCAL_WORKING_COPY_METADATA_FILE_LOCKED_CONTEXT_VALUE,
]);
const LOCAL_PROPERTIES_CONTEXT_VALUES = new Set(LOCAL_MERGEINFO_CONTEXT_VALUES);
const LOCAL_BLAME_FILE_CONTEXT_VALUES = new Set([
  "subversionr.conflicted",
  "subversionr.changedFile",
  BASE_DIFFABLE_FILE_CONTEXT_VALUE,
  "subversionr.conflicted.changelisted",
  "subversionr.changedFile.changelisted",
  "subversionr.changedFile.baseDiffable.changelisted",
  ...LOCAL_CONFLICTED_LOCKED_CONTEXT_VALUES,
  ...LOCAL_CHANGED_FILE_LOCKED_CONTEXT_VALUES,
]);
const LOCAL_REMOVABLE_CONTEXT_VALUES = new Set([
  "subversionr.conflicted",
  "subversionr.changedFile",
  BASE_DIFFABLE_FILE_CONTEXT_VALUE,
  "subversionr.changedDirectory",
  "subversionr.conflicted.changelisted",
  "subversionr.changedFile.changelisted",
  "subversionr.changedFile.baseDiffable.changelisted",
  "subversionr.changedDirectory.changelisted",
  ...LOCAL_CONFLICTED_LOCKED_CONTEXT_VALUES,
  ...LOCAL_CHANGED_FILE_LOCKED_CONTEXT_VALUES,
]);
const LOCAL_MOVABLE_CONTEXT_VALUES = new Set([
  "subversionr.conflicted",
  "subversionr.changedFile",
  BASE_DIFFABLE_FILE_CONTEXT_VALUE,
  "subversionr.changedDirectory",
  "subversionr.conflicted.changelisted",
  "subversionr.changedFile.changelisted",
  "subversionr.changedFile.baseDiffable.changelisted",
  "subversionr.changedDirectory.changelisted",
  ...LOCAL_CONFLICTED_LOCKED_CONTEXT_VALUES,
  ...LOCAL_CHANGED_FILE_LOCKED_CONTEXT_VALUES,
]);
const LOCAL_RESOLVABLE_CONTEXT_VALUES = new Set([
  "subversionr.conflicted",
  "subversionr.conflicted.changelisted",
  ...LOCAL_CONFLICTED_LOCKED_CONTEXT_VALUES,
]);
const REMOTE_UPDATEABLE_CONTEXT_VALUES = new Set([
  "subversionr.incoming",
  "subversionr.incoming.locked",
  "subversionr.incomingFile",
  "subversionr.incomingFile.locked",
]);
const HEAD_WORKING_COPY_UPDATE_OPTIONS: RepositoryUpdateOptions = {
  revision: "head",
  depth: "workingCopy",
  depthIsSticky: false,
  ignoreExternals: true,
};
const MAX_SVN_REVNUM = 2_147_483_647;

export class RepositoryCommandController {
  private readonly reviewCommitSelections = new Map<string, Set<string>>();

  public constructor(private readonly options: RepositoryCommandControllerOptions) {}

  public async openRepository(): Promise<void> {
    try {
      const workspaceRoots = this.options.ui.workspaceRoots();
      if (workspaceRoots.length === 0) {
        await this.options.ui.showWarningMessage(
          this.options.localize("Open a workspace folder before opening an SVN repository."),
        );
        return;
      }
      const pathCase = this.options.ui.pathCasePolicy();
      const openSessions = this.options.sessionService.listOpenSessions();
      const ignoredRoots = openSessions.map((session) => session.identity.workingCopyRoot);

      const discovery = await this.options.discoveryService.discoverRepositories({
        workspaceRoots,
        discoverNested: true,
        discoveryDepth: REPOSITORY_DISCOVERY_DEPTH,
        discoveryIgnore: [],
        ignoredRoots,
        externalsMode: "lazy",
      });
      const candidates = unopenedDiscoveryCandidates(discovery.candidates, openSessions, pathCase);
      if (discovery.candidates.length > 0 && candidates.length === 0) {
        await this.options.ui.showWarningMessage(
          this.options.localize("All discovered SVN working copies are already open."),
        );
        return;
      }
      const candidate = await this.selectCandidate(candidates);
      if (!candidate) {
        return;
      }

      const boundaryRoots = discoveryBoundaryRoots(
        discovery.candidates,
        candidate,
        pathCase,
        openSessions,
        discovery.fileExternalBoundaries,
      );
      const session = await this.options.discoveryService.openDiscoveredRepository({
        candidate,
        pathCase,
        ...(boundaryRoots.length > 0 ? { boundaryRoots } : {}),
      });
      this.showCommandInformation(
        this.options.localize("SubversionR opened SVN working copy: {0}", session.identity.workingCopyRoot),
      );
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async closeRepository(repositoryId?: unknown): Promise<void> {
    try {
      const session = await this.selectOpenSessionForRepository(
        repositoryId,
        closeRepositoryIdInvalid,
        closeRepositoryNotOpen,
      );
      if (!session) {
        return;
      }
      await this.options.sessionService.closeRepository(session.repositoryId);
      this.showCommandInformation(
        this.options.localize("SubversionR closed SVN working copy: {0}", session.identity.workingCopyRoot),
      );
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async checkoutRepository(): Promise<void> {
    try {
      this.requireTrustedWorkspace();
      const checkoutOptions = await this.options.ui.promptCheckoutOptions();
      if (!checkoutOptions) {
        return;
      }
      const pathCase = this.options.ui.pathCasePolicy();
      const result = await this.options.ui.runOperationWithProgress(
        this.options.localize("Checking out SVN working copy"),
        async (signal) => {
          const options = checkoutRunOptions(signal);
          const request = validateRepositoryCheckoutOptions(checkoutOptions);
          return options
            ? await this.options.checkoutClient.checkout(request, options)
            : await this.options.checkoutClient.checkout(request);
        },
      );
      const session = await this.options.sessionService.openWorkingCopy({
        path: result.workingCopyPath,
        pathCase,
      });
      this.showCommandInformation(
        this.options.localize(
          "SubversionR checked out SVN working copy at revision {0}: {1}",
          result.revision,
          session.identity.workingCopyRoot,
        ),
      );
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async refreshRepository(repositoryId?: unknown): Promise<void> {
    try {
      const session = await this.selectOpenSessionForRepository(
        repositoryId,
        refreshRepositoryIdInvalid,
        refreshRepositoryNotOpen,
      );
      if (!session) {
        return;
      }
      await this.options.ui.runOperationWithProgress(
        this.options.localize("Refreshing SVN working copy"),
        async (signal) => {
          const options = statusRefreshRunOptions(signal);
          if (options === undefined) {
            await this.options.refreshService.refreshRepository(session.repositoryId);
          } else {
            await this.options.refreshService.refreshRepository(session.repositoryId, options);
          }
        },
      );
      this.showCommandInformation(
        this.options.localize("SubversionR refreshed SVN working copy: {0}", session.identity.workingCopyRoot),
      );
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async checkRemoteChanges(repositoryId?: unknown): Promise<void> {
    try {
      this.requireTrustedWorkspace();
      const session = await this.selectOpenSessionForRepository(
        repositoryId,
        checkRemoteChangesRepositoryIdInvalid,
        checkRemoteChangesRepositoryNotOpen,
      );
      if (!session) {
        return;
      }
      const incomingChanges = await this.options.ui.runOperationWithProgress(
        this.options.localize("Checking SVN remote changes"),
        async (signal) => {
          const request = {
            repositoryId: session.repositoryId,
            epoch: session.epoch,
          };
          const options = statusRefreshRunOptions(signal);
          if (options === undefined) {
            return await this.options.remoteStatusCheckService.checkRemoteChanges(request);
          }
          return await this.options.remoteStatusCheckService.checkRemoteChanges(request, options);
        },
      );
      if (incomingChanges === 0) {
        this.showCommandInformation(
          this.options.localize("No incoming SVN changes: {0}", session.identity.workingCopyRoot),
        );
      } else {
        this.showCommandInformation(
          this.options.localize(
            "SubversionR incoming SVN changes: {0} ({1})",
            incomingChanges,
            session.identity.workingCopyRoot,
          ),
        );
      }
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async fullReconcileRepository(repositoryId?: unknown): Promise<void> {
    try {
      const session = await this.selectOpenSessionForRepository(
        repositoryId,
        fullReconcileRepositoryIdInvalid,
        fullReconcileRepositoryNotOpen,
      );
      if (!session) {
        return;
      }
      await this.options.ui.runOperationWithProgress(
        this.options.localize("Reconciling SVN working copy status"),
        async (signal) => {
          const target = {
            repositoryId: session.repositoryId,
            epoch: session.epoch,
          };
          const options = statusRefreshRunOptions(signal);
          if (options === undefined) {
            await this.options.refreshService.fullReconcileRepository(target);
          } else {
            await this.options.refreshService.fullReconcileRepository(target, options);
          }
        },
      );
      this.showCommandInformation(
        this.options.localize("SubversionR completed full reconcile: {0}", session.identity.workingCopyRoot),
      );
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async cleanupRepository(repositoryId?: unknown): Promise<void> {
    try {
      this.requireTrustedWorkspace();
      const session = await this.selectOpenSessionForRepository(
        repositoryId,
        cleanupRepositoryIdInvalid,
        cleanupRepositoryNotOpen,
      );
      if (!session) {
        return;
      }
      const cleanupOptions = await this.options.ui.promptCleanupOptions(session.identity.workingCopyRoot);
      if (!cleanupOptions) {
        return;
      }
      const validatedOptions = validateRepositoryCleanupOptions(cleanupOptions);
      await this.options.operationScheduler.run(session.repositoryId, async () => {
        await this.runJournaledOperation(
          "cleanup",
          this.options.localize("Cleaning up SVN working copy"),
          session.repositoryId,
          1,
          (operationOptions) => {
            const request = {
              repositoryId: session.repositoryId,
              epoch: session.epoch,
              path: "." as const,
              ...validatedOptions,
            };
            return operationOptions
              ? this.options.operationClient.cleanup(request, operationOptions)
              : this.options.operationClient.cleanup(request);
          },
        );
        await this.options.refreshService.fullReconcileRepository({
          repositoryId: session.repositoryId,
          epoch: session.epoch,
        });
      });
      this.showCommandInformation(
        this.options.localize("SubversionR cleaned up SVN working copy: {0}", session.identity.workingCopyRoot),
      );
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async upgradeWorkingCopy(repositoryId?: unknown): Promise<void> {
    try {
      this.requireTrustedWorkspace();
      const session = await this.selectOpenSessionForRepository(
        repositoryId,
        upgradeWorkingCopyRepositoryIdInvalid,
        upgradeWorkingCopyRepositoryNotOpen,
      );
      if (!session) {
        return;
      }
      await this.options.operationScheduler.run(session.repositoryId, async () => {
        await this.runJournaledOperation(
          "upgrade",
          this.options.localize("Upgrading SVN working copy"),
          session.repositoryId,
          1,
          (operationOptions) => {
            const request = {
              repositoryId: session.repositoryId,
              epoch: session.epoch,
              path: "." as const,
            };
            return operationOptions
              ? this.options.operationClient.upgrade(request, operationOptions)
              : this.options.operationClient.upgrade(request);
          },
        );
        await this.options.refreshService.fullReconcileRepository({
          repositoryId: session.repositoryId,
          epoch: session.epoch,
        });
      });
      this.showCommandInformation(
        this.options.localize("SubversionR upgraded SVN working copy: {0}", session.identity.workingCopyRoot),
      );
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async updateRepository(repositoryId?: unknown): Promise<void> {
    try {
      this.requireTrustedWorkspace();
      const session = await this.selectOpenSessionForRepository(
        repositoryId,
        updateRepositoryIdInvalid,
        updateRepositoryNotOpen,
      );
      if (!session) {
        return;
      }
      const result = await this.runRepositoryUpdate(
        session,
        HEAD_WORKING_COPY_UPDATE_OPTIONS,
        this.options.localize("Updating SVN working copy"),
      );
      this.showUpdateCompletion(
        this.options.localize(
          "SubversionR updated SVN working copy to revision {0}: {1}",
          result.revision,
          session.identity.workingCopyRoot,
        ),
        session,
        ["."],
      );
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async updateToRevision(repositoryId?: unknown): Promise<void> {
    try {
      this.requireTrustedWorkspace();
      const session = await this.selectOpenSessionForRepository(
        repositoryId,
        updateToRevisionRepositoryIdInvalid,
        updateToRevisionRepositoryNotOpen,
      );
      if (!session) {
        return;
      }
      const updateOptions = await this.options.ui.promptUpdateOptions(session.identity.workingCopyRoot);
      if (!updateOptions) {
        return;
      }
      const result = await this.runRepositoryUpdate(
        session,
        validateRepositoryUpdateOptions(updateOptions),
        this.options.localize("Updating SVN working copy"),
      );
      this.showUpdateCompletion(
        this.options.localize(
          "SubversionR updated SVN working copy to revision {0}: {1}",
          result.revision,
          session.identity.workingCopyRoot,
        ),
        session,
        ["."],
      );
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async branchCreateRepository(repositoryId?: unknown): Promise<void> {
    try {
      this.requireTrustedWorkspace();
      const session = await this.selectOpenSessionForRepository(
        repositoryId,
        branchCreateRepositoryIdInvalid,
        branchCreateRepositoryNotOpen,
      );
      if (!session) {
        return;
      }
      const branchOptions = await this.options.ui.promptBranchCreateOptions(session.identity.workingCopyRoot);
      if (!branchOptions) {
        return;
      }
      const validatedOptions = validateRepositoryBranchCreateOptions(branchOptions);
      const { switchAfterCreate, ...branchRequestOptions } = validatedOptions;
      const result = await this.options.operationScheduler.run(session.repositoryId, async () => {
        const branchResult = await this.runJournaledOperation(
          "branchCreate",
          this.options.localize("Creating SVN branch or tag"),
          session.repositoryId,
          0,
          (operationOptions) => {
            const request = {
              repositoryId: session.repositoryId,
              epoch: session.epoch,
              ...branchRequestOptions,
            };
            return operationOptions
              ? this.options.operationClient.branchCreate(request, operationOptions)
              : this.options.operationClient.branchCreate(request);
          },
        );
        if (!switchAfterCreate) {
          return { branchResult, switchResult: undefined };
        }
        const switchResult = await this.runJournaledOperation(
          "switch",
          this.options.localize("Switching SVN working copy"),
          session.repositoryId,
          1,
          (operationOptions) => {
            const request = {
              repositoryId: session.repositoryId,
              epoch: session.epoch,
              path: "." as const,
              url: validatedOptions.destinationUrl,
              revision: "head" as const,
              depth: "workingCopy" as const,
              depthIsSticky: false,
              ignoreExternals: validatedOptions.ignoreExternals,
              ignoreAncestry: false,
            };
            return operationOptions
              ? this.options.operationClient.switch(request, operationOptions)
              : this.options.operationClient.switch(request);
          },
        );
        await this.options.refreshService.fullReconcileRepository({
          repositoryId: session.repositoryId,
          epoch: session.epoch,
        });
        return { branchResult, switchResult };
      });
      if (result.switchResult === undefined) {
        this.showCommandInformation(
          this.options.localize(
            "SubversionR created SVN branch/tag at revision {0}: {1}",
            result.branchResult.revision,
            validatedOptions.destinationUrl,
          ),
        );
        return;
      }
      this.showCommandInformation(
        this.options.localize(
          "SubversionR created SVN branch/tag at revision {0} and switched working copy to revision {1}: {2}",
          result.branchResult.revision,
          result.switchResult.revision,
          validatedOptions.destinationUrl,
        ),
      );
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async switchRepository(repositoryId?: unknown): Promise<void> {
    try {
      this.requireTrustedWorkspace();
      const session = await this.selectOpenSessionForRepository(
        repositoryId,
        switchRepositoryIdInvalid,
        switchRepositoryNotOpen,
      );
      if (!session) {
        return;
      }
      const switchOptions = await this.options.ui.promptSwitchOptions(session.identity.workingCopyRoot);
      if (!switchOptions) {
        return;
      }
      const validatedOptions = validateRepositorySwitchOptions(switchOptions);
      const result = await this.options.operationScheduler.run(session.repositoryId, async () => {
        const switchResult = await this.runJournaledOperation(
          "switch",
          this.options.localize("Switching SVN working copy"),
          session.repositoryId,
          1,
          (operationOptions) => {
            const request = {
              repositoryId: session.repositoryId,
              epoch: session.epoch,
              path: ".",
              ...validatedOptions,
            };
            return operationOptions
              ? this.options.operationClient.switch(request, operationOptions)
              : this.options.operationClient.switch(request);
          },
        );
        await this.options.refreshService.fullReconcileRepository({
          repositoryId: session.repositoryId,
          epoch: session.epoch,
        });
        return switchResult;
      });
      this.showCommandInformation(
        this.options.localize(
          "SubversionR switched SVN working copy to revision {0}: {1}",
          result.revision,
          validatedOptions.url,
        ),
      );
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async relocateRepository(repositoryId?: unknown): Promise<void> {
    try {
      this.requireTrustedWorkspace();
      const session = await this.selectOpenSessionForRepository(
        repositoryId,
        relocateRepositoryIdInvalid,
        relocateRepositoryNotOpen,
      );
      if (!session) {
        return;
      }
      const fromUrl = session.identity.repositoryRootUrl;
      const relocateOptions = await this.options.ui.promptRelocateOptions(session.identity.workingCopyRoot, fromUrl);
      if (!relocateOptions) {
        return;
      }
      const validatedOptions = validateRepositoryRelocateOptions(relocateOptions, fromUrl);
      await this.options.operationScheduler.run(session.repositoryId, async () => {
        await this.runJournaledOperation(
          "relocate",
          this.options.localize("Relocating SVN working copy"),
          session.repositoryId,
          1,
          (operationOptions) => {
            const request = {
              repositoryId: session.repositoryId,
              epoch: session.epoch,
              fromUrl,
              ...validatedOptions,
            };
            return operationOptions
              ? this.options.operationClient.relocate(request, operationOptions)
              : this.options.operationClient.relocate(request);
          },
        );
        await this.options.refreshService.fullReconcileRepository({
          repositoryId: session.repositoryId,
          epoch: session.epoch,
        });
        this.options.sessionService.refreshSessionIdentityFromSnapshot({
          repositoryId: session.repositoryId,
          epoch: session.epoch,
        });
      });
      this.showCommandInformation(
        this.options.localize(
          "SubversionR relocated SVN working copy to: {0}",
          validatedOptions.toUrl,
        ),
      );
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async mergeRangeRepository(repositoryId?: unknown): Promise<void> {
    try {
      this.requireTrustedWorkspace();
      const session = await this.selectOpenSessionForRepository(
        repositoryId,
        mergeRangeRepositoryIdInvalid,
        mergeRangeRepositoryNotOpen,
      );
      if (!session) {
        return;
      }
      const mergeOptions = await this.options.ui.promptMergeRangeOptions(session.identity.workingCopyRoot);
      if (!mergeOptions) {
        return;
      }
      const validatedOptions = validateRepositoryMergeRangeOptions(mergeOptions);
      const result = await this.options.operationScheduler.run(session.repositoryId, async () => {
        const mergeResult = await this.runJournaledOperation(
          "merge",
          this.options.localize("Merging SVN revision range"),
          session.repositoryId,
          1,
          (operationOptions) => {
            const request = {
              repositoryId: session.repositoryId,
              epoch: session.epoch,
              ...validatedOptions,
            };
            return operationOptions
              ? this.options.operationClient.merge(request, operationOptions)
              : this.options.operationClient.merge(request);
          },
        );
        await this.options.refreshService.fullReconcileRepository({
          repositoryId: session.repositoryId,
          epoch: session.epoch,
        });
        return mergeResult;
      });
      const mergeLabels = this.mergeDocumentLabels();
      const mergeDirection = mergeRangeDirection(validatedOptions, mergeLabels);
      this.showCommandInformation(
        this.options.localize(
          "SubversionR merged SVN revision range r{0}:r{1} ({2}) from {3} into {4} at {5}: {6} affected SVN path(s), {7} skipped SVN path(s), {8} SVN operation warning(s)",
          validatedOptions.startRevision,
          validatedOptions.endRevision,
          mergeDirection,
          validatedOptions.sourceUrl,
          session.identity.workingCopyRoot,
          validatedOptions.targetPath,
          result.summary.affectedPaths,
          result.summary.skippedPaths,
          result.warnings.length,
        ),
      );
      const resultLabel = `${validatedOptions.sourceUrl} r${validatedOptions.startRevision}:r${validatedOptions.endRevision} -> ${session.identity.workingCopyRoot}`;
      await this.options.ui.showTextDocument({
        title: this.options.localize("SVN Merge Result: {0}", resultLabel),
        language: "markdown",
        content: svnMergePreviewDocument(
          this.options.localize("SVN merge result for {0}", resultLabel),
          validatedOptions.targetPath,
          result.summary,
          result.touchedPaths,
          fullReconcileDocumentState(),
          result.warnings,
          validatedOptions,
          mergeLabels,
        ),
      });
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async previewMergeRangeRepository(repositoryId?: unknown): Promise<void> {
    try {
      this.requireTrustedWorkspace();
      const session = await this.selectOpenSessionForRepository(
        repositoryId,
        previewMergeRangeRepositoryIdInvalid,
        previewMergeRangeRepositoryNotOpen,
      );
      if (!session) {
        return;
      }
      const mergeOptions = await this.options.ui.promptMergeRangeOptions(session.identity.workingCopyRoot);
      if (!mergeOptions) {
        return;
      }
      const validatedOptions = validateRepositoryMergeRangeOptions({
        ...mergeOptions,
        dryRun: true,
      });
      const result = await this.options.operationScheduler.run(session.repositoryId, async () =>
        await this.runJournaledOperation(
          "mergePreview",
          this.options.localize("Previewing SVN merge revision range"),
          session.repositoryId,
          1,
          (operationOptions) => {
            const request = {
              repositoryId: session.repositoryId,
              epoch: session.epoch,
              ...validatedOptions,
            };
            return operationOptions
              ? this.options.operationClient.merge(request, operationOptions)
              : this.options.operationClient.merge(request);
          },
        ),
      );
      const mergeLabels = this.mergeDocumentLabels();
      const mergeDirection = mergeRangeDirection(validatedOptions, mergeLabels);
      this.showCommandInformation(
        this.options.localize(
          "SubversionR previewed SVN merge range r{0}:r{1} ({2}) from {3} into {4} at {5}: {6} affected SVN path(s), {7} skipped SVN path(s), {8} SVN operation warning(s)",
          validatedOptions.startRevision,
          validatedOptions.endRevision,
          mergeDirection,
          validatedOptions.sourceUrl,
          session.identity.workingCopyRoot,
          validatedOptions.targetPath,
          result.summary.affectedPaths,
          result.summary.skippedPaths,
          result.warnings.length,
        ),
      );
      const previewLabel = `${validatedOptions.sourceUrl} r${validatedOptions.startRevision}:r${validatedOptions.endRevision} -> ${session.identity.workingCopyRoot}`;
      await this.options.ui.showTextDocument({
        title: this.options.localize("SVN Merge Preview: {0}", previewLabel),
        language: "markdown",
        content: svnMergePreviewDocument(
          this.options.localize("SVN merge preview for {0}", previewLabel),
          validatedOptions.targetPath,
          result.summary,
          result.touchedPaths,
          result.reconcile,
          result.warnings,
          validatedOptions,
          mergeLabels,
        ),
      });
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  private mergeDocumentLabels(): MergeDocumentLabels {
    return {
      sourceUrl: this.options.localize("SVN merge source URL"),
      startRevision: this.options.localize("SVN merge start revision"),
      endRevision: this.options.localize("SVN merge end revision"),
      mergeDirection: this.options.localize("SVN merge direction"),
      additiveMerge: this.options.localize("Additive merge"),
      subtractiveMerge: this.options.localize("Subtractive merge"),
      targetPath: this.options.localize("SVN merge target path"),
      statusReconcileMode: this.options.localize("SVN status reconcile mode"),
      statusRefreshTargetCount: this.options.localize("SVN status refresh target count"),
      affectedPathCount: this.options.localize("Affected SVN path count"),
      skippedPathCount: this.options.localize("Skipped SVN path count"),
      warningCount: this.options.localize("SVN operation warning count"),
      mergeOption: this.options.localize("SVN merge option"),
      mergeOptionValue: this.options.localize("SVN merge option value"),
      mergeDepth: this.options.localize("SVN merge depth"),
      mergeDryRun: this.options.localize("SVN merge dry run"),
      recordOnly: this.options.localize("Record only"),
      ignoreMergeinfo: this.options.localize("Ignore mergeinfo"),
      ignoreAncestry: this.options.localize("Ignore ancestry"),
      allowMixedRevisions: this.options.localize("Allow mixed revisions"),
      allowForcedDeletes: this.options.localize("Allow forced deletes"),
      yes: this.options.localize("Yes"),
      no: this.options.localize("No"),
      fullReconcile: this.options.localize("Full reconcile"),
      targetedStatusRefresh: this.options.localize("Targeted status refresh"),
      noStatusRefresh: this.options.localize("No status refresh"),
      affectedPath: this.options.localize("Affected SVN path"),
      noAffectedPaths: this.options.localize("No affected SVN paths."),
      skippedPath: this.options.localize("Skipped SVN path"),
      noSkippedPaths: this.options.localize("No skipped SVN paths."),
      skippedPathDetailsUnavailable: this.options.localize("Skipped SVN path details unavailable."),
      operationWarning: this.options.localize("SVN operation warning"),
      warningKey: this.options.localize("SVN warning key"),
      warningDetails: this.options.localize("SVN warning details"),
      statusRefreshTarget: this.options.localize("SVN status refresh target"),
      statusRefreshDepth: this.options.localize("SVN status refresh depth"),
      statusRefreshReason: this.options.localize("SVN status refresh reason"),
    };
  }

  public async showRepositoryMergeinfo(repositoryId?: unknown): Promise<void> {
    try {
      this.requireTrustedWorkspace();
      const session = await this.selectOpenSessionForRepository(
        repositoryId,
        repositoryMergeinfoRepositoryIdInvalid,
        repositoryMergeinfoRepositoryNotOpen,
      );
      if (!session) {
        return;
      }
      const properties = await this.options.ui.runOperationWithProgress(
        this.options.localize("Loading SVN mergeinfo"),
        async () =>
          await this.options.propertiesClient.listProperties({
            repositoryId: session.repositoryId,
            epoch: session.epoch,
            path: ".",
          }),
      );
      const mergeinfo = svnMergeinfoPropertyValue(properties);
      if (mergeinfo === undefined || mergeinfo.trim().length === 0) {
        this.showCommandInformation(
          this.options.localize(
            "No SVN mergeinfo found on working copy root: {0}",
            session.identity.workingCopyRoot,
          ),
        );
        return;
      }

      await this.options.ui.showTextDocument({
        title: this.options.localize("SVN Mergeinfo: {0}", session.identity.workingCopyRoot),
        language: "markdown",
        content: svnMergeinfoDocument(
          this.options.localize("SVN mergeinfo for {0}", session.identity.workingCopyRoot),
          ".",
          properties.source,
          mergeinfo,
          {
            mergeinfoPath: this.options.localize("SVN mergeinfo path"),
            propertySource: this.options.localize("SVN property source"),
            mergeinfoSourcePathCount: this.options.localize("SVN mergeinfo source path count"),
            mergeinfoRevisionRangeCount: this.options.localize("SVN mergeinfo revision range count"),
            mergeinfoUnparsedLineCount: this.options.localize("SVN mergeinfo unparsed line count"),
            mergeinfoUnparsedRevisionRangeCount: this.options.localize(
              "SVN mergeinfo unparsed revision range count",
            ),
            sourcePath: this.options.localize("Source path"),
            sourceRevisionRangeCount: this.options.localize("SVN mergeinfo source revision range count"),
            latestMergedRevision: this.options.localize("Latest merged revision"),
            nonInheritableRangeCount: this.options.localize("SVN mergeinfo non-inheritable range count"),
            rangeStartRevision: this.options.localize("SVN mergeinfo range start revision"),
            rangeEndRevision: this.options.localize("SVN mergeinfo range end revision"),
            nonInheritableRange: this.options.localize("Non-inheritable SVN mergeinfo range"),
            revisionRanges: this.options.localize("Revision ranges"),
            noParsedSourcePaths: this.options.localize("No parsed SVN mergeinfo source paths."),
            unparsedMergeinfoRange: this.options.localize("Unparsed svn:mergeinfo revision range"),
            unparsedMergeinfoLine: this.options.localize("Unparsed svn:mergeinfo line"),
            rawMergeinfo: this.options.localize("Raw svn:mergeinfo"),
            yes: this.options.localize("Yes"),
            no: this.options.localize("No"),
          },
        ),
      });
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async showRepositoryProperties(repositoryId?: unknown): Promise<void> {
    try {
      this.requireTrustedWorkspace();
      const session = await this.selectOpenSessionForRepository(
        repositoryId,
        repositoryPropertiesRepositoryIdInvalid,
        repositoryPropertiesRepositoryNotOpen,
      );
      if (!session) {
        return;
      }
      const properties = await this.options.ui.runOperationWithProgress(
        this.options.localize("Loading SVN properties"),
        async () =>
          await this.options.propertiesClient.listProperties({
            repositoryId: session.repositoryId,
            epoch: session.epoch,
            path: ".",
          }),
      );
      if (properties.properties.length === 0) {
        this.showCommandInformation(
          this.options.localize(
            "No SVN properties found on working copy root: {0}",
            session.identity.workingCopyRoot,
          ),
        );
        return;
      }

      await this.options.ui.showTextDocument({
        title: this.options.localize("SVN Properties: {0}", session.identity.workingCopyRoot),
        language: "markdown",
        content: svnPropertiesDocument(
          this.options.localize("SVN properties for {0}", session.identity.workingCopyRoot),
          ".",
          properties.source,
          properties.properties,
          {
            propertyPath: this.options.localize("SVN property path"),
            propertySource: this.options.localize("SVN property source"),
            propertyCount: this.options.localize("SVN property count"),
            propertyName: this.options.localize("SVN property name"),
            propertyValue: this.options.localize("SVN property value"),
          },
        ),
      });
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async showResourceMergeinfo(...resourceStates: unknown[]): Promise<void> {
    try {
      this.requireTrustedWorkspace();
      const target = await this.resourceTarget(resourceStates, {
        contexts: LOCAL_MERGEINFO_CONTEXT_VALUES,
        invalid: invalidResourceMergeinfoTarget,
        outside: invalidResourceMergeinfoTargetOutsideRepository,
        allowEditorUri: true,
      });
      if (!target) {
        return;
      }
      const path = this.mergeinfoResourcePath(target);

      const properties = await this.options.ui.runOperationWithProgress(
        this.options.localize("Loading SVN mergeinfo"),
        async () =>
          await this.options.propertiesClient.listProperties({
            repositoryId: target.repositoryId,
            epoch: target.epoch,
            path,
          }),
      );
      const mergeinfo = svnMergeinfoPropertyValue(properties);
      if (mergeinfo === undefined || mergeinfo.trim().length === 0) {
        this.showCommandInformation(
          this.options.localize("No SVN mergeinfo found on SVN path: {0}", path),
        );
        return;
      }

      await this.options.ui.showTextDocument({
        title: this.options.localize("SVN Mergeinfo: {0}", path),
        language: "markdown",
        content: svnMergeinfoDocument(
          this.options.localize("SVN mergeinfo for {0}", path),
          path,
          properties.source,
          mergeinfo,
          {
            mergeinfoPath: this.options.localize("SVN mergeinfo path"),
            propertySource: this.options.localize("SVN property source"),
            mergeinfoSourcePathCount: this.options.localize("SVN mergeinfo source path count"),
            mergeinfoRevisionRangeCount: this.options.localize("SVN mergeinfo revision range count"),
            mergeinfoUnparsedLineCount: this.options.localize("SVN mergeinfo unparsed line count"),
            mergeinfoUnparsedRevisionRangeCount: this.options.localize(
              "SVN mergeinfo unparsed revision range count",
            ),
            sourcePath: this.options.localize("Source path"),
            sourceRevisionRangeCount: this.options.localize("SVN mergeinfo source revision range count"),
            latestMergedRevision: this.options.localize("Latest merged revision"),
            nonInheritableRangeCount: this.options.localize("SVN mergeinfo non-inheritable range count"),
            rangeStartRevision: this.options.localize("SVN mergeinfo range start revision"),
            rangeEndRevision: this.options.localize("SVN mergeinfo range end revision"),
            nonInheritableRange: this.options.localize("Non-inheritable SVN mergeinfo range"),
            revisionRanges: this.options.localize("Revision ranges"),
            noParsedSourcePaths: this.options.localize("No parsed SVN mergeinfo source paths."),
            unparsedMergeinfoRange: this.options.localize("Unparsed svn:mergeinfo revision range"),
            unparsedMergeinfoLine: this.options.localize("Unparsed svn:mergeinfo line"),
            rawMergeinfo: this.options.localize("Raw svn:mergeinfo"),
            yes: this.options.localize("Yes"),
            no: this.options.localize("No"),
          },
        ),
      });
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  private mergeinfoResourcePath(target: RepositoryCommandResourceTarget): string {
    const projection = this.options.sourceControlProjection.getProjection(target.repositoryId);
    if (!projection || projection.repositoryId !== target.repositoryId || projection.epoch !== target.epoch) {
      throw invalidResourceMergeinfoTarget();
    }
    if (target.projectionGeneration !== undefined && projection.generation !== target.projectionGeneration) {
      throw invalidResourceMergeinfoTarget();
    }
    const resource = findProjectionResource(projection, target);
    if (!resource || !LOCAL_MERGEINFO_CONTEXT_VALUES.has(resource.contextValue)) {
      throw invalidResourceMergeinfoTarget();
    }
    if (target.resourceKind !== undefined && resource.entry.kind !== target.resourceKind) {
      throw invalidResourceMergeinfoTarget();
    }
    return resource.path;
  }

  public async showResourceProperties(...resourceStates: unknown[]): Promise<void> {
    try {
      this.requireTrustedWorkspace();
      const target = await this.resourceTarget(resourceStates, {
        contexts: LOCAL_PROPERTIES_CONTEXT_VALUES,
        invalid: invalidResourcePropertiesTarget,
        outside: invalidResourcePropertiesTargetOutsideRepository,
        allowEditorUri: true,
      });
      if (!target) {
        return;
      }
      const path = this.propertiesResourcePath(target);

      const properties = await this.options.ui.runOperationWithProgress(
        this.options.localize("Loading SVN properties"),
        async () =>
          await this.options.propertiesClient.listProperties({
            repositoryId: target.repositoryId,
            epoch: target.epoch,
            path,
          }),
      );
      if (properties.properties.length === 0) {
        this.showCommandInformation(
          this.options.localize("No SVN properties found on SVN path: {0}", path),
        );
        return;
      }

      await this.options.ui.showTextDocument({
        title: this.options.localize("SVN Properties: {0}", path),
        language: "markdown",
        content: svnPropertiesDocument(
          this.options.localize("SVN properties for {0}", path),
          path,
          properties.source,
          properties.properties,
          {
            propertyPath: this.options.localize("SVN property path"),
            propertySource: this.options.localize("SVN property source"),
            propertyCount: this.options.localize("SVN property count"),
            propertyName: this.options.localize("SVN property name"),
            propertyValue: this.options.localize("SVN property value"),
          },
        ),
      });
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async setResourceProperty(...resourceStates: unknown[]): Promise<void> {
    try {
      this.requireTrustedWorkspace();
      const target = await this.resourceTarget(resourceStates, {
        contexts: LOCAL_PROPERTIES_CONTEXT_VALUES,
        invalid: invalidResourcePropertiesTarget,
        outside: invalidResourcePropertiesTargetOutsideRepository,
        allowEditorUri: true,
      });
      if (!target) {
        return;
      }
      const path = this.propertiesResourcePath(target);
      const propertyOptions = await this.options.ui.promptPropertySetOptions(path);
      if (propertyOptions === undefined) {
        return;
      }
      const validatedOptions = validateRepositoryPropertySetOptions(propertyOptions);

      const result = await this.options.operationScheduler.run(target.repositoryId, async () =>
        await this.runJournaledOperation(
          "propertySet",
          this.options.localize("Setting SVN property"),
          target.repositoryId,
          1,
          (operationOptions) => {
            const request = {
              repositoryId: target.repositoryId,
              epoch: target.epoch,
              path,
              name: validatedOptions.name,
              value: validatedOptions.value,
            };
            return operationOptions
              ? this.options.operationClient.propertySet(request, operationOptions)
              : this.options.operationClient.propertySet(request);
          },
        ),
      );
      await this.applyOperationReconcile(target, result);
      this.showCommandInformation(
        this.options.localize("SubversionR set SVN property {0} on: {1}", validatedOptions.name, path),
      );
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async deleteResourceProperty(...resourceStates: unknown[]): Promise<void> {
    try {
      this.requireTrustedWorkspace();
      const target = await this.resourceTarget(resourceStates, {
        contexts: LOCAL_PROPERTIES_CONTEXT_VALUES,
        invalid: invalidResourcePropertiesTarget,
        outside: invalidResourcePropertiesTargetOutsideRepository,
        allowEditorUri: true,
      });
      if (!target) {
        return;
      }
      const path = this.propertiesResourcePath(target);
      const properties = await this.options.ui.runOperationWithProgress(
        this.options.localize("Loading SVN properties"),
        async () =>
          await this.options.propertiesClient.listProperties({
            repositoryId: target.repositoryId,
            epoch: target.epoch,
            path,
          }),
      );
      if (properties.properties.length === 0) {
        this.showCommandInformation(this.options.localize("No SVN properties found on SVN path: {0}", path));
        return;
      }
      const name = await this.options.ui.promptPropertyDeleteName(path, properties.properties);
      if (name === undefined) {
        return;
      }
      const validatedName = validateRepositoryPropertyDeleteName(name, properties.properties);

      const result = await this.options.operationScheduler.run(target.repositoryId, async () =>
        await this.runJournaledOperation(
          "propertyDelete",
          this.options.localize("Deleting SVN property"),
          target.repositoryId,
          1,
          (operationOptions) => {
            const request = {
              repositoryId: target.repositoryId,
              epoch: target.epoch,
              path,
              name: validatedName,
            };
            return operationOptions
              ? this.options.operationClient.propertyDelete(request, operationOptions)
              : this.options.operationClient.propertyDelete(request);
          },
        ),
      );
      await this.applyOperationReconcile(target, result);
      this.showCommandInformation(
        this.options.localize("SubversionR deleted SVN property {0} from: {1}", validatedName, path),
      );
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async editRepositoryExternals(repositoryId?: unknown): Promise<void> {
    try {
      this.requireTrustedWorkspace();
      const session = await this.selectOpenSessionForRepository(
        repositoryId,
        repositoryPropertiesRepositoryIdInvalid,
        repositoryPropertiesRepositoryNotOpen,
      );
      if (!session) {
        return;
      }
      await this.editExternalsProperty({
        repositoryId: session.repositoryId,
        epoch: session.epoch,
        path: ".",
      });
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async editResourceExternals(...resourceStates: unknown[]): Promise<void> {
    try {
      this.requireTrustedWorkspace();
      const target = await this.resourceTarget(resourceStates, {
        contexts: LOCAL_PROPERTIES_CONTEXT_VALUES,
        invalid: invalidResourcePropertiesTarget,
        outside: invalidResourcePropertiesTargetOutsideRepository,
        allowEditorUri: true,
      });
      if (!target) {
        return;
      }
      const path = this.externalsResourcePath(target);
      await this.editExternalsProperty({
        repositoryId: target.repositoryId,
        epoch: target.epoch,
        path,
      });
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  private propertiesResourcePath(target: RepositoryCommandResourceTarget): string {
    const projection = this.options.sourceControlProjection.getProjection(target.repositoryId);
    if (!projection || projection.repositoryId !== target.repositoryId || projection.epoch !== target.epoch) {
      throw invalidResourcePropertiesTarget();
    }
    if (target.projectionGeneration !== undefined && projection.generation !== target.projectionGeneration) {
      throw invalidResourcePropertiesTarget();
    }
    const resource = findProjectionResource(projection, target);
    if (!resource || !LOCAL_PROPERTIES_CONTEXT_VALUES.has(resource.contextValue)) {
      throw invalidResourcePropertiesTarget();
    }
    if (target.resourceKind !== undefined && resource.entry.kind !== target.resourceKind) {
      throw invalidResourcePropertiesTarget();
    }
    return resource.path;
  }

  private externalsResourcePath(target: RepositoryCommandResourceTarget): string {
    const projection = this.options.sourceControlProjection.getProjection(target.repositoryId);
    if (!projection || projection.repositoryId !== target.repositoryId || projection.epoch !== target.epoch) {
      throw invalidResourcePropertiesTarget();
    }
    if (target.projectionGeneration !== undefined && projection.generation !== target.projectionGeneration) {
      throw invalidResourcePropertiesTarget();
    }
    const resource = findProjectionResource(projection, target);
    if (!resource || !LOCAL_PROPERTIES_CONTEXT_VALUES.has(resource.contextValue) || resource.entry.kind !== "dir") {
      throw invalidResourcePropertiesTarget();
    }
    if (target.resourceKind !== undefined && resource.entry.kind !== target.resourceKind) {
      throw invalidResourcePropertiesTarget();
    }
    return resource.path;
  }

  private async editExternalsProperty(target: RepositoryResourceRefreshTarget & { path: string }): Promise<void> {
    const properties = await this.options.ui.runOperationWithProgress(
      this.options.localize("Loading SVN properties"),
      async () =>
        await this.options.propertiesClient.listProperties({
          repositoryId: target.repositoryId,
          epoch: target.epoch,
          path: target.path,
        }),
    );
    const existingValue = svnExternalsPropertyValue(properties);
    const editedValue = await this.options.ui.promptExternalsPropertyValue(target.path, existingValue);
    if (editedValue === undefined) {
      return;
    }
    const value = repositoryPropertyValue(editedValue, "value");
    if (value.length === 0) {
      if (existingValue === undefined) {
        this.showCommandInformation(
          this.options.localize("No svn:externals property found on: {0}", target.path),
        );
        return;
      }
      const result = await this.options.operationScheduler.run(target.repositoryId, async () =>
        await this.runJournaledOperation(
          "propertyDelete",
          this.options.localize("Editing svn:externals"),
          target.repositoryId,
          1,
          (operationOptions) => {
            const request = {
              repositoryId: target.repositoryId,
              epoch: target.epoch,
              path: target.path,
              name: "svn:externals",
            };
            return operationOptions
              ? this.options.operationClient.propertyDelete(request, operationOptions)
              : this.options.operationClient.propertyDelete(request);
          },
        ),
      );
      await this.applyOperationReconcile(target, result);
      this.showCommandInformation(
        this.options.localize("SubversionR cleared svn:externals from: {0}", target.path),
      );
      return;
    }

    const result = await this.options.operationScheduler.run(target.repositoryId, async () =>
      await this.runJournaledOperation(
        "propertySet",
        this.options.localize("Editing svn:externals"),
        target.repositoryId,
        1,
        (operationOptions) => {
          const request = {
            repositoryId: target.repositoryId,
            epoch: target.epoch,
            path: target.path,
            name: "svn:externals",
            value,
          };
          return operationOptions
            ? this.options.operationClient.propertySet(request, operationOptions)
            : this.options.operationClient.propertySet(request);
        },
      ),
    );
    await this.applyOperationReconcile(target, result);
    this.showCommandInformation(
      this.options.localize("SubversionR updated svn:externals on: {0}", target.path),
    );
  }

  public async updateResource(...resourceStates: unknown[]): Promise<void> {
    try {
      this.requireTrustedWorkspace();
      const target = await this.resourceTarget(resourceStates, {
        contexts: REMOTE_UPDATEABLE_CONTEXT_VALUES,
        invalid: invalidResourceUpdateTarget,
        outside: invalidResourceUpdateTargetOutsideRepository,
      });
      if (!target) {
        return;
      }
      if (target.path === ".") {
        throw invalidResourceUpdateTarget();
      }
      const session = this.options.sessionService
        .listOpenSessions()
        .find((candidate) => candidate.repositoryId === target.repositoryId && candidate.epoch === target.epoch);
      if (!session) {
        throw invalidResourceUpdateTarget();
      }

      const result = await this.options.operationScheduler.run(target.repositoryId, async () => {
        const updateResult = await this.runJournaledOperation(
          "update",
          this.options.localize("Updating SVN resource"),
          target.repositoryId,
          1,
          (operationOptions) => {
            const request = {
              repositoryId: target.repositoryId,
              epoch: target.epoch,
              path: target.path,
              revision: "head" as const,
              depth: "workingCopy" as const,
              depthIsSticky: false as const,
              ignoreExternals: true as const,
            };
            return operationOptions
              ? this.options.operationClient.update(request, operationOptions)
              : this.options.operationClient.update(request);
          },
        );
        await this.options.refreshService.fullReconcileRepository({
          repositoryId: target.repositoryId,
          epoch: target.epoch,
        });
        return updateResult;
      });
      this.showUpdateCompletion(
        this.options.localize(
          "SubversionR updated SVN resource to revision {0}: {1}",
          result.revision,
          target.path,
        ),
        session,
        [target.path],
      );
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async updateAllIncoming(commandArgument?: unknown): Promise<void> {
    try {
      this.requireTrustedWorkspace();
      const session = await this.selectOpenSessionForRepository(
        sourceControlGroupRepositoryIdArgument(commandArgument),
        invalidResourceUpdateTarget,
        () => invalidResourceUpdateTarget(),
      );
      if (!session) {
        return;
      }
      const projection = this.options.sourceControlProjection.getProjection(session.repositoryId);
      if (!projection || projection.repositoryId !== session.repositoryId || projection.epoch !== session.epoch) {
        throw invalidResourceUpdateTarget();
      }
      const incomingGroup = projection.groups.find((group) => group.id === "incoming");
      if (!incomingGroup) {
        throw invalidResourceUpdateTarget();
      }
      const targets = incomingGroup.resources
        .filter(isIncomingUpdateableProjectedResource)
        .map((resource) => projectionResourceTarget(projection, resource, session.watchScope.pathCase))
        .sort((left, right) => left.path.localeCompare(right.path, "en-US"));
      if (targets.length === 0) {
        await this.options.ui.showWarningMessage(this.options.localize("No incoming SVN resources to update."));
        return;
      }
      if (!targetsShareRepository(targets) || hasDuplicateResourcePaths(targets)) {
        throw invalidResourceUpdateTarget();
      }

      await this.options.operationScheduler.run(session.repositoryId, async () => {
        for (const target of targets) {
          await this.runJournaledOperation(
            "update",
            this.options.localize("Updating SVN resource"),
            session.repositoryId,
            1,
            (operationOptions) => {
              const request = {
                repositoryId: session.repositoryId,
                epoch: session.epoch,
                path: target.path,
                revision: "head" as const,
                depth: "workingCopy" as const,
                depthIsSticky: false as const,
                ignoreExternals: true as const,
              };
              return operationOptions
                ? this.options.operationClient.update(request, operationOptions)
                : this.options.operationClient.update(request);
            },
          );
        }
        await this.options.refreshService.fullReconcileRepository({
          repositoryId: session.repositoryId,
          epoch: session.epoch,
        });
      });
      const paths = targets.map((target) => target.path);
      this.showUpdateCompletion(
        this.options.localize(
          "SubversionR updated {0} incoming SVN resources: {1}",
          paths.length,
          commitPathSummary(paths),
        ),
        session,
        paths,
      );
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  private async runRepositoryUpdate(
    session: RepositorySession,
    updateOptions: RepositoryUpdateOptions,
    progressTitle: string,
  ): Promise<OperationRunResponse> {
    return await this.options.operationScheduler.run(session.repositoryId, async () => {
      const updateResult = await this.runJournaledOperation(
        "update",
        progressTitle,
        session.repositoryId,
        1,
        (operationOptions) => {
          const request = {
            repositoryId: session.repositoryId,
            epoch: session.epoch,
            path: ".",
            revision: updateOptions.revision,
            depth: updateOptions.depth,
            depthIsSticky: updateOptions.depthIsSticky,
            ignoreExternals: updateOptions.ignoreExternals,
          };
          return operationOptions
            ? this.options.operationClient.update(request, operationOptions)
            : this.options.operationClient.update(request);
        },
      );
      await this.options.refreshService.fullReconcileRepository({
        repositoryId: session.repositoryId,
        epoch: session.epoch,
      });
      if (!updateOptions.ignoreExternals) {
        for (const externalSession of childWorkingCopySessions(session, this.options.sessionService.listOpenSessions())) {
          await this.options.refreshService.fullReconcileRepository({
            repositoryId: externalSession.repositoryId,
            epoch: externalSession.epoch,
          });
        }
      }
      return updateResult;
    });
  }

  public async refreshResource(...resourceStates: unknown[]): Promise<void> {
    try {
      const target = await this.resourceRefreshTarget(resourceStates);
      if (!target) {
        return;
      }
      await this.options.refreshService.refreshResource(toRefreshTarget(target));
      this.showCommandInformation(
        this.options.localize("SubversionR refreshed SVN resource: {0}", target.path),
      );
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async diffWithBaseResource(...resourceStates: unknown[]): Promise<void> {
    try {
      const target = await this.resourceTarget(resourceStates, {
        contexts: LOCAL_BASE_DIFFABLE_CONTEXT_VALUES,
        invalid: invalidDiffBaseTarget,
        outside: invalidDiffBaseTargetOutsideRepository,
        allowEditorUri: true,
      });
      if (!target) {
        return;
      }
      if (target.path === ".") {
        throw invalidDiffBaseTarget();
      }

      const projection = this.options.sourceControlProjection.getProjection(target.repositoryId);
      if (!projection) {
        throw diffBaseStateUnavailable(target.repositoryId);
      }
      if (projection.repositoryId !== target.repositoryId || projection.epoch !== target.epoch) {
        throw diffBaseStateStale(target.repositoryId, target.epoch, projection.epoch);
      }
      const resource = findProjectionResource(projection, target);
      if (!resource || !isBaseDiffableProjectedResource(resource)) {
        throw invalidDiffBaseTarget();
      }
      const path = resource.path;

      const baseUri = this.options.ui.uriFromComponents(
        createBaseContentUriComponents({
          repositoryId: target.repositoryId,
          epoch: target.epoch,
          generation: projection.generation,
          path,
          revision: "base",
        }),
      );
      const workingUri = this.options.ui.uriFile(repositoryResourceFsPath(projection.workingCopyRoot, path));
      await this.options.ui.diffWithBase(
        baseUri,
        workingUri,
        this.options.localize("SVN BASE <-> Working Copy: {0}", path),
      );
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async openBaseResource(...resourceStates: unknown[]): Promise<void> {
    try {
      const target = await this.resourceTarget(resourceStates, {
        contexts: LOCAL_BASE_DIFFABLE_CONTEXT_VALUES,
        invalid: invalidOpenBaseTarget,
        outside: invalidOpenBaseTargetOutsideRepository,
        allowEditorUri: true,
      });
      if (!target) {
        return;
      }
      if (target.path === ".") {
        throw invalidOpenBaseTarget();
      }

      const projection = this.options.sourceControlProjection.getProjection(target.repositoryId);
      if (!projection) {
        throw openBaseStateUnavailable(target.repositoryId);
      }
      if (projection.repositoryId !== target.repositoryId || projection.epoch !== target.epoch) {
        throw openBaseStateStale(target.repositoryId, target.epoch, projection.epoch);
      }
      const resource = findProjectionResource(projection, target);
      if (!resource || !isBaseDiffableProjectedResource(resource)) {
        throw invalidOpenBaseTarget();
      }
      const path = resource.path;

      const baseUri = this.options.ui.uriFromComponents(
        createBaseContentUriComponents({
          repositoryId: target.repositoryId,
          epoch: target.epoch,
          generation: projection.generation,
          path,
          revision: "base",
        }),
      );
      await this.options.ui.openBase(baseUri, this.options.localize("SVN BASE: {0}", path));
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async diffWithHeadResource(...resourceStates: unknown[]): Promise<void> {
    try {
      this.requireTrustedWorkspace();
      const target = await this.resourceTarget(resourceStates, {
        contexts: HEAD_CONTENT_CONTEXT_VALUES,
        invalid: invalidDiffHeadTarget,
        outside: invalidDiffHeadTargetOutsideRepository,
        allowEditorUri: true,
      });
      if (!target) {
        return;
      }
      if (target.path === ".") {
        throw invalidDiffHeadTarget();
      }

      const projection = this.options.sourceControlProjection.getProjection(target.repositoryId);
      if (!projection) {
        throw diffHeadStateUnavailable(target.repositoryId);
      }
      if (projection.repositoryId !== target.repositoryId || projection.epoch !== target.epoch) {
        throw diffHeadStateStale(target.repositoryId, target.epoch, projection.epoch);
      }
      const resource = findProjectionResource(projection, target);
      if (!resource || !isHeadContentProjectedResource(resource)) {
        throw invalidDiffHeadTarget();
      }
      const path = resource.path;

      const headUri = this.options.ui.uriFromComponents(
        createHeadContentUriComponents({
          repositoryId: target.repositoryId,
          epoch: target.epoch,
          generation: projection.generation,
          path,
          revision: "head",
          requestId: this.options.createRequestId(),
        }),
      );
      const workingUri = this.options.ui.uriFile(repositoryResourceFsPath(projection.workingCopyRoot, path));
      await this.options.ui.diffWithHead(
        headUri,
        workingUri,
        this.options.localize("SVN HEAD <-> Working Copy: {0}", path),
      );
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async openHeadResource(...resourceStates: unknown[]): Promise<void> {
    try {
      this.requireTrustedWorkspace();
      const target = await this.resourceTarget(resourceStates, {
        contexts: HEAD_CONTENT_CONTEXT_VALUES,
        invalid: invalidOpenHeadTarget,
        outside: invalidOpenHeadTargetOutsideRepository,
        allowEditorUri: true,
      });
      if (!target) {
        return;
      }
      if (target.path === ".") {
        throw invalidOpenHeadTarget();
      }

      const projection = this.options.sourceControlProjection.getProjection(target.repositoryId);
      if (!projection) {
        throw openHeadStateUnavailable(target.repositoryId);
      }
      if (projection.repositoryId !== target.repositoryId || projection.epoch !== target.epoch) {
        throw openHeadStateStale(target.repositoryId, target.epoch, projection.epoch);
      }
      const resource = findProjectionResource(projection, target);
      if (!resource || !isHeadContentProjectedResource(resource)) {
        throw invalidOpenHeadTarget();
      }
      const path = resource.path;

      const headUri = this.options.ui.uriFromComponents(
        createHeadContentUriComponents({
          repositoryId: target.repositoryId,
          epoch: target.epoch,
          generation: projection.generation,
          path,
          revision: "head",
          requestId: this.options.createRequestId(),
        }),
      );
      await this.options.ui.openHead(headUri, this.options.localize("SVN HEAD: {0}", path));
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async diffWithPreviousResource(...resourceStates: unknown[]): Promise<void> {
    try {
      this.requireTrustedWorkspace();
      const target = await this.resourceTarget(resourceStates, {
        contexts: LOCAL_HISTORY_FILE_CONTEXT_VALUES,
        invalid: invalidDiffPreviousTarget,
        outside: invalidDiffPreviousTargetOutsideRepository,
        allowEditorUri: true,
      });
      if (!target) {
        return;
      }
      if (target.path === "." || target.resourceKind !== "file") {
        throw invalidDiffPreviousTarget();
      }

      const projection = this.options.sourceControlProjection.getProjection(target.repositoryId);
      if (!projection) {
        throw diffPreviousStateUnavailable(target.repositoryId);
      }
      if (projection.repositoryId !== target.repositoryId || projection.epoch !== target.epoch) {
        throw diffPreviousStateStale(target.repositoryId, target.epoch, projection.epoch);
      }
      if (target.projectionGeneration !== undefined && projection.generation !== target.projectionGeneration) {
        throw diffPreviousGenerationStale(target.repositoryId, target.projectionGeneration, projection.generation);
      }
      const resource = findProjectionResource(projection, target);
      if (!resource || !isHistoryFileProjectedResource(resource)) {
        throw invalidDiffPreviousTarget();
      }
      const changedRevision = resource.entry.changedRevision;
      if (!isDiffPreviousRevision(changedRevision)) {
        throw invalidDiffPreviousTarget();
      }

      const path = resource.path;
      const log = await this.options.historyClient.getLog({
        repositoryId: target.repositoryId,
        epoch: target.epoch,
        path,
        startRevision: `r${changedRevision}`,
        endRevision: "r0",
        limit: 2,
        discoverChangedPaths: false,
        strictNodeHistory: false,
        includeMergedRevisions: false,
      });
      const currentEntry = log.entries[0];
      const previousEntry = log.entries[1];
      if (
        !currentEntry ||
        currentEntry.revision !== changedRevision ||
        !previousEntry ||
        previousEntry.revision >= currentEntry.revision
      ) {
        throw diffPreviousNoPreviousRevision(path, changedRevision);
      }

      const comparison = historyCompareRevisionUriComponents({
        repositoryId: target.repositoryId,
        epoch: target.epoch,
        path,
        leftRevision: `r${previousEntry.revision}`,
        rightRevision: `r${currentEntry.revision}`,
        label: `${path} r${previousEntry.revision}..r${currentEntry.revision}`,
      });
      await this.options.ui.diffRevisions(
        this.options.ui.uriFromComponents(comparison.left),
        this.options.ui.uriFromComponents(comparison.right),
        this.options.localize("SVN PREV <-> Revision: {0}", comparison.label),
      );
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async showRepositoryLog(commandTarget?: unknown): Promise<void> {
    try {
      this.requireTrustedWorkspace();
      const session = await this.selectHistoryRepositorySession(commandTarget);
      if (!session) {
        return;
      }
      await this.options.ui.showHistory({
        kind: "repository",
        repositoryId: session.repositoryId,
        epoch: session.epoch,
        path: ".",
        label: session.identity.workingCopyRoot,
      });
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async showFileHistoryResource(...resourceStates: unknown[]): Promise<void> {
    try {
      this.requireTrustedWorkspace();
      const target = await this.resourceTarget(resourceStates, {
        contexts: LOCAL_HISTORY_FILE_CONTEXT_VALUES,
        invalid: invalidHistoryFileTarget,
        outside: invalidHistoryFileTargetOutsideRepository,
        allowEditorUri: true,
      });
      if (!target) {
        return;
      }
      if (target.path === "." || target.resourceKind !== "file") {
        throw invalidHistoryFileTarget();
      }

      const projection = this.options.sourceControlProjection.getProjection(target.repositoryId);
      if (!projection) {
        throw historyFileStateUnavailable(target.repositoryId);
      }
      if (projection.repositoryId !== target.repositoryId || projection.epoch !== target.epoch) {
        throw historyFileStateStale(target.repositoryId, target.epoch, projection.epoch);
      }
      const resource = findProjectionResource(projection, target);
      if (!resource || !isHistoryFileProjectedResource(resource)) {
        throw invalidHistoryFileTarget();
      }
      await this.options.ui.showHistory({
        kind: "file",
        repositoryId: target.repositoryId,
        epoch: target.epoch,
        path: resource.path,
        label: resource.path,
      });
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async showBlameResource(...resourceStates: unknown[]): Promise<void> {
    try {
      this.requireTrustedWorkspace();
      const target = await this.resourceTarget(resourceStates, {
        contexts: LOCAL_BLAME_FILE_CONTEXT_VALUES,
        invalid: invalidBlameFileTarget,
        outside: invalidBlameFileTargetOutsideRepository,
        allowEditorUri: true,
      });
      if (!target) {
        return;
      }
      if (target.path === "." || target.resourceKind !== "file") {
        throw invalidBlameFileTarget();
      }

      const projection = this.options.sourceControlProjection.getProjection(target.repositoryId);
      if (!projection) {
        throw blameFileStateUnavailable(target.repositoryId);
      }
      if (projection.repositoryId !== target.repositoryId || projection.epoch !== target.epoch) {
        throw blameFileStateStale(target.repositoryId, target.epoch, projection.epoch);
      }
      const resource = findProjectionResource(projection, target);
      if (!resource || !isHistoryFileProjectedResource(resource)) {
        throw invalidBlameFileTarget();
      }
      await this.options.ui.showBlame({
        repositoryId: target.repositoryId,
        epoch: target.epoch,
        generation: projection.generation,
        path: resource.path,
        label: resource.path,
        pegRevision: "base",
        startRevision: "r0",
        endRevision: "base",
        lineStart: 1,
        lineLimit: 5000,
        ignoreWhitespace: "none",
        ignoreEolStyle: false,
        ignoreMimeType: false,
        includeMergedRevisions: this.options.includeMergedRevisions(),
      });
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async revertResource(...resourceStates: unknown[]): Promise<void> {
    try {
      this.requireTrustedWorkspace();
      const targets = await this.resourceTargets(resourceStates, {
        contexts: LOCAL_REVERTABLE_CONTEXT_VALUES,
        invalid: invalidResourceRevertTarget,
        outside: invalidResourceRevertTargetOutsideRepository,
      });
      if (!targets) {
        return;
      }
      const { target, paths } = this.validateOperationTargets(
        targets,
        invalidResourceRevertTarget,
        isRevertableProjectedResource,
      );
      const pathSummary = commitPathSummary(paths);
      const confirmed = await this.options.ui.confirmRevertResource(pathSummary);
      if (!confirmed) {
        return;
      }

      await this.options.operationScheduler.run(target.repositoryId, async () => {
        const result = await this.runJournaledOperation(
          "revert",
          this.options.localize("Reverting SVN resource"),
          target.repositoryId,
          paths.length,
          (operationOptions) => {
            const request = {
              repositoryId: target.repositoryId,
              epoch: target.epoch,
              paths,
              depth: "empty" as const,
              changelists: [],
              clearChangelists: false,
              metadataOnly: false,
              addedKeepLocal: false,
            };
            return operationOptions
              ? this.options.operationClient.revert(request, operationOptions)
              : this.options.operationClient.revert(request);
          },
        );
        await this.applyOperationReconcile(target, result);
      });
      this.showCommandInformation(
        this.options.localize(
          paths.length === 1
            ? "SubversionR reverted SVN resource: {0}"
            : "SubversionR reverted {0} SVN resources: {1}",
          ...(paths.length === 1 ? [pathSummary] : [paths.length, pathSummary]),
        ),
      );
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async addResource(...resourceStates: unknown[]): Promise<void> {
    try {
      this.requireTrustedWorkspace();
      const targets = await this.resourceTargets(resourceStates, {
        contexts: LOCAL_ADDABLE_CONTEXT_VALUES,
        invalid: invalidResourceAddTarget,
        outside: invalidResourceAddTargetOutsideRepository,
      });
      if (!targets) {
        return;
      }
      const { target, resources } = this.validateOperationResources(
        targets,
        invalidResourceAddTarget,
        isAddableProjectedResource,
      );
      const paths = resources.map((resource) => resource.path);
      const pathSummary = commitPathSummary(paths);

      await this.options.operationScheduler.run(target.repositoryId, async () => {
        for (const resource of resources) {
          const result = await this.runJournaledOperation(
            "add",
            this.options.localize("Adding SVN resource"),
            target.repositoryId,
            1,
            (operationOptions) => {
              const request = {
                repositoryId: target.repositoryId,
                epoch: target.epoch,
                paths: [resource.path],
                depth: addDepthForProjectedResource(resource),
                force: false,
                noIgnore: false,
                noAutoprops: false,
                addParents: false,
              };
              return operationOptions
                ? this.options.operationClient.add(request, operationOptions)
                : this.options.operationClient.add(request);
            },
          );
          await this.applyOperationReconcile(target, result);
        }
      });
      this.showCommandInformation(
        this.options.localize(
          paths.length === 1
            ? "SubversionR added SVN resource: {0}"
            : "SubversionR added {0} SVN resources: {1}",
          ...(paths.length === 1 ? [pathSummary] : [paths.length, pathSummary]),
        ),
      );
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async addToIgnoreResource(...resourceStates: unknown[]): Promise<void> {
    try {
      this.requireTrustedWorkspace();
      const targets = await this.resourceTargets(resourceStates, {
        contexts: LOCAL_IGNORABLE_CONTEXT_VALUES,
        invalid: invalidResourceAddToIgnoreTarget,
        outside: invalidResourceAddToIgnoreTargetOutsideRepository,
      });
      if (!targets) {
        return;
      }
      const { target, paths } = this.validateOperationTargets(
        targets,
        invalidResourceAddToIgnoreTarget,
        isIgnorableProjectedResource,
      );
      const ignoreGroups = groupedIgnoreTargets(paths);

      const changedPaths = await this.options.operationScheduler.run(target.repositoryId, async () => {
        const changed: string[] = [];
        for (const group of ignoreGroups) {
          const properties = await this.options.propertiesClient.listProperties({
            repositoryId: target.repositoryId,
            epoch: target.epoch,
            path: group.parentPath,
          });
          const existingValue = svnIgnorePropertyValue(properties);
          const update = appendSvnIgnorePatterns(existingValue, group.patterns);
          if (update === undefined) {
            continue;
          }
          const changedChildPaths = group.childPaths.filter((path) =>
            update.addedPatterns.includes(ignorePatternForPath(path)),
          );

          const result = await this.runJournaledOperation(
            "propertySet",
            this.options.localize("Adding SVN ignore rule"),
            target.repositoryId,
            update.addedPatterns.length,
            (operationOptions) => {
              const request = {
                repositoryId: target.repositoryId,
                epoch: target.epoch,
                path: group.parentPath,
                name: "svn:ignore",
                value: update.value,
              };
              return operationOptions
                ? this.options.operationClient.propertySet(request, operationOptions)
                : this.options.operationClient.propertySet(request);
            },
          );
          await this.applyOperationReconcile(target, result);
          if (!result.reconcile.requiresFullReconcile && changedChildPaths.length > 0) {
            await this.options.refreshService.refreshTargets({
              repositoryId: target.repositoryId,
              epoch: target.epoch,
              targets: changedChildPaths.map((path) => ({
                path,
                depth: "empty",
                reason: "operationPropertySet",
              })),
            });
          }
          changed.push(...changedChildPaths);
        }
        return changed;
      });

      if (changedPaths.length === 0) {
        this.showCommandInformation(
          this.options.localize("SubversionR SVN ignore rules already include selected item(s)."),
        );
        return;
      }
      this.showCommandInformation(
        this.options.localize(
          changedPaths.length === 1
            ? "SubversionR added SVN ignore rule for: {0}"
            : "SubversionR added SVN ignore rules for {0} items: {1}",
          ...(changedPaths.length === 1 ? [changedPaths[0]] : [changedPaths.length, commitPathSummary(changedPaths)]),
        ),
      );
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async removeFromIgnoreResource(...resourceStates: unknown[]): Promise<void> {
    try {
      this.requireTrustedWorkspace();
      const targets = await this.resourceTargets(resourceStates, {
        contexts: LOCAL_IGNORE_REMOVABLE_CONTEXT_VALUES,
        invalid: invalidResourceRemoveFromIgnoreTarget,
        outside: invalidResourceRemoveFromIgnoreTargetOutsideRepository,
      });
      if (!targets) {
        return;
      }
      const { target, paths } = this.validateOperationTargets(
        targets,
        invalidResourceRemoveFromIgnoreTarget,
        isIgnoreRemovableProjectedResource,
      );
      const ignoreGroups = groupedIgnoreTargets(paths);

      const changedPaths = await this.options.operationScheduler.run(target.repositoryId, async () => {
        const changed: string[] = [];
        for (const group of ignoreGroups) {
          const properties = await this.options.propertiesClient.listProperties({
            repositoryId: target.repositoryId,
            epoch: target.epoch,
            path: group.parentPath,
          });
          const existingValue = svnIgnorePropertyValue(properties);
          const update = removeSvnIgnorePatterns(existingValue, group.patterns);
          if (update === undefined) {
            continue;
          }
          const changedChildPaths = group.childPaths.filter((path) =>
            update.removedPatterns.includes(ignorePatternForPath(path)),
          );
          const operationKind = update.value === undefined ? "propertyDelete" : "propertySet";
          const result = await this.runJournaledOperation(
            operationKind,
            this.options.localize("Removing SVN ignore rule"),
            target.repositoryId,
            update.removedPatterns.length,
            (operationOptions) => {
              const baseRequest = {
                repositoryId: target.repositoryId,
                epoch: target.epoch,
                path: group.parentPath,
                name: "svn:ignore",
              };
              if (update.value === undefined) {
                return operationOptions
                  ? this.options.operationClient.propertyDelete(baseRequest, operationOptions)
                  : this.options.operationClient.propertyDelete(baseRequest);
              }
              const request = {
                ...baseRequest,
                value: update.value,
              };
              return operationOptions
                ? this.options.operationClient.propertySet(request, operationOptions)
                : this.options.operationClient.propertySet(request);
            },
          );
          await this.applyOperationReconcile(target, result);
          if (!result.reconcile.requiresFullReconcile && changedChildPaths.length > 0) {
            await this.options.refreshService.refreshTargets({
              repositoryId: target.repositoryId,
              epoch: target.epoch,
              targets: changedChildPaths.map((path) => ({
                path,
                depth: "empty",
                reason: operationKind === "propertyDelete" ? "operationPropertyDelete" : "operationPropertySet",
              })),
            });
          }
          changed.push(...changedChildPaths);
        }
        return changed;
      });

      if (changedPaths.length === 0) {
        this.showCommandInformation(
          this.options.localize("SubversionR SVN ignore rules did not include selected item(s)."),
        );
        return;
      }
      this.showCommandInformation(
        this.options.localize(
          changedPaths.length === 1
            ? "SubversionR removed SVN ignore rule for: {0}"
            : "SubversionR removed SVN ignore rules for {0} items: {1}",
          ...(changedPaths.length === 1 ? [changedPaths[0]] : [changedPaths.length, commitPathSummary(changedPaths)]),
        ),
      );
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async setResourceChangelist(...resourceStates: unknown[]): Promise<void> {
    try {
      this.requireTrustedWorkspace();
      const targets = await this.resourceTargets(resourceStates, {
        contexts: LOCAL_CHANGELISTABLE_CONTEXT_VALUES,
        invalid: invalidResourceChangelistTarget,
        outside: invalidResourceChangelistTargetOutsideRepository,
      });
      if (!targets) {
        return;
      }
      const { target, paths } = this.validateOperationTargets(
        targets,
        invalidResourceChangelistTarget,
        isChangelistableProjectedResource,
      );
      const changelist = await this.options.ui.promptChangelistName(paths);
      if (changelist === undefined) {
        return;
      }
      const validatedChangelist = validateChangelistName(changelist);
      const pathSummary = commitPathSummary(paths);

      await this.options.operationScheduler.run(target.repositoryId, async () => {
        const result = await this.runJournaledOperation(
          "changelistSet",
          this.options.localize("Setting SVN changelist"),
          target.repositoryId,
          paths.length,
          (operationOptions) => {
            const request = {
              repositoryId: target.repositoryId,
              epoch: target.epoch,
              paths,
              depth: "empty" as const,
              changelist: validatedChangelist,
              changelists: [],
            };
            return operationOptions
              ? this.options.operationClient.changelistSet(request, operationOptions)
              : this.options.operationClient.changelistSet(request);
          },
        );
        await this.applyOperationReconcile(target, result);
      });
      this.showCommandInformation(
        this.options.localize(
          paths.length === 1
            ? "SubversionR assigned SVN changelist {0}: {1}"
            : "SubversionR assigned SVN changelist {0} to {1} resources: {2}",
          ...(paths.length === 1
            ? [validatedChangelist, pathSummary]
            : [validatedChangelist, paths.length, pathSummary]),
        ),
      );
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async clearResourceChangelist(...resourceStates: unknown[]): Promise<void> {
    try {
      this.requireTrustedWorkspace();
      const targets = await this.resourceTargets(resourceStates, {
        contexts: LOCAL_CHANGELISTABLE_CONTEXT_VALUES,
        invalid: invalidResourceChangelistTarget,
        outside: invalidResourceChangelistTargetOutsideRepository,
      });
      if (!targets) {
        return;
      }
      const { target, paths } = this.validateOperationTargets(
        targets,
        invalidResourceChangelistTarget,
        isChangelistedProjectedResource,
      );
      const pathSummary = commitPathSummary(paths);

      await this.options.operationScheduler.run(target.repositoryId, async () => {
        const result = await this.runJournaledOperation(
          "changelistClear",
          this.options.localize("Clearing SVN changelist"),
          target.repositoryId,
          paths.length,
          (operationOptions) => {
            const request = {
              repositoryId: target.repositoryId,
              epoch: target.epoch,
              paths,
              depth: "empty" as const,
              changelists: [],
            };
            return operationOptions
              ? this.options.operationClient.changelistClear(request, operationOptions)
              : this.options.operationClient.changelistClear(request);
          },
        );
        await this.applyOperationReconcile(target, result);
      });
      this.showCommandInformation(
        this.options.localize(
          paths.length === 1
            ? "SubversionR cleared SVN changelist from: {0}"
            : "SubversionR cleared SVN changelist from {0} resources: {1}",
          ...(paths.length === 1 ? [pathSummary] : [paths.length, pathSummary]),
        ),
      );
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async lockResource(...resourceStates: unknown[]): Promise<void> {
    try {
      this.requireTrustedWorkspace();
      const targets = await this.resourceTargets(resourceStates, {
        contexts: LOCAL_LOCKABLE_CONTEXT_VALUES,
        invalid: invalidResourceLockTarget,
        outside: invalidResourceLockTargetOutsideRepository,
      });
      if (!targets) {
        return;
      }
      const { target, paths } = this.validateOperationTargets(
        targets,
        invalidResourceLockTarget,
        isLockableProjectedResource,
      );
      const pathSummary = commitPathSummary(paths);
      const lockOptions = await this.options.ui.promptLockOptions(paths);
      if (lockOptions === undefined) {
        return;
      }

      await this.options.operationScheduler.run(target.repositoryId, async () => {
        const result = await this.runJournaledOperation(
          "lock",
          this.options.localize("Locking SVN resource"),
          target.repositoryId,
          paths.length,
          (operationOptions) => {
            const request = {
              repositoryId: target.repositoryId,
              epoch: target.epoch,
              paths,
              comment: lockOptions.comment,
              stealLock: lockOptions.stealLock,
            };
            return operationOptions
              ? this.options.operationClient.lock(request, operationOptions)
              : this.options.operationClient.lock(request);
          },
        );
        await this.applyOperationReconcile(target, result);
      });
      this.showCommandInformation(
        this.options.localize(
          paths.length === 1
            ? "SubversionR locked SVN resource: {0}"
            : "SubversionR locked {0} SVN resources: {1}",
          ...(paths.length === 1 ? [pathSummary] : [paths.length, pathSummary]),
        ),
      );
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async unlockResource(...resourceStates: unknown[]): Promise<void> {
    try {
      this.requireTrustedWorkspace();
      const targets = await this.resourceTargets(resourceStates, {
        contexts: LOCAL_UNLOCKABLE_CONTEXT_VALUES,
        invalid: invalidResourceUnlockTarget,
        outside: invalidResourceUnlockTargetOutsideRepository,
      });
      if (!targets) {
        return;
      }
      const { target, paths } = this.validateOperationTargets(
        targets,
        invalidResourceUnlockTarget,
        isUnlockableProjectedResource,
      );
      const pathSummary = commitPathSummary(paths);
      const unlockOptions = await this.options.ui.promptUnlockOptions(paths);
      if (unlockOptions === undefined) {
        return;
      }

      await this.options.operationScheduler.run(target.repositoryId, async () => {
        const result = await this.runJournaledOperation(
          "unlock",
          this.options.localize("Unlocking SVN resource"),
          target.repositoryId,
          paths.length,
          (operationOptions) => {
            const request = {
              repositoryId: target.repositoryId,
              epoch: target.epoch,
              paths,
              breakLock: unlockOptions.breakLock,
            };
            return operationOptions
              ? this.options.operationClient.unlock(request, operationOptions)
              : this.options.operationClient.unlock(request);
          },
        );
        await this.applyOperationReconcile(target, result);
      });
      this.showCommandInformation(
        this.options.localize(
          paths.length === 1
            ? "SubversionR unlocked SVN resource: {0}"
            : "SubversionR unlocked {0} SVN resources: {1}",
          ...(paths.length === 1 ? [pathSummary] : [paths.length, pathSummary]),
        ),
      );
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async deleteUnversionedResource(...resourceStates: unknown[]): Promise<void> {
    try {
      this.requireTrustedWorkspace();
      const targets = await this.resourceTargets(resourceStates, {
        contexts: LOCAL_UNVERSIONED_DELETABLE_CONTEXT_VALUES,
        invalid: invalidResourceDeleteUnversionedTarget,
        outside: invalidResourceDeleteUnversionedTargetOutsideRepository,
      });
      if (!targets) {
        return;
      }
      if (!targetsShareRepository(targets) || hasDuplicateResourcePaths(targets)) {
        throw invalidResourceDeleteUnversionedTarget();
      }
      for (const target of targets) {
        if (target.path === "." || (target.resourceKind !== "file" && target.resourceKind !== "dir")) {
          throw invalidResourceDeleteUnversionedTarget();
        }
      }
      const [firstTarget] = targets;
      const projection = this.options.sourceControlProjection.getProjection(firstTarget.repositoryId);
      if (
        !projection ||
        projection.repositoryId !== firstTarget.repositoryId ||
        projection.epoch !== firstTarget.epoch
      ) {
        throw invalidResourceDeleteUnversionedTarget();
      }
      const deleteTargets = targets.map((target) => {
        if (target.projectionGeneration !== undefined && projection.generation !== target.projectionGeneration) {
          throw invalidResourceDeleteUnversionedTarget();
        }
        const resource = findProjectionResource(projection, target);
        if (!resource || !isUnversionedDeletableProjectedResource(resource)) {
          throw invalidResourceDeleteUnversionedTarget();
        }
        if (resource.entry.kind !== target.resourceKind) {
          throw invalidResourceDeleteUnversionedTarget();
        }
        return {
          path: resource.path,
          fsPath: repositoryResourceFsPath(projection.workingCopyRoot, resource.path),
          recursive: resource.entry.kind === "dir",
        };
      });
      const confirmed = await this.options.ui.confirmDeleteUnversionedResources(
        deleteTargets.map((target) => target.path),
      );
      if (!confirmed) {
        return;
      }

      await this.deleteUnversionedTargets(firstTarget.repositoryId, firstTarget.epoch, deleteTargets);
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async deleteAllUnversionedResources(commandArgument?: unknown): Promise<void> {
    try {
      this.requireTrustedWorkspace();
      const session = await this.selectOpenSessionForRepository(
        deleteAllUnversionedRepositoryIdArgument(commandArgument),
        invalidResourceDeleteUnversionedTarget,
        invalidResourceDeleteUnversionedRepositoryNotOpen,
      );
      if (!session) {
        return;
      }
      const projection = this.options.sourceControlProjection.getProjection(session.repositoryId);
      if (!projection || projection.repositoryId !== session.repositoryId || projection.epoch !== session.epoch) {
        throw invalidResourceDeleteUnversionedTarget();
      }
      const unversionedGroup = projection.groups.find((group) => group.id === "unversioned");
      if (!unversionedGroup) {
        throw invalidResourceDeleteUnversionedTarget();
      }
      const deleteTargets = unversionedGroup.resources
        .filter(isUnversionedDeletableProjectedResource)
        .map((resource) => ({
          path: resource.path,
          fsPath: repositoryResourceFsPath(projection.workingCopyRoot, resource.path),
          recursive: resource.entry.kind === "dir",
        }));
      if (deleteTargets.length === 0) {
        await this.options.ui.showWarningMessage(
          this.options.localize("No unversioned SVN items to delete."),
        );
        return;
      }
      const confirmed = await this.options.ui.confirmDeleteUnversionedResources(
        deleteTargets.map((target) => target.path),
      );
      if (!confirmed) {
        return;
      }

      await this.deleteUnversionedTargets(session.repositoryId, session.epoch, deleteTargets);
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async commitResource(...resourceStates: unknown[]): Promise<void> {
    try {
      this.requireTrustedWorkspace();
      const targets = await this.resourceTargets(resourceStates, {
        contexts: LOCAL_COMMITTABLE_CONTEXT_VALUES,
        invalid: invalidResourceCommitTarget,
        outside: invalidResourceCommitTargetOutsideRepository,
      });
      if (!targets) {
        return;
      }
      if (!targetsShareRepository(targets) || hasDuplicateResourcePaths(targets)) {
        throw invalidResourceCommitTarget();
      }
      for (const target of targets) {
        if (!isCommittableResourceTarget(target) || (target.path === "." && target.resourceKind !== "dir")) {
          throw invalidResourceCommitTarget();
        }
      }
      await this.commitTargets(targets);
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async commitAll(repositoryId?: unknown): Promise<void> {
    try {
      this.requireTrustedWorkspace();
      const session = await this.selectOpenSessionForRepository(repositoryId);
      if (!session) {
        return;
      }
      const projection = this.options.sourceControlProjection.getCommitAllTargets(session.repositoryId);
      if (!projection) {
        throw commitAllStateUnavailable(session.repositoryId);
      }
      if (projection.repositoryId !== session.repositoryId || projection.epoch !== session.epoch) {
        throw commitAllStateStale(session.repositoryId, session.epoch, projection.epoch);
      }
      if (projection.hasConflicts) {
        throw commitAllConflictsPresent();
      }

      const targets = projection.targets.map((target) => commitAllResourceTarget(session, target.path));
      if (targets.length === 0) {
        await this.options.ui.showWarningMessage(
          this.options.localize("No eligible SVN file changes to commit."),
        );
        return;
      }
      if (!targetsShareRepository(targets) || hasDuplicateResourcePaths(targets)) {
        throw commitAllTargetsInvalid();
      }
      for (const target of targets) {
        if (target.path === "." || target.resourceKind !== "file" || !isRepositoryRelativeResourcePath(target.path)) {
          throw commitAllTargetsInvalid();
        }
      }
      await this.commitTargets(targets);
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async pickCommitMessageHistory(repositoryId?: unknown): Promise<void> {
    try {
      this.requireTrustedWorkspace();
      const session = await this.selectOpenSessionForRepository(
        repositoryId,
        pickCommitMessageHistoryRepositoryIdInvalid,
        pickCommitMessageHistoryRepositoryNotOpen,
      );
      if (!session) {
        return;
      }
      const messages = this.options.commitMessageHistory.messages(session.repositoryId);
      if (messages.length === 0) {
        await this.options.ui.showWarningMessage(
          this.options.localize("No SVN commit message history for: {0}", session.identity.workingCopyRoot),
        );
        return;
      }
      const message = await this.options.ui.promptCommitMessageHistory(messages);
      if (message === undefined) {
        return;
      }
      this.options.ui.setCommitMessage(session.repositoryId, message);
      this.showCommandInformation(
        this.options.localize("SubversionR restored SVN commit message history for: {0}", session.identity.workingCopyRoot),
      );
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async reviewCommit(repositoryId?: unknown): Promise<void> {
    try {
      this.requireTrustedWorkspace();
      const session = await this.selectOpenSessionForRepository(repositoryId);
      if (!session) {
        return;
      }
      const projection = this.options.sourceControlProjection.getCommitAllTargets(session.repositoryId);
      if (!projection) {
        throw commitAllStateUnavailable(session.repositoryId);
      }
      if (projection.repositoryId !== session.repositoryId || projection.epoch !== session.epoch) {
        throw commitAllStateStale(session.repositoryId, session.epoch, projection.epoch);
      }
      if (projection.hasConflicts) {
        throw commitAllConflictsPresent();
      }

      const candidates = projection.targets;
      if (candidates.length === 0) {
        await this.options.ui.showWarningMessage(
          this.options.localize("No eligible SVN file changes to commit."),
        );
        return;
      }
      const reviewTargets = candidates.map((target) => ({
        path: target.path,
        changelist: target.changelist,
        status: target.status,
        directory: target.directory,
      }));
      const previousSelection = this.reviewCommitSelections.get(session.repositoryId);
      const candidatePaths = new Set(candidates.map((target) => target.path));
      const preselectedPaths = previousSelection
        ? new Set([...previousSelection].filter((path) => candidatePaths.has(path)))
        : candidatePaths;
      const selectedReviewTargets = await this.options.ui.promptReviewCommitTargets(
        reviewTargets,
        preselectedPaths,
      );
      if (selectedReviewTargets === undefined) {
        return;
      }
      this.reviewCommitSelections.set(
        session.repositoryId,
        new Set(selectedReviewTargets.map((target) => target.path)),
      );
      if (selectedReviewTargets.length === 0) {
        await this.options.ui.showWarningMessage(this.options.localize("No SVN resources selected for commit."));
        return;
      }

      const candidateByPath = new Map(candidates.map((target) => [target.path, target]));
      const targets = selectedReviewTargets.map((selectedTarget) => {
        const candidate = candidateByPath.get(selectedTarget.path);
        if (!candidate || candidate.changelist !== selectedTarget.changelist) {
          throw commitAllTargetsInvalid();
        }
        return commitAllResourceTarget(session, candidate.path);
      });
      if (!targetsShareRepository(targets) || hasDuplicateResourcePaths(targets)) {
        throw commitAllTargetsInvalid();
      }
      for (const target of targets) {
        if (target.path === "." || target.resourceKind !== "file" || !isRepositoryRelativeResourcePath(target.path)) {
          throw commitAllTargetsInvalid();
        }
      }
      await this.commitTargets(targets);
      this.reviewCommitSelections.delete(session.repositoryId);
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async commitChangelist(commandArgument?: unknown): Promise<void> {
    try {
      this.requireTrustedWorkspace();
      const changelistTarget = this.changelistGroupCommandTarget(commandArgument);
      const session = await this.selectOpenSessionForRepository(
        changelistTarget.repositoryId,
        invalidChangelistGroupTarget,
        changelistGroupRepositoryNotOpen,
      );
      if (!session) {
        return;
      }
      const projection = this.options.sourceControlProjection.getProjection(session.repositoryId);
      if (!projection) {
        throw changelistGroupStateUnavailable(session.repositoryId);
      }
      const group = this.changelistProjectionGroup(projection, session, changelistTarget.changelist);
      const targets = group.resources
        .filter(isChangelistCommitProjectedResource)
        .map((resource) => projectionResourceTarget(projection, resource, session.watchScope.pathCase));
      if (targets.length === 0) {
        await this.options.ui.showWarningMessage(
          this.options.localize("No eligible SVN file changes in changelist {0} to commit.", changelistTarget.changelist),
        );
        return;
      }
      if (!targetsShareRepository(targets) || hasDuplicateResourcePaths(targets)) {
        throw invalidChangelistGroupTarget();
      }
      await this.commitTargets(targets, [changelistTarget.changelist]);
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async revertChangelist(commandArgument?: unknown): Promise<void> {
    try {
      this.requireTrustedWorkspace();
      const changelistTarget = this.changelistGroupCommandTarget(commandArgument);
      const session = await this.selectOpenSessionForRepository(
        changelistTarget.repositoryId,
        invalidChangelistGroupTarget,
        changelistGroupRepositoryNotOpen,
      );
      if (!session) {
        return;
      }
      const projection = this.options.sourceControlProjection.getProjection(session.repositoryId);
      if (!projection) {
        throw changelistGroupStateUnavailable(session.repositoryId);
      }
      const group = this.changelistProjectionGroup(projection, session, changelistTarget.changelist);
      const targets = group.resources
        .filter(isRevertableProjectedResource)
        .map((resource) => projectionResourceTarget(projection, resource, session.watchScope.pathCase));
      if (targets.length === 0 || !targetsShareRepository(targets) || hasDuplicateResourcePaths(targets)) {
        throw invalidChangelistGroupTarget();
      }
      const paths = targets.map((target) => target.path);
      const pathSummary = commitPathSummary(paths);
      const confirmed = await this.options.ui.confirmRevertResource(pathSummary);
      if (!confirmed) {
        return;
      }

      await this.options.operationScheduler.run(session.repositoryId, async () => {
        const result = await this.runJournaledOperation(
          "revert",
          this.options.localize("Reverting SVN changelist"),
          session.repositoryId,
          paths.length,
          (operationOptions) => {
            const request = {
              repositoryId: session.repositoryId,
              epoch: session.epoch,
              paths,
              depth: "empty" as const,
              changelists: [changelistTarget.changelist],
              clearChangelists: false,
              metadataOnly: false,
              addedKeepLocal: false,
            };
            return operationOptions
              ? this.options.operationClient.revert(request, operationOptions)
              : this.options.operationClient.revert(request);
          },
        );
        await this.applyOperationReconcile(targets[0], result);
      });
      this.showCommandInformation(
        this.options.localize("SubversionR reverted SVN changelist {0}: {1}", changelistTarget.changelist, pathSummary),
      );
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async revertAll(commandArgument?: unknown): Promise<void> {
    try {
      this.requireTrustedWorkspace();
      const session = await this.selectOpenSessionForRepository(
        sourceControlGroupRepositoryIdArgument(commandArgument),
        invalidResourceRevertTarget,
        invalidResourceRevertTargetOutsideRepository,
      );
      if (!session) {
        return;
      }
      const projection = this.options.sourceControlProjection.getProjection(session.repositoryId);
      if (!projection || projection.repositoryId !== session.repositoryId || projection.epoch !== session.epoch) {
        throw invalidResourceRevertTarget();
      }
      const targets = projection.groups
        .flatMap((group) => group.resources)
        .filter(isRevertableProjectedResource)
        .map((resource) => projectionResourceTarget(projection, resource, session.watchScope.pathCase))
        .sort((left, right) => left.path.localeCompare(right.path, "en-US"));
      if (targets.length === 0) {
        await this.options.ui.showWarningMessage(this.options.localize("No eligible SVN resources to revert."));
        return;
      }
      if (!targetsShareRepository(targets) || hasDuplicateResourcePaths(targets)) {
        throw invalidResourceRevertTarget();
      }
      const paths = targets.map((target) => target.path);
      const pathSummary = commitPathSummary(paths);
      const confirmed = await this.options.ui.confirmRevertResource(pathSummary);
      if (!confirmed) {
        return;
      }

      await this.options.operationScheduler.run(session.repositoryId, async () => {
        const result = await this.runJournaledOperation(
          "revert",
          this.options.localize("Reverting SVN resources"),
          session.repositoryId,
          paths.length,
          (operationOptions) => {
            const request = {
              repositoryId: session.repositoryId,
              epoch: session.epoch,
              paths,
              depth: "empty" as const,
              changelists: [],
              clearChangelists: false,
              metadataOnly: false,
              addedKeepLocal: false,
            };
            return operationOptions
              ? this.options.operationClient.revert(request, operationOptions)
              : this.options.operationClient.revert(request);
          },
        );
        await this.applyOperationReconcile(targets[0], result);
      });
      this.showCommandInformation(
        this.options.localize(
          paths.length === 1
            ? "SubversionR reverted SVN resource: {0}"
            : "SubversionR reverted {0} SVN resources: {1}",
          ...(paths.length === 1 ? [pathSummary] : [paths.length, pathSummary]),
        ),
      );
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async removeResource(...resourceStates: unknown[]): Promise<void> {
    await this.removeResourceWithMode({
      resourceStates,
      keepLocal: false,
      confirm: (path) => this.options.ui.confirmRemoveResource(path),
      successMessage: (paths, pathSummary) =>
        this.options.localize(
          paths.length === 1
            ? "SubversionR removed SVN resource: {0}"
            : "SubversionR removed {0} SVN resources: {1}",
          ...(paths.length === 1 ? [pathSummary] : [paths.length, pathSummary]),
        ),
    });
  }

  public async removeResourceKeepLocal(...resourceStates: unknown[]): Promise<void> {
    await this.removeResourceWithMode({
      resourceStates,
      keepLocal: true,
      confirm: (path) => this.options.ui.confirmRemoveResourceKeepLocal(path),
      successMessage: (paths, pathSummary) =>
        this.options.localize(
          paths.length === 1
            ? "SubversionR removed SVN resource but kept local item: {0}"
            : "SubversionR removed {0} SVN resources but kept local items: {1}",
          ...(paths.length === 1 ? [pathSummary] : [paths.length, pathSummary]),
        ),
    });
  }

  private async removeResourceWithMode(options: {
    resourceStates: unknown[];
    keepLocal: boolean;
    confirm(path: string): Promise<boolean>;
    successMessage(paths: readonly string[], pathSummary: string): string;
  }): Promise<void> {
    try {
      this.requireTrustedWorkspace();
      const targets = await this.resourceTargets(options.resourceStates, {
        contexts: LOCAL_REMOVABLE_CONTEXT_VALUES,
        invalid: invalidResourceRemoveTarget,
        outside: invalidResourceRemoveTargetOutsideRepository,
      });
      if (!targets) {
        return;
      }
      const { target, paths } = this.validateOperationTargets(
        targets,
        invalidResourceRemoveTarget,
        isRemovableProjectedResource,
      );
      const pathSummary = commitPathSummary(paths);
      const confirmed = await options.confirm(pathSummary);
      if (!confirmed) {
        return;
      }

      await this.options.operationScheduler.run(target.repositoryId, async () => {
        const result = await this.runJournaledOperation(
          "remove",
          this.options.localize("Removing SVN resource"),
          target.repositoryId,
          paths.length,
          (operationOptions) => {
            const request = {
              repositoryId: target.repositoryId,
              epoch: target.epoch,
              paths,
              force: false,
              keepLocal: options.keepLocal,
            };
            return operationOptions
              ? this.options.operationClient.remove(request, operationOptions)
              : this.options.operationClient.remove(request);
          },
        );
        await this.applyOperationReconcile(target, result);
      });
      this.showCommandInformation(options.successMessage(paths, pathSummary));
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async moveResource(...resourceStates: unknown[]): Promise<void> {
    try {
      this.requireTrustedWorkspace();
      const target = await this.resourceTarget(resourceStates, {
        contexts: LOCAL_MOVABLE_CONTEXT_VALUES,
        invalid: invalidResourceMoveTarget,
        outside: invalidResourceMoveTargetOutsideRepository,
        allowEditorUri: true,
      });
      if (!target) {
        return;
      }
      if (target.path === ".") {
        throw invalidResourceMoveTarget();
      }
      const sourcePath = target.source === "uri" ? this.moveUriResourcePath(target) : target.path;
      const destinationPath = await this.options.ui.promptMoveDestination(sourcePath);
      if (destinationPath === undefined) {
        return;
      }
      if (
        !isRepositoryRelativeResourcePath(destinationPath) ||
        destinationPath === "." ||
        comparisonKey(target.pathCase, destinationPath) === comparisonKey(target.pathCase, sourcePath)
      ) {
        throw invalidResourceMoveDestination(destinationPath);
      }

      await this.options.operationScheduler.run(target.repositoryId, async () => {
        const result = await this.runJournaledOperation(
          "move",
          this.options.localize("Moving SVN resource"),
          target.repositoryId,
          2,
          (operationOptions) => {
            const request = {
              repositoryId: target.repositoryId,
              epoch: target.epoch,
              sourcePath,
              destinationPath,
              makeParents: false,
            };
            return operationOptions
              ? this.options.operationClient.move(request, operationOptions)
              : this.options.operationClient.move(request);
          },
        );
        await this.applyOperationReconcile(target, result);
      });
      this.showCommandInformation(
        this.options.localize("SubversionR moved SVN resource: {0} -> {1}", sourcePath, destinationPath),
      );
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  private moveUriResourcePath(target: RepositoryCommandResourceTarget): string {
    // URI Move is shared by editor and Explorer menus; Explorer selections need not be SCM-projected.
    const projection = this.options.sourceControlProjection.getProjection(target.repositoryId);
    if (!projection || projection.repositoryId !== target.repositoryId || projection.epoch !== target.epoch) {
      return target.path;
    }
    const resource = findProjectionResource(projection, target);
    if (!resource || !isMovableProjectedResource(resource)) {
      return target.path;
    }
    return resource.path;
  }

  public async resolveResource(...resourceStates: unknown[]): Promise<void> {
    try {
      this.requireTrustedWorkspace();
      const targets = await this.resourceTargets(resourceStates, {
        contexts: LOCAL_RESOLVABLE_CONTEXT_VALUES,
        invalid: invalidResourceResolveTarget,
        outside: invalidResourceResolveTargetOutsideRepository,
      });
      if (!targets) {
        return;
      }
      const firstTarget = targets[0];
      if (!firstTarget) {
        throw invalidResourceResolveTarget();
      }
      const { target, paths } =
        targets.length === 1
          ? { target: firstTarget, paths: [firstTarget.path] }
          : this.validateOperationTargets(targets, invalidResourceResolveTarget, isResolvableProjectedResource);
      const choice = await this.options.ui.promptResolveChoice(
        paths.length === 1 ? paths[0] : this.options.localize("{0} SVN conflicts", paths.length),
      );
      if (choice === undefined) {
        return;
      }

      await this.options.operationScheduler.run(target.repositoryId, async () => {
        for (let index = 0; index < paths.length; index += 1) {
          const path = paths[index];
          const sourceTarget = targets[index];
          if (!path || !sourceTarget) {
            throw invalidResourceResolveTarget();
          }
          const operationTarget = {
            ...sourceTarget,
            path,
          };
          const result = await this.runJournaledOperation(
            "resolve",
            this.options.localize(paths.length === 1 ? "Resolving SVN conflict" : "Resolving SVN conflicts"),
            target.repositoryId,
            1,
            (operationOptions) => {
              const request = {
                repositoryId: target.repositoryId,
                epoch: target.epoch,
                paths: [path],
                depth: "empty" as const,
                choice,
              };
              return operationOptions
                ? this.options.operationClient.resolve(request, operationOptions)
                : this.options.operationClient.resolve(request);
            },
          );
          await this.applyOperationReconcile(operationTarget, result);
        }
      });
      this.showCommandInformation(
        this.options.localize(
          paths.length === 1
            ? "SubversionR resolved SVN conflict with {0}: {1}"
            : "SubversionR resolved {0} SVN conflicts with {1}: {2}",
          ...(paths.length === 1
            ? [resolveChoiceLabel(choice, this.options.localize), paths[0]]
            : [paths.length, resolveChoiceLabel(choice, this.options.localize), commitPathSummary(paths)]),
        ),
      );
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  public async resolveAll(commandArgument?: unknown): Promise<void> {
    try {
      this.requireTrustedWorkspace();
      const session = await this.selectOpenSessionForRepository(
        sourceControlGroupRepositoryIdArgument(commandArgument),
        invalidResourceResolveTarget,
        () => invalidResourceResolveTarget(),
      );
      if (!session) {
        return;
      }
      const projection = this.options.sourceControlProjection.getProjection(session.repositoryId);
      if (!projection || projection.repositoryId !== session.repositoryId || projection.epoch !== session.epoch) {
        throw invalidResourceResolveTarget();
      }
      const conflictGroup = projection.groups.find((group) => group.id === "conflicts");
      if (!conflictGroup) {
        throw invalidResourceResolveTarget();
      }
      const targets = conflictGroup.resources
        .filter(isResolvableProjectedResource)
        .map((resource) => projectionResourceTarget(projection, resource, session.watchScope.pathCase));
      if (targets.length === 0) {
        await this.options.ui.showWarningMessage(this.options.localize("No SVN conflicts to resolve."));
        return;
      }
      if (!targetsShareRepository(targets) || hasDuplicateResourcePaths(targets)) {
        throw invalidResourceResolveTarget();
      }
      const paths = targets.map((target) => target.path);
      const choice = await this.options.ui.promptResolveChoice(
        this.options.localize("{0} SVN conflicts", paths.length),
      );
      if (choice === undefined) {
        return;
      }

      await this.options.operationScheduler.run(session.repositoryId, async () => {
        for (const target of targets) {
          const result = await this.runJournaledOperation(
            "resolve",
            this.options.localize("Resolving SVN conflicts"),
            target.repositoryId,
            1,
            (operationOptions) => {
              const request = {
                repositoryId: target.repositoryId,
                epoch: target.epoch,
                paths: [target.path],
                depth: "empty" as const,
                choice,
              };
              return operationOptions
                ? this.options.operationClient.resolve(request, operationOptions)
                : this.options.operationClient.resolve(request);
            },
          );
          await this.applyOperationReconcile(target, result);
        }
      });
      this.showCommandInformation(
        this.options.localize(
          "SubversionR resolved {0} SVN conflicts with {1}: {2}",
          paths.length,
          resolveChoiceLabel(choice, this.options.localize),
          commitPathSummary(paths),
        ),
      );
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  private async selectCandidate(
    candidates: RepositoryDiscoveryCandidate[],
  ): Promise<RepositoryDiscoveryCandidate | undefined> {
    if (candidates.length === 0) {
      await this.options.ui.showWarningMessage(
        this.options.localize("No SVN working copy was found in the workspace."),
      );
      return undefined;
    }
    if (candidates.length === 1) {
      return candidates[0];
    }
    return await this.options.ui.pickRepositoryCandidate(candidates);
  }

  private async selectOpenSession(): Promise<RepositorySession | undefined> {
    const sessions = this.options.sessionService.listOpenSessions();
    if (sessions.length === 0) {
      await this.options.ui.showWarningMessage(this.options.localize("No SVN repository is open."));
      return undefined;
    }
    if (sessions.length === 1) {
      return sessions[0];
    }
    return await this.options.ui.pickOpenRepository(sessions);
  }

  private async selectHistoryRepositorySession(commandTarget: unknown): Promise<RepositorySession | undefined> {
    if (commandTarget !== undefined) {
      const target = requireRepositoryHistoryCommandTarget(commandTarget);
      const sessions = this.options.sessionService.listOpenSessions();
      const match = sessions.find((session) => session.repositoryId === target.repositoryId);
      if (!match) {
        throw historyRepositoryNotOpen(target.repositoryId);
      }
      if (match.epoch !== target.epoch) {
        throw historyRepositorySessionStale(target.repositoryId, target.epoch, match.epoch);
      }
      return match;
    }

    const initialSessions = this.options.sessionService.listOpenSessions();
    if (initialSessions.length === 0) {
      await this.options.ui.showWarningMessage(this.options.localize("No SVN repository is open."));
      return undefined;
    }
    const selected =
      initialSessions.length === 1
        ? initialSessions[0]
        : await this.options.ui.pickOpenRepository(initialSessions);
    if (!selected) {
      return undefined;
    }
    if (!initialSessions.some((session) => sameRepositorySessionSnapshot(session, selected))) {
      throw historyRepositorySessionStale(selected.repositoryId, selected.epoch);
    }

    const latestSessions = this.options.sessionService.listOpenSessions();
    const latest = latestSessions.find((session) => session.repositoryId === selected.repositoryId);
    if (!latest || !sameRepositorySessionSnapshot(selected, latest)) {
      throw historyRepositorySessionStale(selected.repositoryId, selected.epoch, latest?.epoch);
    }
    return latest;
  }

  private selectOpenSessionForRepository(
    repositoryId: unknown,
    invalidRepositoryId: () => RepositoryCommandError = commitAllRepositoryIdInvalid,
    repositoryNotOpen: (repositoryId: string) => RepositoryCommandError = commitAllRepositoryNotOpen,
  ): Promise<RepositorySession | undefined> {
    if (repositoryId === undefined) {
      return this.selectOpenSession();
    }
    if (typeof repositoryId !== "string" || repositoryId.trim().length === 0) {
      throw invalidRepositoryId();
    }
    const requestedRepositoryId = repositoryId.trim();
    const sessions = this.options.sessionService.listOpenSessions();
    if (sessions.length === 0) {
      return this.options.ui
        .showWarningMessage(this.options.localize("No SVN repository is open."))
        .then(() => undefined);
    }
    const match = sessions.find((session) => session.repositoryId === requestedRepositoryId);
    if (!match) {
      throw repositoryNotOpen(requestedRepositoryId);
    }
    return Promise.resolve(match);
  }

  private changelistGroupCommandTarget(argument: unknown): ChangelistGroupCommandTarget {
    if (!isRecord(argument)) {
      throw invalidChangelistGroupTarget();
    }
    const repositoryId = argument.subversionrRepositoryId;
    const changelist = argument.subversionrChangelistName;
    if (typeof repositoryId !== "string" || repositoryId.trim().length === 0) {
      throw invalidChangelistGroupTarget();
    }
    if (typeof changelist !== "string") {
      throw invalidChangelistGroupTarget();
    }
    return {
      repositoryId: repositoryId.trim(),
      changelist: validateChangelistName(changelist),
    };
  }

  private changelistProjectionGroup(
    projection: ScmRepositoryProjection,
    session: RepositorySession,
    changelist: string,
  ): ScmRepositoryProjection["groups"][number] {
    if (projection.repositoryId !== session.repositoryId || projection.epoch !== session.epoch) {
      throw changelistGroupStateStale(session.repositoryId, session.epoch, projection.epoch);
    }
    const group = projection.groups.find((candidate) => candidate.changelist === changelist);
    if (!group || !isChangelistResourceGroupId(group.id)) {
      throw invalidChangelistGroupTarget();
    }
    return group;
  }

  private async resourceRefreshTarget(
    resourceStateArgs: unknown[],
  ): Promise<RepositoryCommandResourceTarget | undefined> {
    return this.resourceTarget(resourceStateArgs, {
      contexts: LOCAL_REFRESHABLE_CONTEXT_VALUES,
      invalid: invalidResourceRefreshTarget,
      outside: invalidResourceRefreshTargetOutsideRepository,
    });
  }

  private async resourceTarget(
    resourceStateArgs: unknown[],
    options: {
      contexts: ReadonlySet<string>;
      invalid(): RepositoryCommandError;
      outside(fsPath: string): RepositoryCommandError;
      allowEditorUri?: boolean;
    },
  ): Promise<RepositoryCommandResourceTarget | undefined> {
    const resourceStates = normalizeResourceStateArgs(resourceStateArgs);
    if (resourceStates.length !== 1) {
      throw options.invalid();
    }
    const [resourceState] = resourceStates;
    if (isEditorUriLike(resourceState)) {
      if (!options.allowEditorUri) {
        throw options.invalid();
      }
      return this.editorUriResourceTarget(resourceState, options.invalid, options.outside);
    }
    const contextValue = requireResourceContext(resourceState, options.contexts, options.invalid);
    const fsPath = requireResourceFsPath(resourceState, options.invalid);
    const resourceKind = requireOptionalResourceKind(resourceState, options.invalid);
    const projectionGeneration = requireOptionalProjectionGeneration(resourceState, options.invalid);
    const sessions = this.options.sessionService.listOpenSessions();
    if (sessions.length === 0) {
      await this.options.ui.showWarningMessage(this.options.localize("No SVN repository is open."));
      return undefined;
    }

    const match = mostSpecificResourceMatch(sessions, fsPath);
    if (!match) {
      throw options.outside(fsPath);
    }
    return {
      repositoryId: match.session.repositoryId,
      epoch: match.session.epoch,
      path: match.path,
      fsPath,
      source: "resource",
      contextValue,
      resourceKind,
      projectionGeneration,
      pathCase: match.session.watchScope.pathCase,
    };
  }

  private async editorUriResourceTarget(
    uri: EditorUriLike,
    invalid: () => RepositoryCommandError,
    outside: (fsPath: string) => RepositoryCommandError,
  ): Promise<RepositoryCommandResourceTarget | undefined> {
    if (uri.scheme !== "file") {
      throw invalid();
    }
    const fsPath = requireEditorUriFsPath(uri, invalid);
    const sessions = this.options.sessionService.listOpenSessions();
    if (sessions.length === 0) {
      await this.options.ui.showWarningMessage(this.options.localize("No SVN repository is open."));
      return undefined;
    }
    const match = mostSpecificResourceMatch(sessions, fsPath);
    if (!match) {
      throw outside(fsPath);
    }
    return {
      repositoryId: match.session.repositoryId,
      epoch: match.session.epoch,
      path: match.path,
      fsPath,
      source: "uri",
      contextValue: undefined,
      resourceKind: "file",
      projectionGeneration: undefined,
      pathCase: match.session.watchScope.pathCase,
    };
  }

  private async resourceTargets(
    resourceStateArgs: unknown[],
    options: {
      contexts: ReadonlySet<string>;
      invalid(): RepositoryCommandError;
      outside(fsPath: string): RepositoryCommandError;
    },
  ): Promise<RepositoryCommandResourceTarget[] | undefined> {
    const resourceStates = normalizeResourceStateArgs(resourceStateArgs);
    if (resourceStates.length === 0) {
      throw options.invalid();
    }
    const parsedResourceStates = resourceStates.map((resourceState) => {
      const contextValue = requireResourceContext(resourceState, options.contexts, options.invalid);
      return {
        fsPath: requireResourceFsPath(resourceState, options.invalid),
        contextValue,
        resourceKind: requireOptionalResourceKind(resourceState, options.invalid),
        projectionGeneration: requireOptionalProjectionGeneration(resourceState, options.invalid),
      };
    });
    const sessions = this.options.sessionService.listOpenSessions();
    if (sessions.length === 0) {
      await this.options.ui.showWarningMessage(this.options.localize("No SVN repository is open."));
      return undefined;
    }

    return parsedResourceStates.map(({ fsPath, contextValue, resourceKind, projectionGeneration }) => {
      const match = mostSpecificResourceMatch(sessions, fsPath);
      if (!match) {
        throw options.outside(fsPath);
      }
      return {
        repositoryId: match.session.repositoryId,
        epoch: match.session.epoch,
        path: match.path,
        fsPath,
        source: "resource",
        contextValue,
        resourceKind,
        projectionGeneration,
        pathCase: match.session.watchScope.pathCase,
      };
    });
  }

  private validateOperationTargets(
    targets: RepositoryCommandResourceTarget[],
    invalid: () => RepositoryCommandError,
    isAllowedResource: (resource: ScmProjectedResource) => boolean,
  ): { target: RepositoryCommandResourceTarget; paths: string[] } {
    const { target, resources } = this.validateOperationResources(targets, invalid, isAllowedResource);
    return { target, paths: resources.map((resource) => resource.path) };
  }

  private validateOperationResources(
    targets: RepositoryCommandResourceTarget[],
    invalid: () => RepositoryCommandError,
    isAllowedResource: (resource: ScmProjectedResource) => boolean,
  ): { target: RepositoryCommandResourceTarget; resources: ValidatedOperationResource[] } {
    if (!targetsShareRepository(targets) || hasDuplicateResourcePaths(targets)) {
      throw invalid();
    }
    const [firstTarget] = targets;
    if (!firstTarget) {
      throw invalid();
    }
    for (const target of targets) {
      if (target.path === ".") {
        throw invalid();
      }
    }
    const projection = this.options.sourceControlProjection.getProjection(firstTarget.repositoryId);
    if (
      !projection ||
      projection.repositoryId !== firstTarget.repositoryId ||
      projection.epoch !== firstTarget.epoch
    ) {
      throw invalid();
    }
    const resources = targets.map((target) => {
      if (target.projectionGeneration !== undefined && projection.generation !== target.projectionGeneration) {
        throw invalid();
      }
      const resource = findProjectionResource(projection, target);
      if (!resource || !isAllowedResource(resource)) {
        throw invalid();
      }
      if (target.resourceKind !== undefined && resource.entry.kind !== target.resourceKind) {
        throw invalid();
      }
      return { path: resource.path, kind: resource.entry.kind };
    });
    return { target: firstTarget, resources };
  }

  private async applyOperationReconcile(
    target: RepositoryResourceRefreshTarget,
    result: OperationRunResponse,
  ): Promise<void> {
    if (result.reconcile.requiresFullReconcile) {
      await this.options.refreshService.fullReconcileRepository({
        repositoryId: target.repositoryId,
        epoch: target.epoch,
      });
    } else if (result.reconcile.targets.length > 0) {
      await this.options.refreshService.refreshTargets({
        repositoryId: target.repositoryId,
        epoch: target.epoch,
        targets: result.reconcile.targets,
      });
    }
  }

  private async deleteUnversionedTargets(
    repositoryId: string,
    epoch: number,
    deleteTargets: readonly UnversionedDeleteTarget[],
  ): Promise<void> {
    await this.options.operationScheduler.run(repositoryId, async () => {
      for (const target of deleteTargets) {
        await this.options.ui.deleteLocalFile(target.fsPath, { recursive: target.recursive });
      }
      if (deleteTargets.length === 1) {
        await this.options.refreshService.refreshResource({
          repositoryId,
          epoch,
          path: deleteTargets[0].path,
        });
        return;
      }
      await this.options.refreshService.fullReconcileRepository({
        repositoryId,
        epoch,
      });
    });
    if (deleteTargets.length === 1) {
      this.showCommandInformation(
        this.options.localize("SubversionR deleted unversioned SVN item: {0}", deleteTargets[0].path),
      );
    } else {
      this.showCommandInformation(
        this.options.localize("SubversionR deleted {0} unversioned SVN items.", deleteTargets.length),
      );
    }
  }

  private async applyPostCommitReconcile(
    target: RepositoryResourceRefreshTarget,
    result: OperationRunResponse,
  ): Promise<void> {
    try {
      await this.applyOperationReconcile(target, result);
    } catch (error) {
      await this.options.ui.showWarningMessage(
        this.options.localize(
          "SubversionR post-commit reconcile failed after revision {0}: {1}",
          result.revision,
          errorCode(error),
        ),
      );
    }
  }

  private async runJournaledOperation<T extends OperationRunResponse>(
    kind: OperationJournalKind,
    progressTitle: string,
    repositoryId: string,
    requestedTouchedCount: number,
    operation: (options?: OperationRunClientOptions) => Promise<T>,
  ): Promise<T> {
    return await this.options.ui.runOperationWithProgress(progressTitle, async (signal) => {
      const startedAt = this.options.now();
      const startedMonotonicMs = this.options.monotonicNowMs();
      try {
        const result = await operationRunWithOptionalOptions(operation, signal);
        const endedAt = this.options.now();
        const durationMs = operationJournalDurationMs(startedMonotonicMs, this.options.monotonicNowMs());
        this.recordOperationJournal({
          kind,
          repositoryId,
          startedAt,
          endedAt,
          durationMs,
          resultCategory: "succeeded",
          scanPlan: operationJournalScanPlan(result),
          touchedCount: operationJournalTouchedCount(result, requestedTouchedCount),
          retryCount: 0,
          cancelled: false,
        });
        return result;
      } catch (error) {
        const resultCategory = operationJournalFailureCategory(error);
        const endedAt = this.options.now();
        const durationMs = operationJournalDurationMs(startedMonotonicMs, this.options.monotonicNowMs());
        this.recordOperationJournal({
          kind,
          repositoryId,
          startedAt,
          endedAt,
          durationMs,
          resultCategory,
          scanPlan: "unknown",
          touchedCount: requestedTouchedCount,
          retryCount: 0,
          cancelled: resultCategory === "cancelled",
        });
        throw error;
      }
    });
  }

  private recordOperationJournal(record: Parameters<RepositoryOperationJournal["tryRecord"]>[0]): void {
    try {
      this.options.operationJournal.tryRecord(record);
    } catch {
      // Observability failures must not change SVN operation or reconcile semantics.
    }
  }

  private async commitTargets(targets: RepositoryCommandResourceTarget[], changelists: string[] = []): Promise<void> {
    const target = targets[0];
    if (!target) {
      throw invalidResourceCommitTarget();
    }
    const commit = await this.options.operationScheduler.run(target.repositoryId, async () => {
      for (const selectedTarget of targets) {
        if (this.options.ui.hasUnsavedTextDocument(selectedTarget.fsPath)) {
          await this.options.ui.showWarningMessage(
            this.options.localize("Save SVN resource before committing: {0}", selectedTarget.path),
          );
          return undefined;
        }
      }

      const paths = targets.map((selectedTarget) => selectedTarget.path);
      const pathSummary = commitPathSummary(paths);
      const message = this.options.ui.commitMessage(target.repositoryId);
      if (message.trim().length === 0) {
        await this.options.ui.showWarningMessage(
          this.options.localize("Enter an SVN commit message before committing {0}.", pathSummary),
        );
        return undefined;
      }
      if (message.includes("\0") || message.includes("\r")) {
        throw invalidResourceCommitMessage();
      }

      const result = await this.runJournaledOperation(
        "commit",
        this.options.localize("Committing SVN changes"),
        target.repositoryId,
        paths.length,
        (operationOptions) => {
          const request = {
            repositoryId: target.repositoryId,
            epoch: target.epoch,
            paths,
            message,
            depth: "empty" as const,
            changelists,
            keepLocks: false as const,
            keepChangelists: false as const,
            commitAsOperations: false as const,
            includeFileExternals: false as const,
            includeDirExternals: false as const,
          };
          return operationOptions
            ? this.options.operationClient.commit(request, operationOptions)
            : this.options.operationClient.commit(request);
        },
      );
      if (result.revision === null) {
        throw invalidResourceCommitRevision();
      }
      this.options.commitMessageHistory.record(target.repositoryId, message);
      this.options.ui.clearCommitMessage(target.repositoryId);
      await this.applyPostCommitReconcile(target, result);
      return {
        pathSummary,
        paths,
        revision: result.revision,
      };
    });

    if (!commit) {
      return;
    }
    this.showCommandInformation(
      this.options.localize(
        commit.paths.length === 1
          ? "SubversionR committed SVN resource at revision {0}: {1}"
          : "SubversionR committed SVN resources at revision {0}: {1}",
        commit.revision,
        commit.pathSummary,
      ),
    );
  }

  private async showCommandError(error: unknown): Promise<void> {
    if (isStatusRefreshCancellation(error)) {
      return;
    }
    const code = errorCode(error);
    const operation = repositoryErrorOperation(code, this.options.localize);
    this.options.diagnostics.recordFailure(operation, error);
    if (isInstalledSourceControlUiE2eRun()) {
      const category = errorCategory(error);
      console.warn(
        category
          ? `SubversionR repository command failed: ${code} (${category}).`
          : `SubversionR repository command failed: ${code}.`,
      );
    }
    if (isUnknownRepositoryCommandError(error)) {
      console.error("SubversionR repository command failed.", error);
    }
    const showLog = this.options.localize("Show Log");
    void this.options.ui
      .showErrorMessage(
        repositoryFailureMessage(operation, error, this.options.localize),
        showLog,
      )
      .then((selected) => {
        if (selected === showLog) {
          this.options.diagnostics.show();
        }
      })
      .catch((notificationError: unknown) => {
        console.error("SubversionR repository command notification failed.", notificationError);
      });
  }

  private showCommandInformation(message: string): void {
    void this.options.ui.showInformationMessage(message).catch((notificationError: unknown) => {
      console.error("SubversionR repository command notification failed.", notificationError);
    });
  }

  private showUpdateCompletion(
    successMessage: string,
    session: Pick<RepositorySession, "repositoryId" | "epoch" | "watchScope">,
    updatedPaths: readonly string[],
  ): void {
    const conflicts = updateConflictPaths(
      session,
      updatedPaths,
      this.options.sourceControlProjection,
    );
    if (conflicts.length === 0) {
      this.showCommandInformation(successMessage);
      return;
    }
    void this.options.ui
      .showWarningMessage(
        this.options.localize(
          "{0}. The working copy has unresolved SVN conflicts ({1}): {2}",
          successMessage,
          conflicts.length,
          updateConflictPathSummary(conflicts, this.options.localize),
        ),
      )
      .catch((notificationError: unknown) => {
        console.error("SubversionR repository command notification failed.", notificationError);
      });
  }

  private requireTrustedWorkspace(): void {
    requireTrustedWorkspaceState(this.options.ui.workspaceTrusted);
  }
}

function errorCode(error: unknown): string {
  if (typeof error === "object" && error !== null && "code" in error) {
    const code = (error as { code?: unknown }).code;
    if (typeof code === "string" && code.trim().length > 0) {
      return code;
    }
  }
  return "SUBVERSIONR_REPOSITORY_COMMAND_FAILED";
}

type RepositoryErrorLocalize = (message: string, ...args: unknown[]) => string;

function repositoryErrorOperation(code: string, localize: RepositoryErrorLocalize): string {
  if (code.includes("COMMIT")) {
    return localize("Commit");
  }
  if (code.includes("UPDATE") || code.includes("REMOTE_STATUS")) {
    return localize("Update");
  }
  if (code.includes("CHECKOUT")) {
    return localize("Checkout");
  }
  if (code.includes("HISTORY") || code.includes("BLAME")) {
    return localize("History");
  }
  if (code.includes("OPEN") || code.includes("WC_")) {
    return localize("Open Working Copy");
  }
  return localize("Repository Operation");
}

function repositoryFailureMessage(
  operation: string,
  error: unknown,
  localize: RepositoryErrorLocalize,
): string {
  switch (errorCode(error)) {
    case "SUBVERSIONR_HISTORY_REPOSITORY_ID_INVALID":
      return localize("Select an open SVN repository and try Show Repository Log again.");
    case "SUBVERSIONR_HISTORY_REPOSITORY_NOT_OPEN":
    case "SUBVERSIONR_HISTORY_REPOSITORY_SESSION_STALE":
      return localize(
        "The selected SVN repository session is no longer open. Select the current repository and try Show Repository Log again.",
      );
  }
  const cause = operationFailureCause(error);
  switch (cause) {
    case "outOfDate":
      return localize(
        "SVN {0} failed because the working copy is out of date. Update the working copy and retry.",
        operation,
      );
    case "conflictPresent":
      return localize("SVN {0} failed because unresolved conflicts are present. Resolve them and retry.", operation);
    case "authenticationFailed":
      return localize("SVN {0} failed because authentication was rejected. Check the credentials and retry.", operation);
    case "notWorkingCopy":
      return localize("SVN {0} failed because the selected target is not a working copy.", operation);
    default:
      if (errorCategory(error) === "auth") {
        return localize("SVN {0} failed because authentication was rejected. Check the credentials and retry.", operation);
      }
      if (isBackendUnavailableError(error)) {
        return localize("SVN {0} failed because the SubversionR backend is unavailable. Retry the operation.", operation);
      }
      return localize("SVN {0} failed. Open the SubversionR log for details.", operation);
  }
}

function operationFailureCause(error: unknown): string | undefined {
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

function isBackendUnavailableError(error: unknown): boolean {
  const code = errorCode(error);
  return code.includes("BACKEND") || code.includes("JSON_RPC") || code.includes("RPC_");
}

function isStatusRefreshCancellation(error: unknown): boolean {
  return errorCode(error) === "SUBVERSIONR_STATUS_REFRESH_CANCELLED";
}

function isUnknownRepositoryCommandError(error: unknown): boolean {
  return errorCode(error) === "SUBVERSIONR_REPOSITORY_COMMAND_FAILED";
}

function isInstalledSourceControlUiE2eRun(): boolean {
  return typeof process !== "undefined" && Boolean(process.env.SUBVERSIONR_INSTALLED_SOURCE_CONTROL_UI_E2E_RESULT);
}

function operationJournalScanPlan(result: OperationRunResponse): OperationJournalScanPlan {
  if (result.reconcile.requiresFullReconcile) {
    return "full";
  }
  if (result.reconcile.targets.length > 0) {
    return "targeted";
  }
  return "none";
}

function fullReconcileDocumentState(): OperationRunResponse["reconcile"] {
  return {
    targets: [],
    requiresFullReconcile: true,
  };
}

function operationJournalTouchedCount(result: OperationRunResponse, requestedTouchedCount: number): number {
  const summaryCount = result.summary.affectedPaths + result.summary.skippedPaths;
  if (summaryCount > 0) {
    return summaryCount;
  }
  if (result.touchedPaths.length > 0) {
    return result.touchedPaths.length;
  }
  return requestedTouchedCount;
}

function operationRunWithOptionalOptions<T>(
  operation: (options?: OperationRunClientOptions) => Promise<T>,
  signal: AbortSignal | undefined,
): Promise<T> {
  if (signal === undefined) {
    return operation();
  }
  return operation({ signal });
}

function statusRefreshRunOptions(signal: AbortSignal | undefined): { signal: AbortSignal } | undefined {
  return signal === undefined ? undefined : { signal };
}

function checkoutRunOptions(signal: AbortSignal | undefined): RepositoryCheckoutClientOptions | undefined {
  return signal === undefined ? undefined : { signal };
}

function operationJournalDurationMs(startedMonotonicMs: number, endedMonotonicMs: number): number {
  if (!Number.isFinite(startedMonotonicMs) || !Number.isFinite(endedMonotonicMs)) {
    throw new RepositoryCommandError(
      "SUBVERSIONR_OPERATION_JOURNAL_CLOCK_INVALID",
      "lifecycle",
      "error.operationJournal.clockInvalid",
    );
  }
  if (endedMonotonicMs < startedMonotonicMs) {
    throw new RepositoryCommandError(
      "SUBVERSIONR_OPERATION_JOURNAL_CLOCK_INVALID",
      "lifecycle",
      "error.operationJournal.clockInvalid",
    );
  }
  return Math.round(endedMonotonicMs - startedMonotonicMs);
}

function operationJournalFailureCategory(error: unknown): OperationJournalResultCategory {
  const code = errorCode(error);
  const category = errorCategory(error);
  if (category === "cancelled" || code.includes("CANCELLED")) {
    return "cancelled";
  }
  if (category === "input") {
    return "inputRejected";
  }
  if (category === "lifecycle") {
    return "lifecycleRejected";
  }
  if (category === "protocol") {
    return "protocolFailed";
  }
  return "failed";
}

function errorCategory(error: unknown): string | undefined {
  if (typeof error === "object" && error !== null && "category" in error) {
    const category = (error as { category?: unknown }).category;
    if (typeof category === "string" && category.trim().length > 0) {
      return category;
    }
  }
  return undefined;
}

interface ResourceMatch {
  session: RepositorySession;
  path: string;
  rootLength: number;
}

interface RepositoryCommandResourceTarget extends RepositoryResourceRefreshTarget {
  fsPath: string;
  source: "resource" | "uri";
  contextValue: string | undefined;
  resourceKind: string | undefined;
  projectionGeneration: number | undefined;
  pathCase: PathCasePolicy;
}

interface ValidatedOperationResource {
  path: string;
  kind: ScmProjectedResource["entry"]["kind"];
}

interface ChangelistGroupCommandTarget {
  repositoryId: string;
  changelist: string;
}

interface UnversionedDeleteTarget {
  path: string;
  fsPath: string;
  recursive: boolean;
}

interface IgnoreTargetGroup {
  parentPath: string;
  patterns: string[];
  childPaths: string[];
}

interface IgnorePropertyUpdate {
  value: string;
  addedPatterns: string[];
}

interface IgnorePropertyRemoval {
  value: string | undefined;
  removedPatterns: string[];
}

interface EditorUriLike {
  scheme: unknown;
  fsPath: unknown;
}

type RepositoryCommandErrorCategory = "input" | "lifecycle";

class RepositoryCommandError extends Error {
  public readonly retryable = false;
  public readonly diagnostics = null;

  public constructor(
    public readonly code: string,
    public readonly category: RepositoryCommandErrorCategory,
    public readonly messageKey: string,
    public readonly safeArgs: Record<string, unknown> = {},
  ) {
    super(code);
    this.name = "RepositoryCommandError";
  }
}

function requireResourceFsPath(resourceState: unknown, invalid: () => RepositoryCommandError): string {
  if (!isRecord(resourceState) || !isRecord(resourceState.resourceUri)) {
    throw invalid();
  }
  const fsPath = resourceState.resourceUri.fsPath;
  if (typeof fsPath !== "string" || fsPath.trim().length === 0) {
    throw invalid();
  }
  const normalized = normalizeAbsolutePath(fsPath);
  if (!isSafeAbsolutePath(normalized)) {
    throw invalid();
  }
  return normalized;
}

function requireEditorUriFsPath(uri: EditorUriLike, invalid: () => RepositoryCommandError): string {
  const fsPath = uri.fsPath;
  if (typeof fsPath !== "string" || fsPath.trim().length === 0) {
    throw invalid();
  }
  const normalized = normalizeAbsolutePath(fsPath);
  if (!isSafeAbsolutePath(normalized)) {
    throw invalid();
  }
  return normalized;
}

function requireRepositoryHistoryCommandTarget(argument: unknown): RepositoryHistoryCommandTarget {
  if (!isRecord(argument)) {
    throw historyRepositoryIdInvalid();
  }
  const keys = Object.keys(argument).sort();
  if (
    keys.length !== 3 ||
    keys[0] !== "epoch" ||
    keys[1] !== "kind" ||
    keys[2] !== "repositoryId" ||
    argument.kind !== REPOSITORY_HISTORY_COMMAND_TARGET_KIND ||
    typeof argument.repositoryId !== "string" ||
    argument.repositoryId.length === 0 ||
    argument.repositoryId !== argument.repositoryId.trim() ||
    !Number.isSafeInteger(argument.epoch) ||
    (argument.epoch as number) < 0
  ) {
    throw historyRepositoryIdInvalid();
  }
  return {
    kind: REPOSITORY_HISTORY_COMMAND_TARGET_KIND,
    repositoryId: argument.repositoryId,
    epoch: argument.epoch as number,
  };
}

function sameRepositorySessionSnapshot(left: RepositorySession, right: RepositorySession): boolean {
  return (
    left.repositoryId === right.repositoryId &&
    left.epoch === right.epoch &&
    left.identity.repositoryUuid === right.identity.repositoryUuid &&
    left.identity.repositoryRootUrl === right.identity.repositoryRootUrl &&
    left.identity.workingCopyRoot === right.identity.workingCopyRoot &&
    left.identity.workspaceScopeRoot === right.identity.workspaceScopeRoot &&
    left.identity.format === right.identity.format &&
    left.watchScope.repositoryId === right.watchScope.repositoryId &&
    left.watchScope.epoch === right.watchScope.epoch &&
    left.watchScope.workingCopyRoot === right.watchScope.workingCopyRoot &&
    left.watchScope.pathCase === right.watchScope.pathCase &&
    sameStringArray(left.watchScope.boundaryRoots, right.watchScope.boundaryRoots)
  );
}

function sameStringArray(left: readonly string[] | undefined, right: readonly string[] | undefined): boolean {
  if (left === right) {
    return true;
  }
  if (!left || !right || left.length !== right.length) {
    return false;
  }
  return left.every((value, index) => value === right[index]);
}

function commitAllResourceTarget(session: RepositorySession, path: string): RepositoryCommandResourceTarget {
  return {
    repositoryId: session.repositoryId,
    epoch: session.epoch,
    path,
    fsPath: repositoryResourceFsPath(session.identity.workingCopyRoot, path),
    source: "resource",
    contextValue: "subversionr.changedFile",
    resourceKind: "file",
    projectionGeneration: undefined,
    pathCase: session.watchScope.pathCase,
  };
}

function projectionResourceTarget(
  projection: ScmRepositoryProjection,
  resource: ScmProjectedResource,
  pathCase: PathCasePolicy,
): RepositoryCommandResourceTarget {
  return {
    repositoryId: projection.repositoryId,
    epoch: projection.epoch,
    path: resource.path,
    fsPath: repositoryResourceFsPath(projection.workingCopyRoot, resource.path),
    source: "resource",
    contextValue: resource.contextValue,
    resourceKind: resource.entry.kind,
    projectionGeneration: projection.generation,
    pathCase,
  };
}

function repositoryResourceFsPath(workingCopyRoot: string, repositoryRelativePath: string): string {
  const root = normalizeAbsolutePath(workingCopyRoot);
  if (repositoryRelativePath === ".") {
    return root;
  }
  return `${root}/${repositoryRelativePath}`;
}

function requireOptionalResourceKind(
  resourceState: unknown,
  invalid: () => RepositoryCommandError,
): string | undefined {
  if (!isRecord(resourceState)) {
    throw invalid();
  }
  const resourceKind = resourceState.subversionrResourceKind;
  if (resourceKind === undefined) {
    return undefined;
  }
  if (resourceKind !== "file" && resourceKind !== "dir") {
    throw invalid();
  }
  return resourceKind;
}

function requireOptionalProjectionGeneration(
  resourceState: unknown,
  invalid: () => RepositoryCommandError,
): number | undefined {
  if (!isRecord(resourceState)) {
    throw invalid();
  }
  const generation = resourceState.subversionrProjectionGeneration;
  if (generation === undefined) {
    return undefined;
  }
  if (typeof generation !== "number" || !Number.isSafeInteger(generation) || generation < 0) {
    throw invalid();
  }
  return generation;
}

function deleteAllUnversionedRepositoryIdArgument(argument: unknown): unknown {
  return sourceControlGroupRepositoryIdArgument(argument);
}

function sourceControlGroupRepositoryIdArgument(argument: unknown): unknown {
  if (isRecord(argument)) {
    const repositoryId = argument.subversionrRepositoryId;
    if (typeof repositoryId === "string") {
      return repositoryId;
    }
  }
  return argument;
}

function normalizeResourceStateArgs(resourceStateArgs: unknown[]): unknown[] {
  if (resourceStateArgs.length === 1 && Array.isArray(resourceStateArgs[0])) {
    return resourceStateArgs[0] as unknown[];
  }
  return resourceStateArgs;
}

function isEditorUriLike(value: unknown): value is EditorUriLike {
  return isRecord(value) && "scheme" in value && "fsPath" in value;
}

function requireResourceContext(
  resourceState: unknown,
  contexts: ReadonlySet<string>,
  invalid: () => RepositoryCommandError,
): string {
  if (!isRecord(resourceState)) {
    throw invalid();
  }
  if (
    typeof resourceState.contextValue !== "string" ||
    !contexts.has(resourceState.contextValue)
  ) {
    throw invalid();
  }
  return resourceState.contextValue;
}

function mostSpecificResourceMatch(sessions: RepositorySession[], fsPath: string): ResourceMatch | undefined {
  const matches = sessions.flatMap((session) => {
    const match = resourceMatch(session, fsPath);
    return match ? [match] : [];
  });
  return matches.sort(
    (left, right) =>
      right.rootLength - left.rootLength || left.session.repositoryId.localeCompare(right.session.repositoryId),
  )[0];
}

function resourceMatch(session: RepositorySession, fsPath: string): ResourceMatch | undefined {
  const root = normalizeAbsolutePath(session.identity.workingCopyRoot);
  if (!isSafeAbsolutePath(root)) {
    return undefined;
  }
  const pathCase = session.watchScope.pathCase;
  const rootKey = comparisonKey(pathCase, root);
  const fsPathKey = comparisonKey(pathCase, fsPath);
  let relativePath: string;
  if (fsPathKey === rootKey) {
    relativePath = ".";
  } else if (fsPathKey.startsWith(`${rootKey}/`)) {
    relativePath = fsPath.slice(root.length + 1);
  } else {
    return undefined;
  }
  if (!isRepositoryRelativeResourcePath(relativePath)) {
    throw invalidResourceRefreshTarget();
  }
  return {
    session,
    path: relativePath,
    rootLength: rootKey.length,
  };
}

function isRepositoryRelativeResourcePath(path: string): boolean {
  if (path === ".") {
    return true;
  }
  if (path.trim().length === 0 || path.includes("\\") || path.startsWith("/") || path.endsWith("/")) {
    return false;
  }
  const parts = path.split("/");
  if (parts.some((part) => part.length === 0 || part === "." || part === "..")) {
    return false;
  }
  return parts[0] !== SVN_INTERNAL_PATH;
}

function normalizeAbsolutePath(path: string): string {
  return path.replaceAll("\\", "/").replace(/\/+$/u, "");
}

function isSafeAbsolutePath(path: string): boolean {
  if (!nodePath.win32.isAbsolute(path) && !nodePath.posix.isAbsolute(path)) {
    return false;
  }
  const parts = path.split("/");
  return !parts.some((part, index) => {
    if (part === "." || part === "..") {
      return true;
    }
    if (part !== "") {
      return false;
    }
    return !isAllowedAbsolutePrefix(parts, index);
  });
}

function isAllowedAbsolutePrefix(parts: string[], index: number): boolean {
  if (index === 0 && parts.length > 1) {
    return true;
  }
  return index === 1 && parts[0] === "" && parts.length > 2;
}

function comparisonKey(pathCase: PathCasePolicy, path: string): string {
  return pathCase === "case-insensitive" ? path.toLocaleLowerCase("en-US") : path;
}

function targetsShareRepository(targets: readonly RepositoryCommandResourceTarget[]): boolean {
  const [firstTarget] = targets;
  if (!firstTarget) {
    return false;
  }
  return targets.every(
    (target) => target.repositoryId === firstTarget.repositoryId && target.epoch === firstTarget.epoch,
  );
}

function hasDuplicateResourcePaths(targets: readonly RepositoryCommandResourceTarget[]): boolean {
  const seen = new Set<string>();
  for (const target of targets) {
    const key = comparisonKey(target.pathCase, target.path);
    if (seen.has(key)) {
      return true;
    }
    seen.add(key);
  }
  return false;
}

function findProjectionResource(
  projection: ScmRepositoryProjection,
  target: RepositoryCommandResourceTarget,
): ScmProjectedResource | undefined {
  const targetPathKey = comparisonKey(target.pathCase, target.path);
  for (const group of projection.groups) {
    for (const resource of group.resources) {
      if (
        resource.repositoryId === target.repositoryId &&
        comparisonKey(target.pathCase, resource.path) === targetPathKey
      ) {
        return resource;
      }
    }
  }
  return undefined;
}

function isHistoryFileProjectedResource(resource: ScmProjectedResource): boolean {
  return (
    resource.entry.kind === "file" &&
    resource.source === "local" &&
    (isLocalChangeGroup(resource.groupId) || resource.groupId === "conflicts") &&
    !resource.entry.external &&
    resource.entry.localStatus !== "ignored" &&
    LOCAL_HISTORY_FILE_CONTEXT_VALUES.has(resource.contextValue)
  );
}

function isHeadContentProjectedResource(resource: ScmProjectedResource): boolean {
  return isBaseDiffableProjectedResource(resource) || isIncomingHeadContentProjectedResource(resource);
}

function isIncomingHeadContentProjectedResource(resource: ScmProjectedResource): boolean {
  return (
    resource.entry.kind === "file" &&
    resource.source === "remote" &&
    resource.groupId === "incoming" &&
    !resource.entry.external &&
    HEAD_CONTENT_CONTEXT_VALUES.has(resource.contextValue)
  );
}

function isIncomingUpdateableProjectedResource(resource: ScmProjectedResource): boolean {
  return (
    resource.path !== "." &&
    resource.source === "remote" &&
    resource.groupId === "incoming" &&
    REMOTE_UPDATEABLE_CONTEXT_VALUES.has(resource.contextValue)
  );
}

function isUnversionedDeletableProjectedResource(resource: ScmProjectedResource): boolean {
  return (
    resource.path !== "." &&
    resource.source === "local" &&
    resource.groupId === "unversioned" &&
    resource.contextValue === "subversionr.unversioned" &&
    (resource.entry.kind === "file" || resource.entry.kind === "dir") &&
    resource.entry.localStatus === "unversioned" &&
    !resource.entry.external
  );
}

function isAddableProjectedResource(resource: ScmProjectedResource): boolean {
  return isUnversionedDeletableProjectedResource(resource);
}

function addDepthForProjectedResource(resource: ValidatedOperationResource): "empty" | "infinity" {
  return resource.kind === "dir" ? "infinity" : "empty";
}

function isIgnorableProjectedResource(resource: ScmProjectedResource): boolean {
  return isUnversionedDeletableProjectedResource(resource);
}

function isIgnoreRemovableProjectedResource(resource: ScmProjectedResource): boolean {
  return (
    resource.path !== "." &&
    resource.source === "local" &&
    resource.groupId === "ignored" &&
    LOCAL_IGNORE_REMOVABLE_CONTEXT_VALUES.has(resource.contextValue) &&
    (resource.entry.kind === "file" || resource.entry.kind === "dir") &&
    resource.entry.localStatus === "ignored" &&
    !resource.entry.external
  );
}

function isResolvableProjectedResource(resource: ScmProjectedResource): boolean {
  return (
    resource.source === "local" &&
    resource.groupId === "conflicts" &&
    LOCAL_RESOLVABLE_CONTEXT_VALUES.has(resource.contextValue) &&
    !resource.entry.external
  );
}

function groupedIgnoreTargets(paths: readonly string[]): IgnoreTargetGroup[] {
  const groups = new Map<string, IgnoreTargetGroup>();
  for (const path of paths) {
    const parentPath = ignoreParentPath(path);
    const pattern = ignorePatternForPath(path);
    let group = groups.get(parentPath);
    if (!group) {
      group = {
        parentPath,
        patterns: [],
        childPaths: [],
      };
      groups.set(parentPath, group);
    }
    if (!group.patterns.includes(pattern)) {
      group.patterns.push(pattern);
    }
    group.childPaths.push(path);
  }
  return [...groups.values()];
}

function ignoreParentPath(path: string): string {
  const lastSlash = path.lastIndexOf("/");
  if (lastSlash < 0) {
    return ".";
  }
  return path.slice(0, lastSlash);
}

function ignorePatternForPath(path: string): string {
  const lastSlash = path.lastIndexOf("/");
  return lastSlash < 0 ? path : path.slice(lastSlash + 1);
}

function svnIgnorePropertyValue(properties: PropertiesListResponse): string | undefined {
  return properties.properties.find((property) => property.name === "svn:ignore")?.value;
}

function svnMergeinfoPropertyValue(properties: PropertiesListResponse): string | undefined {
  return properties.properties.find((property) => property.name === "svn:mergeinfo")?.value;
}

function svnExternalsPropertyValue(properties: PropertiesListResponse): string | undefined {
  return properties.properties.find((property) => property.name === "svn:externals")?.value;
}

interface MergeDocumentLabels {
  sourceUrl: string;
  startRevision: string;
  endRevision: string;
  mergeDirection: string;
  additiveMerge: string;
  subtractiveMerge: string;
  targetPath: string;
  statusReconcileMode: string;
  statusRefreshTargetCount: string;
  affectedPathCount: string;
  skippedPathCount: string;
  warningCount: string;
  mergeOption: string;
  mergeOptionValue: string;
  mergeDepth: string;
  mergeDryRun: string;
  recordOnly: string;
  ignoreMergeinfo: string;
  ignoreAncestry: string;
  allowMixedRevisions: string;
  allowForcedDeletes: string;
  yes: string;
  no: string;
  fullReconcile: string;
  targetedStatusRefresh: string;
  noStatusRefresh: string;
  affectedPath: string;
  noAffectedPaths: string;
  skippedPath: string;
  noSkippedPaths: string;
  skippedPathDetailsUnavailable: string;
  operationWarning: string;
  warningKey: string;
  warningDetails: string;
  statusRefreshTarget: string;
  statusRefreshDepth: string;
  statusRefreshReason: string;
}

function svnMergePreviewDocument(
  title: string,
  targetPath: string,
  summary: OperationRunResponse["summary"],
  affectedPaths: readonly string[],
  reconcile: OperationRunResponse["reconcile"],
  warnings: readonly OperationWarning[],
  options: RepositoryMergeRangeOptions,
  labels: MergeDocumentLabels,
): string {
  const statusRefreshTargets = reconcile.targets;
  const statusReconcileMode = reconcile.requiresFullReconcile
    ? labels.fullReconcile
    : statusRefreshTargets.length > 0
      ? labels.targetedStatusRefresh
      : labels.noStatusRefresh;
  const skippedPaths = warnings.flatMap((warning) =>
    warning.code === "SVN_OPERATION_PATH_SKIPPED" && typeof warning.args.path === "string" ? [warning.args.path] : [],
  );
  const visibleWarnings = warnings.filter(
    (warning) => warning.code !== "SVN_OPERATION_PATH_SKIPPED" || typeof warning.args.path !== "string",
  );
  const affectedPathRows =
    affectedPaths.length > 0
      ? affectedPaths.map((path) => `| ${escapeMarkdownTableCell(path)} |`)
      : [`| ${escapeMarkdownTableCell(labels.noAffectedPaths)} |`];
  const skippedPathRows =
    skippedPaths.length > 0
      ? skippedPaths.map((path) => `| ${escapeMarkdownTableCell(path)} |`)
      : [
          `| ${escapeMarkdownTableCell(
            summary.skippedPaths > 0 ? labels.skippedPathDetailsUnavailable : labels.noSkippedPaths,
          )} |`,
        ];
  const mergeDirection = mergeRangeDirection(options, labels);
  const lines = [
    title,
    "",
    `| ${escapeMarkdownTableCell(labels.sourceUrl)} | ${escapeMarkdownTableCell(labels.startRevision)} | ${escapeMarkdownTableCell(labels.endRevision)} | ${escapeMarkdownTableCell(labels.mergeDirection)} | ${escapeMarkdownTableCell(labels.targetPath)} | ${escapeMarkdownTableCell(labels.statusReconcileMode)} | ${escapeMarkdownTableCell(labels.statusRefreshTargetCount)} | ${escapeMarkdownTableCell(labels.affectedPathCount)} | ${escapeMarkdownTableCell(labels.skippedPathCount)} | ${escapeMarkdownTableCell(labels.warningCount)} |`,
    "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    `| ${escapeMarkdownTableCell(options.sourceUrl)} | r${options.startRevision} | r${options.endRevision} | ${escapeMarkdownTableCell(mergeDirection)} | ${escapeMarkdownTableCell(targetPath)} | ${escapeMarkdownTableCell(statusReconcileMode)} | ${statusRefreshTargets.length} | ${summary.affectedPaths} | ${summary.skippedPaths} | ${warnings.length} |`,
    "",
    `| ${escapeMarkdownTableCell(labels.mergeOption)} | ${escapeMarkdownTableCell(labels.mergeOptionValue)} |`,
    "| --- | --- |",
    `| ${escapeMarkdownTableCell(labels.mergeDepth)} | ${escapeMarkdownTableCell(options.depth)} |`,
    `| ${escapeMarkdownTableCell(labels.mergeDryRun)} | ${escapeMarkdownTableCell(booleanLabel(options.dryRun, labels))} |`,
    `| ${escapeMarkdownTableCell(labels.recordOnly)} | ${escapeMarkdownTableCell(booleanLabel(options.recordOnly, labels))} |`,
    `| ${escapeMarkdownTableCell(labels.ignoreMergeinfo)} | ${escapeMarkdownTableCell(booleanLabel(options.ignoreMergeinfo, labels))} |`,
    `| ${escapeMarkdownTableCell(labels.ignoreAncestry)} | ${escapeMarkdownTableCell(booleanLabel(options.diffIgnoreAncestry, labels))} |`,
    `| ${escapeMarkdownTableCell(labels.allowMixedRevisions)} | ${escapeMarkdownTableCell(booleanLabel(options.allowMixedRevisions, labels))} |`,
    `| ${escapeMarkdownTableCell(labels.allowForcedDeletes)} | ${escapeMarkdownTableCell(booleanLabel(options.forceDelete, labels))} |`,
    "",
    `| ${escapeMarkdownTableCell(labels.affectedPath)} |`,
    "| --- |",
    ...affectedPathRows,
  ];
  if (statusRefreshTargets.length > 0) {
    lines.push(
      "",
      `| ${escapeMarkdownTableCell(labels.statusRefreshTarget)} | ${escapeMarkdownTableCell(labels.statusRefreshDepth)} | ${escapeMarkdownTableCell(labels.statusRefreshReason)} |`,
      "| --- | --- | --- |",
      ...statusRefreshTargets.map(
        (target) =>
          `| ${escapeMarkdownTableCell(target.path)} | ${escapeMarkdownTableCell(target.depth)} | ${escapeMarkdownTableCell(target.reason)} |`,
      ),
    );
  }
  lines.push("", `| ${escapeMarkdownTableCell(labels.skippedPath)} |`, "| --- |", ...skippedPathRows);
  if (visibleWarnings.length > 0) {
    lines.push(
      "",
      `| ${escapeMarkdownTableCell(labels.operationWarning)} | ${escapeMarkdownTableCell(labels.warningKey)} | ${escapeMarkdownTableCell(labels.warningDetails)} |`,
      "| --- | --- | --- |",
      ...visibleWarnings.map(
        (warning) =>
          `| ${escapeMarkdownTableCell(warning.code)} | ${escapeMarkdownTableCell(warning.messageKey)} | ${escapeMarkdownTableCell(JSON.stringify(warning.args))} |`,
      ),
    );
  }
  return lines.join("\n");
}

function booleanLabel(value: boolean, labels: Pick<MergeDocumentLabels, "yes" | "no">): string {
  return value ? labels.yes : labels.no;
}

function mergeRangeDirection(
  options: Pick<RepositoryMergeRangeOptions, "startRevision" | "endRevision">,
  labels: Pick<MergeDocumentLabels, "additiveMerge" | "subtractiveMerge">,
): string {
  return options.startRevision < options.endRevision ? labels.additiveMerge : labels.subtractiveMerge;
}

function resolveChoiceLabel(
  choice: ResolveOperationChoice,
  localize: RepositoryCommandControllerOptions["localize"],
): string {
  switch (choice) {
    case "working":
      return localize("Working copy");
    case "base":
      return localize("Base");
    case "mineFull":
      return localize("Mine full");
    case "theirsFull":
      return localize("Theirs full");
    case "mineConflict":
      return localize("Mine conflict");
    case "theirsConflict":
      return localize("Theirs conflict");
  }
}

function svnMergeinfoDocument(
  title: string,
  targetPath: string,
  propertySource: string,
  mergeinfo: string,
  labels: {
    mergeinfoPath: string;
    propertySource: string;
    mergeinfoSourcePathCount: string;
    mergeinfoRevisionRangeCount: string;
    mergeinfoUnparsedLineCount: string;
    mergeinfoUnparsedRevisionRangeCount: string;
    sourcePath: string;
    sourceRevisionRangeCount: string;
    latestMergedRevision: string;
    nonInheritableRangeCount: string;
    rangeStartRevision: string;
    rangeEndRevision: string;
    nonInheritableRange: string;
    revisionRanges: string;
    noParsedSourcePaths: string;
    unparsedMergeinfoRange: string;
    unparsedMergeinfoLine: string;
    rawMergeinfo: string;
    yes: string;
    no: string;
  },
): string {
  const rows: { sourcePath: string; revisionRanges: string }[] = [];
  const unparsedLines: string[] = [];
  for (const line of mergeinfo.split("\n")) {
    const entry = mergeinfoTableEntry(line);
    if (entry === undefined) {
      continue;
    }
    if ("unparsedLine" in entry) {
      unparsedLines.push(entry.unparsedLine);
    } else {
      rows.push(entry);
    }
  }
  const revisionRangeCount = rows.reduce(
    (count, row) => count + mergeinfoRevisionRangeCount(row.revisionRanges),
    0,
  );
  const nonInheritableRangeCount = rows.reduce(
    (count, row) => count + mergeinfoNonInheritableRangeCount(row.revisionRanges),
    0,
  );
  const table = [
    `| ${escapeMarkdownTableCell(labels.sourcePath)} | ${escapeMarkdownTableCell(labels.sourceRevisionRangeCount)} | ${escapeMarkdownTableCell(labels.latestMergedRevision)} | ${escapeMarkdownTableCell(labels.nonInheritableRangeCount)} | ${escapeMarkdownTableCell(labels.revisionRanges)} |`,
    "| --- | --- | --- | --- | --- |",
    ...(rows.length > 0
      ? rows.map((row) => {
          const latestMergedRevision = mergeinfoLatestMergedRevision(row.revisionRanges);
          return `| ${escapeMarkdownTableCell(row.sourcePath)} | ${mergeinfoRevisionRangeCount(row.revisionRanges)} | ${escapeMarkdownTableCell(latestMergedRevision)} | ${mergeinfoNonInheritableRangeCount(row.revisionRanges)} | ${escapeMarkdownTableCell(row.revisionRanges)} |`;
        })
      : [`| ${escapeMarkdownTableCell(labels.noParsedSourcePaths)} | 0 |  | 0 |  |`]),
  ];
  const revisionRangeRows = rows.flatMap((row) => mergeinfoRevisionRangeRows(row.sourcePath, row.revisionRanges));
  const revisionRangeTable =
    revisionRangeRows.length > 0
      ? [
          "",
          `| ${escapeMarkdownTableCell(labels.sourcePath)} | ${escapeMarkdownTableCell(labels.rangeStartRevision)} | ${escapeMarkdownTableCell(labels.rangeEndRevision)} | ${escapeMarkdownTableCell(labels.nonInheritableRange)} |`,
          "| --- | --- | --- | --- |",
          ...revisionRangeRows.map(
            (row) =>
              `| ${escapeMarkdownTableCell(row.sourcePath)} | r${row.startRevision} | r${row.endRevision} | ${escapeMarkdownTableCell(row.nonInheritable ? labels.yes : labels.no)} |`,
          ),
        ]
      : [];
  const unparsedRangeRows = rows.flatMap((row) => mergeinfoUnparsedRevisionRangeRows(row.sourcePath, row.revisionRanges));
  const unparsedRangeTable =
    unparsedRangeRows.length > 0
      ? [
          "",
          `| ${escapeMarkdownTableCell(labels.sourcePath)} | ${escapeMarkdownTableCell(labels.unparsedMergeinfoRange)} |`,
          "| --- | --- |",
          ...unparsedRangeRows.map(
            (row) => `| ${escapeMarkdownTableCell(row.sourcePath)} | ${escapeMarkdownTableCell(row.revisionRange)} |`,
          ),
        ]
      : [];
  const unparsedTable =
    unparsedLines.length > 0
      ? [
          "",
          `| ${escapeMarkdownTableCell(labels.unparsedMergeinfoLine)} |`,
          "| --- |",
          ...unparsedLines.map((line) => `| ${escapeMarkdownTableCell(line)} |`),
        ]
      : [];
  return [
    title,
    "",
    `| ${escapeMarkdownTableCell(labels.mergeinfoPath)} | ${escapeMarkdownTableCell(labels.propertySource)} | ${escapeMarkdownTableCell(labels.mergeinfoSourcePathCount)} | ${escapeMarkdownTableCell(labels.mergeinfoRevisionRangeCount)} | ${escapeMarkdownTableCell(labels.nonInheritableRangeCount)} | ${escapeMarkdownTableCell(labels.mergeinfoUnparsedRevisionRangeCount)} | ${escapeMarkdownTableCell(labels.mergeinfoUnparsedLineCount)} |`,
    "| --- | --- | --- | --- | --- | --- | --- |",
    `| ${escapeMarkdownTableCell(targetPath)} | ${escapeMarkdownTableCell(propertySource)} | ${rows.length} | ${revisionRangeCount} | ${nonInheritableRangeCount} | ${unparsedRangeRows.length} | ${unparsedLines.length} |`,
    "",
    ...table,
    ...revisionRangeTable,
    ...unparsedRangeTable,
    ...unparsedTable,
    "",
    labels.rawMergeinfo,
    "",
    "```text",
    mergeinfo,
    "```",
  ].join("\n");
}

function svnPropertiesDocument(
  title: string,
  targetPath: string,
  propertySource: string,
  properties: readonly PropertyEntry[],
  labels: {
    propertyPath: string;
    propertySource: string;
    propertyCount: string;
    propertyName: string;
    propertyValue: string;
  },
): string {
  return [
    title,
    "",
    `| ${escapeMarkdownTableCell(labels.propertyPath)} | ${escapeMarkdownTableCell(labels.propertySource)} | ${escapeMarkdownTableCell(labels.propertyCount)} |`,
    "| --- | --- | --- |",
    `| ${escapeMarkdownTableCell(targetPath)} | ${escapeMarkdownTableCell(propertySource)} | ${properties.length} |`,
    "",
    `| ${escapeMarkdownTableCell(labels.propertyName)} | ${escapeMarkdownTableCell(labels.propertyValue)} |`,
    "| --- | --- |",
    ...properties.map(
      (property) =>
        `| ${escapeMarkdownTableCell(property.name)} | ${escapeMarkdownTableCell(property.value)} |`,
    ),
  ].join("\n");
}

function mergeinfoRevisionRangeCount(revisionRanges: string): number {
  return revisionRanges.split(",").filter((revisionRange) => revisionRange.trim().length > 0).length;
}

function mergeinfoNonInheritableRangeCount(revisionRanges: string): number {
  return revisionRanges
    .split(",")
    .filter((revisionRange) => revisionRange.trim().endsWith("*") && revisionRange.trim().length > 1).length;
}

interface MergeinfoRevisionRangeRow {
  sourcePath: string;
  startRevision: number;
  endRevision: number;
  nonInheritable: boolean;
}

function mergeinfoRevisionRangeRows(
  sourcePath: string,
  revisionRanges: string,
): MergeinfoRevisionRangeRow[] {
  return revisionRanges.split(",").flatMap((revisionRange) => {
    const row = mergeinfoRevisionRangeRow(sourcePath, revisionRange);
    return row === undefined ? [] : [row];
  });
}

function mergeinfoUnparsedRevisionRangeRows(
  sourcePath: string,
  revisionRanges: string,
): { sourcePath: string; revisionRange: string }[] {
  return revisionRanges.split(",").flatMap((revisionRange) => {
    const trimmed = revisionRange.trim();
    if (trimmed.length === 0 || mergeinfoRevisionRangeRow(sourcePath, trimmed) !== undefined) {
      return [];
    }
    return [{ sourcePath, revisionRange: trimmed }];
  });
}

function mergeinfoRevisionRangeRow(
  sourcePath: string,
  revisionRange: string,
): MergeinfoRevisionRangeRow | undefined {
  const trimmed = revisionRange.trim();
  if (trimmed.length === 0) {
    return undefined;
  }
  const nonInheritable = trimmed.endsWith("*");
  const normalized = nonInheritable ? trimmed.slice(0, -1) : trimmed;
  const revisions = normalized.split("-");
  if (revisions.length > 2) {
    return undefined;
  }
  const [start, end] = revisions;
  const startRevision = mergeinfoRevisionNumber(start);
  if (startRevision === undefined) {
    return undefined;
  }
  const endRevision = end === undefined ? startRevision : mergeinfoRevisionNumber(end);
  if (endRevision === undefined) {
    return undefined;
  }
  return {
    sourcePath,
    startRevision,
    endRevision,
    nonInheritable,
  };
}

function mergeinfoLatestMergedRevision(revisionRanges: string): string {
  let latestRevision: number | undefined;
  for (const revisionRange of revisionRanges.split(",")) {
    const latestRangeRevision = mergeinfoLatestRangeRevision(revisionRange);
    if (latestRangeRevision === undefined) {
      return "";
    }
    latestRevision =
      latestRevision === undefined ? latestRangeRevision : Math.max(latestRevision, latestRangeRevision);
  }
  return latestRevision === undefined ? "" : `r${latestRevision}`;
}

function mergeinfoLatestRangeRevision(revisionRange: string): number | undefined {
  const normalized = revisionRange.trim().replace(/\*$/u, "");
  if (normalized.length === 0) {
    return undefined;
  }
  const revisions = normalized.split("-");
  if (revisions.length > 2) {
    return undefined;
  }
  const [start, end] = revisions;
  const startRevision = mergeinfoRevisionNumber(start);
  if (startRevision === undefined) {
    return undefined;
  }
  if (end === undefined) {
    return startRevision;
  }
  const endRevision = mergeinfoRevisionNumber(end);
  return endRevision === undefined ? undefined : Math.max(startRevision, endRevision);
}

function mergeinfoRevisionNumber(value: string): number | undefined {
  if (!/^\d+$/u.test(value)) {
    return undefined;
  }
  const revision = Number(value);
  return Number.isSafeInteger(revision) ? revision : undefined;
}

function mergeinfoTableEntry(
  line: string,
): { sourcePath: string; revisionRanges: string } | { unparsedLine: string } | undefined {
  const trimmed = line.trim();
  if (trimmed.length === 0) {
    return undefined;
  }
  const separator = trimmed.lastIndexOf(":");
  if (separator < 1 || separator === trimmed.length - 1) {
    return {
      unparsedLine: trimmed,
    };
  }
  return {
    sourcePath: trimmed.slice(0, separator),
    revisionRanges: trimmed.slice(separator + 1),
  };
}

function escapeMarkdownTableCell(value: string): string {
  return value.replace(/\\/gu, "\\\\").replace(/\|/gu, "\\|").replace(/\r\n|\r|\n/gu, "<br>");
}

function appendSvnIgnorePatterns(
  existingValue: string | undefined,
  patterns: readonly string[],
): IgnorePropertyUpdate | undefined {
  const lines = existingValue === undefined || existingValue.length === 0 ? [] : existingValue.split("\n");
  const addedPatterns: string[] = [];
  for (const pattern of patterns) {
    if (!lines.includes(pattern)) {
      lines.push(pattern);
      addedPatterns.push(pattern);
    }
  }
  return addedPatterns.length > 0
    ? {
        value: lines.join("\n"),
        addedPatterns,
      }
    : undefined;
}

function removeSvnIgnorePatterns(
  existingValue: string | undefined,
  patterns: readonly string[],
): IgnorePropertyRemoval | undefined {
  if (existingValue === undefined || existingValue.length === 0) {
    return undefined;
  }
  const removePatterns = new Set(patterns);
  const removedPatterns: string[] = [];
  const remaining = existingValue.split("\n").filter((line) => {
    if (!removePatterns.has(line)) {
      return true;
    }
    if (!removedPatterns.includes(line)) {
      removedPatterns.push(line);
    }
    return false;
  });
  return removedPatterns.length > 0
    ? {
        value: remaining.some((line) => line.length > 0) ? remaining.join("\n") : undefined,
        removedPatterns,
      }
    : undefined;
}

function isRevertableProjectedResource(resource: ScmProjectedResource): boolean {
  return (
    resource.path !== "." &&
    resource.source === "local" &&
    (isLocalChangeGroup(resource.groupId) || resource.groupId === "conflicts") &&
    LOCAL_REVERTABLE_CONTEXT_VALUES.has(resource.contextValue) &&
    resource.entry.localStatus !== "ignored" &&
    !resource.entry.external
  );
}

function isChangelistableProjectedResource(resource: ScmProjectedResource): boolean {
  return (
    resource.path !== "." &&
    resource.source === "local" &&
    (isLocalChangeGroup(resource.groupId) || resource.groupId === "conflicts") &&
    LOCAL_CHANGELISTABLE_CONTEXT_VALUES.has(resource.contextValue) &&
    resource.entry.localStatus !== "ignored" &&
    !resource.entry.external
  );
}

function isChangelistedProjectedResource(resource: ScmProjectedResource): boolean {
  return isChangelistableProjectedResource(resource) && resource.entry.changelist !== null;
}

function isLockableProjectedResource(resource: ScmProjectedResource): boolean {
  return (
    resource.path !== "." &&
    resource.source === "local" &&
    (isLocalChangeGroup(resource.groupId) || resource.groupId === "conflicts" || resource.groupId === "metadata") &&
    LOCAL_LOCKABLE_PROJECTED_CONTEXT_VALUES.has(resource.contextValue) &&
    resource.entry.kind === "file" &&
    resource.entry.localStatus !== "ignored" &&
    !resource.entry.external
  );
}

function isUnlockableProjectedResource(resource: ScmProjectedResource): boolean {
  return isLockableProjectedResource(resource) && resource.entry.lock !== null;
}

function isChangelistCommitProjectedResource(resource: ScmProjectedResource): boolean {
  return (
    resource.path !== "." &&
    resource.source === "local" &&
    isChangelistResourceGroupId(resource.groupId) &&
    LOCAL_COMMITTABLE_CONTEXT_VALUES.has(resource.contextValue) &&
    resource.entry.kind === "file" &&
    resource.entry.changelist !== null &&
    resource.entry.localStatus !== "ignored" &&
    !resource.entry.external
  );
}

function isCommittableResourceTarget(target: RepositoryCommandResourceTarget): boolean {
  if (target.contextValue === undefined) {
    return false;
  }
  if (target.resourceKind === "file") {
    return LOCAL_COMMITTABLE_FILE_CONTEXT_VALUES.has(target.contextValue);
  }
  if (target.resourceKind === "dir") {
    return LOCAL_COMMITTABLE_DIRECTORY_CONTEXT_VALUES.has(target.contextValue);
  }
  return false;
}

function isRemovableProjectedResource(resource: ScmProjectedResource): boolean {
  return (
    resource.path !== "." &&
    resource.source === "local" &&
    (isLocalChangeGroup(resource.groupId) || resource.groupId === "conflicts") &&
    LOCAL_REMOVABLE_CONTEXT_VALUES.has(resource.contextValue) &&
    resource.entry.localStatus !== "ignored" &&
    !resource.entry.external
  );
}

function isMovableProjectedResource(resource: ScmProjectedResource): boolean {
  return (
    resource.path !== "." &&
    resource.source === "local" &&
    (isLocalChangeGroup(resource.groupId) || resource.groupId === "conflicts") &&
    LOCAL_MOVABLE_CONTEXT_VALUES.has(resource.contextValue) &&
    resource.entry.localStatus !== "ignored" &&
    !resource.entry.external
  );
}

function isLocalChangeGroup(groupId: ScmProjectedResource["groupId"]): boolean {
  return groupId === "changes" || isChangelistResourceGroupId(groupId);
}

function validateChangelistName(value: string): string {
  if (value.trim().length === 0 || value.includes("\0") || value.includes("\r") || value.includes("\n")) {
    throw invalidChangelistName();
  }
  return value;
}

function isDiffPreviousRevision(revision: number): boolean {
  return Number.isSafeInteger(revision) && revision > 0 && revision <= 2_147_483_647;
}

function validateRepositoryUpdateOptions(options: RepositoryUpdateOptions): RepositoryUpdateOptions {
  if (!isRecord(options)) {
    throw invalidUpdateOptions("revision");
  }
  for (const key of Object.keys(options)) {
    if (key !== "revision" && key !== "depth" && key !== "depthIsSticky" && key !== "ignoreExternals") {
      throw invalidUpdateOptions(key);
    }
  }
  const revision = updateRevision(options.revision);
  const depth = updateDepth(options.depth);
  if (typeof options.depthIsSticky !== "boolean") {
    throw invalidUpdateOptions("depthIsSticky");
  }
  if (depth === "workingCopy" && options.depthIsSticky) {
    throw invalidUpdateOptions("depthIsSticky");
  }
  if (typeof options.ignoreExternals !== "boolean") {
    throw invalidUpdateOptions("ignoreExternals");
  }
  return {
    revision,
    depth,
    depthIsSticky: options.depthIsSticky,
    ignoreExternals: options.ignoreExternals,
  };
}

function validateRepositoryCheckoutOptions(options: RepositoryCheckoutOptions): RepositoryCheckoutOptions {
  if (!isRecord(options)) {
    throw invalidCheckoutOptions("url");
  }
  for (const key of Object.keys(options)) {
    if (key !== "url" && key !== "targetPath" && key !== "revision" && key !== "depth" && key !== "ignoreExternals") {
      throw invalidCheckoutOptions(key);
    }
  }
  const url = checkoutUrl(options.url);
  const targetPath = checkoutTargetPath(options.targetPath);
  const revision = checkoutRevision(options.revision);
  const depth = checkoutDepth(options.depth);
  if (typeof options.ignoreExternals !== "boolean") {
    throw invalidCheckoutOptions("ignoreExternals");
  }
  return {
    url,
    targetPath,
    revision,
    depth,
    ignoreExternals: options.ignoreExternals,
  };
}

function validateRepositoryCleanupOptions(options: RepositoryCleanupOptions): RepositoryCleanupOptions {
  if (!isRecord(options)) {
    throw invalidCleanupOptions("breakLocks");
  }
  for (const key of Object.keys(options)) {
    if (
      key !== "breakLocks" &&
      key !== "fixRecordedTimestamps" &&
      key !== "clearDavCache" &&
      key !== "vacuumPristines" &&
      key !== "includeExternals"
    ) {
      throw invalidCleanupOptions(key);
    }
  }
  for (const key of ["breakLocks", "fixRecordedTimestamps", "clearDavCache", "vacuumPristines", "includeExternals"] as const) {
    if (typeof options[key] !== "boolean") {
      throw invalidCleanupOptions(key);
    }
  }
  return {
    breakLocks: options.breakLocks,
    fixRecordedTimestamps: options.fixRecordedTimestamps,
    clearDavCache: options.clearDavCache,
    vacuumPristines: options.vacuumPristines,
    includeExternals: options.includeExternals,
  };
}

function validateRepositoryBranchCreateOptions(options: RepositoryBranchCreateOptions): RepositoryBranchCreateOptions {
  if (!isRecord(options)) {
    throw invalidBranchCreateOptions("sourceUrl");
  }
  for (const key of Object.keys(options)) {
    if (
      key !== "sourceUrl" &&
      key !== "destinationUrl" &&
      key !== "revision" &&
      key !== "message" &&
      key !== "makeParents" &&
      key !== "ignoreExternals" &&
      key !== "switchAfterCreate"
    ) {
      throw invalidBranchCreateOptions(key);
    }
  }
  const sourceUrl = branchCreateUrl(options.sourceUrl, "sourceUrl");
  const destinationUrl = branchCreateUrl(options.destinationUrl, "destinationUrl");
  if (destinationUrl === sourceUrl) {
    throw invalidBranchCreateOptions("destinationUrl");
  }
  const revision = branchCreateRevision(options.revision);
  const message = branchCreateMessage(options.message);
  if (typeof options.makeParents !== "boolean") {
    throw invalidBranchCreateOptions("makeParents");
  }
  if (typeof options.ignoreExternals !== "boolean") {
    throw invalidBranchCreateOptions("ignoreExternals");
  }
  if (typeof options.switchAfterCreate !== "boolean") {
    throw invalidBranchCreateOptions("switchAfterCreate");
  }
  return {
    sourceUrl,
    destinationUrl,
    revision,
    message,
    makeParents: options.makeParents,
    ignoreExternals: options.ignoreExternals,
    switchAfterCreate: options.switchAfterCreate,
  };
}

function validateRepositorySwitchOptions(options: RepositorySwitchOptions): RepositorySwitchOptions {
  if (!isRecord(options)) {
    throw invalidSwitchOptions("url");
  }
  for (const key of Object.keys(options)) {
    if (
      key !== "url" &&
      key !== "revision" &&
      key !== "depth" &&
      key !== "depthIsSticky" &&
      key !== "ignoreExternals" &&
      key !== "ignoreAncestry"
    ) {
      throw invalidSwitchOptions(key);
    }
  }
  const url = switchUrl(options.url);
  const revision = switchRevision(options.revision);
  const depth = switchDepth(options.depth);
  if (typeof options.depthIsSticky !== "boolean") {
    throw invalidSwitchOptions("depthIsSticky");
  }
  if (depth === "workingCopy" && options.depthIsSticky) {
    throw invalidSwitchOptions("depthIsSticky");
  }
  if (typeof options.ignoreExternals !== "boolean") {
    throw invalidSwitchOptions("ignoreExternals");
  }
  if (typeof options.ignoreAncestry !== "boolean") {
    throw invalidSwitchOptions("ignoreAncestry");
  }
  return {
    url,
    revision,
    depth,
    depthIsSticky: options.depthIsSticky,
    ignoreExternals: options.ignoreExternals,
    ignoreAncestry: options.ignoreAncestry,
  };
}

function validateRepositoryRelocateOptions(options: RepositoryRelocateOptions, fromUrl: string): RepositoryRelocateOptions {
  if (!isRecord(options)) {
    throw invalidRelocateOptions("toUrl");
  }
  for (const key of Object.keys(options)) {
    if (key !== "toUrl" && key !== "ignoreExternals") {
      throw invalidRelocateOptions(key);
    }
  }
  const validatedFromUrl = relocateUrl(fromUrl, "fromUrl");
  const toUrl = relocateUrl(options.toUrl, "toUrl");
  if (toUrl === validatedFromUrl) {
    throw invalidRelocateOptions("toUrl");
  }
  if (typeof options.ignoreExternals !== "boolean") {
    throw invalidRelocateOptions("ignoreExternals");
  }
  return {
    toUrl,
    ignoreExternals: options.ignoreExternals,
  };
}

function validateRepositoryMergeRangeOptions(options: RepositoryMergeRangeOptions): RepositoryMergeRangeOptions {
  if (!isRecord(options)) {
    throw invalidMergeRangeOptions("sourceUrl");
  }
  for (const key of Object.keys(options)) {
    if (
      key !== "sourceUrl" &&
      key !== "targetPath" &&
      key !== "startRevision" &&
      key !== "endRevision" &&
      key !== "depth" &&
      key !== "ignoreMergeinfo" &&
      key !== "diffIgnoreAncestry" &&
      key !== "forceDelete" &&
      key !== "recordOnly" &&
      key !== "dryRun" &&
      key !== "allowMixedRevisions"
    ) {
      throw invalidMergeRangeOptions(key);
    }
  }
  const sourceUrl = mergeSourceUrl(options.sourceUrl);
  const targetPath = mergeTargetPath(options.targetPath);
  const startRevision = mergeRevision(options.startRevision, "startRevision");
  const endRevision = mergeRevision(options.endRevision, "endRevision");
  if (startRevision === endRevision) {
    throw invalidMergeRangeOptions("endRevision");
  }
  const depth = mergeDepth(options.depth);
  if (typeof options.ignoreMergeinfo !== "boolean") {
    throw invalidMergeRangeOptions("ignoreMergeinfo");
  }
  if (typeof options.diffIgnoreAncestry !== "boolean") {
    throw invalidMergeRangeOptions("diffIgnoreAncestry");
  }
  if (typeof options.forceDelete !== "boolean") {
    throw invalidMergeRangeOptions("forceDelete");
  }
  if (typeof options.recordOnly !== "boolean") {
    throw invalidMergeRangeOptions("recordOnly");
  }
  if (typeof options.dryRun !== "boolean") {
    throw invalidMergeRangeOptions("dryRun");
  }
  if (typeof options.allowMixedRevisions !== "boolean") {
    throw invalidMergeRangeOptions("allowMixedRevisions");
  }
  return {
    sourceUrl,
    targetPath,
    startRevision,
    endRevision,
    depth,
    ignoreMergeinfo: options.ignoreMergeinfo,
    diffIgnoreAncestry: options.diffIgnoreAncestry,
    forceDelete: options.forceDelete,
    recordOnly: options.recordOnly,
    dryRun: options.dryRun,
    allowMixedRevisions: options.allowMixedRevisions,
  };
}

function validateRepositoryPropertySetOptions(options: RepositoryPropertySetOptions): RepositoryPropertySetOptions {
  if (!isRecord(options)) {
    throw invalidPropertySetOptions("name");
  }
  for (const key of Object.keys(options)) {
    if (key !== "name" && key !== "value") {
      throw invalidPropertySetOptions(key);
    }
  }
  return {
    name: repositoryPropertyName(options.name, "name"),
    value: repositoryPropertyValue(options.value, "value"),
  };
}

function validateRepositoryPropertyDeleteName(name: string, properties: readonly PropertyEntry[]): string {
  const validatedName = repositoryPropertyName(name, "name");
  if (!properties.some((property) => property.name === validatedName)) {
    throw invalidPropertyDeleteName();
  }
  return validatedName;
}

function childWorkingCopySessions(
  parent: RepositorySession,
  openSessions: readonly RepositorySession[],
): RepositorySession[] {
  const root = normalizeAbsolutePath(parent.identity.workingCopyRoot);
  if (!isSafeAbsolutePath(root)) {
    return [];
  }
  const rootKey = comparisonKey(parent.watchScope.pathCase, root);
  return openSessions
    .filter((session) => session.repositoryId !== parent.repositoryId)
    .filter((session) => {
      const childRoot = normalizeAbsolutePath(session.identity.workingCopyRoot);
      if (!isSafeAbsolutePath(childRoot)) {
        return false;
      }
      const childRootKey = comparisonKey(parent.watchScope.pathCase, childRoot);
      return childRootKey.startsWith(`${rootKey}/`);
    })
    .sort((left, right) => left.repositoryId.localeCompare(right.repositoryId));
}

function updateRevision(value: unknown): UpdateOperationRevision {
  if (value === "head") {
    return value;
  }
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0 || value > MAX_SVN_REVNUM) {
    throw invalidUpdateOptions("revision");
  }
  return value;
}

function updateDepth(value: unknown): UpdateOperationDepth {
  if (value === "workingCopy" || value === "empty" || value === "files" || value === "immediates" || value === "infinity") {
    return value;
  }
  throw invalidUpdateOptions("depth");
}

function checkoutUrl(value: unknown): string {
  if (typeof value !== "string" || value.trim().length === 0 || value.includes("\0") || value.includes("\r") || value.includes("\n")) {
    throw invalidCheckoutOptions("url");
  }
  return value;
}

function checkoutTargetPath(value: unknown): string {
  if (
    typeof value !== "string" ||
    value.trim().length === 0 ||
    value.includes("\0") ||
    value.includes("\r") ||
    value.includes("\n") ||
    !isAbsoluteCheckoutTargetPath(value)
  ) {
    throw invalidCheckoutOptions("targetPath");
  }
  return value;
}

function isAbsoluteCheckoutTargetPath(value: string): boolean {
  return nodePath.isAbsolute(value) || nodePath.win32.isAbsolute(value) || nodePath.posix.isAbsolute(value);
}

function checkoutRevision(value: unknown): RepositoryCheckoutRevision {
  if (value === "head") {
    return value;
  }
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0 || value > MAX_SVN_REVNUM) {
    throw invalidCheckoutOptions("revision");
  }
  return value;
}

function checkoutDepth(value: unknown): RepositoryCheckoutDepth {
  if (value === "empty" || value === "files" || value === "immediates" || value === "infinity") {
    return value;
  }
  throw invalidCheckoutOptions("depth");
}

function branchCreateUrl(value: unknown, field: "sourceUrl" | "destinationUrl"): string {
  if (
    typeof value !== "string" ||
    value.trim().length === 0 ||
    value.includes("\0") ||
    value.includes("\r") ||
    value.includes("\n")
  ) {
    throw invalidBranchCreateOptions(field);
  }
  return value;
}

function branchCreateRevision(value: unknown): UpdateOperationRevision {
  if (value === "head") {
    return value;
  }
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0 || value > MAX_SVN_REVNUM) {
    throw invalidBranchCreateOptions("revision");
  }
  return value;
}

function branchCreateMessage(value: unknown): string {
  if (typeof value !== "string" || value.trim().length === 0 || value.includes("\0") || value.includes("\r")) {
    throw invalidBranchCreateOptions("message");
  }
  return value;
}

function switchUrl(value: unknown): string {
  if (
    typeof value !== "string" ||
    value.trim().length === 0 ||
    value.includes("\0") ||
    value.includes("\r") ||
    value.includes("\n")
  ) {
    throw invalidSwitchOptions("url");
  }
  return value;
}

function relocateUrl(value: unknown, field: "fromUrl" | "toUrl"): string {
  if (
    typeof value !== "string" ||
    value.trim().length === 0 ||
    value.includes("\0") ||
    value.includes("\r") ||
    value.includes("\n")
  ) {
    throw invalidRelocateOptions(field);
  }
  return value;
}

function switchRevision(value: unknown): UpdateOperationRevision {
  if (value === "head") {
    return value;
  }
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0 || value > MAX_SVN_REVNUM) {
    throw invalidSwitchOptions("revision");
  }
  return value;
}

function switchDepth(value: unknown): UpdateOperationDepth {
  if (value === "workingCopy" || value === "empty" || value === "files" || value === "immediates" || value === "infinity") {
    return value;
  }
  throw invalidSwitchOptions("depth");
}

function mergeSourceUrl(value: unknown): string {
  if (
    typeof value !== "string" ||
    value.trim().length === 0 ||
    value.includes("\0") ||
    value.includes("\r") ||
    value.includes("\n")
  ) {
    throw invalidMergeRangeOptions("sourceUrl");
  }
  return value;
}

function mergeTargetPath(value: unknown): string {
  if (typeof value !== "string" || !isRepositoryRelativePath(value)) {
    throw invalidMergeRangeOptions("targetPath");
  }
  return value;
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

function mergeRevision(value: unknown, field: "startRevision" | "endRevision"): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0 || value > MAX_SVN_REVNUM) {
    throw invalidMergeRangeOptions(field);
  }
  return value;
}

function repositoryPropertyName(value: unknown, field: string): string {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    value.includes("\0") ||
    value.includes("\r") ||
    value.includes("\n")
  ) {
    throw invalidPropertySetOptions(field);
  }
  return value;
}

function repositoryPropertyValue(value: unknown, field: string): string {
  if (typeof value !== "string" || value.includes("\0") || value.includes("\r")) {
    throw invalidPropertySetOptions(field);
  }
  return value;
}

function mergeDepth(value: unknown): MergeRangeOperationRequest["depth"] {
  if (value === "empty" || value === "files" || value === "immediates" || value === "infinity") {
    return value;
  }
  throw invalidMergeRangeOptions("depth");
}

function commitPathSummary(paths: readonly string[]): string {
  return paths.join(", ");
}

const UPDATE_CONFLICT_PATH_DISPLAY_LIMIT = 3;

function updateConflictPaths(
  session: Pick<RepositorySession, "repositoryId" | "epoch" | "watchScope">,
  updatedPaths: readonly string[],
  projectionService: Pick<SourceControlProjectionService, "getProjection">,
): string[] {
  const projection = projectionService.getProjection(session.repositoryId);
  if (!projection) {
    throw updateConflictStateUnavailable(session.repositoryId);
  }
  if (projection.repositoryId !== session.repositoryId || projection.epoch !== session.epoch) {
    throw updateConflictStateStale(session.repositoryId, session.epoch, projection.epoch);
  }
  const conflictGroup = projection.groups.find((group) => group.id === "conflicts");
  if (!conflictGroup) {
    throw updateConflictStateUnavailable(session.repositoryId);
  }
  return Array.from(
    new Set(
      conflictGroup.resources
        .filter(
          (resource) =>
            resource.source === "local" &&
            updatedPaths.some((updatedPath) =>
              repositoryPathContains(updatedPath, resource.path, session.watchScope.pathCase),
            ),
        )
        .map((resource) => resource.path),
    ),
  ).sort((left, right) => left.localeCompare(right, "en-US"));
}

function repositoryPathContains(parent: string, candidate: string, pathCase: PathCasePolicy): boolean {
  if (parent === ".") {
    return true;
  }
  const parentKey = comparisonKey(pathCase, parent);
  const candidateKey = comparisonKey(pathCase, candidate);
  return candidateKey === parentKey || candidateKey.startsWith(`${parentKey}/`);
}

function updateConflictPathSummary(
  paths: readonly string[],
  localize: (message: string, ...args: unknown[]) => string,
): string {
  const visiblePaths = paths.slice(0, UPDATE_CONFLICT_PATH_DISPLAY_LIMIT);
  const hiddenCount = paths.length - visiblePaths.length;
  const summary = visiblePaths.join(", ");
  return hiddenCount === 0 ? summary : localize("{0} (+{1} more)", summary, hiddenCount);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function invalidResourceRefreshTarget(): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_RESOURCE_REFRESH_TARGET_INVALID",
    "input",
    "error.repository.resourceRefreshTargetInvalid",
  );
}

function invalidResourceRefreshTargetOutsideRepository(fsPath: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_RESOURCE_REFRESH_TARGET_OUTSIDE_REPOSITORY",
    "input",
    "error.repository.resourceRefreshTargetOutsideRepository",
    { fsPath },
  );
}

function invalidResourceRevertTarget(): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_RESOURCE_REVERT_TARGET_INVALID",
    "input",
    "error.repository.resourceRevertTargetInvalid",
  );
}

function invalidResourceRevertTargetOutsideRepository(fsPath: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_RESOURCE_REVERT_TARGET_OUTSIDE_REPOSITORY",
    "input",
    "error.repository.resourceRevertTargetOutsideRepository",
    { fsPath },
  );
}

function invalidResourceAddTarget(): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_RESOURCE_ADD_TARGET_INVALID",
    "input",
    "error.repository.resourceAddTargetInvalid",
  );
}

function invalidResourceAddTargetOutsideRepository(fsPath: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_RESOURCE_ADD_TARGET_OUTSIDE_REPOSITORY",
    "input",
    "error.repository.resourceAddTargetOutsideRepository",
    { fsPath },
  );
}

function invalidResourceAddToIgnoreTarget(): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_RESOURCE_ADD_TO_IGNORE_TARGET_INVALID",
    "input",
    "error.repository.resourceAddToIgnoreTargetInvalid",
  );
}

function invalidResourceAddToIgnoreTargetOutsideRepository(fsPath: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_RESOURCE_ADD_TO_IGNORE_TARGET_OUTSIDE_REPOSITORY",
    "input",
    "error.repository.resourceAddToIgnoreTargetOutsideRepository",
    { fsPath },
  );
}

function invalidResourceRemoveFromIgnoreTarget(): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_RESOURCE_REMOVE_FROM_IGNORE_TARGET_INVALID",
    "input",
    "error.repository.resourceRemoveFromIgnoreTargetInvalid",
  );
}

function invalidResourceRemoveFromIgnoreTargetOutsideRepository(fsPath: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_RESOURCE_REMOVE_FROM_IGNORE_TARGET_OUTSIDE_REPOSITORY",
    "input",
    "error.repository.resourceRemoveFromIgnoreTargetOutsideRepository",
    { fsPath },
  );
}

function invalidResourceChangelistTarget(): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_RESOURCE_CHANGELIST_TARGET_INVALID",
    "input",
    "error.repository.resourceChangelistTargetInvalid",
  );
}

function invalidResourceChangelistTargetOutsideRepository(fsPath: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_RESOURCE_CHANGELIST_TARGET_OUTSIDE_REPOSITORY",
    "input",
    "error.repository.resourceChangelistTargetOutsideRepository",
    { fsPath },
  );
}

function invalidResourceLockTarget(): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_RESOURCE_LOCK_TARGET_INVALID",
    "input",
    "error.repository.resourceLockTargetInvalid",
  );
}

function invalidResourceLockTargetOutsideRepository(fsPath: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_RESOURCE_LOCK_TARGET_OUTSIDE_REPOSITORY",
    "input",
    "error.repository.resourceLockTargetOutsideRepository",
    { fsPath },
  );
}

function invalidResourceUnlockTarget(): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_RESOURCE_UNLOCK_TARGET_INVALID",
    "input",
    "error.repository.resourceUnlockTargetInvalid",
  );
}

function invalidResourceUnlockTargetOutsideRepository(fsPath: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_RESOURCE_UNLOCK_TARGET_OUTSIDE_REPOSITORY",
    "input",
    "error.repository.resourceUnlockTargetOutsideRepository",
    { fsPath },
  );
}

function invalidChangelistName(): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_CHANGELIST_NAME_INVALID",
    "input",
    "error.repository.changelistNameInvalid",
  );
}

function invalidChangelistGroupTarget(): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_CHANGELIST_GROUP_TARGET_INVALID",
    "input",
    "error.repository.changelistGroupTargetInvalid",
  );
}

function changelistGroupRepositoryNotOpen(repositoryId: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_CHANGELIST_GROUP_REPOSITORY_NOT_OPEN",
    "lifecycle",
    "error.repository.changelistGroupRepositoryNotOpen",
    { repositoryId },
  );
}

function changelistGroupStateUnavailable(repositoryId: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_CHANGELIST_GROUP_STATE_UNAVAILABLE",
    "lifecycle",
    "error.repository.changelistGroupStateUnavailable",
    { repositoryId },
  );
}

function changelistGroupStateStale(repositoryId: string, expectedEpoch: number, actualEpoch: number): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_CHANGELIST_GROUP_STATE_STALE",
    "lifecycle",
    "error.repository.changelistGroupStateStale",
    { repositoryId, expectedEpoch, actualEpoch },
  );
}

function invalidResourceDeleteUnversionedTarget(): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_RESOURCE_DELETE_UNVERSIONED_TARGET_INVALID",
    "input",
    "error.repository.resourceDeleteUnversionedTargetInvalid",
  );
}

function invalidResourceDeleteUnversionedTargetOutsideRepository(fsPath: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_RESOURCE_DELETE_UNVERSIONED_TARGET_OUTSIDE_REPOSITORY",
    "input",
    "error.repository.resourceDeleteUnversionedTargetOutsideRepository",
    { fsPath },
  );
}

function invalidResourceDeleteUnversionedRepositoryNotOpen(repositoryId: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_RESOURCE_DELETE_UNVERSIONED_REPOSITORY_NOT_OPEN",
    "lifecycle",
    "error.repository.resourceDeleteUnversionedRepositoryNotOpen",
    { repositoryId },
  );
}

function invalidResourceCommitTarget(): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_RESOURCE_COMMIT_TARGET_INVALID",
    "input",
    "error.repository.resourceCommitTargetInvalid",
  );
}

function invalidResourceCommitTargetOutsideRepository(fsPath: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_RESOURCE_COMMIT_TARGET_OUTSIDE_REPOSITORY",
    "input",
    "error.repository.resourceCommitTargetOutsideRepository",
    { fsPath },
  );
}

function invalidResourceCommitMessage(): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_RESOURCE_COMMIT_MESSAGE_INVALID",
    "input",
    "error.repository.resourceCommitMessageInvalid",
  );
}

function invalidResourceCommitRevision(): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_RESOURCE_COMMIT_REVISION_MISSING",
    "lifecycle",
    "error.repository.resourceCommitRevisionMissing",
  );
}

function commitAllRepositoryIdInvalid(): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_COMMIT_ALL_REPOSITORY_ID_INVALID",
    "input",
    "error.repository.commitAllRepositoryIdInvalid",
  );
}

function commitAllRepositoryNotOpen(repositoryId: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_COMMIT_ALL_REPOSITORY_NOT_OPEN",
    "lifecycle",
    "error.repository.commitAllRepositoryNotOpen",
    { repositoryId },
  );
}

function pickCommitMessageHistoryRepositoryIdInvalid(): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_COMMIT_MESSAGE_HISTORY_REPOSITORY_ID_INVALID",
    "input",
    "error.repository.commitMessageHistoryRepositoryIdInvalid",
  );
}

function pickCommitMessageHistoryRepositoryNotOpen(repositoryId: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_COMMIT_MESSAGE_HISTORY_REPOSITORY_NOT_OPEN",
    "lifecycle",
    "error.repository.commitMessageHistoryRepositoryNotOpen",
    { repositoryId },
  );
}

function closeRepositoryIdInvalid(): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_CLOSE_REPOSITORY_ID_INVALID",
    "input",
    "error.repository.closeRepositoryIdInvalid",
  );
}

function closeRepositoryNotOpen(repositoryId: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_CLOSE_REPOSITORY_NOT_OPEN",
    "lifecycle",
    "error.repository.closeRepositoryNotOpen",
    { repositoryId },
  );
}

function fullReconcileRepositoryIdInvalid(): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_FULL_RECONCILE_REPOSITORY_ID_INVALID",
    "input",
    "error.repository.fullReconcileRepositoryIdInvalid",
  );
}

function fullReconcileRepositoryNotOpen(repositoryId: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_FULL_RECONCILE_REPOSITORY_NOT_OPEN",
    "lifecycle",
    "error.repository.fullReconcileRepositoryNotOpen",
    { repositoryId },
  );
}

function refreshRepositoryIdInvalid(): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_REFRESH_REPOSITORY_ID_INVALID",
    "input",
    "error.repository.refreshRepositoryIdInvalid",
  );
}

function refreshRepositoryNotOpen(repositoryId: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_REFRESH_REPOSITORY_NOT_OPEN",
    "lifecycle",
    "error.repository.refreshRepositoryNotOpen",
    { repositoryId },
  );
}

function checkRemoteChangesRepositoryIdInvalid(): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_CHECK_REMOTE_CHANGES_REPOSITORY_ID_INVALID",
    "input",
    "error.repository.checkRemoteChangesRepositoryIdInvalid",
  );
}

function checkRemoteChangesRepositoryNotOpen(repositoryId: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_CHECK_REMOTE_CHANGES_REPOSITORY_NOT_OPEN",
    "lifecycle",
    "error.repository.checkRemoteChangesRepositoryNotOpen",
    { repositoryId },
  );
}

function cleanupRepositoryIdInvalid(): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_CLEANUP_REPOSITORY_ID_INVALID",
    "input",
    "error.repository.cleanupRepositoryIdInvalid",
  );
}

function cleanupRepositoryNotOpen(repositoryId: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_CLEANUP_REPOSITORY_NOT_OPEN",
    "lifecycle",
    "error.repository.cleanupRepositoryNotOpen",
    { repositoryId },
  );
}

function upgradeWorkingCopyRepositoryIdInvalid(): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_UPGRADE_WORKING_COPY_REPOSITORY_ID_INVALID",
    "input",
    "error.repository.upgradeWorkingCopyRepositoryIdInvalid",
  );
}

function upgradeWorkingCopyRepositoryNotOpen(repositoryId: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_UPGRADE_WORKING_COPY_REPOSITORY_NOT_OPEN",
    "lifecycle",
    "error.repository.upgradeWorkingCopyRepositoryNotOpen",
    { repositoryId },
  );
}

function updateRepositoryIdInvalid(): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_UPDATE_REPOSITORY_ID_INVALID",
    "input",
    "error.repository.updateRepositoryIdInvalid",
  );
}

function updateRepositoryNotOpen(repositoryId: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_UPDATE_REPOSITORY_NOT_OPEN",
    "lifecycle",
    "error.repository.updateRepositoryNotOpen",
    { repositoryId },
  );
}

function updateToRevisionRepositoryIdInvalid(): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_UPDATE_TO_REVISION_REPOSITORY_ID_INVALID",
    "input",
    "error.repository.updateToRevisionRepositoryIdInvalid",
  );
}

function updateToRevisionRepositoryNotOpen(repositoryId: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_UPDATE_TO_REVISION_REPOSITORY_NOT_OPEN",
    "lifecycle",
    "error.repository.updateToRevisionRepositoryNotOpen",
    { repositoryId },
  );
}

function branchCreateRepositoryIdInvalid(): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_BRANCH_CREATE_REPOSITORY_ID_INVALID",
    "input",
    "error.repository.branchCreateRepositoryIdInvalid",
  );
}

function branchCreateRepositoryNotOpen(repositoryId: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_BRANCH_CREATE_REPOSITORY_NOT_OPEN",
    "lifecycle",
    "error.repository.branchCreateRepositoryNotOpen",
    { repositoryId },
  );
}

function switchRepositoryIdInvalid(): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_SWITCH_REPOSITORY_ID_INVALID",
    "input",
    "error.repository.switchRepositoryIdInvalid",
  );
}

function switchRepositoryNotOpen(repositoryId: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_SWITCH_REPOSITORY_NOT_OPEN",
    "lifecycle",
    "error.repository.switchRepositoryNotOpen",
    { repositoryId },
  );
}

function relocateRepositoryIdInvalid(): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_RELOCATE_REPOSITORY_ID_INVALID",
    "input",
    "error.repository.relocateRepositoryIdInvalid",
  );
}

function relocateRepositoryNotOpen(repositoryId: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_RELOCATE_REPOSITORY_NOT_OPEN",
    "lifecycle",
    "error.repository.relocateRepositoryNotOpen",
    { repositoryId },
  );
}

function mergeRangeRepositoryIdInvalid(): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_MERGE_RANGE_REPOSITORY_ID_INVALID",
    "input",
    "error.repository.mergeRangeRepositoryIdInvalid",
  );
}

function mergeRangeRepositoryNotOpen(repositoryId: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_MERGE_RANGE_REPOSITORY_NOT_OPEN",
    "lifecycle",
    "error.repository.mergeRangeRepositoryNotOpen",
    { repositoryId },
  );
}

function previewMergeRangeRepositoryIdInvalid(): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_PREVIEW_MERGE_RANGE_REPOSITORY_ID_INVALID",
    "input",
    "error.repository.previewMergeRangeRepositoryIdInvalid",
  );
}

function previewMergeRangeRepositoryNotOpen(repositoryId: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_PREVIEW_MERGE_RANGE_REPOSITORY_NOT_OPEN",
    "lifecycle",
    "error.repository.previewMergeRangeRepositoryNotOpen",
    { repositoryId },
  );
}

function repositoryMergeinfoRepositoryIdInvalid(): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_REPOSITORY_MERGEINFO_REPOSITORY_ID_INVALID",
    "input",
    "error.repository.repositoryMergeinfoRepositoryIdInvalid",
  );
}

function repositoryMergeinfoRepositoryNotOpen(repositoryId: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_REPOSITORY_MERGEINFO_REPOSITORY_NOT_OPEN",
    "lifecycle",
    "error.repository.repositoryMergeinfoRepositoryNotOpen",
    { repositoryId },
  );
}

function repositoryPropertiesRepositoryIdInvalid(): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_REPOSITORY_PROPERTIES_REPOSITORY_ID_INVALID",
    "input",
    "error.repository.repositoryPropertiesRepositoryIdInvalid",
  );
}

function repositoryPropertiesRepositoryNotOpen(repositoryId: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_REPOSITORY_PROPERTIES_REPOSITORY_NOT_OPEN",
    "lifecycle",
    "error.repository.repositoryPropertiesRepositoryNotOpen",
    { repositoryId },
  );
}

function commitAllStateUnavailable(repositoryId: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_COMMIT_ALL_STATE_UNAVAILABLE",
    "lifecycle",
    "error.repository.commitAllStateUnavailable",
    { repositoryId },
  );
}

function commitAllStateStale(repositoryId: string, expectedEpoch: number, actualEpoch: number): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_COMMIT_ALL_STATE_STALE",
    "lifecycle",
    "error.repository.commitAllStateStale",
    { repositoryId, expectedEpoch, actualEpoch },
  );
}

function updateConflictStateUnavailable(repositoryId: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_UPDATE_CONFLICT_STATE_UNAVAILABLE",
    "lifecycle",
    "error.repository.updateConflictStateUnavailable",
    { repositoryId },
  );
}

function updateConflictStateStale(
  repositoryId: string,
  expectedEpoch: number,
  actualEpoch: number,
): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_UPDATE_CONFLICT_STATE_STALE",
    "lifecycle",
    "error.repository.updateConflictStateStale",
    { repositoryId, expectedEpoch, actualEpoch },
  );
}

function commitAllConflictsPresent(): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_COMMIT_ALL_CONFLICTS_PRESENT",
    "lifecycle",
    "error.repository.commitAllConflictsPresent",
  );
}

function commitAllTargetsInvalid(): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_COMMIT_ALL_TARGETS_INVALID",
    "input",
    "error.repository.commitAllTargetsInvalid",
  );
}

function invalidResourceRemoveTarget(): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_RESOURCE_REMOVE_TARGET_INVALID",
    "input",
    "error.repository.resourceRemoveTargetInvalid",
  );
}

function invalidResourceRemoveTargetOutsideRepository(fsPath: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_RESOURCE_REMOVE_TARGET_OUTSIDE_REPOSITORY",
    "input",
    "error.repository.resourceRemoveTargetOutsideRepository",
    { fsPath },
  );
}

function invalidResourceMoveTarget(): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_RESOURCE_MOVE_TARGET_INVALID",
    "input",
    "error.repository.resourceMoveTargetInvalid",
  );
}

function invalidResourceMoveTargetOutsideRepository(fsPath: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_RESOURCE_MOVE_TARGET_OUTSIDE_REPOSITORY",
    "input",
    "error.repository.resourceMoveTargetOutsideRepository",
    { fsPath },
  );
}

function invalidResourceMoveDestination(destinationPath: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_RESOURCE_MOVE_DESTINATION_INVALID",
    "input",
    "error.repository.resourceMoveDestinationInvalid",
    { destinationPath },
  );
}

function invalidResourceResolveTarget(): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_RESOURCE_RESOLVE_TARGET_INVALID",
    "input",
    "error.repository.resourceResolveTargetInvalid",
  );
}

function invalidResourceResolveTargetOutsideRepository(fsPath: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_RESOURCE_RESOLVE_TARGET_OUTSIDE_REPOSITORY",
    "input",
    "error.repository.resourceResolveTargetOutsideRepository",
    { fsPath },
  );
}

function invalidResourceUpdateTarget(): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_RESOURCE_UPDATE_TARGET_INVALID",
    "input",
    "error.repository.resourceUpdateTargetInvalid",
  );
}

function invalidResourceUpdateTargetOutsideRepository(fsPath: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_RESOURCE_UPDATE_TARGET_OUTSIDE_REPOSITORY",
    "input",
    "error.repository.resourceUpdateTargetOutsideRepository",
    { fsPath },
  );
}

function invalidResourceMergeinfoTarget(): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_RESOURCE_MERGEINFO_TARGET_INVALID",
    "input",
    "error.repository.resourceMergeinfoTargetInvalid",
  );
}

function invalidResourceMergeinfoTargetOutsideRepository(fsPath: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_RESOURCE_MERGEINFO_TARGET_OUTSIDE_REPOSITORY",
    "input",
    "error.repository.resourceMergeinfoTargetOutsideRepository",
    { fsPath },
  );
}

function invalidResourcePropertiesTarget(): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_RESOURCE_PROPERTIES_TARGET_INVALID",
    "input",
    "error.repository.resourcePropertiesTargetInvalid",
  );
}

function invalidResourcePropertiesTargetOutsideRepository(fsPath: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_RESOURCE_PROPERTIES_TARGET_OUTSIDE_REPOSITORY",
    "input",
    "error.repository.resourcePropertiesTargetOutsideRepository",
    { fsPath },
  );
}

function invalidUpdateOptions(field: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_UPDATE_OPTIONS_INVALID",
    "input",
    "error.repository.updateOptionsInvalid",
    { field },
  );
}

function invalidCheckoutOptions(field: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_CHECKOUT_OPTIONS_INVALID",
    "input",
    "error.repository.checkoutOptionsInvalid",
    { field },
  );
}

function invalidCleanupOptions(field: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_CLEANUP_OPTIONS_INVALID",
    "input",
    "error.repository.cleanupOptionsInvalid",
    { field },
  );
}

function invalidBranchCreateOptions(field: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_BRANCH_CREATE_OPTIONS_INVALID",
    "input",
    "error.repository.branchCreateOptionsInvalid",
    { field },
  );
}

function invalidSwitchOptions(field: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_SWITCH_OPTIONS_INVALID",
    "input",
    "error.repository.switchOptionsInvalid",
    { field },
  );
}

function invalidRelocateOptions(field: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_RELOCATE_OPTIONS_INVALID",
    "input",
    "error.repository.relocateOptionsInvalid",
    { field },
  );
}

function invalidMergeRangeOptions(field: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_MERGE_RANGE_OPTIONS_INVALID",
    "input",
    "error.repository.mergeRangeOptionsInvalid",
    { field },
  );
}

function invalidPropertySetOptions(field: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_PROPERTY_SET_OPTIONS_INVALID",
    "input",
    "error.repository.propertySetOptionsInvalid",
    { field },
  );
}

function invalidPropertyDeleteName(): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_PROPERTY_DELETE_NAME_INVALID",
    "input",
    "error.repository.propertyDeleteNameInvalid",
  );
}

function invalidDiffBaseTarget(): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_DIFF_BASE_TARGET_INVALID",
    "input",
    "error.repository.diffBaseTargetInvalid",
  );
}

function invalidDiffBaseTargetOutsideRepository(fsPath: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_DIFF_BASE_TARGET_OUTSIDE_REPOSITORY",
    "input",
    "error.repository.diffBaseTargetOutsideRepository",
    { fsPath },
  );
}

function diffBaseStateUnavailable(repositoryId: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_DIFF_BASE_STATE_UNAVAILABLE",
    "lifecycle",
    "error.repository.diffBaseStateUnavailable",
    { repositoryId },
  );
}

function diffBaseStateStale(repositoryId: string, expectedEpoch: number, actualEpoch: number): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_DIFF_BASE_STATE_STALE",
    "lifecycle",
    "error.repository.diffBaseStateStale",
    { repositoryId, expectedEpoch, actualEpoch },
  );
}

function invalidOpenBaseTarget(): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_OPEN_BASE_TARGET_INVALID",
    "input",
    "error.repository.openBaseTargetInvalid",
  );
}

function invalidOpenBaseTargetOutsideRepository(fsPath: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_OPEN_BASE_TARGET_OUTSIDE_REPOSITORY",
    "input",
    "error.repository.openBaseTargetOutsideRepository",
    { fsPath },
  );
}

function openBaseStateUnavailable(repositoryId: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_OPEN_BASE_STATE_UNAVAILABLE",
    "lifecycle",
    "error.repository.openBaseStateUnavailable",
    { repositoryId },
  );
}

function openBaseStateStale(repositoryId: string, expectedEpoch: number, actualEpoch: number): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_OPEN_BASE_STATE_STALE",
    "lifecycle",
    "error.repository.openBaseStateStale",
    { repositoryId, expectedEpoch, actualEpoch },
  );
}

function invalidDiffHeadTarget(): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_DIFF_HEAD_TARGET_INVALID",
    "input",
    "error.repository.diffHeadTargetInvalid",
  );
}

function invalidDiffHeadTargetOutsideRepository(fsPath: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_DIFF_HEAD_TARGET_OUTSIDE_REPOSITORY",
    "input",
    "error.repository.diffHeadTargetOutsideRepository",
    { fsPath },
  );
}

function diffHeadStateUnavailable(repositoryId: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_DIFF_HEAD_STATE_UNAVAILABLE",
    "lifecycle",
    "error.repository.diffHeadStateUnavailable",
    { repositoryId },
  );
}

function diffHeadStateStale(repositoryId: string, expectedEpoch: number, actualEpoch: number): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_DIFF_HEAD_STATE_STALE",
    "lifecycle",
    "error.repository.diffHeadStateStale",
    { repositoryId, expectedEpoch, actualEpoch },
  );
}

function invalidOpenHeadTarget(): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_OPEN_HEAD_TARGET_INVALID",
    "input",
    "error.repository.openHeadTargetInvalid",
  );
}

function invalidOpenHeadTargetOutsideRepository(fsPath: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_OPEN_HEAD_TARGET_OUTSIDE_REPOSITORY",
    "input",
    "error.repository.openHeadTargetOutsideRepository",
    { fsPath },
  );
}

function openHeadStateUnavailable(repositoryId: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_OPEN_HEAD_STATE_UNAVAILABLE",
    "lifecycle",
    "error.repository.openHeadStateUnavailable",
    { repositoryId },
  );
}

function openHeadStateStale(repositoryId: string, expectedEpoch: number, actualEpoch: number): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_OPEN_HEAD_STATE_STALE",
    "lifecycle",
    "error.repository.openHeadStateStale",
    { repositoryId, expectedEpoch, actualEpoch },
  );
}

function invalidDiffPreviousTarget(): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_DIFF_PREVIOUS_TARGET_INVALID",
    "input",
    "error.repository.diffPreviousTargetInvalid",
  );
}

function invalidDiffPreviousTargetOutsideRepository(fsPath: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_DIFF_PREVIOUS_TARGET_OUTSIDE_REPOSITORY",
    "input",
    "error.repository.diffPreviousTargetOutsideRepository",
    { fsPath },
  );
}

function diffPreviousStateUnavailable(repositoryId: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_DIFF_PREVIOUS_STATE_UNAVAILABLE",
    "lifecycle",
    "error.repository.diffPreviousStateUnavailable",
    { repositoryId },
  );
}

function diffPreviousStateStale(repositoryId: string, expectedEpoch: number, actualEpoch: number): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_DIFF_PREVIOUS_STATE_STALE",
    "lifecycle",
    "error.repository.diffPreviousStateStale",
    { repositoryId, expectedEpoch, actualEpoch },
  );
}

function diffPreviousGenerationStale(
  repositoryId: string,
  expectedGeneration: number,
  actualGeneration: number,
): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_DIFF_PREVIOUS_STATE_STALE",
    "lifecycle",
    "error.repository.diffPreviousStateStale",
    { repositoryId, expectedGeneration, actualGeneration },
  );
}

function diffPreviousNoPreviousRevision(path: string, revision: number): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_DIFF_PREVIOUS_NO_PREVIOUS_REVISION",
    "lifecycle",
    "error.repository.diffPreviousNoPreviousRevision",
    { path, revision },
  );
}

function historyRepositoryIdInvalid(): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_HISTORY_REPOSITORY_ID_INVALID",
    "input",
    "error.repository.historyRepositoryIdInvalid",
  );
}

function historyRepositoryNotOpen(repositoryId: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_HISTORY_REPOSITORY_NOT_OPEN",
    "lifecycle",
    "error.repository.historyRepositoryNotOpen",
    { repositoryId },
  );
}

function historyRepositorySessionStale(
  repositoryId: string,
  expectedEpoch: number,
  actualEpoch?: number,
): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_HISTORY_REPOSITORY_SESSION_STALE",
    "lifecycle",
    "error.repository.historyRepositorySessionStale",
    actualEpoch === undefined
      ? { repositoryId, expectedEpoch }
      : { repositoryId, expectedEpoch, actualEpoch },
  );
}

function invalidHistoryFileTarget(): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_HISTORY_FILE_TARGET_INVALID",
    "input",
    "error.repository.historyFileTargetInvalid",
  );
}

function invalidHistoryFileTargetOutsideRepository(fsPath: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_HISTORY_FILE_TARGET_OUTSIDE_REPOSITORY",
    "input",
    "error.repository.historyFileTargetOutsideRepository",
    { fsPath },
  );
}

function historyFileStateUnavailable(repositoryId: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_HISTORY_FILE_STATE_UNAVAILABLE",
    "lifecycle",
    "error.repository.historyFileStateUnavailable",
    { repositoryId },
  );
}

function historyFileStateStale(repositoryId: string, expectedEpoch: number, actualEpoch: number): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_HISTORY_FILE_STATE_STALE",
    "lifecycle",
    "error.repository.historyFileStateStale",
    { repositoryId, expectedEpoch, actualEpoch },
  );
}

function invalidBlameFileTarget(): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_BLAME_FILE_TARGET_INVALID",
    "input",
    "error.repository.blameFileTargetInvalid",
  );
}

function invalidBlameFileTargetOutsideRepository(fsPath: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_BLAME_FILE_TARGET_OUTSIDE_REPOSITORY",
    "input",
    "error.repository.blameFileTargetOutsideRepository",
    { fsPath },
  );
}

function blameFileStateUnavailable(repositoryId: string): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_BLAME_FILE_STATE_UNAVAILABLE",
    "lifecycle",
    "error.repository.blameFileStateUnavailable",
    { repositoryId },
  );
}

function blameFileStateStale(repositoryId: string, expectedEpoch: number, actualEpoch: number): RepositoryCommandError {
  return repositoryCommandError(
    "SUBVERSIONR_BLAME_FILE_STATE_STALE",
    "lifecycle",
    "error.repository.blameFileStateStale",
    { repositoryId, expectedEpoch, actualEpoch },
  );
}

function repositoryCommandError(
  code: string,
  category: RepositoryCommandErrorCategory,
  messageKey: string,
  safeArgs: Record<string, unknown> = {},
): RepositoryCommandError {
  return new RepositoryCommandError(code, category, messageKey, safeArgs);
}

function toRefreshTarget(target: RepositoryCommandResourceTarget): RepositoryResourceRefreshTarget {
  return {
    repositoryId: target.repositoryId,
    epoch: target.epoch,
    path: target.path,
  };
}
