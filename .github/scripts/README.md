# Release manifest scripts (`build.json`)

Every build produces a `build.json` manifest — a schema-v1, filename-keyed
description of the APKs/ZIPs in that build (app name, version, arch, applied
patches, `originBuild`, ...). Manifests live in exactly one shared place:
`state/` on `main` — `state/manifests/<tag>.json` (a per-build copy) plus the cumulative
`state/archive/<channel>.json` manifests that the website catalog rebuild consumes. Release pages
carry only the files themselves. These scripts implement and repair that
pipeline.

```
builder (utils.sh)                build.yml
      │                                │
      ▼                                ▼
 build.json ──► build_make_manifest.py ──► temp/manifest/build.json
                        │                          │
                        ▼                          ▼ (after archive upload)
            temp/manifest/*.json        merge_archive_manifest.sh
            (not uploaded anymore)       │ writes state/manifests/<tag>.json
                                         │ + merges state/archive/<channel>.json
                                         ▼   (union, live-filter, commit_to_main.sh)
                        main: state/archive/{stable,beta}.json
```

## Per-build pipeline (runs in CI)

### `build_make_manifest.py`
Converts the builder's raw `build.json` into the unified filename-keyed
manifest (`temp/manifest/build.json`) that everything downstream consumes.
Env: `NEXT_VER_CODE` (release tag), `IS_PRERELEASE` (→ channel `beta`/`stable`).

### `generate_release_notes.py`
Writes `build.md`, the numbered release's body, from `build.json` + `build/` at the end of
`build.sh`: apps grouped by patch source (mirrored apps last), per-arch download links, an
applied-patch list per app and a per-app Obtainium link (HTML source on the rolling `stable`/`beta` archive page; its link filter selects that app's file and its version regex reads the app's own version out of the file name - for an app that keeps its source's own file name, whose name embeds a date or hash, the stable lead of the name plus a wildcard, so the link still matches the next build)
(`IS_PRERELEASE=true` marks the beta pool and flips the link's pre-release switch). The same file is
relayed to Telegram, which keeps only the plain Markdown grammar, so GitHub-only markup sits on lines
`build_notify_telegram.sh` drops (`<…`, `![`, `> `, any line holding an Obtainium link). Footer links
come only from the `RELEASE_NOTES_*_LINK` variables — nothing is defaulted. Filename/arch parsing is
imported from `naming.py`, not re-implemented here.

### `obtainium.py`
The one definition of an Obtainium entry for this repository (the complete app object Obtainium reads
back, filter regex, version-detection off, fall-back to older releases, pre-release switch; the link is
the whole deep link percent-encoded once behind `apps.obtainium.imranr.dev/redirect?r=`) — imported by
`generate_release_notes.py` and used as a CLI to regenerate `OBTAINIUM.md`, `obtainium-apps.json` and the
README's apps section from the TOML config (`--configs configs/patches --repo owner/repo --page … --json …
--readme … --manifest archive/stable.json`). The apps section reproduces the apkforge layout: one group
per patch source (MorpheApp's first, the rest A-Z) and a Stock Mirrors group, each a table of App, Arch,
Version (recommended above built), APK Source (the one used), Patches (a dropdown of what the last build applied, and what it did not) and an *Add to Obtainium* badge;
the version and patch cells come from the manifests given with `--manifest` and read *Auto* / *Pending
first build* until a build has published. Pool routing comes from
`compile_patch_configs.py`; its slug rule is a copy of `resolve_slug` in `utils.sh`, which
`.github/traces/test_release_notes.py` runs against the engine's own on awkward input.

### `update_readme.sh`
Refreshes the README's apps section on `main` after a build: runs `obtainium.py --readme` against
`main`'s own copy of the README with `state/archive/*.json` from the same tip, and commits the
result (`README.md` only) with plumbing on `main`'s tip, retrying on a race. Exits 0 with no commit when
nothing changed, and fails loudly when the generation does - the workflow step is `continue-on-error`.
Covered by `.github/traces/test_update_readme.sh`.

### `commit_to_main.sh`
The one writer CI uses for everything it stores on `main` (generated pool configs, watcher state,
build manifests): `commit_to_main.sh "<message>" <path>…`. Plumbing only — a temporary index on
`origin/main`'s tip, named files only (present → added/updated, gone from the worktree → removed),
`[skip ci]`, retry on a race, loud failure. Covered by `.github/traces/test_commit_to_main.sh`.
See [decisions/0008](../../docs/decisions/0008-one-branch.md).

### `build_upload_release.sh`
Unified uploader (native `gh`, per-file retry, `--clobber`). Used for the
numbered release (build outputs) and the archive releases. Note: `gh` names
an uploaded asset after the **local file's basename** — always stage files
under their intended asset name.

Metadata obeys one rule: **a field the caller did not name is not written.**
`RELEASE_TITLE`, `RELEASE_BODY_FILE`, `RELEASE_NOTES` and the tri-state
`IS_PRERELEASE` all mean "leave it be" when unset; whatever is named goes out in a
single `gh release edit`, and when nothing is named there is no call at all. CI's
archive step names none, which makes it a pure asset uploader, while the numbered
step names title, body and channel. `--clobber` stays unconditional on assets.
Per-variable semantics are in the script header; the rationale, the zero-byte
`build.md` case and the rejected alternatives are in
[docs/decisions/0001](../../docs/decisions/0001-release-metadata-ownership.md).

Regression test: `temp/_metastop/test_metadata_write.sh` (stubbed `gh`; walks
exists/create x title x notes-source x prerelease-state, asserts which flags
reach `release edit`/`create`, that CI's archive shape makes no metadata call at
all even with `RELEASE_TARGET` set, that an empty body file counts as unnamed,
and that a bogus `IS_PRERELEASE` is rejected without touching `gh`; Git Bash).

### `merge_archive_manifest.sh`
Merges the current build's manifest into `main`: writes
`state/manifests/<tag>.json` and updates the cumulative `state/archive/<channel>.json`
(union, live-filter against the release's APK/ZIP assets, sanity gate) and
commits both with `commit_to_main.sh`. Run **after** the archive file upload so the live-asset filter sees the
new files. Env: `ARCHIVE_TAG` (`stable`|`beta`), `BUILD_TAG` (this release's
tag), `GITHUB_REPOSITORY`.

Keeping the manifests in git removes the 2026-09-24 incident class by construction: the
previous cumulative manifest is read from `origin/main`, not from a `gh release
download` that can fail into an empty base — a broken `git fetch` fails the
job loudly instead. Remaining guards: the sanity gate recomputes the expected
minimum (`|union(old, new) ∩ live assets|`) and refuses to commit a merge that
kept fewer entries; commit retries re-apply on the new tip of `main`.

Regression tests: `.github/traces/test_manifest_scripts.sh` (stubbed `gh`, local bare `origin`).

## Archive maintenance

### `cleanup-archive-assets.py`
Prunes old assets from the archive releases (size caps). The merge script's
live-asset filter automatically drops manifest entries whose files were
pruned, so the cumulative manifest tracks what is actually downloadable.

### `cleanup_manifests.sh`
Runs in `cleanup.yml` after release deletion: removes `state/manifests/<tag>.json`
from `main` (via `commit_to_main.sh`) when the numbered release no longer exists (same
pattern as `cleanup_update_branch.sh` does for changelogs). `state/archive/*.json`
entries for pruned files drop out at the next build merge (live filter).

### `rebuild_manifests_from_releases.py`
Downloads every live release's `build.json` **asset** and lays out the full
manifest tree (`manifests/*.json` + `archive/*.json`, to be copied under `state/`). Historical
role: seeded the manifest store at migration time (2026-09-25). Since per-build
manifests stopped being uploaded as release assets, `state/` is the sole
store — recovery order is now: ① git history
(`git log -p state/archive/stable.json`, `git show <rev>:state/archive/stable.json`,
commit the old copy back), ② the repair tools below rebuilding from the surviving
window of legacy release assets + a healthy website `data.json`, ③ this
script (only while legacy assets still exist).

## One-time repair tools (manual, dry-run by default)

Both tools are idempotent recovery utilities: run without `--apply` first,
inspect the summary, then re-run with `--apply`.

### `repair_archive_manifest.py`
Rebuilds an **archive** release's cumulative `build.json` from the numbered
releases' own `build.json` assets — used after the merge hardening gap wiped
`stable`. Merges entries whose filenames still live on the archive (newest
`originBuild` wins); files whose originating numbered release has already been
deleted are recovered from the website catalog (`--data-json`, pass a
pre-incident `data.json` revision from git history — its
`patchSetRef`/`changelogRef`/`patchSourceRef` tables are resolved back into
full entries). Only what neither source covers gets filename-derived fallback
entries — those render as degraded "patched" wrapper cards on the site, so
check the dry-run's fallback count is acceptable before `--apply`.

```bash
python3 .github/scripts/repair_archive_manifest.py --archive stable          # dry run
git -C ../nullcpy.github.io show <pre-incident-rev>:data.json > /tmp/data_prewipe.json
python3 .github/scripts/repair_archive_manifest.py --archive stable \
        --data-json /tmp/data_prewipe.json                                   # writes output file
```

The repaired file is then committed as
`state/archive/<channel>.json` (the `--apply` flag still uploads a release asset,
which the pipeline no longer reads), then trigger the website's
`rebuild-catalog.yml` (workflow_dispatch) so `data.json` re-folds from it.
Since the branch keeps full history, the first recovery step for a degraded
`archive/*.json` is `git log -p` / `git show <rev>:archive/stable.json` on
the branch itself.

### `backfill_manifests.py`
Backfills **per-release** `build.json` assets into the numbered releases from
the website catalog (`../nullcpy.github.io/data.json`, override with
`DATA_JSON`), adding fallback entries for live assets the catalog doesn't
cover.

```bash
python3 .github/scripts/backfill_manifests.py          # dry run
python3 .github/scripts/backfill_manifests.py --apply  # upload
```

## Shared conventions

### `naming.py`
Single source of truth for filename/catalog-name derivation (`file_prefix`,
arch extraction/normalization). Imported — never copied — by
`build_make_manifest.py`, `backfill_manifests.py`, **and by the website's
`rebuild_catalog.py`** (whose rebuild job sparse-clones `main` and points
`RVB_NAMING_DIR` at this directory). Keep it stdlib-only so it stays importable
across the repo boundary; a change here is live on the site at the next catalogue
rebuild, so run `rebuild-catalog.yml` with `dry_run: true` before merging one.
See [docs/decisions/0006](../../docs/decisions/0006-filename-parsing-is-imported-not-mirrored.md).
