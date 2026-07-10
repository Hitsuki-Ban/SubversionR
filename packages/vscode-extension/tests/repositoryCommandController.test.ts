import { describe, expect, it, vi } from "vitest";
import {
  RepositoryCommandController,
  type RepositoryCommandUi,
} from "../src/repository/repositoryCommandController";
import { RepositoryCommitMessageHistory } from "../src/repository/repositoryCommitMessageHistory";
import type {
  RepositoryDiscoveryCandidate,
  RepositoryDiscoveryResponse,
  RepositoryDiscoveryService,
} from "../src/repository/repositoryDiscoveryService";
import type { RepositorySession, RepositorySessionService } from "../src/repository/repositorySessionService";
import type { RepositoryRefreshService } from "../src/status/repositoryRefreshService";
import type { PathCasePolicy } from "../src/status/types";
import type { OperationClient, OperationRunResponse } from "../src/operations/operationRunRpcClient";
import type { PropertiesClient, PropertiesListResponse, PropertyEntry } from "../src/properties/propertiesListRpcClient";
import type {
  RepositoryCheckoutClient,
  RepositoryCheckoutResponse,
} from "../src/repository/repositoryCheckoutRpcClient";
import { RepositoryOperationJournal } from "../src/operations/repositoryOperationJournal";
import { RepositoryOperationScheduler } from "../src/operations/repositoryOperationScheduler";
import type { HistoryClient, HistoryLog } from "../src/history/historyLogRpcClient";
import type { HistoryViewTarget } from "../src/history/historyViewTarget";
import type { HistoryBlameViewTarget } from "../src/history/historyBlameViewTarget";
import type { SourceControlProjectionService } from "../src/scm/sourceControlProjectionService";
import type {
  ScmCommitAllTarget,
  ScmCommitAllTargets,
  ScmProjectedResource,
  ScmRepositoryProjection,
} from "../src/scm/sourceControlResourceStore";
import type { StatusEntry } from "../src/status/statusSnapshotRpcClient";

describe("RepositoryCommandController", () => {
  it("discovers workspace roots and opens a single discovered working copy", async () => {
    const candidate = discoveryCandidate({ workingCopyRoot: "C:\\workspace" });
    const discoveryService = fakeDiscoveryService({ candidates: [candidate] });
    const sessionService = fakeSessionService();
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(discoveryService, sessionService, ui);

    await controller.openRepository();

    expect(discoveryService.discoverRepositories).toHaveBeenCalledWith({
      workspaceRoots: ["C:\\workspace"],
      discoverNested: true,
      discoveryDepth: 4,
      discoveryIgnore: [],
      ignoredRoots: [],
      externalsMode: "lazy",
    });
    expect(ui.pickRepositoryCandidate).not.toHaveBeenCalled();
    expect(discoveryService.openDiscoveredRepository).toHaveBeenCalledWith({
      candidate,
      pathCase: "case-insensitive",
    });
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR opened SVN working copy: C:\\workspace",
    );
  });

  it("checks out a repository URL and opens the resulting working copy through repository lifecycle", async () => {
    const sessionService = fakeSessionService({
      openedSession: repositorySession({ workingCopyRoot: "C:/workspace/project" }),
    });
    const checkoutClient = fakeCheckoutClient({
      workingCopyPath: "C:/workspace/project",
      revision: 42,
    });
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace"],
      checkoutOptions: {
        url: "https://svn.example.invalid/project/trunk",
        targetPath: "C:/workspace/project",
        revision: 42,
        depth: "files",
        ignoreExternals: false,
      },
    });
    const controller = commandController(
      fakeDiscoveryService({ candidates: [] }),
      sessionService,
      ui,
      { checkoutClient },
    );

    await controller.checkoutRepository();

    expect(ui.workspaceTrusted).toHaveBeenCalledTimes(1);
    expect(ui.promptCheckoutOptions).toHaveBeenCalledTimes(1);
    expect(ui.pathCasePolicy).toHaveBeenCalledTimes(1);
    expect(ui.runOperationWithProgress).toHaveBeenCalledWith(
      "Checking out SVN working copy",
      expect.any(Function),
    );
    expect(checkoutClient.checkout).toHaveBeenCalledWith({
      url: "https://svn.example.invalid/project/trunk",
      targetPath: "C:/workspace/project",
      revision: 42,
      depth: "files",
      ignoreExternals: false,
    });
    expect(sessionService.openWorkingCopy).toHaveBeenCalledWith({
      path: "C:/workspace/project",
      pathCase: "case-insensitive",
    });
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR checked out SVN working copy at revision 42: C:/workspace/project",
    );
  });

  it("does not run checkout or open a working copy when checkout prompts are cancelled", async () => {
    const sessionService = fakeSessionService();
    const checkoutClient = fakeCheckoutClient();
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"], checkoutOptions: undefined });
    const controller = commandController(
      fakeDiscoveryService({ candidates: [] }),
      sessionService,
      ui,
      { checkoutClient },
    );

    await controller.checkoutRepository();

    expect(checkoutClient.checkout).not.toHaveBeenCalled();
    expect(sessionService.openWorkingCopy).not.toHaveBeenCalled();
    expect(ui.showInformationMessage).not.toHaveBeenCalled();
  });

  it("does not open a working copy when checkout fails in the backend", async () => {
    const sessionService = fakeSessionService();
    const checkoutClient = fakeCheckoutClient();
    checkoutClient.checkout.mockRejectedValueOnce({
      code: "SVN_REPOSITORY_CHECKOUT_FAILED",
      category: "native",
      messageKey: "error.native.repositoryCheckoutFailed",
    });
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace"],
      checkoutOptions: {
        url: "file:///missing/repo/trunk",
        targetPath: "C:/workspace/project",
        revision: "head",
        depth: "infinity",
        ignoreExternals: true,
      },
    });
    const controller = commandController(
      fakeDiscoveryService({ candidates: [] }),
      sessionService,
      ui,
      { checkoutClient },
    );

    await controller.checkoutRepository();

    expect(checkoutClient.checkout).toHaveBeenCalledWith({
      url: "file:///missing/repo/trunk",
      targetPath: "C:/workspace/project",
      revision: "head",
      depth: "infinity",
      ignoreExternals: true,
    });
    expect(sessionService.openWorkingCopy).not.toHaveBeenCalled();
    expect(ui.showInformationMessage).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SVN_REPOSITORY_CHECKOUT_FAILED",
    );
  });

  it("passes open working copy roots as discovery ignored roots", async () => {
    const candidate = discoveryCandidate({ workingCopyRoot: "D:\\other-wc" });
    const discoveryService = fakeDiscoveryService({ candidates: [candidate] });
    const sessionService = fakeSessionService({
      sessions: [
        repositorySession({
          repositoryId: "repo-uuid:C:/workspace",
          workingCopyRoot: "C:\\workspace",
        }),
      ],
    });
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace", "D:\\other-wc"] });
    const controller = commandController(discoveryService, sessionService, ui);

    await controller.openRepository();

    expect(discoveryService.discoverRepositories).toHaveBeenCalledWith({
      workspaceRoots: ["C:\\workspace", "D:\\other-wc"],
      discoverNested: true,
      discoveryDepth: 4,
      discoveryIgnore: [],
      ignoredRoots: ["C:\\workspace"],
      externalsMode: "lazy",
    });
    expect(discoveryService.openDiscoveredRepository).toHaveBeenCalledWith({
      candidate,
      pathCase: "case-insensitive",
    });
  });

  it("does not reopen discovered working copies that already have open sessions", async () => {
    const alreadyOpen = discoveryCandidate({ workingCopyRoot: "C:\\WORKSPACE" });
    const discoveryService = fakeDiscoveryService({ candidates: [alreadyOpen] });
    const sessionService = fakeSessionService({
      sessions: [repositorySession({ workingCopyRoot: "C:\\workspace" })],
    });
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(discoveryService, sessionService, ui);

    await controller.openRepository();

    expect(discoveryService.openDiscoveredRepository).not.toHaveBeenCalled();
    expect(ui.pickRepositoryCandidate).not.toHaveBeenCalled();
    expect(ui.showWarningMessage).toHaveBeenCalledWith("All discovered SVN working copies are already open.");
  });

  it("opens the remaining unopened working copy when discovery also returns open sessions", async () => {
    const alreadyOpen = discoveryCandidate({ workingCopyRoot: "C:\\workspace" });
    const unopened = discoveryCandidate({
      repositoryUuid: "repo-2",
      workingCopyRoot: "D:\\other-wc",
    });
    const discoveryService = fakeDiscoveryService({ candidates: [alreadyOpen, unopened] });
    const sessionService = fakeSessionService({
      sessions: [repositorySession({ workingCopyRoot: "C:\\workspace" })],
    });
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace", "D:\\other-wc"] });
    const controller = commandController(discoveryService, sessionService, ui);

    await controller.openRepository();

    expect(ui.pickRepositoryCandidate).not.toHaveBeenCalled();
    expect(discoveryService.openDiscoveredRepository).toHaveBeenCalledWith({
      candidate: unopened,
      pathCase: "case-insensitive",
    });
  });

  it("fails fast without starting discovery when no workspace folder is open", async () => {
    const discoveryService = fakeDiscoveryService({ candidates: [discoveryCandidate()] });
    const ui = fakeCommandUi({ workspaceRoots: [] });
    const controller = commandController(discoveryService, fakeSessionService(), ui);

    await controller.openRepository();

    expect(discoveryService.discoverRepositories).not.toHaveBeenCalled();
    expect(ui.showWarningMessage).toHaveBeenCalledWith(
      "Open a workspace folder before opening an SVN repository.",
    );
  });

  it("fails fast before discovery when the platform path-case policy is unavailable", async () => {
    const discoveryService = fakeDiscoveryService({ candidates: [discoveryCandidate()] });
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    ui.pathCasePolicy.mockImplementation(() => {
      throw new CodedError("SUBVERSIONR_REPOSITORY_PATH_CASE_UNSUPPORTED");
    });
    const controller = commandController(discoveryService, fakeSessionService(), ui);

    await controller.openRepository();

    expect(discoveryService.discoverRepositories).not.toHaveBeenCalled();
    expect(discoveryService.openDiscoveredRepository).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_REPOSITORY_PATH_CASE_UNSUPPORTED",
    );
  });

  it("reports an empty discovery result without opening a session", async () => {
    const discoveryService = fakeDiscoveryService({ candidates: [] });
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(discoveryService, fakeSessionService(), ui);

    await controller.openRepository();

    expect(discoveryService.openDiscoveredRepository).not.toHaveBeenCalled();
    expect(ui.showWarningMessage).toHaveBeenCalledWith("No SVN working copy was found in the workspace.");
  });

  it("requires an explicit candidate choice when discovery returns multiple working copies", async () => {
    const first = discoveryCandidate({ workingCopyRoot: "C:\\workspace" });
    const second = discoveryCandidate({ repositoryUuid: "repo-2", workingCopyRoot: "C:\\workspace\\nested" });
    const discoveryService = fakeDiscoveryService({ candidates: [first, second] });
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace"],
      pickedCandidate: second,
    });
    const controller = commandController(discoveryService, fakeSessionService(), ui);

    await controller.openRepository();

    expect(ui.pickRepositoryCandidate).toHaveBeenCalledWith([first, second]);
    expect(discoveryService.openDiscoveredRepository).toHaveBeenCalledWith({
      candidate: second,
      pathCase: "case-insensitive",
    });
  });

  it("opens a parent working copy with discovered nested and external roots as watcher boundaries", async () => {
    const parent = discoveryCandidate({ workingCopyRoot: "C:\\workspace" });
    const nested = discoveryCandidate(
      {
        repositoryUuid: "nested-repo",
        workingCopyRoot: "C:\\workspace\\vendor\\nested",
      },
      {
        isNested: true,
        parentWorkingCopyRoot: "C:\\workspace",
      },
    );
    const external = discoveryCandidate(
      {
        repositoryUuid: "external-repo",
        workingCopyRoot: "C:\\workspace\\externals\\library",
      },
      {
        isExternal: true,
        parentWorkingCopyRoot: "C:\\workspace",
      },
    );
    const discoveryService = fakeDiscoveryService({ candidates: [parent, nested, external] });
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace"],
      pickedCandidate: parent,
    });
    const controller = commandController(discoveryService, fakeSessionService(), ui);

    await controller.openRepository();

    expect(discoveryService.openDiscoveredRepository).toHaveBeenCalledWith({
      candidate: parent,
      pathCase: "case-insensitive",
      boundaryRoots: ["C:\\workspace\\vendor\\nested", "C:\\workspace\\externals\\library"],
    });
  });

  it("opens a parent working copy with discovered file external paths as watcher boundaries", async () => {
    const parent = discoveryCandidate({ workingCopyRoot: "C:\\workspace" });
    const discoveryService = fakeDiscoveryService({
      candidates: [parent],
      fileExternalBoundaries: ["C:\\workspace\\externals\\pinned.txt"],
    });
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(discoveryService, fakeSessionService(), ui);

    await controller.openRepository();

    expect(discoveryService.openDiscoveredRepository).toHaveBeenCalledWith({
      candidate: parent,
      pathCase: "case-insensitive",
      boundaryRoots: ["C:\\workspace\\externals\\pinned.txt"],
    });
  });

  it("opens a parent working copy with already open child sessions as watcher boundaries", async () => {
    const parent = discoveryCandidate({ workingCopyRoot: "C:\\workspace" });
    const childSession = repositorySession({
      repositoryId: "nested-repo:C:/workspace/vendor/nested",
      workingCopyRoot: "C:\\workspace\\vendor\\nested",
    });
    const discoveryService = fakeDiscoveryService({ candidates: [parent] });
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(
      discoveryService,
      fakeSessionService({ sessions: [childSession] }),
      ui,
    );

    await controller.openRepository();

    expect(discoveryService.discoverRepositories).toHaveBeenCalledWith({
      workspaceRoots: ["C:\\workspace"],
      discoverNested: true,
      discoveryDepth: 4,
      discoveryIgnore: [],
      ignoredRoots: ["C:\\workspace\\vendor\\nested"],
      externalsMode: "lazy",
    });
    expect(discoveryService.openDiscoveredRepository).toHaveBeenCalledWith({
      candidate: parent,
      pathCase: "case-insensitive",
      boundaryRoots: ["C:\\workspace\\vendor\\nested"],
    });
  });

  it("does not open a repository when candidate selection is cancelled", async () => {
    const first = discoveryCandidate({ workingCopyRoot: "C:\\workspace" });
    const second = discoveryCandidate({ repositoryUuid: "repo-2", workingCopyRoot: "C:\\workspace\\nested" });
    const discoveryService = fakeDiscoveryService({ candidates: [first, second] });
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace"],
      pickedCandidate: undefined,
    });
    const controller = commandController(discoveryService, fakeSessionService(), ui);

    await controller.openRepository();

    expect(discoveryService.openDiscoveredRepository).not.toHaveBeenCalled();
    expect(ui.showInformationMessage).not.toHaveBeenCalled();
  });

  it("closes the single open repository session reported by the session service", async () => {
    const discoveryService = fakeDiscoveryService({ candidates: [discoveryCandidate()] });
    const sessionService = fakeSessionService({ sessions: [repositorySession()] });
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(discoveryService, sessionService, ui);

    await controller.closeRepository();

    expect(sessionService.closeRepository).toHaveBeenCalledTimes(1);
    expect(sessionService.closeRepository).toHaveBeenCalledWith("repo-uuid:C:/workspace");
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR closed SVN working copy: C:\\workspace",
    );
  });

  it("reports no open repository from the session service without using local command state", async () => {
    const sessionService = fakeSessionService({ sessions: [] });
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui);

    await controller.closeRepository();

    expect(sessionService.closeRepository).not.toHaveBeenCalled();
    expect(ui.showWarningMessage).toHaveBeenCalledWith("No SVN repository is open.");
  });

  it("requires an explicit repository choice before closing multiple open sessions", async () => {
    const first = repositorySession();
    const second = repositorySession({
      repositoryId: "repo-uuid:D:/other-wc",
      workingCopyRoot: "D:\\other-wc",
    });
    const sessionService = fakeSessionService({ sessions: [first, second] });
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace"],
      pickedSession: second,
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui);

    await controller.closeRepository();

    expect(ui.pickOpenRepository).toHaveBeenCalledWith([first, second]);
    expect(sessionService.closeRepository).toHaveBeenCalledWith("repo-uuid:D:/other-wc");
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR closed SVN working copy: D:\\other-wc",
    );
  });

  it("closes a repository id command argument without prompting", async () => {
    const first = repositorySession();
    const second = repositorySession({
      repositoryId: "repo-uuid:D:/other-wc",
      workingCopyRoot: "D:\\other-wc",
    });
    const sessionService = fakeSessionService({ sessions: [first, second] });
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui);

    await (controller as unknown as { closeRepository(repositoryId?: unknown): Promise<void> })
      .closeRepository("repo-uuid:D:/other-wc");

    expect(ui.pickOpenRepository).not.toHaveBeenCalled();
    expect(sessionService.closeRepository).toHaveBeenCalledTimes(1);
    expect(sessionService.closeRepository).toHaveBeenCalledWith("repo-uuid:D:/other-wc");
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR closed SVN working copy: D:\\other-wc",
    );
  });

  it("rejects invalid close repository id command arguments with a close error code", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui);

    await (controller as unknown as { closeRepository(repositoryId?: unknown): Promise<void> })
      .closeRepository("   ");

    expect(ui.pickOpenRepository).not.toHaveBeenCalled();
    expect(sessionService.closeRepository).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_CLOSE_REPOSITORY_ID_INVALID",
    );
  });

  it("rejects unknown close repository ids with a close error code", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui);

    await (controller as unknown as { closeRepository(repositoryId?: unknown): Promise<void> })
      .closeRepository("repo-uuid:D:/missing-wc");

    expect(ui.pickOpenRepository).not.toHaveBeenCalled();
    expect(sessionService.closeRepository).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_CLOSE_REPOSITORY_NOT_OPEN",
    );
  });

  it("refreshes the single open repository through the dirty-path refresh service", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
    });

    await controller.refreshRepository();

    expect(refreshService.refreshRepository).toHaveBeenCalledWith("repo-uuid:C:/workspace");
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR refreshed SVN working copy: C:\\workspace",
    );
  });

  it("runs repository refresh through cancellable operation progress and forwards the progress signal", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const progressCancellation = new AbortController();
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace"],
      operationProgressSignal: progressCancellation.signal,
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
    });

    await controller.refreshRepository();

    expect(ui.runOperationWithProgress).toHaveBeenCalledWith(
      "Refreshing SVN working copy",
      expect.any(Function),
    );
    expect(refreshService.refreshRepository).toHaveBeenCalledWith(
      "repo-uuid:C:/workspace",
      { signal: progressCancellation.signal },
    );
  });

  it("runs repository refresh for a repository id command argument without prompting", async () => {
    const first = repositorySession();
    const second = repositorySession({
      repositoryId: "repo-uuid:D:/other-wc",
      workingCopyRoot: "D:\\other-wc",
    });
    const sessionService = fakeSessionService({ sessions: [first, second] });
    const refreshService = fakeRefreshService();
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
    });

    await (controller as unknown as { refreshRepository(repositoryId?: unknown): Promise<void> })
      .refreshRepository("repo-uuid:D:/other-wc");

    expect(ui.pickOpenRepository).not.toHaveBeenCalled();
    expect(refreshService.refreshRepository).toHaveBeenCalledWith("repo-uuid:D:/other-wc");
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR refreshed SVN working copy: D:\\other-wc",
    );
  });

  it("checks remote changes through an explicit manual remote status refresh target", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const progressCancellation = new AbortController();
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace"],
      operationProgressSignal: progressCancellation.signal,
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
    });

    await controller.checkRemoteChanges();

    expect(ui.runOperationWithProgress).toHaveBeenCalledWith(
      "Checking SVN remote changes",
      expect.any(Function),
    );
    expect(refreshService.refreshTargets).toHaveBeenCalledWith(
      {
        repositoryId: "repo-uuid:C:/workspace",
        epoch: 7,
        targets: [{ path: ".", depth: "infinity", reason: "manualRemoteCheck" }],
      },
      { signal: progressCancellation.signal },
    );
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR checked SVN remote changes: C:\\workspace",
    );
  });

  it("rejects invalid refresh repository id command arguments with a refresh error code", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
    });

    await (controller as unknown as { refreshRepository(repositoryId?: unknown): Promise<void> })
      .refreshRepository("   ");

    expect(ui.pickOpenRepository).not.toHaveBeenCalled();
    expect(refreshService.refreshRepository).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_REFRESH_REPOSITORY_ID_INVALID",
    );
  });

  it("rejects unknown refresh repository ids with a refresh error code", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
    });

    await (controller as unknown as { refreshRepository(repositoryId?: unknown): Promise<void> })
      .refreshRepository("repo-uuid:D:/missing-wc");

    expect(ui.pickOpenRepository).not.toHaveBeenCalled();
    expect(refreshService.refreshRepository).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_REFRESH_REPOSITORY_NOT_OPEN",
    );
  });

  it("runs full reconcile for the selected repository session", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
    });

    await controller.fullReconcileRepository();

    expect(refreshService.fullReconcileRepository).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
    });
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR completed full reconcile: C:\\workspace",
    );
  });

  it("runs full reconcile through cancellable operation progress and forwards the progress signal", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const progressCancellation = new AbortController();
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace"],
      operationProgressSignal: progressCancellation.signal,
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
    });

    await controller.fullReconcileRepository();

    expect(ui.runOperationWithProgress).toHaveBeenCalledWith(
      "Reconciling SVN working copy status",
      expect.any(Function),
    );
    expect(refreshService.fullReconcileRepository).toHaveBeenCalledWith(
      {
        repositoryId: "repo-uuid:C:/workspace",
        epoch: 7,
      },
      { signal: progressCancellation.signal },
    );
  });

  it("treats full reconcile progress cancellation as a user-cancelled command", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    refreshService.fullReconcileRepository.mockRejectedValueOnce(
      new CodedError("SUBVERSIONR_STATUS_REFRESH_CANCELLED"),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
    });

    await controller.fullReconcileRepository();

    expect(ui.showErrorMessage).not.toHaveBeenCalled();
    expect(ui.showInformationMessage).not.toHaveBeenCalled();
  });

  it("does not wait for passive full reconcile success notification dismissal", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    ui.showInformationMessage.mockImplementationOnce(() => new Promise(() => undefined));
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
    });

    await expect(withTimeout(controller.fullReconcileRepository(), 50)).resolves.toBeUndefined();

    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR completed full reconcile: C:\\workspace",
    );
  });

  it("logs passive full reconcile success notification failures without failing the command", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const notificationError = new Error("notification failed");
    ui.showInformationMessage.mockRejectedValueOnce(notificationError);
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => undefined);
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
    });

    try {
      await controller.fullReconcileRepository();
      await flushMicrotasks();

      expect(consoleError).toHaveBeenCalledWith(
        "SubversionR repository command notification failed.",
        notificationError,
      );
    } finally {
      consoleError.mockRestore();
    }
  });

  it("runs full reconcile for a repository id command argument without prompting", async () => {
    const first = repositorySession();
    const second = repositorySession({
      repositoryId: "repo-uuid:D:/other-wc",
      workingCopyRoot: "D:\\other-wc",
    });
    const sessionService = fakeSessionService({ sessions: [first, second] });
    const refreshService = fakeRefreshService();
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
    });

    await controller.fullReconcileRepository("repo-uuid:D:/other-wc");

    expect(ui.pickOpenRepository).not.toHaveBeenCalled();
    expect(refreshService.fullReconcileRepository).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:D:/other-wc",
      epoch: 7,
    });
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR completed full reconcile: D:\\other-wc",
    );
  });

  it("rejects invalid full reconcile repository id command arguments with a full reconcile error code", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
    });

    await controller.fullReconcileRepository("   ");

    expect(ui.pickOpenRepository).not.toHaveBeenCalled();
    expect(refreshService.fullReconcileRepository).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_FULL_RECONCILE_REPOSITORY_ID_INVALID",
    );
  });

  it("rejects unknown full reconcile repository ids with a full reconcile error code", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
    });

    await controller.fullReconcileRepository("repo-uuid:D:/missing-wc");

    expect(ui.pickOpenRepository).not.toHaveBeenCalled();
    expect(refreshService.fullReconcileRepository).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_FULL_RECONCILE_REPOSITORY_NOT_OPEN",
    );
  });

  it("runs cleanup with prompted options for the selected repository session and performs a full reconcile", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({
        kind: "cleanup",
        path: ".",
        reconcile: {
          targets: [],
          requiresFullReconcile: true,
        },
      }),
    );
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace"],
      cleanupOptions: {
        breakLocks: false,
        fixRecordedTimestamps: true,
        clearDavCache: true,
        vacuumPristines: true,
        includeExternals: true,
      },
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
    });

    await controller.cleanupRepository();

    expect(ui.promptCleanupOptions).toHaveBeenCalledWith("C:\\workspace");
    expect(operationClient.cleanup).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: ".",
      breakLocks: false,
      fixRecordedTimestamps: true,
      clearDavCache: true,
      vacuumPristines: true,
      includeExternals: true,
    });
    expect(refreshService.fullReconcileRepository).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
    });
    expect(refreshService.refreshTargets).not.toHaveBeenCalled();
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR cleaned up SVN working copy: C:\\workspace",
    );
  });

  it("runs cleanup for a repository id command argument without repository picker prompting", async () => {
    const first = repositorySession();
    const second = repositorySession({
      repositoryId: "repo-uuid:D:/other-wc",
      workingCopyRoot: "D:\\other-wc",
    });
    const sessionService = fakeSessionService({ sessions: [first, second] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({
        kind: "cleanup",
        path: ".",
        reconcile: {
          targets: [],
          requiresFullReconcile: true,
        },
      }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace", "D:\\other-wc"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
    });

    await (controller as unknown as { cleanupRepository(repositoryId?: unknown): Promise<void> })
      .cleanupRepository("repo-uuid:D:/other-wc");

    expect(ui.pickOpenRepository).not.toHaveBeenCalled();
    expect(ui.promptCleanupOptions).toHaveBeenCalledWith("D:\\other-wc");
    expect(operationClient.cleanup).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:D:/other-wc",
      epoch: 7,
      path: ".",
      breakLocks: true,
      fixRecordedTimestamps: false,
      clearDavCache: false,
      vacuumPristines: false,
      includeExternals: false,
    });
    expect(refreshService.fullReconcileRepository).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:D:/other-wc",
      epoch: 7,
    });
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR cleaned up SVN working copy: D:\\other-wc",
    );
  });

  it("does not run cleanup when cleanup options are cancelled", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({
        kind: "cleanup",
        path: ".",
      }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"], cleanupOptions: undefined });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
    });

    await controller.cleanupRepository();

    expect(ui.promptCleanupOptions).toHaveBeenCalledWith("C:\\workspace");
    expect(operationClient.cleanup).not.toHaveBeenCalled();
    expect(refreshService.fullReconcileRepository).not.toHaveBeenCalled();
    expect(ui.showInformationMessage).not.toHaveBeenCalled();
  });

  it("rejects invalid cleanup repository id command arguments with a cleanup error code", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const operationClient = fakeOperationClient(
      operationResponse({
        kind: "cleanup",
        path: ".",
      }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      operationClient,
    });

    await (controller as unknown as { cleanupRepository(repositoryId?: unknown): Promise<void> })
      .cleanupRepository("   ");

    expect(ui.pickOpenRepository).not.toHaveBeenCalled();
    expect(operationClient.cleanup).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_CLEANUP_REPOSITORY_ID_INVALID",
    );
  });

  it("rejects unknown cleanup repository ids with a cleanup error code", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const operationClient = fakeOperationClient(
      operationResponse({
        kind: "cleanup",
        path: ".",
      }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      operationClient,
    });

    await (controller as unknown as { cleanupRepository(repositoryId?: unknown): Promise<void> })
      .cleanupRepository("repo-uuid:D:/missing-wc");

    expect(ui.pickOpenRepository).not.toHaveBeenCalled();
    expect(operationClient.cleanup).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_CLEANUP_REPOSITORY_NOT_OPEN",
    );
  });

  it("always runs full reconcile after cleanup even if the backend returns targeted cleanup hints", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({
        kind: "cleanup",
        path: ".",
        reason: "operationCleanup",
      }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
    });

    await controller.cleanupRepository();

    expect(refreshService.fullReconcileRepository).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
    });
    expect(refreshService.refreshTargets).not.toHaveBeenCalled();
  });

  it("runs working copy upgrade for the selected repository session and performs a full reconcile", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({
        kind: "upgrade",
        path: ".",
        reconcile: {
          targets: [],
          requiresFullReconcile: true,
        },
      }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
    });

    await controller.upgradeWorkingCopy();

    expect(operationClient.upgrade).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: ".",
    });
    expect(refreshService.fullReconcileRepository).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
    });
    expect(refreshService.refreshTargets).not.toHaveBeenCalled();
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR upgraded SVN working copy: C:\\workspace",
    );
  });

  it("runs working copy upgrade for a repository id command argument without prompting", async () => {
    const first = repositorySession();
    const second = repositorySession({
      repositoryId: "repo-uuid:D:/other-wc",
      workingCopyRoot: "D:\\other-wc",
    });
    const sessionService = fakeSessionService({ sessions: [first, second] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({
        kind: "upgrade",
        path: ".",
        reconcile: {
          targets: [],
          requiresFullReconcile: true,
        },
      }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace", "D:\\other-wc"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
    });

    await (controller as unknown as { upgradeWorkingCopy(repositoryId?: unknown): Promise<void> })
      .upgradeWorkingCopy("repo-uuid:D:/other-wc");

    expect(ui.pickOpenRepository).not.toHaveBeenCalled();
    expect(operationClient.upgrade).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:D:/other-wc",
      epoch: 7,
      path: ".",
    });
    expect(refreshService.fullReconcileRepository).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:D:/other-wc",
      epoch: 7,
    });
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR upgraded SVN working copy: D:\\other-wc",
    );
  });

  it("rejects invalid working copy upgrade repository id command arguments with an upgrade error code", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const operationClient = fakeOperationClient(operationResponse({ kind: "upgrade", path: "." }));
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      operationClient,
    });

    await (controller as unknown as { upgradeWorkingCopy(repositoryId?: unknown): Promise<void> })
      .upgradeWorkingCopy("   ");

    expect(ui.pickOpenRepository).not.toHaveBeenCalled();
    expect(operationClient.upgrade).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_UPGRADE_WORKING_COPY_REPOSITORY_ID_INVALID",
    );
  });

  it("rejects unknown working copy upgrade repository ids with an upgrade error code", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const operationClient = fakeOperationClient(operationResponse({ kind: "upgrade", path: "." }));
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      operationClient,
    });

    await (controller as unknown as { upgradeWorkingCopy(repositoryId?: unknown): Promise<void> })
      .upgradeWorkingCopy("repo-uuid:D:/missing-wc");

    expect(ui.pickOpenRepository).not.toHaveBeenCalled();
    expect(operationClient.upgrade).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_UPGRADE_WORKING_COPY_REPOSITORY_NOT_OPEN",
    );
  });

  it("runs update for the selected repository session and performs a full reconcile", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({
        kind: "update",
        path: ".",
        revision: 8,
        reconcile: {
          targets: [],
          requiresFullReconcile: true,
        },
      }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
    });

    await controller.updateRepository();

    expect(operationClient.update).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: ".",
      revision: "head",
      depth: "workingCopy",
      depthIsSticky: false,
      ignoreExternals: true,
    });
    expect(refreshService.fullReconcileRepository).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
    });
    expect(refreshService.refreshTargets).not.toHaveBeenCalled();
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR updated SVN working copy to revision 8: C:\\workspace",
    );
  });

  it("runs update for a repository id command argument without prompting", async () => {
    const first = repositorySession();
    const second = repositorySession({
      repositoryId: "repo-uuid:D:/other-wc",
      workingCopyRoot: "D:\\other-wc",
    });
    const sessionService = fakeSessionService({ sessions: [first, second] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({
        kind: "update",
        path: ".",
        revision: 8,
        reconcile: {
          targets: [],
          requiresFullReconcile: true,
        },
      }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace", "D:\\other-wc"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
    });

    await (controller as unknown as { updateRepository(repositoryId?: unknown): Promise<void> })
      .updateRepository("repo-uuid:D:/other-wc");

    expect(ui.pickOpenRepository).not.toHaveBeenCalled();
    expect(operationClient.update).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:D:/other-wc",
      epoch: 7,
      path: ".",
      revision: "head",
      depth: "workingCopy",
      depthIsSticky: false,
      ignoreExternals: true,
    });
    expect(refreshService.fullReconcileRepository).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:D:/other-wc",
      epoch: 7,
    });
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR updated SVN working copy to revision 8: D:\\other-wc",
    );
  });

  it("runs repository update through cancellable operation progress and forwards the progress signal", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const progressCancellation = new AbortController();
    const operationClient = fakeOperationClient(
      operationResponse({
        kind: "update",
        path: ".",
        revision: 8,
        reconcile: {
          targets: [],
          requiresFullReconcile: true,
        },
      }),
    );
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace"],
      operationProgressSignal: progressCancellation.signal,
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
    });

    await controller.updateRepository();

    expect(ui.runOperationWithProgress).toHaveBeenCalledWith(
      "Updating SVN working copy",
      expect.any(Function),
    );
    expect(operationClient.update).toHaveBeenCalledWith(
      {
        repositoryId: "repo-uuid:C:/workspace",
        epoch: 7,
        path: ".",
        revision: "head",
        depth: "workingCopy",
        depthIsSticky: false,
        ignoreExternals: true,
      },
      { signal: progressCancellation.signal },
    );
  });

  it("runs update to a revision with explicit depth and externals options", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({
        kind: "update",
        path: ".",
        revision: 42,
        reconcile: {
          targets: [],
          requiresFullReconcile: true,
        },
      }),
    );
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace"],
      updateOptions: {
        revision: 42,
        depth: "files",
        depthIsSticky: true,
        ignoreExternals: false,
      },
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
    });

    await controller.updateToRevision();

    expect(ui.promptUpdateOptions).toHaveBeenCalledWith("C:\\workspace");
    expect(operationClient.update).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: ".",
      revision: 42,
      depth: "files",
      depthIsSticky: true,
      ignoreExternals: false,
    });
    expect(refreshService.fullReconcileRepository).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
    });
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR updated SVN working copy to revision 42: C:\\workspace",
    );
  });

  it("runs update to a revision for a repository id command argument without prompting", async () => {
    const first = repositorySession();
    const second = repositorySession({
      repositoryId: "repo-uuid:D:/other-wc",
      workingCopyRoot: "D:\\other-wc",
    });
    const sessionService = fakeSessionService({ sessions: [first, second] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({
        kind: "update",
        path: ".",
        revision: 42,
        reconcile: {
          targets: [],
          requiresFullReconcile: true,
        },
      }),
    );
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace", "D:\\other-wc"],
      updateOptions: {
        revision: 42,
        depth: "files",
        depthIsSticky: true,
        ignoreExternals: false,
      },
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
    });

    await (controller as unknown as { updateToRevision(repositoryId?: unknown): Promise<void> })
      .updateToRevision("repo-uuid:D:/other-wc");

    expect(ui.pickOpenRepository).not.toHaveBeenCalled();
    expect(ui.promptUpdateOptions).toHaveBeenCalledWith("D:\\other-wc");
    expect(operationClient.update).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:D:/other-wc",
      epoch: 7,
      path: ".",
      revision: 42,
      depth: "files",
      depthIsSticky: true,
      ignoreExternals: false,
    });
    expect(refreshService.fullReconcileRepository).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:D:/other-wc",
      epoch: 7,
    });
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR updated SVN working copy to revision 42: D:\\other-wc",
    );
  });

  it("fully reconciles opened child working copies after including externals in an update", async () => {
    const session = repositorySession({
      repositoryId: "repo-uuid:C:/workspace",
      workingCopyRoot: "C:\\workspace",
    });
    const externalSession = repositorySession({
      repositoryId: "external-uuid:C:/workspace/externals/library",
      workingCopyRoot: "C:\\workspace\\externals\\library",
    });
    const siblingSession = repositorySession({
      repositoryId: "sibling-uuid:D:/other-wc",
      workingCopyRoot: "D:\\other-wc",
    });
    const sessionService = fakeSessionService({ sessions: [session, externalSession, siblingSession] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(operationResponse({ kind: "update", path: ".", revision: 42 }));
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace"],
      pickedSession: session,
      updateOptions: {
        revision: 42,
        depth: "workingCopy",
        depthIsSticky: false,
        ignoreExternals: false,
      },
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
    });

    await controller.updateToRevision();

    expect(refreshService.fullReconcileRepository).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
    });
    expect(refreshService.fullReconcileRepository).toHaveBeenCalledWith({
      repositoryId: "external-uuid:C:/workspace/externals/library",
      epoch: 7,
    });
    expect(refreshService.fullReconcileRepository).not.toHaveBeenCalledWith({
      repositoryId: "sibling-uuid:D:/other-wc",
      epoch: 7,
    });
  });

  it("does not run update to revision when the update options prompt is cancelled", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const operationClient = fakeOperationClient(operationResponse({ kind: "update", path: ".", revision: 42 }));
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"], updateOptions: undefined });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      operationClient,
    });

    await controller.updateToRevision();

    expect(ui.promptUpdateOptions).toHaveBeenCalledWith("C:\\workspace");
    expect(operationClient.update).not.toHaveBeenCalled();
  });

  it("creates an SVN branch or tag from prompted repository URLs without local reconcile", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({
        kind: "branchCreate",
        revision: 42,
        reconcile: {
          targets: [],
          requiresFullReconcile: false,
        },
      }),
    );
    operationClient.branchCreate.mockResolvedValueOnce({
      ...operationResponse({
        kind: "branchCreate",
        revision: 42,
        reconcile: {
          targets: [],
          requiresFullReconcile: false,
        },
      }),
      touchedPaths: [],
      summary: { affectedPaths: 0, skippedPaths: 0 },
    });
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace"],
      branchCreateOptions: {
        sourceUrl: "file:///repo/trunk",
        destinationUrl: "file:///repo/branches/feature",
        revision: "head",
        message: "Create feature branch",
        makeParents: true,
        ignoreExternals: false,
        switchAfterCreate: false,
      },
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
    });

    await controller.branchCreateRepository();

    expect(ui.promptBranchCreateOptions).toHaveBeenCalledWith("C:\\workspace");
    expect(operationClient.branchCreate).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      sourceUrl: "file:///repo/trunk",
      destinationUrl: "file:///repo/branches/feature",
      revision: "head",
      message: "Create feature branch",
      makeParents: true,
      ignoreExternals: false,
    });
    expect(refreshService.fullReconcileRepository).not.toHaveBeenCalled();
    expect(refreshService.refreshTargets).not.toHaveBeenCalled();
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR created SVN branch/tag at revision 42: file:///repo/branches/feature",
    );
  });

  it("creates an SVN branch and switches the working copy when requested", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(operationResponse({ kind: "branchCreate", revision: 42 }));
    operationClient.branchCreate.mockResolvedValueOnce({
      ...operationResponse({
        kind: "branchCreate",
        revision: 42,
        reconcile: {
          targets: [],
          requiresFullReconcile: false,
        },
      }),
      touchedPaths: [],
      summary: { affectedPaths: 0, skippedPaths: 0 },
    });
    operationClient.switch.mockResolvedValueOnce(
      operationResponse({
        kind: "switch",
        path: ".",
        revision: 44,
        reconcile: {
          targets: [],
          requiresFullReconcile: true,
        },
      }),
    );
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace"],
      branchCreateOptions: {
        sourceUrl: "file:///repo/trunk",
        destinationUrl: "file:///repo/branches/feature",
        revision: "head",
        message: "Create feature branch",
        makeParents: true,
        ignoreExternals: false,
        switchAfterCreate: true,
      },
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
    });

    await controller.branchCreateRepository();

    expect(operationClient.branchCreate).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      sourceUrl: "file:///repo/trunk",
      destinationUrl: "file:///repo/branches/feature",
      revision: "head",
      message: "Create feature branch",
      makeParents: true,
      ignoreExternals: false,
    });
    expect(operationClient.switch).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: ".",
      url: "file:///repo/branches/feature",
      revision: "head",
      depth: "workingCopy",
      depthIsSticky: false,
      ignoreExternals: false,
      ignoreAncestry: false,
    });
    expect(refreshService.fullReconcileRepository).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
    });
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR created SVN branch/tag at revision 42 and switched working copy to revision 44: file:///repo/branches/feature",
    );
  });

  it("creates an SVN branch or tag for a repository id command argument without prompting", async () => {
    const first = repositorySession();
    const second = repositorySession({
      repositoryId: "repo-uuid:D:/other-wc",
      workingCopyRoot: "D:\\other-wc",
    });
    const sessionService = fakeSessionService({ sessions: [first, second] });
    const operationClient = fakeOperationClient(
      operationResponse({
        kind: "branchCreate",
        revision: 43,
        reconcile: {
          targets: [],
          requiresFullReconcile: false,
        },
      }),
    );
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace", "D:\\other-wc"],
      branchCreateOptions: {
        sourceUrl: "file:///repo/trunk",
        destinationUrl: "file:///repo/tags/release-1.0",
        revision: "head",
        message: "Create release tag",
        makeParents: true,
        ignoreExternals: false,
        switchAfterCreate: false,
      },
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      operationClient,
    });

    await (controller as unknown as { branchCreateRepository(repositoryId?: unknown): Promise<void> })
      .branchCreateRepository("repo-uuid:D:/other-wc");

    expect(ui.pickOpenRepository).not.toHaveBeenCalled();
    expect(ui.promptBranchCreateOptions).toHaveBeenCalledWith("D:\\other-wc");
    expect(operationClient.branchCreate).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:D:/other-wc",
      epoch: 7,
      sourceUrl: "file:///repo/trunk",
      destinationUrl: "file:///repo/tags/release-1.0",
      revision: "head",
      message: "Create release tag",
      makeParents: true,
      ignoreExternals: false,
    });
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR created SVN branch/tag at revision 43: file:///repo/tags/release-1.0",
    );
  });

  it("rejects invalid branch create repository id command arguments with a branch create error code", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const operationClient = fakeOperationClient(
      operationResponse({
        kind: "branchCreate",
        revision: 43,
      }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      operationClient,
    });

    await (controller as unknown as { branchCreateRepository(repositoryId?: unknown): Promise<void> })
      .branchCreateRepository("   ");

    expect(ui.pickOpenRepository).not.toHaveBeenCalled();
    expect(operationClient.branchCreate).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_BRANCH_CREATE_REPOSITORY_ID_INVALID",
    );
  });

  it("rejects unknown branch create repository ids with a branch create error code", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const operationClient = fakeOperationClient(
      operationResponse({
        kind: "branchCreate",
        revision: 43,
      }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      operationClient,
    });

    await (controller as unknown as { branchCreateRepository(repositoryId?: unknown): Promise<void> })
      .branchCreateRepository("repo-uuid:D:/missing-wc");

    expect(ui.pickOpenRepository).not.toHaveBeenCalled();
    expect(operationClient.branchCreate).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_BRANCH_CREATE_REPOSITORY_NOT_OPEN",
    );
  });

  it("switches the selected repository and performs a full reconcile", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({
        kind: "switch",
        path: ".",
        revision: 55,
        reconcile: {
          targets: [],
          requiresFullReconcile: true,
        },
      }),
    );
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace"],
      switchOptions: {
        url: "file:///repo/branches/feature",
        revision: 55,
        depth: "infinity",
        depthIsSticky: true,
        ignoreExternals: true,
        ignoreAncestry: false,
      },
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
    });

    await controller.switchRepository();

    expect(ui.promptSwitchOptions).toHaveBeenCalledWith("C:\\workspace");
    expect(operationClient.switch).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: ".",
      url: "file:///repo/branches/feature",
      revision: 55,
      depth: "infinity",
      depthIsSticky: true,
      ignoreExternals: true,
      ignoreAncestry: false,
    });
    expect(refreshService.fullReconcileRepository).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
    });
    expect(refreshService.refreshTargets).not.toHaveBeenCalled();
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR switched SVN working copy to revision 55: file:///repo/branches/feature",
    );
  });

  it("switches a repository id command argument without prompting", async () => {
    const first = repositorySession();
    const second = repositorySession({
      repositoryId: "repo-uuid:D:/other-wc",
      workingCopyRoot: "D:\\other-wc",
    });
    const sessionService = fakeSessionService({ sessions: [first, second] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({
        kind: "switch",
        path: ".",
        revision: 61,
        reconcile: {
          targets: [],
          requiresFullReconcile: true,
        },
      }),
    );
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace", "D:\\other-wc"],
      switchOptions: {
        url: "file:///repo/branches/release",
        revision: 61,
        depth: "files",
        depthIsSticky: true,
        ignoreExternals: false,
        ignoreAncestry: true,
      },
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
    });

    await (controller as unknown as { switchRepository(repositoryId?: unknown): Promise<void> })
      .switchRepository("repo-uuid:D:/other-wc");

    expect(ui.pickOpenRepository).not.toHaveBeenCalled();
    expect(ui.promptSwitchOptions).toHaveBeenCalledWith("D:\\other-wc");
    expect(operationClient.switch).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:D:/other-wc",
      epoch: 7,
      path: ".",
      url: "file:///repo/branches/release",
      revision: 61,
      depth: "files",
      depthIsSticky: true,
      ignoreExternals: false,
      ignoreAncestry: true,
    });
    expect(refreshService.fullReconcileRepository).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:D:/other-wc",
      epoch: 7,
    });
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR switched SVN working copy to revision 61: file:///repo/branches/release",
    );
  });

  it("rejects invalid switch repository id command arguments with a switch error code", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const operationClient = fakeOperationClient(
      operationResponse({
        kind: "switch",
        path: ".",
        revision: 61,
      }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      operationClient,
    });

    await (controller as unknown as { switchRepository(repositoryId?: unknown): Promise<void> })
      .switchRepository("   ");

    expect(ui.pickOpenRepository).not.toHaveBeenCalled();
    expect(ui.promptSwitchOptions).not.toHaveBeenCalled();
    expect(operationClient.switch).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_SWITCH_REPOSITORY_ID_INVALID",
    );
  });

  it("rejects unknown switch repository ids with a switch error code", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const operationClient = fakeOperationClient(
      operationResponse({
        kind: "switch",
        path: ".",
        revision: 61,
      }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      operationClient,
    });

    await (controller as unknown as { switchRepository(repositoryId?: unknown): Promise<void> })
      .switchRepository("repo-uuid:D:/missing-wc");

    expect(ui.pickOpenRepository).not.toHaveBeenCalled();
    expect(ui.promptSwitchOptions).not.toHaveBeenCalled();
    expect(operationClient.switch).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_SWITCH_REPOSITORY_NOT_OPEN",
    );
  });

  it("relocates the selected repository and performs a full reconcile", async () => {
    const session = repositorySession({
      repositoryRootUrl: "file:///repo",
    });
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({
        kind: "relocate",
        path: ".",
        revision: null,
        reconcile: {
          targets: [],
          requiresFullReconcile: true,
        },
      }),
    );
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace"],
      relocateOptions: {
        toUrl: "https://svn.example.invalid/repo",
        ignoreExternals: true,
      },
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
    });

    await controller.relocateRepository();

    expect(ui.promptRelocateOptions).toHaveBeenCalledWith("C:\\workspace", "file:///repo");
    expect(operationClient.relocate).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      fromUrl: "file:///repo",
      toUrl: "https://svn.example.invalid/repo",
      ignoreExternals: true,
    });
    expect(refreshService.fullReconcileRepository).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
    });
    expect(sessionService.refreshSessionIdentityFromSnapshot).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
    });
    expect(refreshService.refreshTargets).not.toHaveBeenCalled();
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR relocated SVN working copy to: https://svn.example.invalid/repo",
    );
  });

  it("runs an SVN merge range from prompted options and performs a full reconcile", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const mergeResponse = operationResponse({
      kind: "merge",
      path: ".",
      reconcile: {
        targets: [
          { path: "src/main.c", depth: "empty", reason: "operationMerge" },
          { path: "src/lib.c", depth: "empty", reason: "operationMerge" },
        ],
        requiresFullReconcile: false,
      },
    });
    mergeResponse.touchedPaths = ["src/main.c", "src/lib.c"];
    mergeResponse.summary = { affectedPaths: 2, skippedPaths: 0 };
    const merge = vi.fn(async () => mergeResponse);
    const operationClient = {
      ...fakeOperationClient(mergeResponse),
      merge,
    };
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace"],
      mergeRangeOptions: {
        sourceUrl: "file:///repo/branches/feature",
        targetPath: "src",
        startRevision: 10,
        endRevision: 12,
        depth: "infinity",
        ignoreMergeinfo: false,
        diffIgnoreAncestry: false,
        forceDelete: false,
        recordOnly: false,
        dryRun: false,
        allowMixedRevisions: false,
      },
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
    });

    await controller.mergeRangeRepository();

    expect(ui.promptMergeRangeOptions).toHaveBeenCalledWith("C:\\workspace");
    expect(merge).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      sourceUrl: "file:///repo/branches/feature",
      targetPath: "src",
      startRevision: 10,
      endRevision: 12,
      depth: "infinity",
      ignoreMergeinfo: false,
      diffIgnoreAncestry: false,
      forceDelete: false,
      recordOnly: false,
      dryRun: false,
      allowMixedRevisions: false,
    });
    expect(refreshService.fullReconcileRepository).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
    });
    expect(refreshService.refreshTargets).not.toHaveBeenCalled();
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR merged SVN revision range r10:r12 (Additive merge) from file:///repo/branches/feature into C:\\workspace at src: 2 affected SVN path(s), 0 skipped SVN path(s), 0 SVN operation warning(s)",
    );
    expect(ui.showTextDocument).toHaveBeenCalledWith({
      title: "SVN Merge Result: file:///repo/branches/feature r10:r12 -> C:\\workspace",
      language: "markdown",
      content:
        "SVN merge result for file:///repo/branches/feature r10:r12 -> C:\\workspace\n\n" +
        "| SVN merge source URL | SVN merge start revision | SVN merge end revision | SVN merge direction | SVN merge target path | SVN status reconcile mode | SVN status refresh target count | Affected SVN path count | Skipped SVN path count | SVN operation warning count |\n" +
        "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |\n" +
        "| file:///repo/branches/feature | r10 | r12 | Additive merge | src | Full reconcile | 0 | 2 | 0 | 0 |\n\n" +
        "| SVN merge option | SVN merge option value |\n" +
        "| --- | --- |\n" +
        "| SVN merge depth | infinity |\n" +
        "| SVN merge dry run | No |\n" +
        "| Record only | No |\n" +
        "| Ignore mergeinfo | No |\n" +
        "| Ignore ancestry | No |\n" +
        "| Allow mixed revisions | No |\n" +
        "| Allow forced deletes | No |\n\n" +
        "| Affected SVN path |\n" +
        "| --- |\n" +
        "| src/main.c |\n" +
        "| src/lib.c |\n\n" +
        "| Skipped SVN path |\n" +
        "| --- |\n" +
        "| No skipped SVN paths. |",
    });
  });

  it("runs an SVN merge range for a repository id command argument without prompting", async () => {
    const first = repositorySession();
    const second = repositorySession({
      repositoryId: "repo-uuid:D:/other-wc",
      workingCopyRoot: "D:\\other-wc",
    });
    const sessionService = fakeSessionService({ sessions: [first, second] });
    const refreshService = fakeRefreshService();
    const mergeResponse = operationResponse({
      kind: "merge",
      path: ".",
      reconcile: {
        targets: [],
        requiresFullReconcile: true,
      },
    });
    mergeResponse.touchedPaths = [];
    mergeResponse.summary = { affectedPaths: 0, skippedPaths: 0 };
    const merge = vi.fn(async () => mergeResponse);
    const operationClient = {
      ...fakeOperationClient(mergeResponse),
      merge,
    };
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace", "D:\\other-wc"],
      mergeRangeOptions: {
        sourceUrl: "file:///repo/branches/feature",
        targetPath: ".",
        startRevision: 10,
        endRevision: 12,
        depth: "infinity",
        ignoreMergeinfo: false,
        diffIgnoreAncestry: false,
        forceDelete: false,
        recordOnly: false,
        dryRun: false,
        allowMixedRevisions: false,
      },
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
    });

    await (controller as unknown as { mergeRangeRepository(repositoryId?: unknown): Promise<void> })
      .mergeRangeRepository("repo-uuid:D:/other-wc");

    expect(ui.pickOpenRepository).not.toHaveBeenCalled();
    expect(ui.promptMergeRangeOptions).toHaveBeenCalledWith("D:\\other-wc");
    expect(merge).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:D:/other-wc",
      epoch: 7,
      sourceUrl: "file:///repo/branches/feature",
      targetPath: ".",
      startRevision: 10,
      endRevision: 12,
      depth: "infinity",
      ignoreMergeinfo: false,
      diffIgnoreAncestry: false,
      forceDelete: false,
      recordOnly: false,
      dryRun: false,
      allowMixedRevisions: false,
    });
    expect(refreshService.fullReconcileRepository).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:D:/other-wc",
      epoch: 7,
    });
  });

  it("shows an SVN merge result document when a merge reports warnings", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const mergeResponse = operationResponse({
      kind: "merge",
      path: ".",
      reconcile: {
        targets: [],
        requiresFullReconcile: true,
      },
    });
    mergeResponse.touchedPaths = ["src/main.c"];
    mergeResponse.summary = { affectedPaths: 1, skippedPaths: 1 };
    mergeResponse.warnings = [
      {
        code: "SVN_OPERATION_PATH_SKIPPED",
        messageKey: "warning.operation.pathSkipped",
        args: { path: "src/generated.c" },
      },
      {
        code: "SVN_OPERATION_TREE_CONFLICT",
        messageKey: "warning.operation.treeConflict",
        args: { path: "src/tree.c", reason: "local obstruction" },
      },
    ];
    const merge = vi.fn(async () => mergeResponse);
    const operationClient = {
      ...fakeOperationClient(mergeResponse),
      merge,
    };
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace"],
      mergeRangeOptions: {
        sourceUrl: "file:///repo/branches/feature",
        targetPath: "src",
        startRevision: 10,
        endRevision: 12,
        depth: "infinity",
        ignoreMergeinfo: true,
        diffIgnoreAncestry: true,
        forceDelete: true,
        recordOnly: true,
        dryRun: false,
        allowMixedRevisions: true,
      },
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
    });

    await controller.mergeRangeRepository();

    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR merged SVN revision range r10:r12 (Additive merge) from file:///repo/branches/feature into C:\\workspace at src: 1 affected SVN path(s), 1 skipped SVN path(s), 2 SVN operation warning(s)",
    );
    expect(ui.showTextDocument).toHaveBeenCalledWith({
      title: "SVN Merge Result: file:///repo/branches/feature r10:r12 -> C:\\workspace",
      language: "markdown",
      content:
        "SVN merge result for file:///repo/branches/feature r10:r12 -> C:\\workspace\n\n" +
        "| SVN merge source URL | SVN merge start revision | SVN merge end revision | SVN merge direction | SVN merge target path | SVN status reconcile mode | SVN status refresh target count | Affected SVN path count | Skipped SVN path count | SVN operation warning count |\n" +
        "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |\n" +
        "| file:///repo/branches/feature | r10 | r12 | Additive merge | src | Full reconcile | 0 | 1 | 1 | 2 |\n\n" +
        "| SVN merge option | SVN merge option value |\n" +
        "| --- | --- |\n" +
        "| SVN merge depth | infinity |\n" +
        "| SVN merge dry run | No |\n" +
        "| Record only | Yes |\n" +
        "| Ignore mergeinfo | Yes |\n" +
        "| Ignore ancestry | Yes |\n" +
        "| Allow mixed revisions | Yes |\n" +
        "| Allow forced deletes | Yes |\n\n" +
        "| Affected SVN path |\n" +
        "| --- |\n" +
        "| src/main.c |\n\n" +
        "| Skipped SVN path |\n" +
        "| --- |\n" +
        "| src/generated.c |\n\n" +
        "| SVN operation warning | SVN warning key | SVN warning details |\n" +
        "| --- | --- | --- |\n" +
        '| SVN_OPERATION_TREE_CONFLICT | warning.operation.treeConflict | {"path":"src/tree.c","reason":"local obstruction"} |',
    });
  });

  it("previews an SVN merge range from prompted options without full reconcile", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const mergeResponse = operationResponse({
      kind: "merge",
      path: ".",
      reconcile: {
        targets: [
          { path: "src/main.c", depth: "empty", reason: "operationMergePreview" },
          { path: "src/lib.c", depth: "empty", reason: "operationMergePreview" },
        ],
        requiresFullReconcile: false,
      },
    });
    mergeResponse.touchedPaths = ["src/main.c", "src/lib.c"];
    mergeResponse.summary = { affectedPaths: 2, skippedPaths: 1 };
    mergeResponse.warnings = [
      {
        code: "SVN_OPERATION_PATH_SKIPPED",
        messageKey: "warning.operation.pathSkipped",
        args: { path: "src/generated.c" },
      },
      {
        code: "SVN_OPERATION_TREE_CONFLICT",
        messageKey: "warning.operation.treeConflict",
        args: { path: "src/tree.c", reason: "local obstruction" },
      },
    ];
    const merge = vi.fn(async () => mergeResponse);
    const operationClient = {
      ...fakeOperationClient(mergeResponse),
      merge,
    };
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace"],
      mergeRangeOptions: {
        sourceUrl: "file:///repo/branches/feature",
        targetPath: "src",
        startRevision: 10,
        endRevision: 12,
        depth: "infinity",
        ignoreMergeinfo: false,
        diffIgnoreAncestry: false,
        forceDelete: false,
        recordOnly: false,
        dryRun: false,
        allowMixedRevisions: false,
      },
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
    });

    await controller.previewMergeRangeRepository();

    expect(ui.promptMergeRangeOptions).toHaveBeenCalledWith("C:\\workspace");
    expect(merge).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      sourceUrl: "file:///repo/branches/feature",
      targetPath: "src",
      startRevision: 10,
      endRevision: 12,
      depth: "infinity",
      ignoreMergeinfo: false,
      diffIgnoreAncestry: false,
      forceDelete: false,
      recordOnly: false,
      dryRun: true,
      allowMixedRevisions: false,
    });
    expect(refreshService.fullReconcileRepository).not.toHaveBeenCalled();
    expect(refreshService.refreshTargets).not.toHaveBeenCalled();
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR previewed SVN merge range r10:r12 (Additive merge) from file:///repo/branches/feature into C:\\workspace at src: 2 affected SVN path(s), 1 skipped SVN path(s), 2 SVN operation warning(s)",
    );
    expect(ui.showTextDocument).toHaveBeenCalledWith({
      title: "SVN Merge Preview: file:///repo/branches/feature r10:r12 -> C:\\workspace",
      language: "markdown",
      content:
        "SVN merge preview for file:///repo/branches/feature r10:r12 -> C:\\workspace\n\n" +
        "| SVN merge source URL | SVN merge start revision | SVN merge end revision | SVN merge direction | SVN merge target path | SVN status reconcile mode | SVN status refresh target count | Affected SVN path count | Skipped SVN path count | SVN operation warning count |\n" +
        "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |\n" +
        "| file:///repo/branches/feature | r10 | r12 | Additive merge | src | Targeted status refresh | 2 | 2 | 1 | 2 |\n\n" +
        "| SVN merge option | SVN merge option value |\n" +
        "| --- | --- |\n" +
        "| SVN merge depth | infinity |\n" +
        "| SVN merge dry run | Yes |\n" +
        "| Record only | No |\n" +
        "| Ignore mergeinfo | No |\n" +
        "| Ignore ancestry | No |\n" +
        "| Allow mixed revisions | No |\n" +
        "| Allow forced deletes | No |\n\n" +
        "| Affected SVN path |\n" +
        "| --- |\n" +
        "| src/main.c |\n" +
        "| src/lib.c |\n\n" +
        "| SVN status refresh target | SVN status refresh depth | SVN status refresh reason |\n" +
        "| --- | --- | --- |\n" +
        "| src/main.c | empty | operationMergePreview |\n" +
        "| src/lib.c | empty | operationMergePreview |\n\n" +
        "| Skipped SVN path |\n" +
        "| --- |\n" +
        "| src/generated.c |\n\n" +
        "| SVN operation warning | SVN warning key | SVN warning details |\n" +
        "| --- | --- | --- |\n" +
        '| SVN_OPERATION_TREE_CONFLICT | warning.operation.treeConflict | {"path":"src/tree.c","reason":"local obstruction"} |',
    });
  });

  it("previews an SVN merge range for a repository id command argument without prompting", async () => {
    const first = repositorySession();
    const second = repositorySession({
      repositoryId: "repo-uuid:D:/other-wc",
      workingCopyRoot: "D:\\other-wc",
    });
    const sessionService = fakeSessionService({ sessions: [first, second] });
    const refreshService = fakeRefreshService();
    const mergeResponse = operationResponse({
      kind: "merge",
      path: ".",
      reconcile: {
        targets: [],
        requiresFullReconcile: false,
      },
    });
    mergeResponse.touchedPaths = [];
    mergeResponse.summary = { affectedPaths: 0, skippedPaths: 0 };
    const merge = vi.fn(async () => mergeResponse);
    const operationClient = {
      ...fakeOperationClient(mergeResponse),
      merge,
    };
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace", "D:\\other-wc"],
      mergeRangeOptions: {
        sourceUrl: "file:///repo/branches/feature",
        targetPath: ".",
        startRevision: 10,
        endRevision: 12,
        depth: "infinity",
        ignoreMergeinfo: false,
        diffIgnoreAncestry: false,
        forceDelete: false,
        recordOnly: false,
        dryRun: false,
        allowMixedRevisions: false,
      },
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
    });

    await (controller as unknown as { previewMergeRangeRepository(repositoryId?: unknown): Promise<void> })
      .previewMergeRangeRepository("repo-uuid:D:/other-wc");

    expect(ui.pickOpenRepository).not.toHaveBeenCalled();
    expect(ui.promptMergeRangeOptions).toHaveBeenCalledWith("D:\\other-wc");
    expect(merge).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:D:/other-wc",
      epoch: 7,
      sourceUrl: "file:///repo/branches/feature",
      targetPath: ".",
      startRevision: 10,
      endRevision: 12,
      depth: "infinity",
      ignoreMergeinfo: false,
      diffIgnoreAncestry: false,
      forceDelete: false,
      recordOnly: false,
      dryRun: true,
      allowMixedRevisions: false,
    });
    expect(refreshService.fullReconcileRepository).not.toHaveBeenCalled();
  });

  it("shows an explicit empty state in an SVN merge preview with no affected paths", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const mergeResponse = operationResponse({
      kind: "merge",
      path: ".",
      reconcile: {
        targets: [],
        requiresFullReconcile: false,
      },
    });
    mergeResponse.touchedPaths = [];
    mergeResponse.summary = { affectedPaths: 0, skippedPaths: 0 };
    mergeResponse.warnings = [];
    const merge = vi.fn(async () => mergeResponse);
    const operationClient = {
      ...fakeOperationClient(mergeResponse),
      merge,
    };
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace"],
      mergeRangeOptions: {
        sourceUrl: "file:///repo/branches/feature",
        targetPath: ".",
        startRevision: 10,
        endRevision: 12,
        depth: "infinity",
        ignoreMergeinfo: false,
        diffIgnoreAncestry: false,
        forceDelete: false,
        recordOnly: false,
        dryRun: false,
        allowMixedRevisions: false,
      },
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
    });

    await controller.previewMergeRangeRepository();

    expect(refreshService.fullReconcileRepository).not.toHaveBeenCalled();
    expect(refreshService.refreshTargets).not.toHaveBeenCalled();
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR previewed SVN merge range r10:r12 (Additive merge) from file:///repo/branches/feature into C:\\workspace at .: 0 affected SVN path(s), 0 skipped SVN path(s), 0 SVN operation warning(s)",
    );
    expect(ui.showTextDocument).toHaveBeenCalledWith({
      title: "SVN Merge Preview: file:///repo/branches/feature r10:r12 -> C:\\workspace",
      language: "markdown",
      content:
        "SVN merge preview for file:///repo/branches/feature r10:r12 -> C:\\workspace\n\n" +
        "| SVN merge source URL | SVN merge start revision | SVN merge end revision | SVN merge direction | SVN merge target path | SVN status reconcile mode | SVN status refresh target count | Affected SVN path count | Skipped SVN path count | SVN operation warning count |\n" +
        "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |\n" +
        "| file:///repo/branches/feature | r10 | r12 | Additive merge | . | No status refresh | 0 | 0 | 0 | 0 |\n\n" +
        "| SVN merge option | SVN merge option value |\n" +
        "| --- | --- |\n" +
        "| SVN merge depth | infinity |\n" +
        "| SVN merge dry run | Yes |\n" +
        "| Record only | No |\n" +
        "| Ignore mergeinfo | No |\n" +
        "| Ignore ancestry | No |\n" +
        "| Allow mixed revisions | No |\n" +
        "| Allow forced deletes | No |\n\n" +
        "| Affected SVN path |\n" +
        "| --- |\n" +
        "| No affected SVN paths. |\n\n" +
        "| Skipped SVN path |\n" +
        "| --- |\n" +
        "| No skipped SVN paths. |",
    });
  });

  it("shows unavailable skipped path details when an SVN merge preview only reports a skipped count", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const mergeResponse = operationResponse({
      kind: "merge",
      path: ".",
      reconcile: {
        targets: [{ path: "src/main.c", depth: "empty", reason: "operationMergePreview" }],
        requiresFullReconcile: false,
      },
    });
    mergeResponse.touchedPaths = ["src/main.c"];
    mergeResponse.summary = { affectedPaths: 1, skippedPaths: 2 };
    mergeResponse.warnings = [];
    const merge = vi.fn(async () => mergeResponse);
    const operationClient = {
      ...fakeOperationClient(mergeResponse),
      merge,
    };
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace"],
      mergeRangeOptions: {
        sourceUrl: "file:///repo/branches/feature",
        targetPath: "src",
        startRevision: 12,
        endRevision: 10,
        depth: "infinity",
        ignoreMergeinfo: false,
        diffIgnoreAncestry: false,
        forceDelete: false,
        recordOnly: false,
        dryRun: false,
        allowMixedRevisions: false,
      },
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
    });

    await controller.previewMergeRangeRepository();

    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR previewed SVN merge range r12:r10 (Subtractive merge) from file:///repo/branches/feature into C:\\workspace at src: 1 affected SVN path(s), 2 skipped SVN path(s), 0 SVN operation warning(s)",
    );
    expect(ui.showTextDocument).toHaveBeenCalledWith({
      title: "SVN Merge Preview: file:///repo/branches/feature r12:r10 -> C:\\workspace",
      language: "markdown",
      content:
        "SVN merge preview for file:///repo/branches/feature r12:r10 -> C:\\workspace\n\n" +
        "| SVN merge source URL | SVN merge start revision | SVN merge end revision | SVN merge direction | SVN merge target path | SVN status reconcile mode | SVN status refresh target count | Affected SVN path count | Skipped SVN path count | SVN operation warning count |\n" +
        "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |\n" +
        "| file:///repo/branches/feature | r12 | r10 | Subtractive merge | src | Targeted status refresh | 1 | 1 | 2 | 0 |\n\n" +
        "| SVN merge option | SVN merge option value |\n" +
        "| --- | --- |\n" +
        "| SVN merge depth | infinity |\n" +
        "| SVN merge dry run | Yes |\n" +
        "| Record only | No |\n" +
        "| Ignore mergeinfo | No |\n" +
        "| Ignore ancestry | No |\n" +
        "| Allow mixed revisions | No |\n" +
        "| Allow forced deletes | No |\n\n" +
        "| Affected SVN path |\n" +
        "| --- |\n" +
        "| src/main.c |\n\n" +
        "| SVN status refresh target | SVN status refresh depth | SVN status refresh reason |\n" +
        "| --- | --- | --- |\n" +
        "| src/main.c | empty | operationMergePreview |\n\n" +
        "| Skipped SVN path |\n" +
        "| --- |\n" +
        "| Skipped SVN path details unavailable. |",
    });
  });

  it("shows repository root SVN mergeinfo from libsvn properties", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const propertiesClient = fakePropertiesClient(
      propertiesResponse({
        path: ".",
        properties: [
          {
            name: "svn:mergeinfo",
            value: "/trunk:1-12*,15\n/branches/release:14",
            valueEncoding: "utf8",
          },
        ],
      }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      propertiesClient,
    });

    await controller.showRepositoryMergeinfo();

    expect(propertiesClient.listProperties).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: ".",
    });
    expect(ui.showTextDocument).toHaveBeenCalledWith({
      title: "SVN Mergeinfo: C:\\workspace",
      language: "markdown",
      content:
        "SVN mergeinfo for C:\\workspace\n\n" +
        "| SVN mergeinfo path | SVN property source | SVN mergeinfo source path count | SVN mergeinfo revision range count | SVN mergeinfo non-inheritable range count | SVN mergeinfo unparsed revision range count | SVN mergeinfo unparsed line count |\n" +
        "| --- | --- | --- | --- | --- | --- | --- |\n" +
        "| . | libsvn-local | 2 | 3 | 1 | 0 | 0 |\n\n" +
        "| Source path | SVN mergeinfo source revision range count | Latest merged revision | SVN mergeinfo non-inheritable range count | Revision ranges |\n" +
        "| --- | --- | --- | --- | --- |\n" +
        "| /trunk | 2 | r15 | 1 | 1-12*,15 |\n" +
        "| /branches/release | 1 | r14 | 0 | 14 |\n\n" +
        "| Source path | SVN mergeinfo range start revision | SVN mergeinfo range end revision | Non-inheritable SVN mergeinfo range |\n" +
        "| --- | --- | --- | --- |\n" +
        "| /trunk | r1 | r12 | Yes |\n" +
        "| /trunk | r15 | r15 | No |\n" +
        "| /branches/release | r14 | r14 | No |\n\n" +
        "Raw svn:mergeinfo\n\n" +
        "```text\n" +
        "/trunk:1-12*,15\n" +
        "/branches/release:14\n" +
        "```",
    });
  });

  it("shows repository root SVN mergeinfo for a repository id command argument without prompting", async () => {
    const first = repositorySession();
    const second = repositorySession({
      repositoryId: "repo-uuid:D:/other-wc",
      workingCopyRoot: "D:\\other-wc",
    });
    const sessionService = fakeSessionService({ sessions: [first, second] });
    const propertiesClient = fakePropertiesClient(
      propertiesResponse({
        path: ".",
        properties: [{ name: "svn:mergeinfo", value: "/trunk:1-3", valueEncoding: "utf8" }],
      }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace", "D:\\other-wc"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      propertiesClient,
    });

    await (controller as unknown as { showRepositoryMergeinfo(repositoryId?: unknown): Promise<void> })
      .showRepositoryMergeinfo("repo-uuid:D:/other-wc");

    expect(ui.pickOpenRepository).not.toHaveBeenCalled();
    expect(propertiesClient.listProperties).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:D:/other-wc",
      epoch: 7,
      path: ".",
    });
    expect(ui.showTextDocument).toHaveBeenCalledWith(
      expect.objectContaining({ title: "SVN Mergeinfo: D:\\other-wc" }),
    );
  });

  it("shows unparsed SVN mergeinfo lines separately from parsed source paths", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const propertiesClient = fakePropertiesClient(
      propertiesResponse({
        path: ".",
        properties: [
          {
            name: "svn:mergeinfo",
            value: "/trunk:1-12*\nmissing-range:\njust-text\n/branches/release:14,bad-range,16-18*",
            valueEncoding: "utf8",
          },
        ],
      }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      propertiesClient,
    });

    await controller.showRepositoryMergeinfo();

    expect(ui.showTextDocument).toHaveBeenCalledWith({
      title: "SVN Mergeinfo: C:\\workspace",
      language: "markdown",
      content:
        "SVN mergeinfo for C:\\workspace\n\n" +
        "| SVN mergeinfo path | SVN property source | SVN mergeinfo source path count | SVN mergeinfo revision range count | SVN mergeinfo non-inheritable range count | SVN mergeinfo unparsed revision range count | SVN mergeinfo unparsed line count |\n" +
        "| --- | --- | --- | --- | --- | --- | --- |\n" +
        "| . | libsvn-local | 2 | 4 | 2 | 1 | 2 |\n\n" +
        "| Source path | SVN mergeinfo source revision range count | Latest merged revision | SVN mergeinfo non-inheritable range count | Revision ranges |\n" +
        "| --- | --- | --- | --- | --- |\n" +
        "| /trunk | 1 | r12 | 1 | 1-12* |\n" +
        "| /branches/release | 3 |  | 1 | 14,bad-range,16-18* |\n\n" +
        "| Source path | SVN mergeinfo range start revision | SVN mergeinfo range end revision | Non-inheritable SVN mergeinfo range |\n" +
        "| --- | --- | --- | --- |\n" +
        "| /trunk | r1 | r12 | Yes |\n" +
        "| /branches/release | r14 | r14 | No |\n" +
        "| /branches/release | r16 | r18 | Yes |\n\n" +
        "| Source path | Unparsed svn:mergeinfo revision range |\n" +
        "| --- | --- |\n" +
        "| /branches/release | bad-range |\n\n" +
        "| Unparsed svn:mergeinfo line |\n" +
        "| --- |\n" +
        "| missing-range: |\n" +
        "| just-text |\n\n" +
        "Raw svn:mergeinfo\n\n" +
        "```text\n" +
        "/trunk:1-12*\n" +
        "missing-range:\n" +
        "just-text\n" +
        "/branches/release:14,bad-range,16-18*\n" +
        "```",
    });
  });

  it("shows an explicit parsed source path empty state when SVN mergeinfo only has unparsed lines", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const propertiesClient = fakePropertiesClient(
      propertiesResponse({
        path: ".",
        properties: [
          {
            name: "svn:mergeinfo",
            value: "missing-range:\njust-text",
            valueEncoding: "utf8",
          },
        ],
      }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      propertiesClient,
    });

    await controller.showRepositoryMergeinfo();

    expect(ui.showTextDocument).toHaveBeenCalledWith({
      title: "SVN Mergeinfo: C:\\workspace",
      language: "markdown",
      content:
        "SVN mergeinfo for C:\\workspace\n\n" +
        "| SVN mergeinfo path | SVN property source | SVN mergeinfo source path count | SVN mergeinfo revision range count | SVN mergeinfo non-inheritable range count | SVN mergeinfo unparsed revision range count | SVN mergeinfo unparsed line count |\n" +
        "| --- | --- | --- | --- | --- | --- | --- |\n" +
        "| . | libsvn-local | 0 | 0 | 0 | 0 | 2 |\n\n" +
        "| Source path | SVN mergeinfo source revision range count | Latest merged revision | SVN mergeinfo non-inheritable range count | Revision ranges |\n" +
        "| --- | --- | --- | --- | --- |\n" +
        "| No parsed SVN mergeinfo source paths. | 0 |  | 0 |  |\n\n" +
        "| Unparsed svn:mergeinfo line |\n" +
        "| --- |\n" +
        "| missing-range: |\n" +
        "| just-text |\n\n" +
        "Raw svn:mergeinfo\n\n" +
        "```text\n" +
        "missing-range:\n" +
        "just-text\n" +
        "```",
    });
  });

  it("reports when repository root has no SVN mergeinfo", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const propertiesClient = fakePropertiesClient(propertiesResponse({ path: "." }));
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      propertiesClient,
    });

    await controller.showRepositoryMergeinfo();

    expect(propertiesClient.listProperties).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: ".",
    });
    expect(ui.showTextDocument).not.toHaveBeenCalled();
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "No SVN mergeinfo found on working copy root: C:\\workspace",
    );
  });

  it("shows repository root SVN properties from libsvn properties", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const propertiesClient = fakePropertiesClient(
      propertiesResponse({
        path: ".",
        properties: [
          { name: "bugtraq:number", value: "SR-42", valueEncoding: "utf8" },
          { name: "svn:ignore", value: "node_modules\n.DS_Store", valueEncoding: "utf8" },
        ],
      }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      propertiesClient,
    });

    await controller.showRepositoryProperties();

    expect(propertiesClient.listProperties).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: ".",
    });
    expect(ui.showTextDocument).toHaveBeenCalledWith({
      title: "SVN Properties: C:\\workspace",
      language: "markdown",
      content:
        "SVN properties for C:\\workspace\n\n" +
        "| SVN property path | SVN property source | SVN property count |\n" +
        "| --- | --- | --- |\n" +
        "| . | libsvn-local | 2 |\n\n" +
        "| SVN property name | SVN property value |\n" +
        "| --- | --- |\n" +
        "| bugtraq:number | SR-42 |\n" +
        "| svn:ignore | node_modules<br>.DS_Store |",
    });
  });

  it("shows repository root SVN properties for a repository id command argument without prompting", async () => {
    const first = repositorySession();
    const second = repositorySession({
      repositoryId: "repo-uuid:D:/other-wc",
      workingCopyRoot: "D:\\other-wc",
    });
    const sessionService = fakeSessionService({ sessions: [first, second] });
    const propertiesClient = fakePropertiesClient(
      propertiesResponse({
        path: ".",
        properties: [{ name: "bugtraq:number", value: "SR-42", valueEncoding: "utf8" }],
      }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace", "D:\\other-wc"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      propertiesClient,
    });

    await (controller as unknown as { showRepositoryProperties(repositoryId?: unknown): Promise<void> })
      .showRepositoryProperties("repo-uuid:D:/other-wc");

    expect(ui.pickOpenRepository).not.toHaveBeenCalled();
    expect(propertiesClient.listProperties).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:D:/other-wc",
      epoch: 7,
      path: ".",
    });
    expect(ui.showTextDocument).toHaveBeenCalledWith(
      expect.objectContaining({ title: "SVN Properties: D:\\other-wc" }),
    );
  });

  it("reports when repository root has no SVN properties", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const propertiesClient = fakePropertiesClient(propertiesResponse({ path: "." }));
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      propertiesClient,
    });

    await controller.showRepositoryProperties();

    expect(propertiesClient.listProperties).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: ".",
    });
    expect(ui.showTextDocument).not.toHaveBeenCalled();
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "No SVN properties found on working copy root: C:\\workspace",
    );
  });

  it("shows selected SVN resource mergeinfo from libsvn properties", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const propertiesClient = fakePropertiesClient(
      propertiesResponse({
        path: "src/main.c",
        properties: [
          {
            name: "svn:mergeinfo",
            value: "/branches/feature/src/main.c:3-9*",
            valueEncoding: "utf8",
          },
        ],
      }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      propertiesClient,
    });

    await controller.showResourceMergeinfo({
      contextValue: "subversionr.changedFile",
      resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
      resourceKind: "file",
    });

    expect(propertiesClient.listProperties).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: "src/main.c",
    });
    expect(ui.showTextDocument).toHaveBeenCalledWith({
      title: "SVN Mergeinfo: src/main.c",
      language: "markdown",
      content:
        "SVN mergeinfo for src/main.c\n\n" +
        "| SVN mergeinfo path | SVN property source | SVN mergeinfo source path count | SVN mergeinfo revision range count | SVN mergeinfo non-inheritable range count | SVN mergeinfo unparsed revision range count | SVN mergeinfo unparsed line count |\n" +
        "| --- | --- | --- | --- | --- | --- | --- |\n" +
        "| src/main.c | libsvn-local | 1 | 1 | 1 | 0 | 0 |\n\n" +
        "| Source path | SVN mergeinfo source revision range count | Latest merged revision | SVN mergeinfo non-inheritable range count | Revision ranges |\n" +
        "| --- | --- | --- | --- | --- |\n" +
        "| /branches/feature/src/main.c | 1 | r9 | 1 | 3-9* |\n\n" +
        "| Source path | SVN mergeinfo range start revision | SVN mergeinfo range end revision | Non-inheritable SVN mergeinfo range |\n" +
        "| --- | --- | --- | --- |\n" +
        "| /branches/feature/src/main.c | r3 | r9 | Yes |\n\n" +
        "Raw svn:mergeinfo\n\n" +
        "```text\n" +
        "/branches/feature/src/main.c:3-9*\n" +
        "```",
    });
  });

  it("shows editor SVN resource mergeinfo using the projection canonical path", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const propertiesClient = fakePropertiesClient(
      propertiesResponse({
        path: "src/main.c",
        properties: [
          {
            name: "svn:mergeinfo",
            value: "/branches/feature/src/main.c:3-9*",
            valueEncoding: "utf8",
          },
        ],
      }),
    );
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        resources: [scmProjectedResource({ path: "src/main.c" })],
      }),
    });
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      propertiesClient,
      sourceControlProjection,
    });

    await controller.showResourceMergeinfo({ scheme: "file", fsPath: "C:\\workspace\\SRC\\MAIN.C" });

    expect(sourceControlProjection.getProjection).toHaveBeenCalledWith("repo-uuid:C:/workspace");
    expect(propertiesClient.listProperties).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: "src/main.c",
    });
    expect(ui.showTextDocument).toHaveBeenCalledWith(
      expect.objectContaining({
        title: "SVN Mergeinfo: src/main.c",
        content: expect.stringContaining("SVN mergeinfo for src/main.c"),
      }),
    );
  });

  it("reports when selected SVN resource has no mergeinfo", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const propertiesClient = fakePropertiesClient(propertiesResponse({ path: "src/main.c" }));
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      propertiesClient,
    });

    await controller.showResourceMergeinfo({
      contextValue: "subversionr.changedFile",
      resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
      resourceKind: "file",
    });

    expect(propertiesClient.listProperties).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: "src/main.c",
    });
    expect(ui.showTextDocument).not.toHaveBeenCalled();
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "No SVN mergeinfo found on SVN path: src/main.c",
    );
  });

  it("shows selected SVN resource properties from libsvn", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const propertiesClient = fakePropertiesClient(
      propertiesResponse({
        path: "src/main.c",
        properties: [
          { name: "bugtraq:number", value: "SR-42", valueEncoding: "utf8" },
          { name: "svn:eol-style", value: "native", valueEncoding: "utf8" },
        ],
      }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      propertiesClient,
    });

    await controller.showResourceProperties({
      contextValue: "subversionr.changedFile",
      resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
      resourceKind: "file",
    });

    expect(propertiesClient.listProperties).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: "src/main.c",
    });
    expect(ui.showTextDocument).toHaveBeenCalledWith({
      title: "SVN Properties: src/main.c",
      language: "markdown",
      content:
        "SVN properties for src/main.c\n\n" +
        "| SVN property path | SVN property source | SVN property count |\n" +
        "| --- | --- | --- |\n" +
        "| src/main.c | libsvn-local | 2 |\n\n" +
        "| SVN property name | SVN property value |\n" +
        "| --- | --- |\n" +
        "| bugtraq:number | SR-42 |\n" +
        "| svn:eol-style | native |",
    });
  });

  it("shows selected SVN resource properties from an editor URI", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const propertiesClient = fakePropertiesClient(
      propertiesResponse({
        path: "src/main.c",
        properties: [{ name: "svn:eol-style", value: "native", valueEncoding: "utf8" }],
      }),
    );
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        resources: [scmProjectedResource({ path: "src/main.c" })],
      }),
    });
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      propertiesClient,
      sourceControlProjection,
    });

    await controller.showResourceProperties({ scheme: "file", fsPath: "C:\\workspace\\SRC\\MAIN.C" });

    expect(sourceControlProjection.getProjection).toHaveBeenCalledWith("repo-uuid:C:/workspace");
    expect(propertiesClient.listProperties).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: "src/main.c",
    });
    expect(ui.showTextDocument).toHaveBeenCalledWith(
      expect.objectContaining({
        title: "SVN Properties: src/main.c",
        content: expect.stringContaining("SVN properties for src/main.c"),
      }),
    );
  });

  it("keeps multi-line SVN resource property values inside one Markdown table cell", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const propertiesClient = fakePropertiesClient(
      propertiesResponse({
        path: "src/main.c",
        properties: [{ name: "svn:ignore", value: "node_modules\n.DS_Store", valueEncoding: "utf8" }],
      }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      propertiesClient,
    });

    await controller.showResourceProperties({
      contextValue: "subversionr.changedFile",
      resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
      resourceKind: "file",
    });

    expect(ui.showTextDocument).toHaveBeenCalledWith(
      expect.objectContaining({
        content: expect.stringContaining("| svn:ignore | node_modules<br>.DS_Store |"),
      }),
    );
  });

  it("reports when selected SVN resource has no properties", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const propertiesClient = fakePropertiesClient(propertiesResponse({ path: "src/main.c" }));
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      propertiesClient,
    });

    await controller.showResourceProperties({
      contextValue: "subversionr.changedFile",
      resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
      resourceKind: "file",
    });

    expect(propertiesClient.listProperties).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: "src/main.c",
    });
    expect(ui.showTextDocument).not.toHaveBeenCalled();
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "No SVN properties found on SVN path: src/main.c",
    );
  });

  it("does not run branchCreate or switch when prompts are cancelled", async () => {
    const sessionService = fakeSessionService({ sessions: [repositorySession()] });
    const operationClient = fakeOperationClient(operationResponse());
    const branchUi = fakeCommandUi({ workspaceRoots: ["C:\\workspace"], branchCreateOptions: undefined });
    const switchUi = fakeCommandUi({ workspaceRoots: ["C:\\workspace"], switchOptions: undefined });

    await commandController(fakeDiscoveryService({ candidates: [] }), sessionService, branchUi, {
      operationClient,
    }).branchCreateRepository();
    await commandController(fakeDiscoveryService({ candidates: [] }), sessionService, switchUi, {
      operationClient,
    }).switchRepository();

    expect(operationClient.branchCreate).not.toHaveBeenCalled();
    expect(operationClient.switch).not.toHaveBeenCalled();
  });

  it("always runs full reconcile after update even if the backend returns targeted update hints", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({
        kind: "update",
        path: ".",
        revision: 8,
        reason: "operationUpdate",
      }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
    });

    await controller.updateRepository();

    expect(refreshService.fullReconcileRepository).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
    });
    expect(refreshService.refreshTargets).not.toHaveBeenCalled();
  });

  it("serializes repository update operations until their full reconcile completes", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(operationResponse({ kind: "update", path: ".", revision: 8 }));
    const operationScheduler = new RepositoryOperationScheduler();
    const firstUpdate = deferred<OperationRunResponse>();
    const firstReconcile = deferred<void>();
    const events: string[] = [];
    operationClient.update
      .mockImplementationOnce(async () => {
        events.push("update:1");
        return await firstUpdate.promise;
      })
      .mockImplementationOnce(async () => {
        events.push("update:2");
        return operationResponse({ kind: "update", path: ".", revision: 9 });
      });
    refreshService.fullReconcileRepository
      .mockImplementationOnce(async () => {
        events.push("reconcile:1");
        await firstReconcile.promise;
      })
      .mockImplementationOnce(async () => {
        events.push("reconcile:2");
      });
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
      operationScheduler,
    });

    const first = controller.updateRepository();
    await flushMicrotasks();
    expect(events).toEqual(["update:1"]);

    firstUpdate.resolve(
      operationResponse({
        kind: "update",
        path: ".",
        revision: 8,
        reconcile: { targets: [], requiresFullReconcile: true },
      }),
    );
    await flushMicrotasks();
    await flushMicrotasks();
    expect(events).toEqual(["update:1", "reconcile:1"]);

    const second = controller.updateRepository();
    await flushMicrotasks();
    expect(events).toEqual(["update:1", "reconcile:1"]);

    firstReconcile.resolve();

    await Promise.all([first, second]);
    expect(events).toEqual(["update:1", "reconcile:1", "update:2", "reconcile:2"]);
  });

  it("reports no open repository before running update", async () => {
    const sessionService = fakeSessionService({ sessions: [] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(operationResponse({ kind: "update", path: ".", revision: 8 }));
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
    });

    await controller.updateRepository();

    expect(operationClient.update).not.toHaveBeenCalled();
    expect(refreshService.fullReconcileRepository).not.toHaveBeenCalled();
    expect(ui.showWarningMessage).toHaveBeenCalledWith("No SVN repository is open.");
  });

  it.each([
    ["checkout repository", (controller: RepositoryCommandController) => controller.checkoutRepository()],
    ["cleanup repository", (controller: RepositoryCommandController) => controller.cleanupRepository()],
    ["update repository", (controller: RepositoryCommandController) => controller.updateRepository()],
    [
      "update selected incoming resource",
      (controller: RepositoryCommandController) =>
        controller.updateResource({
          contextValue: "subversionr.incoming",
          resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
        }),
    ],
    [
      "revert selected resource",
      (controller: RepositoryCommandController) =>
        controller.revertResource({
          contextValue: "subversionr.changedFile",
          resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
        }),
    ],
    [
      "update all incoming resources",
      (controller: RepositoryCommandController) =>
        (controller as unknown as { updateAllIncoming(commandArgument?: unknown): Promise<void> })
          .updateAllIncoming("repo-uuid:C:/workspace"),
    ],
    [
      "add selected unversioned resource",
      (controller: RepositoryCommandController) =>
        controller.addResource({
          contextValue: "subversionr.unversioned",
          resourceUri: { fsPath: "C:\\workspace\\scratch.txt" },
        }),
    ],
    [
      "remove selected resource",
      (controller: RepositoryCommandController) =>
        controller.removeResource({
          contextValue: "subversionr.changedFile",
          resourceUri: { fsPath: "C:\\workspace\\src\\old.c" },
        }),
    ],
    [
      "resolve selected conflict",
      (controller: RepositoryCommandController) =>
        controller.resolveResource({
          contextValue: "subversionr.conflicted",
          resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
        }),
    ],
    [
      "commit selected resource",
      (controller: RepositoryCommandController) =>
        controller.commitResource({
          contextValue: "subversionr.changedFile",
          subversionrResourceKind: "file",
          resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
        }),
    ],
    [
      "set selected resource changelist",
      (controller: RepositoryCommandController) =>
        controller.setResourceChangelist({
          contextValue: "subversionr.changedFile",
          resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
        }),
    ],
    [
      "clear selected resource changelist",
      (controller: RepositoryCommandController) =>
        controller.clearResourceChangelist({
          contextValue: "subversionr.changedFile.changelisted",
          resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
        }),
    ],
    [
      "lock selected resource",
      (controller: RepositoryCommandController) =>
        controller.lockResource({
          contextValue: "subversionr.changedFile",
          resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
        }),
    ],
    [
      "unlock selected resource",
      (controller: RepositoryCommandController) =>
        controller.unlockResource({
          contextValue: "subversionr.changedFile",
          resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
        }),
    ],
    ["commit all resources", (controller: RepositoryCommandController) => controller.commitAll("repo-uuid:C:/workspace")],
    ["create branch or tag", (controller: RepositoryCommandController) => controller.branchCreateRepository()],
    ["switch repository", (controller: RepositoryCommandController) => controller.switchRepository()],
    ["relocate repository", (controller: RepositoryCommandController) => controller.relocateRepository()],
    [
      "commit changelist",
      (controller: RepositoryCommandController) =>
        controller.commitChangelist({
          subversionrRepositoryId: "repo-uuid:C:/workspace",
          subversionrChangelistName: "review",
        }),
    ],
    [
      "revert changelist",
      (controller: RepositoryCommandController) =>
        controller.revertChangelist({
          subversionrRepositoryId: "repo-uuid:C:/workspace",
          subversionrChangelistName: "review",
        }),
    ],
    ["revert all resources", (controller: RepositoryCommandController) => controller.revertAll("repo-uuid:C:/workspace")],
  ])("blocks %s in untrusted workspaces before operation side effects", async (_label, invoke) => {
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(operationResponse({ kind: "update", path: ".", revision: 8 }));
    const checkoutClient = fakeCheckoutClient();
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace"],
      workspaceTrusted: false,
      commitMessage: "commit message",
    });
    const controller = commandController(
      fakeDiscoveryService({ candidates: [discoveryCandidate()] }),
      fakeSessionService({ sessions: [repositorySession()] }),
      ui,
      {
        refreshService,
        operationClient,
        checkoutClient,
        sourceControlProjection: fakeSourceControlProjection(),
      },
    );

    await invoke(controller);

    expect(checkoutClient.checkout).not.toHaveBeenCalled();
    expect(operationClient.add).not.toHaveBeenCalled();
    expect(operationClient.branchCreate).not.toHaveBeenCalled();
    expect(operationClient.changelistClear).not.toHaveBeenCalled();
    expect(operationClient.changelistSet).not.toHaveBeenCalled();
    expect(operationClient.cleanup).not.toHaveBeenCalled();
    expect(operationClient.commit).not.toHaveBeenCalled();
    expect(operationClient.lock).not.toHaveBeenCalled();
    expect(operationClient.remove).not.toHaveBeenCalled();
    expect(operationClient.resolve).not.toHaveBeenCalled();
    expect(operationClient.revert).not.toHaveBeenCalled();
    expect(operationClient.switch).not.toHaveBeenCalled();
    expect(operationClient.unlock).not.toHaveBeenCalled();
    expect(operationClient.upgrade).not.toHaveBeenCalled();
    expect(operationClient.update).not.toHaveBeenCalled();
    expect(refreshService.refreshTargets).not.toHaveBeenCalled();
    expect(refreshService.fullReconcileRepository).not.toHaveBeenCalled();
    expect(ui.confirmRevertResource).not.toHaveBeenCalled();
    expect(ui.confirmRemoveResource).not.toHaveBeenCalled();
    expect(ui.promptResolveChoice).not.toHaveBeenCalled();
    expect(ui.promptChangelistName).not.toHaveBeenCalled();
    expect(ui.promptLockOptions).not.toHaveBeenCalled();
    expect(ui.promptUnlockOptions).not.toHaveBeenCalled();
    expect(ui.commitMessage).not.toHaveBeenCalled();
    expect(ui.clearCommitMessage).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_WORKSPACE_UNTRUSTED_OPERATION",
    );
  });

  it("keeps local read-only status and BASE content commands available in untrusted workspaces", async () => {
    const refreshService = fakeRefreshService();
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace"],
      workspaceTrusted: false,
    });
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        resources: [scmProjectedResource({ path: "src/main.c", localStatus: "modified", textStatus: "modified" })],
      }),
    });
    const controller = commandController(
      fakeDiscoveryService({ candidates: [discoveryCandidate()] }),
      fakeSessionService({ sessions: [repositorySession()] }),
      ui,
      {
        refreshService,
        sourceControlProjection,
      },
    );
    const resourceState = {
      contextValue: "subversionr.changedFile.baseDiffable",
      resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
    };

    await controller.refreshRepository();
    await controller.refreshResource(resourceState);
    await controller.diffWithBaseResource(resourceState);
    await controller.openBaseResource(resourceState);

    expect(refreshService.refreshRepository).toHaveBeenCalledWith("repo-uuid:C:/workspace");
    expect(refreshService.refreshResource).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: "src/main.c",
    });
    expect(ui.diffWithBase).toHaveBeenCalledWith(
      expect.objectContaining({ scheme: "svn-r-base" }),
      { fsPath: "C:/workspace/src/main.c" },
      "SVN BASE <-> Working Copy: src/main.c",
    );
    expect(ui.openBase).toHaveBeenCalledWith(
      expect.objectContaining({ scheme: "svn-r-base" }),
      "SVN BASE: src/main.c",
    );
    expect(ui.workspaceTrusted).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).not.toHaveBeenCalled();
  });

  it.each([
    [
      "diff with HEAD",
      (controller: RepositoryCommandController) =>
        controller.diffWithHeadResource({
          contextValue: "subversionr.changedFile.baseDiffable",
          resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
        }),
    ],
    [
      "open HEAD",
      (controller: RepositoryCommandController) =>
        controller.openHeadResource({
          contextValue: "subversionr.changedFile.baseDiffable",
          resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
        }),
    ],
    [
      "diff with PREV",
      (controller: RepositoryCommandController) =>
        controller.diffWithPreviousResource({
          contextValue: "subversionr.changedFile",
          resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
        }),
    ],
    ["repository log", (controller: RepositoryCommandController) => controller.showRepositoryLog("repo-uuid:C:/workspace")],
    [
      "file history",
      (controller: RepositoryCommandController) =>
        controller.showFileHistoryResource({
          contextValue: "subversionr.changedFile",
          resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
        }),
    ],
    [
      "file blame",
      (controller: RepositoryCommandController) =>
        controller.showBlameResource({
          contextValue: "subversionr.changedFile",
          resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
        }),
    ],
  ])("blocks %s in untrusted workspaces before remote read side effects", async (_label, invoke) => {
    const historyClient = fakeHistoryClient(historyLog());
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        resources: [scmProjectedResource({ path: "src/main.c", localStatus: "modified", textStatus: "modified" })],
      }),
    });
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace"],
      workspaceTrusted: false,
    });
    const controller = commandController(
      fakeDiscoveryService({ candidates: [discoveryCandidate()] }),
      fakeSessionService({ sessions: [repositorySession()] }),
      ui,
      {
        historyClient,
        sourceControlProjection,
      },
    );

    await invoke(controller);

    expect(historyClient.getLog).not.toHaveBeenCalled();
    expect(sourceControlProjection.getProjection).not.toHaveBeenCalled();
    expect(ui.diffWithHead).not.toHaveBeenCalled();
    expect(ui.openHead).not.toHaveBeenCalled();
    expect(ui.diffRevisions).not.toHaveBeenCalled();
    expect(ui.showHistory).not.toHaveBeenCalled();
    expect(ui.showBlame).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_WORKSPACE_UNTRUSTED_OPERATION",
    );
  });

  it("updates a selected incoming SVN resource and performs a full reconcile", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({
        kind: "update",
        path: "src/main.c",
        revision: 9,
        reconcile: {
          targets: [{ path: "src/main.c", depth: "empty", reason: "operationUpdate" }],
          requiresFullReconcile: false,
        },
      }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
    });

    await controller.updateResource({
      contextValue: "subversionr.incoming",
      resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
    });

    expect(operationClient.update).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: "src/main.c",
      revision: "head",
      depth: "workingCopy",
      depthIsSticky: false,
      ignoreExternals: true,
    });
    expect(refreshService.fullReconcileRepository).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
    });
    expect(refreshService.refreshTargets).not.toHaveBeenCalled();
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR updated SVN resource to revision 9: src/main.c",
    );
  });

  it("updates a selected locked incoming SVN resource and performs a full reconcile", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({
        kind: "update",
        path: "src/main.c",
        revision: 9,
        reconcile: {
          targets: [{ path: "src/main.c", depth: "empty", reason: "operationUpdate" }],
          requiresFullReconcile: false,
        },
      }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
    });

    await controller.updateResource({
      contextValue: "subversionr.incoming.locked",
      resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
    });

    expect(operationClient.update).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: "src/main.c",
      revision: "head",
      depth: "workingCopy",
      depthIsSticky: false,
      ignoreExternals: true,
    });
    expect(refreshService.fullReconcileRepository).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
    });
    expect(refreshService.refreshTargets).not.toHaveBeenCalled();
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR updated SVN resource to revision 9: src/main.c",
    );
  });

  it("updates all incoming SVN resources for a repository group and performs one full reconcile", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        resources: [
          scmIncomingProjectedResource({ path: "src/module" }),
          scmIncomingProjectedResource({ path: "src/main.c" }),
        ],
      }),
    });
    const operationClient = fakeOperationClient(operationResponse({ kind: "update", path: "src/main.c", revision: 9 }));
    operationClient.update
      .mockResolvedValueOnce(operationResponse({ kind: "update", path: "src/main.c", revision: 9 }))
      .mockResolvedValueOnce(operationResponse({ kind: "update", path: "src/module", revision: 9 }));
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
      sourceControlProjection,
    });

    await (controller as unknown as { updateAllIncoming(commandArgument?: unknown): Promise<void> })
      .updateAllIncoming({
        subversionrRepositoryId: "repo-uuid:C:/workspace",
      });

    expect(operationClient.update).toHaveBeenNthCalledWith(1, {
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: "src/main.c",
      revision: "head",
      depth: "workingCopy",
      depthIsSticky: false,
      ignoreExternals: true,
    });
    expect(operationClient.update).toHaveBeenNthCalledWith(2, {
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: "src/module",
      revision: "head",
      depth: "workingCopy",
      depthIsSticky: false,
      ignoreExternals: true,
    });
    expect(refreshService.fullReconcileRepository).toHaveBeenCalledTimes(1);
    expect(refreshService.fullReconcileRepository).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
    });
    expect(refreshService.refreshTargets).not.toHaveBeenCalled();
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR updated 2 incoming SVN resources: src/main.c, src/module",
    );
  });

  it("does not update the repository root when updating all incoming SVN resources", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        resources: [
          scmIncomingProjectedResource({ path: ".", kind: "dir" }),
          scmIncomingProjectedResource({ path: "src/main.c" }),
        ],
      }),
    });
    const operationClient = fakeOperationClient(operationResponse({ kind: "update", path: "src/main.c", revision: 9 }));
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
      sourceControlProjection,
    });

    await (controller as unknown as { updateAllIncoming(commandArgument?: unknown): Promise<void> })
      .updateAllIncoming("repo-uuid:C:/workspace");

    expect(operationClient.update).toHaveBeenCalledTimes(1);
    expect(operationClient.update).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: "src/main.c",
      revision: "head",
      depth: "workingCopy",
      depthIsSticky: false,
      ignoreExternals: true,
    });
    expect(refreshService.fullReconcileRepository).toHaveBeenCalledTimes(1);
  });

  it("warns without running update when there are no incoming SVN resources", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const sourceControlProjection = fakeSourceControlProjection({ projection: scmProjection({ resources: [] }) });
    const operationClient = fakeOperationClient(operationResponse({ kind: "update", path: "src/main.c", revision: 9 }));
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
      sourceControlProjection,
    });

    await (controller as unknown as { updateAllIncoming(commandArgument?: unknown): Promise<void> })
      .updateAllIncoming("repo-uuid:C:/workspace");

    expect(operationClient.update).not.toHaveBeenCalled();
    expect(refreshService.fullReconcileRepository).not.toHaveBeenCalled();
    expect(ui.showWarningMessage).toHaveBeenCalledWith("No incoming SVN resources to update.");
  });

  it("rejects non-incoming SCM resources for selected update", async () => {
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(operationResponse({ kind: "update", path: "src/main.c", revision: 9 }));
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      refreshService,
      operationClient,
    });

    await controller.updateResource({
      contextValue: "subversionr.changedFile",
      resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
    });

    expect(operationClient.update).not.toHaveBeenCalled();
    expect(refreshService.fullReconcileRepository).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_RESOURCE_UPDATE_TARGET_INVALID",
    );
  });

  it("rejects repository root resources for selected update", async () => {
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(operationResponse({ kind: "update", path: ".", revision: 9 }));
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      refreshService,
      operationClient,
    });

    await controller.updateResource({
      contextValue: "subversionr.incoming",
      resourceUri: { fsPath: "C:\\workspace" },
    });

    expect(operationClient.update).not.toHaveBeenCalled();
    expect(refreshService.fullReconcileRepository).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_RESOURCE_UPDATE_TARGET_INVALID",
    );
  });

  it("rejects multi-resource selection for selected update", async () => {
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(operationResponse({ kind: "update", path: "src/main.c", revision: 9 }));
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      refreshService,
      operationClient,
    });

    await controller.updateResource([
      {
        contextValue: "subversionr.incoming",
        resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
      },
      {
        contextValue: "subversionr.incoming",
        resourceUri: { fsPath: "C:\\workspace\\src\\other.c" },
      },
    ]);

    expect(operationClient.update).not.toHaveBeenCalled();
    expect(refreshService.fullReconcileRepository).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_RESOURCE_UPDATE_TARGET_INVALID",
    );
  });

  it("rejects selected update resources outside every open repository", async () => {
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(operationResponse({ kind: "update", path: "src/main.c", revision: 9 }));
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      refreshService,
      operationClient,
    });

    await controller.updateResource({
      contextValue: "subversionr.incoming",
      resourceUri: { fsPath: "D:\\outside\\src\\main.c" },
    });

    expect(operationClient.update).not.toHaveBeenCalled();
    expect(refreshService.fullReconcileRepository).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_RESOURCE_UPDATE_TARGET_OUTSIDE_REPOSITORY",
    );
  });

  it("opens a BASE diff for a selected changed SVN file using the projection canonical path", async () => {
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        resources: [scmProjectedResource({ path: "src/main.c", localStatus: "modified", textStatus: "modified" })],
      }),
    });
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      sourceControlProjection,
    });

    await controller.diffWithBaseResource({
      contextValue: "subversionr.changedFile.baseDiffable",
      resourceUri: { fsPath: "C:\\workspace\\SRC\\MAIN.C" },
    });

    expect(sourceControlProjection.getProjection).toHaveBeenCalledWith("repo-uuid:C:/workspace");
    expect(ui.uriFromComponents).toHaveBeenCalledWith({
      scheme: "svn-r-base",
      authority: "base",
      path: "/",
      query:
        "repositoryId=repo-uuid%3AC%3A%2Fworkspace&epoch=7&generation=11&path=src%2Fmain.c&revision=base",
    });
    expect(ui.uriFile).toHaveBeenCalledWith("C:/workspace/src/main.c");
    expect(ui.diffWithBase).toHaveBeenCalledWith(
      {
        scheme: "svn-r-base",
        authority: "base",
        path: "/",
        query:
          "repositoryId=repo-uuid%3AC%3A%2Fworkspace&epoch=7&generation=11&path=src%2Fmain.c&revision=base",
      },
      { fsPath: "C:/workspace/src/main.c" },
      "SVN BASE <-> Working Copy: src/main.c",
    );
  });

  it("runs advertised file inspection commands for a selected changelisted base-diffable SVN file", async () => {
    const resourceState = {
      contextValue: "subversionr.changedFile.baseDiffable.changelisted",
      subversionrResourceKind: "file",
      subversionrProjectionGeneration: 11,
      resourceUri: { fsPath: "C:\\workspace\\SRC\\REVIEW.C" },
    };
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        resources: [
          scmChangelistProjectedResource({
            path: "src/review.c",
            changedRevision: 3,
            localStatus: "modified",
            textStatus: "modified",
          }),
        ],
      }),
    });
    const historyClient = fakeHistoryClient(
      historyLog({
        path: "src/review.c",
        entries: [historyEntry(3), historyEntry(2)],
      }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(
      fakeDiscoveryService({ candidates: [discoveryCandidate()] }),
      fakeSessionService({ sessions: [repositorySession()] }),
      ui,
      {
        createRequestId: () => "11111111-1111-4111-8111-111111111111",
        historyClient,
        sourceControlProjection,
      },
    );

    await controller.diffWithBaseResource(resourceState);
    await controller.openBaseResource(resourceState);
    await controller.diffWithHeadResource(resourceState);
    await controller.openHeadResource(resourceState);
    await controller.diffWithPreviousResource(resourceState);
    await controller.showFileHistoryResource(resourceState);
    await controller.showBlameResource(resourceState);

    expect(ui.diffWithBase).toHaveBeenCalledWith(
      expect.objectContaining({ scheme: "svn-r-base" }),
      { fsPath: "C:/workspace/src/review.c" },
      "SVN BASE <-> Working Copy: src/review.c",
    );
    expect(ui.openBase).toHaveBeenCalledWith(
      expect.objectContaining({ scheme: "svn-r-base" }),
      "SVN BASE: src/review.c",
    );
    expect(ui.diffWithHead).toHaveBeenCalledWith(
      expect.objectContaining({ scheme: "svn-r-head" }),
      { fsPath: "C:/workspace/src/review.c" },
      "SVN HEAD <-> Working Copy: src/review.c",
    );
    expect(ui.openHead).toHaveBeenCalledWith(
      expect.objectContaining({ scheme: "svn-r-head" }),
      "SVN HEAD: src/review.c",
    );
    expect(historyClient.getLog).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: "src/review.c",
      startRevision: "r3",
      endRevision: "r0",
      limit: 2,
      discoverChangedPaths: false,
      strictNodeHistory: false,
      includeMergedRevisions: false,
    });
    expect(ui.diffRevisions).toHaveBeenCalledWith(
      expect.objectContaining({ scheme: "svn-r-revision" }),
      expect.objectContaining({ scheme: "svn-r-revision" }),
      "SVN PREV <-> Revision: src/review.c r2..r3",
    );
    expect(ui.showHistory).toHaveBeenCalledWith({
      kind: "file",
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: "src/review.c",
      label: "src/review.c",
    });
    expect(ui.showBlame).toHaveBeenCalledWith(
      expect.objectContaining({
        repositoryId: "repo-uuid:C:/workspace",
        epoch: 7,
        generation: 11,
        path: "src/review.c",
        label: "src/review.c",
      }),
    );
    expect(ui.showErrorMessage).not.toHaveBeenCalled();
  });

  it.each([
    [
      "conflicted",
      "subversionr.conflicted.changelisted",
      scmConflictedProjectedResource({ path: "src/review.c", changelist: "review" }),
    ],
    [
      "changed file",
      "subversionr.changedFile.changelisted",
      scmChangelistProjectedResource({ path: "src/review.c" }),
    ],
    [
      "base-diffable changed file",
      "subversionr.changedFile.baseDiffable.changelisted",
      scmChangelistProjectedResource({
        path: "src/review.c",
        localStatus: "modified",
        textStatus: "modified",
      }),
    ],
  ])(
    "opens file history and blame for a selected changelisted %s SCM resource",
    async (_label, contextValue, resource) => {
      const sourceControlProjection = fakeSourceControlProjection({
        projection: scmProjection({ resources: [resource] }),
      });
      const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
      const controller = commandController(
        fakeDiscoveryService({ candidates: [discoveryCandidate()] }),
        fakeSessionService({ sessions: [repositorySession()] }),
        ui,
        { sourceControlProjection },
      );
      const resourceState = {
        contextValue,
        subversionrResourceKind: "file",
        resourceUri: { fsPath: "C:\\workspace\\SRC\\REVIEW.C" },
      };

      await controller.showFileHistoryResource(resourceState);
      await controller.showBlameResource(resourceState);

      expect(ui.showHistory).toHaveBeenCalledWith({
        kind: "file",
        repositoryId: "repo-uuid:C:/workspace",
        epoch: 7,
        path: "src/review.c",
        label: "src/review.c",
      });
      expect(ui.showBlame).toHaveBeenCalledWith(
        expect.objectContaining({
          repositoryId: "repo-uuid:C:/workspace",
          epoch: 7,
          generation: 11,
          path: "src/review.c",
          label: "src/review.c",
        }),
      );
      expect(ui.showErrorMessage).not.toHaveBeenCalled();
    },
  );

  it("opens a BASE diff for an editor file URI using the projection canonical path", async () => {
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        resources: [scmProjectedResource({ path: "src/main.c", localStatus: "modified", textStatus: "modified" })],
      }),
    });
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      sourceControlProjection,
    });

    await controller.diffWithBaseResource({ scheme: "file", fsPath: "C:\\workspace\\SRC\\MAIN.C" });

    expect(sourceControlProjection.getProjection).toHaveBeenCalledWith("repo-uuid:C:/workspace");
    expect(ui.diffWithBase).toHaveBeenCalledWith(
      {
        scheme: "svn-r-base",
        authority: "base",
        path: "/",
        query:
          "repositoryId=repo-uuid%3AC%3A%2Fworkspace&epoch=7&generation=11&path=src%2Fmain.c&revision=base",
      },
      { fsPath: "C:/workspace/src/main.c" },
      "SVN BASE <-> Working Copy: src/main.c",
    );
  });

  it("opens BASE content for a selected changed SVN file using the projection canonical path", async () => {
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        resources: [scmProjectedResource({ path: "src/main.c", localStatus: "modified", textStatus: "modified" })],
      }),
    });
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      sourceControlProjection,
    });

    await controller.openBaseResource({
      contextValue: "subversionr.changedFile.baseDiffable",
      subversionrResourceKind: "file",
      resourceUri: { fsPath: "C:\\workspace\\SRC\\MAIN.C" },
    });

    expect(sourceControlProjection.getProjection).toHaveBeenCalledWith("repo-uuid:C:/workspace");
    expect(ui.uriFromComponents).toHaveBeenCalledWith({
      scheme: "svn-r-base",
      authority: "base",
      path: "/",
      query:
        "repositoryId=repo-uuid%3AC%3A%2Fworkspace&epoch=7&generation=11&path=src%2Fmain.c&revision=base",
    });
    expect(ui.openBase).toHaveBeenCalledWith(
      {
        scheme: "svn-r-base",
        authority: "base",
        path: "/",
        query:
          "repositoryId=repo-uuid%3AC%3A%2Fworkspace&epoch=7&generation=11&path=src%2Fmain.c&revision=base",
      },
      "SVN BASE: src/main.c",
    );
  });

  it("opens a HEAD diff for a selected changed SVN file using a fresh request identity", async () => {
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        resources: [scmProjectedResource({ path: "src/main.c", localStatus: "modified", textStatus: "modified" })],
      }),
    });
    const createRequestId = vi
      .fn()
      .mockReturnValueOnce("11111111-1111-4111-8111-111111111111")
      .mockReturnValueOnce("22222222-2222-4222-8222-222222222222");
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      createRequestId,
      sourceControlProjection,
    });

    await controller.diffWithHeadResource({
      contextValue: "subversionr.changedFile.baseDiffable",
      subversionrResourceKind: "file",
      resourceUri: { fsPath: "C:\\workspace\\SRC\\MAIN.C" },
    });
    await controller.diffWithHeadResource({
      contextValue: "subversionr.changedFile.baseDiffable",
      subversionrResourceKind: "file",
      resourceUri: { fsPath: "C:\\workspace\\SRC\\MAIN.C" },
    });

    expect(sourceControlProjection.getProjection).toHaveBeenCalledWith("repo-uuid:C:/workspace");
    expect(ui.uriFromComponents).toHaveBeenNthCalledWith(1, {
      scheme: "svn-r-head",
      authority: "head",
      path: "/",
      query:
        "repositoryId=repo-uuid%3AC%3A%2Fworkspace&epoch=7&generation=11&path=src%2Fmain.c&revision=head&requestId=11111111-1111-4111-8111-111111111111",
    });
    expect(ui.uriFromComponents).toHaveBeenNthCalledWith(2, {
      scheme: "svn-r-head",
      authority: "head",
      path: "/",
      query:
        "repositoryId=repo-uuid%3AC%3A%2Fworkspace&epoch=7&generation=11&path=src%2Fmain.c&revision=head&requestId=22222222-2222-4222-8222-222222222222",
    });
    expect(ui.uriFile).toHaveBeenCalledWith("C:/workspace/src/main.c");
    expect(ui.diffWithHead).toHaveBeenNthCalledWith(
      1,
      {
        scheme: "svn-r-head",
        authority: "head",
        path: "/",
        query:
          "repositoryId=repo-uuid%3AC%3A%2Fworkspace&epoch=7&generation=11&path=src%2Fmain.c&revision=head&requestId=11111111-1111-4111-8111-111111111111",
      },
      { fsPath: "C:/workspace/src/main.c" },
      "SVN HEAD <-> Working Copy: src/main.c",
    );
    expect(ui.diffWithHead).toHaveBeenNthCalledWith(
      2,
      {
        scheme: "svn-r-head",
        authority: "head",
        path: "/",
        query:
          "repositoryId=repo-uuid%3AC%3A%2Fworkspace&epoch=7&generation=11&path=src%2Fmain.c&revision=head&requestId=22222222-2222-4222-8222-222222222222",
      },
      { fsPath: "C:/workspace/src/main.c" },
      "SVN HEAD <-> Working Copy: src/main.c",
    );
  });

  it("opens HEAD content for a selected changed SVN file using the projection canonical path", async () => {
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        resources: [scmProjectedResource({ path: "src/main.c", localStatus: "modified", textStatus: "modified" })],
      }),
    });
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      createRequestId: () => "11111111-1111-4111-8111-111111111111",
      sourceControlProjection,
    });

    await controller.openHeadResource({
      contextValue: "subversionr.changedFile.baseDiffable",
      subversionrResourceKind: "file",
      resourceUri: { fsPath: "C:\\workspace\\SRC\\MAIN.C" },
    });

    expect(sourceControlProjection.getProjection).toHaveBeenCalledWith("repo-uuid:C:/workspace");
    expect(ui.uriFromComponents).toHaveBeenCalledWith({
      scheme: "svn-r-head",
      authority: "head",
      path: "/",
      query:
        "repositoryId=repo-uuid%3AC%3A%2Fworkspace&epoch=7&generation=11&path=src%2Fmain.c&revision=head&requestId=11111111-1111-4111-8111-111111111111",
    });
    expect(ui.openHead).toHaveBeenCalledWith(
      {
        scheme: "svn-r-head",
        authority: "head",
        path: "/",
        query:
          "repositoryId=repo-uuid%3AC%3A%2Fworkspace&epoch=7&generation=11&path=src%2Fmain.c&revision=head&requestId=11111111-1111-4111-8111-111111111111",
      },
      "SVN HEAD: src/main.c",
    );
  });

  it("opens a HEAD diff for a selected incoming SVN file using the projection canonical path", async () => {
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        resources: [scmIncomingProjectedResource({ path: "src/incoming.c" })],
      }),
    });
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      createRequestId: () => "11111111-1111-4111-8111-111111111111",
      sourceControlProjection,
    });

    await controller.diffWithHeadResource({
      contextValue: "subversionr.incomingFile",
      subversionrResourceKind: "file",
      resourceUri: { fsPath: "C:\\workspace\\SRC\\INCOMING.C" },
    });

    expect(sourceControlProjection.getProjection).toHaveBeenCalledWith("repo-uuid:C:/workspace");
    expect(ui.uriFromComponents).toHaveBeenCalledWith({
      scheme: "svn-r-head",
      authority: "head",
      path: "/",
      query:
        "repositoryId=repo-uuid%3AC%3A%2Fworkspace&epoch=7&generation=11&path=src%2Fincoming.c&revision=head&requestId=11111111-1111-4111-8111-111111111111",
    });
    expect(ui.uriFile).toHaveBeenCalledWith("C:/workspace/src/incoming.c");
    expect(ui.diffWithHead).toHaveBeenCalledWith(
      {
        scheme: "svn-r-head",
        authority: "head",
        path: "/",
        query:
          "repositoryId=repo-uuid%3AC%3A%2Fworkspace&epoch=7&generation=11&path=src%2Fincoming.c&revision=head&requestId=11111111-1111-4111-8111-111111111111",
      },
      { fsPath: "C:/workspace/src/incoming.c" },
      "SVN HEAD <-> Working Copy: src/incoming.c",
    );
  });

  it("opens HEAD content for a selected incoming locked SVN file", async () => {
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        resources: [
          scmIncomingProjectedResource({
            path: "src/locked.c",
            lock: {
              token: "opaquelocktoken:remote",
              owner: "alice",
              comment: "remote edit",
              createdDate: "2026-06-25T00:00:00.000Z",
              expiresDate: null,
              isRemote: true,
            },
          }),
        ],
      }),
    });
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      createRequestId: () => "11111111-1111-4111-8111-111111111111",
      sourceControlProjection,
    });

    await controller.openHeadResource({
      contextValue: "subversionr.incomingFile.locked",
      subversionrResourceKind: "file",
      resourceUri: { fsPath: "C:\\workspace\\SRC\\LOCKED.C" },
    });

    expect(ui.uriFromComponents).toHaveBeenCalledWith({
      scheme: "svn-r-head",
      authority: "head",
      path: "/",
      query:
        "repositoryId=repo-uuid%3AC%3A%2Fworkspace&epoch=7&generation=11&path=src%2Flocked.c&revision=head&requestId=11111111-1111-4111-8111-111111111111",
    });
    expect(ui.openHead).toHaveBeenCalledWith(
      {
        scheme: "svn-r-head",
        authority: "head",
        path: "/",
        query:
          "repositoryId=repo-uuid%3AC%3A%2Fworkspace&epoch=7&generation=11&path=src%2Flocked.c&revision=head&requestId=11111111-1111-4111-8111-111111111111",
      },
      "SVN HEAD: src/locked.c",
    );
  });

  it("fails fast when HEAD diff state is unavailable", async () => {
    const sourceControlProjection = fakeSourceControlProjection({ projection: undefined });
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      sourceControlProjection,
    });

    await controller.diffWithHeadResource({
      contextValue: "subversionr.changedFile.baseDiffable",
      subversionrResourceKind: "file",
      resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
    });

    expect(ui.diffWithHead).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_DIFF_HEAD_STATE_UNAVAILABLE",
    );
  });

  it("fails fast when HEAD content state is stale", async () => {
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({ epoch: 8 }),
    });
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      sourceControlProjection,
    });

    await controller.openHeadResource({
      contextValue: "subversionr.changedFile.baseDiffable",
      subversionrResourceKind: "file",
      resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
    });

    expect(ui.openHead).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_OPEN_HEAD_STATE_STALE",
    );
  });

  it("rejects added and directory SCM resources for HEAD commands", async () => {
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        resources: [scmProjectedResource({ path: "src/new.c", localStatus: "added", nodeStatus: "added" })],
      }),
    });
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      sourceControlProjection,
    });

    await controller.openHeadResource({
      contextValue: "subversionr.changedFile.baseDiffable",
      subversionrResourceKind: "file",
      resourceUri: { fsPath: "C:\\workspace\\src\\new.c" },
    });
    await controller.diffWithHeadResource({
      contextValue: "subversionr.changedDirectory",
      subversionrResourceKind: "dir",
      resourceUri: { fsPath: "C:\\workspace\\src" },
    });

    expect(ui.openHead).not.toHaveBeenCalled();
    expect(ui.diffWithHead).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenNthCalledWith(
      1,
      "SubversionR repository command failed: SUBVERSIONR_OPEN_HEAD_TARGET_INVALID",
    );
    expect(ui.showErrorMessage).toHaveBeenNthCalledWith(
      2,
      "SubversionR repository command failed: SUBVERSIONR_DIFF_HEAD_TARGET_INVALID",
    );
  });

  it("fails fast when BASE content state is unavailable", async () => {
    const sourceControlProjection = fakeSourceControlProjection({ projection: undefined });
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      sourceControlProjection,
    });

    await controller.openBaseResource({
      contextValue: "subversionr.changedFile.baseDiffable",
      subversionrResourceKind: "file",
      resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
    });

    expect(ui.openBase).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_OPEN_BASE_STATE_UNAVAILABLE",
    );
  });

  it("fails fast when BASE content state is stale", async () => {
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({ epoch: 8 }),
    });
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      sourceControlProjection,
    });

    await controller.openBaseResource({
      contextValue: "subversionr.changedFile.baseDiffable",
      subversionrResourceKind: "file",
      resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
    });

    expect(ui.openBase).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_OPEN_BASE_STATE_STALE",
    );
  });

  it("rejects added SVN files for BASE content until added-file rendering is supported", async () => {
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        resources: [scmProjectedResource({ path: "src/new.c", localStatus: "added", nodeStatus: "added" })],
      }),
    });
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      sourceControlProjection,
    });

    await controller.openBaseResource({
      contextValue: "subversionr.changedFile.baseDiffable",
      subversionrResourceKind: "file",
      resourceUri: { fsPath: "C:\\workspace\\src\\new.c" },
    });

    expect(ui.openBase).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_OPEN_BASE_TARGET_INVALID",
    );
  });

  it("rejects non-file SCM resources for BASE content", async () => {
    const sourceControlProjection = fakeSourceControlProjection();
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      sourceControlProjection,
    });

    await controller.openBaseResource({
      contextValue: "subversionr.changedDirectory",
      subversionrResourceKind: "dir",
      resourceUri: { fsPath: "C:\\workspace\\src" },
    });

    expect(ui.openBase).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_OPEN_BASE_TARGET_INVALID",
    );
  });

  it("fails fast when BASE diff state is unavailable", async () => {
    const sourceControlProjection = fakeSourceControlProjection({ projection: undefined });
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      sourceControlProjection,
    });

    await controller.diffWithBaseResource({
      contextValue: "subversionr.changedFile.baseDiffable",
      resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
    });

    expect(ui.diffWithBase).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_DIFF_BASE_STATE_UNAVAILABLE",
    );
  });

  it("rejects added SVN files for BASE diff until added-file rendering is supported", async () => {
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        resources: [scmProjectedResource({ path: "src/new.c", localStatus: "added", nodeStatus: "added" })],
      }),
    });
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      sourceControlProjection,
    });

    await controller.diffWithBaseResource({
      contextValue: "subversionr.changedFile.baseDiffable",
      resourceUri: { fsPath: "C:\\workspace\\src\\new.c" },
    });

    expect(ui.diffWithBase).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_DIFF_BASE_TARGET_INVALID",
    );
  });

  it.each([
    ["obstructed", { localStatus: "obstructed", nodeStatus: "obstructed" }],
    ["incomplete", { localStatus: "incomplete", nodeStatus: "incomplete" }],
    ["property-only", { localStatus: "normal", textStatus: "normal", propertyStatus: "modified" }],
  ])("rejects %s SVN files for BASE diff until safe rendering is supported", async (_label, entry) => {
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        resources: [scmProjectedResource({ path: "src/main.c", ...entry })],
      }),
    });
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      sourceControlProjection,
    });

    await controller.diffWithBaseResource({
      contextValue: "subversionr.changedFile.baseDiffable",
      resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
    });

    expect(ui.diffWithBase).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_DIFF_BASE_TARGET_INVALID",
    );
  });

  it("rejects non-file SCM resources for BASE diff", async () => {
    const sourceControlProjection = fakeSourceControlProjection();
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      sourceControlProjection,
    });

    await controller.diffWithBaseResource({
      contextValue: "subversionr.changedDirectory",
      subversionrResourceKind: "dir",
      resourceUri: { fsPath: "C:\\workspace\\src" },
    });

    expect(ui.diffWithBase).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_DIFF_BASE_TARGET_INVALID",
    );
  });

  it("opens repository history for the selected open repository", async () => {
    const session = repositorySession();
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(
      fakeDiscoveryService({ candidates: [discoveryCandidate()] }),
      fakeSessionService({ sessions: [session] }),
      ui,
    );

    await controller.showRepositoryLog("repo-uuid:C:/workspace");

    expect(ui.showHistory).toHaveBeenCalledWith({
      kind: "repository",
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: ".",
      label: "C:\\workspace",
    });
  });

  it("opens file history for a selected versioned SVN file using the projection canonical path", async () => {
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        resources: [scmProjectedResource({ path: "src/main.c", localStatus: "modified", textStatus: "modified" })],
      }),
    });
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(
      fakeDiscoveryService({ candidates: [discoveryCandidate()] }),
      fakeSessionService({ sessions: [repositorySession()] }),
      ui,
      { sourceControlProjection },
    );

    await controller.showFileHistoryResource({
      contextValue: "subversionr.changedFile.baseDiffable",
      subversionrResourceKind: "file",
      resourceUri: { fsPath: "C:\\workspace\\SRC\\MAIN.C" },
    });

    expect(sourceControlProjection.getProjection).toHaveBeenCalledWith("repo-uuid:C:/workspace");
    expect(ui.showHistory).toHaveBeenCalledWith({
      kind: "file",
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: "src/main.c",
      label: "src/main.c",
    });
  });

  it("opens file history for a switched projected SVN file using the switched branch path", async () => {
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        resources: [
          scmProjectedResource({
            path: "src/feature-only.c",
            localStatus: "normal",
            textStatus: "normal",
            switched: true,
          }),
        ],
      }),
    });
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(
      fakeDiscoveryService({ candidates: [discoveryCandidate()] }),
      fakeSessionService({ sessions: [repositorySession()] }),
      ui,
      { sourceControlProjection },
    );

    await controller.showFileHistoryResource({
      contextValue: "subversionr.changedFile",
      subversionrResourceKind: "file",
      resourceUri: { fsPath: "C:\\workspace\\SRC\\FEATURE-ONLY.C" },
    });

    expect(sourceControlProjection.getProjection).toHaveBeenCalledWith("repo-uuid:C:/workspace");
    expect(ui.showHistory).toHaveBeenCalledWith({
      kind: "file",
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: "src/feature-only.c",
      label: "src/feature-only.c",
    });
  });

  it("opens file history for an editor file URI using the projection canonical path", async () => {
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        resources: [scmProjectedResource({ path: "src/main.c", localStatus: "modified", textStatus: "modified" })],
      }),
    });
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(
      fakeDiscoveryService({ candidates: [discoveryCandidate()] }),
      fakeSessionService({ sessions: [repositorySession()] }),
      ui,
      { sourceControlProjection },
    );

    await controller.showFileHistoryResource({ scheme: "file", fsPath: "C:\\workspace\\SRC\\MAIN.C" });

    expect(sourceControlProjection.getProjection).toHaveBeenCalledWith("repo-uuid:C:/workspace");
    expect(ui.showHistory).toHaveBeenCalledWith({
      kind: "file",
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: "src/main.c",
      label: "src/main.c",
    });
  });

  it("opens a PREV comparison for an editor file URI using bounded file history", async () => {
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        resources: [
          scmProjectedResource({
            path: "src/main.c",
            changedRevision: 3,
            localStatus: "modified",
            textStatus: "modified",
          }),
        ],
      }),
    });
    const historyClient = fakeHistoryClient(
      historyLog({
        entries: [historyEntry(3), historyEntry(2)],
      }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(
      fakeDiscoveryService({ candidates: [discoveryCandidate()] }),
      fakeSessionService({ sessions: [repositorySession()] }),
      ui,
      { sourceControlProjection, historyClient },
    );

    await controller.diffWithPreviousResource({ scheme: "file", fsPath: "C:\\workspace\\SRC\\MAIN.C" });

    expect(historyClient.getLog).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: "src/main.c",
      startRevision: "r3",
      endRevision: "r0",
      limit: 2,
      discoverChangedPaths: false,
      strictNodeHistory: false,
      includeMergedRevisions: false,
    });
    expect(ui.diffRevisions).toHaveBeenCalledWith(
      {
        scheme: "svn-r-revision",
        authority: "revision",
        path: "/",
        query: "repositoryId=repo-uuid%3AC%3A%2Fworkspace&epoch=7&path=src%2Fmain.c&revision=r2",
      },
      {
        scheme: "svn-r-revision",
        authority: "revision",
        path: "/",
        query: "repositoryId=repo-uuid%3AC%3A%2Fworkspace&epoch=7&path=src%2Fmain.c&revision=r3",
      },
      "SVN PREV <-> Revision: src/main.c r2..r3",
    );
  });

  it("opens a PREV comparison for an SCM resource using projection generation", async () => {
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        resources: [
          scmProjectedResource({
            path: "src/main.c",
            changedRevision: 3,
            localStatus: "modified",
            textStatus: "modified",
          }),
        ],
      }),
    });
    const historyClient = fakeHistoryClient(
      historyLog({
        entries: [historyEntry(3), historyEntry(2)],
      }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(
      fakeDiscoveryService({ candidates: [discoveryCandidate()] }),
      fakeSessionService({ sessions: [repositorySession()] }),
      ui,
      { sourceControlProjection, historyClient },
    );

    await controller.diffWithPreviousResource({
      contextValue: "subversionr.changedFile",
      subversionrResourceKind: "file",
      subversionrProjectionGeneration: 11,
      resourceUri: { fsPath: "C:\\workspace\\SRC\\MAIN.C" },
    });

    expect(historyClient.getLog).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: "src/main.c",
      startRevision: "r3",
      endRevision: "r0",
      limit: 2,
      discoverChangedPaths: false,
      strictNodeHistory: false,
      includeMergedRevisions: false,
    });
    expect(ui.diffRevisions).toHaveBeenCalledWith(
      {
        scheme: "svn-r-revision",
        authority: "revision",
        path: "/",
        query: "repositoryId=repo-uuid%3AC%3A%2Fworkspace&epoch=7&path=src%2Fmain.c&revision=r2",
      },
      {
        scheme: "svn-r-revision",
        authority: "revision",
        path: "/",
        query: "repositoryId=repo-uuid%3AC%3A%2Fworkspace&epoch=7&path=src%2Fmain.c&revision=r3",
      },
      "SVN PREV <-> Revision: src/main.c r2..r3",
    );
  });

  it("rejects stale PREV comparison projection generations before history requests", async () => {
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        generation: 12,
        resources: [scmProjectedResource({ path: "src/main.c", changedRevision: 3 })],
      }),
    });
    const historyClient = fakeHistoryClient(historyLog());
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(
      fakeDiscoveryService({ candidates: [discoveryCandidate()] }),
      fakeSessionService({ sessions: [repositorySession()] }),
      ui,
      { sourceControlProjection, historyClient },
    );

    await controller.diffWithPreviousResource({
      contextValue: "subversionr.changedFile",
      subversionrResourceKind: "file",
      subversionrProjectionGeneration: 11,
      resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
    });

    expect(historyClient.getLog).not.toHaveBeenCalled();
    expect(ui.diffRevisions).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_DIFF_PREVIOUS_STATE_STALE",
    );
  });

  it("fails fast when no previous revision is available for PREV comparison", async () => {
    const historyClient = fakeHistoryClient(
      historyLog({
        entries: [historyEntry(3)],
      }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(
      fakeDiscoveryService({ candidates: [discoveryCandidate()] }),
      fakeSessionService({ sessions: [repositorySession()] }),
      ui,
      { historyClient },
    );

    await controller.diffWithPreviousResource({
      contextValue: "subversionr.changedFile",
      subversionrResourceKind: "file",
      resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
    });

    expect(ui.diffRevisions).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_DIFF_PREVIOUS_NO_PREVIOUS_REVISION",
    );
  });

  it("rejects PREV comparison targets with invalid changed revisions before history requests", async () => {
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        resources: [scmProjectedResource({ path: "src/main.c", changedRevision: 0 })],
      }),
    });
    const historyClient = fakeHistoryClient(historyLog());
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(
      fakeDiscoveryService({ candidates: [discoveryCandidate()] }),
      fakeSessionService({ sessions: [repositorySession()] }),
      ui,
      { sourceControlProjection, historyClient },
    );

    await controller.diffWithPreviousResource({
      contextValue: "subversionr.changedFile",
      subversionrResourceKind: "file",
      resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
    });

    expect(historyClient.getLog).not.toHaveBeenCalled();
    expect(ui.diffRevisions).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_DIFF_PREVIOUS_TARGET_INVALID",
    );
  });

  it("rejects editor URI command arguments outside open SVN repositories", async () => {
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(
      fakeDiscoveryService({ candidates: [discoveryCandidate()] }),
      fakeSessionService({ sessions: [repositorySession()] }),
      ui,
    );

    await controller.openBaseResource({ scheme: "file", fsPath: "D:\\outside\\src\\main.c" });

    expect(ui.openBase).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_OPEN_BASE_TARGET_OUTSIDE_REPOSITORY",
    );
  });

  it("fails fast when file history state is unavailable", async () => {
    const sourceControlProjection = fakeSourceControlProjection({ projection: undefined });
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(
      fakeDiscoveryService({ candidates: [discoveryCandidate()] }),
      fakeSessionService({ sessions: [repositorySession()] }),
      ui,
      { sourceControlProjection },
    );

    await controller.showFileHistoryResource({
      contextValue: "subversionr.changedFile",
      subversionrResourceKind: "file",
      resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
    });

    expect(ui.showHistory).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_HISTORY_FILE_STATE_UNAVAILABLE",
    );
  });

  it("rejects unversioned and directory SCM resources for file history", async () => {
    const sourceControlProjection = fakeSourceControlProjection();
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(
      fakeDiscoveryService({ candidates: [discoveryCandidate()] }),
      fakeSessionService({ sessions: [repositorySession()] }),
      ui,
      { sourceControlProjection },
    );

    await controller.showFileHistoryResource({
      contextValue: "subversionr.unversioned",
      subversionrResourceKind: "file",
      resourceUri: { fsPath: "C:\\workspace\\src\\new.c" },
    });
    await controller.showFileHistoryResource({
      contextValue: "subversionr.changedDirectory",
      subversionrResourceKind: "dir",
      resourceUri: { fsPath: "C:\\workspace\\src" },
    });

    expect(ui.showHistory).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenNthCalledWith(
      1,
      "SubversionR repository command failed: SUBVERSIONR_HISTORY_FILE_TARGET_INVALID",
    );
    expect(ui.showErrorMessage).toHaveBeenNthCalledWith(
      2,
      "SubversionR repository command failed: SUBVERSIONR_HISTORY_FILE_TARGET_INVALID",
    );
  });

  it("opens file blame for a selected versioned SVN file using the projection canonical path", async () => {
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        resources: [scmProjectedResource({ path: "src/main.c", localStatus: "modified", textStatus: "modified" })],
      }),
    });
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(
      fakeDiscoveryService({ candidates: [discoveryCandidate()] }),
      fakeSessionService({ sessions: [repositorySession()] }),
      ui,
      { sourceControlProjection },
    );

    await controller.showBlameResource({
      contextValue: "subversionr.changedFile.baseDiffable",
      subversionrResourceKind: "file",
      resourceUri: { fsPath: "C:\\workspace\\SRC\\MAIN.C" },
    });

    expect(sourceControlProjection.getProjection).toHaveBeenCalledWith("repo-uuid:C:/workspace");
    expect(ui.showBlame).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      generation: 11,
      path: "src/main.c",
      label: "src/main.c",
      pegRevision: "base",
      startRevision: "r0",
      endRevision: "base",
      lineStart: 1,
      lineLimit: 5000,
      ignoreWhitespace: "none",
      ignoreEolStyle: false,
      ignoreMimeType: false,
      includeMergedRevisions: false,
    });
  });

  it("includes merged revisions in explicit blame documents when history settings enable them", async () => {
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        resources: [scmProjectedResource({ path: "src/main.c", localStatus: "modified", textStatus: "modified" })],
      }),
    });
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(
      fakeDiscoveryService({ candidates: [discoveryCandidate()] }),
      fakeSessionService({ sessions: [repositorySession()] }),
      ui,
      {
        sourceControlProjection,
        includeMergedRevisions: () => true,
      },
    );

    await controller.showBlameResource({
      contextValue: "subversionr.changedFile.baseDiffable",
      subversionrResourceKind: "file",
      resourceUri: { fsPath: "C:\\workspace\\SRC\\MAIN.C" },
    });

    expect(ui.showBlame).toHaveBeenCalledWith(
      expect.objectContaining({
        includeMergedRevisions: true,
      }),
    );
  });

  it("rejects unversioned and directory SCM resources for file blame", async () => {
    const sourceControlProjection = fakeSourceControlProjection();
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(
      fakeDiscoveryService({ candidates: [discoveryCandidate()] }),
      fakeSessionService({ sessions: [repositorySession()] }),
      ui,
      { sourceControlProjection },
    );

    await controller.showBlameResource({
      contextValue: "subversionr.unversioned",
      subversionrResourceKind: "file",
      resourceUri: { fsPath: "C:\\workspace\\src\\new.c" },
    });
    await controller.showBlameResource({
      contextValue: "subversionr.changedDirectory",
      subversionrResourceKind: "dir",
      resourceUri: { fsPath: "C:\\workspace\\src" },
    });

    expect(ui.showBlame).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenNthCalledWith(
      1,
      "SubversionR repository command failed: SUBVERSIONR_BLAME_FILE_TARGET_INVALID",
    );
    expect(ui.showErrorMessage).toHaveBeenNthCalledWith(
      2,
      "SubversionR repository command failed: SUBVERSIONR_BLAME_FILE_TARGET_INVALID",
    );
  });

  it.each([
    ["conflicted external", { localStatus: "conflicted", nodeStatus: "conflicted", external: true }],
    ["conflicted ignored", { localStatus: "ignored", nodeStatus: "conflicted" }],
  ])("rejects %s SCM resources for file history", async (_label, entry) => {
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        resources: [
          scmProjectedResource({
            path: "src/main.c",
            ...entry,
          }),
        ],
      }),
    });
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(
      fakeDiscoveryService({ candidates: [discoveryCandidate()] }),
      fakeSessionService({ sessions: [repositorySession()] }),
      ui,
      { sourceControlProjection },
    );

    await controller.showFileHistoryResource({
      contextValue: "subversionr.conflicted",
      subversionrResourceKind: "file",
      resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
    });

    expect(ui.showHistory).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_HISTORY_FILE_TARGET_INVALID",
    );
  });

  it.each([
    ["subversionr.changedFile.baseDiffable", "C:\\workspace\\src\\main.c", "src/main.c"],
    ["subversionr.conflicted.changelisted", "C:\\workspace\\src\\conflicted.c", "src/conflicted.c"],
    ["subversionr.changedFile.changelisted", "C:\\workspace\\src\\review.c", "src/review.c"],
    ["subversionr.changedFile.baseDiffable.changelisted", "C:\\workspace\\src\\review.c", "src/review.c"],
    ["subversionr.changedDirectory.changelisted", "C:\\workspace\\src", "src"],
    ["subversionr.workingCopyMetadata", "C:\\workspace\\branches\\feature", "branches/feature"],
    ["subversionr.workingCopyMetadataFile", "C:\\workspace\\src\\needs-lock.c", "src/needs-lock.c"],
    ["subversionr.workingCopyMetadataFile.locked", "C:\\workspace\\src\\locked.c", "src/locked.c"],
  ])(
    "refreshes a selected %s SCM resource through the explicit resource refresh service",
    async (contextValue, fsPath, expectedPath) => {
      const session = repositorySession();
      const sessionService = fakeSessionService({ sessions: [session] });
      const refreshService = fakeRefreshService();
      const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
      const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
        refreshService,
      });

      await controller.refreshResource({
        contextValue,
        resourceUri: { fsPath },
      });

      expect(refreshService.refreshResource).toHaveBeenCalledWith({
        repositoryId: "repo-uuid:C:/workspace",
        epoch: 7,
        path: expectedPath,
      });
      expect(ui.showInformationMessage).toHaveBeenCalledWith(
        `SubversionR refreshed SVN resource: ${expectedPath}`,
      );
    },
  );

  it("accepts the SCM resource array shape documented by VS Code", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
    });

    await controller.refreshResource([
      {
        contextValue: "subversionr.changedFile",
        resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
      },
    ]);

    expect(refreshService.refreshResource).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: "src/main.c",
    });
  });

  it("resolves SCM resource refresh to the most specific open working copy root", async () => {
    const root = repositorySession();
    const nested = repositorySession({
      repositoryId: "repo-uuid:C:/workspace/nested",
      workingCopyRoot: "C:\\workspace\\nested",
    });
    const sessionService = fakeSessionService({ sessions: [root, nested] });
    const refreshService = fakeRefreshService();
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
    });

    await controller.refreshResource({
      contextValue: "subversionr.changedFile",
      resourceUri: { fsPath: "C:\\workspace\\nested\\src\\main.c" },
    });

    expect(ui.pickOpenRepository).not.toHaveBeenCalled();
    expect(refreshService.refreshResource).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace/nested",
      epoch: 7,
      path: "src/main.c",
    });
  });

  it("fails fast when a selected SCM resource is outside every open repository", async () => {
    const sessionService = fakeSessionService({ sessions: [repositorySession()] });
    const refreshService = fakeRefreshService();
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
    });

    await controller.refreshResource({
      contextValue: "subversionr.changedFile",
      resourceUri: { fsPath: "D:\\outside\\main.c" },
    });

    expect(refreshService.refreshResource).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_RESOURCE_REFRESH_TARGET_OUTSIDE_REPOSITORY",
    );
  });

  it("reports missing SCM resource command arguments without guessing a repository", async () => {
    const sessionService = fakeSessionService({ sessions: [repositorySession()] });
    const refreshService = fakeRefreshService();
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
    });

    await controller.refreshResource(undefined);

    expect(refreshService.refreshResource).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_RESOURCE_REFRESH_TARGET_INVALID",
    );
  });

  it("rejects SCM resource arguments without an absolute fsPath", async () => {
    const sessionService = fakeSessionService({ sessions: [repositorySession()] });
    const refreshService = fakeRefreshService();
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
    });

    await controller.refreshResource({
      contextValue: "subversionr.changedFile",
      resourceUri: { fsPath: "src\\main.c" },
    });

    expect(refreshService.refreshResource).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_RESOURCE_REFRESH_TARGET_INVALID",
    );
  });

  it("rejects remote incoming SCM resources for local resource refresh", async () => {
    const sessionService = fakeSessionService({ sessions: [repositorySession()] });
    const refreshService = fakeRefreshService();
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
    });

    await controller.refreshResource({
      contextValue: "subversionr.incoming",
      resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
    });

    expect(refreshService.refreshResource).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_RESOURCE_REFRESH_TARGET_INVALID",
    );
  });

  it("rejects multi-select SCM resource refresh until batch semantics are defined", async () => {
    const sessionService = fakeSessionService({ sessions: [repositorySession()] });
    const refreshService = fakeRefreshService();
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
    });

    await controller.refreshResource(
      {
        contextValue: "subversionr.changedFile",
        resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
      },
      {
        contextValue: "subversionr.changedFile",
        resourceUri: { fsPath: "C:\\workspace\\src\\other.c" },
      },
    );

    expect(refreshService.refreshResource).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_RESOURCE_REFRESH_TARGET_INVALID",
    );
  });

  it("rejects SCM resource arrays with more than one resource", async () => {
    const sessionService = fakeSessionService({ sessions: [repositorySession()] });
    const refreshService = fakeRefreshService();
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
    });

    await controller.refreshResource([
      {
        contextValue: "subversionr.changedFile",
        resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
      },
      {
        contextValue: "subversionr.changedFile",
        resourceUri: { fsPath: "C:\\workspace\\src\\other.c" },
      },
    ]);

    expect(refreshService.refreshResource).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_RESOURCE_REFRESH_TARGET_INVALID",
    );
  });

  it("confirms and reverts a selected changed SCM resource through operation/run", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(operationResponse());
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({ resources: [scmProjectedResource({ path: "src/main.c" })] }),
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
      sourceControlProjection,
    });

    await controller.revertResource({
      contextValue: "subversionr.changedFile",
      resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
    });

    expect(ui.confirmRevertResource).toHaveBeenCalledWith("src/main.c");
    expect(operationClient.revert).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      paths: ["src/main.c"],
      depth: "empty",
      changelists: [],
      clearChangelists: false,
      metadataOnly: false,
      addedKeepLocal: false,
    });
    expect(refreshService.refreshTargets).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [{ path: "src/main.c", depth: "empty", reason: "operationRevert" }],
    });
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR reverted SVN resource: src/main.c",
    );
  });

  it.each([
    [
      "subversionr.changedFile.changelisted",
      "src/main.c",
      scmProjectedResource({ path: "src/main.c", changelist: "review" }),
    ],
    [
      "subversionr.changedFile.baseDiffable.changelisted",
      "src/main.c",
      scmProjectedResource({ path: "src/main.c", changelist: "review" }),
    ],
    [
      "subversionr.changedDirectory.changelisted",
      "src/module",
      scmProjectedResource({ path: "src/module", kind: "directory", changelist: "review" }),
    ],
    [
      "subversionr.conflicted.changelisted",
      "src/conflicted.txt",
      scmConflictedProjectedResource({ path: "src/conflicted.txt", changelist: "review" }),
    ],
  ])("confirms and reverts a selected %s SCM resource through operation/run", async (contextValue, repositoryPath, projectionResource) => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "revert", path: repositoryPath, reason: "operationRevert" }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({ resources: [projectionResource] }),
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
      sourceControlProjection,
    });

    await controller.revertResource({
      contextValue,
      resourceUri: { fsPath: repositoryPathToFsPath("C:\\workspace", repositoryPath) },
    });

    expect(ui.confirmRevertResource).toHaveBeenCalledWith(repositoryPath);
    expect(operationClient.revert).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      paths: [repositoryPath],
      depth: "empty",
      changelists: [],
      clearChangelists: false,
      metadataOnly: false,
      addedKeepLocal: false,
    });
    expect(refreshService.refreshTargets).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [{ path: repositoryPath, depth: "empty", reason: "operationRevert" }],
    });
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      `SubversionR reverted SVN resource: ${repositoryPath}`,
    );
  });

  it("confirms and reverts multiple selected changed SCM resources through one operation/run request", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const revertResponse: OperationRunResponse = {
      ...operationResponse(),
      touchedPaths: ["src/main.c", "src/other.c"],
      summary: { affectedPaths: 2, skippedPaths: 0 },
      reconcile: {
        targets: [
          { path: "src/main.c", depth: "empty", reason: "operationRevert" },
          { path: "src/other.c", depth: "empty", reason: "operationRevert" },
        ],
        requiresFullReconcile: false,
      },
    };
    const operationClient = fakeOperationClient(revertResponse);
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        resources: [
          scmProjectedResource({ path: "src/main.c" }),
          scmProjectedResource({ path: "src/other.c" }),
        ],
      }),
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
      sourceControlProjection,
    });

    await controller.revertResource([
      {
        contextValue: "subversionr.changedFile",
        resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
      },
      {
        contextValue: "subversionr.changedFile",
        resourceUri: { fsPath: "C:\\workspace\\src\\other.c" },
      },
    ]);

    expect(ui.confirmRevertResource).toHaveBeenCalledWith("src/main.c, src/other.c");
    expect(operationClient.revert).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      paths: ["src/main.c", "src/other.c"],
      depth: "empty",
      changelists: [],
      clearChangelists: false,
      metadataOnly: false,
      addedKeepLocal: false,
    });
    expect(refreshService.refreshTargets).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [
        { path: "src/main.c", depth: "empty", reason: "operationRevert" },
        { path: "src/other.c", depth: "empty", reason: "operationRevert" },
      ],
    });
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR reverted 2 SVN resources: src/main.c, src/other.c",
    );
  });

  it("adds a selected unversioned SCM resource through operation/run", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "add", path: "scratch.txt", reason: "operationAdd" }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({ resources: [scmUnversionedProjectedResource({ path: "scratch.txt" })] }),
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
      sourceControlProjection,
    });

    await controller.addResource({
      contextValue: "subversionr.unversioned",
      resourceUri: { fsPath: "C:\\workspace\\scratch.txt" },
    });

    expect(operationClient.add).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      paths: ["scratch.txt"],
      depth: "empty",
      force: false,
      noIgnore: false,
      noAutoprops: false,
      addParents: false,
    });
    expect(refreshService.refreshTargets).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [{ path: "scratch.txt", depth: "empty", reason: "operationAdd" }],
    });
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR added SVN resource: scratch.txt",
    );
  });

  it("adds selected unversioned files and directories with SVN-appropriate depths", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const addFirstResponse = operationResponse({ kind: "add", path: "scratch-a.txt", reason: "operationAdd" });
    const addSecondResponse = operationResponse({ kind: "add", path: "scratch-dir", reason: "operationAdd", depth: "infinity" });
    const operationClient = fakeOperationClient(addFirstResponse);
    operationClient.add.mockResolvedValueOnce(addFirstResponse).mockResolvedValueOnce(addSecondResponse);
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        resources: [
          scmUnversionedProjectedResource({ path: "scratch-a.txt" }),
          scmUnversionedProjectedResource({ path: "scratch-dir", kind: "dir" }),
        ],
      }),
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
      sourceControlProjection,
    });

    await controller.addResource([
      {
        contextValue: "subversionr.unversioned",
        resourceUri: { fsPath: "C:\\workspace\\scratch-a.txt" },
      },
      {
        contextValue: "subversionr.unversioned",
        subversionrResourceKind: "dir",
        resourceUri: { fsPath: "C:\\workspace\\scratch-dir" },
      },
    ]);

    expect(operationClient.add).toHaveBeenNthCalledWith(1, {
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      paths: ["scratch-a.txt"],
      depth: "empty",
      force: false,
      noIgnore: false,
      noAutoprops: false,
      addParents: false,
    });
    expect(operationClient.add).toHaveBeenNthCalledWith(2, {
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      paths: ["scratch-dir"],
      depth: "infinity",
      force: false,
      noIgnore: false,
      noAutoprops: false,
      addParents: false,
    });
    expect(refreshService.refreshTargets).toHaveBeenNthCalledWith(1, {
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [{ path: "scratch-a.txt", depth: "empty", reason: "operationAdd" }],
    });
    expect(refreshService.refreshTargets).toHaveBeenNthCalledWith(2, {
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [{ path: "scratch-dir", depth: "infinity", reason: "operationAdd" }],
    });
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR added 2 SVN resources: scratch-a.txt, scratch-dir",
    );
  });

  it("reconciles a successful selected add before reporting a later selected add failure", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const addFirstResponse = operationResponse({ kind: "add", path: "scratch-a.txt", reason: "operationAdd" });
    const operationClient = fakeOperationClient(addFirstResponse);
    operationClient.add
      .mockResolvedValueOnce(addFirstResponse)
      .mockRejectedValueOnce(new CodedError("SUBVERSIONR_OPERATION_FAILED"));
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        resources: [
          scmUnversionedProjectedResource({ path: "scratch-a.txt" }),
          scmUnversionedProjectedResource({ path: "scratch-b.txt" }),
        ],
      }),
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
      sourceControlProjection,
    });

    await controller.addResource([
      {
        contextValue: "subversionr.unversioned",
        resourceUri: { fsPath: "C:\\workspace\\scratch-a.txt" },
      },
      {
        contextValue: "subversionr.unversioned",
        resourceUri: { fsPath: "C:\\workspace\\scratch-b.txt" },
      },
    ]);

    expect(operationClient.add).toHaveBeenCalledTimes(2);
    expect(refreshService.refreshTargets).toHaveBeenCalledTimes(1);
    expect(refreshService.refreshTargets).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [{ path: "scratch-a.txt", depth: "empty", reason: "operationAdd" }],
    });
    expect(refreshService.refreshTargets.mock.invocationCallOrder[0]).toBeLessThan(
      operationClient.add.mock.invocationCallOrder[1],
    );
    expect(ui.showInformationMessage).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_OPERATION_FAILED",
    );
  });

  it("adds a selected unversioned SCM resource basename to parent svn:ignore", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "propertySet", path: ".", reason: "operationPropertySet" }),
    );
    const propertiesClient = fakePropertiesClient(propertiesResponse({ path: "." }));
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({ resources: [scmUnversionedProjectedResource({ path: "scratch.txt" })] }),
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
      propertiesClient,
      sourceControlProjection,
    });

    await controller.addToIgnoreResource({
      contextValue: "subversionr.unversioned",
      resourceUri: { fsPath: "C:\\workspace\\scratch.txt" },
    });

    expect(propertiesClient.listProperties).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: ".",
    });
    expect(operationClient.propertySet).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: ".",
      name: "svn:ignore",
      value: "scratch.txt",
    });
    expect(refreshService.refreshTargets).toHaveBeenNthCalledWith(1, {
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [{ path: ".", depth: "empty", reason: "operationPropertySet" }],
    });
    expect(refreshService.refreshTargets).toHaveBeenNthCalledWith(2, {
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [{ path: "scratch.txt", depth: "empty", reason: "operationPropertySet" }],
    });
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR added SVN ignore rule for: scratch.txt",
    );
  });

  it("adds multiple selected unversioned SCM resources to a single parent svn:ignore property", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "propertySet", path: "src", reason: "operationPropertySet" }),
    );
    const propertiesClient = fakePropertiesClient(
      propertiesResponse({
        path: "src",
        properties: [{ name: "svn:ignore", value: "node_modules", valueEncoding: "utf8" }],
      }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        resources: [
          scmUnversionedProjectedResource({ path: "src/generated.log" }),
          scmUnversionedProjectedResource({ path: "src/cache" }),
        ],
      }),
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
      propertiesClient,
      sourceControlProjection,
    });

    await controller.addToIgnoreResource([
      {
        contextValue: "subversionr.unversioned",
        resourceUri: { fsPath: "C:\\workspace\\src\\generated.log" },
      },
      {
        contextValue: "subversionr.unversioned",
        resourceUri: { fsPath: "C:\\workspace\\src\\cache" },
      },
    ]);

    expect(propertiesClient.listProperties).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: "src",
    });
    expect(operationClient.propertySet).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: "src",
      name: "svn:ignore",
      value: "node_modules\ngenerated.log\ncache",
    });
    expect(refreshService.refreshTargets).toHaveBeenLastCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [
        { path: "src/generated.log", depth: "empty", reason: "operationPropertySet" },
        { path: "src/cache", depth: "empty", reason: "operationPropertySet" },
      ],
    });
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR added SVN ignore rules for 2 items: src/generated.log, src/cache",
    );
  });

  it("does not rewrite svn:ignore when the selected basename is already ignored", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "propertySet", path: ".", reason: "operationPropertySet" }),
    );
    const propertiesClient = fakePropertiesClient(
      propertiesResponse({
        path: ".",
        properties: [{ name: "svn:ignore", value: "scratch.txt\nother.tmp", valueEncoding: "utf8" }],
      }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({ resources: [scmUnversionedProjectedResource({ path: "scratch.txt" })] }),
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
      propertiesClient,
      sourceControlProjection,
    });

    await controller.addToIgnoreResource({
      contextValue: "subversionr.unversioned",
      resourceUri: { fsPath: "C:\\workspace\\scratch.txt" },
    });

    expect(operationClient.propertySet).not.toHaveBeenCalled();
    expect(refreshService.refreshTargets).not.toHaveBeenCalled();
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR SVN ignore rules already include selected item(s).",
    );
  });

  it("removes a selected ignored SCM resource basename from parent svn:ignore", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "propertySet", path: "src", reason: "operationPropertySet" }),
    );
    const propertiesClient = fakePropertiesClient(
      propertiesResponse({
        path: "src",
        properties: [{ name: "svn:ignore", value: "generated.log\ncache", valueEncoding: "utf8" }],
      }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({ resources: [scmIgnoredProjectedResource({ path: "src/generated.log" })] }),
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
      propertiesClient,
      sourceControlProjection,
    });

    await controller.removeFromIgnoreResource({
      contextValue: "subversionr.ignored",
      resourceUri: { fsPath: "C:\\workspace\\src\\generated.log" },
    });

    expect(propertiesClient.listProperties).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: "src",
    });
    expect(operationClient.propertySet).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: "src",
      name: "svn:ignore",
      value: "cache",
    });
    expect(operationClient.propertyDelete).not.toHaveBeenCalled();
    expect(refreshService.refreshTargets).toHaveBeenNthCalledWith(1, {
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [{ path: "src", depth: "empty", reason: "operationPropertySet" }],
    });
    expect(refreshService.refreshTargets).toHaveBeenNthCalledWith(2, {
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [{ path: "src/generated.log", depth: "empty", reason: "operationPropertySet" }],
    });
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR removed SVN ignore rule for: src/generated.log",
    );
  });

  it("deletes parent svn:ignore when removing the last selected ignored basename", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "propertyDelete", path: "src", reason: "operationPropertyDelete" }),
    );
    const propertiesClient = fakePropertiesClient(
      propertiesResponse({
        path: "src",
        properties: [{ name: "svn:ignore", value: "generated.log", valueEncoding: "utf8" }],
      }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({ resources: [scmIgnoredProjectedResource({ path: "src/generated.log" })] }),
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
      propertiesClient,
      sourceControlProjection,
    });

    await controller.removeFromIgnoreResource({
      contextValue: "subversionr.ignored",
      resourceUri: { fsPath: "C:\\workspace\\src\\generated.log" },
    });

    expect(operationClient.propertyDelete).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: "src",
      name: "svn:ignore",
    });
    expect(operationClient.propertySet).not.toHaveBeenCalled();
    expect(refreshService.refreshTargets).toHaveBeenNthCalledWith(1, {
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [{ path: "src", depth: "empty", reason: "operationPropertyDelete" }],
    });
    expect(refreshService.refreshTargets).toHaveBeenNthCalledWith(2, {
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [{ path: "src/generated.log", depth: "empty", reason: "operationPropertyDelete" }],
    });
  });

  it("deletes newline-terminated parent svn:ignore when removing the last selected ignored basename", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "propertyDelete", path: "src", reason: "operationPropertyDelete" }),
    );
    const propertiesClient = fakePropertiesClient(
      propertiesResponse({
        path: "src",
        properties: [{ name: "svn:ignore", value: "generated.log\n", valueEncoding: "utf8" }],
      }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({ resources: [scmIgnoredProjectedResource({ path: "src/generated.log" })] }),
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
      propertiesClient,
      sourceControlProjection,
    });

    await controller.removeFromIgnoreResource({
      contextValue: "subversionr.ignored",
      resourceUri: { fsPath: "C:\\workspace\\src\\generated.log" },
    });

    expect(operationClient.propertyDelete).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: "src",
      name: "svn:ignore",
    });
    expect(operationClient.propertySet).not.toHaveBeenCalled();
    expect(refreshService.refreshTargets).toHaveBeenLastCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [{ path: "src/generated.log", depth: "empty", reason: "operationPropertyDelete" }],
    });
  });

  it("sets a selected SVN resource property through operation/run", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "propertySet", path: "src/main.c", reason: "operationPropertySet" }),
    );
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace"],
      propertySetOptions: { name: "svn:eol-style", value: "LF" },
    });
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({ resources: [scmProjectedResource({ path: "src/main.c" })] }),
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
      sourceControlProjection,
    });

    await controller.setResourceProperty({
      contextValue: "subversionr.changedFile",
      resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
    });

    expect(ui.promptPropertySetOptions).toHaveBeenCalledWith("src/main.c");
    expect(operationClient.propertySet).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: "src/main.c",
      name: "svn:eol-style",
      value: "LF",
    });
    expect(refreshService.refreshTargets).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [{ path: "src/main.c", depth: "empty", reason: "operationPropertySet" }],
    });
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR set SVN property svn:eol-style on: src/main.c",
    );
  });

  it("deletes a selected SVN resource property through operation/run", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "propertyDelete", path: "src/main.c", reason: "operationPropertyDelete" }),
    );
    const properties = [{ name: "svn:needs-lock", value: "*", valueEncoding: "utf8" as const }];
    const propertiesClient = fakePropertiesClient(propertiesResponse({ path: "src/main.c", properties }));
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace"],
      propertyDeleteName: "svn:needs-lock",
    });
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({ resources: [scmProjectedResource({ path: "src/main.c" })] }),
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
      propertiesClient,
      sourceControlProjection,
    });

    await controller.deleteResourceProperty({
      contextValue: "subversionr.changedFile",
      resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
    });

    expect(propertiesClient.listProperties).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: "src/main.c",
    });
    expect(ui.promptPropertyDeleteName).toHaveBeenCalledWith("src/main.c", properties);
    expect(operationClient.propertyDelete).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: "src/main.c",
      name: "svn:needs-lock",
    });
    expect(refreshService.refreshTargets).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [{ path: "src/main.c", depth: "empty", reason: "operationPropertyDelete" }],
    });
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR deleted SVN property svn:needs-lock from: src/main.c",
    );
  });

  it("sets svn:externals on the working-copy root through operation/run", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "propertySet", path: ".", reason: "operationPropertySet" }),
    );
    const propertiesClient = fakePropertiesClient(propertiesResponse({ path: "." }));
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace"],
      externalsPropertyValue: "^/libs/shared shared",
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
      propertiesClient,
    });

    await controller.editRepositoryExternals("repo-uuid:C:/workspace");

    expect(propertiesClient.listProperties).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: ".",
    });
    expect(ui.promptExternalsPropertyValue).toHaveBeenCalledWith(".", undefined);
    expect(operationClient.propertySet).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: ".",
      name: "svn:externals",
      value: "^/libs/shared shared",
    });
    expect(refreshService.refreshTargets).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [{ path: ".", depth: "empty", reason: "operationPropertySet" }],
    });
    expect(ui.showInformationMessage).toHaveBeenCalledWith("SubversionR updated svn:externals on: .");
  });

  it("deletes svn:externals from a selected SVN directory when the edited value is empty", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "propertyDelete", path: "src", reason: "operationPropertyDelete" }),
    );
    const propertiesClient = fakePropertiesClient(
      propertiesResponse({
        path: "src",
        properties: [{ name: "svn:externals", value: "^/libs/shared shared", valueEncoding: "utf8" }],
      }),
    );
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace"],
      externalsPropertyValue: "",
    });
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({ resources: [scmProjectedResource({ path: "src", kind: "dir" })] }),
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
      propertiesClient,
      sourceControlProjection,
    });

    await controller.editResourceExternals({
      contextValue: "subversionr.changedDirectory",
      resourceUri: { fsPath: "C:\\workspace\\src" },
    });

    expect(ui.promptExternalsPropertyValue).toHaveBeenCalledWith("src", "^/libs/shared shared");
    expect(operationClient.propertyDelete).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: "src",
      name: "svn:externals",
    });
    expect(operationClient.propertySet).not.toHaveBeenCalled();
    expect(refreshService.refreshTargets).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [{ path: "src", depth: "empty", reason: "operationPropertyDelete" }],
    });
    expect(ui.showInformationMessage).toHaveBeenCalledWith("SubversionR cleared svn:externals from: src");
  });

  it("rejects selected SVN files for editing svn:externals", async () => {
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "propertySet", path: "src/main.c", reason: "operationPropertySet" }),
    );
    const propertiesClient = fakePropertiesClient(propertiesResponse({ path: "src/main.c" }));
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"], externalsPropertyValue: "^/libs/shared shared" });
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({ resources: [scmProjectedResource({ path: "src/main.c", kind: "file" })] }),
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      refreshService,
      operationClient,
      propertiesClient,
      sourceControlProjection,
    });

    await controller.editResourceExternals({
      contextValue: "subversionr.changedFile",
      resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
    });

    expect(propertiesClient.listProperties).not.toHaveBeenCalled();
    expect(ui.promptExternalsPropertyValue).not.toHaveBeenCalled();
    expect(operationClient.propertySet).not.toHaveBeenCalled();
    expect(operationClient.propertyDelete).not.toHaveBeenCalled();
    expect(refreshService.refreshTargets).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_RESOURCE_PROPERTIES_TARGET_INVALID",
    );
  });

  it("does not rewrite svn:ignore when the selected ignored basename is not present", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "propertySet", path: "src", reason: "operationPropertySet" }),
    );
    const propertiesClient = fakePropertiesClient(
      propertiesResponse({
        path: "src",
        properties: [{ name: "svn:ignore", value: "cache", valueEncoding: "utf8" }],
      }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({ resources: [scmIgnoredProjectedResource({ path: "src/generated.log" })] }),
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
      propertiesClient,
      sourceControlProjection,
    });

    await controller.removeFromIgnoreResource({
      contextValue: "subversionr.ignored",
      resourceUri: { fsPath: "C:\\workspace\\src\\generated.log" },
    });

    expect(operationClient.propertySet).not.toHaveBeenCalled();
    expect(operationClient.propertyDelete).not.toHaveBeenCalled();
    expect(refreshService.refreshTargets).not.toHaveBeenCalled();
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR SVN ignore rules did not include selected item(s).",
    );
  });

  it.each([
    "subversionr.changed",
    "subversionr.changedUnknown",
    "subversionr.conflicted",
    "subversionr.external",
    "subversionr.ignored",
    "subversionr.incoming",
  ])("rejects %s SCM resources for add to ignore", async (contextValue) => {
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(operationResponse({ kind: "propertySet", reason: "operationPropertySet" }));
    const propertiesClient = fakePropertiesClient(propertiesResponse());
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      refreshService,
      operationClient,
      propertiesClient,
    });

    await controller.addToIgnoreResource({
      contextValue,
      resourceUri: { fsPath: "C:\\workspace\\scratch.txt" },
    });

    expect(propertiesClient.listProperties).not.toHaveBeenCalled();
    expect(operationClient.propertySet).not.toHaveBeenCalled();
    expect(refreshService.refreshTargets).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_RESOURCE_ADD_TO_IGNORE_TARGET_INVALID",
    );
  });

  it("sets a selected changed resource changelist through operation/run", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "changelistSet", path: "src/main.c", reason: "operationChangelistSet" }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"], changelistName: "review" });
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({ resources: [scmProjectedResource({ path: "src/main.c" })] }),
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
      sourceControlProjection,
    });

    await controller.setResourceChangelist({
      contextValue: "subversionr.changedFile",
      resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
    });

    expect(ui.promptChangelistName).toHaveBeenCalledWith(["src/main.c"]);
    expect(operationClient.changelistSet).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      paths: ["src/main.c"],
      depth: "empty",
      changelist: "review",
      changelists: [],
    });
    expect(refreshService.refreshTargets).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [{ path: "src/main.c", depth: "empty", reason: "operationChangelistSet" }],
    });
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR assigned SVN changelist review: src/main.c",
    );
  });

  it("clears selected changelisted resources through operation/run", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "changelistClear", path: "src/main.c", reason: "operationChangelistClear" }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({ resources: [scmChangelistProjectedResource({ path: "src/main.c" })] }),
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
      sourceControlProjection,
    });

    await controller.clearResourceChangelist({
      contextValue: "subversionr.changedFile.changelisted",
      resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
    });

    expect(operationClient.changelistClear).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      paths: ["src/main.c"],
      depth: "empty",
      changelists: [],
    });
    expect(refreshService.refreshTargets).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [{ path: "src/main.c", depth: "empty", reason: "operationChangelistClear" }],
    });
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR cleared SVN changelist from: src/main.c",
    );
  });

  it("locks a selected changed file resource through operation/run", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "lock", path: "src/main.c", reason: "operationLock" }),
    );
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace"],
      lockOptions: { comment: "coordinating beta edit", stealLock: true },
    });
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({ resources: [scmProjectedResource({ path: "src/main.c" })] }),
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
      sourceControlProjection,
    });

    await controller.lockResource({
      contextValue: "subversionr.changedFile",
      resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
    });

    expect(ui.promptLockOptions).toHaveBeenCalledWith(["src/main.c"]);
    expect(operationClient.lock).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      paths: ["src/main.c"],
      comment: "coordinating beta edit",
      stealLock: true,
    });
    expect(refreshService.refreshTargets).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [{ path: "src/main.c", depth: "empty", reason: "operationLock" }],
    });
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR locked SVN resource: src/main.c",
    );
  });

  it("unlocks a selected locked file resource through operation/run", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "unlock", path: "src/main.c", reason: "operationUnlock" }),
    );
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace"],
      unlockOptions: { breakLock: true },
    });
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        resources: [
          scmProjectedResource({
            path: "src/main.c",
            lock: {
              token: "opaquelocktoken:1",
              owner: "alice",
              comment: "editing",
              createdDate: "2026-06-25T00:00:00Z",
              expiresDate: null,
              isRemote: false,
            },
          }),
        ],
      }),
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
      sourceControlProjection,
    });

    await controller.unlockResource({
      contextValue: "subversionr.changedFile.baseDiffable.locked",
      resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
    });

    expect(ui.promptUnlockOptions).toHaveBeenCalledWith(["src/main.c"]);
    expect(operationClient.unlock).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      paths: ["src/main.c"],
      breakLock: true,
    });
    expect(refreshService.refreshTargets).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [{ path: "src/main.c", depth: "empty", reason: "operationUnlock" }],
    });
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR unlocked SVN resource: src/main.c",
    );
  });

  it("locks a selected working-copy metadata file resource through operation/run", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "lock", path: "src/needs-lock.c", reason: "operationLock" }),
    );
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace"],
      lockOptions: { comment: "coordinate metadata-only file edit", stealLock: false },
    });
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        resources: [scmWorkingCopyMetadataProjectedResource({ path: "src/needs-lock.c", needsLock: true })],
      }),
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
      sourceControlProjection,
    });

    await controller.lockResource({
      contextValue: "subversionr.workingCopyMetadataFile",
      subversionrResourceKind: "file",
      resourceUri: { fsPath: "C:\\workspace\\src\\needs-lock.c" },
    });

    expect(ui.promptLockOptions).toHaveBeenCalledWith(["src/needs-lock.c"]);
    expect(operationClient.lock).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      paths: ["src/needs-lock.c"],
      comment: "coordinate metadata-only file edit",
      stealLock: false,
    });
    expect(refreshService.refreshTargets).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [{ path: "src/needs-lock.c", depth: "empty", reason: "operationLock" }],
    });
  });

  it("unlocks a selected working-copy metadata file resource through operation/run", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "unlock", path: "src/locked.c", reason: "operationUnlock" }),
    );
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace"],
      unlockOptions: { breakLock: false },
    });
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        resources: [
          scmWorkingCopyMetadataProjectedResource({
            path: "src/locked.c",
            lock: {
              token: "opaquelocktoken:1",
              owner: "alice",
              comment: "editing",
              createdDate: "2026-06-25T00:00:00Z",
              expiresDate: null,
              isRemote: false,
            },
          }),
        ],
      }),
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
      sourceControlProjection,
    });

    await controller.unlockResource({
      contextValue: "subversionr.workingCopyMetadataFile.locked",
      subversionrResourceKind: "file",
      resourceUri: { fsPath: "C:\\workspace\\src\\locked.c" },
    });

    expect(ui.promptUnlockOptions).toHaveBeenCalledWith(["src/locked.c"]);
    expect(operationClient.unlock).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      paths: ["src/locked.c"],
      breakLock: false,
    });
    expect(refreshService.refreshTargets).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [{ path: "src/locked.c", depth: "empty", reason: "operationUnlock" }],
    });
  });

  it("cancels lock before operation/run when lock options are dismissed", async () => {
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "lock", path: "src/main.c", reason: "operationLock" }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"], lockOptions: undefined });
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({ resources: [scmProjectedResource({ path: "src/main.c" })] }),
    });
    const controller = commandController(
      fakeDiscoveryService({ candidates: [discoveryCandidate()] }),
      fakeSessionService({ sessions: [repositorySession()] }),
      ui,
      {
        operationClient,
        sourceControlProjection,
      },
    );

    await controller.lockResource({
      contextValue: "subversionr.changedFile",
      resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
    });

    expect(ui.promptLockOptions).toHaveBeenCalledWith(["src/main.c"]);
    expect(operationClient.lock).not.toHaveBeenCalled();
  });

  it("cancels unlock before operation/run when unlock options are dismissed", async () => {
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "unlock", path: "src/main.c", reason: "operationUnlock" }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"], unlockOptions: undefined });
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        resources: [
          scmProjectedResource({
            path: "src/main.c",
            lock: {
              token: "opaquelocktoken:1",
              owner: "alice",
              comment: "editing",
              createdDate: "2026-06-25T00:00:00Z",
              expiresDate: null,
              isRemote: false,
            },
          }),
        ],
      }),
    });
    const controller = commandController(
      fakeDiscoveryService({ candidates: [discoveryCandidate()] }),
      fakeSessionService({ sessions: [repositorySession()] }),
      ui,
      {
        operationClient,
        sourceControlProjection,
      },
    );

    await controller.unlockResource({
      contextValue: "subversionr.changedFile.baseDiffable.locked",
      resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
    });

    expect(ui.promptUnlockOptions).toHaveBeenCalledWith(["src/main.c"]);
    expect(operationClient.unlock).not.toHaveBeenCalled();
  });

  it("rejects unlock for an unlocked resource even if the menu context is forged", async () => {
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "unlock", path: "src/main.c", reason: "operationUnlock" }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({ resources: [scmProjectedResource({ path: "src/main.c" })] }),
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      operationClient,
      sourceControlProjection,
    });

    await controller.unlockResource({
      contextValue: "subversionr.changedFile.baseDiffable.locked",
      resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
    });

    expect(operationClient.unlock).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_RESOURCE_UNLOCK_TARGET_INVALID",
    );
  });

  it("commits eligible resources from an SVN changelist group with a restrictive changelist filter", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "commit", path: "src/review.c", reason: "operationCommit", revision: 8 }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"], commitMessage: "commit review changelist" });
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({ resources: [scmChangelistProjectedResource({ path: "src/review.c" })] }),
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
      sourceControlProjection,
    });

    await controller.commitChangelist({
      subversionrRepositoryId: "repo-uuid:C:/workspace",
      subversionrChangelistName: "review",
    });

    expect(sourceControlProjection.getProjection).toHaveBeenCalledWith("repo-uuid:C:/workspace");
    expect(operationClient.commit).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      paths: ["src/review.c"],
      message: "commit review changelist",
      depth: "empty",
      changelists: ["review"],
      keepLocks: false,
      keepChangelists: false,
      commitAsOperations: false,
      includeFileExternals: false,
      includeDirExternals: false,
    });
    expect(ui.clearCommitMessage).toHaveBeenCalledWith("repo-uuid:C:/workspace");
  });

  it.each([
    "subversionr.changedFile.changelisted",
    "subversionr.changedFile.changelisted.locked",
    "subversionr.changedFile.baseDiffable.changelisted",
    "subversionr.changedFile.baseDiffable.changelisted.locked",
  ])("commits a %s resource from an SVN changelist group", async (contextValue) => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "commit", path: "src/review.c", reason: "operationCommit", revision: 8 }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"], commitMessage: "commit review changelist" });
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        resources: [
          {
            ...scmChangelistProjectedResource({ path: "src/review.c" }),
            contextValue,
          },
        ],
      }),
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
      sourceControlProjection,
    });

    await controller.commitChangelist({
      subversionrRepositoryId: "repo-uuid:C:/workspace",
      subversionrChangelistName: "review",
    });

    expect(operationClient.commit).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      paths: ["src/review.c"],
      message: "commit review changelist",
      depth: "empty",
      changelists: ["review"],
      keepLocks: false,
      keepChangelists: false,
      commitAsOperations: false,
      includeFileExternals: false,
      includeDirExternals: false,
    });
    expect(ui.clearCommitMessage).toHaveBeenCalledWith("repo-uuid:C:/workspace");
  });

  it("reverts resources from an SVN changelist group with a restrictive changelist filter", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "revert", path: "src/review.c", reason: "operationRevert" }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({ resources: [scmChangelistProjectedResource({ path: "src/review.c" })] }),
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
      sourceControlProjection,
    });

    await controller.revertChangelist({
      subversionrRepositoryId: "repo-uuid:C:/workspace",
      subversionrChangelistName: "review",
    });

    expect(ui.confirmRevertResource).toHaveBeenCalledWith("src/review.c");
    expect(operationClient.revert).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      paths: ["src/review.c"],
      depth: "empty",
      changelists: ["review"],
      clearChangelists: false,
      metadataOnly: false,
      addedKeepLocal: false,
    });
    expect(refreshService.refreshTargets).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [{ path: "src/review.c", depth: "empty", reason: "operationRevert" }],
    });
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR reverted SVN changelist review: src/review.c",
    );
  });

  it("reverts changelisted projected resources from an SVN changelist group", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "revert", path: "src/review.c", reason: "operationRevert" }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        resources: [
          {
            ...scmChangelistProjectedResource({ path: "src/review.c" }),
            contextValue: "subversionr.changedFile.changelisted",
          },
        ],
      }),
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
      sourceControlProjection,
    });

    await controller.revertChangelist({
      subversionrRepositoryId: "repo-uuid:C:/workspace",
      subversionrChangelistName: "review",
    });

    expect(ui.confirmRevertResource).toHaveBeenCalledWith("src/review.c");
    expect(operationClient.revert).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      paths: ["src/review.c"],
      depth: "empty",
      changelists: ["review"],
      clearChangelists: false,
      metadataOnly: false,
      addedKeepLocal: false,
    });
    expect(refreshService.refreshTargets).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [{ path: "src/review.c", depth: "empty", reason: "operationRevert" }],
    });
  });

  it("confirms and reverts all eligible local SVN resources from the current projection", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({
        kind: "revert",
        path: "src/main.c",
        reconcile: {
          targets: [
            { path: "src/main.c", depth: "empty", reason: "operationRevert" },
            { path: "src/module", depth: "empty", reason: "operationRevert" },
            { path: "src/review.c", depth: "empty", reason: "operationRevert" },
            { path: "src/conflicted.txt", depth: "empty", reason: "operationRevert" },
          ],
          requiresFullReconcile: false,
        },
      }),
    );
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        resources: [
          scmProjectedResource({ path: "src/main.c" }),
          scmProjectedResource({ path: "src/module", kind: "dir" }),
          {
            ...scmChangelistProjectedResource({ path: "src/review.c" }),
            contextValue: "subversionr.changedFile.changelisted",
          },
          scmConflictedProjectedResource({ path: "src/conflicted.txt" }),
          scmUnversionedProjectedResource({ path: "scratch.txt" }),
        ],
      }),
    });
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
      sourceControlProjection,
    });

    await controller.revertAll("repo-uuid:C:/workspace");

    expect(sourceControlProjection.getProjection).toHaveBeenCalledWith("repo-uuid:C:/workspace");
    expect(ui.confirmRevertResource).toHaveBeenCalledWith(
      "src/conflicted.txt, src/main.c, src/module, src/review.c",
    );
    expect(operationClient.revert).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      paths: ["src/conflicted.txt", "src/main.c", "src/module", "src/review.c"],
      depth: "empty",
      changelists: [],
      clearChangelists: false,
      metadataOnly: false,
      addedKeepLocal: false,
    });
    expect(refreshService.refreshTargets).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [
        { path: "src/main.c", depth: "empty", reason: "operationRevert" },
        { path: "src/module", depth: "empty", reason: "operationRevert" },
        { path: "src/review.c", depth: "empty", reason: "operationRevert" },
        { path: "src/conflicted.txt", depth: "empty", reason: "operationRevert" },
      ],
    });
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR reverted 4 SVN resources: src/conflicted.txt, src/main.c, src/module, src/review.c",
    );
  });

  it("confirms and deletes a selected unversioned file before refreshing its status", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(operationResponse());
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({ resources: [scmUnversionedProjectedResource({ path: "scratch.txt" })] }),
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
      sourceControlProjection,
    });

    await controller.deleteUnversionedResource({
      contextValue: "subversionr.unversioned",
      subversionrResourceKind: "file",
      subversionrProjectionGeneration: 11,
      resourceUri: { fsPath: "C:\\workspace\\scratch.txt" },
    });

    expect(ui.confirmDeleteUnversionedResources).toHaveBeenCalledWith(["scratch.txt"]);
    expect(sourceControlProjection.getProjection).toHaveBeenCalledWith("repo-uuid:C:/workspace");
    expect(ui.deleteLocalFile).toHaveBeenCalledWith("C:/workspace/scratch.txt", { recursive: false });
    expect(operationClient.remove).not.toHaveBeenCalled();
    expect(operationClient.add).not.toHaveBeenCalled();
    expect(refreshService.refreshResource).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: "scratch.txt",
    });
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR deleted unversioned SVN item: scratch.txt",
    );
  });

  it("confirms and deletes a refreshed installed Source Control unversioned file", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        generation: 2,
        resources: [scmUnversionedProjectedResource({ path: "scratch.txt", generation: 2 })],
      }),
    });
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      sourceControlProjection,
    });

    await controller.deleteUnversionedResource({
      contextValue: "subversionr.unversioned",
      subversionrResourceKind: "file",
      subversionrProjectionGeneration: 2,
      resourceUri: {
        scheme: "file",
        fsPath: "C:\\workspace\\scratch.txt",
        path: "/c:/workspace/scratch.txt",
      },
    });

    expect(ui.confirmDeleteUnversionedResources).toHaveBeenCalledWith(["scratch.txt"]);
    expect(ui.deleteLocalFile).toHaveBeenCalledWith("C:/workspace/scratch.txt", { recursive: false });
    expect(refreshService.refreshResource).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: "scratch.txt",
    });
  });

  it("does not wait for passive command error notification dismissal", async () => {
    const unknownError = new Error("projection failed");
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => undefined);
    const sourceControlProjection = {
      getCommitAllTargets: vi.fn(() => commitAllTargets()),
      getProjection: vi.fn(() => {
        throw unknownError;
      }),
    };
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    ui.showErrorMessage.mockImplementationOnce(() => new Promise(() => undefined));
    const controller = commandController(
      fakeDiscoveryService({ candidates: [discoveryCandidate()] }),
      fakeSessionService({ sessions: [repositorySession()] }),
      ui,
      {
        sourceControlProjection,
      },
    );

    try {
      await expect(
        withTimeout(
          controller.deleteUnversionedResource({
            contextValue: "subversionr.unversioned",
            subversionrResourceKind: "file",
            subversionrProjectionGeneration: 11,
            resourceUri: { fsPath: "C:\\workspace\\scratch.txt" },
          }),
          50,
        ),
      ).resolves.toBeUndefined();

      expect(ui.showErrorMessage).toHaveBeenCalledWith(
        "SubversionR repository command failed: SUBVERSIONR_REPOSITORY_COMMAND_FAILED",
      );
      expect(consoleError).toHaveBeenCalledWith("SubversionR repository command failed.", unknownError);
    } finally {
      consoleError.mockRestore();
    }
  });

  it("does not delete an unversioned file when confirmation is cancelled", async () => {
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"], deleteUnversionedConfirmed: false });
    const refreshService = fakeRefreshService();
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({ resources: [scmUnversionedProjectedResource({ path: "scratch.txt" })] }),
    });
    const controller = commandController(
      fakeDiscoveryService({ candidates: [discoveryCandidate()] }),
      fakeSessionService({ sessions: [repositorySession()] }),
      ui,
      {
        refreshService,
        sourceControlProjection,
      },
    );

    await controller.deleteUnversionedResource({
      contextValue: "subversionr.unversioned",
      subversionrResourceKind: "file",
      subversionrProjectionGeneration: 11,
      resourceUri: { fsPath: "C:\\workspace\\scratch.txt" },
    });

    expect(ui.confirmDeleteUnversionedResources).toHaveBeenCalledWith(["scratch.txt"]);
    expect(sourceControlProjection.getProjection).toHaveBeenCalledWith("repo-uuid:C:/workspace");
    expect(ui.deleteLocalFile).not.toHaveBeenCalled();
    expect(refreshService.refreshResource).not.toHaveBeenCalled();
    expect(ui.showInformationMessage).not.toHaveBeenCalledWith(
      "SubversionR deleted unversioned SVN item: scratch.txt",
    );
  });

  it("confirms and recursively deletes a selected unversioned directory before refreshing its status", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const refreshService = fakeRefreshService();
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        resources: [scmUnversionedProjectedResource({ path: "scratch-dir", kind: "dir" })],
      }),
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      sourceControlProjection,
    });

    await controller.deleteUnversionedResource({
      contextValue: "subversionr.unversioned",
      subversionrResourceKind: "dir",
      subversionrProjectionGeneration: 11,
      resourceUri: { fsPath: "C:\\workspace\\scratch-dir" },
    });

    expect(ui.confirmDeleteUnversionedResources).toHaveBeenCalledWith(["scratch-dir"]);
    expect(sourceControlProjection.getProjection).toHaveBeenCalledWith("repo-uuid:C:/workspace");
    expect(ui.deleteLocalFile).toHaveBeenCalledWith("C:/workspace/scratch-dir", { recursive: true });
    expect(refreshService.refreshResource).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: "scratch-dir",
    });
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR deleted unversioned SVN item: scratch-dir",
    );
  });

  it("confirms and deletes multiple selected unversioned items before refreshing them together", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const refreshService = fakeRefreshService();
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        resources: [
          scmUnversionedProjectedResource({ path: "scratch.txt", kind: "file" }),
          scmUnversionedProjectedResource({ path: "temp-dir", kind: "dir" }),
        ],
      }),
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      sourceControlProjection,
    });

    await controller.deleteUnversionedResource(
      {
        contextValue: "subversionr.unversioned",
        subversionrResourceKind: "file",
        subversionrProjectionGeneration: 11,
        resourceUri: { fsPath: "C:\\workspace\\scratch.txt" },
      },
      {
        contextValue: "subversionr.unversioned",
        subversionrResourceKind: "dir",
        subversionrProjectionGeneration: 11,
        resourceUri: { fsPath: "C:\\workspace\\temp-dir" },
      },
    );

    expect(ui.confirmDeleteUnversionedResources).toHaveBeenCalledWith(["scratch.txt", "temp-dir"]);
    expect(sourceControlProjection.getProjection).toHaveBeenCalledWith("repo-uuid:C:/workspace");
    expect(ui.deleteLocalFile).toHaveBeenCalledWith("C:/workspace/scratch.txt", { recursive: false });
    expect(ui.deleteLocalFile).toHaveBeenCalledWith("C:/workspace/temp-dir", { recursive: true });
    expect(refreshService.refreshResource).not.toHaveBeenCalled();
    expect(refreshService.refreshTargets).not.toHaveBeenCalled();
    expect(refreshService.fullReconcileRepository).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
    });
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR deleted 2 unversioned SVN items.",
    );
  });

  it("confirms and deletes all projected unversioned items for an open repository", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(operationResponse());
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        resources: [
          scmProjectedResource({ path: "src/main.c", kind: "file" }),
          scmUnversionedProjectedResource({ path: "scratch.txt", kind: "file" }),
          scmUnversionedProjectedResource({ path: "temp-dir", kind: "dir" }),
        ],
      }),
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
      sourceControlProjection,
    });

    await controller.deleteAllUnversionedResources("repo-uuid:C:/workspace");

    expect(sourceControlProjection.getProjection).toHaveBeenCalledWith("repo-uuid:C:/workspace");
    expect(ui.confirmDeleteUnversionedResources).toHaveBeenCalledWith(["scratch.txt", "temp-dir"]);
    expect(ui.deleteLocalFile).toHaveBeenCalledWith("C:/workspace/scratch.txt", { recursive: false });
    expect(ui.deleteLocalFile).toHaveBeenCalledWith("C:/workspace/temp-dir", { recursive: true });
    expect(operationClient.remove).not.toHaveBeenCalled();
    expect(operationClient.add).not.toHaveBeenCalled();
    expect(refreshService.refreshResource).not.toHaveBeenCalled();
    expect(refreshService.refreshTargets).not.toHaveBeenCalled();
    expect(refreshService.fullReconcileRepository).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
    });
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR deleted 2 unversioned SVN items.",
    );
  });

  it("reports no-op delete-all when the current projection has no unversioned items", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const refreshService = fakeRefreshService();
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({ resources: [scmProjectedResource({ path: "src/main.c", kind: "file" })] }),
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      sourceControlProjection,
    });

    await controller.deleteAllUnversionedResources("repo-uuid:C:/workspace");

    expect(sourceControlProjection.getProjection).toHaveBeenCalledWith("repo-uuid:C:/workspace");
    expect(ui.confirmDeleteUnversionedResources).not.toHaveBeenCalled();
    expect(ui.deleteLocalFile).not.toHaveBeenCalled();
    expect(refreshService.refreshResource).not.toHaveBeenCalled();
    expect(refreshService.refreshTargets).not.toHaveBeenCalled();
    expect(ui.showWarningMessage).toHaveBeenCalledWith("No unversioned SVN items to delete.");
  });

  it("rejects multi-selected unversioned delete requests from different repositories before confirmation", async () => {
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace", "D:\\other-wc"] });
    const refreshService = fakeRefreshService();
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({ resources: [scmUnversionedProjectedResource({ path: "scratch.txt" })] }),
    });
    const controller = commandController(
      fakeDiscoveryService({ candidates: [discoveryCandidate()] }),
      fakeSessionService({
        sessions: [
          repositorySession(),
          repositorySession({ repositoryId: "repo-2:D:/other-wc", workingCopyRoot: "D:\\other-wc" }),
        ],
      }),
      ui,
      {
        refreshService,
        sourceControlProjection,
      },
    );

    await controller.deleteUnversionedResource(
      {
        contextValue: "subversionr.unversioned",
        subversionrResourceKind: "file",
        subversionrProjectionGeneration: 11,
        resourceUri: { fsPath: "C:\\workspace\\scratch.txt" },
      },
      {
        contextValue: "subversionr.unversioned",
        subversionrResourceKind: "file",
        subversionrProjectionGeneration: 11,
        resourceUri: { fsPath: "D:\\other-wc\\other.txt" },
      },
    );

    expect(ui.confirmDeleteUnversionedResources).not.toHaveBeenCalled();
    expect(ui.deleteLocalFile).not.toHaveBeenCalled();
    expect(refreshService.refreshResource).not.toHaveBeenCalled();
    expect(refreshService.refreshTargets).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_RESOURCE_DELETE_UNVERSIONED_TARGET_INVALID",
    );
  });

  it("rejects forged unversioned delete requests when the current projection is not unversioned", async () => {
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const refreshService = fakeRefreshService();
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({ resources: [scmProjectedResource({ path: "scratch.txt" })] }),
    });
    const controller = commandController(
      fakeDiscoveryService({ candidates: [discoveryCandidate()] }),
      fakeSessionService({ sessions: [repositorySession()] }),
      ui,
      {
        refreshService,
        sourceControlProjection,
      },
    );

    await controller.deleteUnversionedResource({
      contextValue: "subversionr.unversioned",
      subversionrResourceKind: "file",
      subversionrProjectionGeneration: 11,
      resourceUri: { fsPath: "C:\\workspace\\scratch.txt" },
    });

    expect(sourceControlProjection.getProjection).toHaveBeenCalledWith("repo-uuid:C:/workspace");
    expect(ui.confirmDeleteUnversionedResources).not.toHaveBeenCalled();
    expect(ui.deleteLocalFile).not.toHaveBeenCalled();
    expect(refreshService.refreshResource).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_RESOURCE_DELETE_UNVERSIONED_TARGET_INVALID",
    );
  });

  it("rejects stale projected unversioned delete requests before deleting local files", async () => {
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const refreshService = fakeRefreshService();
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        generation: 12,
        resources: [scmUnversionedProjectedResource({ path: "scratch.txt", generation: 12 })],
      }),
    });
    const controller = commandController(
      fakeDiscoveryService({ candidates: [discoveryCandidate()] }),
      fakeSessionService({ sessions: [repositorySession()] }),
      ui,
      {
        refreshService,
        sourceControlProjection,
      },
    );

    await controller.deleteUnversionedResource({
      contextValue: "subversionr.unversioned",
      subversionrResourceKind: "file",
      subversionrProjectionGeneration: 11,
      resourceUri: { fsPath: "C:\\workspace\\scratch.txt" },
    });

    expect(sourceControlProjection.getProjection).toHaveBeenCalledWith("repo-uuid:C:/workspace");
    expect(ui.confirmDeleteUnversionedResources).not.toHaveBeenCalled();
    expect(ui.deleteLocalFile).not.toHaveBeenCalled();
    expect(refreshService.refreshResource).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_RESOURCE_DELETE_UNVERSIONED_TARGET_INVALID",
    );
  });

  it("rejects unversioned delete requests when the resource kind does not match the current projection", async () => {
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const refreshService = fakeRefreshService();
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({ resources: [scmUnversionedProjectedResource({ path: "scratch.txt", kind: "file" })] }),
    });
    const controller = commandController(
      fakeDiscoveryService({ candidates: [discoveryCandidate()] }),
      fakeSessionService({ sessions: [repositorySession()] }),
      ui,
      {
        refreshService,
        sourceControlProjection,
      },
    );

    await controller.deleteUnversionedResource({
      contextValue: "subversionr.unversioned",
      subversionrResourceKind: "dir",
      subversionrProjectionGeneration: 11,
      resourceUri: { fsPath: "C:\\workspace\\scratch.txt" },
    });

    expect(sourceControlProjection.getProjection).toHaveBeenCalledWith("repo-uuid:C:/workspace");
    expect(ui.confirmDeleteUnversionedResources).not.toHaveBeenCalled();
    expect(ui.deleteLocalFile).not.toHaveBeenCalled();
    expect(refreshService.refreshResource).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_RESOURCE_DELETE_UNVERSIONED_TARGET_INVALID",
    );
  });

  it("confirms and removes a selected changed SCM resource through operation/run", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "remove", path: "src/old.c", reason: "operationRemove" }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({ resources: [scmProjectedResource({ path: "src/old.c" })] }),
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
      sourceControlProjection,
    });

    await controller.removeResource({
      contextValue: "subversionr.changedFile",
      resourceUri: { fsPath: "C:\\workspace\\src\\old.c" },
    });

    expect(ui.confirmRemoveResource).toHaveBeenCalledWith("src/old.c");
    expect(operationClient.remove).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      paths: ["src/old.c"],
      force: false,
      keepLocal: false,
    });
    expect(refreshService.refreshTargets).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [{ path: "src/old.c", depth: "empty", reason: "operationRemove" }],
    });
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR removed SVN resource: src/old.c",
    );
  });

  it("confirms and removes multiple selected changed SCM resources through one operation/run request", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const removeResponse: OperationRunResponse = {
      ...operationResponse({ kind: "remove", path: "src/old.c", reason: "operationRemove" }),
      touchedPaths: ["src/old.c", "src/other.c"],
      summary: { affectedPaths: 2, skippedPaths: 0 },
      reconcile: {
        targets: [
          { path: "src/old.c", depth: "empty", reason: "operationRemove" },
          { path: "src/other.c", depth: "empty", reason: "operationRemove" },
        ],
        requiresFullReconcile: false,
      },
    };
    const operationClient = fakeOperationClient(removeResponse);
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        resources: [
          scmProjectedResource({ path: "src/old.c" }),
          scmProjectedResource({ path: "src/other.c" }),
        ],
      }),
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
      sourceControlProjection,
    });

    await controller.removeResource([
      {
        contextValue: "subversionr.changedFile",
        resourceUri: { fsPath: "C:\\workspace\\src\\old.c" },
      },
      {
        contextValue: "subversionr.changedFile",
        resourceUri: { fsPath: "C:\\workspace\\src\\other.c" },
      },
    ]);

    expect(ui.confirmRemoveResource).toHaveBeenCalledWith("src/old.c, src/other.c");
    expect(operationClient.remove).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      paths: ["src/old.c", "src/other.c"],
      force: false,
      keepLocal: false,
    });
    expect(refreshService.refreshTargets).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [
        { path: "src/old.c", depth: "empty", reason: "operationRemove" },
        { path: "src/other.c", depth: "empty", reason: "operationRemove" },
      ],
    });
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR removed 2 SVN resources: src/old.c, src/other.c",
    );
  });

  it("confirms and removes a selected changed SCM resource while keeping local content", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "remove", path: "src/old.c", reason: "operationRemove" }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({ resources: [scmProjectedResource({ path: "src/old.c" })] }),
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
      sourceControlProjection,
    });

    await controller.removeResourceKeepLocal({
      contextValue: "subversionr.changedFile",
      resourceUri: { fsPath: "C:\\workspace\\src\\old.c" },
    });

    expect(ui.confirmRemoveResourceKeepLocal).toHaveBeenCalledWith("src/old.c");
    expect(operationClient.remove).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      paths: ["src/old.c"],
      force: false,
      keepLocal: true,
    });
    expect(refreshService.refreshTargets).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [{ path: "src/old.c", depth: "empty", reason: "operationRemove" }],
    });
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR removed SVN resource but kept local item: src/old.c",
    );
  });

  it.each([
    [
      "removeResource",
      "subversionr.changedFile.changelisted",
      "src/old.c",
      scmChangelistProjectedResource({ path: "src/old.c" }),
      false,
    ],
    [
      "removeResource",
      "subversionr.changedFile.baseDiffable.changelisted",
      "src/old.c",
      scmChangelistProjectedResource({ path: "src/old.c" }),
      false,
    ],
    [
      "removeResource",
      "subversionr.changedDirectory.changelisted",
      "src/module",
      scmChangelistProjectedResource({ path: "src/module", kind: "directory" }),
      false,
    ],
    [
      "removeResource",
      "subversionr.conflicted.changelisted",
      "src/conflicted.txt",
      scmConflictedProjectedResource({ path: "src/conflicted.txt", changelist: "review" }),
      false,
    ],
    [
      "removeResourceKeepLocal",
      "subversionr.changedFile.changelisted",
      "src/old.c",
      scmChangelistProjectedResource({ path: "src/old.c" }),
      true,
    ],
    [
      "removeResourceKeepLocal",
      "subversionr.changedFile.baseDiffable.changelisted",
      "src/old.c",
      scmChangelistProjectedResource({ path: "src/old.c" }),
      true,
    ],
    [
      "removeResourceKeepLocal",
      "subversionr.changedDirectory.changelisted",
      "src/module",
      scmChangelistProjectedResource({ path: "src/module", kind: "directory" }),
      true,
    ],
    [
      "removeResourceKeepLocal",
      "subversionr.conflicted.changelisted",
      "src/conflicted.txt",
      scmConflictedProjectedResource({ path: "src/conflicted.txt", changelist: "review" }),
      true,
    ],
  ])("confirms and removes a selected %s %s SCM resource through operation/run", async (commandName, contextValue, repositoryPath, projectionResource, keepLocal) => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "remove", path: repositoryPath, reason: "operationRemove" }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({ resources: [projectionResource] }),
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
      sourceControlProjection,
    });

    const resourceState = {
      contextValue,
      resourceUri: { fsPath: repositoryPathToFsPath("C:\\workspace", repositoryPath) },
    };
    if (commandName === "removeResourceKeepLocal") {
      await controller.removeResourceKeepLocal(resourceState);
      expect(ui.confirmRemoveResourceKeepLocal).toHaveBeenCalledWith(repositoryPath);
      expect(ui.confirmRemoveResource).not.toHaveBeenCalled();
    } else {
      await controller.removeResource(resourceState);
      expect(ui.confirmRemoveResource).toHaveBeenCalledWith(repositoryPath);
      expect(ui.confirmRemoveResourceKeepLocal).not.toHaveBeenCalled();
    }
    expect(operationClient.remove).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      paths: [repositoryPath],
      force: false,
      keepLocal,
    });
    expect(refreshService.refreshTargets).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [{ path: repositoryPath, depth: "empty", reason: "operationRemove" }],
    });
  });

  it("confirms and removes multiple selected changed SCM resources while keeping local content", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const removeResponse: OperationRunResponse = {
      ...operationResponse({ kind: "remove", path: "src/old.c", reason: "operationRemove" }),
      touchedPaths: ["src/old.c", "src/other.c"],
      summary: { affectedPaths: 2, skippedPaths: 0 },
      reconcile: {
        targets: [
          { path: "src/old.c", depth: "empty", reason: "operationRemove" },
          { path: "src/other.c", depth: "empty", reason: "operationRemove" },
        ],
        requiresFullReconcile: false,
      },
    };
    const operationClient = fakeOperationClient(removeResponse);
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        resources: [
          scmProjectedResource({ path: "src/old.c" }),
          scmProjectedResource({ path: "src/other.c" }),
        ],
      }),
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
      sourceControlProjection,
    });

    await controller.removeResourceKeepLocal([
      {
        contextValue: "subversionr.changedFile",
        resourceUri: { fsPath: "C:\\workspace\\src\\old.c" },
      },
      {
        contextValue: "subversionr.changedFile",
        resourceUri: { fsPath: "C:\\workspace\\src\\other.c" },
      },
    ]);

    expect(ui.confirmRemoveResourceKeepLocal).toHaveBeenCalledWith("src/old.c, src/other.c");
    expect(operationClient.remove).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      paths: ["src/old.c", "src/other.c"],
      force: false,
      keepLocal: true,
    });
    expect(refreshService.refreshTargets).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [
        { path: "src/old.c", depth: "empty", reason: "operationRemove" },
        { path: "src/other.c", depth: "empty", reason: "operationRemove" },
      ],
    });
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR removed 2 SVN resources but kept local items: src/old.c, src/other.c",
    );
  });

  it.each(writeOperationScenarios())(
    "rejects duplicate selected paths for $label before confirmation or operation/run",
    async (scenario) => {
      const refreshService = fakeRefreshService();
      const operationClient = fakeOperationClient(operationResponse());
      const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
      const controller = commandController(
        fakeDiscoveryService({ candidates: [discoveryCandidate()] }),
        fakeSessionService({ sessions: [repositorySession()] }),
        ui,
        {
          refreshService,
          operationClient,
          sourceControlProjection: fakeSourceControlProjection({ projection: scenario.validProjection() }),
        },
      );

      await scenario.invoke(controller, [
        scmWriteState(scenario.contextValue, scenario.path),
        scmWriteState(scenario.contextValue, scenario.path.toUpperCase()),
      ]);

      expect(operationClient[scenario.clientMethod]).not.toHaveBeenCalled();
      expectWriteConfirmationsNotCalled(ui);
      expect(ui.showErrorMessage).toHaveBeenCalledWith(
        `SubversionR repository command failed: ${scenario.errorCode}`,
      );
    },
  );

  it.each(writeOperationScenarios())(
    "rejects mixed repository selected paths for $label before confirmation or operation/run",
    async (scenario) => {
      const refreshService = fakeRefreshService();
      const operationClient = fakeOperationClient(operationResponse());
      const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace", "D:\\other-wc"] });
      const controller = commandController(
        fakeDiscoveryService({ candidates: [discoveryCandidate()] }),
        fakeSessionService({
          sessions: [
            repositorySession(),
            repositorySession({ repositoryId: "repo-2:D:/other-wc", workingCopyRoot: "D:\\other-wc" }),
          ],
        }),
        ui,
        {
          refreshService,
          operationClient,
          sourceControlProjection: fakeSourceControlProjection({ projection: scenario.validProjection() }),
        },
      );

      await scenario.invoke(controller, [
        scmWriteState(scenario.contextValue, scenario.path),
        scmWriteState(scenario.contextValue, scenario.path, { root: "D:\\other-wc" }),
      ]);

      expect(operationClient[scenario.clientMethod]).not.toHaveBeenCalled();
      expectWriteConfirmationsNotCalled(ui);
      expect(ui.showErrorMessage).toHaveBeenCalledWith(
        `SubversionR repository command failed: ${scenario.errorCode}`,
      );
    },
  );

  it.each(writeOperationScenarios())(
    "rejects repository root selected paths for $label before confirmation or operation/run",
    async (scenario) => {
      const refreshService = fakeRefreshService();
      const operationClient = fakeOperationClient(operationResponse());
      const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
      const controller = commandController(
        fakeDiscoveryService({ candidates: [discoveryCandidate()] }),
        fakeSessionService({ sessions: [repositorySession()] }),
        ui,
        {
          refreshService,
          operationClient,
          sourceControlProjection: fakeSourceControlProjection({ projection: scenario.validProjection() }),
        },
      );

      await scenario.invoke(controller, [scmWriteState(scenario.contextValue, ".")]);

      expect(operationClient[scenario.clientMethod]).not.toHaveBeenCalled();
      expectWriteConfirmationsNotCalled(ui);
      expect(ui.showErrorMessage).toHaveBeenCalledWith(
        `SubversionR repository command failed: ${scenario.errorCode}`,
      );
    },
  );

  it.each(writeOperationScenarios())(
    "rejects stale projection generations for $label before confirmation or operation/run",
    async (scenario) => {
      const refreshService = fakeRefreshService();
      const operationClient = fakeOperationClient(operationResponse());
      const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
      const controller = commandController(
        fakeDiscoveryService({ candidates: [discoveryCandidate()] }),
        fakeSessionService({ sessions: [repositorySession()] }),
        ui,
        {
          refreshService,
          operationClient,
          sourceControlProjection: fakeSourceControlProjection({ projection: scenario.validProjection({ generation: 12 }) }),
        },
      );

      await scenario.invoke(controller, [
        scmWriteState(scenario.contextValue, scenario.path, { generation: 11 }),
      ]);

      expect(operationClient[scenario.clientMethod]).not.toHaveBeenCalled();
      expectWriteConfirmationsNotCalled(ui);
      expect(ui.showErrorMessage).toHaveBeenCalledWith(
        `SubversionR repository command failed: ${scenario.errorCode}`,
      );
    },
  );

  it.each(writeOperationScenarios())(
    "rejects selected paths no longer authorized by the current projection for $label",
    async (scenario) => {
      const refreshService = fakeRefreshService();
      const operationClient = fakeOperationClient(operationResponse());
      const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
      const controller = commandController(
        fakeDiscoveryService({ candidates: [discoveryCandidate()] }),
        fakeSessionService({ sessions: [repositorySession()] }),
        ui,
        {
          refreshService,
          operationClient,
          sourceControlProjection: fakeSourceControlProjection({ projection: scenario.unauthorizedProjection() }),
        },
      );

      await scenario.invoke(controller, [
        scmWriteState(scenario.contextValue, scenario.path, { generation: 11 }),
      ]);

      expect(operationClient[scenario.clientMethod]).not.toHaveBeenCalled();
      expectWriteConfirmationsNotCalled(ui);
      expect(ui.showErrorMessage).toHaveBeenCalledWith(
        `SubversionR repository command failed: ${scenario.errorCode}`,
      );
    },
  );

  it("prompts and moves a selected SVN resource through operation/run", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({
        kind: "move",
        path: "src/new.c",
        reconcile: {
          targets: [
            { path: "src", depth: "immediates", reason: "operationMove" },
          ],
          requiresFullReconcile: false,
        },
      }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"], moveDestination: "src/new.c" });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
    });

    await controller.moveResource({
      contextValue: "subversionr.changedFile",
      subversionrResourceKind: "file",
      resourceUri: { fsPath: "C:\\workspace\\src\\old.c" },
    });

    expect(ui.promptMoveDestination).toHaveBeenCalledWith("src/old.c");
    expect(operationClient.move).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      sourcePath: "src/old.c",
      destinationPath: "src/new.c",
      makeParents: false,
    });
    expect(refreshService.refreshTargets).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [
        { path: "src", depth: "immediates", reason: "operationMove" },
      ],
    });
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR moved SVN resource: src/old.c -> src/new.c",
    );
  });

  it("prompts and moves an editor SVN resource using the projection canonical path", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({
        kind: "move",
        path: "src/new.c",
        reconcile: {
          targets: [
            { path: "src", depth: "immediates", reason: "operationMove" },
          ],
          requiresFullReconcile: false,
        },
      }),
    );
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        resources: [scmProjectedResource({ path: "src/old.c" })],
      }),
    });
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"], moveDestination: "src/new.c" });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
      sourceControlProjection,
    });

    await controller.moveResource({ scheme: "file", fsPath: "C:\\workspace\\SRC\\OLD.C" });

    expect(sourceControlProjection.getProjection).toHaveBeenCalledWith("repo-uuid:C:/workspace");
    expect(ui.promptMoveDestination).toHaveBeenCalledWith("src/old.c");
    expect(operationClient.move).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      sourcePath: "src/old.c",
      destinationPath: "src/new.c",
      makeParents: false,
    });
    expect(refreshService.refreshTargets).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [
        { path: "src", depth: "immediates", reason: "operationMove" },
      ],
    });
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR moved SVN resource: src/old.c -> src/new.c",
    );
  });

  it("prompts and moves an Explorer SVN resource URI without a movable projection", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({
        kind: "move",
        path: "src/new.c",
        reconcile: {
          targets: [
            { path: "src", depth: "immediates", reason: "operationMove" },
          ],
          requiresFullReconcile: false,
        },
      }),
    );
    const sourceControlProjection = fakeSourceControlProjection({ projection: undefined });
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"], moveDestination: "src/new.c" });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
      sourceControlProjection,
    });

    await controller.moveResource({ scheme: "file", fsPath: "C:\\workspace\\src\\old.c" });

    expect(sourceControlProjection.getProjection).toHaveBeenCalledWith("repo-uuid:C:/workspace");
    expect(ui.promptMoveDestination).toHaveBeenCalledWith("src/old.c");
    expect(operationClient.move).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      sourcePath: "src/old.c",
      destinationPath: "src/new.c",
      makeParents: false,
    });
    expect(refreshService.refreshTargets).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [
        { path: "src", depth: "immediates", reason: "operationMove" },
      ],
    });
  });

  it.each([
    "subversionr.changedFile.changelisted",
    "subversionr.changedFile.baseDiffable.changelisted",
    "subversionr.conflicted.changelisted",
  ])("prompts and moves a selected %s SCM resource through operation/run", async (contextValue) => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({
        kind: "move",
        path: "src/new.c",
        reconcile: {
          targets: [
            { path: "src", depth: "immediates", reason: "operationMove" },
          ],
          requiresFullReconcile: false,
        },
      }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"], moveDestination: "src/new.c" });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
    });

    await controller.moveResource({
      contextValue,
      subversionrResourceKind: "file",
      resourceUri: { fsPath: "C:\\workspace\\src\\old.c" },
    });

    expect(ui.promptMoveDestination).toHaveBeenCalledWith("src/old.c");
    expect(operationClient.move).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      sourcePath: "src/old.c",
      destinationPath: "src/new.c",
      makeParents: false,
    });
    expect(refreshService.refreshTargets).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [
        { path: "src", depth: "immediates", reason: "operationMove" },
      ],
    });
  });

  it.each([
    ["subversionr.changedDirectory", "src/module"],
    ["subversionr.changedDirectory.changelisted", "src/module"],
  ])("prompts and moves a selected %s SCM resource through operation/run", async (contextValue, repositoryPath) => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({
        kind: "move",
        path: "src/module-renamed",
        reconcile: {
          targets: [
            { path: "src", depth: "immediates", reason: "operationMove" },
          ],
          requiresFullReconcile: false,
        },
      }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"], moveDestination: "src/module-renamed" });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
    });

    await controller.moveResource({
      contextValue,
      subversionrResourceKind: "dir",
      resourceUri: { fsPath: "C:\\workspace\\src\\module" },
    });

    expect(ui.promptMoveDestination).toHaveBeenCalledWith(repositoryPath);
    expect(operationClient.move).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      sourcePath: repositoryPath,
      destinationPath: "src/module-renamed",
      makeParents: false,
    });
    expect(refreshService.refreshTargets).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [
        { path: "src", depth: "immediates", reason: "operationMove" },
      ],
    });
  });

  it("confirms and resolves a selected conflicted SCM resource through operation/run", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "resolve", path: "src/conflicted.txt", reason: "operationResolve" }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"], resolveChoice: "theirsFull" });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
    });

    await controller.resolveResource({
      contextValue: "subversionr.conflicted",
      resourceUri: { fsPath: "C:\\workspace\\src\\conflicted.txt" },
    });

    expect(ui.promptResolveChoice).toHaveBeenCalledWith("src/conflicted.txt");
    expect(operationClient.resolve).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      paths: ["src/conflicted.txt"],
      depth: "empty",
      choice: "theirsFull",
    });
    expect(refreshService.refreshTargets).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [{ path: "src/conflicted.txt", depth: "empty", reason: "operationResolve" }],
    });
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR resolved SVN conflict with Theirs full: src/conflicted.txt",
    );
  });

  it("confirms and resolves a selected conflicted SCM resource with a hunk conflict strategy", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "resolve", path: "src/conflicted.txt", reason: "operationResolve" }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"], resolveChoice: "theirsConflict" });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
    });

    await controller.resolveResource({
      contextValue: "subversionr.conflicted",
      resourceUri: { fsPath: "C:\\workspace\\src\\conflicted.txt" },
    });

    expect(operationClient.resolve).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      paths: ["src/conflicted.txt"],
      depth: "empty",
      choice: "theirsConflict",
    });
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR resolved SVN conflict with Theirs conflict: src/conflicted.txt",
    );
  });

  it("confirms and resolves a selected changelisted conflicted SCM resource through operation/run", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "resolve", path: "src/conflicted.txt", reason: "operationResolve" }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"], resolveChoice: "working" });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
    });

    await controller.resolveResource({
      contextValue: "subversionr.conflicted.changelisted",
      resourceUri: { fsPath: "C:\\workspace\\src\\conflicted.txt" },
    });

    expect(ui.promptResolveChoice).toHaveBeenCalledWith("src/conflicted.txt");
    expect(operationClient.resolve).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      paths: ["src/conflicted.txt"],
      depth: "empty",
      choice: "working",
    });
    expect(refreshService.refreshTargets).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [{ path: "src/conflicted.txt", depth: "empty", reason: "operationResolve" }],
    });
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR resolved SVN conflict with Working copy: src/conflicted.txt",
    );
  });

  it("resolves multi-selected conflicted SCM resources with one selected strategy", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "resolve", path: "src/conflicted-a.txt", reason: "operationResolve" }),
    );
    operationClient.resolve
      .mockResolvedValueOnce(
        operationResponse({ kind: "resolve", path: "src/conflicted-a.txt", reason: "operationResolve" }),
      )
      .mockResolvedValueOnce(
        operationResponse({ kind: "resolve", path: "src/conflicted-b.txt", reason: "operationResolve" }),
      );
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        resources: [
          scmConflictedProjectedResource({ path: "src/conflicted-a.txt" }),
          {
            ...scmConflictedProjectedResource({ path: "src/conflicted-b.txt", changelist: "review" }),
            contextValue: "subversionr.conflicted.changelisted",
          },
        ],
      }),
    });
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"], resolveChoice: "mineFull" });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
      sourceControlProjection,
    });

    await controller.resolveResource([
      {
        contextValue: "subversionr.conflicted",
        resourceUri: { fsPath: "C:\\workspace\\src\\conflicted-a.txt" },
      },
      {
        contextValue: "subversionr.conflicted.changelisted",
        resourceUri: { fsPath: "C:\\workspace\\src\\conflicted-b.txt" },
      },
    ]);

    expect(ui.promptResolveChoice).toHaveBeenCalledWith("2 SVN conflicts");
    expect(operationClient.resolve).toHaveBeenNthCalledWith(1, {
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      paths: ["src/conflicted-a.txt"],
      depth: "empty",
      choice: "mineFull",
    });
    expect(operationClient.resolve).toHaveBeenNthCalledWith(2, {
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      paths: ["src/conflicted-b.txt"],
      depth: "empty",
      choice: "mineFull",
    });
    expect(refreshService.refreshTargets).toHaveBeenNthCalledWith(1, {
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [{ path: "src/conflicted-a.txt", depth: "empty", reason: "operationResolve" }],
    });
    expect(refreshService.refreshTargets).toHaveBeenNthCalledWith(2, {
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [{ path: "src/conflicted-b.txt", depth: "empty", reason: "operationResolve" }],
    });
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR resolved 2 SVN conflicts with Mine full: src/conflicted-a.txt, src/conflicted-b.txt",
    );
  });

  it("resolves all conflicted SCM resources with one selected strategy", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "resolve", path: "src/conflicted-a.txt", reason: "operationResolve" }),
    );
    operationClient.resolve
      .mockResolvedValueOnce(
        operationResponse({ kind: "resolve", path: "src/conflicted-a.txt", reason: "operationResolve" }),
      )
      .mockResolvedValueOnce(
        operationResponse({ kind: "resolve", path: "src/conflicted-b.txt", reason: "operationResolve" }),
      );
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({
        resources: [
          scmConflictedProjectedResource({ path: "src/conflicted-a.txt" }),
          {
            ...scmConflictedProjectedResource({ path: "src/conflicted-b.txt", changelist: "review" }),
            contextValue: "subversionr.conflicted.changelisted",
          },
          scmProjectedResource({ path: "src/changed.c" }),
        ],
      }),
    });
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"], resolveChoice: "mineFull" });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
      sourceControlProjection,
    });

    await controller.resolveAll("repo-uuid:C:/workspace");

    expect(sourceControlProjection.getProjection).toHaveBeenCalledWith("repo-uuid:C:/workspace");
    expect(ui.promptResolveChoice).toHaveBeenCalledWith("2 SVN conflicts");
    expect(operationClient.resolve).toHaveBeenNthCalledWith(1, {
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      paths: ["src/conflicted-a.txt"],
      depth: "empty",
      choice: "mineFull",
    });
    expect(operationClient.resolve).toHaveBeenNthCalledWith(2, {
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      paths: ["src/conflicted-b.txt"],
      depth: "empty",
      choice: "mineFull",
    });
    expect(refreshService.refreshTargets).toHaveBeenNthCalledWith(1, {
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [{ path: "src/conflicted-a.txt", depth: "empty", reason: "operationResolve" }],
    });
    expect(refreshService.refreshTargets).toHaveBeenNthCalledWith(2, {
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [{ path: "src/conflicted-b.txt", depth: "empty", reason: "operationResolve" }],
    });
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR resolved 2 SVN conflicts with Mine full: src/conflicted-a.txt, src/conflicted-b.txt",
    );
  });

  it("commits a selected changed SCM resource with the repository input message", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "commit", path: "src/main.c", reason: "operationCommit", revision: 8 }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"], commitMessage: "commit tracked file" });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
    });

    await controller.commitResource({
      contextValue: "subversionr.changedFile",
      subversionrResourceKind: "file",
      resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
    });

    expect(ui.workspaceTrusted).toHaveBeenCalledTimes(1);
    expect(ui.commitMessage).toHaveBeenCalledWith("repo-uuid:C:/workspace");
    expect(operationClient.commit).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      paths: ["src/main.c"],
      message: "commit tracked file",
      depth: "empty",
      changelists: [],
      keepLocks: false,
      keepChangelists: false,
      commitAsOperations: false,
      includeFileExternals: false,
      includeDirExternals: false,
    });
    expect(refreshService.refreshTargets).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [{ path: "src/main.c", depth: "empty", reason: "operationCommit" }],
    });
    expect(ui.clearCommitMessage).toHaveBeenCalledWith("repo-uuid:C:/workspace");
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR committed SVN resource at revision 8: src/main.c",
    );
  });

  it.each([
    "subversionr.changedFile.changelisted",
    "subversionr.changedFile.baseDiffable.changelisted",
  ])("commits a selected %s SCM resource with the repository input message", async (contextValue) => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "commit", path: "src/main.c", reason: "operationCommit", revision: 8 }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"], commitMessage: "commit tracked file" });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
    });

    await controller.commitResource({
      contextValue,
      subversionrResourceKind: "file",
      resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
    });

    expect(ui.commitMessage).toHaveBeenCalledWith("repo-uuid:C:/workspace");
    expect(operationClient.commit).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      paths: ["src/main.c"],
      message: "commit tracked file",
      depth: "empty",
      changelists: [],
      keepLocks: false,
      keepChangelists: false,
      commitAsOperations: false,
      includeFileExternals: false,
      includeDirExternals: false,
    });
    expect(refreshService.refreshTargets).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [{ path: "src/main.c", depth: "empty", reason: "operationCommit" }],
    });
    expect(ui.clearCommitMessage).toHaveBeenCalledWith("repo-uuid:C:/workspace");
  });

  it.each([
    "subversionr.changedDirectory",
    "subversionr.changedDirectory.changelisted",
  ])("commits a selected %s SCM resource with the repository input message", async (contextValue) => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "commit", path: "src", reason: "operationCommit", revision: 8 }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"], commitMessage: "commit directory props" });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
    });

    await controller.commitResource({
      contextValue,
      subversionrResourceKind: "dir",
      resourceUri: { fsPath: "C:\\workspace\\src" },
    });

    expect(ui.commitMessage).toHaveBeenCalledWith("repo-uuid:C:/workspace");
    expect(operationClient.commit).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      paths: ["src"],
      message: "commit directory props",
      depth: "empty",
      changelists: [],
      keepLocks: false,
      keepChangelists: false,
      commitAsOperations: false,
      includeFileExternals: false,
      includeDirExternals: false,
    });
    expect(refreshService.refreshTargets).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [{ path: "src", depth: "empty", reason: "operationCommit" }],
    });
    expect(ui.clearCommitMessage).toHaveBeenCalledWith("repo-uuid:C:/workspace");
  });

  it("commits a selected working-copy root directory property resource with the repository input message", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "commit", path: ".", reason: "operationCommit", revision: 9 }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"], commitMessage: "commit root props" });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
    });

    await controller.commitResource({
      contextValue: "subversionr.changedDirectory",
      subversionrResourceKind: "dir",
      resourceUri: { fsPath: "C:\\workspace" },
    });

    expect(operationClient.commit).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      paths: ["."],
      message: "commit root props",
      depth: "empty",
      changelists: [],
      keepLocks: false,
      keepChangelists: false,
      commitAsOperations: false,
      includeFileExternals: false,
      includeDirExternals: false,
    });
    expect(refreshService.refreshTargets).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [{ path: ".", depth: "empty", reason: "operationCommit" }],
    });
    expect(ui.clearCommitMessage).toHaveBeenCalledWith("repo-uuid:C:/workspace");
  });

  it("commits multiple selected changed file resources from one repository with the repository input message", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const commitResponse: OperationRunResponse = {
      ...operationResponse({ kind: "commit", path: "src/main.c", reason: "operationCommit", revision: 8 }),
      touchedPaths: ["src/main.c", "src/other.c"],
      summary: { affectedPaths: 2, skippedPaths: 0 },
      reconcile: {
        targets: [
          { path: "src/main.c", depth: "empty", reason: "operationCommit" },
          { path: "src/other.c", depth: "empty", reason: "operationCommit" },
        ],
        requiresFullReconcile: false,
      },
    };
    const operationClient = fakeOperationClient(commitResponse);
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"], commitMessage: "commit selected files" });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
    });

    await controller.commitResource([
      {
        contextValue: "subversionr.changedFile",
        subversionrResourceKind: "file",
        resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
      },
      {
        contextValue: "subversionr.changedFile",
        subversionrResourceKind: "file",
        resourceUri: { fsPath: "C:\\workspace\\src\\other.c" },
      },
    ]);

    expect(ui.workspaceTrusted).toHaveBeenCalledTimes(1);
    expect(ui.commitMessage).toHaveBeenCalledWith("repo-uuid:C:/workspace");
    expect(operationClient.commit).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      paths: ["src/main.c", "src/other.c"],
      message: "commit selected files",
      depth: "empty",
      changelists: [],
      keepLocks: false,
      keepChangelists: false,
      commitAsOperations: false,
      includeFileExternals: false,
      includeDirExternals: false,
    });
    expect(refreshService.refreshTargets).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [
        { path: "src/main.c", depth: "empty", reason: "operationCommit" },
        { path: "src/other.c", depth: "empty", reason: "operationCommit" },
      ],
    });
    expect(ui.clearCommitMessage).toHaveBeenCalledWith("repo-uuid:C:/workspace");
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR committed SVN resources at revision 8: src/main.c, src/other.c",
    );
  });

  it("commits all eligible changed file resources for the repository input message", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const commitResponse: OperationRunResponse = {
      ...operationResponse({ kind: "commit", path: "src/main.c", reason: "operationCommit", revision: 8 }),
      touchedPaths: ["src/main.c", "src/other.c"],
      summary: { affectedPaths: 2, skippedPaths: 0 },
      reconcile: {
        targets: [
          { path: "src/main.c", depth: "empty", reason: "operationCommit" },
          { path: "src/other.c", depth: "empty", reason: "operationCommit" },
        ],
        requiresFullReconcile: false,
      },
    };
    const operationClient = fakeOperationClient(commitResponse);
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"], commitMessage: "commit all files" });
    const sourceControlProjection = fakeSourceControlProjection({
      targets: commitAllTargets({
        targets: [
          { path: "src/main.c", changelist: null },
          { path: "src/other.c", changelist: null },
        ],
      }),
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
      sourceControlProjection,
    });

    await controller.commitAll("repo-uuid:C:/workspace");

    expect(ui.workspaceTrusted).toHaveBeenCalledTimes(1);
    expect(ui.commitMessage).toHaveBeenCalledWith("repo-uuid:C:/workspace");
    expect(operationClient.commit).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      paths: ["src/main.c", "src/other.c"],
      message: "commit all files",
      depth: "empty",
      changelists: [],
      keepLocks: false,
      keepChangelists: false,
      commitAsOperations: false,
      includeFileExternals: false,
      includeDirExternals: false,
    });
    expect(refreshService.refreshTargets).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [
        { path: "src/main.c", depth: "empty", reason: "operationCommit" },
        { path: "src/other.c", depth: "empty", reason: "operationCommit" },
      ],
    });
    expect(ui.clearCommitMessage).toHaveBeenCalledWith("repo-uuid:C:/workspace");
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR committed SVN resources at revision 8: src/main.c, src/other.c",
    );
  });

  it("records successful commit messages in repository history", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const commitMessageHistory = fakeCommitMessageHistory();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "commit", path: "src/main.c", reason: "operationCommit", revision: 8 }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"], commitMessage: "commit all files" });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      commitMessageHistory,
      operationClient,
      sourceControlProjection: fakeSourceControlProjection({
        targets: commitAllTargets({ targets: [{ path: "src/main.c", changelist: null }] }),
      }),
    });

    await controller.commitAll("repo-uuid:C:/workspace");

    expect(commitMessageHistory.record).toHaveBeenCalledWith("repo-uuid:C:/workspace", "commit all files");
  });

  it("does not record a commit message when commit validation stops before operation/run", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const commitMessageHistory = fakeCommitMessageHistory();
    const operationClient = fakeOperationClient(operationResponse({ kind: "commit" }));
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"], commitMessage: "  " });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      commitMessageHistory,
      operationClient,
      sourceControlProjection: fakeSourceControlProjection({
        targets: commitAllTargets({ targets: [{ path: "src/main.c", changelist: null }] }),
      }),
    });

    await controller.commitAll("repo-uuid:C:/workspace");

    expect(operationClient.commit).not.toHaveBeenCalled();
    expect(commitMessageHistory.record).not.toHaveBeenCalled();
  });

  it("picks a recent commit message and restores it into the repository input box", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const commitMessageHistory = fakeCommitMessageHistory(["fix parser state", "update docs"]);
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace"],
      pickedCommitHistoryMessage: "fix parser state",
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      commitMessageHistory,
    });

    await controller.pickCommitMessageHistory("repo-uuid:C:/workspace");

    expect(ui.promptCommitMessageHistory).toHaveBeenCalledWith(["fix parser state", "update docs"]);
    expect(ui.setCommitMessage).toHaveBeenCalledWith("repo-uuid:C:/workspace", "fix parser state");
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR restored SVN commit message history for: C:\\workspace",
    );
  });

  it("warns when no commit message history is available for the selected repository", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      commitMessageHistory: fakeCommitMessageHistory([]),
    });

    await controller.pickCommitMessageHistory("repo-uuid:C:/workspace");

    expect(ui.promptCommitMessageHistory).not.toHaveBeenCalled();
    expect(ui.setCommitMessage).not.toHaveBeenCalled();
    expect(ui.showWarningMessage).toHaveBeenCalledWith(
      "No SVN commit message history for: C:\\workspace",
    );
  });

  it("selects an open repository when Commit All is invoked without an input-accept repository id", async () => {
    const first = repositorySession();
    const second = repositorySession({
      repositoryId: "repo-uuid:D:/other-wc",
      workingCopyRoot: "D:\\other-wc",
    });
    const sessionService = fakeSessionService({ sessions: [first, second] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "commit", path: "src/other.c", reason: "operationCommit", revision: 9 }),
    );
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace", "D:\\other-wc"],
      pickedSession: second,
      commitMessage: "commit selected repository",
    });
    const sourceControlProjection = fakeSourceControlProjection({
      targets: commitAllTargets({
        repositoryId: "repo-uuid:D:/other-wc",
        workingCopyRoot: "D:/other-wc",
        targets: [{ path: "src/other.c", changelist: null }],
      }),
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
      sourceControlProjection,
    });

    await controller.commitAll();

    expect(ui.pickOpenRepository).toHaveBeenCalledWith([first, second]);
    expect(operationClient.commit).toHaveBeenCalledWith(
      expect.objectContaining({
        repositoryId: "repo-uuid:D:/other-wc",
        paths: ["src/other.c"],
      }),
    );
  });

  it("reviews and commits the selected eligible SVN file changes", async () => {
    const session = repositorySession();
    const sessionService = fakeSessionService({ sessions: [session] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "commit", path: "src/other.c", reason: "operationCommit", revision: 8 }),
    );
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace"],
      commitMessage: "commit reviewed files",
      reviewCommitSelection: ["src/other.c"],
    });
    const sourceControlProjection = fakeSourceControlProjection({
      targets: commitAllTargets({
        targets: [
          { path: "src/main.c", changelist: null, status: "modified", directory: "src" },
          { path: "src/other.c", changelist: "review", status: "added", directory: "src" },
        ],
      }),
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
      sourceControlProjection,
    });

    await controller.reviewCommit("repo-uuid:C:/workspace");

    expect(ui.promptReviewCommitTargets).toHaveBeenCalledWith([
      { path: "src/main.c", changelist: null, status: "modified", directory: "src" },
      { path: "src/other.c", changelist: "review", status: "added", directory: "src" },
    ]);
    expect(ui.commitMessage).toHaveBeenCalledWith("repo-uuid:C:/workspace");
    expect(operationClient.commit).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      paths: ["src/other.c"],
      message: "commit reviewed files",
      depth: "empty",
      changelists: [],
      keepLocks: false,
      keepChangelists: false,
      commitAsOperations: false,
      includeFileExternals: false,
      includeDirExternals: false,
    });
    expect(refreshService.refreshTargets).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      targets: [{ path: "src/other.c", depth: "empty", reason: "operationCommit" }],
    });
    expect(ui.clearCommitMessage).toHaveBeenCalledWith("repo-uuid:C:/workspace");
  });

  it("does not read the commit message when Review and Commit is cancelled", async () => {
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "commit", path: "src/main.c", reason: "operationCommit", revision: 8 }),
    );
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace"],
      commitMessage: "commit reviewed files",
      reviewCommitCancelled: true,
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      operationClient,
      sourceControlProjection: fakeSourceControlProjection({
        targets: commitAllTargets({ targets: [{ path: "src/main.c", changelist: null }] }),
      }),
    });

    await controller.reviewCommit("repo-uuid:C:/workspace");

    expect(ui.promptReviewCommitTargets).toHaveBeenCalledWith([
      { path: "src/main.c", changelist: null, status: "modified", directory: "src" },
    ]);
    expect(ui.commitMessage).not.toHaveBeenCalled();
    expect(operationClient.commit).not.toHaveBeenCalled();
    expect(ui.clearCommitMessage).not.toHaveBeenCalled();
  });

  it("warns and preserves the message when Review and Commit selection is empty", async () => {
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "commit", path: "src/main.c", reason: "operationCommit", revision: 8 }),
    );
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace"],
      commitMessage: "commit reviewed files",
      reviewCommitSelection: [],
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      operationClient,
      sourceControlProjection: fakeSourceControlProjection({
        targets: commitAllTargets({ targets: [{ path: "src/main.c", changelist: null }] }),
      }),
    });

    await controller.reviewCommit("repo-uuid:C:/workspace");

    expect(ui.commitMessage).not.toHaveBeenCalled();
    expect(operationClient.commit).not.toHaveBeenCalled();
    expect(ui.clearCommitMessage).not.toHaveBeenCalled();
    expect(ui.showWarningMessage).toHaveBeenCalledWith("No SVN resources selected for commit.");
  });

  it("does not read the commit message when Commit All runs in an untrusted workspace", async () => {
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "commit", path: "src/main.c", reason: "operationCommit", revision: 8 }),
    );
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace"],
      commitMessage: "commit all files",
      workspaceTrusted: false,
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      operationClient,
      sourceControlProjection: fakeSourceControlProjection(),
    });

    await controller.commitAll("repo-uuid:C:/workspace");

    expect(ui.commitMessage).not.toHaveBeenCalled();
    expect(operationClient.commit).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_WORKSPACE_UNTRUSTED_OPERATION",
    );
  });

  it("warns and preserves the message when Commit All has no eligible changed file resources", async () => {
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "commit", path: "src/main.c", reason: "operationCommit", revision: 8 }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"], commitMessage: "commit all files" });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      operationClient,
      sourceControlProjection: fakeSourceControlProjection({
        targets: commitAllTargets({ targets: [] }),
      }),
    });

    await controller.commitAll("repo-uuid:C:/workspace");

    expect(ui.commitMessage).not.toHaveBeenCalled();
    expect(operationClient.commit).not.toHaveBeenCalled();
    expect(ui.clearCommitMessage).not.toHaveBeenCalled();
    expect(ui.showWarningMessage).toHaveBeenCalledWith("No eligible SVN file changes to commit.");
  });

  it("warns and preserves the message when Commit All includes an unsaved changed file", async () => {
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "commit", path: "src/main.c", reason: "operationCommit", revision: 8 }),
    );
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace"],
      dirtyTextDocumentFsPaths: ["C:/workspace/src/main.c"],
      commitMessage: "commit all files",
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      operationClient,
      sourceControlProjection: fakeSourceControlProjection({
        targets: commitAllTargets({ targets: [{ path: "src/main.c", changelist: null }] }),
      }),
    });

    await controller.commitAll("repo-uuid:C:/workspace");

    expect(ui.commitMessage).not.toHaveBeenCalled();
    expect(operationClient.commit).not.toHaveBeenCalled();
    expect(ui.clearCommitMessage).not.toHaveBeenCalled();
    expect(ui.showWarningMessage).toHaveBeenCalledWith("Save SVN resource before committing: src/main.c");
  });

  it("blocks Commit All when the current projection contains unresolved conflicts", async () => {
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "commit", path: "src/main.c", reason: "operationCommit", revision: 8 }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"], commitMessage: "commit all files" });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      operationClient,
      sourceControlProjection: fakeSourceControlProjection({
        targets: commitAllTargets({ hasConflicts: true }),
      }),
    });

    await controller.commitAll("repo-uuid:C:/workspace");

    expect(ui.commitMessage).not.toHaveBeenCalled();
    expect(operationClient.commit).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_COMMIT_ALL_CONFLICTS_PRESENT",
    );
  });

  it("keeps the repository input message when commit fails", async () => {
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "commit", path: "src/main.c", reason: "operationCommit", revision: 8 }),
    );
    operationClient.commit.mockRejectedValue(new CodedError("SUBVERSIONR_COMMIT_FAILED"));
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"], commitMessage: "commit tracked file" });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      refreshService,
      operationClient,
    });

    await controller.commitResource({
      contextValue: "subversionr.changedFile",
      subversionrResourceKind: "file",
      resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
    });

    expect(refreshService.refreshTargets).not.toHaveBeenCalled();
    expect(ui.clearCommitMessage).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_COMMIT_FAILED",
    );
  });

  it("does not commit when the repository input message is empty", async () => {
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "commit", path: "src/main.c", reason: "operationCommit", revision: 8 }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"], commitMessage: "   " });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      refreshService,
      operationClient,
    });

    await controller.commitResource({
      contextValue: "subversionr.changedFile",
      subversionrResourceKind: "file",
      resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
    });

    expect(operationClient.commit).not.toHaveBeenCalled();
    expect(refreshService.refreshTargets).not.toHaveBeenCalled();
    expect(ui.clearCommitMessage).not.toHaveBeenCalled();
    expect(ui.showWarningMessage).toHaveBeenCalledWith(
      "Enter an SVN commit message before committing src/main.c.",
    );
  });

  it("fails fast before commit when the input message contains unsupported characters", async () => {
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "commit", path: "src/main.c", reason: "operationCommit", revision: 8 }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"], commitMessage: "line one\r\nline two" });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      refreshService,
      operationClient,
    });

    await controller.commitResource({
      contextValue: "subversionr.changedFile",
      subversionrResourceKind: "file",
      resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
    });

    expect(operationClient.commit).not.toHaveBeenCalled();
    expect(refreshService.refreshTargets).not.toHaveBeenCalled();
    expect(ui.clearCommitMessage).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_RESOURCE_COMMIT_MESSAGE_INVALID",
    );
  });

  it("blocks commit in untrusted workspaces before reading the message", async () => {
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "commit", path: "src/main.c", reason: "operationCommit", revision: 8 }),
    );
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace"],
      commitMessage: "commit tracked file",
      workspaceTrusted: false,
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      refreshService,
      operationClient,
    });

    await controller.commitResource({
      contextValue: "subversionr.changedFile",
      subversionrResourceKind: "file",
      resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
    });

    expect(ui.commitMessage).not.toHaveBeenCalled();
    expect(operationClient.commit).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_WORKSPACE_UNTRUSTED_OPERATION",
    );
  });

  it("warns and preserves the message when the selected resource has unsaved editor contents", async () => {
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "commit", path: "src/main.c", reason: "operationCommit", revision: 8 }),
    );
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace"],
      commitMessage: "commit tracked file",
      dirtyTextDocumentFsPaths: ["C:/workspace/src/main.c"],
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      refreshService,
      operationClient,
    });

    await controller.commitResource({
      contextValue: "subversionr.changedFile",
      subversionrResourceKind: "file",
      resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
    });

    expect(ui.hasUnsavedTextDocument).toHaveBeenCalledWith("C:/workspace/src/main.c");
    expect(operationClient.commit).not.toHaveBeenCalled();
    expect(ui.clearCommitMessage).not.toHaveBeenCalled();
    expect(ui.showWarningMessage).toHaveBeenCalledWith(
      "Save SVN resource before committing: src/main.c",
    );
  });

  it("warns and preserves the message when any selected commit resource has unsaved editor contents", async () => {
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "commit", path: "src/main.c", reason: "operationCommit", revision: 8 }),
    );
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace"],
      commitMessage: "commit selected files",
      dirtyTextDocumentFsPaths: ["C:/workspace/src/other.c"],
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      refreshService,
      operationClient,
    });

    await controller.commitResource([
      {
        contextValue: "subversionr.changedFile",
        subversionrResourceKind: "file",
        resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
      },
      {
        contextValue: "subversionr.changedFile",
        subversionrResourceKind: "file",
        resourceUri: { fsPath: "C:\\workspace\\src\\other.c" },
      },
    ]);

    expect(ui.hasUnsavedTextDocument).toHaveBeenCalledWith("C:/workspace/src/main.c");
    expect(ui.hasUnsavedTextDocument).toHaveBeenCalledWith("C:/workspace/src/other.c");
    expect(operationClient.commit).not.toHaveBeenCalled();
    expect(ui.clearCommitMessage).not.toHaveBeenCalled();
    expect(ui.showWarningMessage).toHaveBeenCalledWith(
      "Save SVN resource before committing: src/other.c",
    );
  });

  it("runs a full reconcile when the commit operation result requires it", async () => {
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({
        kind: "commit",
        path: "src/main.c",
        revision: 8,
        reconcile: {
          targets: [],
          requiresFullReconcile: true,
        },
      }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"], commitMessage: "commit tracked file" });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      refreshService,
      operationClient,
    });

    await controller.commitResource({
      contextValue: "subversionr.changedFile",
      subversionrResourceKind: "file",
      resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
    });

    expect(refreshService.fullReconcileRepository).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
    });
    expect(refreshService.refreshTargets).not.toHaveBeenCalled();
    expect(ui.clearCommitMessage).toHaveBeenCalledWith("repo-uuid:C:/workspace");
  });

  it("rejects repository root resources for commit because the first commit slice is single-file only", async () => {
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "commit", path: "src/main.c", reason: "operationCommit", revision: 8 }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"], commitMessage: "commit tracked file" });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      refreshService,
      operationClient,
    });

    await controller.commitResource({
      contextValue: "subversionr.changedFile",
      subversionrResourceKind: "file",
      resourceUri: { fsPath: "C:\\workspace" },
    });

    expect(operationClient.commit).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_RESOURCE_COMMIT_TARGET_INVALID",
    );
  });

  it("does not report commit failure when post-commit targeted reconcile fails", async () => {
    const refreshService = fakeRefreshService();
    refreshService.refreshTargets.mockRejectedValue(new CodedError("SUBVERSIONR_POST_COMMIT_RECONCILE_FAILED"));
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "commit", path: "src/main.c", reason: "operationCommit", revision: 8 }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"], commitMessage: "commit tracked file" });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      refreshService,
      operationClient,
    });

    await controller.commitResource({
      contextValue: "subversionr.changedFile",
      subversionrResourceKind: "file",
      resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
    });

    expect(operationClient.commit).toHaveBeenCalledTimes(1);
    expect(ui.clearCommitMessage).toHaveBeenCalledWith("repo-uuid:C:/workspace");
    expect(ui.showInformationMessage).toHaveBeenCalledWith(
      "SubversionR committed SVN resource at revision 8: src/main.c",
    );
    expect(ui.showWarningMessage).toHaveBeenCalledWith(
      "SubversionR post-commit reconcile failed after revision 8: SUBVERSIONR_POST_COMMIT_RECONCILE_FAILED",
    );
    expect(ui.showErrorMessage).not.toHaveBeenCalled();
  });

  it("rejects changed directory resources for commit even if the menu context is forged", async () => {
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "commit", path: "src", reason: "operationCommit", revision: 8 }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"], commitMessage: "commit tracked file" });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      refreshService,
      operationClient,
    });

    await controller.commitResource({
      contextValue: "subversionr.changedFile",
      subversionrResourceKind: "dir",
      resourceUri: { fsPath: "C:\\workspace\\src" },
    });

    expect(operationClient.commit).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_RESOURCE_COMMIT_TARGET_INVALID",
    );
  });

  it("rejects duplicate selected resources for commit", async () => {
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "commit", path: "src/main.c", reason: "operationCommit", revision: 8 }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"], commitMessage: "commit selected files" });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      refreshService,
      operationClient,
    });

    await controller.commitResource([
      {
        contextValue: "subversionr.changedFile",
        subversionrResourceKind: "file",
        resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
      },
      {
        contextValue: "subversionr.changedFile",
        subversionrResourceKind: "file",
        resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
      },
    ]);

    expect(operationClient.commit).not.toHaveBeenCalled();
    expect(refreshService.refreshTargets).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_RESOURCE_COMMIT_TARGET_INVALID",
    );
  });

  it("rejects duplicate selected commit resources using the repository path case policy", async () => {
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "commit", path: "src/main.c", reason: "operationCommit", revision: 8 }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"], commitMessage: "commit selected files" });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      refreshService,
      operationClient,
    });

    await controller.commitResource([
      {
        contextValue: "subversionr.changedFile",
        subversionrResourceKind: "file",
        resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
      },
      {
        contextValue: "subversionr.changedFile",
        subversionrResourceKind: "file",
        resourceUri: { fsPath: "C:\\workspace\\SRC\\MAIN.C" },
      },
    ]);

    expect(operationClient.commit).not.toHaveBeenCalled();
    expect(refreshService.refreshTargets).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_RESOURCE_COMMIT_TARGET_INVALID",
    );
  });

  it("rejects selected commit resources that span open repositories", async () => {
    const first = repositorySession();
    const second = repositorySession({
      repositoryId: "repo-uuid:D:/other-wc",
      workingCopyRoot: "D:\\other-wc",
    });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "commit", path: "src/main.c", reason: "operationCommit", revision: 8 }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace", "D:\\other-wc"], commitMessage: "commit selected files" });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [first, second] }), ui, {
      refreshService,
      operationClient,
    });

    await controller.commitResource([
      {
        contextValue: "subversionr.changedFile",
        subversionrResourceKind: "file",
        resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
      },
      {
        contextValue: "subversionr.changedFile",
        subversionrResourceKind: "file",
        resourceUri: { fsPath: "D:\\other-wc\\src\\other.c" },
      },
    ]);

    expect(operationClient.commit).not.toHaveBeenCalled();
    expect(refreshService.refreshTargets).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_RESOURCE_COMMIT_TARGET_INVALID",
    );
  });

  it("allows conflicted SCM resources to be reverted", async () => {
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(operationResponse());
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      refreshService,
      operationClient,
    });

    await controller.revertResource({
      contextValue: "subversionr.conflicted",
      resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
    });

    expect(operationClient.revert).toHaveBeenCalledTimes(1);
    expect(refreshService.refreshTargets).toHaveBeenCalledTimes(1);
  });

  it("does not run revert when the irreversible operation confirmation is cancelled", async () => {
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(operationResponse());
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"], revertConfirmed: false });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      refreshService,
      operationClient,
    });

    await controller.revertResource({
      contextValue: "subversionr.changedFile",
      resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
    });

    expect(operationClient.revert).not.toHaveBeenCalled();
    expect(refreshService.refreshTargets).not.toHaveBeenCalled();
    expect(ui.showInformationMessage).not.toHaveBeenCalled();
  });

  it("does not run remove when the irreversible operation confirmation is cancelled", async () => {
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(operationResponse({ kind: "remove", reason: "operationRemove" }));
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"], removeConfirmed: false });
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({ resources: [scmProjectedResource({ path: "src/old.c" })] }),
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      refreshService,
      operationClient,
      sourceControlProjection,
    });

    await controller.removeResource({
      contextValue: "subversionr.changedFile",
      resourceUri: { fsPath: "C:\\workspace\\src\\old.c" },
    });

    expect(ui.confirmRemoveResource).toHaveBeenCalledWith("src/old.c");
    expect(operationClient.remove).not.toHaveBeenCalled();
    expect(refreshService.refreshTargets).not.toHaveBeenCalled();
    expect(ui.showInformationMessage).not.toHaveBeenCalled();
  });

  it("does not run keep-local remove when the explicit confirmation is cancelled", async () => {
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(operationResponse({ kind: "remove", reason: "operationRemove" }));
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"], removeKeepLocalConfirmed: false });
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({ resources: [scmProjectedResource({ path: "src/old.c" })] }),
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      refreshService,
      operationClient,
      sourceControlProjection,
    });

    await controller.removeResourceKeepLocal({
      contextValue: "subversionr.changedFile",
      resourceUri: { fsPath: "C:\\workspace\\src\\old.c" },
    });

    expect(ui.confirmRemoveResourceKeepLocal).toHaveBeenCalledWith("src/old.c");
    expect(operationClient.remove).not.toHaveBeenCalled();
    expect(refreshService.refreshTargets).not.toHaveBeenCalled();
    expect(ui.showInformationMessage).not.toHaveBeenCalled();
  });

  it("does not run resolve when explicit conflict resolution choice is cancelled", async () => {
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "resolve", path: "src/conflicted.txt", reason: "operationResolve" }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"], resolveChoice: undefined });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      refreshService,
      operationClient,
    });

    await controller.resolveResource({
      contextValue: "subversionr.conflicted",
      resourceUri: { fsPath: "C:\\workspace\\src\\conflicted.txt" },
    });

    expect(operationClient.resolve).not.toHaveBeenCalled();
    expect(refreshService.refreshTargets).not.toHaveBeenCalled();
    expect(ui.showInformationMessage).not.toHaveBeenCalled();
  });

  it.each([
    "subversionr.changedUnknown",
    "subversionr.unversioned",
    "subversionr.external",
    "subversionr.ignored",
    "subversionr.incoming",
  ])("rejects %s SCM resources for revert", async (contextValue) => {
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(operationResponse());
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      refreshService,
      operationClient,
    });

    await controller.revertResource({
      contextValue,
      resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
    });

    expect(operationClient.revert).not.toHaveBeenCalled();
    expect(refreshService.refreshTargets).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_RESOURCE_REVERT_TARGET_INVALID",
    );
  });

  it("fails fast when a selected SCM resource for revert is outside every open repository", async () => {
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(operationResponse());
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      refreshService,
      operationClient,
    });

    await controller.revertResource({
      contextValue: "subversionr.changedFile",
      resourceUri: { fsPath: "D:\\outside\\src\\main.c" },
    });

    expect(operationClient.revert).not.toHaveBeenCalled();
    expect(refreshService.refreshTargets).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_RESOURCE_REVERT_TARGET_OUTSIDE_REPOSITORY",
    );
  });

  it("runs a full reconcile when the revert operation result requires it", async () => {
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({
        reconcile: {
          targets: [],
          requiresFullReconcile: true,
        },
      }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({ resources: [scmProjectedResource({ path: "src/main.c" })] }),
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      refreshService,
      operationClient,
      sourceControlProjection,
    });

    await controller.revertResource({
      contextValue: "subversionr.changedFile",
      resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
    });

    expect(refreshService.fullReconcileRepository).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
    });
    expect(refreshService.refreshTargets).not.toHaveBeenCalled();
  });

  it("runs a full reconcile when the add operation result requires it", async () => {
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({
        kind: "add",
        path: "scratch.txt",
        reason: "operationAdd",
        reconcile: {
          targets: [],
          requiresFullReconcile: true,
        },
      }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({ resources: [scmUnversionedProjectedResource({ path: "scratch.txt" })] }),
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      refreshService,
      operationClient,
      sourceControlProjection,
    });

    await controller.addResource({
      contextValue: "subversionr.unversioned",
      resourceUri: { fsPath: "C:\\workspace\\scratch.txt" },
    });

    expect(refreshService.fullReconcileRepository).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
    });
    expect(refreshService.refreshTargets).not.toHaveBeenCalled();
  });

  it("runs a full reconcile when the remove operation result requires it", async () => {
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({
        kind: "remove",
        path: "src/old.c",
        reason: "operationRemove",
        reconcile: {
          targets: [],
          requiresFullReconcile: true,
        },
      }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const sourceControlProjection = fakeSourceControlProjection({
      projection: scmProjection({ resources: [scmProjectedResource({ path: "src/old.c" })] }),
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      refreshService,
      operationClient,
      sourceControlProjection,
    });

    await controller.removeResource({
      contextValue: "subversionr.changedFile",
      resourceUri: { fsPath: "C:\\workspace\\src\\old.c" },
    });

    expect(refreshService.fullReconcileRepository).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
    });
    expect(refreshService.refreshTargets).not.toHaveBeenCalled();
  });

  it("runs a full reconcile when the resolve operation result requires it", async () => {
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({
        kind: "resolve",
        path: "src/conflicted.txt",
        reason: "operationResolve",
        reconcile: {
          targets: [],
          requiresFullReconcile: true,
        },
      }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      refreshService,
      operationClient,
    });

    await controller.resolveResource({
      contextValue: "subversionr.conflicted",
      resourceUri: { fsPath: "C:\\workspace\\src\\conflicted.txt" },
    });

    expect(refreshService.fullReconcileRepository).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
    });
    expect(refreshService.refreshTargets).not.toHaveBeenCalled();
  });

  it.each([
    "subversionr.changed",
    "subversionr.changedUnknown",
    "subversionr.conflicted",
    "subversionr.external",
    "subversionr.ignored",
    "subversionr.incoming",
  ])("rejects %s SCM resources for add", async (contextValue) => {
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(operationResponse({ kind: "add", reason: "operationAdd" }));
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      refreshService,
      operationClient,
    });

    await controller.addResource({
      contextValue,
      resourceUri: { fsPath: "C:\\workspace\\scratch.txt" },
    });

    expect(operationClient.add).not.toHaveBeenCalled();
    expect(refreshService.refreshTargets).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_RESOURCE_ADD_TARGET_INVALID",
    );
  });

  it.each([
    "subversionr.changedUnknown",
    "subversionr.unversioned",
    "subversionr.external",
    "subversionr.ignored",
    "subversionr.incoming",
  ])("rejects %s SCM resources for remove", async (contextValue) => {
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(operationResponse({ kind: "remove", reason: "operationRemove" }));
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      refreshService,
      operationClient,
    });

    await controller.removeResource({
      contextValue,
      resourceUri: { fsPath: "C:\\workspace\\src\\old.c" },
    });

    expect(operationClient.remove).not.toHaveBeenCalled();
    expect(refreshService.refreshTargets).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_RESOURCE_REMOVE_TARGET_INVALID",
    );
  });

  it.each([
    "subversionr.changed",
    "subversionr.changedUnknown",
    "subversionr.unversioned",
    "subversionr.external",
    "subversionr.ignored",
    "subversionr.incoming",
  ])("rejects %s SCM resources for resolve", async (contextValue) => {
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "resolve", path: "src/conflicted.txt", reason: "operationResolve" }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      refreshService,
      operationClient,
    });

    await controller.resolveResource({
      contextValue,
      resourceUri: { fsPath: "C:\\workspace\\src\\conflicted.txt" },
    });

    expect(operationClient.resolve).not.toHaveBeenCalled();
    expect(refreshService.refreshTargets).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_RESOURCE_RESOLVE_TARGET_INVALID",
    );
  });

  it.each([
    "subversionr.changed",
    "subversionr.changedUnknown",
    "subversionr.conflicted",
    "subversionr.unversioned",
    "subversionr.external",
    "subversionr.ignored",
    "subversionr.incoming",
  ])("rejects %s SCM resources for commit", async (contextValue) => {
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({ kind: "commit", path: "src/main.c", reason: "operationCommit", revision: 8 }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"], commitMessage: "commit tracked file" });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), fakeSessionService({ sessions: [repositorySession()] }), ui, {
      refreshService,
      operationClient,
    });

    await controller.commitResource({
      contextValue,
      subversionrResourceKind: "file",
      resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
    });

    expect(operationClient.commit).not.toHaveBeenCalled();
    expect(refreshService.refreshTargets).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_RESOURCE_COMMIT_TARGET_INVALID",
    );
  });

  it("requires an explicit repository choice before refreshing multiple open sessions", async () => {
    const first = repositorySession();
    const second = repositorySession({
      repositoryId: "repo-uuid:D:/other-wc",
      workingCopyRoot: "D:\\other-wc",
    });
    const sessionService = fakeSessionService({ sessions: [first, second] });
    const refreshService = fakeRefreshService();
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace"],
      pickedSession: second,
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
    });

    await controller.refreshRepository();

    expect(ui.pickOpenRepository).toHaveBeenCalledWith([first, second]);
    expect(refreshService.refreshRepository).toHaveBeenCalledWith("repo-uuid:D:/other-wc");
  });

  it("requires an explicit repository choice before full reconcile with multiple open sessions", async () => {
    const first = repositorySession();
    const second = repositorySession({
      repositoryId: "repo-uuid:D:/other-wc",
      workingCopyRoot: "D:\\other-wc",
    });
    const sessionService = fakeSessionService({ sessions: [first, second] });
    const refreshService = fakeRefreshService();
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace"],
      pickedSession: second,
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
    });

    await controller.fullReconcileRepository();

    expect(ui.pickOpenRepository).toHaveBeenCalledWith([first, second]);
    expect(refreshService.fullReconcileRepository).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:D:/other-wc",
      epoch: 7,
    });
  });

  it("requires an explicit repository choice before update with multiple open sessions", async () => {
    const first = repositorySession();
    const second = repositorySession({
      repositoryId: "repo-uuid:D:/other-wc",
      workingCopyRoot: "D:\\other-wc",
    });
    const sessionService = fakeSessionService({ sessions: [first, second] });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(operationResponse({ kind: "update", path: ".", revision: 8 }));
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace"],
      pickedSession: second,
    });
    const controller = commandController(fakeDiscoveryService({ candidates: [discoveryCandidate()] }), sessionService, ui, {
      refreshService,
      operationClient,
    });

    await controller.updateRepository();

    expect(ui.pickOpenRepository).toHaveBeenCalledWith([first, second]);
    expect(operationClient.update).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:D:/other-wc",
      epoch: 7,
      path: ".",
      revision: "head",
      depth: "workingCopy",
      depthIsSticky: false,
      ignoreExternals: true,
    });
    expect(refreshService.fullReconcileRepository).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:D:/other-wc",
      epoch: 7,
    });
  });

  it("routes repository command errors through localized safe codes", async () => {
    const discoveryService = fakeDiscoveryService(new CodedError("SUBVERSIONR_REPOSITORY_DISCOVERY_FAILED"));
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(discoveryService, fakeSessionService(), ui);

    await controller.openRepository();

    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_REPOSITORY_DISCOVERY_FAILED",
    );
  });

  it("records a successful repository update in the sanitized operation journal", async () => {
    const operationJournal = new RepositoryOperationJournal({ maxEntries: 10 });
    const operationClient = fakeOperationClient(
      operationResponse({
        kind: "update",
        path: ".",
        revision: 8,
        reconcile: {
          targets: [],
          requiresFullReconcile: true,
        },
      }),
    );
    const controller = commandController(
      fakeDiscoveryService({ candidates: [] }),
      fakeSessionService({ sessions: [repositorySession()] }),
      fakeCommandUi({ workspaceRoots: ["C:\\workspace"] }),
      {
        operationClient,
        operationJournal,
        now: sequenceNow([
          "2026-06-25T00:00:00.000Z",
          "2026-06-25T00:00:02.500Z",
        ]),
        monotonicNowMs: sequenceNumber([100, 2600]),
      },
    );

    await controller.updateRepository();

    const entries = operationJournal.snapshot();
    expect(entries).toHaveLength(1);
    expect(entries[0]).toMatchObject({
      kind: "update",
      startedAt: "2026-06-25T00:00:00.000Z",
      endedAt: "2026-06-25T00:00:02.500Z",
      durationMs: 2500,
      resultCategory: "succeeded",
      scanPlan: "full",
      touchedCount: 1,
      retryCount: 0,
      cancelled: false,
    });
    expect(entries[0]?.repositoryHash).toMatch(/^[0-9a-f]{16}$/u);
    const json = JSON.stringify(entries);
    expect(json).not.toContain("repo-uuid:C:/workspace");
    expect(json).not.toContain("C:\\workspace");
  });

  it("does not let wall-clock rollback block reconcile after a successful update", async () => {
    const operationJournal = new RepositoryOperationJournal({ maxEntries: 10 });
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({
        kind: "update",
        path: ".",
        revision: 8,
        reconcile: {
          targets: [],
          requiresFullReconcile: true,
        },
      }),
    );
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(
      fakeDiscoveryService({ candidates: [] }),
      fakeSessionService({ sessions: [repositorySession()] }),
      ui,
      {
        refreshService,
        operationClient,
        operationJournal,
        now: sequenceNow([
          "2026-06-25T00:00:02.000Z",
          "2026-06-25T00:00:01.000Z",
        ]),
        monotonicNowMs: sequenceNumber([500, 525]),
      },
    );

    await controller.updateRepository();

    expect(refreshService.fullReconcileRepository).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
    });
    expect(ui.showErrorMessage).not.toHaveBeenCalled();
    expect(operationJournal.snapshot()).toEqual([
      expect.objectContaining({
        kind: "update",
        durationMs: 25,
        resultCategory: "succeeded",
      }),
    ]);
  });

  it("does not let operation journal write failures block reconcile after a successful update", async () => {
    const refreshService = fakeRefreshService();
    const operationClient = fakeOperationClient(
      operationResponse({
        kind: "update",
        path: ".",
        revision: 8,
        reconcile: {
          targets: [],
          requiresFullReconcile: true,
        },
      }),
    );
    const operationJournal = {
      tryRecord: vi.fn(() => {
        throw new CodedError("SUBVERSIONR_OPERATION_JOURNAL_TEST_FAILURE");
      }),
    };
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(
      fakeDiscoveryService({ candidates: [] }),
      fakeSessionService({ sessions: [repositorySession()] }),
      ui,
      {
        refreshService,
        operationClient,
        operationJournal,
        monotonicNowMs: sequenceNumber([500, 525]),
      },
    );

    await controller.updateRepository();

    expect(operationJournal.tryRecord).toHaveBeenCalledTimes(1);
    expect(refreshService.fullReconcileRepository).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
    });
    expect(ui.showErrorMessage).not.toHaveBeenCalled();
  });

  it("records a cancelled repository update in the sanitized operation journal", async () => {
    const operationJournal = new RepositoryOperationJournal({ maxEntries: 10 });
    const operationClient = fakeOperationClient(
      operationResponse({
        kind: "update",
        path: ".",
        revision: 8,
        reconcile: {
          targets: [],
          requiresFullReconcile: true,
        },
      }),
    );
    operationClient.update.mockRejectedValue(new CodedError("SUBVERSIONR_OPERATION_CANCELLED"));
    const ui = fakeCommandUi({ workspaceRoots: ["C:\\workspace"] });
    const controller = commandController(
      fakeDiscoveryService({ candidates: [] }),
      fakeSessionService({ sessions: [repositorySession()] }),
      ui,
      {
        operationClient,
        operationJournal,
        now: sequenceNow([
          "2026-06-25T00:00:00.000Z",
          "2026-06-25T00:00:01.000Z",
        ]),
        monotonicNowMs: sequenceNumber([100, 1100]),
      },
    );

    await controller.updateRepository();

    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR repository command failed: SUBVERSIONR_OPERATION_CANCELLED",
    );
    expect(operationJournal.snapshot()).toEqual([
      expect.objectContaining({
        kind: "update",
        durationMs: 1000,
        resultCategory: "cancelled",
        scanPlan: "unknown",
        touchedCount: 1,
        retryCount: 0,
        cancelled: true,
      }),
    ]);
  });

  it("records commit journal entries without storing commit messages or selected paths", async () => {
    const operationJournal = new RepositoryOperationJournal({ maxEntries: 10 });
    const operationClient = fakeOperationClient(
      operationResponse({
        kind: "commit",
        path: "src/private-feature.c",
        reason: "operationCommit",
        revision: 8,
      }),
    );
    const ui = fakeCommandUi({
      workspaceRoots: ["C:\\workspace"],
      commitMessage: "fix private customer token handling",
    });
    const controller = commandController(
      fakeDiscoveryService({ candidates: [] }),
      fakeSessionService({ sessions: [repositorySession()] }),
      ui,
      {
        operationClient,
        operationJournal,
        now: sequenceNow([
          "2026-06-25T00:00:00.000Z",
          "2026-06-25T00:00:00.250Z",
        ]),
        monotonicNowMs: sequenceNumber([10, 260]),
      },
    );

    await controller.commitResource({
      contextValue: "subversionr.changedFile",
      subversionrResourceKind: "file",
      resourceUri: { fsPath: "C:\\workspace\\src\\private-feature.c" },
    });

    const entries = operationJournal.snapshot();
    expect(entries).toEqual([
      expect.objectContaining({
        kind: "commit",
        durationMs: 250,
        resultCategory: "succeeded",
        scanPlan: "targeted",
        touchedCount: 1,
      }),
    ]);
    const json = JSON.stringify(entries);
    expect(json).not.toContain("fix private customer token handling");
    expect(json).not.toContain("src/private-feature.c");
    expect(json).not.toContain("private-feature");
    expect(json).not.toContain("C:\\workspace");
  });
});

function commandController(
  discoveryService: Pick<RepositoryDiscoveryService, "discoverRepositories" | "openDiscoveredRepository">,
  sessionService: Pick<
    RepositorySessionService,
    "closeRepository" | "listOpenSessions" | "openWorkingCopy" | "refreshSessionIdentityFromSnapshot"
  >,
  ui: FakeCommandUi,
  deps: {
    refreshService?: Pick<RepositoryRefreshService, "refreshRepository" | "fullReconcileRepository" | "refreshResource" | "refreshTargets">;
    operationClient?: Pick<
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
      | "relocate"
      | "remove"
      | "resolve"
      | "revert"
      | "switch"
      | "unlock"
      | "upgrade"
      | "update"
    >;
    checkoutClient?: Pick<RepositoryCheckoutClient, "checkout">;
    propertiesClient?: Pick<PropertiesClient, "listProperties">;
    operationJournal?: Pick<RepositoryOperationJournal, "tryRecord">;
    historyClient?: Pick<HistoryClient, "getLog">;
    operationScheduler?: Pick<RepositoryOperationScheduler, "run">;
    sourceControlProjection?: Pick<SourceControlProjectionService, "getCommitAllTargets" | "getProjection">;
    commitMessageHistory?: Pick<RepositoryCommitMessageHistory, "messages" | "record">;
    includeMergedRevisions?: () => boolean;
    createRequestId?: () => string;
    now?: () => string;
    monotonicNowMs?: () => number;
  } = {},
): RepositoryCommandController {
  return new RepositoryCommandController({
    discoveryService,
    sessionService,
    refreshService: deps.refreshService ?? fakeRefreshService(),
    operationClient: deps.operationClient ?? fakeOperationClient(operationResponse()),
    checkoutClient: deps.checkoutClient ?? fakeCheckoutClient(),
    propertiesClient: deps.propertiesClient ?? fakePropertiesClient(propertiesResponse()),
    operationJournal: deps.operationJournal ?? new RepositoryOperationJournal({ maxEntries: 10 }),
    historyClient: deps.historyClient ?? fakeHistoryClient(historyLog()),
    operationScheduler: deps.operationScheduler ?? fakeOperationScheduler(),
    sourceControlProjection: deps.sourceControlProjection ?? fakeSourceControlProjection(),
    commitMessageHistory: deps.commitMessageHistory ?? new RepositoryCommitMessageHistory(),
    includeMergedRevisions: deps.includeMergedRevisions ?? (() => false),
    createRequestId: deps.createRequestId ?? (() => "11111111-1111-4111-8111-111111111111"),
    now: deps.now ?? (() => "2026-06-25T00:00:00.000Z"),
    monotonicNowMs: deps.monotonicNowMs ?? (() => 0),
    ui,
    localize: (message: string, ...args: unknown[]): string =>
      args.reduce<string>((current, arg, index) => current.replace(`{${index}}`, String(arg)), message),
  });
}

function fakeSourceControlProjection(options: {
  targets?: ScmCommitAllTargets | undefined;
  projection?: ScmRepositoryProjection | undefined;
} = {}): Pick<
  SourceControlProjectionService,
  "getCommitAllTargets" | "getProjection"
> & {
  getCommitAllTargets: ReturnType<typeof vi.fn<(repositoryId: string) => ScmCommitAllTargets | undefined>>;
  getProjection: ReturnType<typeof vi.fn<(repositoryId: string) => ScmRepositoryProjection | undefined>>;
} {
  return {
    getCommitAllTargets: vi.fn(() => options.targets ?? commitAllTargets()),
    getProjection: vi.fn(() => ("projection" in options ? options.projection : scmProjection())),
  };
}

type FakeCommitAllTargetInput = Pick<ScmCommitAllTarget, "path" | "changelist"> & Partial<ScmCommitAllTarget>;

function commitAllTargets(
  overrides: Partial<Omit<ScmCommitAllTargets, "targets">> & { targets?: FakeCommitAllTargetInput[] } = {},
): ScmCommitAllTargets {
  return {
    repositoryId: overrides.repositoryId ?? "repo-uuid:C:/workspace",
    epoch: overrides.epoch ?? 7,
    workingCopyRoot: overrides.workingCopyRoot ?? "C:/workspace",
    generation: overrides.generation ?? 11,
    hasConflicts: overrides.hasConflicts ?? false,
    targets: (overrides.targets ?? [{ path: "src/main.c", changelist: null }]).map(fakeCommitAllTarget),
  };
}

function fakeCommitAllTarget(target: FakeCommitAllTargetInput): ScmCommitAllTarget {
  return {
    path: target.path,
    changelist: target.changelist,
    status: target.status ?? "modified",
    directory: target.directory ?? parentDirectory(target.path),
  };
}

function parentDirectory(path: string): string {
  const index = path.lastIndexOf("/");
  return index === -1 ? "." : path.slice(0, index);
}

function scmProjection(options: {
  resources?: ScmProjectedResource[];
  repositoryId?: string;
  epoch?: number;
  workingCopyRoot?: string;
  generation?: number;
} = {}): ScmRepositoryProjection {
  const resources = options.resources ?? [scmProjectedResource()];
  return {
    repositoryId: options.repositoryId ?? "repo-uuid:C:/workspace",
    epoch: options.epoch ?? 7,
    workingCopyRoot: options.workingCopyRoot ?? "C:/workspace",
    generation: options.generation ?? 11,
    count: resources.length,
    freshness: {
      repositoryCompleteness: "complete",
      lastRefreshCompleteness: "complete",
      lastRefreshKind: "snapshot",
    },
    groups: [
      { id: "conflicts", labelKey: "scm.group.conflicts", changelist: null, resources: resourcesForGroup(resources, "conflicts") },
      ...changelistGroups(resources),
      { id: "changes", labelKey: "scm.group.changes", changelist: null, resources: resourcesForGroup(resources, "changes") },
      { id: "unversioned", labelKey: "scm.group.unversioned", changelist: null, resources: resourcesForGroup(resources, "unversioned") },
      { id: "incoming", labelKey: "scm.group.incoming", changelist: null, resources: resourcesForGroup(resources, "incoming") },
      { id: "externals", labelKey: "scm.group.externals", changelist: null, resources: resourcesForGroup(resources, "externals") },
      { id: "ignored", labelKey: "scm.group.ignored", changelist: null, resources: resourcesForGroup(resources, "ignored") },
    ],
  };
}

function changelistGroups(resources: ScmProjectedResource[]): ScmRepositoryProjection["groups"] {
  const changelists = Array.from(
    new Set(
      resources
        .filter((resource) => resource.groupId.startsWith("changelist:"))
        .map((resource) => resource.entry.changelist)
        .filter((changelist): changelist is string => changelist !== null),
    ),
  ).sort((left, right) => left.localeCompare(right, "en-US"));
  return changelists.map((changelist) => ({
    id: `changelist:${encodeURIComponent(changelist)}`,
    labelKey: "scm.group.changelist",
    changelist,
    resources: resourcesForGroup(resources, `changelist:${encodeURIComponent(changelist)}`),
  }));
}

function resourcesForGroup(resources: ScmProjectedResource[], groupId: ScmProjectedResource["groupId"]): ScmProjectedResource[] {
  return resources.filter((resource) => resource.groupId === groupId);
}

function scmProjectedResource(overrides: Partial<StatusEntry> = {}): ScmProjectedResource {
  const entry = statusEntry(overrides);
  return {
    key: `local:${entry.path}`,
    repositoryId: "repo-uuid:C:/workspace",
    path: entry.path,
    source: "local",
    groupId: "changes",
    contextValue: entry.kind === "file" ? "subversionr.changedFile" : "subversionr.changedDirectory",
    tooltipKey: "scm.resource.changed",
    entry,
  };
}

function scmIncomingProjectedResource(overrides: Partial<StatusEntry> = {}): ScmProjectedResource {
  const entry = statusEntry({
    path: "src/incoming.c",
    localStatus: "normal",
    textStatus: "normal",
    remoteStatus: "modified",
    ...overrides,
  });
  return {
    key: `remote:${entry.path}`,
    repositoryId: "repo-uuid:C:/workspace",
    path: entry.path,
    source: "remote",
    groupId: "incoming",
    contextValue:
      entry.kind === "file"
        ? entry.lock?.isRemote
          ? "subversionr.incomingFile.locked"
          : "subversionr.incomingFile"
        : "subversionr.incoming",
    tooltipKey: "scm.resource.incoming",
    entry,
  };
}

function scmConflictedProjectedResource(overrides: Partial<StatusEntry> = {}): ScmProjectedResource {
  const entry = statusEntry({
    path: "src/conflicted.txt",
    localStatus: "conflicted",
    nodeStatus: "conflicted",
    textStatus: "conflicted",
    ...overrides,
  });
  return {
    key: `local:${entry.path}`,
    repositoryId: "repo-uuid:C:/workspace",
    path: entry.path,
    source: "local",
    groupId: "conflicts",
    contextValue: "subversionr.conflicted",
    tooltipKey: "scm.resource.conflicted",
    entry,
  };
}

function scmUnversionedProjectedResource(overrides: Partial<StatusEntry> = {}): ScmProjectedResource {
  const entry = statusEntry({
    path: "scratch.txt",
    nodeStatus: "normal",
    textStatus: "normal",
    propertyStatus: "normal",
    localStatus: "unversioned",
    ...overrides,
  });
  return {
    key: `local:${entry.path}`,
    repositoryId: "repo-uuid:C:/workspace",
    path: entry.path,
    source: "local",
    groupId: "unversioned",
    contextValue: "subversionr.unversioned",
    tooltipKey: "scm.resource.unversioned",
    entry,
  };
}

function scmIgnoredProjectedResource(overrides: Partial<StatusEntry> = {}): ScmProjectedResource {
  const entry = statusEntry({
    path: "ignored.txt",
    nodeStatus: "ignored",
    textStatus: "normal",
    propertyStatus: "normal",
    localStatus: "ignored",
    ...overrides,
  });
  return {
    key: `local:${entry.path}`,
    repositoryId: "repo-uuid:C:/workspace",
    path: entry.path,
    source: "local",
    groupId: "ignored",
    contextValue: "subversionr.ignored",
    tooltipKey: "scm.resource.ignored",
    entry,
  };
}

function scmWorkingCopyMetadataProjectedResource(overrides: Partial<StatusEntry> = {}): ScmProjectedResource {
  const entry = statusEntry({
    path: "src/metadata.c",
    nodeStatus: "normal",
    textStatus: "normal",
    propertyStatus: "normal",
    localStatus: "normal",
    ...overrides,
  });
  return {
    key: `local:${entry.path}`,
    repositoryId: "repo-uuid:C:/workspace",
    path: entry.path,
    source: "local",
    groupId: "changes",
    contextValue: "subversionr.workingCopyMetadata",
    tooltipKey: "scm.resource.workingCopyMetadata",
    entry,
  };
}

function scmChangelistProjectedResource(overrides: Partial<StatusEntry> = {}): ScmProjectedResource {
  const changelist = overrides.changelist ?? "review";
  const entry = statusEntry({
    path: "src/review.c",
    changelist,
    ...overrides,
  });
  return {
    key: `local:${entry.path}`,
    repositoryId: "repo-uuid:C:/workspace",
    path: entry.path,
    source: "local",
    groupId: `changelist:${encodeURIComponent(changelist)}`,
    contextValue: entry.kind === "file" ? "subversionr.changedFile" : "subversionr.changedDirectory",
    tooltipKey: "scm.resource.changed",
    entry,
  };
}

function statusEntry(overrides: Partial<StatusEntry> = {}): StatusEntry {
  return {
    path: overrides.path ?? "src/main.c",
    kind: overrides.kind ?? "file",
    nodeStatus: overrides.nodeStatus ?? "normal",
    textStatus: overrides.textStatus ?? "modified",
    propertyStatus: overrides.propertyStatus ?? "normal",
    localStatus: overrides.localStatus ?? "modified",
    remoteStatus: overrides.remoteStatus ?? "none",
    revision: overrides.revision ?? 3,
    changedRevision: overrides.changedRevision ?? 3,
    changedAuthor: overrides.changedAuthor ?? "alice",
    changedDate: overrides.changedDate ?? "2026-06-22T00:00:00Z",
    changelist: overrides.changelist ?? null,
    lock: overrides.lock ?? null,
    needsLock: overrides.needsLock ?? false,
    copy: overrides.copy ?? null,
    move: overrides.move ?? null,
    switched: overrides.switched ?? false,
    depth: overrides.depth ?? "infinity",
    conflict: overrides.conflict ?? null,
    external: overrides.external ?? false,
    generation: overrides.generation ?? 11,
  };
}

type RepositoryDiscoveryFixtureResponse = Pick<RepositoryDiscoveryResponse, "candidates"> &
  Partial<Pick<RepositoryDiscoveryResponse, "fileExternalBoundaries">>;

function fakeDiscoveryService(
  result: RepositoryDiscoveryFixtureResponse | Error,
): Pick<RepositoryDiscoveryService, "discoverRepositories" | "openDiscoveredRepository"> & {
  discoverRepositories: ReturnType<typeof vi.fn<RepositoryDiscoveryService["discoverRepositories"]>>;
  openDiscoveredRepository: ReturnType<typeof vi.fn<RepositoryDiscoveryService["openDiscoveredRepository"]>>;
} {
  return {
    discoverRepositories: vi.fn<RepositoryDiscoveryService["discoverRepositories"]>(() => {
      if (result instanceof Error) {
        return Promise.reject(result);
      }
      return Promise.resolve(discoveryResponse(result));
    }),
    openDiscoveredRepository: vi.fn<RepositoryDiscoveryService["openDiscoveredRepository"]>().mockResolvedValue(
      repositorySession(),
    ),
  };
}

function discoveryResponse(response: RepositoryDiscoveryFixtureResponse): RepositoryDiscoveryResponse {
  return {
    candidates: response.candidates,
    fileExternalBoundaries: response.fileExternalBoundaries ?? [],
  };
}

function fakeSessionService(options: { sessions?: RepositorySession[]; openedSession?: RepositorySession } = {}): Pick<
  RepositorySessionService,
  "closeRepository" | "listOpenSessions" | "openWorkingCopy" | "refreshSessionIdentityFromSnapshot"
> & {
  closeRepository: ReturnType<typeof vi.fn<RepositorySessionService["closeRepository"]>>;
  listOpenSessions: ReturnType<typeof vi.fn<RepositorySessionService["listOpenSessions"]>>;
  openWorkingCopy: ReturnType<typeof vi.fn<RepositorySessionService["openWorkingCopy"]>>;
  refreshSessionIdentityFromSnapshot: ReturnType<
    typeof vi.fn<RepositorySessionService["refreshSessionIdentityFromSnapshot"]>
  >;
} {
  return {
    closeRepository: vi.fn<RepositorySessionService["closeRepository"]>().mockResolvedValue(undefined),
    listOpenSessions: vi.fn<RepositorySessionService["listOpenSessions"]>(() => options.sessions ?? []),
    openWorkingCopy: vi.fn<RepositorySessionService["openWorkingCopy"]>().mockResolvedValue(
      options.openedSession ?? repositorySession(),
    ),
    refreshSessionIdentityFromSnapshot: vi.fn<RepositorySessionService["refreshSessionIdentityFromSnapshot"]>(
      () => options.sessions?.[0] ?? repositorySession(),
    ),
  };
}

function fakeRefreshService(): Pick<
  RepositoryRefreshService,
  "refreshRepository" | "fullReconcileRepository" | "refreshResource" | "refreshTargets"
> & {
  refreshRepository: ReturnType<
    typeof vi.fn<(repositoryId: string, options?: { signal?: AbortSignal }) => Promise<void>>
  >;
  fullReconcileRepository: ReturnType<
    typeof vi.fn<
      (session: { repositoryId: string; epoch: number }, options?: { signal?: AbortSignal }) => Promise<void>
    >
  >;
  refreshResource: ReturnType<
    typeof vi.fn<(target: { repositoryId: string; epoch: number; path: string }) => Promise<void>>
  >;
  refreshTargets: ReturnType<
    typeof vi.fn<
      (target: {
        repositoryId: string;
        epoch: number;
        targets: Array<{ path: string; depth: string; reason: string }>;
      }, options?: { signal?: AbortSignal }) => Promise<void>
    >
  >;
} {
  return {
    refreshRepository: vi.fn<(repositoryId: string, options?: { signal?: AbortSignal }) => Promise<void>>()
      .mockResolvedValue(undefined),
    fullReconcileRepository: vi
      .fn<(session: { repositoryId: string; epoch: number }, options?: { signal?: AbortSignal }) => Promise<void>>()
      .mockResolvedValue(undefined),
    refreshResource: vi
      .fn<(target: { repositoryId: string; epoch: number; path: string }) => Promise<void>>()
      .mockResolvedValue(undefined),
    refreshTargets: vi
      .fn<
        (target: {
          repositoryId: string;
          epoch: number;
          targets: Array<{ path: string; depth: string; reason: string }>;
        }, options?: { signal?: AbortSignal }) => Promise<void>
      >()
      .mockResolvedValue(undefined),
  };
}

function fakeOperationClient(response: OperationRunResponse): Pick<
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
  | "relocate"
  | "remove"
  | "resolve"
  | "revert"
  | "switch"
  | "unlock"
  | "update"
> & {
  add: ReturnType<typeof vi.fn<OperationClient["add"]>>;
  branchCreate: ReturnType<typeof vi.fn<OperationClient["branchCreate"]>>;
  changelistClear: ReturnType<typeof vi.fn<OperationClient["changelistClear"]>>;
  changelistSet: ReturnType<typeof vi.fn<OperationClient["changelistSet"]>>;
  cleanup: ReturnType<typeof vi.fn<OperationClient["cleanup"]>>;
  commit: ReturnType<typeof vi.fn<OperationClient["commit"]>>;
  lock: ReturnType<typeof vi.fn<OperationClient["lock"]>>;
  merge: ReturnType<typeof vi.fn<OperationClient["merge"]>>;
  move: ReturnType<typeof vi.fn<OperationClient["move"]>>;
  propertyDelete: ReturnType<typeof vi.fn<OperationClient["propertyDelete"]>>;
  propertySet: ReturnType<typeof vi.fn<OperationClient["propertySet"]>>;
  relocate: ReturnType<typeof vi.fn<OperationClient["relocate"]>>;
  remove: ReturnType<typeof vi.fn<OperationClient["remove"]>>;
  resolve: ReturnType<typeof vi.fn<OperationClient["resolve"]>>;
  revert: ReturnType<typeof vi.fn<OperationClient["revert"]>>;
  switch: ReturnType<typeof vi.fn<OperationClient["switch"]>>;
  unlock: ReturnType<typeof vi.fn<OperationClient["unlock"]>>;
  upgrade: ReturnType<typeof vi.fn<OperationClient["upgrade"]>>;
  update: ReturnType<typeof vi.fn<OperationClient["update"]>>;
} {
  return {
    add: vi.fn<OperationClient["add"]>().mockResolvedValue(response),
    branchCreate: vi.fn<OperationClient["branchCreate"]>().mockResolvedValue(response),
    changelistClear: vi.fn<OperationClient["changelistClear"]>().mockResolvedValue(response),
    changelistSet: vi.fn<OperationClient["changelistSet"]>().mockResolvedValue(response),
    cleanup: vi.fn<OperationClient["cleanup"]>().mockResolvedValue(response),
    commit: vi.fn<OperationClient["commit"]>().mockResolvedValue(response),
    lock: vi.fn<OperationClient["lock"]>().mockResolvedValue(response),
    merge: vi.fn<OperationClient["merge"]>().mockResolvedValue(response),
    move: vi.fn<OperationClient["move"]>().mockResolvedValue(response),
    propertyDelete: vi.fn<OperationClient["propertyDelete"]>().mockResolvedValue(response),
    propertySet: vi.fn<OperationClient["propertySet"]>().mockResolvedValue(response),
    relocate: vi.fn<OperationClient["relocate"]>().mockResolvedValue(response),
    remove: vi.fn<OperationClient["remove"]>().mockResolvedValue(response),
    resolve: vi.fn<OperationClient["resolve"]>().mockResolvedValue(response),
    revert: vi.fn<OperationClient["revert"]>().mockResolvedValue(response),
    switch: vi.fn<OperationClient["switch"]>().mockResolvedValue(response),
    unlock: vi.fn<OperationClient["unlock"]>().mockResolvedValue(response),
    upgrade: vi.fn<OperationClient["upgrade"]>().mockResolvedValue(response),
    update: vi.fn<OperationClient["update"]>().mockResolvedValue(response),
  };
}

function fakeCheckoutClient(response: RepositoryCheckoutResponse = checkoutResponse()): Pick<
  RepositoryCheckoutClient,
  "checkout"
> & {
  checkout: ReturnType<typeof vi.fn<RepositoryCheckoutClient["checkout"]>>;
} {
  return {
    checkout: vi.fn<RepositoryCheckoutClient["checkout"]>().mockResolvedValue(response),
  };
}

function fakePropertiesClient(response: PropertiesListResponse): Pick<PropertiesClient, "listProperties"> & {
  listProperties: ReturnType<typeof vi.fn<PropertiesClient["listProperties"]>>;
} {
  return {
    listProperties: vi.fn<PropertiesClient["listProperties"]>().mockResolvedValue(response),
  };
}

function fakeHistoryClient(response: HistoryLog): Pick<HistoryClient, "getLog"> & {
  getLog: ReturnType<typeof vi.fn<HistoryClient["getLog"]>>;
} {
  return {
    getLog: vi.fn<HistoryClient["getLog"]>().mockResolvedValue(response),
  };
}

function fakeOperationScheduler(): Pick<RepositoryOperationScheduler, "run"> {
  return {
    run: async <T>(_repositoryId: string, task: () => Promise<T>): Promise<T> => await task(),
  };
}

function sequenceNow(values: string[]): () => string {
  let index = 0;
  return () => {
    const value = values[index];
    if (value === undefined) {
      throw new Error("sequenceNow exhausted");
    }
    index += 1;
    return value;
  };
}

function sequenceNumber(values: number[]): () => number {
  let index = 0;
  return () => {
    const value = values[index];
    if (value === undefined) {
      throw new Error("sequenceNumber exhausted");
    }
    index += 1;
    return value;
  };
}

interface FakeCommandUi {
  workspaceRoots: ReturnType<typeof vi.fn<() => string[]>>;
  pathCasePolicy: ReturnType<typeof vi.fn<() => PathCasePolicy>>;
  pickRepositoryCandidate: ReturnType<
    typeof vi.fn<(candidates: RepositoryDiscoveryCandidate[]) => Promise<RepositoryDiscoveryCandidate | undefined>>
  >;
  pickOpenRepository: ReturnType<typeof vi.fn<(sessions: RepositorySession[]) => Promise<RepositorySession | undefined>>>;
  showInformationMessage: ReturnType<typeof vi.fn<(message: string) => Promise<void>>>;
  showWarningMessage: ReturnType<typeof vi.fn<(message: string) => Promise<void>>>;
  showErrorMessage: ReturnType<typeof vi.fn<(message: string) => Promise<void>>>;
  showTextDocument: ReturnType<
    typeof vi.fn<(document: { title: string; content: string; language: string }) => Promise<void>>
  >;
  confirmRevertResource: ReturnType<typeof vi.fn<(path: string) => Promise<boolean>>>;
  confirmRemoveResource: ReturnType<typeof vi.fn<(path: string) => Promise<boolean>>>;
  confirmRemoveResourceKeepLocal: ReturnType<typeof vi.fn<(path: string) => Promise<boolean>>>;
  promptMoveDestination: ReturnType<typeof vi.fn<(sourcePath: string) => Promise<string | undefined>>>;
  confirmDeleteUnversionedResources: ReturnType<typeof vi.fn<(paths: readonly string[]) => Promise<boolean>>>;
  promptResolveChoice: ReturnType<typeof vi.fn<(path: string) => Promise<FakeResolveChoice | undefined>>>;
  promptChangelistName: ReturnType<typeof vi.fn<(paths: readonly string[]) => Promise<string | undefined>>>;
  promptLockOptions: ReturnType<typeof vi.fn<(paths: readonly string[]) => Promise<FakeLockOptions | undefined>>>;
  promptUnlockOptions: ReturnType<typeof vi.fn<(paths: readonly string[]) => Promise<FakeUnlockOptions | undefined>>>;
  promptCleanupOptions: ReturnType<typeof vi.fn<(workingCopyRoot: string) => Promise<FakeCleanupOptions | undefined>>>;
  promptUpdateOptions: ReturnType<typeof vi.fn<(workingCopyRoot: string) => Promise<FakeUpdateOptions | undefined>>>;
  promptCheckoutOptions: ReturnType<typeof vi.fn<() => Promise<FakeCheckoutOptions | undefined>>>;
  promptBranchCreateOptions: ReturnType<typeof vi.fn<(workingCopyRoot: string) => Promise<FakeBranchCreateOptions | undefined>>>;
  promptSwitchOptions: ReturnType<typeof vi.fn<(workingCopyRoot: string) => Promise<FakeSwitchOptions | undefined>>>;
  promptRelocateOptions: ReturnType<
    typeof vi.fn<(workingCopyRoot: string, fromUrl: string) => Promise<FakeRelocateOptions | undefined>>
  >;
  promptMergeRangeOptions: ReturnType<typeof vi.fn<(workingCopyRoot: string) => Promise<FakeMergeRangeOptions | undefined>>>;
  promptPropertySetOptions: ReturnType<typeof vi.fn<(path: string) => Promise<FakePropertySetOptions | undefined>>>;
  promptPropertyDeleteName: ReturnType<
    typeof vi.fn<(path: string, properties: readonly PropertyEntry[]) => Promise<string | undefined>>
  >;
  promptExternalsPropertyValue: ReturnType<
    typeof vi.fn<(path: string, existingValue: string | undefined) => Promise<string | undefined>>
  >;
  promptReviewCommitTargets: ReturnType<
    typeof vi.fn<
      (targets: readonly FakeReviewCommitTarget[]) => Promise<readonly FakeReviewCommitTarget[] | undefined>
    >
  >;
  promptCommitMessageHistory: ReturnType<typeof vi.fn<(messages: readonly string[]) => Promise<string | undefined>>>;
  runOperationWithProgress: RepositoryCommandUi["runOperationWithProgress"] & ReturnType<typeof vi.fn>;
  workspaceTrusted: ReturnType<typeof vi.fn<() => boolean>>;
  hasUnsavedTextDocument: ReturnType<typeof vi.fn<(fsPath: string) => boolean>>;
  deleteLocalFile: ReturnType<typeof vi.fn<(fsPath: string, options: { recursive: boolean }) => Promise<void>>>;
  commitMessage: ReturnType<typeof vi.fn<(repositoryId: string) => string>>;
  setCommitMessage: ReturnType<typeof vi.fn<(repositoryId: string, message: string) => void>>;
  clearCommitMessage: ReturnType<typeof vi.fn<(repositoryId: string) => void>>;
  uriFile: ReturnType<typeof vi.fn<(fsPath: string) => { fsPath: string }>>;
  uriFromComponents: ReturnType<
    typeof vi.fn<(components: { scheme: string; authority: string; path: string; query: string }) => {
      scheme: string;
      authority: string;
      path: string;
      query: string;
    }>
  >;
  diffWithBase: ReturnType<typeof vi.fn<(left: unknown, right: unknown, title: string) => Promise<void>>>;
  openBase: ReturnType<typeof vi.fn<(uri: unknown, title: string) => Promise<void>>>;
  diffWithHead: ReturnType<typeof vi.fn<(left: unknown, right: unknown, title: string) => Promise<void>>>;
  openHead: ReturnType<typeof vi.fn<(uri: unknown, title: string) => Promise<void>>>;
  diffRevisions: ReturnType<typeof vi.fn<(left: unknown, right: unknown, title: string) => Promise<void>>>;
  showHistory: ReturnType<typeof vi.fn<(target: HistoryViewTarget) => Promise<void>>>;
  showBlame: ReturnType<typeof vi.fn<(target: HistoryBlameViewTarget) => Promise<void>>>;
}

interface FakeUpdateOptions {
  revision: "head" | number;
  depth: "workingCopy" | "empty" | "files" | "immediates" | "infinity";
  depthIsSticky: boolean;
  ignoreExternals: boolean;
}

interface FakeCheckoutOptions {
  url: string;
  targetPath: string;
  revision: "head" | number;
  depth: "empty" | "files" | "immediates" | "infinity";
  ignoreExternals: boolean;
}

interface FakeBranchCreateOptions {
  sourceUrl: string;
  destinationUrl: string;
  revision: "head" | number;
  message: string;
  makeParents: boolean;
  ignoreExternals: boolean;
  switchAfterCreate: boolean;
}

interface FakeSwitchOptions {
  url: string;
  revision: "head" | number;
  depth: "workingCopy" | "empty" | "files" | "immediates" | "infinity";
  depthIsSticky: boolean;
  ignoreExternals: boolean;
  ignoreAncestry: boolean;
}

interface FakeRelocateOptions {
  toUrl: string;
  ignoreExternals: boolean;
}

interface FakeMergeRangeOptions {
  sourceUrl: string;
  targetPath: string;
  startRevision: number;
  endRevision: number;
  depth: "empty" | "files" | "immediates" | "infinity";
  ignoreMergeinfo: boolean;
  diffIgnoreAncestry: boolean;
  forceDelete: boolean;
  recordOnly: boolean;
  dryRun: boolean;
  allowMixedRevisions: boolean;
}

interface FakePropertySetOptions {
  name: string;
  value: string;
}

interface FakeReviewCommitTarget {
  path: string;
  changelist: string | null;
  status: string;
  directory: string;
}

type FakeResolveChoice = "working" | "base" | "mineFull" | "theirsFull" | "mineConflict" | "theirsConflict";

interface FakeLockOptions {
  comment: string | null;
  stealLock: boolean;
}

interface FakeUnlockOptions {
  breakLock: boolean;
}

interface FakeCleanupOptions {
  breakLocks: boolean;
  fixRecordedTimestamps: boolean;
  clearDavCache: boolean;
  vacuumPristines: boolean;
  includeExternals: boolean;
}

function fakeCommandUi(options: {
  workspaceRoots: string[];
  pathCase?: PathCasePolicy;
  pickedCandidate?: RepositoryDiscoveryCandidate;
  pickedSession?: RepositorySession;
  revertConfirmed?: boolean;
  removeConfirmed?: boolean;
  removeKeepLocalConfirmed?: boolean;
  moveDestination?: string;
  deleteUnversionedConfirmed?: boolean;
  resolveChoice?: FakeResolveChoice;
  changelistName?: string;
  lockOptions?: FakeLockOptions;
  unlockOptions?: FakeUnlockOptions;
  cleanupOptions?: FakeCleanupOptions;
  updateOptions?: FakeUpdateOptions;
  checkoutOptions?: FakeCheckoutOptions;
  branchCreateOptions?: FakeBranchCreateOptions;
  switchOptions?: FakeSwitchOptions;
  relocateOptions?: FakeRelocateOptions;
  mergeRangeOptions?: FakeMergeRangeOptions;
  propertySetOptions?: FakePropertySetOptions;
  propertyDeleteName?: string;
  externalsPropertyValue?: string;
  reviewCommitSelection?: readonly string[];
  reviewCommitCancelled?: boolean;
  workspaceTrusted?: boolean;
  dirtyTextDocumentFsPaths?: string[];
  commitMessage?: string;
  pickedCommitHistoryMessage?: string;
  operationProgressSignal?: AbortSignal;
}): FakeCommandUi {
  const dirtyTextDocumentFsPaths = new Set(options.dirtyTextDocumentFsPaths ?? []);
  return {
    workspaceRoots: vi.fn(() => options.workspaceRoots),
    pathCasePolicy: vi.fn(() => options.pathCase ?? "case-insensitive"),
    pickRepositoryCandidate: vi.fn(async () => options.pickedCandidate),
    pickOpenRepository: vi.fn(async () => options.pickedSession),
    showInformationMessage: vi.fn(async () => undefined),
    showWarningMessage: vi.fn(async () => undefined),
    showErrorMessage: vi.fn(async () => undefined),
    showTextDocument: vi.fn(async () => undefined),
    confirmRevertResource: vi.fn(async () => options.revertConfirmed ?? true),
    confirmRemoveResource: vi.fn(async () => options.removeConfirmed ?? true),
    confirmRemoveResourceKeepLocal: vi.fn(async () => options.removeKeepLocalConfirmed ?? true),
    promptMoveDestination: vi.fn(async () => options.moveDestination),
    confirmDeleteUnversionedResources: vi.fn(async () => options.deleteUnversionedConfirmed ?? true),
    promptResolveChoice: vi.fn(async () => ("resolveChoice" in options ? options.resolveChoice : "working")),
    promptChangelistName: vi.fn(async () => options.changelistName ?? "review"),
    promptLockOptions: vi.fn(async () =>
      "lockOptions" in options ? options.lockOptions : { comment: null, stealLock: false },
    ),
    promptUnlockOptions: vi.fn(async () =>
      "unlockOptions" in options ? options.unlockOptions : { breakLock: false },
    ),
    promptCleanupOptions: vi.fn(async () =>
      "cleanupOptions" in options
        ? options.cleanupOptions
        : {
            breakLocks: true,
            fixRecordedTimestamps: false,
            clearDavCache: false,
            vacuumPristines: false,
            includeExternals: false,
          },
    ),
    promptUpdateOptions: vi.fn(async () => options.updateOptions),
    promptCheckoutOptions: vi.fn(async () =>
      "checkoutOptions" in options
        ? options.checkoutOptions
        : {
            url: "https://svn.example.invalid/project/trunk",
            targetPath: "C:/workspace/project",
            revision: "head",
            depth: "infinity",
            ignoreExternals: true,
          },
    ),
    promptBranchCreateOptions: vi.fn(async () =>
      "branchCreateOptions" in options
        ? options.branchCreateOptions
        : {
            sourceUrl: "https://svn.example.invalid/project/trunk",
            destinationUrl: "https://svn.example.invalid/project/branches/feature",
            revision: "head",
            message: "Create feature branch",
            makeParents: false,
            ignoreExternals: true,
            switchAfterCreate: false,
          },
    ),
    promptSwitchOptions: vi.fn(async () =>
      "switchOptions" in options
        ? options.switchOptions
        : {
            url: "https://svn.example.invalid/project/branches/feature",
            revision: "head",
            depth: "workingCopy",
            depthIsSticky: false,
            ignoreExternals: true,
            ignoreAncestry: false,
          },
    ),
    promptRelocateOptions: vi.fn(async () =>
      "relocateOptions" in options
        ? options.relocateOptions
        : {
            toUrl: "https://svn.example.invalid/project",
            ignoreExternals: true,
          },
    ),
    promptMergeRangeOptions: vi.fn(async () =>
      "mergeRangeOptions" in options
        ? options.mergeRangeOptions
        : {
            sourceUrl: "https://svn.example.invalid/project/branches/feature",
            targetPath: ".",
            startRevision: 1,
            endRevision: 2,
            depth: "infinity",
            ignoreMergeinfo: false,
            diffIgnoreAncestry: false,
            forceDelete: false,
            recordOnly: false,
            dryRun: false,
            allowMixedRevisions: false,
          },
    ),
    promptPropertySetOptions: vi.fn(async () => options.propertySetOptions),
    promptPropertyDeleteName: vi.fn(async (_path, properties) =>
      "propertyDeleteName" in options ? options.propertyDeleteName : properties[0]?.name,
    ),
    promptExternalsPropertyValue: vi.fn(async () => options.externalsPropertyValue),
    promptReviewCommitTargets: vi.fn(async (targets) => {
      if (options.reviewCommitCancelled) {
        return undefined;
      }
      if (!("reviewCommitSelection" in options)) {
        return targets;
      }
      const selectedPaths = new Set(options.reviewCommitSelection);
      return targets.filter((target) => selectedPaths.has(target.path));
    }),
    promptCommitMessageHistory: vi.fn(async () => options.pickedCommitHistoryMessage),
    runOperationWithProgress: vi.fn((_title, task) => task(options.operationProgressSignal)) as FakeCommandUi["runOperationWithProgress"],
    workspaceTrusted: vi.fn(() => options.workspaceTrusted ?? true),
    hasUnsavedTextDocument: vi.fn((fsPath) => dirtyTextDocumentFsPaths.has(fsPath)),
    deleteLocalFile: vi.fn(async () => undefined),
    commitMessage: vi.fn(() => options.commitMessage ?? "commit tracked file"),
    setCommitMessage: vi.fn(() => undefined),
    clearCommitMessage: vi.fn(() => undefined),
    uriFile: vi.fn((fsPath) => ({ fsPath })),
    uriFromComponents: vi.fn((components) => components),
    diffWithBase: vi.fn(async () => undefined),
    openBase: vi.fn(async () => undefined),
    diffWithHead: vi.fn(async () => undefined),
    openHead: vi.fn(async () => undefined),
    diffRevisions: vi.fn(async () => undefined),
    showHistory: vi.fn(async () => undefined),
    showBlame: vi.fn(async () => undefined),
  };
}

function fakeCommitMessageHistory(messages: readonly string[] = []): Pick<RepositoryCommitMessageHistory, "messages" | "record"> & {
  messages: ReturnType<typeof vi.fn<(repositoryId: string) => readonly string[]>>;
  record: ReturnType<typeof vi.fn<(repositoryId: string, message: string) => void>>;
} {
  return {
    messages: vi.fn(() => [...messages]),
    record: vi.fn(() => undefined),
  };
}

interface WriteOperationScenario {
  label: string;
  contextValue: string;
  path: string;
  clientMethod: "add" | "remove" | "revert";
  errorCode: string;
  invoke(controller: RepositoryCommandController, states: unknown[]): Promise<void>;
  validProjection(options?: { generation?: number }): ScmRepositoryProjection;
  unauthorizedProjection(): ScmRepositoryProjection;
}

function writeOperationScenarios(): WriteOperationScenario[] {
  return [
    {
      label: "Add",
      contextValue: "subversionr.unversioned",
      path: "scratch.txt",
      clientMethod: "add",
      errorCode: "SUBVERSIONR_RESOURCE_ADD_TARGET_INVALID",
      invoke: (controller, states) => controller.addResource(states),
      validProjection: (options = {}) =>
        scmProjection({
          generation: options.generation,
          resources: [scmUnversionedProjectedResource({ path: "scratch.txt", generation: options.generation })],
        }),
      unauthorizedProjection: () =>
        scmProjection({ resources: [scmProjectedResource({ path: "scratch.txt" })] }),
    },
    {
      label: "Remove",
      contextValue: "subversionr.changedFile",
      path: "src/old.c",
      clientMethod: "remove",
      errorCode: "SUBVERSIONR_RESOURCE_REMOVE_TARGET_INVALID",
      invoke: (controller, states) => controller.removeResource(states),
      validProjection: (options = {}) =>
        scmProjection({
          generation: options.generation,
          resources: [scmProjectedResource({ path: "src/old.c", generation: options.generation })],
        }),
      unauthorizedProjection: () =>
        scmProjection({ resources: [scmUnversionedProjectedResource({ path: "src/old.c" })] }),
    },
    {
      label: "Remove Keep Local",
      contextValue: "subversionr.changedFile",
      path: "src/old.c",
      clientMethod: "remove",
      errorCode: "SUBVERSIONR_RESOURCE_REMOVE_TARGET_INVALID",
      invoke: (controller, states) => controller.removeResourceKeepLocal(states),
      validProjection: (options = {}) =>
        scmProjection({
          generation: options.generation,
          resources: [scmProjectedResource({ path: "src/old.c", generation: options.generation })],
        }),
      unauthorizedProjection: () =>
        scmProjection({ resources: [scmUnversionedProjectedResource({ path: "src/old.c" })] }),
    },
    {
      label: "Revert",
      contextValue: "subversionr.changedFile",
      path: "src/main.c",
      clientMethod: "revert",
      errorCode: "SUBVERSIONR_RESOURCE_REVERT_TARGET_INVALID",
      invoke: (controller, states) => controller.revertResource(states),
      validProjection: (options = {}) =>
        scmProjection({
          generation: options.generation,
          resources: [scmProjectedResource({ path: "src/main.c", generation: options.generation })],
        }),
      unauthorizedProjection: () =>
        scmProjection({ resources: [scmUnversionedProjectedResource({ path: "src/main.c" })] }),
    },
  ];
}

function scmWriteState(
  contextValue: string,
  repositoryPath: string,
  options: { generation?: number; root?: string } = {},
): Record<string, unknown> {
  return {
    contextValue,
    resourceUri: { fsPath: repositoryPathToFsPath(options.root ?? "C:\\workspace", repositoryPath) },
    ...(options.generation === undefined ? {} : { subversionrProjectionGeneration: options.generation }),
  };
}

function repositoryPathToFsPath(root: string, repositoryPath: string): string {
  if (repositoryPath === ".") {
    return root;
  }
  return `${root}\\${repositoryPath.replace(/\//g, "\\")}`;
}

function expectWriteConfirmationsNotCalled(ui: FakeCommandUi): void {
  expect(ui.confirmRevertResource).not.toHaveBeenCalled();
  expect(ui.confirmRemoveResource).not.toHaveBeenCalled();
  expect(ui.confirmRemoveResourceKeepLocal).not.toHaveBeenCalled();
}

function discoveryCandidate(
  overrides: Partial<RepositoryDiscoveryCandidate["identity"]> = {},
  candidateOverrides: Partial<Pick<RepositoryDiscoveryCandidate, "isNested" | "isExternal" | "parentWorkingCopyRoot">> = {},
): RepositoryDiscoveryCandidate {
  const workingCopyRoot = overrides.workingCopyRoot ?? "C:\\workspace";
  return {
    identity: {
      repositoryUuid: overrides.repositoryUuid ?? "repo-uuid",
      repositoryRootUrl: overrides.repositoryRootUrl ?? "file:///C:/repo",
      workingCopyRoot,
      workspaceScopeRoot: overrides.workspaceScopeRoot ?? workingCopyRoot,
      format: overrides.format ?? 31,
    },
    isNested: candidateOverrides.isNested ?? false,
    isExternal: candidateOverrides.isExternal ?? false,
    ...(candidateOverrides.parentWorkingCopyRoot
      ? { parentWorkingCopyRoot: candidateOverrides.parentWorkingCopyRoot }
      : {}),
  };
}

function repositorySession(
  overrides: Partial<{ repositoryId: string; repositoryRootUrl: string; workingCopyRoot: string }> = {},
): RepositorySession {
  const repositoryId = overrides.repositoryId ?? "repo-uuid:C:/workspace";
  const workingCopyRoot = overrides.workingCopyRoot ?? "C:\\workspace";
  return {
    repositoryId,
    epoch: 7,
    identity: discoveryCandidate({
      repositoryRootUrl: overrides.repositoryRootUrl,
      workingCopyRoot,
    }).identity,
    watchScope: {
      repositoryId,
      epoch: 7,
      workingCopyRoot,
      pathCase: "case-insensitive",
    },
  };
}

class CodedError extends Error {
  public constructor(public readonly code: string) {
    super(code);
  }
}

function operationResponse(
  overrides: Partial<Pick<OperationRunResponse, "kind" | "reconcile" | "revision">> & {
    path?: string;
    depth?: "empty" | "files" | "immediates" | "infinity";
    reason?: string;
  } = {},
): OperationRunResponse {
  const kind = overrides.kind ?? "revert";
  const path = overrides.path ?? "src/main.c";
  return {
    repositoryId: "repo-uuid:C:/workspace",
    epoch: 7,
    operationId: "op-1",
    kind,
    touchedPaths: [path],
    revision: overrides.revision ?? null,
    summary: {
      affectedPaths: 1,
      skippedPaths: 0,
    },
    warnings: [],
    reconcile: overrides.reconcile ?? {
      targets: [{ path, depth: overrides.depth ?? "empty", reason: overrides.reason ?? "operationRevert" }],
      requiresFullReconcile: false,
    },
  };
}

function propertiesResponse(overrides: Partial<PropertiesListResponse> = {}): PropertiesListResponse {
  return {
    repositoryId: overrides.repositoryId ?? "repo-uuid:C:/workspace",
    epoch: overrides.epoch ?? 7,
    path: overrides.path ?? ".",
    properties: overrides.properties ?? [],
    source: overrides.source ?? "libsvn-local",
  };
}

function checkoutResponse(overrides: Partial<RepositoryCheckoutResponse> = {}): RepositoryCheckoutResponse {
  return {
    workingCopyPath: overrides.workingCopyPath ?? "C:/workspace/project",
    revision: overrides.revision ?? 42,
  };
}

function historyLog(overrides: Partial<HistoryLog> = {}): HistoryLog {
  return {
    repositoryId: overrides.repositoryId ?? "repo-uuid:C:/workspace",
    epoch: overrides.epoch ?? 7,
    path: overrides.path ?? "src/main.c",
    startRevision: overrides.startRevision ?? ("r3" as HistoryLog["startRevision"]),
    endRevision: overrides.endRevision ?? ("r0" as HistoryLog["endRevision"]),
    limit: overrides.limit ?? 2,
    entries: overrides.entries ?? [historyEntry(3), historyEntry(2)],
    source: overrides.source ?? "libsvn-log",
  };
}

function historyEntry(revision: number): HistoryLog["entries"][number] {
  return {
    revision,
    author: "alice",
    date: "2026-06-22T00:00:00Z",
    message: `revision ${revision}`,
    changedPaths: [],
    hasChildren: false,
    nonInheritable: false,
    subtractiveMerge: false,
  };
}

interface Deferred<T> {
  promise: Promise<T>;
  resolve(value: T | PromiseLike<T>): void;
  reject(error: unknown): void;
}

function deferred<T>(): Deferred<T> {
  let resolve: (value: T | PromiseLike<T>) => void = () => undefined;
  let reject: (error: unknown) => void = () => undefined;
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}

function withTimeout<T>(promise: Promise<T>, timeoutMs: number): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => {
      reject(new Error(`timed out after ${timeoutMs}ms`));
    }, timeoutMs);
    promise.then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      (error: unknown) => {
        clearTimeout(timer);
        reject(error);
      },
    );
  });
}

async function flushMicrotasks(): Promise<void> {
  await Promise.resolve();
  await Promise.resolve();
}
