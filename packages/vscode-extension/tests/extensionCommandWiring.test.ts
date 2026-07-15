import * as nodeFs from "node:fs";
import * as nodePath from "node:path";
import { describe, expect, it } from "vitest";

describe("extension command wiring", () => {
  it("passes SCM title repository command arguments to repository commands", () => {
    const extensionSource = readExtensionSource();

    expect(extensionSource).toMatch(
      /registerCommand\("subversionr\.closeRepository",\s*\(commandArgument\?: unknown\) =>\s*repositoryLifecycleCoordinator\.runExclusive\("manualClose",\s*\(\) =>\s*repositoryCommandController\.closeRepository\(\s*commitAllRepositoryIdArgument\(commandArgument, sourceControlRepositoryIds\),\s*\),\s*\),\s*\)/su,
    );
    expect(extensionSource).toMatch(
      /registerCommand\("subversionr\.refreshRepository",\s*\(commandArgument\?: unknown\) =>\s*repositoryCommandController\.refreshRepository\(\s*commitAllRepositoryIdArgument\(commandArgument, sourceControlRepositoryIds\),\s*\),\s*\)/su,
    );
    expect(extensionSource).toMatch(
      /registerCommand\("subversionr\.checkRemoteChanges",\s*\(commandArgument\?: unknown\) =>\s*repositoryCommandController\.checkRemoteChanges\(\s*commitAllRepositoryIdArgument\(commandArgument, sourceControlRepositoryIds\),\s*\),\s*\)/su,
    );
    expect(extensionSource).toMatch(
      /registerCommand\("subversionr\.reviewCommit",\s*\(commandArgument\?: unknown\) =>\s*repositoryCommandController\.reviewCommit\(\s*commitAllRepositoryIdArgument\(commandArgument, sourceControlRepositoryIds\),\s*\),\s*\)/su,
    );
    expect(extensionSource).toMatch(
      /registerCommand\("subversionr\.pickCommitMessageHistory",\s*\(commandArgument\?: unknown\) =>\s*repositoryCommandController\.pickCommitMessageHistory\(\s*commitAllRepositoryIdArgument\(commandArgument, sourceControlRepositoryIds\),\s*\),\s*\)/su,
    );
    expect(extensionSource).toMatch(
      /registerCommand\("subversionr\.setResourceProperty",\s*\(\.\.\.resourceStates: unknown\[\]\) =>\s*repositoryCommandController\.setResourceProperty\(\.\.\.resourceStates\),\s*\)/su,
    );
    expect(extensionSource).toMatch(
      /registerCommand\("subversionr\.deleteResourceProperty",\s*\(\.\.\.resourceStates: unknown\[\]\) =>\s*repositoryCommandController\.deleteResourceProperty\(\.\.\.resourceStates\),\s*\)/su,
    );
    expect(extensionSource).toMatch(
      /registerCommand\("subversionr\.editRepositoryExternals",\s*\(commandArgument\?: unknown\) =>\s*repositoryCommandController\.editRepositoryExternals\(\s*commitAllRepositoryIdArgument\(commandArgument, sourceControlRepositoryIds\),\s*\),\s*\)/su,
    );
    expect(extensionSource).toMatch(
      /registerCommand\("subversionr\.editResourceExternals",\s*\(\.\.\.resourceStates: unknown\[\]\) =>\s*repositoryCommandController\.editResourceExternals\(\.\.\.resourceStates\),\s*\)/su,
    );
    expect(extensionSource).toMatch(
      /registerCommand\("subversionr\.fullReconcile",\s*\(commandArgument\?: unknown\) =>\s*repositoryCommandController\.fullReconcileRepository\(\s*commitAllRepositoryIdArgument\(commandArgument, sourceControlRepositoryIds\),\s*\),\s*\)/su,
    );
    expect(extensionSource).toMatch(
      /registerCommand\("subversionr\.cleanupRepository",\s*\(commandArgument\?: unknown\) =>\s*repositoryCommandController\.cleanupRepository\(\s*commitAllRepositoryIdArgument\(commandArgument, sourceControlRepositoryIds\),\s*\),\s*\)/su,
    );
    expect(extensionSource).toMatch(
      /registerCommand\("subversionr\.upgradeWorkingCopy",\s*\(commandArgument\?: unknown\) =>\s*repositoryCommandController\.upgradeWorkingCopy\(\s*commitAllRepositoryIdArgument\(commandArgument, sourceControlRepositoryIds\),\s*\),\s*\)/su,
    );
    expect(extensionSource).toMatch(
      /registerCommand\("subversionr\.updateRepository",\s*\(commandArgument\?: unknown\) =>\s*repositoryCommandController\.updateRepository\(\s*commitAllRepositoryIdArgument\(commandArgument, sourceControlRepositoryIds\),\s*\),\s*\)/su,
    );
    expect(extensionSource).toMatch(
      /registerCommand\("subversionr\.updateToRevision",\s*\(commandArgument\?: unknown\) =>\s*repositoryCommandController\.updateToRevision\(\s*commitAllRepositoryIdArgument\(commandArgument, sourceControlRepositoryIds\),\s*\),\s*\)/su,
    );
    expect(extensionSource).toMatch(
      /registerCommand\("subversionr\.branchCreateRepository",\s*\(commandArgument\?: unknown\) =>\s*repositoryCommandController\.branchCreateRepository\(\s*commitAllRepositoryIdArgument\(commandArgument, sourceControlRepositoryIds\),\s*\),\s*\)/su,
    );
    expect(extensionSource).toMatch(
      /registerCommand\("subversionr\.switchRepository",\s*\(commandArgument\?: unknown\) =>\s*repositoryCommandController\.switchRepository\(\s*commitAllRepositoryIdArgument\(commandArgument, sourceControlRepositoryIds\),\s*\),\s*\)/su,
    );
    expect(extensionSource).toMatch(
      /registerCommand\("subversionr\.relocateRepository",\s*\(commandArgument\?: unknown\) =>\s*repositoryCommandController\.relocateRepository\(\s*commitAllRepositoryIdArgument\(commandArgument, sourceControlRepositoryIds\),\s*\),\s*\)/su,
    );
    expect(extensionSource).toMatch(
      /registerCommand\("subversionr\.mergeRangeRepository",\s*\(commandArgument\?: unknown\) =>\s*repositoryCommandController\.mergeRangeRepository\(\s*commitAllRepositoryIdArgument\(commandArgument, sourceControlRepositoryIds\),\s*\),\s*\)/su,
    );
    expect(extensionSource).toMatch(
      /registerCommand\("subversionr\.previewMergeRangeRepository",\s*\(commandArgument\?: unknown\) =>\s*repositoryCommandController\.previewMergeRangeRepository\(\s*commitAllRepositoryIdArgument\(commandArgument, sourceControlRepositoryIds\),\s*\),\s*\)/su,
    );
    expect(extensionSource).toMatch(
      /registerCommand\("subversionr\.showRepositoryMergeinfo",\s*\(commandArgument\?: unknown\) =>\s*repositoryCommandController\.showRepositoryMergeinfo\(\s*commitAllRepositoryIdArgument\(commandArgument, sourceControlRepositoryIds\),\s*\),\s*\)/su,
    );
    expect(extensionSource).toMatch(
      /registerCommand\("subversionr\.showRepositoryProperties",\s*\(commandArgument\?: unknown\) =>\s*repositoryCommandController\.showRepositoryProperties\(\s*commitAllRepositoryIdArgument\(commandArgument, sourceControlRepositoryIds\),\s*\),\s*\)/su,
    );
    expect(extensionSource).toMatch(
      /registerCommand\("subversionr\.showRepositoryLog",\s*\(commandArgument\?: unknown\) =>\s*repositoryCommandController\.showRepositoryLog\(\s*repositoryHistoryCommandArgument\(commandArgument, sourceControlRepositoryHistoryTargets\),\s*\),\s*\)/su,
    );
    expect(extensionSource).toMatch(
      /registerCommand\(\s*"subversionr\.tortoise\.openRepositoryLog",\s*\(commandArgument\?: unknown\) =>\s*tortoiseCommandController\.openRepositoryLog\(\s*commitAllRepositoryIdArgument\(commandArgument, sourceControlRepositoryIds\),\s*\),\s*\)/su,
    );
    expect(extensionSource).toMatch(
      /registerCommand\(\s*"subversionr\.tortoise\.openRevisionGraph",\s*\(commandArgument\?: unknown\) =>\s*tortoiseCommandController\.openRepositoryRevisionGraph\(\s*commitAllRepositoryIdArgument\(commandArgument, sourceControlRepositoryIds\),\s*\),\s*\)/su,
    );
    expect(extensionSource).toMatch(
      /registerCommand\(\s*"subversionr\.tortoise\.openRepositoryBrowser",\s*\(commandArgument\?: unknown\) =>\s*tortoiseCommandController\.openRepositoryBrowser\(\s*commitAllRepositoryIdArgument\(commandArgument, sourceControlRepositoryIds\),\s*\),\s*\)/su,
    );
  });

  it("wires history merged-revision settings into symbol history CodeLens blame requests", () => {
    const extensionSource = readExtensionSource();

    expect(extensionSource).toMatch(
      /new SymbolHistoryCodeLensProvider<vscode\.CodeLens>\(\{\s*settings: \(\) => lensSettings,\s*includeMergedRevisions: \(\) => historySettings\.includeMergedRevisions,\s*historyClient,/su,
    );
  });

  it("refreshes the SCM Repository Log target when a repository session advances epoch", () => {
    const extensionSource = readExtensionSource();

    expect(extensionSource).toMatch(
      /updateSourceControlRepositorySession:\s*\(sourceControl, repositoryId, epoch\) => \{\s*sourceControlRepositoryHistoryTargets\.set\(\s*sourceControl,\s*repositoryHistoryCommandTarget\(repositoryId, epoch\),\s*\);\s*\}/su,
    );
  });

  it("makes Review and Commit QuickPick filterable by review facets", () => {
    const extensionSource = readExtensionSource();

    expect(extensionSource).toContain("reviewCommitTargetDescription(target)");
    expect(extensionSource).toContain("reviewCommitTargetDetail(target)");
    expect(extensionSource).toContain("matchOnDescription: true");
    expect(extensionSource).toContain("matchOnDetail: true");
  });

  it("uses an SVN URL and workspace-derived default for the checkout target prompt", () => {
    const extensionSource = readExtensionSource();

    expect(extensionSource).toMatch(
      /value: suggestedCheckoutTargetPath\(\s*url,\s*\(vscode\.workspace\.workspaceFolders \?\? \[\]\)\.map\(\(folder\) => folder\.uri\.fsPath\),\s*\),/su,
    );
  });

  it("wires history merged-revision settings into explicit blame documents", () => {
    const extensionSource = readExtensionSource();

    expect(extensionSource).toMatch(
      /new RepositoryCommandController\(\{[\s\S]*?historyClient,[\s\S]*?includeMergedRevisions: \(\) => historySettings\.includeMergedRevisions,[\s\S]*?ui:/u,
    );
  });

  it("wires history merged-revision settings into current-line blame requests", () => {
    const extensionSource = readExtensionSource();

    expect(extensionSource).toMatch(
      /new CurrentLineBlameHoverProvider<vscode\.Hover, vscode\.MarkdownString>\(\{\s*settings: \(\) => lensSettings,\s*includeMergedRevisions: \(\) => historySettings\.includeMergedRevisions,\s*historyClient,/su,
    );
    expect(extensionSource).toMatch(
      /new CurrentLineBlameStatusBarService\(\{\s*settings: \(\) => lensSettings,\s*includeMergedRevisions: \(\) => historySettings\.includeMergedRevisions,\s*historyClient,/su,
    );
  });

  it("registers the clear saved credentials command through the credential controller", () => {
    const extensionSource = readExtensionSource();

    expect(extensionSource).toMatch(
      /registerCommand\("subversionr\.credentials\.clearSaved",\s*async \(\) =>\s*clearSavedCredentials\(credentialController\),\s*\)/su,
    );
    expect(extensionSource).toMatch(/clearSavedCredentialsCommand,/u);
  });

  it("refreshes history settings at runtime when the history configuration changes", () => {
    const extensionSource = readExtensionSource();

    expect(extensionSource).toMatch(/let historySettings = readHistorySettings\(configuration\);/u);
    expect(extensionSource).toMatch(
      /const historyConfigurationChange = vscode\.workspace\.onDidChangeConfiguration\(\(event\) => \{\s*if \(event\.affectsConfiguration\("subversionr\.history"\)\) \{\s*historySettings = readHistorySettings\(vscode\.workspace\.getConfiguration\("subversionr"\)\);\s*void runHistoryCommand\(\(\) => historyTreeDataProvider\.updateSettings\(historySettings\)\);\s*symbolHistoryCodeLensProvider\.refresh\(\);\s*refreshCurrentLineBlame\(\);\s*\}\s*\}\);/su,
    );
    expect(extensionSource).toMatch(/historyConfigurationChange,/u);
  });
});

function readExtensionSource(): string {
  return nodeFs.readFileSync(nodePath.resolve(__dirname, "../src/extension.ts"), "utf8");
}
