# Storage and branches

Where every artifact lives, who is allowed to write it, and how to get it back.
The governing rule: **`main` is the one long-lived branch.** Code, your config and what the
pipeline records all live on it, in separate directories with separate writers. (Until
2026-10-06 the config and state lived on `data` and `website` branches to keep `main`'s history
human-only; for a single-maintainer fork that cost more than it bought — see
[decisions/0008](decisions/0008-one-branch.md).)

## Where things live

| Path on `main` | Contents | Sole writer(s) | Readers |
|---|---|---|---|
| engine, workflows, scripts, `module/`, `bin/`, `docs/`, `CONFIG.md` | code | maintainer | every CI job |
| `configs/patches/*.toml`, `configs/config.manual.toml` | **your app configuration** | maintainer (a normal commit) | watcher, builds, `obtainium.py` |
| `configs/{stable,beta}_build.json` | generated pool configs | watcher, via `commit_to_main.sh` | builds |
| `state/{patch_sources,app_versions,patch_file_hashes}.json` | watcher memory | watcher, via `commit_to_main.sh` | watcher, builds |
| `state/manifests/<tag>.json`, `state/archive/{stable,beta}.json` | build metadata | `merge_archive_manifest.sh`; pruned by `cleanup_manifests.sh` | `obtainium.py` (README table); a download site, if one exists |
| `README.md` apps section | generated table | `update_readme.sh`, via plumbing | readers |

The one other branch that can ever exist is `update` (`changelogs/<code>.md`,
`<channel>/<module-id>.json`, written by `build_update_changelog.sh`, pruned by
`cleanup_update_branch.sh`). It holds Magisk/KernelSU module pointers and is created by the first
build that produces a module zip — an APK-only fork never has one.

GitHub Releases are storage too, and they are **not** mirrors of the repository:
releases hold files, `state/` holds the metadata that describes the files.

## How CI writes to `main`

Every CI write goes through `.github/scripts/commit_to_main.sh "<message>" <path>…`:

- **Named files only.** A path in the worktree is added or updated; one missing from the worktree
  but present on `main` is removed; one in neither is ignored. A half-edited TOML or scratch file
  can never ride along, because nothing is ever `git add -A`'d.
- **Plumbing.** A temporary index on `origin/main`'s tip, `commit-tree`, a direct ref push — the
  runner's checkout, index and worktree are never switched or dirtied.
- **A human push in between is built upon, not overwritten.** On a rejected push the script
  re-fetches and re-applies *only the named files* on the new tip (the worktree's copy of those
  files wins); after 3 attempts it fails the step loudly.
- Commits end `[skip ci]` and are authored by `github-actions[bot]`. A push made with
  `GITHUB_TOKEN` starts no workflow anyway; the marker keeps it true if that ever changes.

For you: `git pull` before editing `configs/` — CI commits to `main` between your edits — and
hand-edit only `configs/**.toml`. The JSON in `configs/` and everything in `state/` is
machine-written. `state/` is regenerable (the watcher rebuilds it from the forges); the TOMLs are
the sole copy of your intent, which is what `git` is for.

## Manifests (`state/manifests/`, `state/archive/`)

Per-build manifests plus two cumulative archives. They replaced release assets as the manifest
store on **2026-09-25**: numbered releases no longer carry a `build.json`, so git history is the
only metadata history. The move and the failure it eliminated are recorded in
[decisions/0002](decisions/0002-manifests-live-on-a-branch.md).

Schema v1 envelope (produced by `build_make_manifest.py`):

```json
{
  "schema": 1,
  "kind": "build" | "archive",
  "meta": { "build": "<tag>", "channel": "stable" | "beta", "publishedAt": "<iso>" },
  "files": { "<exact asset filename>": { … per-file entry … } }
}
```

Per-file entry keys: `name` (file prefix), `version`, `appKey`, `appName`, `arch`
(normalised: `arm64`, `arm`, `all`, `universal`, `x86_64`, `x86`), `fileType`
(`APK` | `Module`), `brandKey`, `brandName`, `variant`, `subVariant`,
`packageName`, `patchSources[]`, `changelogs[]`, `appliedPatches[]`,
`originBuild` (the numbered tag the file came from — carried along when an entry
is merged into an archive, which is how the site still links an archived file to
its build), `publishedAt`.

The `<arch>` token in an asset filename is frozen grammar (parse it only through
`.github/scripts/naming.py`). A manifest records exactly the arches a build
produced, so an app may legitimately list one arch rather than both — the requested
arch is a hard requirement and an absent channel is unbuilt, never a mislabeled
file ([decisions/0007](decisions/0007-requested-arch-is-a-hard-requirement.md)).

An archive envelope restamps `meta` as `{build: <channel>, channel: <channel>,
publishedAt: <merge time>}` while keeping the surviving file entries.

Merge semantics for `state/archive/<channel>.json` (`merge_archive_manifest.sh`):

1. Fetch `origin/main` and read the current cumulative file from its tip. A fetch
   failure **fails the job** — there is deliberately no "start from empty" path,
   which is what eliminated the 2026-09-24 collapse where a failed asset download
   silently restarted the cumulative manifest.
2. Union old + new — **new entries win on a filename collision** — then drop every
   entry whose file no longer exists on the archive release (live filter, read from
   the Releases API). Existence is the releases' business; history is git's.
3. Sanity gate: recompute `|union(old,new) ∩ live|` and refuse to push if the
   result kept fewer entries than that.
4. Commit the two files with `commit_to_main.sh` (retries over concurrent updates; the
   `build` concurrency group is what makes "concurrent" rare).

Recovery order for a damaged `state/archive/*.json`: **git history first**
(`git log -p state/archive/stable.json`, `git show <rev>:state/archive/stable.json`, then commit
the old copy back), then `repair_archive_manifest.py` (dry-run by default), and only while
legacy release assets still exist does `rebuild_manifests_from_releases.py` make sense.

## `update`

Wire format baked into shipped software. A module zip's `module.prop` carries
`updateJson=https://raw.githubusercontent.com/<owner>/<repo>/update/<channel>/<module-id>.json`
— the branch must mirror that path exactly, and `update_json_path()` in
[scripts/utils.sh](../scripts/utils.sh) is the single derivation:

```
module id  <table>-<author>[-beta][-arm64|-arm]     (build.sh composes it)
pointer    <channel>/<id-without-author-or-channel>.json   → stable/youtube.json
                                                      → beta/youtube-arm64.json
changelog  changelogs/<build-code>.md
```

Pointer content: `{ "version", "versionCode", "zipUrl", "changelog" }` — `zipUrl`
points at the **archive** release (`releases/download/<channel>/<file>`), so a
pruned archive asset means a pointer that no longer resolves; that coupling is why
the archive upload precedes the merge step.

Consumers are the KernelSU and Magisk app updaters only. LSPatch is a patching
backend, not an updater — its APKs come from releases/Obtainium and never poll
this branch. **Never "tidy" this layout:** every installed module carries the old
URL and would 404, which is a forced re-flash for the user.

## GitHub Releases

| | Numbered | Archive |
|---|---|---|
| Tags | `260141`, `260140`, … (`YY` + sequence) | `stable`, `beta` |
| Lifetime | append-only; newest 98 survive cleanup | permanent (`releases_keep_keyword`) |
| Contents | this build's APKs + module zips | cumulative, pruned to 2 versions per app+arch |
| Title/body | generated per build | **owner-written**; CI names no metadata |
| Pre-release flag | `--prerelease` on beta runs | set once by hand (`beta` only) |
| `build.json` | no (moved to `state/manifests/`) | no |

Asset filename grammar — the contract every consumer parses:

```
<file-prefix>-v<version>-<arch>.apk                  youtube-morphe-v19.16.39-arm64-v8a.apk
<file-prefix>-module-v<version>-<arch>.zip           youtube-morphe-module-v19.16.39-arm64-v8a.zip
```

A **mirrored** app (`mirror = true`, [CONFIG.md](../CONFIG.md#mirrored-apps)) follows the same
grammar with no brand segment — `bitget-v9.1-arm64-v8a.apk`. The one sanctioned exception is
`keep-filename`: the asset keeps its source's own name, which is recorded in the build record's
`file` field so the manifest step can find it by exact name instead of by prefix; its arch comes
from the same record, never from the name.

`file-prefix` is everything before the first `-v<digit>` or `-module-`
(`naming.py:file_prefix`). Arch spelling is normalised for matching
(`armeabi-v7a` ≡ `arm-v7a`, `all` ≡ `universal`) because the engines of different
patchers write different tokens. Filename-derived arch is a *fallback*: the
manifest's recorded arch is authoritative, and the derivation itself lives in
`naming.py` alone — the website imports that module rather than copying it
([website-contract.md](website-contract.md)).

## `nullcpy/apks` (shared download cache)

A **separate repository**, not a branch: one release per Android package name,
holding the stock APKs and bundles the engine has already fetched, named
`<pkg>-<version>[-<versionCode>]-<arch>.<ext>`. It is download source #1 and is
never consulted for version listing, so it cannot become a rival source of truth
about upstream releases. The engine writes back anything it fetched freshly (never
a copy that came from the cache itself or from `archive`), and
`update_usage_tracker.py` stamps the versions a run consumed into the repo's
`usage.json`, which is what its monthly retention pass keys on.

This repo's Actions cache (`temp/apks`) is a fast local copy of the same
population; both are caches, neither is authoritative. Layout, read/write rules,
retention policy and debugging: [cache-repo.md](cache-repo.md).

## `temp/` (gitignored, but load-bearing locally)

Scratch space for downloads, prebuilts, per-job logs and manifests — plus the
project's habit of keeping **prototype regression harnesses** here
(`test_*.sh`, `_mp/`, `_ver/`, `_metastop/`, …). They are not tracked, so the
references to them in docs and in `.github/scripts/README.md` are pointers to a
maintainer's disk, not to CI. Anything the pipeline must run forever belongs in
`.github/traces/` instead.

## Line endings

[.gitattributes](../.gitattributes) forces LF for `*.sh`, `*.py`, `*.yml`,
`*.json`, `*.toml` and `*.trace` — Windows checkouts with `core.autocrlf=true`
would otherwise inject CRLF, breaking Linux execution and byte-comparing trace
goldens. The engine also normalises `utils.sh` defensively (`dos2unix`) before
sourcing it in CI.
