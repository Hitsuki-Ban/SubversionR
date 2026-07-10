import * as nodePath from "node:path";
import { describe, expect, it, vi } from "vitest";
import {
  VscodeSourceControlPresenter,
  type VscodeSourceControlPresenterApi,
  type VscodeSourceControlQuickDiffProvider,
  type VscodeSourceControlResourceState,
} from "../src/scm/vscodeSourceControlPresenter";
import type { ScmRepositoryProjection } from "../src/scm/sourceControlResourceStore";
import type { StatusEntry } from "../src/status/statusSnapshotRpcClient";

describe("VscodeSourceControlPresenter", () => {
  it("creates fixed SCM groups and assigns projected resource states", () => {
    const api = fakeVscodeScmApi();
    const presenter = new VscodeSourceControlPresenter(api);

    presenter.registerRepository({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      workingCopyRoot: "C:/wc",
    });
    presenter.updateRepository(projection());

    expect(api.createSourceControl).toHaveBeenCalledWith(
      "svn-r",
      "SubversionR",
      { fsPath: "C:/wc" },
      "repo-uuid:C:/wc",
    );
    expect(api.createdGroups.map((group) => group.id)).toEqual([
      "conflicts",
      "changes",
      "unversioned",
      "incoming",
      "externals",
      "ignored",
    ]);
    expect(api.createdGroups.map((group) => group.label)).toEqual([
      "l10n:Conflicts",
      "l10n:Changes",
      "l10n:Unversioned",
      "l10n:Incoming",
      "l10n:Externals",
      "l10n:Ignored",
    ]);
    expect(api.sourceControl.inputBox.placeholder).toBe("l10n:SVN commit message");
    expect(api.sourceControl.acceptInputCommand).toEqual({
      command: "subversionr.commitAll",
      title: "l10n:Commit",
      arguments: ["repo-uuid:C:/wc"],
    });
    expect(api.group("changes").resourceStates).toEqual([
      {
        resourceUri: { fsPath: nodePath.join("C:/wc", "src", "main.c") },
        contextValue: "subversionr.changedFile.baseDiffable",
        subversionrResourceKind: "file",
        subversionrProjectionGeneration: 11,
        decorations: {
          tooltip:
            "l10n:SVN local change\n" +
            "l10n:SVN changed revision: r7\n" +
            "l10n:SVN changed author: alice\n" +
            "l10n:SVN changed date: 2026-06-22T00:00:00Z",
        },
      },
    ]);
    expect(api.sourceControl.count).toBe(1);
  });

  it("omits changed metadata tooltip lines when SVN changed revision is unknown", () => {
    const api = fakeVscodeScmApi();
    const presenter = new VscodeSourceControlPresenter(api);

    presenter.registerRepository({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      workingCopyRoot: "C:/wc",
    });
    presenter.updateRepository(
      {
        ...projection(),
        groups: [
          { id: "conflicts", labelKey: "scm.group.conflicts", changelist: null, resources: [] },
          {
            id: "changes",
            labelKey: "scm.group.changes",
            changelist: null,
            resources: [
              projectedResource(
                "local",
                "changes",
                "subversionr.changedFile",
                statusEntry("src/unknown.c", "modified", {
                  changedRevision: -1,
                  changedAuthor: null,
                  changedDate: null,
                }),
              ),
            ],
          },
          { id: "unversioned", labelKey: "scm.group.unversioned", changelist: null, resources: [] },
          { id: "incoming", labelKey: "scm.group.incoming", changelist: null, resources: [] },
          { id: "externals", labelKey: "scm.group.externals", changelist: null, resources: [] },
          { id: "ignored", labelKey: "scm.group.ignored", changelist: null, resources: [] },
        ],
      },
    );

    expect(api.group("changes").resourceStates[0]).toMatchObject({
      decorations: {
        tooltip: "l10n:SVN local change",
      },
    });
  });

  it("shows SVN changed metadata in incoming resource tooltips", () => {
    const api = fakeVscodeScmApi();
    const presenter = new VscodeSourceControlPresenter(api);

    presenter.registerRepository({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      workingCopyRoot: "C:/wc",
    });
    presenter.updateRepository(
      {
        ...projection(),
        groups: [
          { id: "conflicts", labelKey: "scm.group.conflicts", changelist: null, resources: [] },
          { id: "changes", labelKey: "scm.group.changes", changelist: null, resources: [] },
          { id: "unversioned", labelKey: "scm.group.unversioned", changelist: null, resources: [] },
          {
            id: "incoming",
            labelKey: "scm.group.incoming",
            changelist: null,
            resources: [
              projectedResource("remote", "incoming", "subversionr.incoming", statusEntry("incoming.txt", "normal"), {
                tooltipKey: "scm.resource.incoming",
              }),
            ],
          },
          { id: "externals", labelKey: "scm.group.externals", changelist: null, resources: [] },
          { id: "ignored", labelKey: "scm.group.ignored", changelist: null, resources: [] },
        ],
      },
    );

    expect(api.group("incoming").resourceStates[0]).toMatchObject({
      decorations: {
        tooltip:
          "l10n:SVN incoming change\n" +
          "l10n:SVN changed revision: r7\n" +
          "l10n:SVN changed author: alice\n" +
          "l10n:SVN changed date: 2026-06-22T00:00:00Z",
      },
    });
  });

  it("omits incoming changed metadata tooltip lines when SVN changed revision is unknown", () => {
    const api = fakeVscodeScmApi();
    const presenter = new VscodeSourceControlPresenter(api);

    presenter.registerRepository({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      workingCopyRoot: "C:/wc",
    });
    presenter.updateRepository(
      {
        ...projection(),
        groups: [
          { id: "conflicts", labelKey: "scm.group.conflicts", changelist: null, resources: [] },
          { id: "changes", labelKey: "scm.group.changes", changelist: null, resources: [] },
          { id: "unversioned", labelKey: "scm.group.unversioned", changelist: null, resources: [] },
          {
            id: "incoming",
            labelKey: "scm.group.incoming",
            changelist: null,
            resources: [
              projectedResource(
                "remote",
                "incoming",
                "subversionr.incoming",
                statusEntry("unknown-incoming.txt", "normal", {
                  changedRevision: -1,
                  changedAuthor: null,
                  changedDate: null,
                }),
                { tooltipKey: "scm.resource.incoming" },
              ),
            ],
          },
          { id: "externals", labelKey: "scm.group.externals", changelist: null, resources: [] },
          { id: "ignored", labelKey: "scm.group.ignored", changelist: null, resources: [] },
        ],
      },
    );

    expect(api.group("incoming").resourceStates[0]).toMatchObject({
      decorations: {
        tooltip: "l10n:SVN incoming change",
      },
    });
  });

  it("creates and disposes dynamic SVN changelist groups from projected state", () => {
    const api = fakeVscodeScmApi();
    const presenter = new VscodeSourceControlPresenter(api);

    presenter.registerRepository({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      workingCopyRoot: "C:/wc",
    });
    presenter.updateRepository(projectionWithChangelist());

    expect(api.group("changelist:review").label).toBe("l10n:Changelist: review");
    expect(api.group("changelist:review")).toMatchObject({
      contextValue: "subversionr.changelist",
      hideWhenEmpty: true,
      subversionrRepositoryId: "repo-uuid:C:/wc",
      subversionrChangelistName: "review",
    });
    expect(api.group("changelist:review").resourceStates).toEqual([
      expect.objectContaining({
        resourceUri: { fsPath: nodePath.join("C:/wc", "src", "review.c") },
        contextValue: "subversionr.changedFile.baseDiffable.changelisted",
        subversionrResourceKind: "file",
        subversionrProjectionGeneration: 11,
      }),
    ]);
    expect(presenter.snapshotRepository("repo-uuid:C:/wc")?.groups.map((group) => group.id)).toEqual([
      "conflicts",
      "changelist:review",
      "changes",
      "unversioned",
      "incoming",
      "externals",
      "ignored",
    ]);

    presenter.updateRepository(projection());

    expect(api.group("changelist:review").dispose).toHaveBeenCalledTimes(1);
    expect(presenter.snapshotRepository("repo-uuid:C:/wc")?.groups.map((group) => group.id)).toEqual([
      "conflicts",
      "changes",
      "unversioned",
      "incoming",
      "externals",
      "ignored",
    ]);
  });

  it("adds locked SCM context suffix after base-diffable and changelist context", () => {
    const api = fakeVscodeScmApi();
    const presenter = new VscodeSourceControlPresenter(api);

    presenter.registerRepository({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      workingCopyRoot: "C:/wc",
    });
    presenter.updateRepository(projectionWithLockedResources());

    expect(api.group("changes").resourceStates.map((resource) => resource.contextValue)).toEqual([
      "subversionr.changedFile.baseDiffable.locked",
    ]);
    expect(api.group("changelist:review").resourceStates.map((resource) => resource.contextValue)).toEqual([
      "subversionr.changedFile.baseDiffable.changelisted.locked",
    ]);
  });

  it("returns a release diagnostics snapshot of SourceControl groups and resources", () => {
    const api = fakeVscodeScmApi();
    const presenter = new VscodeSourceControlPresenter(api);

    presenter.registerRepository({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      workingCopyRoot: "C:/wc",
    });
    presenter.updateRepository(projection());

    expect(presenter.snapshotRepository("repo-uuid:C:/wc")).toEqual({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      workingCopyRoot: "C:/wc",
      generation: 11,
      freshness: {
        repositoryCompleteness: "complete",
        lastRefreshCompleteness: "complete",
        lastRefreshKind: "snapshot",
      },
      count: 1,
      statusBarCommands: undefined,
      inputBox: {
        placeholder: "l10n:SVN commit message",
        acceptInputCommand: "subversionr.commitAll",
        acceptInputCommandArguments: ["repo-uuid:C:/wc"],
      },
      groups: [
        { id: "conflicts", contextValue: "subversionr.conflicts", hideWhenEmpty: true, count: 0, resources: [] },
        {
          id: "changes",
          contextValue: "subversionr.changes",
          hideWhenEmpty: true,
          count: 1,
          resources: [
            {
              path: "src/main.c",
              contextValue: "subversionr.changedFile.baseDiffable",
              kind: "file",
              generation: 11,
            },
          ],
        },
        { id: "unversioned", contextValue: "subversionr.unversioned", hideWhenEmpty: true, count: 0, resources: [] },
        { id: "incoming", contextValue: "subversionr.incoming", hideWhenEmpty: true, count: 0, resources: [] },
        { id: "externals", contextValue: "subversionr.externals", hideWhenEmpty: true, count: 0, resources: [] },
        { id: "ignored", contextValue: "subversionr.ignored", hideWhenEmpty: true, count: 0, resources: [] },
      ],
    });
  });

  it("snapshots a working copy root property-only resource as the repository root path", () => {
    const api = fakeVscodeScmApi();
    const presenter = new VscodeSourceControlPresenter(api);
    const rootPropertyEntry = statusEntry(".", "normal", {
      kind: "dir",
      propertyStatus: "modified",
    });
    const rootPropertyProjection = {
      ...projection(),
      count: 1,
      groups: [
        { id: "conflicts", labelKey: "scm.group.conflicts", changelist: null, resources: [] },
        {
          id: "changes",
          labelKey: "scm.group.changes",
          changelist: null,
          resources: [
            projectedResource("local", "changes", "subversionr.changedDirectory", rootPropertyEntry, {
              tooltipKey: "scm.resource.changed",
            }),
          ],
        },
        { id: "unversioned", labelKey: "scm.group.unversioned", changelist: null, resources: [] },
        { id: "incoming", labelKey: "scm.group.incoming", changelist: null, resources: [] },
        { id: "externals", labelKey: "scm.group.externals", changelist: null, resources: [] },
        { id: "ignored", labelKey: "scm.group.ignored", changelist: null, resources: [] },
      ],
    } satisfies ScmRepositoryProjection;

    presenter.registerRepository({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      workingCopyRoot: "C:/wc",
    });
    presenter.updateRepository(rootPropertyProjection);

    expect(presenter.snapshotRepository("repo-uuid:C:/wc")?.groups.find((group) => group.id === "changes")?.resources).toEqual([
      {
        path: ".",
        contextValue: "subversionr.changedDirectory",
        kind: "dir",
        generation: 11,
      },
    ]);
  });

  it("sets a SourceControl status bar command when repository freshness is partial or stale", () => {
    const api = fakeVscodeScmApi();
    const presenter = new VscodeSourceControlPresenter(api);

    presenter.registerRepository({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      workingCopyRoot: "C:/wc",
    });

    presenter.updateRepository(
      projection({
        freshness: {
          repositoryCompleteness: "partial",
          lastRefreshCompleteness: "partial",
          lastRefreshKind: "snapshot",
        },
      }),
    );

    expect(api.sourceControl.statusBarCommands).toEqual([
      {
        command: "subversionr.fullReconcile",
        title: "l10n:SVN status partial",
        arguments: ["repo-uuid:C:/wc"],
      },
    ]);
    expect(presenter.snapshotRepository("repo-uuid:C:/wc")).toMatchObject({
      statusBarCommands: [
        {
          command: "subversionr.fullReconcile",
          title: "l10n:SVN status partial",
          arguments: ["repo-uuid:C:/wc"],
        },
      ],
    });

    presenter.updateRepository(
      projection({
        freshness: {
          repositoryCompleteness: "stale",
          lastRefreshCompleteness: "stale",
          lastRefreshKind: "snapshot",
        },
      }),
    );

    expect(api.sourceControl.statusBarCommands).toEqual([
      {
        command: "subversionr.fullReconcile",
        title: "l10n:SVN status stale",
        arguments: ["repo-uuid:C:/wc"],
      },
    ]);
    expect(presenter.snapshotRepository("repo-uuid:C:/wc")).toMatchObject({
      statusBarCommands: [
        {
          command: "subversionr.fullReconcile",
          title: "l10n:SVN status stale",
          arguments: ["repo-uuid:C:/wc"],
        },
      ],
    });
  });

  it("clears the SourceControl status bar freshness command when repository state is complete", () => {
    const api = fakeVscodeScmApi();
    const presenter = new VscodeSourceControlPresenter(api);

    presenter.registerRepository({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      workingCopyRoot: "C:/wc",
    });

    presenter.updateRepository(
      projection({
        freshness: {
          repositoryCompleteness: "partial",
          lastRefreshCompleteness: "partial",
          lastRefreshKind: "snapshot",
        },
      }),
    );
    presenter.updateRepository(projection());

    expect(api.sourceControl.statusBarCommands).toBeUndefined();
  });

  it("does not return a SourceControl snapshot for an unregistered repository", () => {
    const presenter = new VscodeSourceControlPresenter(fakeVscodeScmApi());

    expect(presenter.snapshotRepository("repo-uuid:C:/missing")).toBeUndefined();
  });

  it("keeps resource refresh on the context menu without assigning a default resource command", () => {
    const api = fakeVscodeScmApi();
    const presenter = new VscodeSourceControlPresenter(api);

    presenter.registerRepository({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      workingCopyRoot: "C:/wc",
    });
    presenter.updateRepository(projection());

    expect(api.group("changes").resourceStates[0]).toMatchObject({
      contextValue: "subversionr.changedFile.baseDiffable",
      subversionrResourceKind: "file",
      subversionrProjectionGeneration: 11,
    });
    expect(api.group("changes").resourceStates[0]).not.toHaveProperty("command");
  });

  it("adds switched and sparse depth metadata to SourceControl resource tooltips", () => {
    const api = fakeVscodeScmApi();
    const presenter = new VscodeSourceControlPresenter(api);

    presenter.registerRepository({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      workingCopyRoot: "C:/wc",
    });
    presenter.updateRepository(projectionWithWorkingCopyMetadata());

    expect(api.group("changes").resourceStates).toEqual([
      expect.objectContaining({
        contextValue: "subversionr.workingCopyMetadata",
        decorations: {
          tooltip: "l10n:SVN working copy metadata\nl10n:SVN switched node\nl10n:SVN sparse depth: files",
        },
      }),
      expect.objectContaining({
        contextValue: "subversionr.changedFile.baseDiffable",
        decorations: {
          tooltip:
            "l10n:SVN local change\n" +
            "l10n:SVN changed revision: r7\n" +
            "l10n:SVN changed author: alice\n" +
            "l10n:SVN changed date: 2026-06-22T00:00:00Z\n" +
            "l10n:SVN switched node\n" +
            "l10n:SVN sparse depth: empty",
        },
      }),
    ]);
  });

  it("uses file-specific working copy metadata contexts for lockable metadata resources", () => {
    const api = fakeVscodeScmApi();
    const presenter = new VscodeSourceControlPresenter(api);

    presenter.registerRepository({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      workingCopyRoot: "C:/wc",
    });
    presenter.updateRepository(
      {
        ...projection(),
        groups: [
          { id: "conflicts", labelKey: "scm.group.conflicts", changelist: null, resources: [] },
          {
            id: "changes",
            labelKey: "scm.group.changes",
            changelist: null,
            resources: [
              projectedResource(
                "local",
                "changes",
                "subversionr.workingCopyMetadata",
                statusEntry("src/needs-lock.c", "normal", { needsLock: true }),
                { tooltipKey: "scm.resource.workingCopyMetadata" },
              ),
              projectedResource(
                "local",
                "changes",
                "subversionr.workingCopyMetadata",
                statusEntry("src/locked.c", "normal", {
                  lock: {
                    token: "opaquelocktoken:1",
                    owner: "alice",
                    comment: null,
                    createdDate: null,
                    expiresDate: null,
                    isRemote: false,
                  },
                }),
                { tooltipKey: "scm.resource.workingCopyMetadata" },
              ),
              projectedResource(
                "local",
                "changes",
                "subversionr.workingCopyMetadata",
                statusEntry("branches/feature", "normal", { kind: "dir", switched: true }),
                { tooltipKey: "scm.resource.workingCopyMetadata" },
              ),
            ],
          },
          { id: "unversioned", labelKey: "scm.group.unversioned", changelist: null, resources: [] },
          { id: "incoming", labelKey: "scm.group.incoming", changelist: null, resources: [] },
          { id: "externals", labelKey: "scm.group.externals", changelist: null, resources: [] },
          { id: "ignored", labelKey: "scm.group.ignored", changelist: null, resources: [] },
        ],
      },
    );

    expect(api.group("changes").resourceStates.map((resource) => resource.contextValue)).toEqual([
      "subversionr.workingCopyMetadataFile",
      "subversionr.workingCopyMetadataFile.locked",
      "subversionr.workingCopyMetadata",
    ]);
  });

  it("does not append locked suffixes to non-lock-aware SCM resource contexts", () => {
    const api = fakeVscodeScmApi();
    const presenter = new VscodeSourceControlPresenter(api);
    const lock = {
      token: "opaquelocktoken:1",
      owner: "alice",
      comment: null,
      createdDate: null,
      expiresDate: null,
      isRemote: false,
    };

    presenter.registerRepository({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      workingCopyRoot: "C:/wc",
    });
    presenter.updateRepository(
      {
        ...projection(),
        groups: [
          { id: "conflicts", labelKey: "scm.group.conflicts", changelist: null, resources: [] },
          {
            id: "changes",
            labelKey: "scm.group.changes",
            changelist: null,
            resources: [
              projectedResource(
                "local",
                "changes",
                "subversionr.changedDirectory",
                statusEntry("src", "modified", { kind: "dir", lock }),
              ),
              projectedResource(
                "local",
                "changes",
                "subversionr.changedFile",
                statusEntry("src/locked.c", "modified", { lock }),
              ),
            ],
          },
          {
            id: "unversioned",
            labelKey: "scm.group.unversioned",
            changelist: null,
            resources: [
              projectedResource(
                "local",
                "unversioned",
                "subversionr.unversioned",
                statusEntry("scratch.txt", "unversioned", { lock }),
              ),
            ],
          },
          {
            id: "incoming",
            labelKey: "scm.group.incoming",
            changelist: null,
            resources: [
              projectedResource(
                "remote",
                "incoming",
                "subversionr.incomingFile",
                statusEntry("incoming.txt", "normal", { lock }),
                {
                  tooltipKey: "scm.resource.incoming",
                },
              ),
            ],
          },
          {
            id: "externals",
            labelKey: "scm.group.externals",
            changelist: null,
            resources: [
              projectedResource(
                "local",
                "externals",
                "subversionr.external",
                statusEntry("external.txt", "normal", { external: true, lock }),
                {
                  tooltipKey: "scm.resource.external",
                },
              ),
            ],
          },
          {
            id: "ignored",
            labelKey: "scm.group.ignored",
            changelist: null,
            resources: [
              projectedResource(
                "local",
                "ignored",
                "subversionr.ignored",
                statusEntry("ignored.txt", "ignored", { lock }),
                {
                  tooltipKey: "scm.resource.ignored",
                },
              ),
            ],
          },
        ],
      },
    );

    expect(api.group("changes").resourceStates.map((resource) => resource.contextValue)).toEqual([
      "subversionr.changedDirectory",
      "subversionr.changedFile.baseDiffable.locked",
    ]);
    expect(api.group("unversioned").resourceStates[0].contextValue).toBe("subversionr.unversioned");
    expect(api.group("incoming").resourceStates[0].contextValue).toBe("subversionr.incomingFile.locked");
    expect(api.group("externals").resourceStates[0].contextValue).toBe("subversionr.external");
    expect(api.group("ignored").resourceStates[0].contextValue).toBe("subversionr.ignored");
  });

  it("adds structured SVN lock owner, comment, timestamps, and token to SourceControl resource tooltips", () => {
    const api = fakeVscodeScmApi();
    const presenter = new VscodeSourceControlPresenter(api);

    presenter.registerRepository({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      workingCopyRoot: "C:/wc",
    });
    presenter.updateRepository(
      {
        ...projection(),
        groups: [
          { id: "conflicts", labelKey: "scm.group.conflicts", changelist: null, resources: [] },
          {
            id: "changes",
            labelKey: "scm.group.changes",
            changelist: null,
            resources: [
              projectedResource(
                "local",
                "changes",
                "subversionr.workingCopyMetadata",
                statusEntry("src/locked.c", "normal", {
                  lock: {
                    token: "opaquelocktoken:1",
                    owner: "alice",
                    comment: "editing",
                    createdDate: "2026-06-25T00:00:00Z",
                    expiresDate: "2026-06-26T00:00:00Z",
                    isRemote: false,
                  },
                }),
                { tooltipKey: "scm.resource.workingCopyMetadata" },
              ),
            ],
          },
          { id: "unversioned", labelKey: "scm.group.unversioned", changelist: null, resources: [] },
          { id: "incoming", labelKey: "scm.group.incoming", changelist: null, resources: [] },
          { id: "externals", labelKey: "scm.group.externals", changelist: null, resources: [] },
          { id: "ignored", labelKey: "scm.group.ignored", changelist: null, resources: [] },
        ],
      },
    );

    const resourceState = api.group("changes").resourceStates[0];
    expect(resourceState).toBeDefined();
    expect(resourceState).toMatchObject({
      decorations: {
        tooltip:
          "l10n:SVN working copy metadata\n" +
          "l10n:SVN lock owner: alice\n" +
          "l10n:SVN lock comment: editing\n" +
          "l10n:SVN lock created: 2026-06-25T00:00:00Z\n" +
          "l10n:SVN lock expires: 2026-06-26T00:00:00Z\n" +
          "l10n:SVN lock token: opaquelocktoken:1",
      },
    });
  });

  it("adds remote SVN lock state to SourceControl resource tooltips", () => {
    const api = fakeVscodeScmApi();
    const presenter = new VscodeSourceControlPresenter(api);

    presenter.registerRepository({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      workingCopyRoot: "C:/wc",
    });
    presenter.updateRepository(
      {
        ...projection(),
        groups: [
          { id: "conflicts", labelKey: "scm.group.conflicts", changelist: null, resources: [] },
          {
            id: "changes",
            labelKey: "scm.group.changes",
            changelist: null,
            resources: [
              projectedResource(
                "local",
                "changes",
                "subversionr.workingCopyMetadata",
                statusEntry("src/remote-lock.c", "normal", {
                  lock: {
                    token: "opaquelocktoken:remote",
                    owner: "bob",
                    comment: "remote edit",
                    createdDate: "2026-06-25T00:00:00Z",
                    expiresDate: null,
                    isRemote: true,
                  },
                }),
                { tooltipKey: "scm.resource.workingCopyMetadata" },
              ),
            ],
          },
          { id: "unversioned", labelKey: "scm.group.unversioned", changelist: null, resources: [] },
          { id: "incoming", labelKey: "scm.group.incoming", changelist: null, resources: [] },
          { id: "externals", labelKey: "scm.group.externals", changelist: null, resources: [] },
          { id: "ignored", labelKey: "scm.group.ignored", changelist: null, resources: [] },
        ],
      },
    );

    expect(api.group("changes").resourceStates[0]).toMatchObject({
      decorations: {
        tooltip:
          "l10n:SVN working copy metadata\n" +
          "l10n:SVN remote lock\n" +
          "l10n:SVN lock owner: bob\n" +
          "l10n:SVN lock comment: remote edit\n" +
          "l10n:SVN lock created: 2026-06-25T00:00:00Z\n" +
          "l10n:SVN lock token: opaquelocktoken:remote",
      },
    });
  });

  it("adds SVN copy and move metadata to SourceControl resource tooltips", () => {
    const api = fakeVscodeScmApi();
    const presenter = new VscodeSourceControlPresenter(api);

    presenter.registerRepository({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      workingCopyRoot: "C:/wc",
    });
    presenter.updateRepository(
      {
        ...projection(),
        groups: [
          { id: "conflicts", labelKey: "scm.group.conflicts", changelist: null, resources: [] },
          {
            id: "changes",
            labelKey: "scm.group.changes",
            changelist: null,
            resources: [
              projectedResource(
                "local",
                "changes",
                "subversionr.changedFile",
                statusEntry("src/copied.c", "added", { copy: "branches/stable/src/copied.c@42" }),
              ),
              projectedResource(
                "local",
                "changes",
                "subversionr.changedFile",
                statusEntry("src/moved.c", "added", { move: "src/old.c" }),
              ),
            ],
          },
          { id: "unversioned", labelKey: "scm.group.unversioned", changelist: null, resources: [] },
          { id: "incoming", labelKey: "scm.group.incoming", changelist: null, resources: [] },
          { id: "externals", labelKey: "scm.group.externals", changelist: null, resources: [] },
          { id: "ignored", labelKey: "scm.group.ignored", changelist: null, resources: [] },
        ],
      },
    );

    expect(api.group("changes").resourceStates).toEqual([
      expect.objectContaining({
        decorations: {
          tooltip:
            "l10n:SVN local change\n" +
            "l10n:SVN changed revision: r7\n" +
            "l10n:SVN changed author: alice\n" +
            "l10n:SVN changed date: 2026-06-22T00:00:00Z\n" +
            "l10n:SVN copy from: branches/stable/src/copied.c@42",
        },
      }),
      expect.objectContaining({
        decorations: {
          tooltip:
            "l10n:SVN local change\n" +
            "l10n:SVN changed revision: r7\n" +
            "l10n:SVN changed author: alice\n" +
            "l10n:SVN changed date: 2026-06-22T00:00:00Z\n" +
            "l10n:SVN move from: src/old.c",
        },
      }),
    ]);
  });

  it("keeps unsupported changed files on the non-diffable changed-file context", () => {
    const api = fakeVscodeScmApi();
    const presenter = new VscodeSourceControlPresenter(api);

    presenter.registerRepository({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      workingCopyRoot: "C:/wc",
    });
    presenter.updateRepository(projectionWithUnsupportedChangedFiles());

    expect(api.group("changes").resourceStates.map((resource) => resource.contextValue)).toEqual([
      "subversionr.changedFile",
      "subversionr.changedFile",
      "subversionr.changedFile",
      "subversionr.changedFile",
      "subversionr.changedFile",
      "subversionr.changedFile",
    ]);

    const quickDiffProvider = api.sourceControl.quickDiffProvider;
    for (const resource of api.group("changes").resourceStates) {
      expect(quickDiffProvider?.provideOriginalResource(resource.resourceUri)).toBeUndefined();
    }
  });

  it("reads, sets, and clears the repository SourceControl input box for commit commands", () => {
    const api = fakeVscodeScmApi();
    const presenter = new VscodeSourceControlPresenter(api);

    presenter.registerRepository({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      workingCopyRoot: "C:/wc",
    });

    api.sourceControl.inputBox.value = "commit tracked file";

    expect(presenter.commitMessage("repo-uuid:C:/wc")).toBe("commit tracked file");

    presenter.setCommitMessage("repo-uuid:C:/wc", "commit all tracked files");

    expect(api.sourceControl.inputBox.value).toBe("commit all tracked files");

    presenter.clearCommitMessage("repo-uuid:C:/wc");

    expect(api.sourceControl.inputBox.value).toBe("");
  });

  it("hides the SourceControl accept input command in untrusted workspaces", () => {
    const api = fakeVscodeScmApi({ workspaceTrusted: false });
    const presenter = new VscodeSourceControlPresenter(api);

    presenter.registerRepository({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      workingCopyRoot: "C:/wc",
    });

    expect(api.sourceControl.inputBox.placeholder).toBe("l10n:Trust this workspace to commit SVN changes");
    expect(api.sourceControl.acceptInputCommand).toBeUndefined();
  });

  it("refreshes the SourceControl commit affordance when workspace trust changes", () => {
    const api = fakeVscodeScmApi({ workspaceTrusted: false });
    const presenter = new VscodeSourceControlPresenter(api);

    presenter.registerRepository({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      workingCopyRoot: "C:/wc",
    });

    api.setWorkspaceTrusted(true);
    presenter.refreshWorkspaceTrust();

    expect(api.sourceControl.inputBox.placeholder).toBe("l10n:SVN commit message");
    expect(api.sourceControl.acceptInputCommand).toEqual({
      command: "subversionr.commitAll",
      title: "l10n:Commit",
      arguments: ["repo-uuid:C:/wc"],
    });

    api.setWorkspaceTrusted(false);
    presenter.refreshWorkspaceTrust();

    expect(api.sourceControl.inputBox.placeholder).toBe("l10n:Trust this workspace to commit SVN changes");
    expect(api.sourceControl.acceptInputCommand).toBeUndefined();
  });

  it("fails fast when commit input is requested for an unregistered repository", () => {
    const api = fakeVscodeScmApi();
    const presenter = new VscodeSourceControlPresenter(api);

    expect(() => presenter.commitMessage("repo-uuid:C:/missing")).toThrow(
      "Source control repository is not registered: repo-uuid:C:/missing",
    );
    expect(() => presenter.setCommitMessage("repo-uuid:C:/missing", "commit all tracked files")).toThrow(
      "Source control repository is not registered: repo-uuid:C:/missing",
    );
    expect(() => presenter.clearCommitMessage("repo-uuid:C:/missing")).toThrow(
      "Source control repository is not registered: repo-uuid:C:/missing",
    );
  });

  it("provides BASE virtual document URIs for QuickDiff without scanning repository state", () => {
    const api = fakeVscodeScmApi();
    const presenter = new VscodeSourceControlPresenter(api);

    presenter.registerRepository({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      workingCopyRoot: "C:/wc",
    });
    presenter.updateRepository(projection());

    const quickDiffProvider = api.sourceControl.quickDiffProvider;
    expect(quickDiffProvider).toBeDefined();
    expect(quickDiffProvider?.provideOriginalResource({ fsPath: nodePath.join("C:/wc", "src", "main.c") })).toEqual({
      scheme: "svn-r-base",
      authority: "base",
      path: "/",
      query:
        "repositoryId=repo-uuid%3AC%3A%2Fwc&epoch=7&generation=11&path=src%2Fmain.c&revision=base",
    });
    expect(quickDiffProvider?.provideOriginalResource({ fsPath: "C:/outside/main.c" })).toBeUndefined();
    expect(quickDiffProvider?.provideOriginalResource({ fsPath: "C:/wc" })).toBeUndefined();
  });

  it("does not provide QuickDiff originals for unversioned ignored external or remote resources", () => {
    const api = fakeVscodeScmApi();
    const presenter = new VscodeSourceControlPresenter(api);

    presenter.registerRepository({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      workingCopyRoot: "C:/wc",
    });
    presenter.updateRepository(projectionWithNonBaseResources());

    const quickDiffProvider = api.sourceControl.quickDiffProvider;
    expect(quickDiffProvider?.provideOriginalResource({ fsPath: "C:/wc/scratch.txt" })).toBeUndefined();
    expect(quickDiffProvider?.provideOriginalResource({ fsPath: "C:/wc/ignored.txt" })).toBeUndefined();
    expect(quickDiffProvider?.provideOriginalResource({ fsPath: "C:/wc/external.txt" })).toBeUndefined();
    expect(quickDiffProvider?.provideOriginalResource({ fsPath: "C:/wc/incoming.txt" })).toBeUndefined();
  });

  it("does not provide QuickDiff originals for conflicted ignored or external files", () => {
    const api = fakeVscodeScmApi();
    const presenter = new VscodeSourceControlPresenter(api);

    presenter.registerRepository({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      workingCopyRoot: "C:/wc",
    });
    presenter.updateRepository(projectionWithConflictedIgnoredAndExternal());

    const quickDiffProvider = api.sourceControl.quickDiffProvider;
    expect(quickDiffProvider?.provideOriginalResource({ fsPath: "C:/wc/conflicted-external.txt" })).toBeUndefined();
    expect(quickDiffProvider?.provideOriginalResource({ fsPath: "C:/wc/conflicted-ignored.txt" })).toBeUndefined();
  });

  it("disposes all resource groups and the source control on unregister", () => {
    const api = fakeVscodeScmApi();
    const presenter = new VscodeSourceControlPresenter(api);

    presenter.registerRepository({
      repositoryId: "repo-uuid:C:/wc",
      epoch: 7,
      workingCopyRoot: "C:/wc",
    });
    presenter.unregisterRepository("repo-uuid:C:/wc");

    expect(api.sourceControl.dispose).toHaveBeenCalledTimes(1);
    expect(api.createdGroups.map((group) => group.dispose)).toSatisfy(
      (disposers: Array<ReturnType<typeof vi.fn<() => void>>>) =>
        disposers.every((dispose) => dispose.mock.calls.length === 1),
    );
  });

  it("disposes partially created SCM resources when group registration fails", () => {
    const api = fakeVscodeScmApi();
    api.sourceControl.createResourceGroup.mockImplementation((id: string, label: string) => {
      if (id === "changes") {
        throw new Error("group registration failed");
      }
      return api.createGroup(id, label);
    });
    const presenter = new VscodeSourceControlPresenter(api);

    expect(() =>
      presenter.registerRepository({
        repositoryId: "repo-uuid:C:/wc",
        epoch: 7,
        workingCopyRoot: "C:/wc",
      }),
    ).toThrow("group registration failed");

    expect(api.group("conflicts").dispose).toHaveBeenCalledTimes(1);
    expect(api.sourceControl.dispose).toHaveBeenCalledTimes(1);
    expect(api.createdGroups.map((group) => group.id)).toEqual(["conflicts"]);
  });
});

function fakeVscodeScmApi(options: { workspaceTrusted?: boolean } = {}): VscodeSourceControlPresenterApi & {
  sourceControl: {
    count: number | undefined;
    quickDiffProvider: VscodeSourceControlQuickDiffProvider | undefined;
    statusBarCommands:
      | Array<{
          command: string;
          title: string;
          arguments?: unknown[];
        }>
      | undefined;
    acceptInputCommand: {
      command: string;
      title: string;
      arguments?: unknown[];
    } | undefined;
    inputBox: {
      placeholder: string;
      value: string;
    };
    dispose: ReturnType<typeof vi.fn<() => void>>;
    createResourceGroup: ReturnType<typeof vi.fn<(id: string, label: string) => FakeResourceGroup>>;
  };
  readonly createdGroups: FakeResourceGroup[];
  createGroup(id: string, label: string): FakeResourceGroup;
  group(id: string): FakeResourceGroup;
  setWorkspaceTrusted(value: boolean): void;
} {
  let workspaceTrusted = options.workspaceTrusted ?? true;
  const groups = new Map<string, FakeResourceGroup>();
  const createGroup = (id: string, label: string): FakeResourceGroup => {
    const group: FakeResourceGroup = {
      id,
      label,
      contextValue: undefined,
      hideWhenEmpty: undefined,
      subversionrRepositoryId: undefined,
      subversionrChangelistName: undefined,
      resourceStates: [],
      dispose: vi.fn<() => void>(),
    };
    groups.set(id, group);
    return group;
  };
  const sourceControl = {
    count: undefined as number | undefined,
    quickDiffProvider: undefined as VscodeSourceControlQuickDiffProvider | undefined,
    statusBarCommands: undefined as
      | Array<{
          command: string;
          title: string;
          arguments?: unknown[];
        }>
      | undefined,
    acceptInputCommand: undefined as { command: string; title: string; arguments?: unknown[] } | undefined,
    inputBox: {
      placeholder: "",
      value: "",
    },
    dispose: vi.fn<() => void>(),
    createResourceGroup: vi.fn(createGroup),
  };
  return {
    sourceControl,
    get createdGroups() {
      return Array.from(groups.values());
    },
    createGroup,
    createSourceControl: vi.fn(() => sourceControl),
    uriFromComponents: (components) => components,
    uriFile: (fsPath: string) => ({ fsPath }),
    uriFsPath: (uri: unknown) => (isUriWithFsPath(uri) ? uri.fsPath : undefined),
    workspaceTrusted: () => workspaceTrusted,
    localize: (message: string, ...args: unknown[]) =>
      `l10n:${args.reduce<string>((current, arg, index) => current.replace(`{${index}}`, String(arg)), message)}`,
    setWorkspaceTrusted: (value: boolean) => {
      workspaceTrusted = value;
    },
    group: (id: string) => {
      const group = groups.get(id);
      if (!group) {
        throw new Error(`Missing group: ${id}`);
      }
      return group;
    },
  };
}

function isUriWithFsPath(uri: unknown): uri is { fsPath: string } {
  return typeof uri === "object" && uri !== null && typeof (uri as { fsPath?: unknown }).fsPath === "string";
}

interface FakeResourceGroup {
  id: string;
  label: string;
  contextValue: string | undefined;
  hideWhenEmpty: boolean | undefined;
  subversionrRepositoryId: string | undefined;
  subversionrChangelistName: string | undefined;
  resourceStates: VscodeSourceControlResourceState[];
  dispose: ReturnType<typeof vi.fn<() => void>>;
}

function projection(
  overrides: Partial<Pick<ScmRepositoryProjection, "freshness">> = {},
): ScmRepositoryProjection {
  return {
    repositoryId: "repo-uuid:C:/wc",
    epoch: 7,
    workingCopyRoot: "C:/wc",
    generation: 11,
    freshness: overrides.freshness ?? {
      repositoryCompleteness: "complete",
      lastRefreshCompleteness: "complete",
      lastRefreshKind: "snapshot",
    },
    count: 1,
    groups: [
      { id: "conflicts", labelKey: "scm.group.conflicts", changelist: null, resources: [] },
      {
        id: "changes",
        labelKey: "scm.group.changes",
        changelist: null,
        resources: [
          {
            key: "local:src/main.c",
            repositoryId: "repo-uuid:C:/wc",
            path: "src/main.c",
            source: "local",
            groupId: "changes",
            contextValue: "subversionr.changedFile",
            tooltipKey: "scm.resource.changed",
            entry: {
              path: "src/main.c",
              kind: "file",
              nodeStatus: "modified",
              textStatus: "modified",
              propertyStatus: "normal",
              localStatus: "modified",
              remoteStatus: "notChecked",
              revision: 7,
              changedRevision: 7,
              changedAuthor: "alice",
              changedDate: "2026-06-22T00:00:00Z",
              changelist: null,
              lock: null,
              needsLock: false,
              copy: null,
              move: null,
              switched: false,
              depth: "infinity",
              conflict: null,
              external: false,
              generation: 11,
            },
          },
        ],
      },
      { id: "unversioned", labelKey: "scm.group.unversioned", changelist: null, resources: [] },
      { id: "incoming", labelKey: "scm.group.incoming", changelist: null, resources: [] },
      { id: "externals", labelKey: "scm.group.externals", changelist: null, resources: [] },
      { id: "ignored", labelKey: "scm.group.ignored", changelist: null, resources: [] },
    ],
  };
}

function projectionWithLockedResources(): ScmRepositoryProjection {
  const base = projection();
  const lock = {
    token: "opaquelocktoken:1",
    owner: "alice",
    comment: "editing",
    createdDate: "2026-06-25T00:00:00Z",
    expiresDate: null,
    isRemote: false,
  };
  const lockedEntry = statusEntry("src/main.c", "modified", { lock });
  const lockedReviewEntry = statusEntry("src/review.c", "modified", { changelist: "review", lock });
  return {
    ...base,
    count: 2,
    groups: [
      { id: "conflicts", labelKey: "scm.group.conflicts", changelist: null, resources: [] },
      {
        id: "changelist:review",
        labelKey: "scm.group.changelist",
        changelist: "review",
        resources: [projectedResource("local", "changelist:review", "subversionr.changedFile", lockedReviewEntry)],
      },
      {
        id: "changes",
        labelKey: "scm.group.changes",
        changelist: null,
        resources: [projectedResource("local", "changes", "subversionr.changedFile", lockedEntry)],
      },
      { id: "unversioned", labelKey: "scm.group.unversioned", changelist: null, resources: [] },
      { id: "incoming", labelKey: "scm.group.incoming", changelist: null, resources: [] },
      { id: "externals", labelKey: "scm.group.externals", changelist: null, resources: [] },
      { id: "ignored", labelKey: "scm.group.ignored", changelist: null, resources: [] },
    ],
  };
}

function projectionWithChangelist(): ScmRepositoryProjection {
  const base = projection();
  const reviewEntry = statusEntry("src/review.c", "modified", { changelist: "review" });
  return {
    ...base,
    count: 2,
    groups: [
      { id: "conflicts", labelKey: "scm.group.conflicts", changelist: null, resources: [] },
      {
        id: "changelist:review",
        labelKey: "scm.group.changelist",
        changelist: "review",
        resources: [projectedResource("local", "changelist:review", "subversionr.changedFile", reviewEntry)],
      },
      ...(base.groups.filter((group) => group.id !== "conflicts") as ScmRepositoryProjection["groups"]),
    ],
  };
}

function projectionWithNonBaseResources(): ScmRepositoryProjection {
  const base = projection();
  const unversionedEntry = statusEntry("scratch.txt", "unversioned");
  const ignoredEntry = statusEntry("ignored.txt", "ignored");
  const externalEntry = statusEntry("external.txt", "external");
  externalEntry.external = true;
  const incomingEntry = statusEntry("incoming.txt", "normal");
  return {
    ...base,
    count: 0,
    groups: [
      { id: "conflicts", labelKey: "scm.group.conflicts", changelist: null, resources: [] },
      { id: "changes", labelKey: "scm.group.changes", changelist: null, resources: [] },
      {
        id: "unversioned",
        labelKey: "scm.group.unversioned",
        changelist: null,
        resources: [projectedResource("local", "unversioned", "subversionr.unversioned", unversionedEntry)],
      },
      {
        id: "incoming",
        labelKey: "scm.group.incoming",
        changelist: null,
        resources: [projectedResource("remote", "incoming", "subversionr.incoming", incomingEntry)],
      },
      {
        id: "externals",
        labelKey: "scm.group.externals",
        changelist: null,
        resources: [projectedResource("local", "externals", "subversionr.external", externalEntry)],
      },
      {
        id: "ignored",
        labelKey: "scm.group.ignored",
        changelist: null,
        resources: [projectedResource("local", "ignored", "subversionr.ignored", ignoredEntry)],
      },
    ],
  };
}

function projectionWithUnsupportedChangedFiles(): ScmRepositoryProjection {
  const entries = [
    statusEntry("added.txt", "added"),
    statusEntry("deleted.txt", "deleted"),
    statusEntry("missing.txt", "missing"),
    statusEntry("obstructed.txt", "obstructed"),
    statusEntry("incomplete.txt", "incomplete"),
    statusEntry("props.txt", "normal", { propertyStatus: "modified" }),
  ];
  return {
    ...projection(),
    count: entries.length,
    groups: [
      { id: "conflicts", labelKey: "scm.group.conflicts", changelist: null, resources: [] },
      {
        id: "changes",
        labelKey: "scm.group.changes",
        changelist: null,
        resources: entries.map((entry) => projectedResource("local", "changes", "subversionr.changedFile", entry)),
      },
      { id: "unversioned", labelKey: "scm.group.unversioned", changelist: null, resources: [] },
      { id: "incoming", labelKey: "scm.group.incoming", changelist: null, resources: [] },
      { id: "externals", labelKey: "scm.group.externals", changelist: null, resources: [] },
      { id: "ignored", labelKey: "scm.group.ignored", changelist: null, resources: [] },
    ],
  };
}

function projectionWithWorkingCopyMetadata(): ScmRepositoryProjection {
  const metadataOnlyEntry = statusEntry("branches/feature", "normal", {
    kind: "dir",
    switched: true,
    depth: "files",
  });
  const changedEntry = statusEntry("src/main.c", "modified", {
    switched: true,
    depth: "empty",
  });
  return {
    ...projection(),
    count: 1,
    groups: [
      { id: "conflicts", labelKey: "scm.group.conflicts", changelist: null, resources: [] },
      {
        id: "changes",
        labelKey: "scm.group.changes",
        changelist: null,
        resources: [
          projectedResource("local", "changes", "subversionr.workingCopyMetadata", metadataOnlyEntry, {
            tooltipKey: "scm.resource.workingCopyMetadata",
          }),
          projectedResource("local", "changes", "subversionr.changedFile", changedEntry),
        ],
      },
      { id: "unversioned", labelKey: "scm.group.unversioned", changelist: null, resources: [] },
      { id: "incoming", labelKey: "scm.group.incoming", changelist: null, resources: [] },
      { id: "externals", labelKey: "scm.group.externals", changelist: null, resources: [] },
      { id: "ignored", labelKey: "scm.group.ignored", changelist: null, resources: [] },
    ],
  };
}

function projectionWithConflictedIgnoredAndExternal(): ScmRepositoryProjection {
  const conflictedExternal = statusEntry("conflicted-external.txt", "conflicted");
  conflictedExternal.conflict = "tree";
  conflictedExternal.external = true;
  const conflictedIgnored = statusEntry("conflicted-ignored.txt", "ignored");
  conflictedIgnored.conflict = "text";
  return {
    ...projection(),
    count: 2,
    groups: [
      {
        id: "conflicts",
        labelKey: "scm.group.conflicts",
        changelist: null,
        resources: [
          projectedResource("local", "conflicts", "subversionr.conflicted", conflictedExternal),
          projectedResource("local", "conflicts", "subversionr.conflicted", conflictedIgnored),
        ],
      },
      { id: "changes", labelKey: "scm.group.changes", changelist: null, resources: [] },
      { id: "unversioned", labelKey: "scm.group.unversioned", changelist: null, resources: [] },
      { id: "incoming", labelKey: "scm.group.incoming", changelist: null, resources: [] },
      { id: "externals", labelKey: "scm.group.externals", changelist: null, resources: [] },
      { id: "ignored", labelKey: "scm.group.ignored", changelist: null, resources: [] },
    ],
  };
}

function projectedResource(
  source: "local" | "remote",
  groupId: ScmRepositoryProjection["groups"][number]["id"],
  contextValue: string,
  entry: ReturnType<typeof statusEntry>,
  overrides: Partial<Pick<ScmRepositoryProjection["groups"][number]["resources"][number], "tooltipKey">> = {},
) {
  return {
    key: `${source}:${entry.path}`,
    repositoryId: "repo-uuid:C:/wc",
    path: entry.path,
    source,
    groupId,
    contextValue,
    tooltipKey: overrides.tooltipKey ?? "scm.resource.changed",
    entry,
  };
}

function statusEntry(path: string, localStatus: string, overrides: Partial<StatusEntry> = {}): StatusEntry {
  return {
    path,
    kind: "file",
    nodeStatus: localStatus,
    textStatus: localStatus,
    propertyStatus: "normal",
    localStatus,
    remoteStatus: "notChecked",
    revision: 7,
    changedRevision: 7,
    changedAuthor: "alice",
    changedDate: "2026-06-22T00:00:00Z",
    changelist: null,
    lock: null,
    needsLock: false,
    copy: null,
    move: null,
    switched: false,
    depth: "infinity",
    conflict: null,
    external: false,
    generation: 11,
    ...overrides,
  };
}
