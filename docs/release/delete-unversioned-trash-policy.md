# Delete Unversioned Trash Policy

Requirement: `OPS-004`

## Policy

`subversionr.deleteUnversionedResource` and `subversionr.deleteAllUnversionedResources` permanently delete selected unversioned SVN items after explicit modal confirmation. The confirmation text must state `This cannot be undone`.

The VS Code adapter must call `vscode.workspace.fs.delete` with explicit options:

```ts
{ recursive: options.recursive, useTrash: false }
```

No trash-mode fallback is allowed. Missing or unavailable platform trash support must not silently change Delete Unversioned semantics.

## Rationale

Unversioned items are not scheduled SVN nodes, so Delete Unversioned does not call libsvn, the SVN CLI, or TortoiseSVN for deletion. The command removes only local filesystem items proven by the current SourceControl projection to be unversioned files or directories, then runs targeted status refresh so libsvn-backed status confirms the resulting working-copy projection.

Using `useTrash: false` keeps the product contract aligned with the confirmation copy and avoids platform-dependent recycle-bin behavior in release evidence. A future trash-mode command would need a separate requirement, distinct command wording, tests, localization, diagnostics, and release evidence.

## Release Evidence

- `packages/vscode-extension/src/extension.ts` contains the adapter call to `vscode.workspace.fs.delete(..., { recursive: options.recursive, useTrash: false })`.
- `packages/vscode-extension/src/repository/repositoryCommandController.ts` validates the projected unversioned target and requests recursive deletion only for projected directories.
- `packages/vscode-extension/tests/repositoryCommandController.test.ts` covers file deletion, recursive directory deletion, multi-select deletion, delete-all, cancellation, stale projection rejection, and targeted refresh.
- `scripts/release/test-vscode-installed-source-control-ui-e2e.ps1` executes the installed `subversionr.deleteUnversionedResource` command, captures and clicks the VS Code Delete confirmation, and verifies the fixture file is gone from both filesystem and SourceControl projection.
