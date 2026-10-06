# AI context brief

A dense, checkable digest for an agent working in this repository. Read this
first; follow the links for depth. Nothing here is prose for humans' sake — every
line is either a rule you must obey or a fact you cannot infer from a single file.

## What this is

`nullcpy/rvb` automatically builds patched Android APKs and Magisk/KernelSU
modules (ReVanced-family, Morphe, and others) whenever an upstream **patch source**
or an upstream **app** releases something new, publishes the files to GitHub
Releases, records build metadata in the repository (`state/`), and feeds a static download site
(`nullcpy.github.io`). Detail: [architecture.md](architecture.md).

## Hard rules

1. **`main` is the only long-lived branch.** Code, config (`configs/`) and recorded
   state (`state/`) all live on it. `temp/`, `build/`, `build.json`, `build.md` are
   scratch and gitignored — never commit them, never `git add -A` blindly.
2. CI writes to `main` only through `.github/scripts/commit_to_main.sh "<msg>" <path>…`
   (plumbing: temp index on origin/main's tip, named files only, `[skip ci]`; a path
   missing from the worktree but present on main is removed). The generated
   `*.json` under `configs/`/`state/`, the build manifests and the README apps section
   are the only things it ever writes.
3. **`git pull` before editing `configs/` or `state/`** — CI commits between your edits.
   Hand-edit only `configs/**.toml`; the JSON there and all of `state/` is machine-written.
4. **A field nobody named is not yours to write.** Defaults that assert a value
   (`${X:-false}`, `-n ""`, a synthesised title) are bugs in this codebase, not
   conveniences — see [decisions/0001](decisions/0001-release-metadata-ownership.md).
   Fail loudly on an unrecognised value instead of guessing.
5. **Wire formats are frozen.** Asset filename grammar; `module.prop` `updateJson`
   path (`<channel>/<id>.json` on the `update` branch); manifest schema keys;
   `data.json` schema keys; the `update` branch name (module pointers). Changing one
   orphans installed software or the site's catalogue. Add a key, age it out, or
   bump a schema version — never reinterpret in place.
6. **`.github/scripts/naming.py` is the single implementation of filename and
   architecture parsing.** The website's `rebuild_catalog.py` imports it via a sparse
   clone of `main`; adding a copy on either side reintroduces silent divergence
   ([decisions/0006](decisions/0006-filename-parsing-is-imported-not-mirrored.md)).
7. Every script starts `set -euo pipefail`. Under it, a `[ … ] && var=x` chain whose
   last command may not run **aborts the step** — write `if` blocks before anything
   that must reach `$GITHUB_OUTPUT`. Command substitution discards global/cache
   side effects, so cache-writing functions are called directly.
8. Patcher argv is assembled as strings and evaluated later. Quoting happens in
   exactly one place (`join_args`). Do not add a second quoting site.
9. **Fail loud where data could be silently lost** (branch fetch, manifest merge,
   archive sanity gate, `origin/main` unreadable). **Fail soft where one app must not
   stop sixty** (per-app build, archive upload `continue-on-error`, Telegram, usage
   tracker). Adding a new `|| true` to a metadata path is a regression.
10. Commits: Conventional Commits (`fix(ci):`, `refactor(build):`, `feat(config):`,
    `perf(build):`, `docs:`), **one logical step per commit**, message body explains
    *why*. Multi-line messages via `git commit -F <file>`. Do not push, merge, or
    open releases unless explicitly asked.
11. `.gitattributes` forces LF for `.sh .py .yml .json .toml .trace`. Never write
    CRLF into a script (breaks Linux execution and byte-compared trace goldens).
12. Prototype tests live in `temp/` (gitignored) and are **not** CI gates. Anything
    that must run forever goes to `.github/traces/`. An absence assertion needs a
    negative control in the same harness.
13. Nothing here runs on `push` to `main` except Trace Verify. A workflow change
    takes effect on the next *scheduled* run (every 4 h) or a dispatch.

## File map

| Path | Role |
|---|---|
| `scripts/build.sh` | CLI entry: parses config, resolves defaults/channel routing, fans out `arch = both`, owns the parallel job pool, calls `merge_build_info` |
| `scripts/utils.sh` | engine library (~4.7k lines, 124 functions): TOML access, forge release helpers, prebuilt download, version resolution, scrapers, patching, metadata, module packaging |
| `scripts/cf_get.py`, `apkmirror_search.py`, `uptodown.py` | anti-bot / store access helpers invoked by the engine |
| `.github/workflows/ci.yml` | the watcher: detects changes, regenerates pool configs, decides per-channel build triggers |
| `.github/workflows/build.yml` | reusable build job; owns tuning env (`PARALLEL_JOBS`, `UPLOAD_CONCURRENCY`), keystore, caches, uploads, branch merges |
| `.github/workflows/cleanup.yml` | release/asset pruning + `catalog-updated` dispatch to the site |
| `.github/workflows/manual-ci.yml` | human-triggered single build, including `remove_apks` cache eviction |
| `.github/workflows/trace-verify.yml` | offline regression gate on engine pushes |
| `.github/scripts/` | CI-side tooling; the [index](../.github/scripts/README.md) describes each script's contract |
| `.github/traces/` | fixtures + `curl`/`java` stubs + golden argv files; the engine's safety net |
| `configs/patches/*.toml` | the actual app configuration — one file per patch-source family |
| `state/*.json` | watcher memory: patch source tags/blocked flags, app versions, bundle hashes |
| `state/manifests/`, `state/archive/` | build metadata: one manifest per numbered release + the cumulative `stable`/`beta` archive manifests (schema v1) |
| `module/` | Magisk/KernelSU module template (scripted `module.prop`, `config`, `service.sh`, `action.sh`, bundled binaries) |
| `README.md` apps section, `OBTAINIUM.md`, `obtainium-apps.json` | generated from `configs/patches/*.toml` (+ `state/archive/`) by `obtainium.py`; the README section is refreshed by CI after each build |
| `bin/` | vendored tools: `aapt2`, `htmlq`, `toml/tq` (per-arch), `apksigner.jar`, `dexlib2.jar`, `paccer.jar` |
| `temp/`, `build/`, `build.json`, `build.md` | scratch + outputs; all gitignored |
| `CONFIG.md` | the authoritative TOML key reference |

## Where things live (branches)

| Branch | Holds | Written by |
|---|---|---|
| `main` | code + docs, `configs/` (TOMLs + generated pool JSON), `state/` (watcher JSONs, `manifests/<tag>.json`, `archive/{stable,beta}.json`) | humans (code, TOML); CI via `commit_to_main.sh` (JSON, manifests, README table) |
| `update` | `<channel>/<module-id>.json` pointers, `changelogs/<code>.md` | build job, only when modules were built (never in an APK-only fork) |

Releases: numbered (`260141`) = immutable per-build; `stable`/`beta` = rolling
archives whose metadata CI never touches. External: `nullcpy/apks` = shared
download cache (release per package name). Full detail:
[storage-and-branches.md](storage-and-branches.md) and
[cache-repo.md](cache-repo.md).

## Version resolution precedence (highest first)

1. Explicit `version` in the app's TOML — a tag, or `exp` / `latest` / `beta`.
2. The version the patch bundle advertises under `auto` — a tested compatibility
   guarantee, unlike chasing upstream latest.
3. `state/app_versions.json`, reached only when the CLI advertises nothing.
4. Live latest from the configured download source.

Target `versionCode` derives from patch metadata only. Download source order is
fixed: `cache_repo` → `direct` → `github` → `archive` → `apkmirror` → `uptodown` →
`apkpure` → `apkcombo`. A download is accepted only if its bytes carry the requested
arch (or are universal/arch-agnostic); a wrong single ABI falls through to the next
source and the arch goes unbuilt if none supplies it
([decisions/0007](decisions/0007-requested-arch-is-a-hard-requirement.md)).

## Looks wrong, is intentional

| What you will notice | Why |
|---|---|
| The archive upload step passes no title/notes/prerelease | CI does not own release prose → [decisions/0001](decisions/0001-release-metadata-ownership.md) |
| `--clobber` is unconditional on asset upload | retried runs must be idempotent; absence is not expressible for a file list |
| `continue-on-error: true` on the archive upload, `|| true` on Telegram/usage tracker | one failed upload must not lose the other 60 apps' release |
| `merge_archive_manifest.sh` has no "start from empty" fallback; fetch failure kills the job | the 2026-09-24 archive collapse |
| `get_prebuilts` is called outside `$( )` | it writes `__PREBUILTS_CACHE__`; a subshell discards it |
| `declare -gA JOB_…=()` has explicit empty initialisers | bash 5.3 treats a bare `declare -gA` as unset under `set -u` |
| `dos2unix scripts/utils.sh` before sourcing in CI | defensive against Windows-authored checkouts |
| Blocked patch sources (`404`/`451`/`403`) are **skipped**, not retried | a repository that is gone cannot be recovered by retrying; the app returns when the source does |
| `build.md` is copied to `build.tmp` and the changelog step prefers the tmp | so a later append cannot corrupt the recorded changelog |
| Cleanup keeps 98 numbered releases, 2 archive versions per app+arch, site rebuild retains ≥60% | three different circuit breakers with three different jobs |
| Module auto-update silently off for local builds | no published `update` branch to point a phone at |
| No config sets `cache_repo-dlurl`, yet the cache source always works | `build_rv` synthesises the URL from `UPLOAD_APKS_REPO` + package name → [cache-repo.md](cache-repo.md) |
| There is no download-concurrency knob and no pre-download phase | a prewarm pool was built and reverted as unmeasured complexity → [decisions/0004](decisions/0004-no-download-prewarm-pass.md); the per `pkg+version` flock already collapses duplicates |
| A single-ABI app publishes only one arch and the other is silently absent | the requested arch is a hard requirement; never a mislabeled file — an arm64-only app ships no `arm-v7a` APK and users install the honest artifact → [decisions/0007](decisions/0007-requested-arch-is-a-hard-requirement.md) |
| CI commits to `main` after a build (`docs: refresh the app table … [skip ci]`) | the README apps section carries live versions and patch lists; `update_readme.sh` writes `README.md` only, with plumbing, never anything else on `main` → [ci-pipelines.md](ci-pipelines.md) |
| `mirror = true` apps have no patch source and are never rebuilt by a patch release | they are the stock APK re-hosted, so only the app's own update triggers them → [build-engine.md](build-engine.md#mirrored-apps-mirror_rv) |
| No workflow defaults point at `nullcpy/apks`, the upstream site or its Telegram chats | a fork must opt in to every satellite; an unset value switches the feature off instead of sending traffic to somebody else's repository → [fork-setup.md](fork-setup.md) |
| Tuning values sit in `build.yml` `env:` rather than in config or repo variables | reviewable, fork-safe, git history for the numbers → [decisions/0005](decisions/0005-tuning-knobs-live-in-the-workflow.md) |
| A malformed `patch_sources.json` answers "not blocked" instead of failing closed | fail-open on purpose: the alternative silently skips every app → [decisions/0003](decisions/0003-blocked-patch-sources-are-skipped.md) |
| `configs/stable_build.json` keeps `patches-version: "stable"` rather than a tag | one source of truth (`state/patch_sources.json`) instead of a stamped copy that can go stale |

## Task → start here

| Task | Files | Verify with |
|---|---|---|
| Add/enable/disable an app or patch | `data:configs/patches/*.toml` ([CONFIG.md](../CONFIG.md)) | Manual CI on `configs/config.manual.toml` |
| Fix a scraper / download source | `scripts/utils.sh` (`dl_<source>`, `get_<source>_resp/vers`) | trace harness + a single-app manual build |
| Debug a cache miss or a vanished stock APK | `dl_cache_repo`, `usage.json` in `nullcpy/apks` | [cache-repo.md](cache-repo.md) debugging checklist |
| Change patch invocation/flags | `scripts/utils.sh:patch_apk`, `.github/scripts/patchers.sh` | `trace_runner.sh verify` (goldens will diff — read them) |
| Change release upload semantics | `.github/scripts/build_upload_release.sh` | stubbed-`gh` metadata matrix harness |
| Change what gets built when | `.github/scripts/ci_*.sh` and `.py` | read the previous run's flags; dispatch CI |
| Change manifest/catalogue format | `build_make_manifest.py` (+ `naming.py`, shared by import) then site `rebuild_catalog.py` | site rebuild `dry_run: true` + diff |
| Change module update wiring | `scripts/utils.sh:update_json_path/module_prop`, `build_update_changelog.sh` | inspect `update` branch after a build |
| Tune concurrency/timeouts | `.github/workflows/build.yml` env | Actions run timings |

## Commands

```bash
bash .github/traces/trace_runner.sh verify           # offline engine regression gate
bash .github/traces/trace_runner.sh capture          # re-record goldens after intent change
bash scripts/build.sh configs/config.manual.toml     # real build (network + java + jq)
bash scripts/build.sh clean                          # reset temp/ build/ build.md
python3 .github/traces/test_release_notes.py         # release notes, Obtainium links, generated docs in sync
bash .github/traces/test_mirror.sh                   # mirrored-app engine path
python3 .github/scripts/obtainium.py --configs configs/patches --repo softpyscho/rvb \
        --page OBTAINIUM.md --json obtainium-apps.json --readme README.md   # regenerate the app table and Obtainium files
gh run list --repo nullcpy/rvb                       # what ran and how
```

## Glossary

**pool** — one channel's generated config (`configs/{stable,beta}_build.json`) and
the build run from it. **channel** — `stable` | `beta`, the only two keywords.
**watcher** — `ci.yml`, which decides whether anything needs building. **prebuilts**
— the patcher CLI jar + patch bundles downloaded per source release. **bundle** — a
multi-APK container (`.xapk`/`.apkm`/`.apks`). **manifest** — a schema-v1,
filename-keyed JSON of what a build produced. **pointer** — a module's
`<channel>/<id>.json` update record. **archive release** — the rolling `stable` /
`beta` release. **golden** — a recorded expected argv trace under `.github/traces/goldens/`.
