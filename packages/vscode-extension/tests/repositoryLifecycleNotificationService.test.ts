import { describe, expect, it, vi } from "vitest";
import {
  RepositoryLifecycleNotificationService,
  type RepositoryLifecycleNotificationUi,
} from "../src/repository/repositoryLifecycleNotificationService";

describe("RepositoryLifecycleNotificationService", () => {
  it("records automatic open failures without showing a notification", async () => {
    const ui = notificationUi();
    const recordFailure = vi.fn();
    const service = notificationService({ ui, recordFailure });

    await service.handleEvent({
      kind: "autoOpenFailed",
      trigger: "activation",
      code: "SUBVERSIONR_REPOSITORY_DISCOVERY_FAILED",
    });

    expect(recordFailure).toHaveBeenCalledWith("Repository Auto Open", {
      code: "SUBVERSIONR_REPOSITORY_DISCOVERY_FAILED",
      category: "lifecycle",
      messageKey: "error.repository.autoOpenFailed",
      safeArgs: { trigger: "activation" },
      retryable: false,
      diagnostics: null,
    });
    expect(ui.showInformationMessage).not.toHaveBeenCalled();
    expect(ui.showWarningMessage).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).not.toHaveBeenCalled();
  });

  it("offers a retry action when closing a missing working copy fails", async () => {
    const ui = notificationUi({ selectedErrorAction: "l10n:Retry Close" });
    const retryDisappearedRepositoryCleanup = vi.fn(async () => undefined);
    const service = notificationService({
      ui,
      retryDisappearedRepositoryCleanup,
    });

    await service.handleEvent({
      kind: "openSessionCloseFailed",
      trigger: "workspaceFolders",
      reason: "workingCopyMissing",
      repositoryId: "repo-1",
      epoch: 7,
      workingCopyRoot: "C:\\missing",
      code: "SUBVERSIONR_REPOSITORY_CLOSE_FAILED",
    });

    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "l10n:SubversionR could not close missing SVN working copy {0}: {1}:C:\\missing:SUBVERSIONR_REPOSITORY_CLOSE_FAILED",
      "l10n:Retry Close",
    );
    expect(retryDisappearedRepositoryCleanup).toHaveBeenCalledWith("workspaceFolders");
  });

  it("offers a retry action when checking a working-copy root fails", async () => {
    const ui = notificationUi({ selectedErrorAction: "l10n:Retry Check" });
    const retryDisappearedRepositoryCleanup = vi.fn(async () => undefined);
    const service = notificationService({
      ui,
      retryDisappearedRepositoryCleanup,
    });

    await service.handleEvent({
      kind: "openSessionCloseFailed",
      trigger: "activation",
      reason: "workingCopyStatusUnavailable",
      repositoryId: "repo-1",
      epoch: 7,
      workingCopyRoot: "C:\\workspace",
      code: "SUBVERSIONR_WORKING_COPY_STAT_FAILED",
    });

    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "l10n:SubversionR could not check SVN working copy {0}: {1}:C:\\workspace:SUBVERSIONR_WORKING_COPY_STAT_FAILED",
      "l10n:Retry Check",
    );
    expect(retryDisappearedRepositoryCleanup).toHaveBeenCalledWith("activation");
  });

  it("offers moved recovery retry when closing the old moved session fails", async () => {
    const ui = notificationUi({ selectedErrorAction: "l10n:Retry Recovery" });
    const retryMovedRepositoryRecovery = vi.fn(async () => undefined);
    const service = notificationService({
      ui,
      retryMovedRepositoryRecovery,
    });

    await service.handleEvent({
      kind: "openSessionMoveFailed",
      trigger: "workspaceFolders",
      reason: "closeFailed",
      repositoryId: "repo-1",
      epoch: 7,
      workingCopyRoot: "C:\\old-wc",
      code: "SUBVERSIONR_REPOSITORY_CLOSE_FAILED",
    });

    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "l10n:SubversionR could not recover moved SVN working copy {0}: {1}:C:\\old-wc:SUBVERSIONR_REPOSITORY_CLOSE_FAILED",
      "l10n:Retry Recovery",
    );
    expect(retryMovedRepositoryRecovery).toHaveBeenCalledWith("workspaceFolders");
  });

  it("offers automatic open retry when moved recovery closes the old session but opening the new one fails", async () => {
    const ui = notificationUi({ selectedErrorAction: "l10n:Retry Open" });
    const retryWorkspaceRepositoryOpen = vi.fn(async () => undefined);
    const service = notificationService({
      ui,
      retryWorkspaceRepositoryOpen,
    });

    await service.handleEvent({
      kind: "openSessionMoveFailed",
      trigger: "workspaceFolders",
      reason: "openFailed",
      repositoryId: "repo-1",
      epoch: 7,
      workingCopyRoot: "C:\\old-wc",
      code: "SUBVERSIONR_REPOSITORY_OPEN_FAILED",
    });

    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "l10n:SubversionR could not recover moved SVN working copy {0}: {1}:C:\\old-wc:SUBVERSIONR_REPOSITORY_OPEN_FAILED",
      "l10n:Retry Open",
    );
    expect(retryWorkspaceRepositoryOpen).toHaveBeenCalledWith("workspaceFolders");
  });

  it("reports a stable code when the selected retry action fails", async () => {
    const ui = notificationUi({ selectedErrorAction: "l10n:Retry Close" });
    const service = notificationService({
      ui,
      retryDisappearedRepositoryCleanup: vi.fn(async () => {
        throw new CodedError("SUBVERSIONR_REPOSITORY_RETRY_FAILED");
      }),
    });

    await service.handleEvent({
      kind: "openSessionCloseFailed",
      trigger: "workspaceFolders",
      reason: "workingCopyMissing",
      repositoryId: "repo-1",
      epoch: 7,
      workingCopyRoot: "C:\\missing",
      code: "SUBVERSIONR_REPOSITORY_CLOSE_FAILED",
    });

    expect(ui.showErrorMessage).toHaveBeenLastCalledWith(
      "l10n:SubversionR repository lifecycle retry failed: {0}:SUBVERSIONR_REPOSITORY_RETRY_FAILED",
    );
  });
});

function notificationService(
  options: {
    ui?: RepositoryLifecycleNotificationUi;
    recordFailure?: (operation: string, error: unknown) => void;
    retryDisappearedRepositoryCleanup?: (trigger: "activation" | "workspaceTrust" | "workspaceFolders") => Promise<void>;
    retryMovedRepositoryRecovery?: (trigger: "activation" | "workspaceTrust" | "workspaceFolders") => Promise<void>;
    retryWorkspaceRepositoryOpen?: (trigger: "activation" | "workspaceTrust" | "workspaceFolders") => Promise<void>;
  } = {},
): RepositoryLifecycleNotificationService {
  return new RepositoryLifecycleNotificationService({
    ui: options.ui ?? notificationUi(),
    localize: localizeForTest,
    recordFailure: options.recordFailure ?? vi.fn(),
    retryDisappearedRepositoryCleanup: options.retryDisappearedRepositoryCleanup ?? vi.fn(async () => undefined),
    retryMovedRepositoryRecovery: options.retryMovedRepositoryRecovery ?? vi.fn(async () => undefined),
    retryWorkspaceRepositoryOpen: options.retryWorkspaceRepositoryOpen ?? vi.fn(async () => undefined),
  });
}

function notificationUi(options: { selectedErrorAction?: string } = {}): RepositoryLifecycleNotificationUi {
  return {
    showInformationMessage: vi.fn(async () => undefined),
    showWarningMessage: vi.fn(async () => undefined),
    showErrorMessage: vi.fn(async () => options.selectedErrorAction),
  };
}

function localizeForTest(message: string, ...args: unknown[]): string {
  return ["l10n", message, ...args].join(":");
}

class CodedError extends Error {
  public constructor(public readonly code: string) {
    super(code);
  }
}
