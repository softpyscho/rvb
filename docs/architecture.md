# Architecture

## The system at a glance

```
   patch sources (github/gitlab/codeberg)         app sources (stores & mirrors)
   MorpheApp, ReVanced, anddea, Piko, devanced…   APKMirror, Uptodown, APKPure,
        │                                         APKCombo, archive.org, GitHub,
        │ watcher lists releases, every 4 h       direct URL, shared APK cache
        ▼                                              │
 ┌──────────────────────────────────────┐              ▼
 │ nullcpy/rvb  (this repo)             │      ┌──────────────────┐
 │  main     code, workflows, docs,     │      │  nullcpy/apks    │
 │           configs/ + state/ (incl.   │      │  shared APK cache│
 │           manifests/ + archive/)     │      │  + usage stats   │
 │  update   module pointers (if any)   │      └──────────────────┘
 │  Releases numbered + stable + beta   │
 └──────────────────────────────────────┘
        │            ▲        │
        │            │        │ clone state/ of main (manifest input)
        │            │        ▼
        │            │   ┌────────────────────────────────────────┐
        │            │   │ nullcpy/nullcpy.github.io              │
        │            │   │  rebuild-catalog.yml → data.json       │
        │            │   │  GitHub Pages: index.html + script.js  │
        │            │   └────────────────────────────────────────┘
        │            │                 ▲
        └────────────┼─────────────────┘
          catalog-updated repository_dispatch (from cleanup.yml)
```

Four moving parts: **this repo** builds and publishes, the **`apks` repo** is a
shared download cache, **`state/manifests/` + `state/archive/`** on `main` are the build-metadata store, and
**`nullcpy.github.io`** folds that store into the `data.json` the site renders.

## Repositories

| Repo | Role | Written by |
|---|---|---|
| `nullcpy/rvb` | The builder: engine, CI, patch configs, artifacts | CI + maintainer |
| `nullcpy/apks` | Cross-run cache of downloaded stock APKs/bundles plus a usage tracker | CI (`GH_TOKEN`/`APKS_REPO_TOKEN`, `vars.APKS_REPO`) |
| `nullcpy/nullcpy.github.io` | The download site: catalogue generator + static Pages UI | CI rebuild + maintainer |

The site is a separate repository with its own guide; this folder documents only
the seam between them → [website-contract.md](website-contract.md).

## Branches of this repo

`main` is the one long-lived branch ([decisions/0008](decisions/0008-one-branch.md)). Code, config
and recorded state sit in separate directories with separate writers:

| On `main` | Contains | Sole writer | Read by |
|---|---|---|---|
| engine, workflows, scripts, `module/`, `bin/`, docs | code | maintainer | every job |
| `configs/patches/*.toml`, `configs/config.manual.toml` | the app configuration | maintainer | watcher, builds |
| `configs/{stable,beta}_build.json`, `state/*.json` | generated pool configs, watcher memory | watcher (`commit_to_main.sh`) | watcher, builds |
| `state/manifests/<tag>.json`, `state/archive/{stable,beta}.json` | build metadata | `merge_archive_manifest.sh` (build), `cleanup_manifests.sh` (prune) | `obtainium.py`; a catalogue site, if any |

Only one other branch can ever exist: `update` (`changelogs/<code>.md` + `<channel>/<module-id>.json`
pointers, written by `build_update_changelog.sh` and pruned by `cleanup_update_branch.sh`), created by
the first build that makes a module zip — read by KernelSU / Magisk updaters at phone-check time.

Details, recovery procedures and the wire formats: [storage-and-branches.md](storage-and-branches.md).

## Releases

Two classes, and the distinction is load-bearing:

- **Numbered** (`260141`, `260140`, …) — one per build, append-only, immutable.
  Title `Build No. <code>`, body generated from that build's APK list by
  `generate_release_notes.py`, `--prerelease` for beta-channel runs. Holds that
  run's files. The build number is `YY` + a 4-digit sequence derived from the
  highest existing tag/release (`build_resolve_version.sh`).
- **Archive** (`stable`, `beta`) — two rolling releases that accumulate every
  build's files. Assets are overwritten in place (`--clobber`) and pruned by
  `cleanup.yml`, which keeps the **two newest versions per app + architecture**
  (`cleanup-archive-assets.py`). Their title, notes and pre-release badge are
  **owner-written**: the archive upload step names no metadata at all, so CI
  touches files only → [decisions/0001-release-metadata-ownership.md](decisions/0001-release-metadata-ownership.md).

Per-build `build.json` is **no longer a release asset**; `state/manifests/` and
`state/archive/` on `main` are the only manifest store (completed 2026-09-25; moved from a
`website` branch to `main` on 2026-10-06).

## Patched and mirrored apps

Most apps are **patched**: stock APK → patch bundle → signed APK. An app with `mirror = true` is
**mirrored**: the stock APK is downloaded, checked (package, signature, ABI) and republished
unmodified so that apps without a release page of their own can be followed from these releases
([build-engine.md](build-engine.md#mirrored-apps-mirror_rv)). Both kinds share the filename grammar,
the manifests and the releases, and both are delivered to phones through Obtainium
([OBTAINIUM.md](../OBTAINIUM.md)).

## Channels and pools

`stable` and `beta` are the only channel keywords. They are routing, not
versioning:

- `patches-version = "stable"` (the default) → the app is compiled into the
  **stable pool** only.
- `"beta"` → beta pool only; `"both"` → both, resolved per config file at build
  time (`build.sh` reads the file it was given: a beta-named config *is* the beta
  pool).
- A concrete value (`"v4.8.3"`) pins that release; it survives generation
  verbatim and nothing rewrites it.
- Keywords are resolved at build time against `state/patch_sources.json` — the
  watcher's record of each source's current release per channel — rather than
  being stamped into the config, so a build is consistent with the state snapshot
  it was generated from (`configs/` and `state/` always come from the same `main`
  commit).

Channel decides three downstream things: which generated config is built
(`configs/stable_build.json` / `beta_build.json`), which archive release receives
the files, and the `-beta` module-id suffix that gives Magisk modules an
independent update channel.

## One build, end to end

**Watcher** — `ci.yml`, 6 UTC crons on a 4 h window grid with randomized minutes
(GitHub's scheduler is best-effort and drops missed ticks — see
[CI pipelines](ci-pipelines.md)), concurrency group `ci`:

1. Checkout `main`: `configs/` + `state/` come with it.
2. `compile_patch_configs.py` regenerates the two pool configs from the TOMLs.
3. `sync_patch_sources.py` lists every patch source's releases → writes
   `state/patch_sources.json` (per-channel tag + date + `blocked` flag) and
   reports whether stable/beta moved.
4. `ci_fetch_app_versions.sh` + `ci_compare_app_versions.sh` scrape the app
   stores for current versions and compare with `state/app_versions.json`.
5. `ci_trigger_flags.sh` is the single owner of "is there any work left";
   `ci_check_app_patches.py` checks whether new patches cover known app versions;
   `ci_generate_configs.sh` rewrites the pool configs for the apps that changed.
6. `commit_to_main.sh` commits the generated `configs/*_build.json` + `state/*.json` onto
   `main` — named files only, so a hand-edited TOML can never ride along.
7. Outputs `trigger_stable` / `trigger_beta` gate the two build calls: beta
   first, then stable (`needs: build_beta`, and only if the watcher succeeded).

**Build** — `build.yml`, once per pool, concurrency group `build`, with a
Cloudflare-bypass sidecar service on `:8000`:

1. Checkout `main` (full history, submodules) →
   `build_resolve_context.sh` maps the config file to `ARCHIVE_TAG`,
   `IS_PRERELEASE`, Telegram thread and title suffix.
2. Install Bouncy Castle only if a BKS-needing Xposed module is in the config;
   install the signing keystore from secrets.
3. `build_resolve_version.sh` computes `NEXT_VER_CODE`; the Actions APK cache is
   restored and the `nullcpy/apks` repo cache is available to the engine as the
   highest-priority download source.
4. `scripts/build.sh configs/<pool>_build.json` runs the engine →
   [build-engine.md](build-engine.md). Output: `build/` files, `build.json`,
   `build.md`.
5. `update_usage_tracker.py` records which app versions this run consumed;
   `build_cache_cleanup.sh` trims the local APK cache against an 8 GB watermark.
6. `build_make_manifest.py` converts `build.json` into the schema-v1 manifest;
   the numbered release is uploaded (`RELEASE_BODY_FILE=build.md`,
   `IS_PRERELEASE` from the channel).
7. `build_update_changelog.sh` + a scoped `git add` publish module pointers and
   this build's changelog to `update`.
8. `build_exclude_from_archive.sh` drops opted-out apps from `build/`, then the
   **archive** upload runs — assets only, no metadata named.
9. `merge_archive_manifest.sh` merges this build's manifest into `main`
   (`state/manifests/<tag>.json` + cumulative `state/archive/<channel>.json`), live-filtered
   against the archive release's actual files.
10. `update_readme.sh` refreshes the README's apps section on `main` (versions and applied patches
    from the manifests just merged) — the one generated file CI writes to `main`'s code.
11. Telegram notification for the build.

**Cleanup** — `cleanup.yml`, called after a successful build:

1. `ophub/delete-releases-workflows` deletes old releases/tags, keeping the
   newest 98 and anything matching `stable`/`beta`.
2. `cleanup-archive-assets.py` prunes archive assets to 2 versions per app+arch.
3. `cleanup_update_branch.sh` and `cleanup_manifests.sh` drop pointers and
   manifests whose releases are gone.
4. A `catalog-updated` `repository_dispatch` pings the website repo, which
   re-folds `data.json` and redeploys Pages. A missed dispatch is not lost: the
   site also rebuilds on its own `23 */6 * * *` schedule.

Failure of any `notify.yml` path is non-fatal to the pipeline; the notify workflow
only fires on `failure()`.

## Where truth lives

| Question | Authoritative source |
|---|---|
| Which apps exist, with which patches, on which channel | `configs/patches/*.toml` |
| Which pool an app lands in | that TOML's `patches-version`, resolved by `build.sh` |
| What version a patch source is on | `state/patch_sources.json` (watcher-written) |
| Which app versions are current in the stores | scraped live; `state/app_versions.json` only tracks what a CLI cannot report |
| What went into a build | `state/manifests/<tag>.json` |
| What is downloadable right now | the GitHub Releases API (existence, size, download counts) |
| What the website shows | `nullcpy.github.io:data.json`, derived — never hand-edited except to fix a bad fold |
| What module id polls for updates | `updateJson` baked into `module.prop`, mirroring `update_json_path()` |

## Failure policy, and why it is asymmetric

- **Destructive or silent-wrong-data paths fail loudly.** An unreadable
  `origin/main` when merging the archive manifest, or an archive merge that keeps fewer
  entries than the sanity gate computes are hard failures. The 2026-09-24
  archive collapse happened because a download failure silently started from an
  empty base; reading the previous state from git made that path unrepresentable.
- **Per-app and notification paths fail soft.** One broken app must not lose the
  other 60: `build_rv` failures log and continue, `continue-on-error: true` covers
  the archive upload and Telegram, `update_usage_tracker.py` is `|| true`.
- **Re-runs must be idempotent.** Asset uploads use `--clobber` and a 3-attempt
  per-file retry; catalogue pushes rebase and retry; the repair tools are dry-run
  by default.

## Coupling hazards worth knowing before editing

- **The site imports rvb's filename rules.** `rebuild_catalog.py` resolves
  `.github/scripts/naming.py` from a sparse clone of this repo's `main`
  (`RVB_NAMING_DIR`) rather than mirroring it, so moving that path breaks the
  catalogue rebuild — loudly. The dependency is one-way and intentional;
  [decisions/0006](decisions/0006-filename-parsing-is-imported-not-mirrored.md).
- **Wire formats that are already in the wild.** `updateJson` paths baked into
  installed modules, `module.prop` shape, `data.json` schema keys, and the
  `state/manifests/`+`state/archive/` layout (formerly the `website` branch's `manifests/`+`archive/`). Renaming any of them orphans existing clients.
- **`configs/` and `state/` are tracked and CI commits to them.** `git pull` before you edit
  `configs/`; hand-edit only the TOMLs.
- **Everything downstream of `merge_build_info`** assumes `build.json` keys match
  what the engine wrote for each table build — the manifest, the release notes
  and the site all read the same record.
