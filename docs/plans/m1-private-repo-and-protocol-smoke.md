# M1 Private Repo And Protocol Smoke Plan

## Goal

Establish a private but publishable repository with a real Apache Subversion source gate, a hand-written bridge boundary, and protocol smoke tests across Rust and TypeScript.

## Gates

- Environment tools are verified from the current shell.
- Apache Subversion 1.14.5 source archive verifies against SHA512 and PGP signature.
- Locked native dependency archives verify through `scripts/native/verify-sources.ps1`.
- The Windows dependency stage builds through `scripts/native/build-dependencies.ps1 -Only all`.
- The Apache HTTP Server DAV fixture substrate builds through `scripts/native/build-httpd.ps1` against the explicit Windows dependency stage.
- Apache Subversion 1.14.5 Windows `__ALL__` builds run through `scripts/native/build-subversion.ps1` with explicit APR, APR-util, APR-iconv, SQLite, zlib, Serf, and OpenSSL roots.
- The source-built `mod_dav_svn` and `mod_authz_svn` Apache modules build through `scripts/native/build-subversion-dav-modules.ps1`, stage into a separate composite httpd/Subversion DAV runtime, and pass a load-only `httpd.exe -M`/`-t` probe.
- The native bridge builds through `scripts/native/build-bridge.ps1` against a verified staged Subversion prefix.
- The native bridge smoke test compiles a temporary C caller and verifies that `subversionr_bridge_version` reports Apache Subversion `1.14.5`.
- Rust native bridge integration tests load the built bridge DLL, report libsvn `1.14.5`, create a local repository/working-copy fixture with the staged `svnadmin.exe` and `svn.exe`, and verify `repository/open` through the C ABI.
- Rust protocol and sidecar tests pass.
- TypeScript extension checks and tests pass.
- Windows CI runs the same checks.

## Native Build Inputs

`build-subversion.ps1` intentionally requires dependency roots. It does not search system library paths and does not load TortoiseSVN or a system `svn` installation. The first M1 dependency set is locked in `native/sources.lock.json`:

- APR 1.7.6.
- APR-util 1.6.3.
- APR-iconv 1.2.2, required on Windows because the generated `__LIBS__` graph includes the `apriconv` library edge through APR-util.
- Expat 2.8.1, staged as APR-util's XML parser.
- SQLite amalgamation 3.53.2.
- zlib 1.3.2.
- OpenSSL 3.5.7.
- Apache Serf 1.3.10.

M6q locks Serf 1.3.10 and OpenSSL 3.5.7, M6r builds and stages them with a Serf/OpenSSL link probe, M6s wires them into the Apache Subversion Windows generator, and M6t adds the first source-built libsvn/ra_serf HTTPS certificate-callback fixture. They are now required Subversion generator inputs and stage-manifest dependencies; OpenSSL runtime DLLs are copied beside the bridge because `libsvn_ra-1.dll` depends on them, while Serf remains static RA build evidence on the current Windows path. M6z adds the first successful localhost SVN-over-HTTPS DAV content/update fixture against source-built Apache httpd/mod_dav_svn, but this still does not claim product-level support for arbitrary HTTPS repositories.

Windows CI targets the `windows-2022` runner image for the M1 gate because the first supported MSVC baseline is Visual Studio 2022. The workflow installs CMake 4.3.4 from Kitware's official Windows x64 ZIP and NASM 3.01 from the official NASM Windows x64 ZIP, verifies archive SHA256 values before adding those tools to `PATH`, locates Visual Studio 2022 with `vswhere`, and passes the resolved `VsDevCmd.bat` path explicitly to native build scripts. Local development requires CMake 4.3 or newer, NASM on `PATH` for the OpenSSL Windows build, and must set `SUBVERSIONR_VSDEVCMD` before running native package scripts.

`build-dependencies.ps1 -Only all` rebuilds `.cache/native/work/deps` and stages these dependencies under `.cache/native/stage/subversion-deps-win-x64` with `include`, `lib`, and `bin` subdirectories. SQLite is compiled from the amalgamation with MSVC, zlib is built with its upstream `win32/Makefile.msc`, Expat is built with CMake and installed as `libexpat`, PCRE2 is built with CMake as a static 8-bit package for the future Apache httpd fixture track, APR/APR-util/APR-iconv are built from the required parallel source layout through APR-util's Windows makefile, OpenSSL is built with its upstream MSVC `nmake` flow, and Serf is built with SCons against the staged APR, zlib, and OpenSSL inputs. The APR stage also carries the exact private headers required by Apache HTTP Server's Windows build path. The script removes stale generated work and stage directories before building, and refuses to recursively remove paths outside repository generated roots.

`build-httpd.ps1` rebuilds `.cache/native/work/httpd` and stages Apache HTTP Server under `.cache/native/stage/httpd-win-x64`. It consumes only the explicit `.cache/native/stage/subversion-deps-win-x64` dependency stage, binds CMake to staged APR, static PCRE2, OpenSSL, and zlib, copies required APR/Expat/OpenSSL runtime DLLs beside `httpd.exe`, writes `subversionr-httpd-stage-manifest.json`, and verifies `httpd.exe -V` plus `httpd.exe -t`. This gate proves the httpd core/DAV/SSL/deflate substrate only and intentionally rejects `mod_dav_svn` and `mod_authz_svn`.

`build-subversion-dav-modules.ps1` rebuilds a clean Apache Subversion 1.14.5 source tree with `--with-httpd` pointing at the verified substrate, validates the generated `mod_dav_svn` and `mod_authz_svn` MSBuild project graph, builds the module project directly, and stages a separate `.cache/native/stage/httpd-subversion-dav-win-x64` composite runtime. The composite stage carries its own `subversionr-httpd-subversion-dav-stage-manifest.json`, copies the required libsvn DAV runtime DLL closure beside `httpd.exe`, and runs a load-only `httpd.exe -M` plus `httpd.exe -t` probe. M6z now consumes that stage in a localhost HTTPS DAV fixture smoke that proves bridge HEAD content and update flows through libsvn/ra_serf and the certificate broker.

LZ4 and utf8proc are consumed from the Apache Subversion 1.14.5 source tree by its Windows generator. The first Subversion build target is `__ALL__`, so the same verified source build produces both the libsvn DLL/import-library closure and the `svn`/`svnadmin` fixture tools used by integration tests.

The Apache Subversion 1.14.5 Windows generator only models Visual Studio versions through 2019. On VS 2022, `build-subversion.ps1` verifies the locked source archive, re-extracts a clean source tree, keeps `--vsnet-version=2019`, passes the staged Serf and OpenSSL prefixes through `--with-serf` and `--with-openssl`, patches the generator's Expat version regex for Expat 2.7.2+ header spacing, then retargets generated `.vcxproj` files from `v142` to `v143` before invoking MSBuild. This retarget is explicit, tested, and fails fast if generated project files or expected `PlatformToolset` entries are missing.

The bridge build expects a staged native prefix:

- `include/subversion-1`
- APR and APR-util headers
- `lib`
- `bin`

`build-subversion.ps1` stages this prefix under `.cache/native/stage/subversion-win-x64` after the `__ALL__` build. The stage includes public Subversion headers, the DLL import libraries used by the bridge, the source-built `libsvn_ra_serf-1.lib` static RA target, the runtime DLL closure needed beside `subversionr_svn_bridge.dll`, APR iconv runtime modules, the fixture `svn.exe`, `svnadmin.exe`, and `svnserve.exe` tools, and `subversionr-stage-manifest.json` with the locked Apache Subversion source and dependency versions/checksums. On Windows, Apache Subversion 1.14.5 links the `libsvn_ra_serf` static target into `libsvn_ra-1.dll`; the build gate checks the generated MSBuild project graph for that static target, the `libsvn_ra` DLL project reference, and Serf/OpenSSL link inputs, then uses staged `svn.exe --version` only as the `ra_serf` registration probe for the `http` and `https` schemes.

`build-bridge.ps1` validates the staged prefix, manifest, version header, and expected architecture/configuration before entering the Visual Studio toolchain, rebuilds its own generated target directory, links only against the `libsvn_*-1.lib` DLL import libraries, and copies the staged runtime DLLs into the bridge output directory. `smoke-bridge.ps1` then compiles a temporary caller against `subversionr_svn_bridge.lib` and runs it with the bridge output directory on `PATH`.

Staging is explicit work. The bridge must not discover random system libraries.
