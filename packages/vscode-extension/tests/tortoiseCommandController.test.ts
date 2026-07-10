import { describe, expect, it, vi } from "vitest";
import { TortoiseCommandController } from "../src/tortoise/tortoiseCommandController";
import type { RepositorySession, RepositorySessionService } from "../src/repository/repositorySessionService";
import type {
  TortoiseDetectionResult,
} from "../src/tortoise/tortoiseDetector";
import type { TortoiseIntent } from "../src/tortoise/tortoiseLauncher";

describe("TortoiseCommandController", () => {
  it("blocks repository log launch in untrusted workspaces before detection or process spawn", async () => {
    const detector = fakeDetector(availableDetection());
    const launcher = vi.fn();
    const controller = commandController({
      detector,
      launcher,
      ui: fakeUi({ workspaceTrusted: false }),
    });

    await controller.openRepositoryLog();

    expect(detector.detect).not.toHaveBeenCalled();
    expect(launcher).not.toHaveBeenCalled();
    expect(controllerOptions(controller).ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR TortoiseSVN command failed: SUBVERSIONR_EXTERNAL_TOOL_UNTRUSTED_WORKSPACE",
    );
  });

  it("silently skips unavailable TortoiseSVN without launching while keeping repository sessions intact", async () => {
    const launcher = vi.fn();
    const ui = fakeUi();
    const controller = commandController({
      detector: fakeDetector({ status: "unavailable", reason: "notFound" }),
      launcher,
      ui,
    });

    await controller.openRepositoryLog();

    expect(launcher).not.toHaveBeenCalled();
    expect(ui.pickOpenRepository).not.toHaveBeenCalled();
    expect(ui.showWarningMessage).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).not.toHaveBeenCalled();
  });

  it("silently skips unavailable TortoiseSVN resource commands without launching", async () => {
    const launcher = vi.fn();
    const ui = fakeUi();
    const detector = fakeDetector({ status: "unavailable", reason: "notFound" });
    const controller = commandController({
      detector,
      launcher,
      ui,
    });

    await controller.diffResource(resourceState());

    expect(detector.detect).toHaveBeenCalledTimes(1);
    expect(launcher).not.toHaveBeenCalled();
    expect(ui.showWarningMessage).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).not.toHaveBeenCalled();
  });

  it("launches repository log with the selected working-copy root and configured Tortoise config directory", async () => {
    const launcher = vi.fn().mockResolvedValue(undefined);
    const detection = availableDetection({ configDirectory: "C:\\Users\\Alice\\AppData\\Roaming\\Subversion" });
    const controller = commandController({ detector: fakeDetector(detection), launcher });

    await controller.openRepositoryLog();

    expect(launcher).toHaveBeenCalledWith({
      executablePath: "C:\\Tools\\TortoiseSVN\\bin\\TortoiseProc.exe",
      intent: "log",
      path: "C:\\workspace",
      configDirectory: "C:\\Users\\Alice\\AppData\\Roaming\\Subversion",
    });
  });

  it("launches the repository browser with the selected working-copy root", async () => {
    const launcher = vi.fn().mockResolvedValue(undefined);
    const controller = commandController({ launcher });

    await controller.openRepositoryBrowser();

    expect(launcher).toHaveBeenCalledWith({
      executablePath: "C:\\Tools\\TortoiseSVN\\bin\\TortoiseProc.exe",
      intent: "repobrowser",
      path: "C:\\workspace",
      configDirectory: undefined,
    });
  });

  it.each([
    [
      "repository log",
      (controller: TortoiseCommandController, repositoryId: string) => controller.openRepositoryLog(repositoryId),
      "log",
    ],
    [
      "revision graph",
      (controller: TortoiseCommandController, repositoryId: string) =>
        controller.openRepositoryRevisionGraph(repositoryId),
      "revisiongraph",
    ],
    [
      "repository browser",
      (controller: TortoiseCommandController, repositoryId: string) =>
        controller.openRepositoryBrowser(repositoryId),
      "repobrowser",
    ],
  ])("launches %s for the SCM title repository without prompting", async (_label, invoke, intent) => {
    const first = repositorySession();
    const second = repositorySession({ repositoryId: "repo-uuid:D:/other", workingCopyRoot: "D:\\other" });
    const launcher = vi.fn().mockResolvedValue(undefined);
    const ui = fakeUi({ pickedSession: first });
    const controller = commandController({ sessions: [first, second], launcher, ui });

    await invoke(controller, "repo-uuid:D:/other");

    expect(ui.pickOpenRepository).not.toHaveBeenCalled();
    expect(launcher).toHaveBeenCalledWith(
      expect.objectContaining({
        intent,
        path: "D:\\other",
      }),
    );
  });

  it("launches resource diff only for a single open repository resource under the working-copy root", async () => {
    const launcher = vi.fn().mockResolvedValue(undefined);
    const controller = commandController({ launcher });

    await controller.diffResource({
      contextValue: "subversionr.changedFile.baseDiffable",
      resourceUri: { fsPath: "C:\\workspace\\src\\main.c" },
    });

    expect(launcher).toHaveBeenCalledWith({
      executablePath: "C:\\Tools\\TortoiseSVN\\bin\\TortoiseProc.exe",
      intent: "diff",
      path: "C:\\workspace\\src\\main.c",
      configDirectory: undefined,
    });
  });

  it("accepts file URI command arguments from editor context menus", async () => {
    const launcher = vi.fn().mockResolvedValue(undefined);
    const controller = commandController({ launcher });

    await controller.openResourceLog({ scheme: "file", fsPath: "C:\\workspace\\src\\main.c" });

    expect(launcher).toHaveBeenCalledWith(
      expect.objectContaining({
        intent: "log",
        path: "C:\\workspace\\src\\main.c",
      }),
    );
  });

  it.each([
    ["log", (controller: TortoiseCommandController) => controller.openResourceLog(resourceState())],
    ["diff", (controller: TortoiseCommandController) => controller.diffResource(resourceState())],
    ["blame", (controller: TortoiseCommandController) => controller.blameResource(resourceState())],
  ])("rejects %s resource launch targets outside open working copies", async (_label, invoke) => {
    const launcher = vi.fn();
    const ui = fakeUi();
    const controller = commandController({ launcher, ui });

    await invoke(
      controller,
    );

    expect(launcher).toHaveBeenCalledTimes(1);

    launcher.mockClear();
    await invoke(
      commandController({
        launcher,
        ui,
        sessions: [repositorySession({ workingCopyRoot: "D:\\other" })],
      }),
    );
    expect(launcher).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR TortoiseSVN command failed: SUBVERSIONR_TORTOISE_RESOURCE_OUTSIDE_REPOSITORY",
    );
  });

  it.each([
    [
      "log array",
      (controller: TortoiseCommandController) =>
        controller.openResourceLog([resourceState(), resourceState("C:\\workspace\\src\\other.c")]),
    ],
    [
      "log varargs",
      (controller: TortoiseCommandController) =>
        controller.openResourceLog(resourceState(), resourceState("C:\\workspace\\src\\other.c")),
    ],
    [
      "diff array",
      (controller: TortoiseCommandController) =>
        controller.diffResource([resourceState(), resourceState("C:\\workspace\\src\\other.c")]),
    ],
    [
      "diff varargs",
      (controller: TortoiseCommandController) =>
        controller.diffResource(resourceState(), resourceState("C:\\workspace\\src\\other.c")),
    ],
    [
      "blame array",
      (controller: TortoiseCommandController) =>
        controller.blameResource([resourceState(), resourceState("C:\\workspace\\src\\other.c")]),
    ],
    [
      "blame varargs",
      (controller: TortoiseCommandController) =>
        controller.blameResource(resourceState(), resourceState("C:\\workspace\\src\\other.c")),
    ],
  ])("rejects %s multi-select resource targets before detection or launch", async (_label, invoke) => {
    const detector = fakeDetector(availableDetection());
    const launcher = vi.fn();
    const ui = fakeUi();
    const controller = commandController({ detector, launcher, ui });

    await invoke(controller);

    expect(detector.detect).not.toHaveBeenCalled();
    expect(launcher).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR TortoiseSVN command failed: SUBVERSIONR_TORTOISE_RESOURCE_TARGET_INVALID",
    );
  });

  it("rejects dot-segment resource paths before detection or launch", async () => {
    const detector = fakeDetector(availableDetection());
    const launcher = vi.fn();
    const ui = fakeUi();
    const controller = commandController({ detector, launcher, ui });

    await controller.openResourceLog({ scheme: "file", fsPath: "C:\\workspace\\..\\outside\\file.c" });

    expect(detector.detect).not.toHaveBeenCalled();
    expect(launcher).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR TortoiseSVN command failed: SUBVERSIONR_TORTOISE_RESOURCE_PATH_INVALID",
    );
  });

  it("rejects .svn internal paths before launching TortoiseSVN", async () => {
    const detector = fakeDetector(availableDetection());
    const launcher = vi.fn();
    const ui = fakeUi();
    const controller = commandController({ detector, launcher, ui });

    await controller.openResourceLog({ scheme: "file", fsPath: "C:\\workspace\\.svn\\wc.db" });

    expect(detector.detect).not.toHaveBeenCalled();
    expect(launcher).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR TortoiseSVN command failed: SUBVERSIONR_TORTOISE_RESOURCE_INTERNAL_PATH",
    );
  });

  it("requires an explicit repository choice before opening revision graph with multiple sessions", async () => {
    const first = repositorySession();
    const second = repositorySession({ repositoryId: "repo-uuid:D:/other", workingCopyRoot: "D:\\other" });
    const launcher = vi.fn().mockResolvedValue(undefined);
    const ui = fakeUi({ pickedSession: second });
    const controller = commandController({ sessions: [first, second], launcher, ui });

    await controller.openRepositoryRevisionGraph();

    expect(ui.pickOpenRepository).toHaveBeenCalledWith([first, second]);
    expect(launcher).toHaveBeenCalledWith(
      expect.objectContaining({
        intent: "revisiongraph",
        path: "D:\\other",
      }),
    );
  });

  it("rejects unknown repository title targets before detection or launch", async () => {
    const detector = fakeDetector(availableDetection());
    const launcher = vi.fn();
    const ui = fakeUi();
    const controller = commandController({ detector, launcher, ui });

    await controller.openRepositoryLog("repo-uuid:D:/missing");

    expect(detector.detect).not.toHaveBeenCalled();
    expect(launcher).not.toHaveBeenCalled();
    expect(ui.pickOpenRepository).not.toHaveBeenCalled();
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "SubversionR TortoiseSVN command failed: SUBVERSIONR_TORTOISE_REPOSITORY_TARGET_INVALID",
    );
  });
});

function commandController(options: {
  detector?: { detect(): Promise<TortoiseDetectionResult> };
  launcher?: (request: {
    executablePath: string;
    intent: TortoiseIntent;
    path: string;
    configDirectory?: string;
  }) => Promise<void>;
  sessions?: RepositorySession[];
  ui?: FakeUi;
} = {}): TortoiseCommandController {
  return new TortoiseCommandController({
    detector: options.detector ?? fakeDetector(availableDetection()),
    launcher: options.launcher ?? vi.fn().mockResolvedValue(undefined),
    sessionService: fakeSessionService(options.sessions ?? [repositorySession()]),
    ui: options.ui ?? fakeUi(),
    localize,
  });
}

function controllerOptions(controller: TortoiseCommandController): { ui: FakeUi } {
  return (controller as unknown as { options: { ui: FakeUi } }).options;
}

function fakeDetector(result: TortoiseDetectionResult): { detect: ReturnType<typeof vi.fn<() => Promise<TortoiseDetectionResult>>> } {
  return {
    detect: vi.fn(async () => result),
  };
}

function availableDetection(overrides: Partial<Extract<TortoiseDetectionResult, { status: "available" }>> = {}): TortoiseDetectionResult {
  return {
    status: "available",
    executablePath: overrides.executablePath ?? "C:\\Tools\\TortoiseSVN\\bin\\TortoiseProc.exe",
    source: overrides.source ?? "configured",
    configDirectory: overrides.configDirectory,
  };
}

function fakeSessionService(sessions: RepositorySession[]): Pick<RepositorySessionService, "listOpenSessions"> {
  return {
    listOpenSessions: vi.fn(() => sessions),
  };
}

interface FakeUi {
  workspaceTrusted: ReturnType<typeof vi.fn<() => boolean>>;
  pickOpenRepository: ReturnType<typeof vi.fn<(sessions: RepositorySession[]) => Promise<RepositorySession | undefined>>>;
  showWarningMessage: ReturnType<typeof vi.fn<(message: string) => Promise<void>>>;
  showErrorMessage: ReturnType<typeof vi.fn<(message: string) => Promise<void>>>;
}

function fakeUi(options: { workspaceTrusted?: boolean; pickedSession?: RepositorySession } = {}): FakeUi {
  return {
    workspaceTrusted: vi.fn(() => options.workspaceTrusted ?? true),
    pickOpenRepository: vi.fn(async () => options.pickedSession),
    showWarningMessage: vi.fn(async () => undefined),
    showErrorMessage: vi.fn(async () => undefined),
  };
}

function repositorySession(
  overrides: Partial<{ repositoryId: string; workingCopyRoot: string }> = {},
): RepositorySession {
  const repositoryId = overrides.repositoryId ?? "repo-uuid:C:/workspace";
  const workingCopyRoot = overrides.workingCopyRoot ?? "C:\\workspace";
  return {
    repositoryId,
    epoch: 7,
    identity: {
      repositoryUuid: "repo-uuid",
      repositoryRootUrl: "file:///C:/repo",
      workingCopyRoot,
      workspaceScopeRoot: workingCopyRoot,
      format: 31,
    },
    watchScope: {
      repositoryId,
      epoch: 7,
      workingCopyRoot,
      pathCase: "case-insensitive",
    },
  };
}

function resourceState(
  fsPath = "C:\\workspace\\src\\main.c",
): { contextValue: string; resourceUri: { fsPath: string } } {
  return {
    contextValue: "subversionr.changedFile.baseDiffable",
    resourceUri: { fsPath },
  };
}

function localize(message: string, ...args: unknown[]): string {
  return args.reduce<string>((current, arg, index) => current.replace(`{${index}}`, String(arg)), message);
}
