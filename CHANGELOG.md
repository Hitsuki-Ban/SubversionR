# Changelog

## 0.2.4

- Hides deferred Merge, preview, and mergeinfo entry points until their native workflows are implemented.
- Refines Source Control around three primary title actions, four overflow submenus, at most three resource-row actions, consistent SVN command naming, and no routine activation toast.
- Adds runtime Source Control count policies and a dedicated working-copy metadata group while preserving Lock and Unlock workflows.
- Strengthens installed VSIX UI evidence for command placement, accessibility, renderer output, and negative detail-accuracy cases.
- Retains the `hitsuki-ban.subversionr` identity, `SVN-R` Marketplace display name, Windows `win32-x64` pre-release channel, and existing public-readiness non-claim.
- Publishes the exact Windows package through the Visual Studio Marketplace pre-release channel and as the `v0.2.4-beta.1` GitHub pre-release, with live digest attestation and Gallery byte-continuity evidence.

## 0.2.3

- Activates organically when VS Code opens a working-copy root or a bounded ancestor path, with installed no-command activation evidence.
- Adds explicit on-demand remote status with truthful Incoming projection and result counts while keeping ordinary refreshes offline.
- Reports Update-created conflicts with warning severity, conflict counts, and bounded affected-path context after authoritative reconciliation.
- Preserves bounded symbolic libsvn failure chains through protocol 1.29, adds the redacted SubversionR log and actionable localized recovery notifications, and keeps failed commit message and Review Commit selection state.
- Retains the `hitsuki-ban.subversionr` identity, `SVN-R` Marketplace display name, Windows `win32-x64` pre-release channel, and existing public-claim boundary.
- Publishes the exact Windows package through the Visual Studio Marketplace pre-release channel and as the `v0.2.3-beta.1` GitHub pre-release, with live digest attestation and Gallery byte-continuity evidence.

## 0.2.2

- Includes all product content introduced in 0.2.1.
- Aligns the Marketplace display name with the existing `hitsuki-ban.subversionr` listing as `SVN-R` while retaining SubversionR as the product and brand name.
- Avoids the permanently reserved `SubversionR` Marketplace name left by a deleted pre-governance extension.
- Publishes the Windows `win32-x64` package through the Visual Studio Marketplace pre-release channel and as the `v0.2.2-beta.1` GitHub pre-release.
- Keeps the extension identity, command identities, pre-release packaging, and public claim boundary unchanged.

## 0.2.1

- Includes all product content introduced in 0.2.0.
- Packages the dedicated Marketplace listing README from `packages/vscode-extension/README.md`.
- Marks the VSIX as a VS Code pre-release package at creation time.
- Normalizes VSIX ZIP timestamps and entry ordering so identical inputs produce identical package bytes.
- Keeps the `hitsuki-ban.subversionr` extension identity and `subversionr.*` command identities unchanged.

## 0.2.0

- Publishes under the public `hitsuki-ban.subversionr` extension identity. This is a new extension id, so 0.1.0 test installs are replaced by installing the new VSIX rather than upgraded in place.
- Renames all command IDs from `svn-r.*` to `subversionr.*`. Keybindings or tasks that referenced old command IDs must be updated; there are no compatibility aliases.
- Adds changelist breadth: revert, remove, move, commit, and inspect resources by changelist, plus changelist context on SVN Lens surfaces.
- Adds property editing commands, repository properties, and an `svn:externals` edit workflow.
- Adds Review & Commit with filter facets, a commit message history picker, and an explicit remote changes check command.
- Adds working-copy onboarding improvements: checkout target suggestions from repository URLs, custom tunnel checkout URLs, and clearer checkout failure handling.
- Adds credential management: additional SVN credential prompt kinds, session credential caching, and a command to clear saved credentials.
- Adds repository maintenance workflows: relocate, working copy upgrade, explicit cleanup options, recursive add for unversioned directories, directory property commits, and update-all-incoming.
- Adds branch switch-after-create and a TortoiseSVN repository browser entry point.
- Respects merged revision history in blame documents, current-line blame, symbol lenses, and line history.
- Expands lock, metadata, and incoming tooltips plus editor/repository context menu coverage.

## 0.1.0

- Initial Windows `win32-x64` test release.
- Supports local SVN working-copy operations in VS Code Source Control.
- Supports checkout, open, status, add, remove, move, revert, resolve, update, commit, delete unversioned files, properties, `svn:ignore`, changelists, lock/unlock, branch/tag creation, and switch.
- Merge, merge preview, mergeinfo, Marketplace installation, signing, and cross-platform packages are not included.
