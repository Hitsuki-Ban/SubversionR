import { readdirSync, readFileSync, statSync } from "node:fs";
import { extname, join } from "node:path";
import { describe, expect, it } from "vitest";

const extensionRoot = join(__dirname, "..");

describe("extension manifest", () => {
  it("declares the public SubversionR extension identity", () => {
    const manifest = readJson("package.json");

    expect(manifest.name).toBe("subversionr");
    expect(manifest.publisher).toBe("hitsuki-ban");
    expect(manifest.displayName).toBe("SVN-R");
    expect(manifest.version).toBe("0.2.5");
    expect(manifest.private).toBeUndefined();
    expect(manifest.repository).toEqual({
      type: "git",
      url: "https://github.com/Hitsuki-Ban/SubversionR.git",
    });
    expect(manifest.homepage).toBe("https://github.com/Hitsuki-Ban/SubversionR#readme");
    expect(manifest.bugs).toEqual({
      url: "https://github.com/Hitsuki-Ban/SubversionR/issues",
    });
  });

  it("uses the public subversionr command namespace for contributed command surfaces", () => {
    const manifest = readJson("package.json");
    const oldCommandNamespace = ["svn", "-r."].join("");

    const contributedCommands = new Set<string>(
      (manifest.contributes?.commands ?? []).map((command: { command: string }) => command.command),
    );
    const activationCommands = (manifest.activationEvents ?? [])
      .filter((event: string) => event.startsWith("onCommand:"))
      .map((event: string) => event.slice("onCommand:".length));
    const menuCommands = Object.values(manifest.contributes?.menus ?? {})
      .flatMap((items) => items as Array<{ command?: string }>)
      .map((item) => item.command)
      .filter((command): command is string => typeof command === "string");

    expect([...contributedCommands].every((command) => command.startsWith("subversionr."))).toBe(true);

    const oldNamespaceCommands = [
      ...[...contributedCommands],
      ...activationCommands,
      ...menuCommands,
    ].filter((command) => command.startsWith(oldCommandNamespace));
    expect(oldNamespaceCommands).toEqual([]);
  });

  it("activates on the SVN working-copy database without broad startup", () => {
    const manifest = readJson("package.json");

    expect(manifest.l10n).toBe("./l10n");
    expect(manifest.activationEvents).toEqual([
      "workspaceContains:.svn/wc.db",
      "workspaceContains:../.svn/wc.db",
      "workspaceContains:../../.svn/wc.db",
      "workspaceContains:../../../.svn/wc.db",
      "workspaceContains:../../../../.svn/wc.db",
      "onCommand:subversionr.initialize",
      "onCommand:subversionr.diagnostics.collect",
      "onCommand:subversionr.diagnostics.versionReport",
      "onCommand:subversionr.diagnostics.installedSvnAnonymousReport",
      "onCommand:subversionr.diagnostics.installedSvnAnonymousStressCheckout",
      "onCommand:subversionr.diagnostics.installedSvnAnonymousNegativeReport",
      "onCommand:subversionr.diagnostics.installedSvnAnonymousAuthzDeniedReport",
      "onCommand:subversionr.diagnostics.installedSvnAnonymousStalledReadReport",
      "onCommand:subversionr.diagnostics.installedSvnAnonymousDeadlineReport",
      "onCommand:subversionr.diagnostics.installedSvnAnonymousCancellationReport",
      "onCommand:subversionr.diagnostics.installedSvnAnonymousTrustRevokedReport",
      "onCommand:subversionr.diagnostics.installedSvnAnonymousRecoveryBlockedReport",
      "onCommand:subversionr.diagnostics.installedSvnAnonymousRedactionReport",
      "onCommand:subversionr.diagnostics.installedSvnAnonymousLocalEventZeroNetworkArm",
      "onCommand:subversionr.diagnostics.installedSvnAnonymousLocalEventZeroNetworkReport",
      "onCommand:subversionr.diagnostics.installedCoreWorkflowReport",
      "onCommand:subversionr.diagnostics.installedSourceControlSurfaceReport",
      "onCommand:subversionr.diagnostics.installedSourceControlUiE2eOpenReport",
      "onCommand:subversionr.diagnostics.installedSourceControlUiE2eCurrentSurfaceReport",
      "onCommand:subversionr.diagnostics.installedSourceControlUiE2eFreshnessReport",
      "onCommand:subversionr.diagnostics.installedSourceControlUiE2eArmFullReconcileCancellation",
      "onCommand:subversionr.diagnostics.installedSourceControlUiE2eFullReconcileCancellationReport",
      "onCommand:subversionr.diagnostics.installedSourceControlUiE2eArmDirtyGenerationCancellation",
      "onCommand:subversionr.diagnostics.installedSourceControlUiE2eDirtyGenerationCancellationReport",
      "onCommand:subversionr.diagnostics.installedSourceControlUiE2eDirtyEvent",
      "onCommand:subversionr.diagnostics.installedSourceControlUiE2eSetInputMessage",
      "onCommand:subversionr.diagnostics.installedSourceControlUiE2eCloseReport",
      "onCommand:subversionr.diagnostics.installedSourceControlUiE2eLazyExternalProviderReport",
      "onCommand:subversionr.diagnostics.installedRepositoryLifecycleReport",
      "onCommand:subversionr.cache.clear",
      "onCommand:subversionr.credentials.clearSaved",
      "onCommand:subversionr.migration.showReport",
      "onCommand:subversionr.tortoise.openRepositoryLog",
      "onCommand:subversionr.tortoise.openResourceLog",
      "onCommand:subversionr.tortoise.diffResource",
      "onCommand:subversionr.tortoise.openRevisionGraph",
      "onCommand:subversionr.tortoise.openRepositoryBrowser",
      "onCommand:subversionr.tortoise.blameResource",
      "onCommand:subversionr.openRepository",
      "onCommand:subversionr.checkoutRepository",
      "onCommand:subversionr.closeRepository",
      "onCommand:subversionr.refreshRepository",
      "onCommand:subversionr.checkRemoteChanges",
      "onCommand:subversionr.retryRemoteRecovery",
      "onCommand:subversionr.resolveCheckoutTargetRecovery",
      "onCommand:subversionr.refreshResource",
      "onCommand:subversionr.openConflictArtifact",
      "onCommand:subversionr.addResource",
      "onCommand:subversionr.addToIgnoreResource",
      "onCommand:subversionr.removeFromIgnoreResource",
      "onCommand:subversionr.setResourceChangelist",
      "onCommand:subversionr.clearResourceChangelist",
      "onCommand:subversionr.lockResource",
      "onCommand:subversionr.unlockResource",
      "onCommand:subversionr.deleteUnversionedResource",
      "onCommand:subversionr.deleteAllUnversionedResources",
      "onCommand:subversionr.commitResource",
      "onCommand:subversionr.commitAll",
      "onCommand:subversionr.pickCommitMessageHistory",
      "onCommand:subversionr.commitChangelist",
      "onCommand:subversionr.reviewCommit",
      "onCommand:subversionr.revertChangelist",
      "onCommand:subversionr.revertAll",
      "onCommand:subversionr.removeResource",
      "onCommand:subversionr.removeResourceKeepLocal",
      "onCommand:subversionr.moveResource",
      "onCommand:subversionr.resolveResource",
      "onCommand:subversionr.resolveAll",
      "onCommand:subversionr.revertResource",
      "onCommand:subversionr.cleanupRepository",
      "onCommand:subversionr.upgradeWorkingCopy",
      "onCommand:subversionr.updateRepository",
      "onCommand:subversionr.updateToRevision",
      "onCommand:subversionr.branchCreateRepository",
      "onCommand:subversionr.switchRepository",
      "onCommand:subversionr.relocateRepository",
      "onCommand:subversionr.mergeRangeRepository",
      "onCommand:subversionr.previewMergeRangeRepository",
      "onCommand:subversionr.showRepositoryMergeinfo",
      "onCommand:subversionr.showRepositoryProperties",
      "onCommand:subversionr.showResourceMergeinfo",
      "onCommand:subversionr.showResourceProperties",
      "onCommand:subversionr.setResourceProperty",
      "onCommand:subversionr.deleteResourceProperty",
      "onCommand:subversionr.editRepositoryExternals",
      "onCommand:subversionr.editResourceExternals",
      "onCommand:subversionr.updateResource",
      "onCommand:subversionr.updateAllIncoming",
      "onCommand:subversionr.diffWithBase",
      "onCommand:subversionr.openBase",
      "onCommand:subversionr.diffWithHead",
      "onCommand:subversionr.openHead",
      "onCommand:subversionr.diffWithPrevious",
      "onCommand:subversionr.showRepositoryLog",
      "onCommand:subversionr.showFileHistory",
      "onCommand:subversionr.showLineHistory",
      "onCommand:subversionr.showBlame",
      "onCommand:subversionr.history.refresh",
      "onCommand:subversionr.history.searchLoaded",
      "onCommand:subversionr.history.loadMore",
      "onCommand:subversionr.history.openRevision",
      "onCommand:subversionr.history.compareWithPrevious",
      "onCommand:subversionr.history.compareRevisions",
      "onCommand:subversionr.history.openRevisionDetails",
      "onCommand:subversionr.history.copyMessage",
      "onCommand:subversionr.history.copyRevision",
      "onCommand:svn.itemlog.openDiff",
      "onCommand:svn.repolog.openDiff",
      "onCommand:svn.itemlog.copymsg",
      "onCommand:svn.repolog.copymsg",
      "onCommand:svn.itemlog.copyrevision",
      "onCommand:svn.repolog.copyrevision",
      "onCommand:svn.searchLogByText",
      "onCommand:svn.openHEADFile",
      "onCommand:svn.openChangeHead",
      "onCommand:svn.openChangePrev",
      "onCommand:subversionr.fullReconcile",
    ]);
    expect(manifest.activationEvents).not.toContain("*");
    expect(manifest.activationEvents).not.toContain("onStartupFinished");
    expect(manifest.activationEvents).not.toContain("workspaceContains:**/.svn");
    expect(manifest.activationEvents).not.toContain("workspaceContains:**/.svn/wc.db");
    expect(manifest.activationEvents).not.toContain("onCommand:subversionr.diagnostics.installedRedactionReport");
    const contributedCommands = (manifest.contributes?.commands ?? []).map(
      (command: { command: string }) => command.command,
    );
    expect(contributedCommands).not.toContain("subversionr.diagnostics.installedSvnAnonymousNegativeReport");
    expect(contributedCommands).not.toContain("subversionr.diagnostics.installedSvnAnonymousAuthzDeniedReport");
    expect(contributedCommands).not.toContain("subversionr.diagnostics.installedSvnAnonymousStalledReadReport");
    expect(contributedCommands).not.toContain("subversionr.diagnostics.installedSvnAnonymousDeadlineReport");
    expect(contributedCommands).not.toContain("subversionr.diagnostics.installedSvnAnonymousCancellationReport");
    expect(contributedCommands).not.toContain("subversionr.diagnostics.installedSvnAnonymousTrustRevokedReport");
    expect(contributedCommands).not.toContain("subversionr.diagnostics.installedSvnAnonymousRecoveryBlockedReport");
    expect(contributedCommands).not.toContain("subversionr.diagnostics.installedSvnAnonymousRedactionReport");
    expect(contributedCommands).not.toContain("subversionr.diagnostics.installedSvnAnonymousLocalEventZeroNetworkArm");
    expect(contributedCommands).not.toContain("subversionr.diagnostics.installedSvnAnonymousLocalEventZeroNetworkReport");
    expect(JSON.stringify(manifest.contributes?.menus ?? {})).not.toContain(
      "subversionr.diagnostics.installedSvnAnonymousNegativeReport",
    );
    expect(JSON.stringify(manifest.contributes?.menus ?? {})).not.toContain(
      "subversionr.diagnostics.installedSvnAnonymousAuthzDeniedReport",
    );
    expect(JSON.stringify(manifest.contributes?.menus ?? {})).not.toContain(
      "subversionr.diagnostics.installedSvnAnonymousStalledReadReport",
    );
    expect(JSON.stringify(manifest.contributes?.menus ?? {})).not.toContain(
      "subversionr.diagnostics.installedSvnAnonymousDeadlineReport",
    );
    expect(JSON.stringify(manifest.contributes?.menus ?? {})).not.toContain(
      "subversionr.diagnostics.installedSvnAnonymousCancellationReport",
    );
    expect(JSON.stringify(manifest.contributes?.menus ?? {})).not.toContain(
      "subversionr.diagnostics.installedSvnAnonymousTrustRevokedReport",
    );
    expect(JSON.stringify(manifest.contributes?.menus ?? {})).not.toContain(
      "subversionr.diagnostics.installedSvnAnonymousRecoveryBlockedReport",
    );
    expect(JSON.stringify(manifest.contributes?.menus ?? {})).not.toContain(
      "subversionr.diagnostics.installedSvnAnonymousRedactionReport",
    );
    expect(JSON.stringify(manifest.contributes?.menus ?? {})).not.toContain(
      "subversionr.diagnostics.installedSvnAnonymousLocalEventZeroNetworkArm",
    );
    expect(JSON.stringify(manifest.contributes?.menus ?? {})).not.toContain(
      "subversionr.diagnostics.installedSvnAnonymousLocalEventZeroNetworkReport",
    );
  });

  it("binds installed redaction evidence to the real diagnostics and redaction functions", () => {
    const source = readFileSync(join(extensionRoot, "src/extension.ts"), "utf8");
    const productionClosure = `              collectDiagnosticsComposite: async (diagnosticInput) => ({
                diagnosticsBundle: await collectDiagnosticsBundle({
                  context: diagnosticsContext(context),
                  backendService: service,
                  operationJournal,
                  watcherOverflowDiagnostics,
                }),
                redactedCanary: redactDiagnosticValue(diagnosticInput),
              }),`;

    expect(source).toContain(productionClosure);
    expect(source.match(/collectDiagnosticsComposite: async \(diagnosticInput\)/gu)).toHaveLength(1);
  });

  it("declares limited Workspace Trust support for trust-sensitive SVN operations and external tool config paths", () => {
    const manifest = readJson("package.json");

    expect(manifest.capabilities?.untrustedWorkspaces).toEqual({
      supported: "limited",
      description: "%workspaceTrust.description%",
      restrictedConfigurations: [
        "subversionr.tortoise.executablePath",
        "subversionr.tortoise.configDirectory",
      ],
    });
  });

  it("contributes explicit repository open and close commands", () => {
    const manifest = readJson("package.json");

    expect(manifest.contributes.commands.map(
      ({ icon: _icon, ...entry }: { icon?: string; [key: string]: unknown }) => entry,
    )).toEqual([
      {
        command: "subversionr.initialize",
        title: "%command.initialize.title%",
      },
      {
        command: "subversionr.diagnostics.collect",
        title: "%command.diagnostics.collect.title%",
      },
      {
        command: "subversionr.diagnostics.versionReport",
        title: "%command.diagnostics.versionReport.title%",
      },
      {
        command: "subversionr.cache.clear",
        title: "%command.cache.clear.title%",
      },
      {
        command: "subversionr.credentials.clearSaved",
        title: "%command.credentials.clearSaved.title%",
      },
      {
        command: "subversionr.migration.showReport",
        title: "%command.migration.showReport.title%",
      },
      {
        command: "subversionr.tortoise.openRepositoryLog",
        title: "%command.tortoise.openRepositoryLog.title%",
      },
      {
        command: "subversionr.tortoise.openResourceLog",
        title: "%command.tortoise.openResourceLog.title%",
      },
      {
        command: "subversionr.tortoise.diffResource",
        title: "%command.tortoise.diffResource.title%",
      },
      {
        command: "subversionr.tortoise.openRevisionGraph",
        title: "%command.tortoise.openRevisionGraph.title%",
      },
      {
        command: "subversionr.tortoise.openRepositoryBrowser",
        title: "%command.tortoise.openRepositoryBrowser.title%",
      },
      {
        command: "subversionr.tortoise.blameResource",
        title: "%command.tortoise.blameResource.title%",
      },
      {
        command: "subversionr.openRepository",
        title: "%command.openRepository.title%",
      },
      {
        command: "subversionr.checkoutRepository",
        title: "%command.checkoutRepository.title%",
      },
      {
        command: "subversionr.closeRepository",
        title: "%command.closeRepository.title%",
      },
      {
        command: "subversionr.refreshRepository",
        title: "%command.refreshRepository.title%",
      },
      {
        command: "subversionr.checkRemoteChanges",
        title: "%command.checkRemoteChanges.title%",
      },
      {
        command: "subversionr.retryRemoteRecovery",
        title: "%command.retryRemoteRecovery.title%",
      },
      {
        command: "subversionr.resolveCheckoutTargetRecovery",
        title: "%command.resolveCheckoutTargetRecovery.title%",
      },
      {
        command: "subversionr.refreshResource",
        title: "%command.refreshResource.title%",
      },
      {
        command: "subversionr.openConflictArtifact",
        title: "%command.openConflictArtifact.title%",
      },
      {
        command: "subversionr.addResource",
        title: "%command.addResource.title%",
      },
      {
        command: "subversionr.addToIgnoreResource",
        title: "%command.addToIgnoreResource.title%",
      },
      {
        command: "subversionr.removeFromIgnoreResource",
        title: "%command.removeFromIgnoreResource.title%",
      },
      {
        command: "subversionr.setResourceChangelist",
        title: "%command.setResourceChangelist.title%",
      },
      {
        command: "subversionr.clearResourceChangelist",
        title: "%command.clearResourceChangelist.title%",
      },
      {
        command: "subversionr.lockResource",
        title: "%command.lockResource.title%",
      },
      {
        command: "subversionr.unlockResource",
        title: "%command.unlockResource.title%",
      },
      {
        command: "subversionr.deleteUnversionedResource",
        title: "%command.deleteUnversionedResource.title%",
      },
      {
        command: "subversionr.deleteAllUnversionedResources",
        title: "%command.deleteAllUnversionedResources.title%",
      },
      {
        command: "subversionr.commitResource",
        title: "%command.commitResource.title%",
      },
      {
        command: "subversionr.commitAll",
        title: "%command.commitAll.title%",
      },
      {
        command: "subversionr.pickCommitMessageHistory",
        title: "%command.pickCommitMessageHistory.title%",
      },
      {
        command: "subversionr.commitChangelist",
        title: "%command.commitChangelist.title%",
      },
      {
        command: "subversionr.reviewCommit",
        title: "%command.reviewCommit.title%",
      },
      {
        command: "subversionr.revertChangelist",
        title: "%command.revertChangelist.title%",
      },
      {
        command: "subversionr.revertAll",
        title: "%command.revertAll.title%",
      },
      {
        command: "subversionr.removeResource",
        title: "%command.removeResource.title%",
      },
      {
        command: "subversionr.removeResourceKeepLocal",
        title: "%command.removeResourceKeepLocal.title%",
      },
      {
        command: "subversionr.moveResource",
        title: "%command.moveResource.title%",
      },
      {
        command: "subversionr.resolveResource",
        title: "%command.resolveResource.title%",
      },
      {
        command: "subversionr.resolveAll",
        title: "%command.resolveAll.title%",
      },
      {
        command: "subversionr.revertResource",
        title: "%command.revertResource.title%",
      },
      {
        command: "subversionr.cleanupRepository",
        title: "%command.cleanupRepository.title%",
      },
      {
        command: "subversionr.upgradeWorkingCopy",
        title: "%command.upgradeWorkingCopy.title%",
      },
      {
        command: "subversionr.updateRepository",
        title: "%command.updateRepository.title%",
      },
      {
        command: "subversionr.updateToRevision",
        title: "%command.updateToRevision.title%",
      },
      {
        command: "subversionr.branchCreateRepository",
        title: "%command.branchCreateRepository.title%",
      },
      {
        command: "subversionr.switchRepository",
        title: "%command.switchRepository.title%",
      },
      {
        command: "subversionr.relocateRepository",
        title: "%command.relocateRepository.title%",
      },
      {
        command: "subversionr.mergeRangeRepository",
        title: "%command.mergeRangeRepository.title%",
      },
      {
        command: "subversionr.previewMergeRangeRepository",
        title: "%command.previewMergeRangeRepository.title%",
      },
      {
        command: "subversionr.showRepositoryMergeinfo",
        title: "%command.showRepositoryMergeinfo.title%",
      },
      {
        command: "subversionr.showRepositoryProperties",
        title: "%command.showRepositoryProperties.title%",
      },
      {
        command: "subversionr.showResourceMergeinfo",
        title: "%command.showResourceMergeinfo.title%",
      },
      {
        command: "subversionr.showResourceProperties",
        title: "%command.showResourceProperties.title%",
      },
      {
        command: "subversionr.setResourceProperty",
        title: "%command.setResourceProperty.title%",
      },
      {
        command: "subversionr.deleteResourceProperty",
        title: "%command.deleteResourceProperty.title%",
      },
      {
        command: "subversionr.editRepositoryExternals",
        title: "%command.editRepositoryExternals.title%",
      },
      {
        command: "subversionr.editResourceExternals",
        title: "%command.editResourceExternals.title%",
      },
      {
        command: "subversionr.updateResource",
        title: "%command.updateResource.title%",
      },
      {
        command: "subversionr.updateAllIncoming",
        title: "%command.updateAllIncoming.title%",
      },
      {
        command: "subversionr.diffWithBase",
        title: "%command.diffWithBase.title%",
      },
      {
        command: "subversionr.openBase",
        title: "%command.openBase.title%",
      },
      {
        command: "subversionr.diffWithHead",
        title: "%command.diffWithHead.title%",
      },
      {
        command: "subversionr.openHead",
        title: "%command.openHead.title%",
      },
      {
        command: "subversionr.diffWithPrevious",
        title: "%command.diffWithPrevious.title%",
      },
      {
        command: "subversionr.showRepositoryLog",
        title: "%command.showRepositoryLog.title%",
      },
      {
        command: "subversionr.showFileHistory",
        title: "%command.showFileHistory.title%",
      },
      {
        command: "subversionr.showLineHistory",
        title: "%command.showLineHistory.title%",
      },
      {
        command: "subversionr.showBlame",
        title: "%command.showBlame.title%",
      },
      {
        command: "subversionr.history.refresh",
        title: "%command.history.refresh.title%",
      },
      {
        command: "subversionr.history.searchLoaded",
        title: "%command.history.searchLoaded.title%",
      },
      {
        command: "subversionr.history.loadMore",
        title: "%command.history.loadMore.title%",
      },
      {
        command: "subversionr.history.openRevision",
        title: "%command.history.openRevision.title%",
      },
      {
        command: "subversionr.history.compareWithPrevious",
        title: "%command.history.compareWithPrevious.title%",
      },
      {
        command: "subversionr.history.compareRevisions",
        title: "%command.history.compareRevisions.title%",
      },
      {
        command: "subversionr.history.openRevisionDetails",
        title: "%command.history.openRevisionDetails.title%",
      },
      {
        command: "subversionr.history.copyMessage",
        title: "%command.history.copyMessage.title%",
      },
      {
        command: "subversionr.history.copyRevision",
        title: "%command.history.copyRevision.title%",
      },
      {
        command: "subversionr.fullReconcile",
        title: "%command.fullReconcile.title%",
      },
    ]);
    expect(manifest.contributes.commands.map((command: { command: string }) => command.command)).not.toContain(
      "svn.itemlog.copymsg",
    );
    expect(manifest.contributes.commands.map((command: { command: string }) => command.command)).not.toContain(
      "svn.repolog.copymsg",
    );
    expect(manifest.contributes.commands.map((command: { command: string }) => command.command)).not.toContain(
      "svn.itemlog.copyrevision",
    );
    expect(manifest.contributes.commands.map((command: { command: string }) => command.command)).not.toContain(
      "svn.repolog.copyrevision",
    );
    expect(manifest.contributes.commands.map((command: { command: string }) => command.command)).not.toContain(
      "svn.itemlog.openDiff",
    );
    expect(manifest.contributes.commands.map((command: { command: string }) => command.command)).not.toContain(
      "svn.repolog.openDiff",
    );
    expect(manifest.contributes.commands.map((command: { command: string }) => command.command)).not.toContain(
      "svn.openHEADFile",
    );
    expect(manifest.contributes.commands.map((command: { command: string }) => command.command)).not.toContain(
      "svn.openChangeHead",
    );
    expect(manifest.contributes.commands.map((command: { command: string }) => command.command)).not.toContain(
      "svn.openChangePrev",
    );
    expect(manifest.contributes.commands.map((command: { command: string }) => command.command)).not.toContain(
      "svn.searchLogByText",
    );
  });

  it("contributes localized SCM empty-state open and checkout welcome content", () => {
    const manifest = readJson("package.json");

    expect(manifest.contributes.viewsWelcome).toEqual([
      {
        view: "scm",
        contents: "%view.scm.emptyState.content%",
      },
    ]);
    expect(manifest.activationEvents).toContain("onCommand:subversionr.openRepository");
    expect(manifest.activationEvents).toContain("onCommand:subversionr.checkoutRepository");
    expect(JSON.stringify(manifest.contributes.viewsWelcome)).toContain("view.scm.emptyState.content");
    expect(JSON.stringify(manifest.contributes.viewsWelcome)).not.toContain("Open Repository URL");

    expect(readJson("package.nls.json")).toHaveProperty(
      "view.scm.emptyState.content",
      "No SVN working copy was found in the workspace.\n[Open SVN Working Copy…](command:subversionr.openRepository)\n[Checkout SVN Repository…](command:subversionr.checkoutRepository)",
    );
    expect(readJson("package.nls.ja.json")).toHaveProperty(
      "view.scm.emptyState.content",
      "ワークスペースに SVN 作業コピーが見つかりませんでした。\n[SVN 作業コピーを開く…](command:subversionr.openRepository)\n[SVN リポジトリをチェックアウト…](command:subversionr.checkoutRepository)",
    );
    expect(readJson("package.nls.zh-cn.json")).toHaveProperty(
      "view.scm.emptyState.content",
      "工作区中未找到 SVN 工作副本。\n[打开 SVN 工作副本…](command:subversionr.openRepository)\n[检出 SVN 仓库…](command:subversionr.checkoutRepository)",
    );
    expect(readJson("package.nls.json")).toHaveProperty(
      "command.openRepository.title",
      "SubversionR: Open SVN Working Copy…",
    );
    expect(readJson("package.nls.json")).toHaveProperty(
      "command.checkoutRepository.title",
      "SubversionR: Checkout SVN Repository…",
    );
  });

  it("contributes a localized Beta workflow walkthrough for first-run SVN entrypoints", () => {
    const manifest = readJson("package.json");

    expect(manifest.contributes.walkthroughs).toEqual([
      {
        id: "subversionr.betaWorkflow",
        title: "%walkthrough.betaWorkflow.title%",
        description: "%walkthrough.betaWorkflow.description%",
        steps: [
          {
            id: "subversionr.betaWorkflow.openOrCheckout",
            title: "%walkthrough.betaWorkflow.openOrCheckout.title%",
            description: "%walkthrough.betaWorkflow.openOrCheckout.description%",
            media: {
              image: "media/walkthrough/subversionr-workflow.svg",
              altText: "%walkthrough.betaWorkflow.openOrCheckout.alt%",
            },
            completionEvents: ["onCommand:subversionr.openRepository", "onCommand:subversionr.checkoutRepository"],
          },
          {
            id: "subversionr.betaWorkflow.reviewStatus",
            title: "%walkthrough.betaWorkflow.reviewStatus.title%",
            description: "%walkthrough.betaWorkflow.reviewStatus.description%",
            media: {
              image: "media/walkthrough/subversionr-workflow.svg",
              altText: "%walkthrough.betaWorkflow.reviewStatus.alt%",
            },
            completionEvents: ["onCommand:subversionr.refreshRepository", "onCommand:subversionr.checkRemoteChanges"],
          },
          {
            id: "subversionr.betaWorkflow.reviewAndCommit",
            title: "%walkthrough.betaWorkflow.reviewAndCommit.title%",
            description: "%walkthrough.betaWorkflow.reviewAndCommit.description%",
            media: {
              image: "media/walkthrough/subversionr-workflow.svg",
              altText: "%walkthrough.betaWorkflow.reviewAndCommit.alt%",
            },
            completionEvents: ["onCommand:subversionr.reviewCommit"],
          },
          {
            id: "subversionr.betaWorkflow.inspectHistory",
            title: "%walkthrough.betaWorkflow.inspectHistory.title%",
            description: "%walkthrough.betaWorkflow.inspectHistory.description%",
            media: {
              image: "media/walkthrough/subversionr-workflow.svg",
              altText: "%walkthrough.betaWorkflow.inspectHistory.alt%",
            },
            completionEvents: ["onCommand:subversionr.showRepositoryLog", "onCommand:subversionr.showRepositoryProperties"],
          },
        ],
      },
    ]);

    expect(readJson("package.nls.json")).toHaveProperty(
      "walkthrough.betaWorkflow.title",
      "Get started with SubversionR",
    );
    expect(readJson("package.nls.ja.json")).toHaveProperty(
      "walkthrough.betaWorkflow.title",
      "SubversionR を始める",
    );
    expect(readJson("package.nls.zh-cn.json")).toHaveProperty(
      "walkthrough.betaWorkflow.title",
      "开始使用 SubversionR",
    );

    expect(statSync(join(extensionRoot, "media/walkthrough/subversionr-workflow.svg")).isFile()).toBe(true);
    const commandCompletionEvents = manifest.contributes.walkthroughs[0].steps.flatMap(
      (step: { completionEvents: readonly string[] }) => step.completionEvents,
    );
    expect(commandCompletionEvents.every((event: string) => manifest.activationEvents.includes(event))).toBe(true);

    for (const bundleName of ["package.nls.json", "package.nls.ja.json", "package.nls.zh-cn.json"]) {
      const walkthrough = readJson(bundleName)["walkthrough.betaWorkflow.inspectHistory.description"] as string;
      expect(walkthrough).not.toMatch(/merge|mergeinfo|合并/i);
    }
  });

  it("uses Unicode ellipsis exactly for command titles that collect user input", () => {
    const dialogTitleKeys = [
      "command.branchCreateRepository.title",
      "command.checkoutRepository.title",
      "command.cleanupRepository.title",
      "command.deleteAllUnversionedResources.title",
      "command.deleteResourceProperty.title",
      "command.deleteUnversionedResource.title",
      "command.diagnostics.collect.title",
      "command.editRepositoryExternals.title",
      "command.editResourceExternals.title",
      "command.history.searchLoaded.title",
      "command.lockResource.title",
      "command.mergeRangeRepository.title",
      "command.moveResource.title",
      "command.openRepository.title",
      "command.pickCommitMessageHistory.title",
      "command.previewMergeRangeRepository.title",
      "command.relocateRepository.title",
      "command.removeResource.title",
      "command.removeResourceKeepLocal.title",
      "command.resolveAll.title",
      "command.resolveResource.title",
      "command.revertAll.title",
      "command.revertChangelist.title",
      "command.revertResource.title",
      "command.reviewCommit.title",
      "command.setResourceChangelist.title",
      "command.setResourceProperty.title",
      "command.switchRepository.title",
      "command.unlockResource.title",
      "command.updateToRevision.title",
    ].sort();

    for (const bundleName of ["package.nls.json", "package.nls.ja.json", "package.nls.zh-cn.json"]) {
      const bundle = readJson(bundleName);
      const ellipsisTitles = Object.entries(bundle)
        .filter(([key, value]) => key.startsWith("command.") && typeof value === "string" && value.endsWith("…"))
        .map(([key]) => key)
        .sort();
      expect(ellipsisTitles, bundleName).toEqual(dialogTitleKeys);
      expect(
        Object.entries(bundle).filter(([key, value]) =>
          key.startsWith("command.") && typeof value === "string" && value.includes("...")
        ),
        bundleName,
      ).toEqual([]);
    }
  });

  it("logs successful backend initialization without showing an information toast", () => {
    const source = readFileSync(join(extensionRoot, "src/extension.ts"), "utf8");
    const start = source.indexOf("const initializeCommandHandler = createInitializeCommandHandler({");
    const end = source.indexOf("const collectDiagnosticsCommand", start);
    expect(start).toBeGreaterThanOrEqual(0);
    expect(end).toBeGreaterThan(start);

    const initializeCommand = source.slice(start, end);
    expect(initializeCommand).toContain("operationLogChannel.info(");
    expect(initializeCommand).toContain('vscode.l10n.t("SubversionR backend ready. libsvn: {0}"');
    expect(initializeCommand).not.toContain("showInformationMessage");
    expect(initializeCommand).toContain(
      'vscode.commands.registerCommand("subversionr.initialize", initializeCommandHandler)',
    );

    const handlerSource = readFileSync(join(extensionRoot, "src/backend/initializeCommandHandler.ts"), "utf8");
    expect(handlerSource).toContain("void Promise.resolve()");
    expect(handlerSource).not.toMatch(/await\s+options\.showErrorMessage/u);
  });

  it("contributes localized SubversionR editor and SCM action submenus", () => {
    const manifest = readJson("package.json");

    expect(manifest.contributes.submenus).toEqual([
      {
        id: "subversionr.editorContext",
        label: "%submenu.editorContext.label%",
      },
      {
        id: "subversionr.scm.commit",
        label: "%submenu.scm.commit.label%",
      },
      {
        id: "subversionr.scm.update",
        label: "%submenu.scm.update.label%",
      },
      {
        id: "subversionr.scm.repository",
        label: "%submenu.scm.repository.label%",
      },
      {
        id: "subversionr.scm.history",
        label: "%submenu.scm.history.label%",
      },
    ]);
  });

  it("contributes SubversionR SCM and history view menus only", () => {
    const manifest = readJson("package.json");

    const expectedStableMenus = {
      "scm/resourceGroup/context": [
        {
          command: "subversionr.deleteAllUnversionedResources",
          when: "scmProvider == svn-r && isWorkspaceTrusted && scmResourceGroup == unversioned",
          group: "inline",
        },
        {
          command: "subversionr.resolveAll",
          when: "scmProvider == svn-r && isWorkspaceTrusted && scmResourceGroupState == subversionr.conflicts",
          group: "inline",
        },
        {
          command: "subversionr.commitChangelist",
          when: "scmProvider == svn-r && isWorkspaceTrusted && scmResourceGroupState == subversionr.changelist",
          group: "inline",
        },
        {
          command: "subversionr.revertChangelist",
          when: "scmProvider == svn-r && isWorkspaceTrusted && scmResourceGroupState == subversionr.changelist",
          group: "inline@2",
        },
        {
          command: "subversionr.updateAllIncoming",
          when: "scmProvider == svn-r && isWorkspaceTrusted && scmResourceGroupState == subversionr.incoming",
          group: "inline",
        },
      ],
      "editor/context": [
        {
          submenu: "subversionr.editorContext",
          when: "resourceScheme == file && subversionr.activeEditorHistoryFile",
          group: "subversionr@1",
        },
      ],
      "explorer/context": [
        {
          command: "subversionr.moveResource",
          when: "resourceScheme == file && isWorkspaceTrusted",
          group: "subversionr@1",
        },
      ],
      "subversionr.editorContext": [
        {
          command: "subversionr.diffWithPrevious",
          when: "resourceScheme == file && isWorkspaceTrusted && subversionr.activeEditorPreviousDiffable",
          group: "diff@1",
        },
        {
          command: "subversionr.diffWithBase",
          when: "resourceScheme == file && subversionr.activeEditorBaseDiffable",
          group: "diff@2",
        },
        {
          command: "subversionr.openBase",
          when: "resourceScheme == file && subversionr.activeEditorBaseDiffable",
          group: "diff@3",
        },
        {
          command: "subversionr.diffWithHead",
          when: "resourceScheme == file && isWorkspaceTrusted && subversionr.activeEditorBaseDiffable",
          group: "diff@4",
        },
        {
          command: "subversionr.openHead",
          when: "resourceScheme == file && isWorkspaceTrusted && subversionr.activeEditorBaseDiffable",
          group: "diff@5",
        },
        {
          command: "subversionr.moveResource",
          when: "resourceScheme == file && isWorkspaceTrusted && subversionr.activeEditorHistoryFile",
          group: "operation@1",
        },
        {
          command: "subversionr.showFileHistory",
          when: "resourceScheme == file && isWorkspaceTrusted && subversionr.activeEditorHistoryFile",
          group: "history@1",
        },
        {
          command: "subversionr.showLineHistory",
          when: "resourceScheme == file && isWorkspaceTrusted && subversionr.activeEditorLineHistoryFile",
          group: "history@2",
        },
        {
          command: "subversionr.showBlame",
          when: "resourceScheme == file && isWorkspaceTrusted && subversionr.activeEditorHistoryFile",
          group: "history@3",
        },
        {
          command: "subversionr.showResourceProperties",
          when: "resourceScheme == file && isWorkspaceTrusted && subversionr.activeEditorHistoryFile",
          group: "history@5",
        },
        {
          command: "subversionr.tortoise.openResourceLog",
          when: "resourceScheme == file && isWorkspaceTrusted && subversionr.tortoiseAvailable && subversionr.activeEditorHistoryFile",
          group: "tortoise@1",
        },
        {
          command: "subversionr.tortoise.diffResource",
          when: "resourceScheme == file && isWorkspaceTrusted && subversionr.tortoiseAvailable && subversionr.activeEditorBaseDiffable",
          group: "tortoise@2",
        },
        {
          command: "subversionr.tortoise.blameResource",
          when: "resourceScheme == file && isWorkspaceTrusted && subversionr.tortoiseAvailable && subversionr.activeEditorHistoryFile",
          group: "tortoise@3",
        },
      ],
      "view/title": [
        {
          command: "subversionr.history.refresh",
          when: "view == subversionr.history && isWorkspaceTrusted",
          group: "navigation",
        },
        {
          command: "subversionr.history.searchLoaded",
          when: "view == subversionr.history",
          group: "navigation@2",
        },
      ],
      "view/item/context": [
        {
          command: "subversionr.history.openRevision",
          when: "view == subversionr.history && isWorkspaceTrusted && (viewItem == subversionr.history.fileRevision || viewItem == subversionr.history.fileRevision.previousDiffable) && !listMultiSelection",
          group: "inline",
        },
        {
          command: "subversionr.history.compareWithPrevious",
          when: "view == subversionr.history && isWorkspaceTrusted && viewItem == subversionr.history.fileRevision.previousDiffable && !listMultiSelection",
          group: "inline@1",
        },
        {
          command: "subversionr.history.compareRevisions",
          when: "view == subversionr.history && isWorkspaceTrusted && (viewItem == subversionr.history.fileRevision || viewItem == subversionr.history.fileRevision.previousDiffable) && listMultiSelection",
          group: "inline@2",
        },
        {
          command: "subversionr.history.openRevisionDetails",
          when: "view == subversionr.history && (viewItem == subversionr.history.repositoryRevision || viewItem == subversionr.history.fileRevision || viewItem == subversionr.history.fileRevision.previousDiffable || viewItem == subversionr.history.lineRevision) && !listMultiSelection",
          group: "inline",
        },
        {
          command: "subversionr.history.copyMessage",
          when: "view == subversionr.history && (viewItem == subversionr.history.repositoryRevision || viewItem == subversionr.history.fileRevision || viewItem == subversionr.history.fileRevision.previousDiffable || viewItem == subversionr.history.lineRevision) && !listMultiSelection",
          group: "clipboard",
        },
        {
          command: "subversionr.history.copyRevision",
          when: "view == subversionr.history && (viewItem == subversionr.history.repositoryRevision || viewItem == subversionr.history.fileRevision || viewItem == subversionr.history.fileRevision.previousDiffable || viewItem == subversionr.history.lineRevision) && !listMultiSelection",
          group: "clipboard",
        },
      ],
      commandPalette: [
        {
          command: "subversionr.tortoise.openRepositoryLog",
          when: "isWorkspaceTrusted && subversionr.tortoiseAvailable",
        },
        {
          command: "subversionr.tortoise.openRevisionGraph",
          when: "isWorkspaceTrusted && subversionr.tortoiseAvailable",
        },
        {
          command: "subversionr.tortoise.openRepositoryBrowser",
          when: "isWorkspaceTrusted && subversionr.tortoiseAvailable",
        },
        {
          command: "subversionr.refreshResource",
          when: "false",
        },
        {
          command: "subversionr.openConflictArtifact",
          when: "false",
        },
        {
          command: "subversionr.checkRemoteChanges",
          when: "false",
        },
        {
          command: "subversionr.retryRemoteRecovery",
          when: "false",
        },
        {
          command: "subversionr.addResource",
          when: "false",
        },
        {
          command: "subversionr.addToIgnoreResource",
          when: "false",
        },
        {
          command: "subversionr.removeFromIgnoreResource",
          when: "false",
        },
        {
          command: "subversionr.setResourceChangelist",
          when: "false",
        },
        {
          command: "subversionr.clearResourceChangelist",
          when: "false",
        },
        {
          command: "subversionr.lockResource",
          when: "false",
        },
        {
          command: "subversionr.unlockResource",
          when: "false",
        },
        {
          command: "subversionr.deleteUnversionedResource",
          when: "false",
        },
        {
          command: "subversionr.deleteAllUnversionedResources",
          when: "false",
        },
        {
          command: "subversionr.commitResource",
          when: "false",
        },
        {
          command: "subversionr.commitChangelist",
          when: "false",
        },
        {
          command: "subversionr.revertChangelist",
          when: "false",
        },
        {
          command: "subversionr.revertAll",
          when: "false",
        },
        {
          command: "subversionr.removeResource",
          when: "false",
        },
        {
          command: "subversionr.removeResourceKeepLocal",
          when: "false",
        },
        {
          command: "subversionr.moveResource",
          when: "false",
        },
        {
          command: "subversionr.resolveResource",
          when: "false",
        },
        {
          command: "subversionr.resolveAll",
          when: "false",
        },
        {
          command: "subversionr.revertResource",
          when: "false",
        },
        {
          command: "subversionr.updateResource",
          when: "false",
        },
        {
          command: "subversionr.updateAllIncoming",
          when: "false",
        },
        {
          command: "subversionr.tortoise.openResourceLog",
          when: "false",
        },
        {
          command: "subversionr.tortoise.diffResource",
          when: "false",
        },
        {
          command: "subversionr.tortoise.blameResource",
          when: "false",
        },
        {
          command: "subversionr.diffWithBase",
          when: "resourceScheme == file && subversionr.activeEditorBaseDiffable",
        },
        {
          command: "subversionr.openBase",
          when: "false",
        },
        {
          command: "subversionr.diffWithHead",
          when: "resourceScheme == file && isWorkspaceTrusted && subversionr.activeEditorBaseDiffable",
        },
        {
          command: "subversionr.openHead",
          when: "false",
        },
        {
          command: "subversionr.diffWithPrevious",
          when: "resourceScheme == file && isWorkspaceTrusted && subversionr.activeEditorPreviousDiffable",
        },
        {
          command: "subversionr.showFileHistory",
          when: "resourceScheme == file && isWorkspaceTrusted && subversionr.activeEditorHistoryFile",
        },
        {
          command: "subversionr.showLineHistory",
          when: "resourceScheme == file && isWorkspaceTrusted && subversionr.activeEditorLineHistoryFile",
        },
        {
          command: "subversionr.showBlame",
          when: "resourceScheme == file && isWorkspaceTrusted && subversionr.activeEditorHistoryFile",
        },
        {
          command: "subversionr.mergeRangeRepository",
          when: "false",
        },
        {
          command: "subversionr.previewMergeRangeRepository",
          when: "false",
        },
        {
          command: "subversionr.showRepositoryMergeinfo",
          when: "false",
        },
        {
          command: "subversionr.showResourceMergeinfo",
          when: "false",
        },
        {
          command: "subversionr.showResourceProperties",
          when: "false",
        },
        {
          command: "subversionr.setResourceProperty",
          when: "false",
        },
        {
          command: "subversionr.deleteResourceProperty",
          when: "false",
        },
        {
          command: "subversionr.editRepositoryExternals",
          when: "false",
        },
        {
          command: "subversionr.editResourceExternals",
          when: "false",
        },
        {
          command: "subversionr.history.refresh",
          when: "false",
        },
        {
          command: "subversionr.history.searchLoaded",
          when: "false",
        },
        {
          command: "subversionr.history.loadMore",
          when: "false",
        },
        {
          command: "subversionr.history.openRevision",
          when: "false",
        },
        {
          command: "subversionr.history.compareWithPrevious",
          when: "false",
        },
        {
          command: "subversionr.history.compareRevisions",
          when: "false",
        },
        {
          command: "subversionr.history.openRevisionDetails",
          when: "false",
        },
        {
          command: "subversionr.history.copyMessage",
          when: "false",
        },
        {
          command: "subversionr.history.copyRevision",
          when: "false",
        },
      ],
    } as Record<string, unknown>;
    const restructuredMenus = [
      "scm/title",
      "scm/resourceState/context",
      "subversionr.scm.commit",
      "subversionr.scm.update",
      "subversionr.scm.repository",
      "subversionr.scm.history",
    ];
    for (const menu of restructuredMenus) {
      expectedStableMenus[menu] = manifest.contributes.menus[menu];
    }
    expect(manifest.contributes.menus).toEqual(expectedStableMenus);
  });

  it("keeps only Refresh, Commit, and Review as SCM title navigation icons", () => {
    const manifest = readJson("package.json");
    const titleMenu = manifest.contributes.menus["scm/title"] as Array<{
      command?: string;
      submenu?: string;
      group: string;
    }>;

    expect(titleMenu.filter((entry) => entry.group.startsWith("navigation"))).toEqual([
      {
        command: "subversionr.refreshRepository",
        when: "scmProvider == svn-r",
        group: "navigation@1",
      },
      {
        command: "subversionr.commitAll",
        when: "scmProvider == svn-r && isWorkspaceTrusted",
        group: "navigation@2",
      },
      {
        command: "subversionr.reviewCommit",
        when: "scmProvider == svn-r && isWorkspaceTrusted",
        group: "navigation@3",
      },
    ]);
    expect(titleMenu.filter((entry) => entry.submenu !== undefined).map((entry) => entry.submenu)).toEqual([
      "subversionr.scm.commit",
      "subversionr.scm.update",
      "subversionr.scm.repository",
      "subversionr.scm.history",
    ]);
    const commandIcons = new Map(
      manifest.contributes.commands.map((entry: { command: string; icon?: string }) => [entry.command, entry.icon]),
    );
    expect([
      commandIcons.get("subversionr.refreshRepository"),
      commandIcons.get("subversionr.commitAll"),
      commandIcons.get("subversionr.reviewCommit"),
    ]).toEqual(["$(refresh)", "$(check)", "$(diff)"]);
  });

  it("keeps every former SCM title action reachable through the title or one overflow submenu", () => {
    const manifest = readJson("package.json");
    const menus = manifest.contributes.menus as Record<
      string,
      Array<{ command?: string; submenu?: string }>
    >;
    const scmMenuIds = [
      "scm/title",
      "subversionr.scm.commit",
      "subversionr.scm.update",
      "subversionr.scm.repository",
      "subversionr.scm.history",
    ];
    const reachableCommands = scmMenuIds.flatMap((menu) =>
      menus[menu].flatMap((entry) => entry.command === undefined ? [] : [entry.command]),
    );

    expect(reachableCommands.sort()).toEqual([
      "subversionr.branchCreateRepository",
      "subversionr.checkRemoteChanges",
      "subversionr.cleanupRepository",
      "subversionr.closeRepository",
      "subversionr.commitAll",
      "subversionr.editRepositoryExternals",
      "subversionr.fullReconcile",
      "subversionr.pickCommitMessageHistory",
      "subversionr.refreshRepository",
      "subversionr.relocateRepository",
      "subversionr.revertAll",
      "subversionr.reviewCommit",
      "subversionr.showRepositoryLog",
      "subversionr.showRepositoryProperties",
      "subversionr.switchRepository",
      "subversionr.tortoise.openRepositoryBrowser",
      "subversionr.tortoise.openRepositoryLog",
      "subversionr.tortoise.openRevisionGraph",
      "subversionr.updateRepository",
      "subversionr.updateToRevision",
      "subversionr.upgradeWorkingCopy",
    ].sort());
    expect(new Set(reachableCommands).size).toBe(reachableCommands.length);
  });

  it("limits each SCM resource state to at most three icon-backed inline actions", () => {
    const manifest = readJson("package.json");
    const commands = new Map<string, { icon?: string }>(
      manifest.contributes.commands.map((entry: { command: string; icon?: string }) => [entry.command, entry]),
    );
    const menus = manifest.contributes.menus as Record<
      string,
      Array<{ command?: string; group?: string; when?: string }>
    >;
    const resourceContext = menus["scm/resourceState/context"];
    const resourceInline = resourceContext.filter((entry) => entry.group?.startsWith("inline"));
    const inlineEntries = Object.entries(menus).flatMap(([menu, entries]) =>
      entries.filter((entry) =>
        entry.command !== undefined &&
        (entry.group?.startsWith("inline") || (menu.endsWith("/title") && entry.group?.startsWith("navigation")))
      ),
    );
    const resourceStates = [
      "subversionr.conflicted",
      "subversionr.conflicted.changelisted",
      "subversionr.conflicted.locked",
      "subversionr.conflicted.changelisted.locked",
      "subversionr.conflictArtifact",
      "subversionr.changedFile",
      "subversionr.changedFile.changelisted",
      "subversionr.changedFile.locked",
      "subversionr.changedFile.changelisted.locked",
      "subversionr.changedFile.baseDiffable",
      "subversionr.changedFile.baseDiffable.changelisted",
      "subversionr.changedFile.baseDiffable.locked",
      "subversionr.changedFile.baseDiffable.changelisted.locked",
      "subversionr.changedDirectory",
      "subversionr.changedDirectory.changelisted",
      "subversionr.changedUnknown",
      "subversionr.workingCopyMetadata",
      "subversionr.workingCopyMetadataFile",
      "subversionr.workingCopyMetadataFile.locked",
      "subversionr.unversioned",
      "subversionr.external",
      "subversionr.ignored",
      "subversionr.incoming",
      "subversionr.incoming.locked",
      "subversionr.incomingFile",
      "subversionr.incomingFile.locked",
    ];

    for (const state of resourceStates) {
      const visibleInline = resourceInline.filter((entry) => resourceStateWhenMatches(entry.when ?? "", state));
      expect(visibleInline.length, state).toBeLessThanOrEqual(3);
    }
    expect(
      resourceInline
        .filter((entry) => resourceStateWhenMatches(entry.when ?? "", "subversionr.changedFile.baseDiffable"))
        .map((entry) => entry.command),
    ).toContain("subversionr.commitResource");
    expect(
      resourceContext
        .filter((entry) => resourceStateWhenMatches(entry.when ?? "", "subversionr.changedFile.baseDiffable"))
        .map((entry) => entry.command),
    ).toEqual(expect.arrayContaining(["subversionr.diffWithBase", "subversionr.openBase"]));
    for (const state of ["subversionr.conflicted", "subversionr.changedFile"]) {
      expect(
        resourceContext
          .filter((entry) => resourceStateWhenMatches(entry.when ?? "", state))
          .map((entry) => entry.command),
        state,
      ).toContain("subversionr.showBlame");
    }
    const conflictArtifactEntries = resourceContext.filter((entry) =>
      resourceStateWhenMatches(entry.when ?? "", "subversionr.conflictArtifact")
    );
    expect(
      conflictArtifactEntries
        .filter((entry) => !entry.group?.startsWith("inline"))
        .map((entry) => entry.command),
    ).toEqual([]);
    expect(conflictArtifactEntries.filter((entry) => entry.group?.startsWith("inline"))).toEqual([
      {
        command: "subversionr.openConflictArtifact",
        when: "scmProvider == svn-r && scmResourceState == subversionr.conflictArtifact",
        group: "inline",
      },
    ]);
    for (const entry of resourceInline) {
      if (entry.command === "subversionr.openConflictArtifact") {
        continue;
      }
      expect(entry.when, entry.command).toContain("scmResourceGroup != conflictArtifacts");
    }
    for (const entry of inlineEntries) {
      expect(commands.get(entry.command!)?.icon, entry.command).toMatch(/^\$\([^)]+\)$/);
    }

    const ordinaryContextCommands = new Set(
      menus["scm/resourceState/context"]
        .filter((entry) => !entry.group?.startsWith("inline"))
        .flatMap((entry) => entry.command === undefined ? [] : [entry.command]),
    );
    for (const command of [
      "subversionr.addToIgnoreResource",
      "subversionr.deleteUnversionedResource",
      "subversionr.clearResourceChangelist",
      "subversionr.lockResource",
      "subversionr.unlockResource",
      "subversionr.removeResource",
      "subversionr.removeResourceKeepLocal",
      "subversionr.moveResource",
    ]) {
      expect(ordinaryContextCommands.has(command), command).toBe(true);
    }
  });

  it("exposes exactly the six active-editor inspection commands through bounded Command Palette contexts", () => {
    const manifest = readJson("package.json");
    const menus = manifest.contributes.menus as Record<
      string,
      Array<{ command?: string; submenu?: string; when?: string }>
    >;
    const expected = new Map([
      ["subversionr.diffWithBase", "resourceScheme == file && subversionr.activeEditorBaseDiffable"],
      ["subversionr.diffWithHead", "resourceScheme == file && isWorkspaceTrusted && subversionr.activeEditorBaseDiffable"],
      ["subversionr.diffWithPrevious", "resourceScheme == file && isWorkspaceTrusted && subversionr.activeEditorPreviousDiffable"],
      ["subversionr.showFileHistory", "resourceScheme == file && isWorkspaceTrusted && subversionr.activeEditorHistoryFile"],
      ["subversionr.showLineHistory", "resourceScheme == file && isWorkspaceTrusted && subversionr.activeEditorLineHistoryFile"],
      ["subversionr.showBlame", "resourceScheme == file && isWorkspaceTrusted && subversionr.activeEditorHistoryFile"],
    ]);
    const resourceCommands = new Set(
      ["scm/resourceState/context", "subversionr.editorContext", "explorer/context"]
        .flatMap((menu) => menus[menu] ?? [])
        .flatMap((entry) => entry.command === undefined ? [] : [entry.command]),
    );
    const paletteEntries = menus.commandPalette.filter(
      (entry) => entry.command !== undefined && resourceCommands.has(entry.command),
    );

    expect(
      paletteEntries
        .filter((entry) => entry.when !== "false")
        .map((entry) => [entry.command, entry.when]),
    ).toEqual([...expected.entries()]);
    for (const command of resourceCommands) {
      const entries = paletteEntries.filter((entry) => entry.command === command);
      expect(entries, command).toHaveLength(1);
      expect(entries[0]?.when, command).toBe(expected.get(command) ?? "false");
    }
  });

  it("keeps deferred merge commands registered but hidden from every user-facing menu", () => {
    const manifest = readJson("package.json");
    const deferredCommands = [
      "subversionr.mergeRangeRepository",
      "subversionr.previewMergeRangeRepository",
      "subversionr.showRepositoryMergeinfo",
      "subversionr.showResourceMergeinfo",
    ];
    const contributedCommands = new Set(
      manifest.contributes.commands.map((entry: { command: string }) => entry.command),
    );
    const menus = manifest.contributes.menus as Record<
      string,
      Array<{ command?: string; when?: string }>
    >;
    const visibleEntries = Object.entries(menus)
      .filter(([menu]) => menu !== "commandPalette")
      .flatMap(([menu, entries]) =>
        entries
          .filter((entry) => entry.command !== undefined && deferredCommands.includes(entry.command))
          .map((entry) => ({ menu, ...entry })),
      );

    expect(deferredCommands.every((command) => contributedCommands.has(command))).toBe(true);
    expect(visibleEntries).toEqual([]);
    expect(
      menus.commandPalette.filter(
        (entry) => entry.command !== undefined && deferredCommands.includes(entry.command),
      ),
    ).toEqual(deferredCommands.map((command) => ({ command, when: "false" })));
  });

  it("hides current write and remote operation menu entries in untrusted workspaces", () => {
    const manifest = readJson("package.json");
    const menus = manifest.contributes.menus;
    const trustSensitiveCommands = new Set([
      "subversionr.addResource",
      "subversionr.addToIgnoreResource",
      "subversionr.removeFromIgnoreResource",
      "subversionr.branchCreateRepository",
      "subversionr.checkRemoteChanges",
      "subversionr.cleanupRepository",
      "subversionr.upgradeWorkingCopy",
      "subversionr.commitAll",
      "subversionr.commitResource",
      "subversionr.pickCommitMessageHistory",
      "subversionr.reviewCommit",
      "subversionr.deleteUnversionedResource",
      "subversionr.deleteAllUnversionedResources",
      "subversionr.diffWithHead",
      "subversionr.diffWithPrevious",
      "subversionr.relocateRepository",
      "subversionr.showRepositoryProperties",
      "subversionr.showResourceProperties",
      "subversionr.setResourceProperty",
      "subversionr.deleteResourceProperty",
      "subversionr.editRepositoryExternals",
      "subversionr.editResourceExternals",
      "subversionr.moveResource",
      "subversionr.removeResourceKeepLocal",
      "subversionr.removeResource",
      "subversionr.resolveAll",
      "subversionr.resolveResource",
      "subversionr.revertResource",
      "subversionr.showBlame",
      "subversionr.showFileHistory",
      "subversionr.showLineHistory",
      "subversionr.showRepositoryLog",
      "subversionr.switchRepository",
      "subversionr.history.compareRevisions",
      "subversionr.history.compareWithPrevious",
      "subversionr.history.openRevision",
      "subversionr.history.refresh",
      "subversionr.openHead",
      "subversionr.updateRepository",
      "subversionr.updateToRevision",
      "subversionr.updateResource",
      "subversionr.updateAllIncoming",
    ]);
    const contributedItems = [
      ...menus["scm/title"],
      ...menus["subversionr.scm.commit"],
      ...menus["subversionr.scm.update"],
      ...menus["subversionr.scm.repository"],
      ...menus["subversionr.scm.history"],
      ...menus["scm/resourceGroup/context"],
      ...menus["scm/resourceState/context"],
      ...menus["explorer/context"],
      ...menus["subversionr.editorContext"],
      ...menus["view/title"],
      ...menus["view/item/context"],
    ].filter((item) => trustSensitiveCommands.has(item.command));

    expect(contributedItems).toHaveLength(69);
    for (const item of contributedItems) {
      expect(item.when).toContain("isWorkspaceTrusted");
    }
  });

  it("contributes a native SCM history view", () => {
    const manifest = readJson("package.json");

    expect(manifest.contributes.views).toEqual({
      scm: [
        {
          id: "subversionr.history",
          name: "%view.history.name%",
          visibility: "collapsed",
        },
      ],
    });
  });

  it("does not contribute backend path settings because packaged resources are mandatory", () => {
    const manifest = readJson("package.json");
    const configuration = manifest.contributes.configuration;

    expect(configuration).toMatchObject({
      title: "%configuration.title%",
    });
    expect(configuration.properties).not.toHaveProperty("subversionr.backend.executablePath");
    expect(configuration.properties).not.toHaveProperty("subversionr.backend.bridgeDllPath");
  });

  it("does not request proposed VS Code APIs", () => {
    const manifest = readJson("package.json");
    const tsconfig = readJson("tsconfig.json");

    expect(manifest).not.toHaveProperty("enabledApiProposals");
    expect(manifest).not.toHaveProperty("apiProposals");
    expect(JSON.stringify(manifest)).not.toContain("enable-proposed-api");
    expect(tsconfig.compilerOptions.types).toEqual(["node", "vscode", "vitest"]);

    const sourceFiles = listTextFiles(join(extensionRoot, "src"), [".ts"]);
    expect(sourceFiles.length).toBeGreaterThan(0);
    for (const file of sourceFiles) {
      const text = readFileSync(file, "utf8");
      expect(text).not.toContain("vscode.proposed");
      expect(text).not.toContain("enabledApiProposals");
      expect(text).not.toContain("enable-proposed-api");
    }
  });

  it("contributes only Tortoise external tool settings behind Workspace Trust without defaults", () => {
    const manifest = readJson("package.json");
    const properties = manifest.contributes.configuration.properties;

    expect(properties["subversionr.tortoise.executablePath"]).toEqual({
      type: "string",
      scope: "machine-overridable",
      markdownDescription: "%configuration.tortoise.executablePath.description%",
    });
    expect(properties["subversionr.tortoise.configDirectory"]).toEqual({
      type: "string",
      scope: "machine-overridable",
      markdownDescription: "%configuration.tortoise.configDirectory.description%",
    });
    expect(properties).not.toHaveProperty("subversionr.svn.configDirectory");
    expect(properties).not.toHaveProperty("subversionr.svn.tunnelCommand");
    expect(properties).not.toHaveProperty("svnNative.tortoise.path");
    expect(properties).not.toHaveProperty("svnNative.advanced.configDir");
    expect(properties).not.toHaveProperty("svnNative.security.allowWorkspaceTunnelConfig");
  });

  it("contributes a strict machine-scoped remote profile schema without a default", () => {
    const manifest = readJson("package.json");
    const setting = manifest.contributes.configuration.properties["subversionr.remote.profiles"];

    expect(setting.type).toBe("array");
    expect(setting.scope).toBe("machine");
    expect(setting).not.toHaveProperty("default");
    expect(setting.markdownDescription).toBe("%configuration.remote.profiles.description%");

    const profile = setting.items;
    expect(profile.additionalProperties).toBe(false);
    expect(profile.required).toEqual([
      "schema",
      "profileId",
      "authority",
      "serverAuth",
      "serverAccount",
      "serverCredentialPersistence",
      "proxy",
      "ssh",
      "redirectPolicy",
    ]);
    expect(profile.properties.schema.enum).toEqual(["subversionr.remote-profile.v1"]);
    expect(profile.properties.authority).toEqual(
      expect.objectContaining({
        additionalProperties: false,
        required: ["scheme", "canonicalHost", "effectivePort"],
      }),
    );
    expect(profile.properties.authority.properties.scheme.enum).toEqual(["http", "https", "svn", "svn+ssh"]);
    expect(profile.properties.authority.properties.effectivePort).toEqual({
      type: "integer",
      minimum: 1,
      maximum: 65535,
    });

    const serverAccount = profile.properties.serverAccount.oneOf;
    expect(serverAccount[0].enum).toEqual(["none"]);
    expect(serverAccount[1]).toEqual(
      expect.objectContaining({ additionalProperties: false, required: ["mode", "username"] }),
    );
    expect(serverAccount[1].properties.mode.enum).toEqual(["fixed"]);
    expect(serverAccount[2]).toEqual(
      expect.objectContaining({ additionalProperties: false, required: ["mode"] }),
    );
    expect(serverAccount[2].properties.mode.enum).toEqual(["chooseForeground"]);

    expect(profile.properties.tls).toEqual(
      expect.objectContaining({ additionalProperties: false, required: ["trust"] }),
    );
    expect(profile.properties.tls.properties.trust.enum).toEqual([
      "windowsRootsThenBroker",
      "explicitCaThenBroker",
    ]);

    const proxy = profile.properties.proxy.oneOf;
    expect(proxy[0].enum).toEqual(["none"]);
    expect(proxy[1]).toEqual(
      expect.objectContaining({ additionalProperties: false, required: ["authority", "auth", "account"] }),
    );
    expect(proxy[1].properties.authority).toEqual(
      expect.objectContaining({
        additionalProperties: false,
        required: ["scheme", "canonicalHost", "effectivePort"],
      }),
    );
    expect(proxy[1].properties.account.oneOf[1]).toEqual(
      expect.objectContaining({ additionalProperties: false, required: ["mode", "username"] }),
    );

    const ssh = profile.properties.ssh.oneOf;
    expect(ssh[0].enum).toEqual(["none"]);
    expect(ssh[1]).toEqual(
      expect.objectContaining({
        additionalProperties: false,
        required: ["adapter", "sshUsername", "auth", "hostKey"],
      }),
    );
    expect(ssh[1].properties.auth.oneOf[1]).toEqual(
      expect.objectContaining({ additionalProperties: false, required: ["identityFilePath"] }),
    );
    expect(ssh[1].properties.hostKey).toEqual(
      expect.objectContaining({
        additionalProperties: false,
        required: ["algorithm", "publicKeyBlob", "fingerprint"],
      }),
    );
    expect(profile.properties.redirectPolicy.enum).toEqual(["rejectAll", "sameAuthorityInitialOptions301"]);
  });

  it("contributes explicit status, history, and lens settings without legacy setting aliases", () => {
    const manifest = readJson("package.json");
    const properties = manifest.contributes.configuration.properties;

    expect(properties["subversionr.status.countUnversioned"]).toEqual({
      type: "boolean",
      scope: "window",
      default: false,
      markdownDescription: "%configuration.status.countUnversioned.description%",
    });
    expect(properties["subversionr.status.ignoreChangelistsInCount"]).toEqual({
      type: "array",
      scope: "window",
      default: ["ignore-on-commit"],
      items: {
        type: "string",
      },
      markdownDescription: "%configuration.status.ignoreChangelistsInCount.description%",
    });
    expect(properties["subversionr.history.pageSize"]).toEqual({
      type: "integer",
      scope: "window",
      default: 100,
      minimum: 1,
      maximum: 500,
      markdownDescription: "%configuration.history.pageSize.description%",
    });
    expect(properties["subversionr.history.includeMergedRevisions"]).toEqual({
      type: "boolean",
      scope: "window",
      default: false,
      markdownDescription: "%configuration.history.includeMergedRevisions.description%",
    });
    expect(properties["subversionr.lens.enabled"]).toEqual({
      type: "boolean",
      scope: "window",
      default: true,
      markdownDescription: "%configuration.lens.enabled.description%",
    });
    expect(properties["subversionr.lens.fileHeader"]).toEqual({
      type: "boolean",
      scope: "window",
      default: true,
      markdownDescription: "%configuration.lens.fileHeader.description%",
    });
    expect(properties["subversionr.lens.currentLine"]).toEqual({
      type: "boolean",
      scope: "window",
      default: true,
      markdownDescription: "%configuration.lens.currentLine.description%",
    });
    expect(properties["subversionr.lens.hover"]).toEqual({
      type: "boolean",
      scope: "window",
      default: true,
      markdownDescription: "%configuration.lens.hover.description%",
    });
    expect(properties["subversionr.lens.symbols"]).toEqual({
      type: "boolean",
      scope: "window",
      default: false,
      markdownDescription: "%configuration.lens.symbols.description%",
    });
    expect(properties["subversionr.lens.maxFileLines"]).toEqual({
      type: "integer",
      scope: "window",
      default: 20000,
      minimum: 1,
      markdownDescription: "%configuration.lens.maxFileLines.description%",
    });
    expect(properties).not.toHaveProperty("svnNative.status.countUnversioned");
    expect(properties).not.toHaveProperty("svnNative.status.ignoreChangelistsInCount");
    expect(properties).not.toHaveProperty("svnNative.lens.enabled");
    expect(properties).not.toHaveProperty("svnNative.lens.fileHeader");
    expect(properties).not.toHaveProperty("svnNative.lens.currentLine");
    expect(properties).not.toHaveProperty("svnNative.lens.hover");
    expect(properties).not.toHaveProperty("svnNative.lens.symbols");
    expect(properties).not.toHaveProperty("svnNative.lens.maxFileLines");
    expect(properties).not.toHaveProperty("svn.status.countUnversioned");
    expect(properties).not.toHaveProperty("svn.status.ignoreChangelistsInCount");
    expect(properties).not.toHaveProperty("svn.lens.enabled");
    expect(properties).not.toHaveProperty("svn.lens.fileHeader");
    expect(properties).not.toHaveProperty("svn.lens.currentLine");
    expect(properties).not.toHaveProperty("svn.lens.hover");
    expect(properties).not.toHaveProperty("svn.lens.symbols");
    expect(properties).not.toHaveProperty("svn.lens.maxFileLines");
  });

  it.each(["package.nls.json", "package.nls.ja.json", "package.nls.zh-cn.json"])(
    "localizes contributed command and configuration keys in %s",
    (fileName) => {
      const bundle = readJson(fileName);

      expect(bundle).toHaveProperty("configuration.title");
      expect(bundle).toHaveProperty("workspaceTrust.description");
      expect(bundle).toHaveProperty("command.diagnostics.collect.title");
      expect(bundle).toHaveProperty("command.diagnostics.versionReport.title");
      expect(bundle).toHaveProperty("command.cache.clear.title");
      expect(bundle).toHaveProperty("command.credentials.clearSaved.title");
      expect(bundle).toHaveProperty("command.migration.showReport.title");
      expect(bundle).toHaveProperty("command.tortoise.openRepositoryLog.title");
      expect(bundle).toHaveProperty("command.tortoise.openResourceLog.title");
      expect(bundle).toHaveProperty("command.tortoise.diffResource.title");
      expect(bundle).toHaveProperty("command.tortoise.openRevisionGraph.title");
      expect(bundle).toHaveProperty("command.tortoise.openRepositoryBrowser.title");
      expect(bundle).toHaveProperty("command.tortoise.blameResource.title");
      expect(bundle).toHaveProperty("command.openRepository.title");
      expect(bundle).toHaveProperty("command.closeRepository.title");
      expect(bundle).toHaveProperty("command.refreshRepository.title");
      expect(bundle).toHaveProperty("command.checkRemoteChanges.title");
      expect(bundle).toHaveProperty("command.refreshResource.title");
      expect(bundle).toHaveProperty("command.addResource.title");
      expect(bundle).toHaveProperty("command.addToIgnoreResource.title");
      expect(bundle).toHaveProperty("command.removeFromIgnoreResource.title");
      expect(bundle).toHaveProperty("command.setResourceChangelist.title");
      expect(bundle).toHaveProperty("command.clearResourceChangelist.title");
      expect(bundle).toHaveProperty("command.deleteUnversionedResource.title");
      expect(bundle).toHaveProperty("command.deleteAllUnversionedResources.title");
      expect(bundle).toHaveProperty("command.commitResource.title");
      expect(bundle).toHaveProperty("command.commitAll.title");
      expect(bundle).toHaveProperty("command.pickCommitMessageHistory.title");
      expect(bundle).toHaveProperty("command.commitChangelist.title");
      expect(bundle).toHaveProperty("command.reviewCommit.title");
      expect(bundle).toHaveProperty("command.revertChangelist.title");
      expect(bundle).toHaveProperty("command.revertAll.title");
      expect(bundle).toHaveProperty("command.removeResource.title");
      expect(bundle).toHaveProperty("command.removeResourceKeepLocal.title");
      expect(bundle).toHaveProperty("command.moveResource.title");
      expect(bundle).toHaveProperty("command.resolveResource.title");
      expect(bundle).toHaveProperty("command.resolveAll.title");
      expect(bundle).toHaveProperty("command.revertResource.title");
      expect(bundle).toHaveProperty("command.cleanupRepository.title");
      expect(bundle).toHaveProperty("command.upgradeWorkingCopy.title");
      expect(bundle).toHaveProperty("command.updateRepository.title");
      expect(bundle).toHaveProperty("command.updateToRevision.title");
      expect(bundle).toHaveProperty("command.branchCreateRepository.title");
      expect(bundle).toHaveProperty("command.switchRepository.title");
      expect(bundle).toHaveProperty("command.relocateRepository.title");
      expect(bundle).toHaveProperty("command.mergeRangeRepository.title");
      expect(bundle).toHaveProperty("command.previewMergeRangeRepository.title");
      expect(bundle).toHaveProperty("command.showRepositoryMergeinfo.title");
      expect(bundle).toHaveProperty("command.showRepositoryProperties.title");
      expect(bundle).toHaveProperty("command.showResourceMergeinfo.title");
      expect(bundle).toHaveProperty("command.showResourceProperties.title");
      expect(bundle).toHaveProperty("command.setResourceProperty.title");
      expect(bundle).toHaveProperty("command.deleteResourceProperty.title");
      expect(bundle).toHaveProperty("command.editRepositoryExternals.title");
      expect(bundle).toHaveProperty("command.editResourceExternals.title");
      expect(bundle).toHaveProperty("command.updateResource.title");
      expect(bundle).toHaveProperty("command.updateAllIncoming.title");
      expect(bundle).toHaveProperty("command.diffWithBase.title");
      expect(bundle).toHaveProperty("command.openBase.title");
      expect(bundle).toHaveProperty("command.diffWithHead.title");
      expect(bundle).toHaveProperty("command.openHead.title");
      expect(bundle).toHaveProperty("command.diffWithPrevious.title");
      expect(bundle).toHaveProperty("command.showRepositoryLog.title");
      expect(bundle).toHaveProperty("command.showFileHistory.title");
      expect(bundle).toHaveProperty("command.showLineHistory.title");
      expect(bundle).toHaveProperty("command.showBlame.title");
      expect(bundle).toHaveProperty("command.history.refresh.title");
      expect(bundle).toHaveProperty("command.history.searchLoaded.title");
      expect(bundle).toHaveProperty("command.history.loadMore.title");
      expect(bundle).toHaveProperty("command.history.openRevision.title");
      expect(bundle).toHaveProperty("command.history.compareWithPrevious.title");
      expect(bundle).toHaveProperty("command.history.compareRevisions.title");
      expect(bundle).toHaveProperty("command.history.openRevisionDetails.title");
      expect(bundle).toHaveProperty("command.history.copyMessage.title");
      expect(bundle).toHaveProperty("command.history.copyRevision.title");
      expect(bundle).toHaveProperty("command.fullReconcile.title");
      expect(bundle).toHaveProperty("submenu.editorContext.label");
      expect(bundle).toHaveProperty("view.history.name");
      expect(bundle).toHaveProperty("view.scm.emptyState.content");
      expect(bundle).not.toHaveProperty("configuration.backend.executablePath.description");
      expect(bundle).not.toHaveProperty("configuration.backend.bridgeDllPath.description");
      expect(bundle).toHaveProperty("configuration.tortoise.executablePath.description");
      expect(bundle).toHaveProperty("configuration.tortoise.configDirectory.description");
      expect(bundle).toHaveProperty("configuration.remote.profiles.description");
      expect(bundle).not.toHaveProperty("configuration.svn.configDirectory.description");
      expect(bundle).not.toHaveProperty("configuration.svn.tunnelCommand.description");
      expect(bundle).toHaveProperty("configuration.status.countUnversioned.description");
      expect(bundle).toHaveProperty("configuration.status.ignoreChangelistsInCount.description");
      expect(bundle).toHaveProperty("configuration.history.pageSize.description");
      expect(bundle).toHaveProperty("configuration.history.includeMergedRevisions.description");
      expect(bundle).toHaveProperty("configuration.lens.enabled.description");
      expect(bundle).toHaveProperty("configuration.lens.fileHeader.description");
      expect(bundle).toHaveProperty("configuration.lens.currentLine.description");
      expect(bundle).toHaveProperty("configuration.lens.hover.description");
      expect(bundle).toHaveProperty("configuration.lens.symbols.description");
      expect(bundle).toHaveProperty("configuration.lens.maxFileLines.description");
    },
  );

  it.each(["l10n/bundle.l10n.json", "l10n/bundle.l10n.ja.json", "l10n/bundle.l10n.zh-cn.json"])(
    "localizes runtime extension strings in %s",
    (fileName) => {
      const bundle = readJson(fileName);

      expect(Object.keys(bundle).sort()).toEqual(runtimeLocalizationKeys().sort());
      expect(bundle).toHaveProperty("Revert");
      expect(bundle).toHaveProperty("Remove");
      expect(bundle).toHaveProperty("Delete");
      expect(bundle).toHaveProperty("Resolve");
      expect(bundle).toHaveProperty("Conflict Artifacts");
      expect(bundle).toHaveProperty("SVN conflict artifact (read-only)");
      expect(bundle).toHaveProperty("The SVN conflict artifact is no longer available.");
      expect(bundle).toHaveProperty("Move");
      expect(bundle).toHaveProperty("Commit");
      expect(bundle).toHaveProperty("SVN commit message");
      expect(bundle).toHaveProperty("SVN commit message history");
      expect(bundle).toHaveProperty("Choose an SVN commit message to reuse");
      expect(bundle).toHaveProperty("No SVN commit message history for: {0}");
      expect(bundle).toHaveProperty("SubversionR restored SVN commit message history for: {0}");
      expect(bundle).toHaveProperty("SVN BASE <-> Working Copy: {0}");
      expect(bundle).toHaveProperty("Cleaning up SVN working copy");
      expect(bundle).toHaveProperty("Break working-copy locks");
      expect(bundle).toHaveProperty("Release stale SVN working-copy locks before cleanup");
      expect(bundle).toHaveProperty("Fix recorded timestamps");
      expect(bundle).toHaveProperty("Refresh recorded SVN file timestamps during cleanup");
      expect(bundle).toHaveProperty("Clear DAV cache");
      expect(bundle).toHaveProperty("Clear cached SVN HTTP/WebDAV state during cleanup");
      expect(bundle).toHaveProperty("Vacuum pristine copies");
      expect(bundle).toHaveProperty("Remove unused pristine SVN base files during cleanup");
      expect(bundle).toHaveProperty("Run cleanup on SVN externals below this working copy");
      expect(bundle).toHaveProperty("SVN cleanup options");
      expect(bundle).toHaveProperty("Choose cleanup options for {0}");
      expect(bundle).toHaveProperty("Upgrading SVN working copy");
      expect(bundle).toHaveProperty("Updating SVN working copy");
      expect(bundle).toHaveProperty("Update SVN working copy to revision");
      expect(bundle).toHaveProperty("Enter the SVN revision number for {0}.");
      expect(bundle).toHaveProperty("Revision number");
      expect(bundle).toHaveProperty("Enter an SVN revision number from 0 to 2147483647.");
      expect(bundle).toHaveProperty("Working copy depth");
      expect(bundle).toHaveProperty("Use each node's current SVN working copy depth");
      expect(bundle).toHaveProperty("Empty");
      expect(bundle).toHaveProperty("Update only the target node");
      expect(bundle).toHaveProperty("Files");
      expect(bundle).toHaveProperty("Update the target and its immediate file children");
      expect(bundle).toHaveProperty("Immediates");
      expect(bundle).toHaveProperty("Update the target and its immediate children");
      expect(bundle).toHaveProperty("Infinity");
      expect(bundle).toHaveProperty("Update the full subtree");
      expect(bundle).toHaveProperty("SVN update depth");
      expect(bundle).toHaveProperty("Choose the SVN depth for update");
      expect(bundle).toHaveProperty("Keep depth non-sticky");
      expect(bundle).toHaveProperty("Do not change the working copy ambient depth");
      expect(bundle).toHaveProperty("Make depth sticky");
      expect(bundle).toHaveProperty("Set the selected depth as the working copy ambient depth");
      expect(bundle).toHaveProperty("SVN update sticky depth");
      expect(bundle).toHaveProperty("Choose whether update changes the ambient depth");
      expect(bundle).toHaveProperty("Ignore externals");
      expect(bundle).toHaveProperty("Skip SVN externals during update");
      expect(bundle).toHaveProperty("Include externals");
      expect(bundle).toHaveProperty("Allow libsvn to update SVN externals");
      expect(bundle).toHaveProperty("SVN update externals");
      expect(bundle).toHaveProperty("Choose how SVN externals are handled");
      expect(bundle).toHaveProperty("Updating SVN resource");
      expect(bundle).toHaveProperty("Reverting SVN resource");
      expect(bundle).toHaveProperty("Adding SVN resource");
      expect(bundle).toHaveProperty("Adding SVN ignore rule");
      expect(bundle).toHaveProperty("Removing SVN ignore rule");
      expect(bundle).toHaveProperty("Removing SVN resource");
      expect(bundle).toHaveProperty("Moving SVN resource");
      expect(bundle).toHaveProperty("Resolving SVN conflict");
      expect(bundle).toHaveProperty("Committing SVN changes");
      expect(bundle).toHaveProperty("SubversionR diagnostics bundle saved.");
      expect(bundle).toHaveProperty("SubversionR diagnostics collection failed: {0}");
      expect(bundle).toHaveProperty("SubversionR version report failed: {0}");
      expect(bundle).toHaveProperty("SubversionR Version Report");
      expect(bundle).toHaveProperty("SubversionR closed missing SVN working copy: {0}");
      expect(bundle).toHaveProperty("SubversionR could not close missing SVN working copy {0}: {1}");
      expect(bundle).toHaveProperty("SubversionR could not check SVN working copy {0}: {1}");
      expect(bundle).toHaveProperty("Retry Close");
      expect(bundle).toHaveProperty("Retry Check");
      expect(bundle).toHaveProperty("Retry Recovery");
      expect(bundle).toHaveProperty("Retry Open");
      expect(bundle).toHaveProperty("SubversionR repository lifecycle retry failed: {0}");
      expect(bundle).toHaveProperty("SubversionR reopened moved SVN working copy: {0} -> {1}");
      expect(bundle).toHaveProperty("SubversionR could not recover moved SVN working copy {0}: {1}");
      expect(bundle).toHaveProperty("SubversionR could not mark SVN status stale after backend restart: {0}");
      expect(bundle).toHaveProperty("SubversionR could not acknowledge the Workspace Trust update: {0}");
      expect(bundle).toHaveProperty("SubversionR could not reopen SVN working copy after backend restart {0}: {1}");
      expect(bundle).toHaveProperty("SubversionR extension cache cleared. SVN working copies were not modified.");
      expect(bundle).toHaveProperty("SubversionR cache clear failed: {0}");
      expect(bundle).toHaveProperty("SubversionR cache migration failed: {0}");
      expect(bundle).toHaveProperty("No SubversionR migration report is available.");
      expect(bundle).toHaveProperty("SubversionR migration report failed: {0}");
      expect(bundle).toHaveProperty("SubversionR Migration Report");
      expect(bundle).toHaveProperty("SubversionR backend cache root path must be absolute.");
      expect(bundle).toHaveProperty("SubversionR backend cache schema is unsupported: {0} version {1} rollback {2}.");
      expect(bundle).toHaveProperty("SubversionR cleared {0} saved SVN credential(s).");
      expect(bundle).toHaveProperty("SubversionR has no saved SVN credentials to clear.");
      expect(bundle).toHaveProperty("SubversionR could not clear saved SVN credentials: {0}");
      expect(bundle).toHaveProperty("SVN Credentials");
      expect(bundle).toHaveProperty("Use another SVN account");
      expect(bundle).toHaveProperty("Choose an SVN account for {0}");
      expect(bundle).toHaveProperty("SVN Account");
      expect(bundle).toHaveProperty("Username for SVN server {0}");
      expect(bundle).toHaveProperty("Password for SVN user {0} at {1}");
      expect(bundle).toHaveProperty("Clear Legacy Credentials");
      expect(bundle).toHaveProperty("Save in VS Code Secret Storage");
      expect(bundle).toHaveProperty("Use for this session only");
      expect(bundle).toHaveProperty("Choose how SubversionR should store this SVN credential");
      expect(bundle).toHaveProperty("SVN Server Certificate");
      expect(bundle).toHaveProperty("Reject");
      expect(bundle).toHaveProperty("Trust Once");
      expect(bundle).toHaveProperty("Trust Permanently");
      expect(bundle).toHaveProperty("SVN server certificate for {0} failed validation.");
      expect(bundle).toHaveProperty("Fingerprint: {0} ({1})");
      expect(bundle).toHaveProperty("Valid from {0} until {1}");
      expect(bundle).toHaveProperty("Certificate failures: {0}");
      expect(bundle).toHaveProperty("Issuer: {0}");
      expect(bundle).toHaveProperty("Subject: {0}");
      expect(bundle).toHaveProperty("SVN HEAD <-> Working Copy: {0}");
      expect(bundle).toHaveProperty("SVN HEAD: {0}");
      expect(bundle).toHaveProperty("SVN PREV <-> Revision: {0}");
      expect(bundle).toHaveProperty("SVN r{0} by {1} on {2}");
      expect(bundle).toHaveProperty("Compare PREV");
      expect(bundle).toHaveProperty("File History");
      expect(bundle).toHaveProperty("SVN r{0} - Authors {1}, Revisions {2}");
      expect(bundle).toHaveProperty("Blame");
      expect(bundle).toHaveProperty("Open Log");
      expect(bundle).toHaveProperty("Search loaded SVN history");
      expect(bundle).toHaveProperty(
        "Enter text, author, path, date, or revision to filter loaded SVN history. Leave empty to clear.",
      );
      expect(bundle).toHaveProperty("Loaded SVN history search is limited to 200 characters.");
      expect(bundle).toHaveProperty("Filtering loaded SVN history: {0}");
      expect(bundle).toHaveProperty("File: {0}");
      expect(bundle).toHaveProperty("Line History: {0}");
      expect(bundle).toHaveProperty("Load More");
      expect(bundle).toHaveProperty("Open Revision");
      expect(bundle).toHaveProperty("SVN Revision Compare: {0}");
      expect(bundle).toHaveProperty("SVN Blame: {0}");
      expect(bundle).toHaveProperty("Revision Range: {0} - {1}");
      expect(bundle).toHaveProperty("Resolved Revision Range: r{0} - r{1}");
      expect(bundle).toHaveProperty("Line Window: {0} - {1}");
      expect(bundle).toHaveProperty("Has More Lines: {0}");
      expect(bundle).toHaveProperty("Uncommitted");
      expect(bundle).toHaveProperty("Merged from r{0}");
      expect(bundle).toHaveProperty("Open Revision Details");
      expect(bundle).toHaveProperty("SVN Revision Details: {0}");
      expect(bundle).toHaveProperty("Revision {0}");
      expect(bundle).toHaveProperty("Repository ID: {0}");
      expect(bundle).toHaveProperty("History Target: File {0}");
      expect(bundle).toHaveProperty("History Target: Line {0}");
      expect(bundle).toHaveProperty("History Target: Repository Root");
      expect(bundle).toHaveProperty("Author: {0}");
      expect(bundle).toHaveProperty("Date: {0}");
      expect(bundle).toHaveProperty("Merged Revision Child: {0}");
      expect(bundle).toHaveProperty("Non-inheritable Merge: {0}");
      expect(bundle).toHaveProperty("Subtractive Merge: {0}");
      expect(bundle).toHaveProperty("Log Message:");
      expect(bundle).toHaveProperty("Changed Paths:");
      expect(bundle).toHaveProperty("No changed paths reported.");
      expect(bundle).toHaveProperty("Node Kind: {0}");
      expect(bundle).toHaveProperty("Text Modified: {0}");
      expect(bundle).toHaveProperty("Properties Modified: {0}");
      expect(bundle).toHaveProperty("Copy From: {0}@r{1}");
      expect(bundle).toHaveProperty("Yes");
      expect(bundle).toHaveProperty("No");
      expect(bundle).toHaveProperty("Unknown");
      expect(bundle).toHaveProperty("No node");
      expect(bundle).toHaveProperty("File");
      expect(bundle).toHaveProperty("Directory");
      expect(bundle).toHaveProperty("Open an SVN file or repository history.");
      expect(bundle).toHaveProperty("No SVN history entries found.");
      expect(bundle).toHaveProperty("No loaded SVN history entries match the search.");
      expect(bundle).toHaveProperty("Unknown author");
      expect(bundle).toHaveProperty("Unknown date");
      expect(bundle).toHaveProperty("No log message");
      expect(bundle).toHaveProperty("from {0}@r{1}");
      expect(bundle).toHaveProperty("Binary SVN revision content is not displayed in the text editor: {0}@{1}");
      expect(bundle).toHaveProperty("Binary SVN HEAD content is not displayed in the text editor: {0}");
      expect(bundle).toHaveProperty("Working copy");
      expect(bundle).toHaveProperty("Use the current working copy file");
      expect(bundle).toHaveProperty("Base");
      expect(bundle).toHaveProperty("Use the pre-conflict base file");
      expect(bundle).toHaveProperty("Mine full");
      expect(bundle).toHaveProperty("Use your full local file");
      expect(bundle).toHaveProperty("Theirs full");
      expect(bundle).toHaveProperty("Use the full incoming file");
      expect(bundle).toHaveProperty("Mine conflict");
      expect(bundle).toHaveProperty("Use your local changes for conflicted hunks");
      expect(bundle).toHaveProperty("Theirs conflict");
      expect(bundle).toHaveProperty("Use incoming changes for conflicted hunks");
      expect(bundle).toHaveProperty("Resolve SVN conflict");
      expect(bundle).toHaveProperty("Resolving SVN conflicts");
      expect(bundle).toHaveProperty("{0} SVN conflict");
      expect(bundle).toHaveProperty("{0} SVN conflicts");
      expect(bundle).toHaveProperty("No SVN conflicts to resolve.");
      expect(bundle).toHaveProperty("Choose how to resolve {0}");
      expect(bundle).toHaveProperty("SVN properties for {0}");
      expect(bundle).toHaveProperty("SVN property path");
      expect(bundle).toHaveProperty("SVN property source");
      expect(bundle).toHaveProperty("SVN property count");
      expect(bundle).toHaveProperty("SVN property name");
      expect(bundle).toHaveProperty("SVN property value");
      expect(bundle).toHaveProperty("Loading SVN properties");
      expect(bundle).toHaveProperty("No SVN properties found on SVN path: {0}");
      expect(bundle).toHaveProperty("Revert local SVN changes to {0}? This cannot be undone.");
      expect(bundle).toHaveProperty(
        "Remove SVN resource {0}? The local item will be deleted and scheduled for commit.",
      );
      expect(bundle).toHaveProperty("Remove SVN resource {0} from version control but keep the local item?");
      expect(bundle).toHaveProperty("Move SVN resource");
      expect(bundle).toHaveProperty("Enter the repository-relative destination path for {0}.");
      expect(bundle).toHaveProperty("Delete unversioned SVN item {0}? This cannot be undone.");
      expect(bundle).toHaveProperty("Delete {0} unversioned SVN items? This cannot be undone.");
      expect(bundle).toHaveProperty("Commit SVN changes");
      expect(bundle).toHaveProperty("Enter an SVN commit message for {0}.");
      expect(bundle).toHaveProperty("Enter a non-empty SVN commit message without carriage returns.");
      expect(bundle).toHaveProperty("Enter a non-empty SVN commit message without carriage returns and try again.");
      expect(bundle).toHaveProperty(
        "The selected SVN changes changed while entering the commit message. Review the current changes and try again.",
      );
      expect(bundle).toHaveProperty(
        "The local OS username is unavailable, so SubversionR cannot record an author for this local SVN commit. Check the OS account and retry.",
      );
      expect(bundle).toHaveProperty("No eligible SVN file changes to commit.");
      expect(bundle).toHaveProperty("Save SVN resource before committing: {0}");
      expect(bundle).toHaveProperty("SubversionR post-commit reconcile failed after revision {0}: {1}");
      expect(bundle).toHaveProperty("SubversionR added SVN resource: {0}");
      expect(bundle).toHaveProperty("SubversionR added {0} SVN resources: {1}");
      expect(bundle).toHaveProperty("SubversionR added SVN ignore rule for: {0}");
      expect(bundle).toHaveProperty("SubversionR added SVN ignore rules for {0} items: {1}");
      expect(bundle).toHaveProperty("SubversionR SVN ignore rules already include selected item(s).");
      expect(bundle).toHaveProperty("SubversionR removed SVN ignore rule for: {0}");
      expect(bundle).toHaveProperty("SubversionR removed SVN ignore rules for {0} items: {1}");
      expect(bundle).toHaveProperty("SubversionR SVN ignore rules did not include selected item(s).");
      expect(bundle).toHaveProperty("SubversionR deleted unversioned SVN item: {0}");
      expect(bundle).toHaveProperty("SubversionR deleted {0} unversioned SVN items.");
      expect(bundle).toHaveProperty("No unversioned SVN items to delete.");
      expect(bundle).toHaveProperty("SubversionR removed SVN resource but kept local item: {0}");
      expect(bundle).toHaveProperty("SubversionR removed {0} SVN resources but kept local items: {1}");
      expect(bundle).toHaveProperty("SubversionR moved SVN resource: {0} -> {1}");
      expect(bundle).toHaveProperty("SubversionR committed SVN resource at revision {0}: {1}");
      expect(bundle).toHaveProperty("SubversionR committed SVN resources at revision {0}: {1}");
      expect(bundle).toHaveProperty("SubversionR cleaned up SVN working copy: {0}");
      expect(bundle).toHaveProperty("SubversionR upgraded SVN working copy: {0}");
      expect(bundle).toHaveProperty("SubversionR updated SVN working copy to revision {0}: {1}");
      expect(bundle).toHaveProperty("SubversionR updated SVN resource to revision {0}: {1}");
      expect(bundle).not.toHaveProperty("SubversionR line history command failed: {0}");
      expect(bundle).toHaveProperty("SubversionR TortoiseSVN command failed: {0}");
      expect(bundle).not.toHaveProperty("No TortoiseSVN executable is configured or detected.");
      expect(bundle).toHaveProperty("Copied SVN commit message.");
      expect(bundle).toHaveProperty("Copied SVN revision number: {0}");
      expect(bundle).toHaveProperty("SubversionR removed SVN resource: {0}");
      expect(bundle).toHaveProperty("SubversionR removed {0} SVN resources: {1}");
      expect(bundle).toHaveProperty("SubversionR resolved SVN conflict with {0}: {1}");
      expect(bundle).toHaveProperty("SubversionR resolved {0} SVN conflicts with {1}: {2}");
      expect(bundle).toHaveProperty("Reverting SVN resources");
      expect(bundle).toHaveProperty("No eligible SVN resources to revert.");
      expect(bundle).toHaveProperty("SubversionR reverted SVN resource: {0}");
      expect(bundle).toHaveProperty("SubversionR reverted {0} SVN resources: {1}");
    },
  );

  it("localizes readonly property and mergeinfo report titles in priority languages", () => {
    expect(readJson("l10n/bundle.l10n.json")).toMatchObject({
      "SVN Properties: {0}": "SVN Properties: {0}",
      "SVN Mergeinfo: {0}": "SVN Mergeinfo: {0}",
    });
    expect(readJson("l10n/bundle.l10n.ja.json")).toMatchObject({
      "SVN Properties: {0}": "SVN プロパティ: {0}",
      "SVN Mergeinfo: {0}": "SVN マージ情報: {0}",
    });
    expect(readJson("l10n/bundle.l10n.zh-cn.json")).toMatchObject({
      "SVN Properties: {0}": "SVN 属性：{0}",
      "SVN Mergeinfo: {0}": "SVN 合并信息：{0}",
    });
  });

  it("localizes singular and plural SVN conflict counts in priority languages", () => {
    expect(readJson("l10n/bundle.l10n.json")).toMatchObject({
      "{0} SVN conflict": "{0} SVN conflict",
      "{0} SVN conflicts": "{0} SVN conflicts",
    });
    expect(readJson("l10n/bundle.l10n.ja.json")).toMatchObject({
      "{0} SVN conflict": "{0} 件の SVN 競合",
      "{0} SVN conflicts": "{0} 件の SVN 競合",
    });
    expect(readJson("l10n/bundle.l10n.zh-cn.json")).toMatchObject({
      "{0} SVN conflict": "{0} 个 SVN 冲突",
      "{0} SVN conflicts": "{0} 个 SVN 冲突",
    });
  });

  it("keeps contributed and localized user-facing text in SVN terminology", () => {
    const manifest = readJson("package.json");
    const userFacingText = [
      ...manifestUserFacingText(manifest),
      ...localizedBundleText("package.nls.json"),
      ...localizedBundleText("package.nls.ja.json"),
      ...localizedBundleText("package.nls.zh-cn.json"),
      ...localizedBundleText("l10n/bundle.l10n.json"),
      ...localizedBundleText("l10n/bundle.l10n.ja.json"),
      ...localizedBundleText("l10n/bundle.l10n.zh-cn.json"),
    ];
    const forbiddenGitTerminology = [
      /\bgit\b/iu,
      /\bstag(?:e|ed|ing)\b/iu,
      /\bpush\b/iu,
      /\bpull\b/iu,
      /\bcommit\s+graph\b/iu,
      /\bbranch\s+graph\b/iu,
    ];

    for (const value of userFacingText) {
      for (const pattern of forbiddenGitTerminology) {
        expect(value, `Forbidden Git-style terminology '${pattern}' in user-facing text: ${value}`).not.toMatch(pattern);
      }
    }
  });
});

function resourceStateWhenMatches(when: string, state: string): boolean {
  const exact = when.match(/scmResourceState == ([\w.]+)/);
  if (exact) {
    return exact[1] === state;
  }
  const regex = when.match(/scmResourceState =~ \/([^/]+)\//);
  if (regex) {
    return new RegExp(regex[1]).test(state);
  }
  throw new Error(`Inline SCM resource action is missing a direct state predicate: ${when}`);
}

function listTextFiles(root: string, extensions: readonly string[]): string[] {
  const files: string[] = [];
  for (const entry of readdirSync(root)) {
    const fullPath = join(root, entry);
    const stat = statSync(fullPath);
    if (stat.isDirectory()) {
      files.push(...listTextFiles(fullPath, extensions));
    } else if (stat.isFile() && extensions.includes(extname(fullPath))) {
      files.push(fullPath);
    }
  }
  return files.sort();
}

function readJson(fileName: string): Record<string, any> {
  return JSON.parse(readFileSync(join(extensionRoot, fileName), "utf8")) as Record<string, any>;
}

function localizedBundleText(fileName: string): string[] {
  return collectStringValues(readJson(fileName));
}

function manifestUserFacingText(manifest: Record<string, any>): string[] {
  return collectStringValues({
    displayName: manifest.displayName,
    description: manifest.description,
    keywords: manifest.keywords,
    categories: manifest.categories,
    contributes: manifest.contributes,
    capabilities: manifest.capabilities,
  });
}

function collectStringValues(value: unknown): string[] {
  if (typeof value === "string") {
    return [value];
  }
  if (Array.isArray(value)) {
    return value.flatMap((item) => collectStringValues(item));
  }
  if (value !== null && typeof value === "object") {
    return Object.values(value).flatMap((item) => collectStringValues(item));
  }
  return [];
}

function runtimeLocalizationKeys(): string[] {
  return [
    "A possibly changed SVN checkout target is blocked until you review its disposition.",
    "Confirm that you reviewed and resolved the possibly changed SVN checkout target before releasing its safety block: {0}",
    "No blocked SVN checkout target requires review.",
    "Release checkout target block",
    "Review blocked SVN checkout target",
    "Review checkout target",
    "Select the checkout target whose disposition you reviewed",
    "SubversionR released the reviewed SVN checkout target: {0}",
    "SVN {0} failed because the server denied authorization for this operation.",
    "SVN {0} failed because the server authorization configuration is invalid.",
    "Revert",
    "Remove",
    "Delete",
    "Resolve",
    "Conflict Artifacts",
    "SVN conflict artifact (read-only)",
    "The SVN conflict artifact is no longer available.",
    "Working copy",
    "Working Copy Metadata",
    "Use the current working copy file",
    "Base",
    "Use the pre-conflict base file",
    "Mine full",
    "Use your full local file",
    "Theirs full",
    "Use the full incoming file",
    "Mine conflict",
    "Use your local changes for conflicted hunks",
    "Theirs conflict",
    "Use incoming changes for conflicted hunks",
    "Resolve SVN conflict",
    "Resolving SVN conflicts",
    "{0} SVN conflict",
    "{0} SVN conflicts",
    "No SVN conflicts to resolve.",
    "Choose how to resolve {0}",
    "SVN Properties: {0}",
    "SVN properties for {0}",
    "SVN property path",
    "SVN property count",
    "SVN property name",
    "SVN property value",
    "Loading SVN properties",
    "No SVN properties found on working copy root: {0}",
    "No SVN properties found on SVN path: {0}",
    "Set SVN property",
    "Enter the SVN property name for {0}.",
    "Enter the SVN property value for {0}.",
    "Enter an SVN property name without line breaks.",
    "Enter an SVN property value without carriage returns.",
    "Delete SVN property",
    "Choose the SVN property to delete from {0}.",
    "Edit svn:externals",
    "Enter the svn:externals value for {0}. Leave empty to clear it.",
    "Move",
    "Commit",
    "Commit SVN changes",
    "Show Log",
    "Retry",
    "Update",
    "Checkout",
    "History",
    "Open Working Copy",
    "Repository Operation",
    "SubversionR could not start or complete the isolated SVN remote worker. Retry the SVN operation.",
    "The isolated SVN remote operation exceeded its deadline. Retry the operation.",
    "Another isolated SVN operation is still using this working copy. Wait for it to finish and retry.",
    "SubversionR blocked this working copy because isolated worker cleanup could not be verified. Restart VS Code before retrying SVN operations.",
    "SVN {0} failed because the working copy is out of date. Update the working copy and retry.",
    "SVN {0} failed because unresolved conflicts are present. Resolve them and retry.",
    "SVN {0} failed because authentication was rejected. Check the credentials and retry.",
    "SVN {0} credential entry was cancelled.",
    "SVN {0} authentication timed out. Retry the operation.",
    "SubversionR blocked SVN {0} because saved credential storage failed an integrity check. Clear saved credentials before retrying.",
    "SubversionR blocked SVN {0} because legacy saved credentials must be cleared first. Run Clear Saved Credentials and retry.",
    "Enter a non-empty SVN password no larger than 32768 UTF-8 bytes and retry {0}.",
    "SubversionR rejected an invalid SVN credential exchange for {0}. Retry the operation.",
    "SVN {0} failed because the selected target is not a working copy.",
    "SVN {0} failed because the SubversionR backend is unavailable. Retry the operation.",
    "SVN {0} failed. Open the SubversionR log for details.",
    "SubversionR backend startup failed. Open the SubversionR log for details.",
    "The selected SVN lock target is no longer current. Select the current resource in Source Control and try Lock again.",
    "The selected SVN lock target is outside an open repository. Select a resource from an open SVN working copy and try Lock again.",
    "The selected SVN unlock target is no longer current. Select the current resource in Source Control and try Unlock again.",
    "The selected SVN unlock target is outside an open repository. Select a resource from an open SVN working copy and try Unlock again.",
    "SVN commit message",
    "SVN commit message history",
    "Choose an SVN commit message to reuse",
    "No SVN commit message history for: {0}",
    "SubversionR restored SVN commit message history for: {0}",
    "SVN status partial",
    "SVN status stale",
    "Trust this workspace to commit SVN changes",
    "Refreshing SVN working copy",
    "Checking SVN remote changes",
    "Reconciling SVN working copy status",
    "Cleaning up SVN working copy",
    "Break working-copy locks",
    "Release stale SVN working-copy locks before cleanup",
    "Fix recorded timestamps",
    "Refresh recorded SVN file timestamps during cleanup",
    "Clear DAV cache",
    "Clear cached SVN HTTP/WebDAV state during cleanup",
    "Vacuum pristine copies",
    "Remove unused pristine SVN base files during cleanup",
    "Run cleanup on SVN externals below this working copy",
    "SVN cleanup options",
    "Choose cleanup options for {0}",
    "Upgrading SVN working copy",
    "Updating SVN working copy",
    "{0}. The working copy has unresolved SVN conflicts ({1}): {2}",
    "{0} (+{1} more)",
    "Update SVN working copy to revision",
    "Enter the SVN revision number for {0}.",
    "Revision number",
    "Enter an SVN revision number from 0 to 2147483647.",
    "Working copy depth",
    "Use each node's current SVN working copy depth",
    "Empty",
    "Update only the target node",
    "Files",
    "Update the target and its immediate file children",
    "Immediates",
    "Update the target and its immediate children",
    "Infinity",
    "Update the full subtree",
    "SVN update depth",
    "Choose the SVN depth for update",
    "Keep depth non-sticky",
    "Do not change the working copy ambient depth",
    "Make depth sticky",
    "Set the selected depth as the working copy ambient depth",
    "SVN update sticky depth",
    "Choose whether update changes the ambient depth",
    "Ignore externals",
    "Skip SVN externals during update",
    "Include externals",
    "Allow libsvn to update SVN externals",
    "SVN update externals",
    "Choose how SVN externals are handled",
    "Updating SVN resource",
    "Reverting SVN resource",
    "Adding SVN resource",
    "Adding SVN ignore rule",
    "Removing SVN ignore rule",
    "Setting SVN property",
    "Deleting SVN property",
    "Editing svn:externals",
    "Removing SVN resource",
    "Moving SVN resource",
    "Resolving SVN conflict",
    "Committing SVN changes",
    "Review SVN commit",
    "Filter by path, changelist, status, or directory",
    "No changelist",
    "Status: {0} | Directory: {1}",
    "Added",
    "Missing",
    "Deleted",
    "Replaced",
    "Modified",
    "Merged",
    "Obstructed",
    "Incomplete",
    "Setting SVN changelist",
    "Clearing SVN changelist",
    "Locking SVN resource",
    "Unlocking SVN resource",
    "SubversionR diagnostics bundle saved.",
    "SubversionR diagnostics collection failed: {0}",
    "SubversionR version report failed: {0}",
    "SubversionR Version Report",
    "SubversionR extension cache cleared. SVN working copies were not modified.",
    "SubversionR cache clear failed: {0}",
    "SubversionR cache migration failed: {0}",
    "No SubversionR migration report is available.",
    "SubversionR migration report failed: {0}",
    "SubversionR Migration Report",
    "SubversionR backend cache root path must be absolute.",
    "SubversionR backend cache schema is unsupported: {0} version {1} rollback {2}.",
    "SubversionR cleared {0} saved SVN credential(s).",
    "SubversionR has no saved SVN credentials to clear.",
    "SubversionR could not clear saved SVN credentials: {0}",
    "SVN Credentials",
    "Use another SVN account",
    "Choose an SVN account for {0}",
    "SVN Account",
    "Username for SVN server {0}",
    "Password for SVN user {0} at {1}",
    "SubversionR found {0} legacy saved SVN credential(s). They must be cleared before remote password authentication can continue.",
    "Clear Legacy Credentials",
    "Save in VS Code Secret Storage",
    "Use for this session only",
    "Choose how SubversionR should store this SVN credential",
    "SVN Server Certificate",
    "Reject",
    "Trust Once",
    "Trust Permanently",
    "SVN server certificate for {0} failed validation.",
    "Fingerprint: {0} ({1})",
    "Valid from {0} until {1}",
    "Certificate failures: {0}",
    "Issuer: {0}",
    "Subject: {0}",
    "SVN BASE <-> Working Copy: {0}",
    "SVN BASE: {0}",
    "SVN HEAD <-> Working Copy: {0}",
    "SVN HEAD: {0}",
    "SVN PREV <-> Revision: {0}",
    "Compare BASE",
    "Compare HEAD",
    "Compare PREV",
    "SVN r{0} by {1} on {2}",
    "SVN r{0} - Authors {1}, Revisions {2}",
    "SVN blame",
    "Loading SVN blame for {0}:{1}",
    "SVN r{0} {1}",
    "SVN blame for {0}:{1}",
    "File History",
    "Blame",
    "Open Log",
    "Search loaded SVN history",
    "Enter text, author, path, date, or revision to filter loaded SVN history. Leave empty to clear.",
    "Loaded SVN history search is limited to 200 characters.",
    "Filtering loaded SVN history: {0}",
    "File: {0}",
    "Line History: {0}",
    "Load More",
    "Open Revision",
    "SVN Revision Compare: {0}",
    "SVN Blame: {0}",
    "Revision Range: {0} - {1}",
    "Resolved Revision Range: r{0} - r{1}",
    "Line Window: {0} - {1}",
    "Has More Lines: {0}",
    "Uncommitted",
    "Merged from r{0}",
    "Open Revision Details",
    "SVN Revision Details: {0}",
    "Revision {0}",
    "Repository ID: {0}",
    "History Target: File {0}",
    "History Target: Line {0}",
    "History Target: Repository Root",
    "Author: {0}",
    "Date: {0}",
    "Merged Revision Child: {0}",
    "Non-inheritable Merge: {0}",
    "Subtractive Merge: {0}",
    "Log Message:",
    "Changed Paths:",
    "No changed paths reported.",
    "Node Kind: {0}",
    "Text Modified: {0}",
    "Properties Modified: {0}",
    "Copy From: {0}@r{1}",
    "Yes",
    "No",
    "Unknown",
    "No node",
    "File",
    "Directory",
    "Open an SVN file or repository history.",
    "No SVN history entries found.",
    "No loaded SVN history entries match the search.",
    "Unknown author",
    "Unknown date",
    "No log message",
    "from {0}@r{1}",
    "Binary SVN revision content is not displayed in the text editor: {0}@{1}",
    "Binary SVN HEAD content is not displayed in the text editor: {0}",
    "Revert local SVN changes to {0}? This cannot be undone.",
    "Remove SVN resource {0}? The local item will be deleted and scheduled for commit.",
    "Remove SVN resource {0} from version control but keep the local item?",
    "Move SVN resource",
    "Enter the repository-relative destination path for {0}.",
    "Delete unversioned SVN item {0}? This cannot be undone.",
    "Delete {0} unversioned SVN items? This cannot be undone.",
    "Set SVN changelist",
    "Enter the SVN changelist name for {0}.",
    "Enter the SVN changelist name for {0} resources.",
    "Changelist name",
    "Enter an SVN changelist name without line breaks.",
    "Lock SVN resource",
    "Enter an SVN lock message for {0}.",
    "Enter an SVN lock message for {0} resources.",
    "Lock message",
    "Enter an SVN lock message without line breaks.",
    "Lock",
    "Create a normal SVN lock",
    "Steal lock",
    "Break an existing SVN lock and create a new lock",
    "SVN lock mode",
    "Choose how SVN lock handles existing locks",
    "Unlock",
    "Release an SVN lock held by this working copy",
    "Force unlock",
    "Break an SVN lock held elsewhere",
    "SVN unlock mode",
    "Choose how SVN unlock handles locks held elsewhere",
    "Checkout SVN repository",
    "Enter the SVN repository URL to checkout.",
    "https://svn.example.com/project/trunk",
    "SVN checkout target folder",
    "Enter the absolute local folder path for the checkout.",
    "C:\\workspace\\project",
    "SVN checkout revision",
    "Choose the SVN revision to checkout",
    "HEAD",
    "Checkout the latest repository revision",
    "Checkout a specific SVN revision",
    "Checkout SVN repository revision",
    "Enter the SVN revision number to checkout.",
    "SVN checkout depth",
    "Choose the SVN depth for checkout",
    "Checkout only the target directory metadata",
    "Checkout the target and its immediate file children",
    "Checkout the target and its immediate children",
    "Checkout the full subtree",
    "SVN checkout externals",
    "Skip SVN externals during checkout",
    "Allow libsvn to checkout SVN externals",
    "Enter an SVN repository URL without line breaks.",
    "Enter a valid SVN repository URL.",
    "Use an SVN URL with file, http, https, svn, or svn+<tunnel>.",
    "Enter SVN passwords through the credential prompt, not in the URL.",
    "Enter an absolute local folder path.",
    "Create SVN branch or tag",
    "Enter the SVN source URL for {0}.",
    "SVN branch or tag destination",
    "Enter the SVN destination URL.",
    "https://svn.example.com/project/branches/feature",
    "SVN branch or tag source revision",
    "Choose the SVN source revision",
    "Copy the latest repository revision",
    "Enter the SVN source revision number.",
    "SVN branch or tag log message",
    "Enter the SVN log message for the copy commit.",
    "Create branch",
    "Enter an SVN log message without carriage returns.",
    "Require destination parent",
    "Fail if the branch or tag parent URL does not exist",
    "Create destination parents",
    "Allow libsvn to create missing parent folders",
    "SVN branch or tag parents",
    "Choose how missing destination parents are handled",
    "SVN branch or tag externals",
    "Do not copy SVN externals",
    "Allow libsvn to include SVN externals",
    "Switch SVN working copy",
    "Enter the SVN URL to switch {0} to.",
    "SVN switch revision",
    "Choose the SVN revision to switch to",
    "Switch to the latest repository revision",
    "Enter the SVN revision number to switch to.",
    "Use a specific SVN revision",
    "SVN switch depth",
    "Choose the SVN depth for switch",
    "Switch only the target node",
    "Switch the target and its immediate file children",
    "Switch the target and its immediate children",
    "Switch the full subtree",
    "SVN switch sticky depth",
    "Choose whether switch changes the ambient depth",
    "SVN switch externals",
    "Skip SVN externals during switch",
    "Allow libsvn to switch SVN externals",
    "SVN switch ancestry",
    "Choose how SVN switch checks ancestry",
    "Check ancestry",
    "Require a shared SVN ancestry for switch",
    "Ignore ancestry",
    "Allow switch without checking SVN ancestry",
    "Merge SVN revision range",
    "Enter the SVN source URL to merge into {0}.",
    "SVN merge target path",
    "Enter the repository-relative target path.",
    "SVN merge start revision",
    "Enter the SVN revision where the merge range starts.",
    "SVN merge end revision",
    "Enter the SVN revision where the merge range ends.",
    "Enter different SVN start and end revisions for merge.",
    "Merge only the target node",
    "Merge the target and its immediate file children",
    "Merge the target and its immediate children",
    "Merge the full subtree",
    "SVN merge depth",
    "Choose the SVN depth for merge",
    "Apply merge",
    "Apply file and property changes during merge",
    "Record only",
    "Record mergeinfo without applying file changes",
    "SVN merge record-only mode",
    "Choose whether SVN merge changes files or only records mergeinfo",
    "Use mergeinfo",
    "Let libsvn skip revisions already recorded in mergeinfo",
    "Ignore mergeinfo",
    "Merge the requested revision range without mergeinfo filtering",
    "SVN mergeinfo filtering",
    "Choose whether SVN merge uses svn:mergeinfo to filter revisions",
    "Require shared SVN ancestry during merge",
    "Allow merge without checking SVN ancestry",
    "SVN merge ancestry",
    "Choose how SVN merge checks ancestry",
    "Require uniform revisions",
    "Reject merge targets with mixed working copy revisions",
    "Allow mixed revisions",
    "Allow merge targets with mixed working copy revisions",
    "SVN merge mixed revisions",
    "Choose whether SVN merge allows mixed working copy revisions",
    "Prevent forced deletes",
    "Reject merge deletes that require libsvn force-delete",
    "Allow forced deletes",
    "Allow libsvn force-delete behavior during merge",
    "SVN merge forced deletes",
    "Choose whether SVN merge can force deletes",
    "Merging SVN revision range",
    "Previewing SVN merge revision range",
    "SVN Merge Result: {0}",
    "SVN merge result for {0}",
    "SVN Merge Preview: {0}",
    "SVN merge preview for {0}",
    "SVN merge source URL",
    "SVN merge direction",
    "Additive merge",
    "Subtractive merge",
    "SVN status reconcile mode",
    "SVN status refresh target count",
    "Full reconcile",
    "Targeted status refresh",
    "No status refresh",
    "Affected SVN path count",
    "Skipped SVN path count",
    "SVN operation warning count",
    "SVN merge option",
    "SVN merge option value",
    "SVN merge dry run",
    "Affected SVN path",
    "No affected SVN paths.",
    "Skipped SVN path",
    "No skipped SVN paths.",
    "Skipped SVN path details unavailable.",
    "SVN operation warning",
    "SVN warning key",
    "SVN warning details",
    "SVN status refresh target",
    "SVN status refresh depth",
    "SVN status refresh reason",
    "Loading SVN mergeinfo",
    "SVN Mergeinfo: {0}",
    "SVN mergeinfo for {0}",
    "SVN mergeinfo path",
    "SVN property source",
    "SVN mergeinfo source path count",
    "SVN mergeinfo revision range count",
    "SVN mergeinfo unparsed revision range count",
    "SVN mergeinfo unparsed line count",
    "Source path",
    "SVN mergeinfo source revision range count",
    "Latest merged revision",
    "SVN mergeinfo non-inheritable range count",
    "SVN mergeinfo range start revision",
    "SVN mergeinfo range end revision",
    "Non-inheritable SVN mergeinfo range",
    "Revision ranges",
    "No parsed SVN mergeinfo source paths.",
    "Unparsed svn:mergeinfo revision range",
    "Unparsed svn:mergeinfo line",
    "Raw svn:mergeinfo",
    "Enter a repository-relative SVN path.",
    "Enter an SVN commit message for {0}.",
    "Enter a non-empty SVN commit message without carriage returns.",
    "Enter a non-empty SVN commit message without carriage returns and try again.",
    "The selected SVN changes changed while entering the commit message. Review the current changes and try again.",
    "The local OS username is unavailable, so SubversionR cannot record an author for this local SVN commit. Check the OS account and retry.",
    "No eligible SVN file changes to commit.",
    "Save SVN resource before committing: {0}",
    "SubversionR post-commit reconcile failed after revision {0}: {1}",
    "SubversionR backend ready. libsvn: {0}",
    "Select an SVN working copy",
    "Select an SVN repository",
    "Select an open SVN repository and try Show Repository Log again.",
    "The selected SVN repository session is no longer open. Select the current repository and try Show Repository Log again.",
    "The SVN report document is no longer available. Reopen the current repository and run the command again.",
    "The SVN report belongs to an older repository session. Run the command again to open the current report.",
    "SubversionR could not open the SVN report because its document address is invalid.",
    "SubversionR backend setting is required: {0}",
    "SubversionR packaged backend does not support this host: {0}/{1}.",
    "SubversionR packaged backend resource is missing: {0} for {1}.",
    "SubversionR packaged backend resource path is invalid: {0} for {1}.",
    "SubversionR backend executable path must be absolute.",
    "SubversionR bridge DLL path must be absolute.",
    "SubversionR backend protocol major version is unsupported: expected {0}, got {1}.",
    "SubversionR backend protocol version is too old: expected at least 1.{0}, got 1.{1}.",
    "SubversionR backend startup failed: {0}",
    "SubversionR backend startup failed.",
    "SVN backend",
    "SubversionR backend degraded: {0} ({1})",
    "Open SubversionR version report",
    "backend startup failed",
    "backend process terminated",
    "backend heartbeat failed",
    "backend protocol fault",
    "Open a workspace folder before opening an SVN repository.",
    "SubversionR opened SVN working copy: {0}",
    "SubversionR closed SVN working copy: {0}",
    "SubversionR closed missing SVN working copy: {0}",
    "SubversionR could not close missing SVN working copy {0}: {1}",
    "SubversionR could not check SVN working copy {0}: {1}",
    "Retry Close",
    "Retry Check",
    "Retry Recovery",
    "Retry Open",
    "SubversionR repository lifecycle retry failed: {0}",
    "SubversionR reopened moved SVN working copy: {0} -> {1}",
    "SubversionR could not recover moved SVN working copy {0}: {1}",
    "SubversionR could not mark SVN status stale after backend restart: {0}",
    "SubversionR could not acknowledge the Workspace Trust update: {0}",
    "SubversionR could not reopen SVN working copy after backend restart {0}: {1}",
    "SubversionR refreshed SVN working copy: {0}",
    "SubversionR completed full reconcile: {0}",
    "SubversionR refreshed SVN resource: {0}",
    "SubversionR added SVN resource: {0}",
    "SubversionR added {0} SVN resources: {1}",
    "SubversionR added SVN ignore rule for: {0}",
    "SubversionR added SVN ignore rules for {0} items: {1}",
    "SubversionR SVN ignore rules already include selected item(s).",
    "SubversionR removed SVN ignore rule for: {0}",
    "SubversionR removed SVN ignore rules for {0} items: {1}",
    "SubversionR SVN ignore rules did not include selected item(s).",
    "SubversionR set SVN property {0} on: {1}",
    "SubversionR deleted SVN property {0} from: {1}",
    "SubversionR updated svn:externals on: {0}",
    "SubversionR cleared svn:externals from: {0}",
    "No svn:externals property found on: {0}",
    "SubversionR assigned SVN changelist {0}: {1}",
    "SubversionR assigned SVN changelist {0} to {1} resources: {2}",
    "SubversionR cleared SVN changelist from: {0}",
    "SubversionR cleared SVN changelist from {0} resources: {1}",
    "SubversionR locked SVN resource: {0}",
    "SubversionR locked {0} SVN resources: {1}",
    "SubversionR unlocked SVN resource: {0}",
    "SubversionR unlocked {0} SVN resources: {1}",
    "SubversionR deleted unversioned SVN item: {0}",
    "SubversionR deleted {0} unversioned SVN items.",
    "No unversioned SVN items to delete.",
    "No SVN resources selected for commit.",
    "No eligible SVN file changes in changelist {0} to commit.",
    "SubversionR removed SVN resource but kept local item: {0}",
    "SubversionR removed {0} SVN resources but kept local items: {1}",
    "SubversionR moved SVN resource: {0} -> {1}",
    "SubversionR resolved SVN conflict with {0}: {1}",
    "SubversionR resolved {0} SVN conflicts with {1}: {2}",
    "SubversionR committed SVN resource at revision {0}: {1}",
    "SubversionR committed SVN resources at revision {0}: {1}",
    "SubversionR cleaned up SVN working copy: {0}",
    "SubversionR upgraded SVN working copy: {0}",
    "No incoming SVN changes: {0}",
    "SubversionR incoming SVN changes: {0} ({1})",
    "SubversionR updated SVN working copy to revision {0}: {1}",
    "SubversionR updated SVN resource to revision {0}: {1}",
    "SubversionR updated {0} incoming SVN resources: {1}",
    "No incoming SVN resources to update.",
    "Creating SVN branch or tag",
    "SubversionR created SVN branch/tag at revision {0}: {1}",
    "SubversionR created SVN branch/tag at revision {0} and switched working copy to revision {1}: {2}",
    "Switching SVN working copy",
    "SubversionR switched SVN working copy to revision {0}: {1}",
    "Stay on the current SVN URL",
    "Create the branch or tag without switching this working copy",
    "Switch this working copy to the new branch/tag",
    "Create the branch or tag, then switch this working copy to the destination URL",
    "SVN branch/tag switch",
    "Choose whether to switch after creating the branch or tag",
    "SubversionR merged SVN revision range r{0}:r{1} ({2}) from {3} into {4} at {5}: {6} affected SVN path(s), {7} skipped SVN path(s), {8} SVN operation warning(s)",
    "SubversionR previewed SVN merge range r{0}:r{1} ({2}) from {3} into {4} at {5}: {6} affected SVN path(s), {7} skipped SVN path(s), {8} SVN operation warning(s)",
    "No SVN mergeinfo found on working copy root: {0}",
    "No SVN mergeinfo found on SVN path: {0}",
    "SubversionR TortoiseSVN command failed: {0}",
    "Copied SVN commit message.",
    "Copied SVN revision number: {0}",
    "SubversionR removed SVN resource: {0}",
    "SubversionR removed {0} SVN resources: {1}",
    "Reverting SVN resources",
    "Reverting SVN changelist",
    "No eligible SVN resources to revert.",
    "SubversionR reverted SVN changelist {0}: {1}",
    "SubversionR reverted SVN resource: {0}",
    "SubversionR reverted {0} SVN resources: {1}",
    "No SVN working copy was found in the workspace.",
    "No SVN repository is open.",
    "Conflicts",
    "Changes",
    "Unversioned",
    "Incoming",
    "Externals",
    "Ignored",
    "Changelist: {0}",
    "SVN conflict",
    "SVN local change",
    "SVN working copy metadata",
    "SVN unversioned item",
    "SVN incoming change",
    "SVN external",
    "SVN ignored item",
    "SVN changed revision",
    "SVN changed author",
    "SVN changed date",
    "SVN switched node",
    "SVN copy from",
    "SVN move from",
    "SVN remote lock",
    "SVN lock owner",
    "SVN lock comment",
    "SVN lock created",
    "SVN lock expires",
    "SVN lock token",
    "SVN locked",
    "SVN needs lock",
    "SVN sparse depth",
    "Binary SVN BASE content is not displayed in the text editor.",
    "Incoming (stale)",
    "Incoming SVN result is stale",
    "SVN remote checking",
    "SVN remote check succeeded ({0})",
    "SVN remote recovery blocked",
    "SVN remote recovery required",
    "SVN remote recovery checking",
    "Configure SVN remote access",
    "SVN remote attention required",
    "SVN remote unreachable",
    "SVN remote check cancelled",
    "SVN remote check failed",
    "Recovering SVN remote operation state",
    "SubversionR remote recovery completed: {0}",
    "SubversionR remote recovery remains indeterminate: {0}",
    "Remote Access",
    "Configure Remote Access",
    "SubversionR remote access failed ({0}).",
  ];
}
