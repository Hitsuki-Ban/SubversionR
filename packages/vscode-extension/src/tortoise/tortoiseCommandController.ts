import type { RepositorySession, RepositorySessionService } from "../repository/repositorySessionService";
import { requireExternalToolExecutionTrusted } from "../security/externalToolConfiguration";
import type { TortoiseDetectionResult } from "./tortoiseDetector";
import type { TortoiseIntent, TortoiseLaunchRequest } from "./tortoiseLauncher";

export interface TortoiseCommandControllerOptions {
  detector: {
    detect(): Promise<TortoiseDetectionResult>;
  };
  launcher(request: TortoiseLaunchRequest): Promise<void>;
  sessionService: Pick<RepositorySessionService, "listOpenSessions">;
  ui: TortoiseCommandUi;
  localize(message: string, ...args: unknown[]): string;
}

export interface TortoiseCommandUi {
  workspaceTrusted(): boolean;
  pickOpenRepository(sessions: RepositorySession[]): Promise<RepositorySession | undefined>;
  showWarningMessage(message: string): Promise<void>;
  showErrorMessage(message: string): Promise<void>;
}

export class TortoiseCommandController {
  public constructor(private readonly options: TortoiseCommandControllerOptions) {}

  public async openRepositoryLog(repositoryId?: unknown): Promise<void> {
    await this.launchForRepository("log", repositoryId);
  }

  public async openRepositoryRevisionGraph(repositoryId?: unknown): Promise<void> {
    await this.launchForRepository("revisiongraph", repositoryId);
  }

  public async openRepositoryBrowser(repositoryId?: unknown): Promise<void> {
    await this.launchForRepository("repobrowser", repositoryId);
  }

  public async openResourceLog(...resourceStates: unknown[]): Promise<void> {
    await this.launchForResource("log", resourceStates);
  }

  public async diffResource(...resourceStates: unknown[]): Promise<void> {
    await this.launchForResource("diff", resourceStates);
  }

  public async blameResource(...resourceStates: unknown[]): Promise<void> {
    await this.launchForResource("blame", resourceStates);
  }

  private async launchForRepository(intent: TortoiseIntent, repositoryId?: unknown): Promise<void> {
    try {
      requireExternalToolExecutionTrusted(this.options.ui.workspaceTrusted(), "tortoise");
      const session = await this.selectOpenSession(repositoryId);
      if (!session) {
        return;
      }
      await this.launch(intent, session.identity.workingCopyRoot);
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  private async launchForResource(intent: TortoiseIntent, resourceStates: unknown[]): Promise<void> {
    try {
      requireExternalToolExecutionTrusted(this.options.ui.workspaceTrusted(), "tortoise");
      const target = this.resourceTarget(resourceStates);
      await this.launch(intent, target.fsPath);
    } catch (error) {
      await this.showCommandError(error);
    }
  }

  private async launch(intent: TortoiseIntent, targetPath: string): Promise<void> {
    const detection = await this.options.detector.detect();
    if (detection.status === "unavailable") {
      return;
    }
    await this.options.launcher({
      executablePath: detection.executablePath,
      intent,
      path: targetPath,
      configDirectory: detection.configDirectory,
    });
  }

  private async selectOpenSession(repositoryId?: unknown): Promise<RepositorySession | undefined> {
    const sessions = this.options.sessionService.listOpenSessions();
    if (repositoryId !== undefined) {
      if (typeof repositoryId !== "string") {
        throw tortoiseCommandError(
          "SUBVERSIONR_TORTOISE_REPOSITORY_TARGET_INVALID",
          "input",
          "error.tortoise.repositoryTargetInvalid",
        );
      }
      const session = sessions.find((candidate) => candidate.repositoryId === repositoryId);
      if (!session) {
        throw tortoiseCommandError(
          "SUBVERSIONR_TORTOISE_REPOSITORY_TARGET_INVALID",
          "input",
          "error.tortoise.repositoryTargetInvalid",
          { repositoryId },
        );
      }
      return session;
    }
    if (sessions.length === 0) {
      await this.options.ui.showWarningMessage(this.options.localize("No SVN repository is open."));
      return undefined;
    }
    if (sessions.length === 1) {
      return sessions[0];
    }
    return await this.options.ui.pickOpenRepository(sessions);
  }

  private resourceTarget(resourceStates: unknown[]): { fsPath: string; session: RepositorySession } {
    const normalizedResourceStates = normalizeResourceStateArgs(resourceStates);
    if (normalizedResourceStates.length !== 1) {
      throw tortoiseCommandError(
        "SUBVERSIONR_TORTOISE_RESOURCE_TARGET_INVALID",
        "input",
        "error.tortoise.resourceTargetInvalid",
      );
    }
    const [resourceState] = normalizedResourceStates;
    const fsPath = resourceFsPath(resourceState);
    if (fsPath === undefined) {
      throw tortoiseCommandError(
        "SUBVERSIONR_TORTOISE_RESOURCE_TARGET_INVALID",
        "input",
        "error.tortoise.resourceTargetInvalid",
      );
    }
    if (hasDotSegment(fsPath)) {
      throw tortoiseCommandError(
        "SUBVERSIONR_TORTOISE_RESOURCE_PATH_INVALID",
        "input",
        "error.tortoise.resourcePathInvalid",
        { fsPath },
      );
    }
    const match = mostSpecificResourceMatch(this.options.sessionService.listOpenSessions(), fsPath);
    if (!match) {
      throw tortoiseCommandError(
        "SUBVERSIONR_TORTOISE_RESOURCE_OUTSIDE_REPOSITORY",
        "input",
        "error.tortoise.resourceOutsideRepository",
        { fsPath },
      );
    }
    if (isSvnInternalPath(match.session, fsPath)) {
      throw tortoiseCommandError(
        "SUBVERSIONR_TORTOISE_RESOURCE_INTERNAL_PATH",
        "input",
        "error.tortoise.resourceInternalPath",
        { fsPath },
      );
    }
    return { fsPath, session: match.session };
  }

  private async showCommandError(error: unknown): Promise<void> {
    await this.options.ui.showErrorMessage(
      this.options.localize("SubversionR TortoiseSVN command failed: {0}", errorCode(error)),
    );
  }
}

function resourceFsPath(resourceState: unknown): string | undefined {
  if (!isRecord(resourceState)) {
    return undefined;
  }
  if (isRecord(resourceState.resourceUri) && typeof resourceState.resourceUri.fsPath === "string") {
    return resourceState.resourceUri.fsPath;
  }
  if (typeof resourceState.fsPath === "string") {
    return resourceState.fsPath;
  }
  return undefined;
}

type TortoiseCommandErrorCategory = "input" | "lifecycle";

class TortoiseCommandError extends Error {
  public constructor(
    public readonly code: string,
    public readonly category: TortoiseCommandErrorCategory,
    public readonly messageKey: string,
    public readonly safeArgs: Record<string, unknown> = {},
  ) {
    super(code);
    this.name = "TortoiseCommandError";
  }
}

interface ResourceMatch {
  session: RepositorySession;
  rootLength: number;
}

function normalizeResourceStateArgs(resourceStateArgs: unknown[]): unknown[] {
  if (resourceStateArgs.length === 1 && Array.isArray(resourceStateArgs[0])) {
    return resourceStateArgs[0] as unknown[];
  }
  return resourceStateArgs;
}

function mostSpecificResourceMatch(sessions: RepositorySession[], fsPath: string): ResourceMatch | undefined {
  const matches = sessions.flatMap((session) => {
    const match = resourceMatch(session, fsPath);
    return match ? [match] : [];
  });
  return matches.sort((left, right) => right.rootLength - left.rootLength)[0];
}

function resourceMatch(session: RepositorySession, fsPath: string): ResourceMatch | undefined {
  const root = normalizeAbsolutePath(session.identity.workingCopyRoot);
  const target = normalizeAbsolutePath(fsPath);
  const pathCase = session.watchScope.pathCase;
  const rootKey = comparisonKey(pathCase, root);
  const targetKey = comparisonKey(pathCase, target);
  if (targetKey === rootKey || targetKey.startsWith(`${rootKey}/`)) {
    return { session, rootLength: rootKey.length };
  }
  return undefined;
}

function isSvnInternalPath(session: RepositorySession, fsPath: string): boolean {
  const root = normalizeAbsolutePath(session.identity.workingCopyRoot);
  const target = normalizeAbsolutePath(fsPath);
  const pathCase = session.watchScope.pathCase;
  const rootKey = comparisonKey(pathCase, root);
  const targetKey = comparisonKey(pathCase, target);
  const relativePath = targetKey === rootKey ? "." : targetKey.slice(rootKey.length + 1);
  return relativePath === ".svn" || relativePath.startsWith(".svn/");
}

function hasDotSegment(pathValue: string): boolean {
  return pathValue.replaceAll("\\", "/").split("/").some((segment) => segment === "." || segment === "..");
}

function normalizeAbsolutePath(pathValue: string): string {
  return pathValue.replaceAll("\\", "/").replace(/\/+$/u, "");
}

function comparisonKey(pathCase: "case-sensitive" | "case-insensitive", pathValue: string): string {
  return pathCase === "case-insensitive" ? pathValue.toLocaleLowerCase("en-US") : pathValue;
}

function tortoiseCommandError(
  code: string,
  category: TortoiseCommandErrorCategory,
  messageKey: string,
  safeArgs: Record<string, unknown> = {},
): TortoiseCommandError {
  return new TortoiseCommandError(code, category, messageKey, safeArgs);
}

function errorCode(error: unknown): string {
  if (isRecord(error) && typeof error.code === "string" && error.code.trim().length > 0) {
    return error.code;
  }
  return "SUBVERSIONR_TORTOISE_COMMAND_FAILED";
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}
