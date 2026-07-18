# Descendant working-copy activation probes (issue #36 research packet)

Status: research evidence only. No product, manifest, gate, or claim change.
Executed 2026-07-18 by the director per the #36 "Fable packet"; complements the
source-level analysis recorded on #36 (VS Code commit
`125df4672b8a6a34975303c6b0baa124e560a4f7`).

## Environment

- VS Code 1.129.0, commit `125df4672b8a6a34975303c6b0baa124e560a4f7` (x64) —
  the same commit the #36 source citations reference, so line citations apply
  to the tested binary verbatim.
- Fully isolated instance (dedicated `--user-data-dir` / `--extensions-dir`),
  default settings, five single-activation-event probe extensions (one event
  per extension so a written marker file unambiguously identifies which event
  fired). Three identical runs.

## Installed activation matrix (identical across 3 runs)

| activation event | wc-root (`.svn/wc.db` at root) | parent-ws (`child/.svn/wc.db`) | no-svn |
| --- | --- | --- | --- |
| `workspaceContains:.svn/wc.db` (exact) | **fired** | not fired | not fired |
| `workspaceContains:**/.svn/wc.db` | not fired | not fired | not fired |
| `workspaceContains:**/.svn` | not fired | not fired | not fired |
| `workspaceContains:*/.svn` | not fired | not fired | not fired |
| `workspaceContains:*/*/.svn` | not fired | not fired | not fired |

The wc-root row is decisive: the exact pattern and the file-shaped glob
describe the same existing file in the same launch, and only the exact
`exists()` branch fires.

## findFiles differential (diagnostic run inside the activated exact probe)

- `findFiles('**/.svn/wc.db', undefined, 10)` -> `[]` (default excludes applied)
- `findFiles('**/.svn/wc.db', null, 10)` -> finds `.svn/wc.db` at wc-root, and
  finds **both** `.svn/wc.db` and `child/.svn/wc.db` in the parent fixture —
  the search engine sees descendant working copies once excludes are disabled.
- `findFiles('**/.svn', undefined | null, 10)` -> `[]` both ways — directory-
  shaped patterns never match regardless of excludes (file search matches
  files; upstream microsoft/vscode#2739).

This is a diagnostic API distinction only; it must not become an Extension
Host startup scan.

## Two independent blockers (refines the earlier single-cause statement)

1. **Default excludes**: `files.exclude` defaults `**/.svn: true`, and the
   `workspaceContains` glob path builds an ordinary file-search query without
   `disregardExcludeSettings`, so every glob form is suppressed.
2. **Directory-shaped patterns can never match**: file search matches files
   only, so `**/.svn` / `*/.svn` would fail even with excludes fixed. Any
   future glob candidate must be file-shaped (`*/.svn/wc.db`,
   `*/*/.svn/wc.db`, `**/.svn/wc.db`).

## Upstream issue landscape (none covers this exactly)

- microsoft/vscode#323964 (open, 2026-07): `.gitignore` defeats glob
  `workspaceContains` — same mechanism, ignore-file flavor; does not cover the
  *default* `files.exclude` SCM entries.
- microsoft/vscode#34711 (closed, 2018): the design history — excludes were
  applied to `workspaceContains` searches for performance; contains the
  ".git/HEAD activation" objection and a suggested middle ground.
- microsoft/vscode#2739 (open, 2016): `workspaceContains` does not fire for
  directories (blocker 2).
- microsoft/vscode#242245, #163255: adjacent (activation after install without
  reload; timeout configurability).

## Product disposition (recommendation to close #36's limitation branch)

No supported, invariant-compatible activation surface exists today for
descendant working copies. Candidates `*`/`onStartupFinished`, helper
extensions, watchers, and Extension Host scans remain rejected per #36.
Recommended disposition:

1. Keep the shipped exact-path sentinels (`.svn/wc.db` + bounded ancestor
   forms) as the only `workspaceContains` surface; document the descendant
   limitation with the explicit `Open Repository` / checkout entrypoints as
   the supported path.
2. Add a readiness needle asserting the manifest contains **no glob**
   `workspaceContains` entries (they are dead on arrival on current VS Code).
3. Reuse the parent-with-`child/.svn/wc.db` fixture as an installed negative
   regression case: descendant working copies do not auto-activate; explicit
   entrypoints must work after manual open.
4. Upstream issue filed as microsoft/vscode#326423 (owner-approved); revisit
   glob candidates (file-shaped only) if upstream changes the exclude
   behavior.

## Appendix: upstream issue (filed with owner approval)

Filed 2026-07-18 as [microsoft/vscode#326423](https://github.com/microsoft/vscode/issues/326423).
Triage-bot version check answered same day: reproduced on stable 1.129.1
(commit `8a7abeba`), and the four cited source files are byte-identical
between the tested commit and the `1.129.1` tag.
Original prepared text follows.

## Title

`workspaceContains` glob activation events are silently defeated by default `files.exclude` (`**/.git`, `**/.svn`, `**/.hg`), so extensions cannot activate on descendant SCM metadata

## Body

<!-- bug report -->
- VS Code Version: 1.129.0 (commit `125df4672b8a6a34975303c6b0baa124e560a4f7`)
- OS Version: Windows 11 Pro 10.0.26200
- Does this issue occur when all extensions are disabled: N/A (behavior of extension activation itself; reproduced with a minimal probe extension in an isolated `--user-data-dir`/`--extensions-dir`, default settings)

### Summary

Any `workspaceContains` activation event containing `*` or `?` is routed through file search, and that search applies the configured excludes — including the *default* `files.exclude` entries `**/.git`, `**/.svn`, `**/.hg`. As a result, a glob activation event that targets SCM metadata (for example `workspaceContains:**/.svn/wc.db` for a Subversion extension) can never fire, even when the file demonstrably exists in the workspace. Exact (glob-free) patterns use a separate `exists()` branch and are unaffected — but exact patterns cannot express "a working copy in some child directory whose name I don't know".

The practical consequence: an SCM extension for Subversion/Mercurial (or anything keyed off dot-directory metadata) has no `workspaceContains` form that activates when the working copy is a *descendant* of the opened folder. The only workarounds are `onStartupFinished`/`*` (activating in every workspace, which `workspaceContains` exists to avoid) or asking the user to open the working-copy root.

This is silent: nothing in the extension host log indicates the pattern was suppressed by an exclude; the extension simply never activates.

### Minimal repro

Probe extension (plain JS, no build step) — one activation event per extension so the fired event is unambiguous; on activation it writes a marker file:

```json
{
  "name": "svnprobe-glob-file",
  "publisher": "svnprobe",
  "version": "0.0.1",
  "engines": { "vscode": "^1.85.0" },
  "main": "./extension.js",
  "activationEvents": ["workspaceContains:**/.svn/wc.db"],
  "capabilities": { "untrustedWorkspaces": { "supported": true } }
}
```

Fixtures (file contents irrelevant; existence matters):

```
wc-root/            .svn/wc.db          # working copy at workspace root
parent-ws/          child/.svn/wc.db    # working copy in a child dir (the real-world case)
no-svn/             plain.txt           # negative control
```

Steps:
1. Install probes into an isolated instance: `code --user-data-dir <ud> --extensions-dir <ext> --install-extension <vsix>`.
2. Open each fixture folder; wait past the workspaceContains window; check markers.

### Observed (3 identical runs, isolated instance, default settings)

| activation event | wc-root (`.svn/wc.db` at root) | parent-ws (`child/.svn/wc.db`) | no-svn |
|---|---|---|---|
| `workspaceContains:.svn/wc.db` (exact) | activates | no (correct: path not at root) | no |
| `workspaceContains:**/.svn/wc.db` | **no** | **no** | no |
| `workspaceContains:**/.svn` | no | no | no |
| `workspaceContains:*/.svn` | no | no | no |
| `workspaceContains:*/*/.svn` | no | no | no |

Note the wc-root row: the exact pattern and the `**/` glob describe the *same existing file*, in the same launch, and only the exact one fires.

Public-API confirmation from inside the activated probe (same workspace, `child/.svn/wc.db` present):

```js
await vscode.workspace.findFiles('**/.svn/wc.db', undefined, 10) // [] — default excludes applied
await vscode.workspace.findFiles('**/.svn/wc.db', null, 10)      // [ '<ws>/.svn/wc.db', '<ws>/child/.svn/wc.db' ]
```

### Source analysis (at `125df467`)

1. Pattern routing — anything with `*`/`?` goes to search, not `exists()`:
   [`src/vs/workbench/services/extensions/common/workspaceContains.ts#L42-L49`](https://github.com/microsoft/vscode/blob/125df4672b8a6a34975303c6b0baa124e560a4f7/src/vs/workbench/services/extensions/common/workspaceContains.ts#L42-L49)
   ```ts
   if (fileNameOrGlob.indexOf('*') >= 0 || fileNameOrGlob.indexOf('?') >= 0 || host.forceUsingSearch) {
       globPatterns.push(fileNameOrGlob);
   } else {
       fileNames.push(fileNameOrGlob);
   }
   ```
   Exact names use `host.exists(...)` in `_activateIfFileName` (L71-L79), which never consults excludes.

2. The glob branch builds an ordinary file-search query **without** `disregardExcludeSettings`:
   [`workspaceContains.ts#L113-L128`](https://github.com/microsoft/vscode/blob/125df4672b8a6a34975303c6b0baa124e560a4f7/src/vs/workbench/services/extensions/common/workspaceContains.ts#L113-L128)
   ```ts
   const query = queryBuilder.file(folders.map(...), {
       _reason: 'checkExists',
       includePattern: includes,
       exists: true
   });
   ```

3. QueryBuilder therefore folds in configured excludes:
   [`src/vs/workbench/services/search/common/queryBuilder.ts#L428-L431`](https://github.com/microsoft/vscode/blob/125df4672b8a6a34975303c6b0baa124e560a4f7/src/vs/workbench/services/search/common/queryBuilder.ts#L428-L431)
   ```ts
   private getExcludesForFolder(folderConfig: ISearchConfiguration, options: ICommonQueryBuilderOptions): glob.IExpression | undefined {
       return options.disregardExcludeSettings ?
           undefined :
           getExcludes(folderConfig, !options.disregardSearchExcludeSettings);
   }
   ```

4. And `files.exclude` *defaults* to excluding SCM metadata everywhere:
   [`src/vs/workbench/contrib/files/browser/files.contribution.ts#L153-L158`](https://github.com/microsoft/vscode/blob/125df4672b8a6a34975303c6b0baa124e560a4f7/src/vs/workbench/contrib/files/browser/files.contribution.ts#L153-L158)
   ```ts
   'default': {
       ...{ '**/.git': true, '**/.svn': true, '**/.hg': true, '**/.DS_Store': true, '**/Thumbs.db': true },
   ```

   Hidden-file handling is not the blocker: the ripgrep provider passes `--hidden` ([`ripgrepFileSearch.ts#L31`](https://github.com/microsoft/vscode/blob/125df4672b8a6a34975303c6b0baa124e560a4f7/src/vs/workbench/services/search/node/ripgrepFileSearch.ts#L31)).

### Expected

`workspaceContains` is documented as activating "whenever a folder is opened that contains at least one file that matches [the] glob pattern". Activation is a statement about workspace *content*; `files.exclude` is a *display/search* filter. A user hiding `.svn` from the Explorer does not intend to disable their Subversion extension — and here it is not even a user choice, it is the product default, so the manifest surface (`workspaceContains:**/.svn/...`) is dead on arrival for every user.

### Suggested fix direction

Have `checkGlobFileExists` build its query with `disregardExcludeSettings: true` (and `disregardIgnoreFiles: true`), matching the semantics of the exact-path branch, which already ignores excludes.

If that is considered too costly — excludes were deliberately applied to these searches for performance in #34711 (avoiding `node_modules`/`.git` walks) — a bounded middle ground is the one already suggested in #34711's discussion: only disregard an exclude when the activation glob explicitly names that directory (e.g. a pattern containing a literal `.svn` segment suppresses the `**/.svn` exclude for this query only). That keeps `**/*.ts`-style patterns cheap while making `**/.svn/wc.db` mean what it says. At minimum, the current behavior deserves a documentation note and an extension-host log line when a `workspaceContains` search returns empty solely due to excludes.

### Related issues

- #34711 — `workspaceContains` starts a search over full workspace, including `.git/`, `node_modules/` (closed 2018; the perf motivation for applying excludes, and the origin of the "how do you then activate on `.git/HEAD`?" question this issue is the answer to)
- #323964 — `.gitignore` will prevent an extension from launching (open; same mechanism via `search.useIgnoreFiles` instead of default `files.exclude`)
- #2739 — `activationEvents.workspaceContains` doesn't fire for directory (open; independent second blocker: directory-shaped patterns like `**/.svn` never match because file search matches files — reproduced here: `findFiles('**/.svn', null)` is also empty)
- #242245 — newly installed extensions not activating on `workspaceContains` trigger (adjacent reliability report)
