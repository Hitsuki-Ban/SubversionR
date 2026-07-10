import type { RepositoryAutoOpenTrigger, RepositoryLifecycleEvent } from "./repositoryLifecycleService";

export interface RepositoryLifecycleNotificationUi {
  showInformationMessage(message: string): Promise<void>;
  showWarningMessage(message: string): Promise<void>;
  showErrorMessage(message: string, ...actions: string[]): Promise<string | undefined>;
}

export interface RepositoryLifecycleNotificationServiceOptions {
  ui: RepositoryLifecycleNotificationUi;
  localize(message: string, ...args: unknown[]): string;
  retryDisappearedRepositoryCleanup(trigger: RepositoryAutoOpenTrigger): Promise<void>;
  retryMovedRepositoryRecovery(trigger: RepositoryAutoOpenTrigger): Promise<void>;
  retryWorkspaceRepositoryOpen(trigger: RepositoryAutoOpenTrigger): Promise<void>;
}

export class RepositoryLifecycleNotificationService {
  public constructor(private readonly options: RepositoryLifecycleNotificationServiceOptions) {}

  public async handleEvent(event: RepositoryLifecycleEvent): Promise<void> {
    if (event.kind === "openSessionClosed" && event.reason === "workingCopyMissing") {
      await this.options.ui.showWarningMessage(
        this.options.localize("SubversionR closed missing SVN working copy: {0}", event.workingCopyRoot),
      );
      return;
    }
    if (event.kind === "openSessionCloseFailed" && event.reason === "workingCopyMissing") {
      await this.showErrorWithAction(
        this.options.localize(
          "SubversionR could not close missing SVN working copy {0}: {1}",
          event.workingCopyRoot,
          event.code,
        ),
        this.options.localize("Retry Close"),
        () => this.options.retryDisappearedRepositoryCleanup(event.trigger),
      );
      return;
    }
    if (event.kind === "openSessionCloseFailed" && event.reason === "workingCopyStatusUnavailable") {
      await this.showErrorWithAction(
        this.options.localize("SubversionR could not check SVN working copy {0}: {1}", event.workingCopyRoot, event.code),
        this.options.localize("Retry Check"),
        () => this.options.retryDisappearedRepositoryCleanup(event.trigger),
      );
      return;
    }
    if (event.kind === "openSessionMoved") {
      await this.options.ui.showInformationMessage(
        this.options.localize(
          "SubversionR reopened moved SVN working copy: {0} -> {1}",
          event.previousWorkingCopyRoot,
          event.workingCopyRoot,
        ),
      );
      return;
    }
    if (event.kind === "openSessionMoveFailed") {
      const message = this.options.localize(
        "SubversionR could not recover moved SVN working copy {0}: {1}",
        event.workingCopyRoot,
        event.code,
      );
      if (event.reason === "closeFailed") {
        await this.showErrorWithAction(message, this.options.localize("Retry Recovery"), () =>
          this.options.retryMovedRepositoryRecovery(event.trigger),
        );
        return;
      }
      if (event.reason === "openFailed") {
        await this.showErrorWithAction(message, this.options.localize("Retry Open"), () =>
          this.options.retryWorkspaceRepositoryOpen(event.trigger),
        );
        return;
      }
      await this.options.ui.showErrorMessage(message);
      return;
    }
    if (event.kind === "openSessionReopenFailed") {
      await this.options.ui.showErrorMessage(
        this.options.localize(
          "SubversionR could not reopen SVN working copy after backend restart {0}: {1}",
          event.workingCopyRoot,
          event.code,
        ),
      );
    }
  }

  private async showErrorWithAction(message: string, action: string, onAction: () => Promise<void>): Promise<void> {
    const selected = await this.options.ui.showErrorMessage(message, action);
    if (selected !== action) {
      return;
    }
    try {
      await onAction();
    } catch (error) {
      await this.options.ui.showErrorMessage(
        this.options.localize("SubversionR repository lifecycle retry failed: {0}", errorCode(error)),
      );
    }
  }
}

function errorCode(error: unknown): string {
  if (typeof error === "object" && error !== null && "code" in error) {
    const code = (error as { code?: unknown }).code;
    if (typeof code === "string" && code.trim().length > 0) {
      return code;
    }
  }
  return "SUBVERSIONR_REPOSITORY_LIFECYCLE_RETRY_FAILED";
}
