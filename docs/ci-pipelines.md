# CI pipelines

Six workflows in [.github/workflows](../.github/workflows). One watcher decides
*whether* to build; the reusable build job does the building; cleanup keeps
GitHub's limits; notify reports failures.

| File | Name | Triggered by | Concurrency group |
|---|---|---|---|
| [ci.yml](../.github/workflows/ci.yml) | CI | `schedule` (6 UTC crons: ~4 h windows with randomized minutes), `workflow_dispatch` | `ci` |
| [build.yml](../.github/workflows/build.yml) | Build | `workflow_call` only — from `ci.yml` (per pool) or `manual-ci.yml` | `build` |
| [cleanup.yml](../.github/workflows/cleanup.yml) | Cleanup | `workflow_call`, `workflow_dispatch` | `clean` |
| [manual-ci.yml](../.github/workflows/manual-ci.yml) | Manual CI | `workflow_dispatch` (`all` / one config + optional `remove_apks`), followed by cleanup | `ci` |
| [notify.yml](../.github/workflows/notify.yml) | Notify | `workflow_call`, on `failure()` of the caller | — |
| [trace-verify.yml](../.github/workflows/trace-verify.yml) | Trace Verify | `push` touching `scripts/build.sh`, `scripts/utils.sh`, `.github/traces/**`, the release-notes / Obtainium / manifest scripts, `configs/patches/**`, or the generated `README.md` / `OBTAINIUM.md` / `obtainium-apps.json` | `trace-verify` |

Nothing here runs on `push` to `main` except Trace Verify: a push changes
behaviour for the *next* scheduled run, it does not start a build.

The watcher's schedule is a set of 6 UTC crons, one per 4 h window (`0,4,8,12,16,20`),
each with its own randomized minute. GitHub's `schedule` trigger is best-effort —
under load a due run is enqueued late, and a tick that was missed is dropped rather
than back-filled (measured here at 3-4 runs a day against a 4 h cron, each 40 min to
3.5 h late) — so widening the window to 4 h trades redundancy away: a dropped tick
can now leave a gap of up to ~4 h instead of the ~2 h the earlier grid tolerated. The
watcher is idempotent, so an extra tick costs only the check steps unless something
actually moved. Spreading the minutes across each window takes ticks off the
contended :00 and keeps every run off the website's `23 */6` rebuild (no window
shares minute 23). Cadence is still not a guarantee — when a check must happen now,
`manual-ci.yml` is the path.

## The watcher (`ci.yml`)

One job, `check_patch`, decides everything downstream. Order matters because each
step's output is the next step's input:

| Step | Script | What it decides |
|---|---|---|
| Compile Base Configs | `compile_patch_configs.py` | every app's pool membership from `configs/patches/*.toml` |
| Sync Patch Sources | `sync_patch_sources.py` | discovers all `(patches-source, host)` pairs, lists releases on GitHub/GitLab/Codeberg, rewrites `state/patch_sources.json`, prunes sources no config uses, emits `TRIGGER_STABLE`/`TRIGGER_BETA`/`TRIGGER_BLOCKED` and writes `changed_sources.json` |
| Fetch App Versions | `ci_fetch_app_versions.sh` | scrapes current store versions (honours `"_check_only_listed"` in `state/app_versions.json`) |
| Compare App Versions | `compare` step | `TRIGGER_APP_UPDATE` when a tracked app moved |
| Classify triggers | `ci_trigger_flags.sh` | the two questions everyone else asks: `SOURCES_CHANGED`, `ANYTHING_CHANGED` |
| Check Patch App Updates | `ci_check_app_patches.py` | only when `SOURCES_CHANGED`: downloads the changed bundles and hashes them (`state/patch_file_hashes.json`) to find which apps the new patches actually cover |
| Generate configs (JSON) | `ci_generate_configs.sh` | only when `ANYTHING_CHANGED`: writes the pool config each channel will build |
| Resolve effective triggers | `ci_resolve_triggers.sh` | per-channel `TRIGGER_*` **after** generation, and downgrades a trigger to 0 when the resulting pool has no enabled apps |
| Notify telegram | `ci_notify_telegram.sh` | raw vs effective triggers, so a suppressed trigger is visible |
| Commit updated state | `commit_to_main.sh` | commits **only** the named `configs/*_build.json` + `state/*.json` onto `main` (plumbing, `[skip ci]`) |

Two design rules worth preserving:

- **`changed_sources.json` is written once**, by the sync step
  (`derive_source_changes.py`). Config generation, the patch-relevance scan and
  the trigger flags all project from that one record, so three steps can never
  disagree about what moved.
- **Generation is membership-only.** `ci_generate_configs.sh` sets
  `enabled = false` for apps outside this run's change set and never rewrites a
  version: an app whose `patches-version` is a channel keyword keeps the keyword,
  resolved at build time against `state/patch_sources.json`. Stamping a concrete
  tag into the pool config used to create a second artifact that had to agree
  with the state snapshot about what "stable" meant.
- The beta pool keeps one extra gate: an app-version bump alone pulls an app into
  beta only when one of its sources genuinely has `beta_date > stable_date`,
  otherwise the stable pool already covers it.

### What causes a build

| Event | Flags | Effect |
|---|---|---|
| A patch source publishes a release on the stable channel | `TRIGGER_STABLE` | stable pool regenerates and builds |
| …on the beta channel | `TRIGGER_BETA` | beta pool only |
| An app's own version changed in a tracked store | `TRIGGER_APP_UPDATE` | both pools reconsider membership (beta gated as above) |
| A source is blocked or unblocked (`404`/`451`/`403` from the forge) | `TRIGGER_BLOCKED` | regenerates membership, so frozen sources drop out and recovered ones return |
| Nothing moved | all `0` | no config write, no notification, no build |

A blocked source is **skipped**, not retried: neither a retry nor a live listing
recovers a repository that is gone, and the app reappears by itself once the
forge answers again. The deliberate fail-open inside that check is recorded in
[decisions/0003](decisions/0003-blocked-patch-sources-are-skipped.md).

### Ordering and safety rails

- `build_beta` runs first; `build_stable` `needs` it and additionally requires the
  watcher to have succeeded and beta not to have been cancelled. The single
  `build` concurrency group therefore serialises every manifest merge against
  `state/` on `main` — two builders never merge at once.
- `trigger_cleanup` runs on `always()` if either build succeeded.
- `ci_trigger_flags.sh` writes outputs with explicit `if` blocks rather than
  `[ … ] || [ … ] && var=` lists on purpose: under `set -e` a short-circuit list
  whose final command never runs exits non-zero and would kill the step *before*
  it wrote its outputs, silently turning every dependent step into a no-op.

## The build job (`build.yml`)

Called once per pool by the watcher with `config_file` (and optional `remove_apks`), or
dispatched by hand with `config_file: all` (the default), which builds **every app in one run**.
A `plan` job (`build_plan_configs.sh`) turns `config_file` into the matrix of the `build` job:
`all` becomes the stable pool and then the beta pool (a pool with no app is left out, neither
having one is an error), any other value is built as named, and an unknown value fails loudly.
The matrix runs one pool at a time (`max-parallel: 1`: each pool has its own release tag, channel,
archive and manifest merge) and `fail-fast: false`, so a pool that fails does not stop the other.
Everything the job needs to be reproducible lives in that one file, including the tuning knobs —
`PARALLEL_JOBS: "1"` and `UPLOAD_CONCURRENCY: "12"` are workflow env values, not
repo variables, so they are visible in PRs, survive forks, and carry git history
(why: [decisions/0005](decisions/0005-tuning-knobs-live-in-the-workflow.md)).

Step order, with the reason each is where it is:

1. Java 21 (Temurin) → checkout `main` with `fetch-depth: 0` and submodules (full
   history is needed to enumerate existing tags). `configs/` and `state/` come with the
   checkout — they are tracked on `main`.
2. `build_resolve_context.sh` maps the config file to `ARCHIVE_TAG`,
   `IS_PRERELEASE`, `TITLE_SUFFIX` and the Telegram thread — the single owner of
   "which channel is this run".
3. Install Bouncy Castle **only if** `patchers.py needs-bks` says a module in this
   config requires a BKS keystore.
4. `install_keystore.sh` writes the signing identity from secrets.
5. `build_resolve_version.sh` computes `NEXT_VER_CODE` (`YY` + the next 4-digit
   sequence above the highest existing tag/release, e.g. `260141`).
6. Restore the Actions APK cache (`temp/apks`), optionally drop named APKs, then
   `pip install curl_cffi` for the store scrapers. The Cloudflare-bypass sidecar
   runs as a job `service` on `:8000`.
7. `scripts/build.sh <config>` — the engine ([build-engine.md](build-engine.md)).
   `UPLOAD_APKS_REPO` + `APKS_REPO_TOKEN` turn on the shared cache repo;
   `RVB_MORPHE_PASSTHROUGH` and the `RELEASE_NOTES_*_LINK` vars are passed here.
8. `update_usage_tracker.py` (`|| true`), `build_cache_cleanup.sh`, then the cache
   manifest (`size name` pairs) is hashed into the save key so a run that changed
   nothing does not re-upload 8 GB.
9. `build_get_output.sh` lifts `build.md` into a step output (and `build.tmp`,
   which the changelog step prefers as the source so the next build's `build.md`
   append does not corrupt it).
10. `build_make_manifest.py` → `temp/manifest/build.json`.
11. **Upload to release** (numbered): title `Build No. <code>`, body from
    `build.md`, `--prerelease` for beta.
12. **Update changelog and module update files**: `build_update_changelog.sh`
    checks out `update`, writes `changelogs/<code>.md` plus one JSON pointer per
    module zip, and lists the exact paths it created in `.updated_pointers`. The
    next step stages *those* paths explicitly — a `git add -A` on that branch
    would sweep in unrelated dirt. Runs only when modules were built.
13. `git checkout -f main` (dropping the `update` checkout) →
    `build_exclude_from_archive.sh` removes opted-out apps from `build/`.
14. **Upload to release (Archive)**: `continue-on-error: true`, assets only. It
    names no metadata at all, which is deliberate —
    [decisions/0001-release-metadata-ownership.md](decisions/0001-release-metadata-ownership.md).
15. `merge_archive_manifest.sh` merges this build's manifest into `state/manifests/` and
    `state/archive/`, reading the previous archive from `origin/main`'s tip and committing both
    files with `commit_to_main.sh`. Must run **after** the archive upload so its live-asset filter
    sees the new files. Why manifests are files in git and not release assets:
    [decisions/0002](decisions/0002-manifests-live-on-a-branch.md); why on `main`:
    [decisions/0008](decisions/0008-one-branch.md).
16. `update_readme.sh` refreshes the README's apps section on `main`: versions and applied
    patches from `state/archive/*.json`, the app list from `configs/patches/`, both read from
    `main`'s tip, committed as one `README.md`-only commit built with plumbing on `main`'s own tip
    (`[skip ci]`). `continue-on-error`: it is presentation and must never cost a build its
    release; an unreadable generation fails the step loudly rather than reading as "unchanged".
17. `build_notify_telegram.sh` posts the release to the channel's thread.

## Cleanup (`cleanup.yml`)

1. `ophub/delete-releases-workflows` deletes releases and tags, keeping the newest
   **98** and anything matching the keyword `stable`/`beta` — that keyword list is
   the only thing protecting the archive releases from deletion.
2. `cleanup-archive-assets.py` prunes each archive to the **2 newest versions per
   app + architecture** (grouping by `<app>-<arch>.<ext>`, newest by `created_at`).
3. `cleanup_update_branch.sh` drops update pointers and changelogs whose release is
   gone — and does nothing, successfully, when the `update` branch does not exist (an
   apk-only repository never builds a module, which is what creates it; an unreachable
   remote is still an error); `cleanup_manifests.sh` drops `state/manifests/<tag>.json`
   for deleted releases.
4. A `catalog-updated` `repository_dispatch` to `vars.WEBSITE_REPO` (skipped when it
   is unset), authenticated with
   `WEBSITE_DISPATCH_TOKEN` falling back to `APKS_REPO_TOKEN`. `continue-on-error`,
   because the site also rebuilds on its own schedule — a lost dispatch delays the
   catalogue, it does not break it.

## Required secrets and variables

| Kind | Name | Used by | Notes |
|---|---|---|---|
| secret | `GITHUB_TOKEN` (auto) | all | `contents: write` on the jobs that push branches |
| secret | `KEYSTORE_B64`, `KEYSTORE_P12_B64`, `KEYSTORE_PASSWORD`, `KEY_ALIAS` | build | signing identity |
| secret | `APKS_REPO_TOKEN` | build, cleanup | cross-repo write to the cache repo (`vars.APKS_REPO`), doubles as dispatch token |
| secret | `CODEBERG_TOKEN` | watcher | raises Codeberg/Forgejo rate limits |
| secret | `TG_TOKEN`, `WEBSITE_DISPATCH_TOKEN` (optional) | notify steps | |
| var | `APKS_REPO`, `WEBSITE_REPO` | build, cleanup | the stock-APK cache repo and the site repo. **No default**: unset turns the cache (read and write, and the usage tracker) and the `catalog-updated` dispatch off, so a fork never talks to the upstream's repositories |
| var | `TG_CHAT_ID`, `TG_CHAT_ID_BROADCAST`, `TG_THREAD_CI`, `TG_THREAD_STABLE`, `TG_THREAD_BETA`, `TG_THREAD_NOTIFY` | notifications | Telegram destinations. **No default**: with `TG_TOKEN` but no `TG_CHAT_ID` nothing is posted, and an unset thread id is simply not sent |
| var | `RELEASE_NOTES_TG_LINK`, `RELEASE_NOTES_DONATE_LINK`, `RELEASE_NOTES_WEBSITE_LINK` | build | footer links in the generated release body; a link that is unset is left out |
| var | `RVB_MORPHE_PASSTHROUGH` | build | bundle handling escape hatch |

## Log conventions

The Actions log is a product surface here: 60+ apps × several arches in parallel,
and a maintainer reads it on failure.

- `::group::` / `::endgroup::` wrap each build (in pooled mode the parent emits
  them while replaying a child's log, in completion order).
- Engine messages go through `pr` / `wpr` / `epr` (green `+`, `!`, red `-`) and
  `abort` for fatal ones.
- The asset uploader marks each file's progress with `⬆️` (start) and `✅`
  (uploaded), and reports a failed attempt as `::warning::Attempt n/3 failed for
  <file>` before the final `::error::` — so a scan of the log locates the failing
  file.
- `::warning::` and `::error::` are reserved for annotatable problems, and a
  validation rejection that must stop the job writes `::error::` **and** exits
  non-zero (see `IS_PRERELEASE` handling in the uploader).

## Testing a pipeline change

| Change | Cheapest honest verification |
|---|---|
| Engine functions (`utils.sh`) | `bash .github/traces/trace_runner.sh verify` — offline, no network |
| A shell script CI calls | a stubbed-binary harness in `temp/` (see [contributing.md](contributing.md)) |
| Release/upload behaviour | the metadata matrix harness + a `workflow_dispatch` of Manual CI against `configs/config.manual.toml` |
| Watcher gating | Manual CI with a chosen config, or read the previous run's flags in the Actions UI |
| Website-facing formats | rebuild the site catalogue with `dry_run: true` on `rebuild-catalog.yml` |
