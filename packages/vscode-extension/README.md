# SubversionR

SubversionR brings native Apache Subversion (SVN) source control to Visual Studio Code through a bundled Rust sidecar and `libsvn`. It does not require the `svn` command-line client or TortoiseSVN for its core workflows.

## Beta scope

The current Beta claim is limited to local VS Code workspaces on Windows x64 (`win32-x64`) with SVN working copies backed by local `file://` repositories. Core local working-copy operations are available through the Source Control view and SubversionR commands.

Arbitrary remote SVN servers and authentication environments, remote VS Code workspaces, other operating systems and architectures, merge workflows, and stable-release readiness are outside the current claim. See the [public claim matrix](https://github.com/Hitsuki-Ban/SubversionR/blob/main/docs/release/public-claim-matrix.md) for the exact boundary.

## Install and update the pre-release

In the VS Code Extensions view, search for `@id:hitsuki-ban.subversionr`, open **SVN-R**, use the Install button dropdown, and select **Install Pre-Release Version**. VS Code updates enabled extensions automatically when extension auto-update is enabled; select **Update** on the extension page to install an available update immediately.

Pre-release versions may change between updates. Check the release notes before updating a working environment.

## 0.2.5 pre-release highlights

- Repository Log now targets the active working copy deterministically and reveals the focused SVN History view.
- Empty commit messages open a prompt, including Review and Commit without losing the reviewed selection.
- Local `file://` commits record the operating-system username as `svn:author`.
- Initialize, Lock, and Unlock settle deterministically, and active-editor diff, history, and blame commands are available from the Command Palette.
- Property reports reuse read-only editor tabs, while libsvn conflict artifacts appear in a dedicated read-only Source Control group.

The 0.2.5 pre-release keeps the existing Windows x64, local file-backed Beta boundary. It does not add stable-channel, cross-platform, broad remote/authentication, merge, signing, public-install verification, previous-stable rollback, or overall public-readiness claims.

## Support and security

For bugs and support requests, use [GitHub Issues](https://github.com/Hitsuki-Ban/SubversionR/issues) and follow the [support guide](https://github.com/Hitsuki-Ban/SubversionR/blob/main/SUPPORT.md). Do not report vulnerabilities in a public issue; follow the [security policy](https://github.com/Hitsuki-Ban/SubversionR/security/policy) instead.
