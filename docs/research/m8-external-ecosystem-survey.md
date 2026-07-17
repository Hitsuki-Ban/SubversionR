# M8 external ecosystem survey: remote access and authentication

Status: independent public-source research

Evidence snapshot: 2026-07-18

Scope: remote Subversion access, authentication, Windows SSH practice, VS Code integration, and test infrastructure

## Executive conclusions

1. The public VS Code Subversion market is overwhelmingly represented by CLI adapters, not by maintained native-libsvn integrations. In the 2026-07-18 Marketplace snapshot, JohnstonCode SVN was the only extension above one million installs, but its last Marketplace release was in June 2023 and it requires a separately installed command-line client. The two more recently updated extensions found in the same search also describe themselves as command-line bridges. This is an opportunity for SubversionR, but not evidence that remote access is easy: authentication, prompt coordination, certificates, SSH tunnels, and background scheduling are the differentiators.
2. Public issue evidence clusters around prompt timing, repeated credential requests, externals, SSH agents/passphrases, misleading errors, and background network activity. The safe product model is a typed challenge broker: libsvn remains authoritative, the Rust sidecar reports structured challenges, the VS Code layer owns interaction and secret storage, and background work never prompts.
3. There is no defensible public data set that ranks all Subversion server products by deployment share. The practical 2023–2026 ecosystem is nevertheless clear enough to test by deployment archetype: VisualSVN Server on Windows, Apache HTTP Server plus mod_dav_svn on Linux, svnserve (plain or SASL), svn+ssh, and hosted HTTPS services. Evidence tiers in this report deliberately separate vendor reach signals from measured prevalence.
4. Windows svn+ssh must expose OpenSSH and Plink as distinct, explicit adapters. Their agent, host-key, prompt, command-line, and noninteractive modes are different. Autodetection, silent switching, and arbitrary tunnel command strings would create both support ambiguity and a code-execution boundary.
5. VS Code's built-in Git extension is useful architectural prior art for an out-of-process askpass bridge, but it is not a reusable public API and its short authority-keyed cache is not an adequate SVN realm model. VS Code SecretStorage fits realm-scoped secrets better than AuthenticationProvider. The SCM history provider API remains proposed, so Marketplace code should not depend on it.
6. Release evidence should come primarily from controlled local servers. Source-built svnserve and Apache fixtures can cover most transports in CI. VisualSVN Community can cover a Windows product deployment but not Integrated Windows Authentication; Kerberos/NTLM needs a private domain-joined lab. Public hosted services should be optional read-only canaries only when their terms explicitly permit automation.

## Method and evidence labels

This survey used only public upstream repositories, vendor documentation, official VS Code sources/documentation, public Marketplace data, and documented local observations. Dynamic facts are dated because install counts, repository activity, package versions, and download counters change.

Evidence labels used below:

- **Source-derived**: behavior stated by official documentation or visible in upstream source.
- **Public demand signal**: a public issue report. Comment counts indicate discussion volume, not unique users, votes, or severity. Cases can overlap and must not be summed as market size.
- **Observed snapshot**: a dated API, repository metadata, download counter, or local-machine observation.
- **Inference**: a design conclusion drawn from the cited evidence, explicitly identified as such.
- **Evidence gap**: the public search did not provide a strong direct signal. It does not mean that the need is absent.

Marketplace results were obtained on 2026-07-18 through the official Gallery extension-query endpoint, <https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery>, using the search term “svn”. Public competitor issues were sampled through reproducible GitHub searches for authentication/credentials, externals, offline/network failures, proxy, certificates, SSH, remote/background refresh, multiple repositories/realms, and errors. Representative issue links are given in the taxonomy rather than treating search hits as a statistically complete sample.

For reproducibility, the focused searches included [authentication and credentials](https://github.com/JohnstonCode/svn-scm/issues?q=is%3Aissue%20auth%20OR%20authentication%20OR%20password%20OR%20credential%20OR%20username%20OR%20login), [externals](https://github.com/JohnstonCode/svn-scm/issues?q=is%3Aissue%20externals), [offline and network failures](https://github.com/JohnstonCode/svn-scm/issues?q=is%3Aissue%20offline%20OR%20unreachable%20OR%20timeout%20OR%20network), [proxy](https://github.com/JohnstonCode/svn-scm/issues?q=is%3Aissue%20proxy), [certificate/TLS](https://github.com/JohnstonCode/svn-scm/issues?q=is%3Aissue%20certificate%20OR%20SSL%20OR%20TLS), [SSH](https://github.com/JohnstonCode/svn-scm/issues?q=is%3Aissue%20SSH%20OR%20plink%20OR%20svn%2Bssh), and [remote/background refresh](https://github.com/JohnstonCode/svn-scm/issues?q=is%3Aissue%20remoteChanges%20OR%20background%20OR%20polling). Snapshot discussion volumes illustrate concentration but are not additive demand counts:

| Signal group | Representative issue comment counts observed 2026-07-18 |
| --- | --- |
| Prompt/authentication | [#89](https://github.com/JohnstonCode/svn-scm/issues/89): 40; [#849](https://github.com/JohnstonCode/svn-scm/issues/849): 7; [#219](https://github.com/JohnstonCode/svn-scm/issues/219): 8 |
| Repeated prompt / persistence | [#552](https://github.com/JohnstonCode/svn-scm/issues/552): 16; [#652](https://github.com/JohnstonCode/svn-scm/issues/652): 13; [#1601](https://github.com/JohnstonCode/svn-scm/issues/1601): 6; [#1383](https://github.com/JohnstonCode/svn-scm/issues/1383): 3 |
| Externals | [#629](https://github.com/JohnstonCode/svn-scm/issues/629): 7; [#1608](https://github.com/JohnstonCode/svn-scm/issues/1608): 0 |
| Offline / unreachable | [#365](https://github.com/JohnstonCode/svn-scm/issues/365): 21; [#462](https://github.com/JohnstonCode/svn-scm/issues/462): 7; [#1644](https://github.com/JohnstonCode/svn-scm/issues/1644): 1 |
| SSH | [#893](https://github.com/JohnstonCode/svn-scm/issues/893): 23; [#263](https://github.com/JohnstonCode/svn-scm/issues/263): 8; [#927](https://github.com/JohnstonCode/svn-scm/issues/927): 4; [#493](https://github.com/JohnstonCode/svn-scm/issues/493): 0 |
| Background policy | [#126](https://github.com/JohnstonCode/svn-scm/issues/126): 17; [#333](https://github.com/JohnstonCode/svn-scm/issues/333): 4; [#720](https://github.com/JohnstonCode/svn-scm/issues/720): 3 |

The repository's current public boundary remains narrower than this research target: the public claim matrix limits remote/authentication/certificate claims and records fixture evidence separately at <code>docs/release/public-claim-matrix.md:71-73</code>. The source lock pins Subversion 1.14.5 at <code>native/sources.lock.json:4-11</code>. Nothing in this survey expands a public support claim.

## 1. VS Code extension landscape

### 1.1 Marketplace and maintenance snapshot

| Extension | Installs observed 2026-07-18 | Latest Marketplace version / update | Public implementation and maintenance signal |
| --- | ---: | --- | --- |
| [JohnstonCode SVN](https://marketplace.visualstudio.com/items?itemName=johnstoncode.svn-scm) | 1,394,786 | 2.17.0 / 2023-06-22 | Requires a machine-installed SVN command-line client; its [repository](https://github.com/JohnstonCode/svn-scm) was not archived and had later issue activity, but no later Marketplace release was observed. |
| [vscode-svn](https://marketplace.visualstudio.com/items?itemName=eliean.vscode-svn) | 64,742 | 0.1.0 / 2017-02-02 | Historical extension; its advertised repository was unavailable in this snapshot. |
| [Tortoise SVN for VS Code](https://marketplace.visualstudio.com/items?itemName=cdsama.tortoise-svn-for-vscode) | 33,147 | 0.1.1 / 2018-09-12 | Tortoise-oriented command integration; the [repository](https://github.com/cdsama/tortoise-svn-for-vscode) showed no recent product release. |
| [TianWu SVN](https://marketplace.visualstudio.com/items?itemName=Tianwu.svn) | 25,801 | 0.0.28 / 2018-12-21 | Historical CLI-oriented integration; the [repository](https://github.com/TianWenHong/vscode-svn) is the public source linked by its listing. |
| [SVN SCM Extension](https://marketplace.visualstudio.com/items?itemName=spmeesseman.svn-scm-ext) | 14,975 | 1.2.1 / 2020-02-17 | Extension of the JohnstonCode provider, not a separate native transport stack. |
| [Subversion](https://marketplace.visualstudio.com/items?itemName=rinrab.subversion) | 2,868 | 0.12.1 / 2025-06-14 | Newer listing; the Marketplace entry describes use of a local SVN executable. No public source repository was linked in the API record. |
| [Shellback SVN](https://marketplace.visualstudio.com/items?itemName=Shellback.shellback-svn) | 815 | 0.8.4 / 2026-06-01 | Actively updated but explicitly a lightweight SVN CLI bridge; [public source](https://github.com/shellback-labs/shellback-svn). |

These figures are an **observed snapshot**, not cumulative unique active users and not a quality ranking. Marketplace install counts can include reinstalls and inactive installations. Repository “updated” dates can also reflect issue metadata rather than code, so release date and source activity are reported separately.

The landscape supports two narrow conclusions. First, the established user base is concentrated in one mature CLI adapter. Second, the recent entrants found here do not demonstrate a maintained Node-native libsvn solution. Neither conclusion establishes that SubversionR already supports remote workflows.

### 1.2 Public demand taxonomy

The table below converts representative public reports into requirements. It does not copy a competitor's implementation contract; it identifies recurring user-visible failure modes.

| Category | Representative public signal | Requirement for SubversionR | Failure pattern to avoid |
| --- | --- | --- | --- |
| Prompt semantics | Startup authentication failures and missing prompts appear in [#89](https://github.com/JohnstonCode/svn-scm/issues/89), [#849](https://github.com/JohnstonCode/svn-scm/issues/849), and [#219](https://github.com/JohnstonCode/svn-scm/issues/219). A password manager stealing focus can dismiss a prompt in [#918](https://github.com/JohnstonCode/svn-scm/issues/918). | Prompt only for a user-visible foreground request; show operation, canonical server, repository, auth realm, and requested credential type; keep credential UI open across focus changes; make cancellation terminate that request. | Generic “authentication failed”, invisible terminal prompting, retry loops, or a prompt whose disappearance is interpreted as empty credentials. |
| Persistence and scope | Credentials are requested again for every repository or every few minutes in [#552](https://github.com/JohnstonCode/svn-scm/issues/552), lost across restarts in [#652](https://github.com/JohnstonCode/svn-scm/issues/652) and [#1601](https://github.com/JohnstonCode/svn-scm/issues/1601), and exposed in process arguments in [#1383](https://github.com/JohnstonCode/svn-scm/issues/1383). | Offer explicit session-only and remembered choices. Persist only secret material in SecretStorage under a canonical transport/server/port/realm/account key. Never place secrets in URLs, argv, environment diagnostics, logs, telemetry, or error arguments. | One global password, silent indefinite persistence, plaintext command-line credentials, or repeated prompts with no explanation of save policy. |
| Multiple repositories and accounts | [#552](https://github.com/JohnstonCode/svn-scm/issues/552) reports repeated prompts across repositories. | Scope by libsvn's challenge realm and canonical endpoint, support multiple accounts intentionally, and serialize/deduplicate concurrent identical challenges. | Workspace-wide credential bleed or separate prompts racing for the same realm. |
| Externals | One operation causes repeated prompts for six externals in [#629](https://github.com/JohnstonCode/svn-scm/issues/629); the behavior is reported again in [#1608](https://github.com/JohnstonCode/svn-scm/issues/1608). | Reuse a credential only when libsvn reports the same canonical realm and account. Different-realm externals receive independent challenges. Include external URL context in safe prompt text. | Blindly applying parent credentials to an external, or seven simultaneous prompts for one identical realm. |
| Offline and unreachable servers | Startup slowness and hangs are reported in [#365](https://github.com/JohnstonCode/svn-scm/issues/365) and [#462](https://github.com/JohnstonCode/svn-scm/issues/462); “no route to host” is represented by [#1644](https://github.com/JohnstonCode/svn-scm/issues/1644). | Local operations remain available. Remote operations have bounded connect/read timeouts, cancellation, a visible stale/unreachable state, and one diagnostic per scheduled request. | Blocking activation, treating network absence as credential failure, or prompt storms while offline. |
| Proxy and proxy authentication | **Evidence gap:** the focused competitor search did not find a clear direct proxy issue. Apache's client configuration nevertheless defines per-server proxy settings and separate proxy credentials in the [Subversion runtime configuration area](https://svnbook.red-bean.com/en/1.8/svn.advanced.confarea.html). | Treat origin authentication and proxy authentication as distinct challenge realms. Make proxy configuration explicit and redact credentials. Test unauthenticated, authenticated, unreachable, and bypass cases. | Sending origin credentials to a proxy, silently bypassing a configured proxy, or mislabelling HTTP 407 as repository authentication failure. |
| TLS server certificates | **Evidence gap:** the focused competitor search did not produce a clear certificate-specific issue. VisualSVN explicitly supports self-signed and enterprise-issued certificates in its [getting-started guidance](https://www.visualsvn.com/server/getting-started/). JavaHL exposes a dedicated SSL server trust callback in its [callback package](https://subversion.apache.org/docs/javahl/1.9/org/apache/subversion/javahl/callback/package-summary.html). | Report hostname, validity, issuer, fingerprint, and failure reasons. Separate trust-once from explicitly persisted trust. A changed certificate must challenge again. | “SSL error” without cause, permanent trust by default, or equating authentication success with certificate trust. |
| TLS client certificates | JavaHL has separate client-certificate and passphrase callbacks in its [callback package](https://subversion.apache.org/docs/javahl/1.9/org/apache/subversion/javahl/callback/package-summary.html). | Model certificate selection and private-key passphrase as distinct typed challenges. Keep private keys outside extension storage; store only an explicitly approved reference and, separately, a passphrase if policy permits. | Treating a PKCS#12 file path as a password or silently choosing the first certificate. |
| SSH, agents, and passphrases | Protected keys and Remote SSH fail in [#893](https://github.com/JohnstonCode/svn-scm/issues/893); Windows tunnels fail even when TortoiseSVN works in [#263](https://github.com/JohnstonCode/svn-scm/issues/263); Pageant/Tortoise behavior is discussed in [#927](https://github.com/JohnstonCode/svn-scm/issues/927); missing agent keys become generic errors in [#493](https://github.com/JohnstonCode/svn-scm/issues/493); a custom SSH port appears in [#1393](https://github.com/JohnstonCode/svn-scm/issues/1393). | Require an explicit OpenSSH or Plink adapter. Model host-key confirmation, key passphrase, password, agent absence, port, timeout, and cancellation separately. | Treating all tunnel exits as SVN auth errors, switching adapters silently, or assuming Pageant and OpenSSH agent are interchangeable. |
| Errors and diagnostics | [#849](https://github.com/JohnstonCode/svn-scm/issues/849) and [#493](https://github.com/JohnstonCode/svn-scm/issues/493) show that generic errors hide the actionable cause. | Return stable error keys plus safe arguments from native/daemon code. Preserve a redacted cause chain with operation, repository, transport, and challenge type for the localized TypeScript UI. | Localized backend prose, raw stderr containing secrets, or collapsing network, trust, proxy, and credential errors into one code. |
| Background network policy | Unexpected idle SSH prompts appear in [#126](https://github.com/JohnstonCode/svn-scm/issues/126). A “zero” frequency that does not disable traffic is reported in [#333](https://github.com/JohnstonCode/svn-scm/issues/333), while [#720](https://github.com/JohnstonCode/svn-scm/issues/720) shows confusion when disabling scheduling also removes manual affordances. | Remote polling is off by default. Local status refresh cannot initiate a remote request. Background work is noninteractive, bounded, and records “authentication required” for the next foreground action. Manual remote refresh remains available. | Any background prompt, SSH agent popup, implicit retry, or setting whose disabled state also disables explicit user commands. |

### 1.3 Architecture implied by the taxonomy

The appropriate direct implementation path is a typed, request-scoped authentication broker:

1. libsvn invokes a typed authentication provider or tunnel request in the native layer.
2. The Rust sidecar emits a protocol challenge containing a request ID, safe endpoint/repository context, realm, challenge type, allowed persistence, and cancellation handle.
3. The TypeScript adapter resolves the challenge in a foreground-only UI flow. It retrieves or stores secrets through SecretStorage and returns only the requested response.
4. The sidecar completes or cancels the exact libsvn request. It never persists secrets and never initiates a second UI path.
5. Background operations run with an explicit noninteractive policy and stop at the first missing challenge response.

This is an **inference** from the issue taxonomy and callback prior art below. It preserves the repository's native-authority and localization invariants while preventing a CLI-style prompt from escaping into an invisible process.

### 1.4 Native binding attempts and callback prior art

Only one directly relevant public Node-native attempt was found. [yume-chan/node-svn](https://github.com/yume-chan/node-svn) is archived and labels itself work in progress; its README says maintenance stopped in 2018. It used node-gyp and statically assembled libsvn, APR, Serf, OpenSSL, and SQLite. Its status matrix did not claim verified cross-platform authentication, and its README warns that concurrent operations need separate clients because the author observed access violations. The project is useful negative evidence: a monolithic Node addon inherits a large native supply chain, ABI/build complexity, threading constraints, and platform verification burden. It is not evidence that libsvn itself is unsuitable.

Two mature bindings provide better authentication design prior art:

- [SharpSvn](https://github.com/AmpScm/SharpSvn) is a Windows-focused .NET wrapper built through C++/CLI and packaged with native dependencies. Its authentication source registers libsvn prompt providers, including the [simple credential prompt provider](https://github.com/AmpScm/SharpSvn/blob/master/src/SharpSvn/SvnAuthentication.cpp). Its value here is typed event/callback translation, not portability to SubversionR.
- JavaHL's official [callback package](https://subversion.apache.org/docs/javahl/1.9/org/apache/subversion/javahl/callback/package-summary.html) separates username/password, SSL server trust, client certificate, certificate passphrase, and tunnel-agent concerns. Current upstream source keeps the Java interface and native bridge distinct in [AuthnCallback.java](https://github.com/apache/subversion/blob/trunk/subversion/bindings/javahl/src/org/apache/subversion/javahl/callback/AuthnCallback.java) and [AuthnCallback.cpp](https://github.com/apache/subversion/blob/trunk/subversion/bindings/javahl/native/AuthnCallback.cpp).

The transferable lesson is typed challenges with challenge-specific results and “may save” semantics. SubversionR should not expose a generic “give me credentials” callback and should not move secret ownership into Rust.

## 2. Server and client ecosystem, 2023–2026

### 2.1 Evidence-tiered deployment archetypes

There is no authoritative current census that compares VisualSVN Server, Linux Apache deployments, svnserve, and hosted services by installed base. “Common” below therefore means supported by multiple current vendor/distribution/release signals, not measured global share.

| Evidence tier | Archetype | Current public signal | Likely auth, certificate, and proxy implications |
| --- | --- | --- | --- |
| Reach signal, not market share | VisualSVN Server on Windows | VisualSVN reports more than three million downloads on its [product page](https://www.visualsvn.com/server/) and shipped Subversion 1.14.5 in [VisualSVN Server 5.4.3](https://www.visualsvn.com/company/news/update-to-subversion-1.14.5). | HTTP(S); internal username/password in Community; Integrated Windows Authentication in Enterprise/Evaluation. Self-signed certificates are normal for initial/non-domain setups and enterprise CA certificates are recommended in domain environments by the [getting-started guide](https://www.visualsvn.com/server/getting-started/). |
| Distribution evidence | Apache HTTP Server plus mod_dav_svn on Linux | Debian 12 publishes Subversion 1.14.2 and <code>libapache2-mod-svn</code> in its [package set](https://packages.debian.org/bookworm/subversion); Debian stable later carried 1.14.5 in the [source-package index](https://packages.debian.org/src%3Asubversion). | HTTP Basic/Digest or Apache authentication providers, TLS server certificates, optional TLS client certificates, and normal enterprise forward/reverse proxy paths. Exact modules are deployment-specific and must be tested, not guessed from URL scheme. |
| Upstream protocol baseline | svnserve | The official [svnserve configuration chapter](https://svnbook.red-bean.com/en/1.8/svn.serverconfig.svnserve.html) documents anonymous access, built-in CRAM-MD5 username/password, realms, and optional SASL. | No HTTP proxy or TLS client certificate in the plain svn transport. SASL mechanisms can add materially different credential and security behavior. |
| Upstream protocol baseline | svn+ssh | The same [svnserve chapter](https://svnbook.red-bean.com/en/1.8/svn.serverconfig.svnserve.html) documents local SSH spawning and remote <code>svnserve -t</code>. | Authentication and host trust belong to SSH, not to the SVN password cache. Windows OpenSSH, Plink/Pageant, passphrases, host keys, and process lifecycle are first-class compatibility surfaces. |
| Hosted-service example, not prevalence | SourceForge hosted SVN | SourceForge's current [SVN overview](https://sourceforge.net/p/forge/documentation/SVN%20Overview/) documents HTTPS repository URLs, anonymous read access for public projects, and authenticated writes. | Public-CA HTTPS and service-defined account credentials. Server version, certificate rotation, rate limits, and auth policy remain provider-controlled. |
| Hosted-service example, not prevalence | RiouxSVN | RiouxSVN's current [terms](https://riouxsvn.com/terms) identify a hosted Subversion service delivered over HTTPS. | Provider-managed TLS and service credentials. The terms do not explicitly authorize automated CI load, so this is not a release-gate host without written permission. |

### 2.2 Version compatibility and its limits

Apache identifies 1.14.x as the current long-term-support line on the [release-notes index](https://subversion.apache.org/docs/release-notes/) and records 1.14.5 on 2024-12-08 in the [release history](https://subversion.apache.org/docs/release-notes/release-history.html). The [1.14 compatibility notes](https://subversion.apache.org/docs/release-notes/1.14.html#compatibility) state that 1.x clients and servers interoperate, with newer features sometimes unavailable or less efficient against older peers, and that working-copy format is shared across 1.8–1.14.

That wire-compatibility policy does not prove authentication coverage. A libsvn build can differ in Serf, SSPI, SASL, certificate-store, or SSH-tunnel capability; a server can choose auth modules independently of its Subversion version. Release evidence must therefore record both versions and the negotiated transport/auth mode. “Server responded” is not evidence for proxy authentication, Integrated Windows Authentication, client certificates, or SSH agents.

TortoiseSVN 1.14.9 currently links Subversion 1.14.5 according to the [TortoiseSVN release page](https://tortoisesvn.net/). This matching baseline creates a valuable differential-test oracle for Windows semantics, but it does not authorize SubversionR to depend on TortoiseSVN.

### 2.3 Authentication matrix and priority

| Deployment | Auth modes to recognize | Proxy / certificate surface | Recommended evidence tier |
| --- | --- | --- | --- |
| VisualSVN Community | Internal Basic credentials over HTTP(S) | Self-signed or configured server certificate; LAN or enterprise proxy paths possible | Required controlled CI smoke on Windows |
| VisualSVN Enterprise / Evaluation | Basic plus IWA via SPNEGO, normally Kerberos with NTLM as applicable | Windows domain, SPN, DNS, and certificate chain all affect the result; [vendor documentation](https://www.visualsvn.com/server/features/windows-auth/) describes the Windows-auth flow | Required private domain-lab gate before claiming IWA |
| Apache/mod_dav_svn | Basic, Digest, LDAP/custom Apache providers, optional client certificate | Forward proxy, proxy authentication, TLS trust, hostname/expiry/rotation, client-cert selection | Required controlled CI for Basic/proxy/trust; client cert is a high-risk gate |
| svnserve | Anonymous, built-in CRAM-MD5, optional Cyrus SASL mechanisms | No HTTP proxy; realm and credential cache still matter | Required CI for anonymous and CRAM-MD5; SASL is a separate gate |
| svn+ssh | SSH key, agent, key passphrase, password where server permits | SSH host key and tunnel adapter, not X.509 or HTTP proxy | High-risk Windows gate for OpenSSH; separate Plink/Pageant gate |
| Hosted HTTPS | Provider-specific password/token/account policy | Public TLS, corporate forward proxy, provider-driven rotation | Optional manual canary; never infer support from one provider |

Suggested evidence labels for release planning:

- **Tier 0 — local baseline:** local <code>file://</code> operations and no authentication.
- **Tier 1 — required controlled remote:** svn anonymous and CRAM-MD5; HTTPS Basic; trusted and unknown/self-signed server certificates; authenticated forward proxy; OpenSSH key/agent/passphrase/host-key flows on Windows; externals in same and different realms.
- **Tier 2 — environment-heavy:** svnserve SASL; HTTPS client certificate; VisualSVN IWA on a domain; Plink/Pageant.
- **Known-risk negative gates:** offline/unreachable endpoints, proxy 407, expired/hostname-mismatched/rotated certificates, cancelled prompts, wrong credentials, agent absent, unknown/changed host key, timeout, multi-realm externals, and background noninteraction.
- **Deferred edge modes unless separately reviewed:** cleartext HTTP except negative tests, exotic SASL mechanisms, arbitrary custom tunnel commands, and network-share <code>file://</code>.

### 2.4 TortoiseSVN dominance signal and interop

TortoiseSVN remains the most visible Windows client distribution signal: its SourceForge download page showed hundreds of thousands of weekly downloads in the 2026-07-18 snapshot, while the project page publishes current 1.14.9 binaries at [SourceForge](https://sourceforge.net/projects/tortoisesvn/files/). This counter is dynamic and is not an active-install or market-share measure.

Its behavior is nevertheless important prior art:

- The [Saved Data documentation](https://tortoisesvn.net/docs/release/TortoiseSVN_en/help-onepage.html) describes Subversion auth data under <code>%APPDATA%\Subversion\auth</code>, including password, server-certificate, and username caches, and exposes explicit clearing.
- The [network settings documentation](https://tortoisesvn.net/docs/release/TortoiseSVN_en/tsvn-dug-settings.html) supports proxy and per-server configuration, recommends TortoisePlink for windowless SSH use, warns that its GUI-oriented build hides useful error output, and recommends standard Plink for diagnostics. It also documents Pageant as the SSH key/passphrase cache.

Interop opportunity: use TortoiseSVN against the same controlled repositories as a differential oracle, especially for server auth, certificate, and svn+ssh behavior. Product boundary: SubversionR must not silently discover or borrow Tortoise executables, Pageant state, cached passwords, trust decisions, or Subversion configuration. Any future import or shared-configuration feature needs an explicit reviewed requirement, visible provenance, and one direct ownership model.

## 3. VS Code platform fit

### 3.1 What the built-in Git askpass bridge demonstrates

The built-in Git extension's [askpass implementation](https://github.com/microsoft/vscode/blob/main/extensions/git/src/askpass.ts) registers an IPC handler and launches helper processes through environment variables. It handles HTTPS username/password prompts, SSH key-passphrase prompts, and SSH host-authenticity confirmation in VS Code UI. The helper's [main program](https://github.com/microsoft/vscode/blob/main/extensions/git/src/askpass-main.ts) forwards a typed request through IPC and writes the result to a pipe. The IPC server uses a Windows named pipe or a Unix socket in [ipcServer.ts](https://github.com/microsoft/vscode/blob/main/extensions/git/src/ipc/ipcServer.ts).

This is **source-derived architectural precedent** for bridging a blocking child-process challenge to Extension Host UI. It is not a supported API for other extensions. It also contains Git-specific behavior that SubversionR should not copy: the HTTPS credential cache is short-lived and keyed by authority, whereas SVN provides authentication realms and “may save” policy. SubversionR's equivalent belongs in its existing daemon protocol with request IDs, typed challenges, bounded lifetime, and cancellation.

### 3.2 SCM history and Source Control Graph

The stable [Source Control API guide](https://code.visualstudio.com/api/extension-guides/scm-provider) exposes source controls, resource groups, commands, and quick diff. The provider-facing history contract remains in [vscode.proposed.scmHistoryProvider.d.ts](https://github.com/microsoft/vscode/blob/main/src/vscode-dts/vscode.proposed.scmHistoryProvider.d.ts); the built-in Git extension opts into the proposal in its [package manifest](https://github.com/microsoft/vscode/blob/main/extensions/git/package.json). The tracking request, [microsoft/vscode#185269](https://github.com/microsoft/vscode/issues/185269), remained open in this research snapshot.

VS Code's [proposed API policy](https://code.visualstudio.com/api/advanced-topics/using-proposed-api) says proposals are unstable, are available only in Insiders, and cannot be used by normal Marketplace extensions. Therefore SubversionR should not ship Source Control Graph/history integration through that proposal today. Continue using stable SCM primitives and the project's own history UI, while tracking the API. Do not add a stable/proposed compatibility switch.

### 3.3 SecretStorage versus AuthenticationProvider

The official [VS Code API reference](https://code.visualstudio.com/api/references/vscode-api) defines SecretStorage as encrypted, machine-specific storage with get/store/delete, key enumeration, and change events. It does not sync secrets. This is the direct fit for SVN realm-scoped password, proxy-password, and certificate-passphrase material.

Recommended key identity:

<code>transport + canonical host + effective port + auth kind + libsvn realm + account</code>

Only the value is secret. Safe display metadata may live separately. The user explicitly chooses session-only or remembered storage, and all invalidation is observable.

AuthenticationProvider in the same API is session/token/scope shaped: a session has an account and access token, and a provider may advertise multiple accounts. It is appropriate only if SubversionR later exposes a genuine reusable sign-in provider with token semantics. Encoding arbitrary realm passwords as <code>accessToken</code> would lose SVN's challenge types and persistence rules. Therefore direct SecretStorage is the recommended path.

### 3.4 Workspace Trust

The [Workspace Trust extension guide](https://code.visualstudio.com/api/extension-guides/workspace-trust) supports limited capability and restricted settings, but also warns that commands can still be invoked and must enforce trust at runtime. The [Workspace Trust user documentation](https://code.visualstudio.com/docs/editing/workspaces/workspace-trust) treats workspace-controlled executable paths as a code-execution concern.

Two flagship process-spawning extensions choose an even stricter precedent. VS Code's built-in Git [manifest](https://github.com/microsoft/vscode/blob/main/extensions/git/package.json) declares `untrustedWorkspaces.supported: false`; the same manifest exposes `git.path` only at machine scope. Microsoft's Python extension likewise declares untrusted-workspace support false in its current [manifest](https://github.com/microsoft/vscode-python/blob/main/package.json), which also exposes interpreter and environment-file settings. These manifests do not require SubversionR to disable its already-defined local read-only restricted mode, but they support a firm boundary: no external SVN, SSH, or tunnel process and no workspace-sourced executable/configuration override may run before trust is granted.

For SSH:

- Adapter selection, executable path, and base adapter configuration must be user-scope only.
- The executable path must be absolute, canonicalized, and displayed in diagnostics without secrets.
- Untrusted workspaces cannot initiate a tunnel or override executable/arguments.
- Trust is necessary but not sufficient: a foreground operation still needs explicit connection intent and host-key policy.

## 4. Windows svn+ssh practice and security

### 4.1 What libsvn actually launches

The official [svnserve tunnelling documentation](https://svnbook.red-bean.com/en/1.8/svn.serverconfig.svnserve.html#svn.serverconfig.svnserve.sshauth) explains that the client launches a local SSH process, SSH authenticates, and the remote process runs <code>svnserve -t</code>. SSH prompts and agent behavior are outside SVN's password cache. Repeated operations can therefore create repeated SSH connections and prompts.

Current libsvn source resolves the tunnel agent, defaults to the <code>SVN_SSH</code> value or <code>ssh -q --</code>, constructs the remote <code>svnserve -t</code> invocation, and owns tunnel pipes in [libsvn_ra_svn/client.c](https://github.com/apache/subversion/blob/trunk/subversion/libsvn_ra_svn/client.c). The runtime configuration template defines tunnel configuration in [config_file.c](https://github.com/apache/subversion/blob/trunk/subversion/libsvn_subr/config_file.c).

This mechanism is a process-execution boundary. It is not just another network socket.

### 4.2 OpenSSH and Plink are separate modes

| Concern | Windows OpenSSH mode | Plink / Pageant mode |
| --- | --- | --- |
| Executable | Explicit absolute path to <code>ssh.exe</code> | Explicit absolute path to <code>plink.exe</code> or reviewed TortoisePlink path |
| Agent | Windows/OpenSSH <code>ssh-agent</code>; Microsoft documents that the service is disabled by default and keys are added with <code>ssh-add</code> in its [key-management guide](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_keymanagement) | Pageant, with PuTTY-format sessions/keys and separate process state; TortoiseSVN documents Pageant in its [SSH settings](https://tortoisesvn.net/docs/release/TortoiseSVN_en/tsvn-dug-settings.html) |
| Background mode | Force noninteraction, for example <code>BatchMode=yes</code>; missing credentials or unknown host key must fail | Use Plink's noninteractive batch behavior and pre-pin a host key. PuTTY explicitly recommends preloading the correct key or using <code>-hostkey</code> for automation in its [FAQ](https://www.chiark.greenend.org.uk/~sgtatham/putty/faq.html) |
| Foreground prompts | A controlled askpass broker may handle password/passphrase/host-key decisions | Plink's prompts and Pageant interaction need a Plink-specific broker; TortoisePlink may hide stderr, so diagnostics need standard Plink or captured structured exit information |
| Host-key store | OpenSSH known-hosts semantics | PuTTY registry/session semantics or explicit <code>-hostkey</code> |
| Argument syntax | OpenSSH argv and <code>--</code> conventions | PuTTY/Plink options and saved sessions; do not pass OpenSSH options |

The product configuration should therefore be a required enum, <code>openssh</code> or <code>plink</code>, with adapter-specific validated fields. There should be no “auto”, no search-through-PATH fallback, and no retry with the other adapter after failure.

### 4.3 Local Windows observations

The following are **empirical checks on the research workstation on 2026-07-18**, not statements about all Windows installations:

- <code>ssh.exe</code> resolved to <code>C:\Windows\System32\OpenSSH\ssh.exe</code>. <code>ssh -V</code> reported <code>OpenSSH_for_Windows_9.5p2, LibreSSL 3.8.2</code>; file version was 9.5.5.1.
- <code>ssh-agent.exe</code> existed at the same Windows component path, but the service was stopped and disabled, and <code>SSH_AUTH_SOCK</code> was unset. This matches Microsoft's documented need to enable the service explicitly, but it proves only this machine's state.
- <code>plink.exe</code> was not on PATH and <code>C:\Program Files\PuTTY\plink.exe</code> did not exist.
- <code>TortoisePlink.exe</code> resolved from a TortoiseGit installation at <code>C:\Program Files\TortoiseGit\bin\TortoisePlink.exe</code>, version 0.83.0.0. The usual TortoiseSVN program path was absent. This is concrete evidence that name-based discovery can select the wrong product provenance.
- A bounded noninteractive failure check ran:

    <code>ssh.exe -o BatchMode=yes -o ConnectTimeout=2 -o StrictHostKeyChecking=no -p 9 127.0.0.1 exit</code>

  It exited 255 with a connection-timeout error. This confirms timeout and noninteractive failure behavior for this binary against this unreachable endpoint. It does **not** test successful key auth, agent use, passphrase prompts, or host-key acceptance. The disabled host-key check was confined to this closed-port diagnostic and is not a product recommendation.

### 4.4 Threats and required gates

Apache's [security page](https://subversion.apache.org/security/) records CVE-2017-9800: crafted svn+ssh URLs could lead vulnerable clients to execute arbitrary commands, including through externals. Modern 1.14.5 is outside the affected versions, but the vulnerability demonstrates why URL-to-tunnel argument construction is security-sensitive. The same page records CVE-2024-45720, a Windows command-line argument-injection issue affecting releases through 1.14.3 and therefore fixed before the locked 1.14.5 baseline.

Required implementation gates:

- Accept a structured hostname, port, username, and adapter configuration; never concatenate a shell command string.
- Spawn directly with an argv array and shell execution disabled.
- Reject control characters and adapter metacharacters before reaching libsvn or a tunnel process.
- Keep executable and base adapter settings at user scope; untrusted workspaces cannot override them.
- Pin adapter provenance and show it in diagnostics. A missing executable fails clearly.
- Keep background mode noninteractive. Foreground challenges go through one broker and one request ID.
- Reserve stdin/stdout for the svn tunnel. Bound and redact stderr; do not let an SSH prompt consume protocol bytes.
- Apply connect, operation, and cancellation deadlines. Terminate the full Windows process tree, and verify that cancellation does not orphan a remote <code>svnserve -t</code>.
- Treat host-key unknown and changed as distinct outcomes. Never disable host-key checking as a fallback.
- Revalidate every svn+ssh URL reached through externals.
- Test OpenSSH and Plink independently; Pageant success is not OpenSSH-agent evidence.

## 5. Test infrastructure and evidence plan

### 5.1 Existing controlled fixture foundation

The repository already pins Subversion 1.14.5 in <code>native/sources.lock.json:4-11</code>. Existing daemon integration tests contain svnserve fixture code at <code>crates/subversionr-daemon/tests/native_bridge.rs:4960-5101</code>, auth-oriented cases around <code>:1585-1677</code>, an HTTP DAV fixture at <code>:5461-5697</code>, and an HTTPS broker case beginning at <code>:1976</code>. Native Apache module inputs and validation are explicit at <code>scripts/native/build-subversion-dav-modules.ps1:2-13,164-186</code>; the HTTPS smoke script wires its staged OpenSSL input and exact daemon test at <code>scripts/native/smoke-httpd-dav-https.ps1:1-47</code>. Relevant package entry points are at <code>package.json:90,95-98,105</code>, with current workflow wiring at <code>.github/workflows/ci.yml:301,311-336,441-445</code>.

These references identify reusable fixture infrastructure; they are not evidence that the remote modes in this report already pass.

### 5.2 Hostability and licensing

| Fixture | Can be controlled in CI? | Licensing / environment constraint | Appropriate use |
| --- | --- | --- | --- |
| Source-built svnserve | Yes, Windows and/or Linux | Apache License; use the repository-pinned source and record build features | Anonymous, CRAM-MD5, realm, cancellation, offline, and externals |
| Source-built Apache + mod_dav_svn | Yes | Apache License; local certificates and proxy are under test control | HTTP(S) Basic, trust failures, rotation, client cert, proxy, and negative cases |
| Local forward proxy | Yes | Choose a redistributable test dependency and pin it explicitly | Proxy bypass, 407, credential isolation, unreachable proxy, redaction |
| Windows OpenSSH server/client | Yes on a controlled Windows image, but setup must be explicit | OpenSSH is a Windows optional capability; Microsoft's [overview](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh-overview) documents differing default installation states | OpenSSH tunnel success/failure, agent, passphrase broker, host-key changes, cancellation |
| VisualSVN Server Community | Automatable for a Windows product smoke | VisualSVN documents [unattended MSI installation](https://www.visualsvn.com/support/topic/00092/); Community is free for commercial use, but Windows Authentication is not a Community feature per the [licensing guide](https://www.visualsvn.com/support/topic/00241/) | Product-interop Basic/HTTPS smoke only |
| VisualSVN IWA | Not credible on an ordinary hosted workgroup runner | Enterprise/Evaluation feature; Kerberos requires a domain, DNS, SPNs, and domain identities | Scheduled private domain-joined lab, with NTLM/Kerberos negotiation recorded |
| Plink/Pageant | Possible on a controlled Windows image; interactive Pageant cases are environment-heavy | PuTTY license is permissive, but key/session state and desktop process lifecycle must be provisioned | Separate Plink noninteractive gate and a scheduled/manual Pageant gate |
| Public hosted SVN | Technically reachable, not controlled | Terms, rate limits, credentials, version, and availability are provider-owned | Optional read-only manual canary only after explicit permission review |

SourceForge permits anonymous reads of public repositories in its [SVN overview](https://sourceforge.net/p/forge/documentation/SVN%20Overview/), but that does not make it a stable load-test target. RiouxSVN's [terms](https://riouxsvn.com/terms) do not explicitly authorize recurring automated tests. Neither should be a release gate or receive generated credential/certificate test traffic without written permission.

### 5.3 Per-transport test map

| Transport / mode | Automated gate | Manual or private-lab gate | Evidence captured |
| --- | --- | --- | --- |
| <code>file://</code> | Existing local baseline | Network-share paths remain out of scope unless reviewed | Client/library versions, working-copy fixture hash |
| <code>svn://</code> anonymous | Source-built svnserve in CI | None | URL, server config hash, anonymous capability, negative authorization |
| <code>svn://</code> CRAM-MD5 | Source-built svnserve; correct/wrong/cancelled credentials; same/different realm externals | None | Realm, prompt count, save policy, redacted error chain |
| svnserve SASL | Linux controlled fixture when Cyrus SASL is explicitly built and pinned | Additional Windows mechanism coverage if claimed | Mechanism, encryption/integrity properties, build features |
| HTTP | Negative/redirect and explicit insecure-policy tests only | None | Clear warning and no accidental credential disclosure |
| HTTPS Basic | Local Apache with trusted, self-signed, expired, mismatched, and rotated certificates | Tortoise differential smoke | Certificate fingerprint/reasons, prompt decision, persisted scope |
| HTTPS client certificate | Local CA and Apache requiring a chosen client certificate; passphrase and cancellation | Platform certificate-store variants if claimed | Selected certificate identity without private data, passphrase challenge, server result |
| HTTPS through proxy | Local forward proxy, with/without auth, bypass, 407, and unreachable cases | Enterprise PAC/system-proxy behavior only if later claimed | Origin versus proxy realm, route, timeout, redaction |
| VisualSVN Basic/HTTPS | Optional Windows CI product smoke | None | VisualSVN and libsvn versions, edition, certificate mode |
| VisualSVN IWA | None on normal hosted CI | Domain-joined private lab: Kerberos success, NTLM path, wrong domain, expired ticket, DNS/SPN failure | Negotiated mechanism, identities redacted, domain topology identifier |
| svn+ssh OpenSSH | Controlled server plus Windows client; key, agent absent, unknown/changed host, timeout, cancel, background batch | Passphrase/askpass interaction if the hosted runner cannot support a desktop broker | Exact ssh version/path, adapter config hash, host-key fingerprint, process cleanup |
| svn+ssh Plink | Noninteractive controlled Windows image with pre-pinned host key | Pageant and interactive passphrase in scheduled desktop lab | Plink version/path/provenance, host-key source, Pageant state, process cleanup |
| Hosted HTTPS | No release gate | Optional read-only canary after provider permission review | Provider, timestamp, URL class, client version; no synthetic load claim |

Every evidence artifact should include client/libsvn and server versions, compiled auth features, transport, auth mode, certificate/host-key identity, server/proxy configuration hash, operation, expected result, prompt count, cancellation result, and redaction assertion. Logs must prove that passwords, passphrases, tokens, private-key contents, and full credential-bearing URLs are absent.

### 5.4 Release-policy consequences

- A fixture that starts is not a support claim. Each mode closes native provider behavior, daemon protocol, VS Code UI, localized errors, secret lifecycle, cancellation, tests, and state reconciliation together.
- Remote status remains independently scheduled and off by default. No test should normalize background authentication prompts.
- “Works with TortoiseSVN installed” is not acceptable evidence for a native core path.
- Passing HTTPS Basic does not imply proxy, IWA, or client-certificate support.
- Passing OpenSSH does not imply Plink/Pageant support.
- A successful hosted-service smoke does not imply compatibility with other hosted services or server versions.

## 6. Recommended direct implementation order

1. Define typed protocol challenges and stable error keys for simple credentials, proxy credentials, server trust, client certificate selection/passphrase, and SSH tunnel outcomes. Include cancellation and “may save”; omit a generic fallback challenge.
2. Implement explicit SecretStorage scope and foreground prompt coordination in TypeScript. Add concurrency deduplication for identical realms and independent flows for different-realm externals.
3. Complete controlled svnserve CRAM-MD5 and Apache HTTPS Basic/server-trust evidence, including offline, timeout, wrong credentials, cancellation, rotation, and background noninteraction.
4. Add proxy authentication and client-certificate flows as separate transports/challenges, not extensions of the password prompt.
5. Add Windows OpenSSH through one explicit adapter, with structured argv, host-key policy, agent/passphrase broker, and process-tree cleanup.
6. Add Plink/Pageant only as a second explicit adapter with its own tests. Do not introduce autodetection or fallback.
7. Validate VisualSVN Basic/HTTPS in a controlled Windows product fixture; use a private domain lab before any Kerberos/NTLM claim.
8. Keep SCM history provider integration out of Marketplace production code until VS Code stabilizes the API.

## 7. Open uncertainties

- Marketplace install counts and download counters do not reveal active users or deployment topology.
- Public issue search underrepresents private enterprise problems, especially proxies, client certificates, IWA, and internal server products.
- No current public census establishes server-product prevalence. The deployment matrix is an evidence-driven coverage model, not a market ranking.
- Hosted providers often conceal Subversion server version and authentication internals; capability must be observed and claims limited to the tested service.
- Windows OpenSSH packaging and service defaults vary by OS image and enterprise policy. The local observations above must not become defaults.
- Plink/TortoisePlink behavior can vary by provenance and version; a binary name is insufficient identification.
- Exact VS Code stabilization timing for SCM history cannot be predicted from the open proposal.

These uncertainties should remain visible in release evidence and public claims rather than being hidden by compatibility aliases, automatic adapter selection, or silent transport fallbacks.
