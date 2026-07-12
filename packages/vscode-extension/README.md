# SubversionR

SubversionR brings native Apache Subversion (SVN) source control to Visual Studio Code through a bundled Rust sidecar and `libsvn`. It does not require the `svn` command-line client or TortoiseSVN for its core workflows.

## Beta scope

The current Beta claim is limited to local VS Code workspaces on Windows x64 (`win32-x64`) with SVN working copies backed by local `file://` repositories. Core local working-copy operations are available through the Source Control view and SubversionR commands.

Arbitrary remote SVN servers and authentication environments, remote VS Code workspaces, other operating systems and architectures, merge workflows, and stable-release readiness are outside the current claim. See the [public claim matrix](https://github.com/Hitsuki-Ban/SubversionR/blob/main/docs/release/public-claim-matrix.md) for the exact boundary.

## Install and update the pre-release

In the VS Code Extensions view, search for `@id:hitsuki-ban.subversionr`, open **SVN-R**, use the Install button dropdown, and select **Install Pre-Release Version**. VS Code updates enabled extensions automatically when extension auto-update is enabled; select **Update** on the extension page to install an available update immediately.

Pre-release versions may change between updates. Check the release notes before updating a working environment.

## Support and security

For bugs and support requests, use [GitHub Issues](https://github.com/Hitsuki-Ban/SubversionR/issues) and follow the [support guide](https://github.com/Hitsuki-Ban/SubversionR/blob/main/SUPPORT.md). Do not report vulnerabilities in a public issue; follow the [security policy](https://github.com/Hitsuki-Ban/SubversionR/security/policy) instead.
