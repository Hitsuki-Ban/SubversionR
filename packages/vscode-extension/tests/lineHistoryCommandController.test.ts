import { Buffer } from "node:buffer";
import { describe, expect, it, vi } from "vitest";
import { LineHistoryCommandController } from "../src/history/lineHistoryCommandController";
import type { HistoryBlame, HistoryBlameClient, HistoryBlameRequest } from "../src/history/historyBlameRpcClient";
import type { HistoryClient as HistoryLogClient, HistoryLog, HistoryLogRequest } from "../src/history/historyLogRpcClient";
import type { HistoryViewTarget } from "../src/history/historyViewTarget";
import type { LensSettings } from "../src/lens/lensSettings";
import type { RepositorySession, RepositorySessionService } from "../src/repository/repositorySessionService";
import type { SourceControlProjectionService } from "../src/scm/sourceControlProjectionService";
import type {
  ScmProjectedResource,
  ScmProjectedResourceLookup,
  ScmRepositoryProjection,
} from "../src/scm/sourceControlResourceStore";
import type { StatusEntry } from "../src/status/statusSnapshotRpcClient";

describe("LineHistoryCommandController", () => {
  it("opens preloaded line history for a safe active editor selection", async () => {
    const historyClient = fakeHistoryClient(
      blameResponse({
        lineStart: 3,
        lineLimit: 3,
        lines: [
          blameLine(3, 4),
          blameLine(4, 9),
          blameLine(5, 4),
        ],
      }),
      logResponse(9, "newer line edit"),
      logResponse(4, "older line edit"),
    );
    const ui = fakeUi({
      editor: activeEditor("C:\\workspace\\SRC\\MAIN.C", {
        selection: selection(2, 4),
      }),
    });
    const controller = lineHistoryController({ historyClient, ui });

    await controller.showLineHistory();

    expect(historyClient.getBlame).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: "src/main.c",
      pegRevision: "base",
      startRevision: "r0",
      endRevision: "base",
      lineStart: 3,
      lineLimit: 3,
      ignoreWhitespace: "none",
      ignoreEolStyle: false,
      ignoreMimeType: false,
      includeMergedRevisions: false,
    });
    expect(historyClient.getLog).toHaveBeenNthCalledWith(1, {
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: "src/main.c",
      startRevision: "r9",
      endRevision: "r9",
      limit: 1,
      discoverChangedPaths: false,
      strictNodeHistory: false,
      includeMergedRevisions: false,
    });
    expect(historyClient.getLog).toHaveBeenNthCalledWith(2, {
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: "src/main.c",
      startRevision: "r4",
      endRevision: "r4",
      limit: 1,
      discoverChangedPaths: false,
      strictNodeHistory: false,
      includeMergedRevisions: false,
    });
    expect(ui.showLineHistory).toHaveBeenCalledWith(
      {
        kind: "line",
        repositoryId: "repo-uuid:C:/workspace",
        epoch: 7,
        path: "src/main.c",
        label: "src/main.c:3-5",
        lineStart: 3,
        lineEnd: 5,
      },
      [
        expect.objectContaining({ revision: 9, message: "newer line edit" }),
        expect.objectContaining({ revision: 4, message: "older line edit" }),
      ],
    );
    expect(ui.showErrorMessage).not.toHaveBeenCalled();
  });

  it("records failures and offers the redacted log without blocking on the notification", async () => {
    const rawCode = "SUBVERSIONR_NATIVE_SECRET_FAILURE";
    const failure = Object.assign(new Error("sensitive backend detail"), { code: rawCode });
    const historyClient = fakeHistoryClient(blameResponse({ lineStart: 1, lineLimit: 1 }), logResponse(4));
    historyClient.getBlame.mockRejectedValueOnce(failure);
    const ui = fakeUi({ errorSelection: "l10n:Show Log" });
    const diagnostics = fakeDiagnostics();
    const controller = lineHistoryController({ historyClient, ui, diagnostics });

    await controller.showLineHistory();

    expect(diagnostics.recordFailure).toHaveBeenCalledWith("Line History", failure);
    expect(ui.showErrorMessage).toHaveBeenCalledWith(
      "l10n:SVN l10n:History failed. Open the SubversionR log for details.",
      "l10n:Show Log",
    );
    expect(ui.showErrorMessage.mock.calls[0]?.[0]).not.toContain(rawCode);
    await vi.waitFor(() => expect(diagnostics.show).toHaveBeenCalledOnce());
  });

  it("opens line history for a safe active editor file from an SVN changelist group", async () => {
    const historyClient = fakeHistoryClient(
      blameResponse({
        lineStart: 2,
        lineLimit: 1,
        lines: [blameLine(2, 6)],
      }),
      logResponse(6, "reviewed line"),
    );
    const ui = fakeUi({
      editor: activeEditor("C:\\workspace\\SRC\\REVIEW.C", {
        selection: selection(1, 1),
      }),
    });
    const controller = lineHistoryController({
      historyClient,
      ui,
      projections: new Map([
        [
          "repo-uuid:C:/workspace",
          scmProjection({
            resources: [
              scmProjectedResource(
                {
                  path: "src/review.c",
                  changelist: "review",
                  localStatus: "normal",
                  textStatus: "normal",
                  propertyStatus: "normal",
                },
                {
                  groupId: "changelist:review",
                },
              ),
            ],
          }),
        ],
      ]),
    });

    await controller.showLineHistory();

    expect(historyClient.getBlame).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: "src/review.c",
      pegRevision: "base",
      startRevision: "r0",
      endRevision: "base",
      lineStart: 2,
      lineLimit: 1,
      ignoreWhitespace: "none",
      ignoreEolStyle: false,
      ignoreMimeType: false,
      includeMergedRevisions: false,
    });
    expect(historyClient.getLog).toHaveBeenCalledWith({
      repositoryId: "repo-uuid:C:/workspace",
      epoch: 7,
      path: "src/review.c",
      startRevision: "r6",
      endRevision: "r6",
      limit: 1,
      discoverChangedPaths: false,
      strictNodeHistory: false,
      includeMergedRevisions: false,
    });
    expect(ui.showLineHistory).toHaveBeenCalledWith(
      expect.objectContaining({
        kind: "line",
        repositoryId: "repo-uuid:C:/workspace",
        epoch: 7,
        path: "src/review.c",
        label: "src/review.c:2",
        lineStart: 2,
        lineEnd: 2,
      }),
      [expect.objectContaining({ revision: 6, message: "reviewed line" })],
    );
    expect(ui.showErrorMessage).not.toHaveBeenCalled();
  });

  it("opens line history for a text-stable property-only active file", async () => {
    const historyClient = fakeHistoryClient(blameResponse({ lineStart: 1, lineLimit: 1 }), logResponse(4));
    const controller = lineHistoryController({
      historyClient,
      projections: new Map([
        [
          "repo-uuid:C:/workspace",
          scmProjection({
            resources: [
              scmProjectedResource({
                localStatus: "modified",
                nodeStatus: "modified",
                textStatus: "normal",
                propertyStatus: "modified",
              }),
            ],
          }),
        ],
      ]),
    });

    await controller.showLineHistory();

    expect(historyClient.getBlame).toHaveBeenCalledTimes(1);
  });

  it("uses the current line for an empty selection and normalizes reversed selections", async () => {
    const historyClient = fakeHistoryClient(
      blameResponse({
        lineStart: 5,
        lineLimit: 4,
        lines: [
          blameLine(5, 8),
          blameLine(6, 7),
          blameLine(7, 7),
          blameLine(8, 5),
        ],
      }),
      logResponse(8),
      logResponse(7),
      logResponse(5),
    );
    const ui = fakeUi({
      editor: activeEditor("C:\\workspace\\src\\main.c", {
        selection: selection(7, 4),
      }),
    });
    const controller = lineHistoryController({ historyClient, ui });

    await controller.showLineHistory();

    expect(historyClient.getBlame).toHaveBeenCalledWith(expect.objectContaining({ lineStart: 5, lineLimit: 4 }));
    expect(historyClient.getLog.mock.calls.map(([request]) => request.startRevision)).toEqual(["r8", "r7", "r5"]);
    expect(ui.showLineHistory).toHaveBeenCalledWith(
      expect.objectContaining({ label: "src/main.c:5-8", lineStart: 5, lineEnd: 8 }),
      expect.any(Array),
    );
  });

  it("includes merged revisions in line blame and revision log requests when history settings enable them", async () => {
    const historyClient = fakeHistoryClient(
      blameResponse({
        lineStart: 1,
        lineLimit: 1,
        lines: [blameLine(1, 8)],
      }),
      logResponse(8, "merged line edit"),
    );
    const controller = lineHistoryController({ historyClient, includeMergedRevisions: true });

    await controller.showLineHistory();

    expect(historyClient.getBlame).toHaveBeenCalledWith(
      expect.objectContaining({ includeMergedRevisions: true }),
    );
    expect(historyClient.getLog).toHaveBeenCalledWith(
      expect.objectContaining({ includeMergedRevisions: true }),
    );
  });

  it("blocks line history in untrusted workspaces before blame or log side effects", async () => {
    const historyClient = fakeHistoryClient(blameResponse({ lineStart: 1, lineLimit: 1 }), logResponse(4));
    const ui = fakeUi({
      editor: activeEditor("C:\\workspace\\src\\main.c"),
    });
    const controller = lineHistoryController({ historyClient, ui, workspaceTrusted: false });

    await controller.showLineHistory();

    expect(historyClient.getBlame).not.toHaveBeenCalled();
    expect(historyClient.getLog).not.toHaveBeenCalled();
    expect(ui.showLineHistory).not.toHaveBeenCalled();
    expectLineHistoryFailure(ui);
  });

  it.each([
    ["missing active editor", undefined, scmProjectedResource()],
    ["non-file document", activeEditor("C:\\workspace\\src\\main.c", { scheme: "untitled" }), scmProjectedResource()],
    ["dirty document", activeEditor("C:\\workspace\\src\\main.c", { isDirty: true }), scmProjectedResource()],
    ["oversized document", activeEditor("C:\\workspace\\src\\main.c", { lineCount: 20001 }), scmProjectedResource()],
    ["text-modified resource", activeEditor("C:\\workspace\\src\\main.c"), scmProjectedResource({ textStatus: "modified" })],
    ["added resource", activeEditor("C:\\workspace\\src\\main.c"), scmProjectedResource({ localStatus: "added", nodeStatus: "normal", textStatus: "normal" })],
    ["conflicted resource", activeEditor("C:\\workspace\\src\\main.c"), scmProjectedResource({ localStatus: "conflicted", nodeStatus: "normal", textStatus: "normal" })],
    ["unversioned resource", activeEditor("C:\\workspace\\src\\main.c"), scmProjectedResource({ localStatus: "unversioned", nodeStatus: "normal", textStatus: "normal" })],
    ["deleted resource", activeEditor("C:\\workspace\\src\\main.c"), scmProjectedResource({ localStatus: "deleted", nodeStatus: "deleted", textStatus: "normal" })],
    ["missing resource", activeEditor("C:\\workspace\\src\\main.c"), scmProjectedResource({ localStatus: "missing", nodeStatus: "missing", textStatus: "normal" })],
    ["replaced resource", activeEditor("C:\\workspace\\src\\main.c"), scmProjectedResource({ localStatus: "replaced", nodeStatus: "normal", textStatus: "normal" })],
    ["obstructed resource", activeEditor("C:\\workspace\\src\\main.c"), scmProjectedResource({ localStatus: "obstructed", nodeStatus: "normal", textStatus: "normal" })],
    ["incomplete resource", activeEditor("C:\\workspace\\src\\main.c"), scmProjectedResource({ localStatus: "incomplete", nodeStatus: "normal", textStatus: "normal" })],
    ["deleted node status", activeEditor("C:\\workspace\\src\\main.c"), scmProjectedResource({ nodeStatus: "deleted", textStatus: "normal" })],
    ["missing text status", activeEditor("C:\\workspace\\src\\main.c"), scmProjectedResource({ nodeStatus: "normal", textStatus: "missing" })],
    ["external resource", activeEditor("C:\\workspace\\src\\main.c"), scmProjectedResource({ external: true })],
    ["ignored resource", activeEditor("C:\\workspace\\src\\main.c"), scmProjectedResource({ localStatus: "ignored" })],
    ["remote resource", activeEditor("C:\\workspace\\src\\main.c"), scmProjectedResource({}, { source: "remote" })],
    ["conflicts group resource", activeEditor("C:\\workspace\\src\\main.c"), scmProjectedResource({}, { groupId: "conflicts" })],
    ["base-diffable context resource", activeEditor("C:\\workspace\\src\\main.c"), scmProjectedResource({}, { contextValue: "subversionr.changedFile.baseDiffable" })],
    ["directory resource", activeEditor("C:\\workspace\\src\\main.c"), scmProjectedResource({ kind: "dir" })],
  ])("does not query history for unsafe line-history target: %s", async (_label, editor, resource) => {
    const historyClient = fakeHistoryClient(blameResponse({ lineStart: 1, lineLimit: 1 }), logResponse(4));
    const ui = fakeUi({ editor });
    const controller = lineHistoryController({
      historyClient,
      ui,
      projections: new Map([["repo-uuid:C:/workspace", scmProjection({ resources: [resource] })]]),
    });

    await controller.showLineHistory();

    expect(historyClient.getBlame).not.toHaveBeenCalled();
    expect(historyClient.getLog).not.toHaveBeenCalled();
    expect(ui.showLineHistory).not.toHaveBeenCalled();
    expectLineHistoryFailure(ui);
  });

  it("does not query history when line history is disabled", async () => {
    const historyClient = fakeHistoryClient(blameResponse({ lineStart: 1, lineLimit: 1 }), logResponse(4));
    const ui = fakeUi();
    const controller = lineHistoryController({
      historyClient,
      ui,
      settings: lensSettings({ enabled: false }),
    });

    await controller.showLineHistory();

    expect(historyClient.getBlame).not.toHaveBeenCalled();
    expect(historyClient.getLog).not.toHaveBeenCalled();
    expect(ui.showLineHistory).not.toHaveBeenCalled();
    expectLineHistoryFailure(ui);
  });

  it("does not query line history from a stale projection", async () => {
    const projection = scmProjection();
    projection.freshness = {
      repositoryCompleteness: "stale",
      lastRefreshCompleteness: "stale",
      lastRefreshKind: "stale",
    };
    const historyClient = fakeHistoryClient(blameResponse({ lineStart: 1, lineLimit: 1 }), logResponse(4));
    const ui = fakeUi();
    const controller = lineHistoryController({
      historyClient,
      ui,
      projections: new Map([[projection.repositoryId, projection]]),
    });

    await controller.showLineHistory();

    expect(historyClient.getBlame).not.toHaveBeenCalled();
    expect(historyClient.getLog).not.toHaveBeenCalled();
    expect(ui.showLineHistory).not.toHaveBeenCalled();
    expectLineHistoryFailure(ui);
  });

  it("does not fall back to a parent repository when a nested working copy projection is missing", async () => {
    const parent = repositorySession();
    const child = repositorySession({
      repositoryId: "repo-child:C:/workspace/vendor",
      workingCopyRoot: "C:\\workspace\\vendor",
    });
    const parentProjection = scmProjection({
      resources: [scmProjectedResource({ path: "vendor/src/main.c" })],
    });
    const getProjectedResource = vi.fn((repositoryId: string) => {
      if (repositoryId !== parent.repositoryId) {
        return undefined;
      }
      const resource = parentProjection.groups.flatMap((group) => group.resources)[0]!;
      return lookup(parentProjection, resource);
    });
    const historyClient = fakeHistoryClient(blameResponse({ lineStart: 1, lineLimit: 1 }), logResponse(4));
    const ui = fakeUi({ editor: activeEditor("C:\\workspace\\vendor\\src\\main.c") });
    const controller = lineHistoryController({
      historyClient,
      ui,
      sessions: [parent, child],
      sourceControlProjection: {
        getProjection: vi.fn(() => undefined),
        getProjectedResource,
      },
    });

    await controller.showLineHistory();

    expect(getProjectedResource).toHaveBeenCalledTimes(1);
    expect(getProjectedResource).toHaveBeenCalledWith(
      child.repositoryId,
      "src/main.c",
      "case-insensitive",
    );
    expect(historyClient.getBlame).not.toHaveBeenCalled();
    expect(ui.showLineHistory).not.toHaveBeenCalled();
    expectLineHistoryFailure(ui);
  });

  it.each([
    ["negative line", activeEditor("C:\\workspace\\src\\main.c", { selection: selection(-1, 0) })],
    ["past end line", activeEditor("C:\\workspace\\src\\main.c", { lineCount: 20, selection: selection(0, 20) })],
    ["over line window cap", activeEditor("C:\\workspace\\src\\main.c", { lineCount: 5001, selection: selection(0, 5000) })],
  ])("does not query history for invalid selection: %s", async (_label, editor) => {
    const historyClient = fakeHistoryClient(blameResponse({ lineStart: 1, lineLimit: 1 }), logResponse(4));
    const ui = fakeUi({ editor });
    const controller = lineHistoryController({ historyClient, ui });

    await controller.showLineHistory();

    expect(historyClient.getBlame).not.toHaveBeenCalled();
    expect(historyClient.getLog).not.toHaveBeenCalled();
    expect(ui.showLineHistory).not.toHaveBeenCalled();
    expectLineHistoryFailure(ui);
  });

  it("does not show partial line history when blame rows are local, unknown, incomplete, or non-contiguous", async () => {
    for (const { blame, editor } of [
      {
        blame: blameResponse({ lineStart: 1, lineLimit: 1, lines: [blameLine(1, 4, { localChange: true })] }),
        editor: activeEditor("C:\\workspace\\src\\main.c"),
      },
      {
        blame: blameResponse({ lineStart: 1, lineLimit: 1, lines: [blameLine(1, null)] }),
        editor: activeEditor("C:\\workspace\\src\\main.c"),
      },
      {
        blame: blameResponse({ lineStart: 1, lineLimit: 2, lines: [blameLine(1, 4)] }),
        editor: activeEditor("C:\\workspace\\src\\main.c", { selection: selection(0, 1) }),
      },
      {
        blame: blameResponse({ lineStart: 1, lineLimit: 2, lines: [blameLine(1, 4), blameLine(3, 5)] }),
        editor: activeEditor("C:\\workspace\\src\\main.c", { selection: selection(0, 1) }),
      },
    ]) {
      const historyClient = fakeHistoryClient(blame, logResponse(4));
      const ui = fakeUi({ editor });
      const controller = lineHistoryController({ historyClient, ui });

      await controller.showLineHistory();

      expect(historyClient.getLog).not.toHaveBeenCalled();
      expect(ui.showLineHistory).not.toHaveBeenCalled();
      expectLineHistoryFailure(ui);
    }
  });

  it("does not show partial line history when any single-revision log lookup is missing or mismatched", async () => {
    for (const log of [
      logResponse(4, "missing", []),
      logResponse(5, "mismatch"),
    ]) {
      const historyClient = fakeHistoryClient(
        blameResponse({ lineStart: 1, lineLimit: 1, lines: [blameLine(1, 4)] }),
        log,
      );
      const ui = fakeUi();
      const controller = lineHistoryController({ historyClient, ui });

      await controller.showLineHistory();

      expect(ui.showLineHistory).not.toHaveBeenCalled();
      expectLineHistoryFailure(ui);
    }
  });

  it("fails before log fanout when the selected lines exceed the unique revision cap", async () => {
    const lines = Array.from({ length: 501 }, (_value, index) => blameLine(index + 1, index + 1));
    const historyClient = fakeHistoryClient(
      blameResponse({
        lineStart: 1,
        lineLimit: lines.length,
        lines,
      }),
    );
    const ui = fakeUi({
      editor: activeEditor("C:\\workspace\\src\\main.c", {
        lineCount: lines.length,
        selection: selection(0, lines.length - 1),
      }),
    });
    const controller = lineHistoryController({ historyClient, ui });

    await controller.showLineHistory();

    expect(historyClient.getLog).not.toHaveBeenCalled();
    expect(ui.showLineHistory).not.toHaveBeenCalled();
    expectLineHistoryFailure(ui);
  });
});

function lineHistoryController(options: {
  settings?: LensSettings;
  historyClient?: HistoryBlameClient & HistoryLogClient;
  ui?: FakeUi;
  sessions?: RepositorySession[];
  projections?: Map<string, ScmRepositoryProjection | undefined>;
  sourceControlProjection?: Pick<SourceControlProjectionService, "getProjectedResource" | "getProjection">;
  includeMergedRevisions?: boolean;
  workspaceTrusted?: boolean;
  diagnostics?: FakeDiagnostics;
} = {}): LineHistoryCommandController {
  const projections = options.projections ?? new Map([["repo-uuid:C:/workspace", scmProjection()]]);
  return new LineHistoryCommandController({
    settings: () => options.settings ?? lensSettings(),
    includeMergedRevisions: () => options.includeMergedRevisions ?? false,
    historyClient: options.historyClient ?? fakeHistoryClient(blameResponse({ lineStart: 1, lineLimit: 1 }), logResponse(4)),
    sessionService: fakeSessionService(options.sessions ?? [repositorySession()]),
    sourceControlProjection: options.sourceControlProjection ?? fakeSourceControlProjection(projections),
    workspaceTrusted: () => options.workspaceTrusted ?? true,
    diagnostics: options.diagnostics ?? fakeDiagnostics(),
    ui: options.ui ?? fakeUi(),
    localize: localizeForTest,
  });
}

function fakeHistoryClient(
  blame: HistoryBlame,
  ...logs: HistoryLog[]
): HistoryBlameClient & HistoryLogClient & {
  getBlame: ReturnType<typeof vi.fn<(request: HistoryBlameRequest) => Promise<HistoryBlame>>>;
  getLog: ReturnType<typeof vi.fn<(request: HistoryLogRequest) => Promise<HistoryLog>>>;
} {
  const pendingLogs = [...logs];
  return {
    getBlame: vi.fn(async () => blame),
    getLog: vi.fn(async () => {
      const response = pendingLogs.shift();
      if (!response) {
        throw new Error("missing log response");
      }
      return response;
    }),
  };
}

function fakeUi(options: { editor?: LineHistoryActiveEditor; errorSelection?: unknown } = {}): FakeUi {
  return {
    activeTextEditor: vi.fn(() => ("editor" in options ? options.editor : activeEditor("C:\\workspace\\src\\main.c"))),
    showLineHistory: vi.fn(async () => undefined),
    showErrorMessage: vi.fn(async () => options.errorSelection),
  };
}

function fakeDiagnostics(): FakeDiagnostics {
  return {
    recordFailure: vi.fn(),
    show: vi.fn(),
  };
}

function expectLineHistoryFailure(ui: FakeUi): void {
  expect(ui.showErrorMessage).toHaveBeenCalledWith(
    "l10n:SVN l10n:History failed. Open the SubversionR log for details.",
    "l10n:Show Log",
  );
}

function fakeSessionService(sessions: RepositorySession[]): Pick<RepositorySessionService, "listOpenSessions"> {
  return {
    listOpenSessions: () => sessions,
  };
}

function fakeSourceControlProjection(
  projections: Map<string, ScmRepositoryProjection | undefined>,
): Pick<SourceControlProjectionService, "getProjectedResource" | "getProjection"> {
  return {
    getProjection: (repositoryId) => projections.get(repositoryId),
    getProjectedResource: (repositoryId, path, pathCase) => {
      const projection = projections.get(repositoryId);
      if (!projection) {
        return undefined;
      }
      const resource = projection.groups
        .flatMap((group) => group.resources)
        .find((candidate) => comparisonKey(pathCase, candidate.path) === comparisonKey(pathCase, path));
      return resource ? lookup(projection, resource) : undefined;
    },
  };
}

function lookup(projection: ScmRepositoryProjection, resource: ScmProjectedResource): ScmProjectedResourceLookup {
  return {
    repositoryId: projection.repositoryId,
    epoch: projection.epoch,
    workingCopyRoot: projection.workingCopyRoot,
    generation: projection.generation,
    resource,
  };
}

function comparisonKey(pathCase: "case-sensitive" | "case-insensitive", path: string): string {
  return pathCase === "case-insensitive" ? path.toLocaleLowerCase("en-US") : path;
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

function scmProjection(options: {
  repositoryId?: string;
  workingCopyRoot?: string;
  resources?: ScmProjectedResource[];
} = {}): ScmRepositoryProjection {
  return {
    repositoryId: options.repositoryId ?? "repo-uuid:C:/workspace",
    epoch: 7,
    workingCopyRoot: options.workingCopyRoot ?? "C:/workspace",
    generation: 11,
    count: 1,
    freshness: {
      repositoryCompleteness: "complete",
      lastRefreshCompleteness: "complete",
      lastRefreshKind: "snapshot",
    },
    groups: [
      { id: "conflicts", labelKey: "scm.group.conflicts", changelist: null, resources: [] },
      { id: "changes", labelKey: "scm.group.changes", changelist: null, resources: options.resources ?? [scmProjectedResource()] },
      { id: "unversioned", labelKey: "scm.group.unversioned", changelist: null, resources: [] },
      { id: "incoming", labelKey: "scm.group.incoming", changelist: null, resources: [] },
      { id: "externals", labelKey: "scm.group.externals", changelist: null, resources: [] },
      { id: "ignored", labelKey: "scm.group.ignored", changelist: null, resources: [] },
    ],
  };
}

function scmProjectedResource(
  overrides: Partial<StatusEntry> = {},
  projectionOverrides: Partial<Pick<ScmProjectedResource, "source" | "groupId" | "contextValue">> = {},
): ScmProjectedResource {
  const entry = statusEntry(overrides);
  return {
    key: `${projectionOverrides.source ?? "local"}:${entry.path}`,
    repositoryId: "repo-uuid:C:/workspace",
    path: entry.path,
    source: projectionOverrides.source ?? "local",
    groupId: projectionOverrides.groupId ?? "changes",
    contextValue: projectionOverrides.contextValue ?? "subversionr.changedFile",
    tooltipKey: "scm.resource.changed",
    entry,
  };
}

function statusEntry(overrides: Partial<StatusEntry> = {}): StatusEntry {
  return {
    path: overrides.path ?? "src/main.c",
    kind: overrides.kind ?? "file",
    nodeStatus: overrides.nodeStatus ?? "normal",
    textStatus: overrides.textStatus ?? "normal",
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
    conflictArtifacts: overrides.conflictArtifacts ?? [],
    external: overrides.external ?? false,
    generation: overrides.generation ?? 11,
  };
}

function lensSettings(overrides: Partial<LensSettings> = {}): LensSettings {
  return {
    enabled: true,
    fileHeader: true,
    currentLine: true,
    hover: true,
    symbols: false,
    maxFileLines: 20000,
    ...overrides,
  };
}

function activeEditor(
  fsPath: string,
  options: {
    scheme?: string;
    lineCount?: number;
    isDirty?: boolean;
    selection?: LineHistorySelection;
  } = {},
): LineHistoryActiveEditor {
  return {
    document: {
      uri: {
        scheme: options.scheme ?? "file",
        fsPath,
      },
      lineCount: options.lineCount ?? 20,
      isDirty: options.isDirty ?? false,
    },
    selection: options.selection ?? selection(0, 0),
  };
}

function selection(startLine: number, endLine: number): LineHistorySelection {
  return {
    start: { line: startLine },
    end: { line: endLine },
  };
}

function blameResponse(options: {
  lineStart: number;
  lineLimit: number;
  path?: string;
  lines?: HistoryBlame["lines"];
}): HistoryBlame {
  return {
    repositoryId: "repo-uuid:C:/workspace",
    epoch: 7,
    path: options.path ?? "src/main.c",
    pegRevision: "base",
    startRevision: "r0" as HistoryBlame["startRevision"],
    endRevision: "base",
    resolvedStartRevision: 1,
    resolvedEndRevision: 9,
    lineStart: options.lineStart,
    lineLimit: options.lineLimit,
    ignoreWhitespace: "none",
    ignoreEolStyle: false,
    ignoreMimeType: false,
    includeMergedRevisions: false,
    hasMore: false,
    lines: options.lines ?? [blameLine(options.lineStart, 4)],
    source: "libsvn-blame",
  };
}

function blameLine(
  lineNumber: number,
  revision: number | null,
  overrides: Partial<HistoryBlame["lines"][number]> = {},
): HistoryBlame["lines"][number] {
  const line = Buffer.from("test", "utf8");
  return {
    lineNumber,
    revision,
    author: "alice",
    date: "2026-06-22T00:00:00.000000Z",
    mergedRevision: null,
    mergedAuthor: null,
    mergedDate: null,
    mergedPath: null,
    lineBase64: line.toString("base64"),
    byteLength: line.byteLength,
    localChange: false,
    ...overrides,
  };
}

function logResponse(
  revision: number,
  message = "line edit",
  entries?: HistoryLog["entries"],
): HistoryLog {
  return {
    repositoryId: "repo-uuid:C:/workspace",
    epoch: 7,
    path: "src/main.c",
    startRevision: `r${revision}` as HistoryLog["startRevision"],
    endRevision: `r${revision}` as HistoryLog["endRevision"],
    limit: 1,
    entries: entries ?? [
      {
        revision,
        author: "alice",
        date: "2026-06-22T00:00:00.000000Z",
        message,
        changedPaths: [],
        hasChildren: false,
        nonInheritable: false,
        subtractiveMerge: false,
      },
    ],
    source: "libsvn-log",
  };
}

function localizeForTest(message: string, ...args: unknown[]): string {
  return `l10n:${args.reduce<string>((current, arg, index) => current.replace(`{${index}}`, String(arg)), message)}`;
}

interface LineHistoryActiveEditor {
  document: {
    uri: {
      scheme: string;
      fsPath: string;
    };
    lineCount: number;
    isDirty: boolean;
  };
  selection: LineHistorySelection;
}

interface LineHistorySelection {
  start: {
    line: number;
  };
  end: {
    line: number;
  };
}

interface FakeUi {
  activeTextEditor: ReturnType<typeof vi.fn<() => LineHistoryActiveEditor | undefined>>;
  showLineHistory: ReturnType<
    typeof vi.fn<(target: HistoryViewTarget, entries: HistoryLog["entries"]) => Promise<void>>
  >;
  showErrorMessage: ReturnType<typeof vi.fn<(message: string, ...actions: string[]) => Promise<unknown>>>;
}

interface FakeDiagnostics {
  recordFailure: ReturnType<typeof vi.fn<(operation: string, error: unknown) => void>>;
  show: ReturnType<typeof vi.fn<() => void>>;
}
