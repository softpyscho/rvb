# Build engine

`scripts/build.sh` (entry) + `scripts/utils.sh` (library, ~4700 lines, 124
functions). This is the part that turns one TOML table into a signed APK and a
Magisk module zip.

## Entry point and invariants

```bash
bash scripts/build.sh configs/stable_build.json   # CWD must be the repo root
bash scripts/build.sh clean                       # remove temp/, build/, build.md
```

- `build.sh` sources its sibling `utils.sh` explicitly and exports `RVB_UTILS_SH`
  so pooled children can re-source it.
- Requires `jq`, `java`, `zip`; `python3` is optional (release notes and TOML
  fallbacks). Repo tools live in `bin/`: `aapt2`, `htmlq`, `toml/tq` (per-arch
  binaries), `apksigner.jar`, `dexlib2.jar`, `paccer.jar`.
- Everything transient goes under `temp/` (gitignored); everything shippable goes
  to `build/`. `build.json` is the machine record, `build.md` the human one.
- The engine never fails the whole run for one app: per-app failures log and
  continue; only "no output at all" aborts (`All builds failed.`).

## From config to a build request

`toml_prep` converts the config to JSON (native `tq` binary, `python3` fallback)
and the file splits into a **main table** (file-level defaults: `patches-version`,
`patches-source`, `cli-source`, `brand`, `variant`, `arch`, `author`, …) and one
table per app. For each enabled table `build.sh`:

1. Inherits every key from the file-level default when the app omits it.
2. Resolves `patches-version = "both"` from the file being built — a beta-named
   config *is* the beta pool (`configs/beta_build.json`, `*.beta.toml`).
3. Validates the enum keys hard (`arch`, `build-mode`, `include-stock`,
   `*-source-host`, boolean `inclusive-patches`) and rejects quote-less patch
   lists, because `list_args` splits on quoted tokens.
4. Refuses `inclusive-patches` together with `exclusive-patches` — they are
   opposites, and the ambiguity would be resolved by argument order.
5. Calls `get_prebuilts` to fetch the CLI jar and every patch bundle, then builds
   the `app_args` associative array, including the aggregated `patches_ref` and
   `changelog_url` derived from the **exact** bundle resolved for this build.
6. `mirror = true` skips steps 3–5 for that app: no CLI and no bundle are fetched, any
   patch-selection key (`patches-source`, `cli-source`, `included-patches`,
   `excluded-patches`, `exclusive-patches`, `inclusive-patches`, `patcher-args`,
   `patched-pkg-name`, `include-stock`) or a non-`apk` `build-mode` is a hard error rather
   than silently ignored, and `keep-filename` on a patched app is one too. The build is
   handed to `mirror_rv` ([below](#mirrored-apps-mirror_rv)).
7. `arch = both` fans out into two builds, `arm64-v8a` and `arm-v7a`, each with
   its own module-id suffix (`-arm64` / `-arm`).
8. Beta builds get `-beta` appended to the module id automatically, so a phone's
   module updater never crosses channels.

`get_prebuilts` must be called directly rather than inside `$( )`: it writes the
`__PREBUILTS_CACHE__` global, and a subshell would discard it.

## Parallel pool (`PARALLEL_JOBS`)

The only knob is the env var set in [build.yml](../.github/workflows/build.yml)
(`PARALLEL_JOBS: "1"` in this fork); no config file can change it. `1` — the historical
default — runs the original sequential path untouched. Above that, each table
build becomes a fresh `bash -c` child that re-sources `utils.sh`:

- per-job globals (`PATCHER_*`, `PATCH_OUTPUT`, every in-process cache) are
  therefore isolated by construction, which is what makes concurrency safe;
- children write `temp/queue/<id>.log` plus an `rc` file; the parent replays
  finished logs inside their own `::group::` in completion order, so the Actions
  log stays as clean as the serial one;
- the wrapper runs `set +e` so it can record a failing child's rc, and a child
  killed externally without an rc file gets a synthesised `137` rather than
  hanging the drain;
- `INT` kills in-flight children before running the normal abort sweep.

The `=()` initialisers on the job arrays are required: bash 5.3 treats a bare
`declare -gA` as unset under `set -u`. Why the knob is a workflow env value and not
a config key: [decisions/0005](decisions/0005-tuning-knobs-live-in-the-workflow.md).
There is no second pool for downloads either — a prewarm pass was built and reverted
for adding surface without a measured gain
([decisions/0004](decisions/0004-no-download-prewarm-pass.md)).

## Mirrored apps (`mirror_rv`)

`mirror = true` re-hosts an app's stock APK **unmodified**, so a phone can track it from
this repository's releases (Obtainium has nothing to follow for an app that publishes no
release of its own). `build_rv` hands such an app to `mirror_rv` before doing anything
else, which:

1. picks the first download source that answers (the usual `DL_SRCS` order; `archive` and
   `cache_repo` are skipped when the version has to be discovered), then takes `latest` as
   the highest version that source lists, or the pinned `version` verbatim — `auto`, `exp`
   and `beta` are refused because there is no patch bundle to resolve them against;
2. downloads through the same `dl_<source>` helpers and applies the same gates as a patched
   build: valid zip with a manifest, package identity (`_meta_field_of`),
   `verify_downloaded_apk`, and the arch-honesty gate
   ([decisions/0007](decisions/0007-requested-arch-is-a-hard-requirement.md));
3. publishes `build/<app-slug>-v<version>-<arch>.apk` — the ordinary grammar, with no brand
   segment — and records a `write_build_info` entry with `brand` `Mirror` (unless named),
   no patch source, and no applied patches.

What differs from `build_rv`, on purpose: no stock-APK cache (the Actions cache and the cache
repo are not consulted or fed — a mirror downloads once per new upstream version and the
release is the store); a bundle source is merged to one APK by the `dl_*` helper, which
**re-signs** it, so a plain-APK source is preferable and a signed-bundle mirror cannot update
over a store install; and for `github`/`direct` sources, where the config names the exact
file, a package-id mismatch is a warning and the id found in the APK is the one published
(that id is what Obtainium matches against the installed app), while a store scrape still
rejects a mismatch. The download loop is deliberately a short second copy rather than a flag
threaded through `build_rv`; a gate added to one belongs in the other. Covered offline by
`.github/traces/test_mirror.sh`.

`keep-filename = true` (mirror only, `github` source only) publishes the release asset under its
own sanitised name instead of the grammar — for builds like a nightly that have no version
number to put in a name. `write_build_info` then records that exact name in a `file` field and
`build_make_manifest.py` finds the artifact by it instead of by `<prefix>-v`, taking the arch
from the build record rather than from a filename token it cannot trust.

The watcher treats a mirrored app as unpatched too: `sync_patch_sources.py` does not let it keep
a patch source alive and `ci_check_app_patches.py` never counts it as covered by a bundle, so it
is rebuilt only when the app itself updates.

A `github` source reports versions in one of two ways. An ordinary release is tagged with its version
(`v1.2.3`) and the tag is the answer. A **release-per-package** release — tagged with the package name
itself (`releases/tag/com.instagram.android`), the shape of the apks cache and of self-hosted stock
releases — is a store of whatever was uploaded, under whatever names the uploader chose. It is told apart
by the tag equalling `pkg-name` (`_github_release_per_package`; without a known package name, as in the
watcher, the tag is reported as before) and is treated like `archive` and `cache_repo`: **never the
authority on "latest"**. When a version has to be discovered, the source loops in `build_rv` and
`mirror_rv` skip it and take the version from the next source; it stays in the download loop, which asks it
for that version. Only assets named `<pkg>-<version>[-<code>]-<arch>.<ext>` ever yield a version
(`_versions_from_asset_names`, shared with `archive`) — a raw store download kept under its own file name
yields none, rather than a version made of the file name.

A mirrored app whose github release holds exactly one APK-like asset and no `github-regex` re-hosts that
asset whatever it is called; with several, the usual name-based selection (and its failure) stands rather
than a guess.

## `build_rv`, stage by stage

1. **Identity** — resolve display name/slug, package name (a `pkg-name` of its
   own, or inferred from a GitHub/archive release-tag URL).
2. **Patch selection** — `inclusive-patches` is expanded *here* into explicit
   patch names via `_all_patch_names`, with excluded names removed from the
   expansion rather than passed as both include and exclude. Downstream code keeps
   reading one `included-patches` string and never learns the flag. Per-bundle
   `-e`/`-d` lists are joined by `join_args` (the single escaping point, which is
   what makes apostrophes in patch names survivable) and `|`-separated per
   bundle, so multi-source apps can address each bundle individually.
3. **Version resolution** — `_resolve_list_and_version` implements the
   precedence: explicit `version` from the config (a tag, or `exp`/`latest`/`beta`)
   → the version the patch bundle advertises under `auto` (a tested compatibility
   guarantee) → `state/app_versions.json` (only when the CLI advertises nothing) →
   live latest from the source. The target `versionCode` is derived from patch
   metadata only, and `has_compatible_patches` gates the build on the bundle
   actually covering the resolved version.
4. **Stock acquisition** — see the source order below. Bundles
   (`.xapk`/`.apkm`/`.apks`) are kept whole and handed to morphe untouched when
   `RVB_MORPHE_PASSTHROUGH=true` (morphe merges natively, and some APKs misbehave
   after `apkeditor`'s rewrite + re-sign); otherwise `merge_splits` flattens them.
   `verify_downloaded_apk` then checks the payload really is the requested
   package/version/arch before anything is patched. An **arch-honesty gate** follows:
   the artifact's real ABIs are read off its bytes (`_artifact_abis`) and, unless it
   carries the requested arch or is universal/arch-agnostic, the download is rejected
   and the run falls through to the next source — the arch goes unbuilt if no source
   supplies it, so no file is ever named for an ABI it does not contain
   ([decisions/0007](decisions/0007-requested-arch-is-a-hard-requirement.md)).
   APKPure/APKCombo/Uptodown links carry no ABI in the URL, so the first build to want
   one fetches it **once** and records its bytes in `temp/urlindex`; a later job that
   resolves the same link adopts the stored blob (right arch) or skips the source
   (wrong arch) with no network hit. Universal bundles are cached under the shared
   `-all` key and reused by both arch jobs from that single fetch.
5. **Arch trimming** — bundles go through `_trim_bundle_for_arch` (config members
   filtered by ABI); plain APKs get foreign `lib/<abi>/*` entries removed with
   `zip -d`. Result is cached as `<prefix>-<version>-<arch>.stripped.<ext>`, and
   `all`/`universal` ships the raw bundle.
6. **Patching** — `patch_apk` dispatches on the tool kind resolved by the patcher
   registry (see below) and records which patches the tool reports as applied.
7. **Naming and metadata** — `aapt2`/`aapt` re-reads the patched manifest, so a
   patcher that rewrote the package id is recorded honestly; output is
   `<file-prefix>-v<version>-<arch>.apk`; `write_build_info` appends the record
   that becomes the release manifest.
8. **Module mode** (`build-mode` `module`/`both`) — the `module/` template is
   copied to a scratch dir, `module_config` writes `config`
   (`PKG_NAME`/`PKG_VER`/`MODULE_ARCH`), `module_prop` writes `module.prop` and —
   only in CI, never for local builds — an `updateJson` URL built by
   `update_json_path()`. Output: `<file-prefix>-module-v<version>-<arch>.zip`.
9. **Finalisation** — `merge_build_info` folds per-job fragments into
   `build.json`, scratch state is swept, `generate_release_notes.py` writes
   `build.md` for the release body.

## Download sources, in priority order

`DL_SRCS` in [utils.sh](../scripts/utils.sh) is the order every app is attempted
in; the first source that yields a verified artifact **carrying the requested arch**
(see the arch-honesty gate above) wins:

| # | Source | Notes |
|---|---|---|
| 1 | `cache_repo` | `nullcpy/apks` — release per package name, download-only (never used to list versions) → [cache-repo.md](cache-repo.md) |
| 2 | `direct` | a straight file URL in the config |
| 3 | `github` | release assets, filtered by `github-release-regex` / `github-regex`, arch-mapped |
| 4 | `archive` | `archive.org` item, the long-term fallback for delisted versions |
| 5 | `apkmirror` | universal-bundle strategy; package/version read from the HTML |
| 6 | `uptodown` | |
| 7 | `apkpure` | XAPK handling in `_apkpure_install_xapk` |
| 8 | `apkcombo` | trusts the served filename over its object key |

Supporting machinery:

- **Anti-bot routing** — a Cloudflare-bypass sidecar (`CF_SOLVER_URL`, the
  `ghcr.io/sarperavci/cloudflarebypassforscraping` service in `build.yml`), asked
  about the **effective URL after redirects**, not the request URL; `curl_cffi`
  (`scripts/cf_get.py`) for TLS-fingerprint walls.
- **Transfer guards** — `_req` sets connect *and* absolute ceilings plus a low-
  speed stall guard, because a mirror that trickles would otherwise hold a build
  slot forever.
- **Locks** — per-package download locks under `temp/dllocks` stop parallel jobs
  fetching the same APK twice; rejected downloads sweep their sibling bundle
  files so the post-loop scan cannot adopt a partial artifact.
- **Response caches** — `__DL_RESP_CACHE__` and friends keep a run from
  re-scraping the same page per architecture.

## Cache layers

| Layer | Location | Keyed by | Written by |
|---|---|---|---|
| Actions cache | `temp/apks` on the runner | `apks-<hash of size+name manifest>` | `build.yml` restore/save |
| Shared APK cache | `nullcpy/apks` releases | tag = package name | the engine, after a successful fresh download (`UPLOAD_APKS_REPO`, `GH_TOKEN=APKS_REPO_TOKEN`) |
| Prebuilt tools | `temp/<host>__<owner>__<repo>-rv` | patch source / CLI release | `get_prebuilts` |
| In-process | `__PREBUILTS_CACHE__`, `__PATCH_VER_CACHE__`, `__PKG_VERS_CACHE__`, `__DL_RESP_CACHE__` | per job | memoised lookups |

`build_cache_cleanup.sh` keeps `temp/apks` under an 8 GB watermark with tiered
retention (30/14/7/3 days) so the Actions cache stays below GitHub's 10 GB
per-repo limit. `update_usage_tracker.py` posts the versions actually consumed
(`temp/used_versions.txt`) back to the cache repo, whose own monthly retention pass
keeps the 10 newest versions per package and everything used in the last 30 days —
see [cache-repo.md](cache-repo.md).

## Patcher registry

`.github/scripts/patchers.sh` (sourced by the engine, overridable with
`RVB_PATCHERS_SH` for tests) owns `resolve_patcher` and the `PATCHER_*` flags:
which tool kind this is, whether it lists patches, whether it needs a mount arg,
how its output is recovered. `.github/scripts/patchers.py` answers the CI-side
question `needs-bks` (does this config contain an Xposed module that requires
Bouncy Castle for BKS keystores?). Adding a tool means editing the registry, not
`build_rv`.

## Signing and identity

| Env var | Default | Purpose |
|---|---|---|
| `RVB_KEYSTORE` / `RVB_KEYSTORE_P12` | `ks.keystore` / `ks-p12.keystore` | signing identity; CI writes them from `KEYSTORE_B64` / `KEYSTORE_P12_B64` via `install_keystore.sh` |
| `RVB_KEYSTORE_PASS` / `RVB_KEY_ALIAS` | upstream defaults | overridden by secrets in CI |
| `RVB_MORPHE_PASSTHROUGH` | `true` | keep bundles whole for morphe instead of merging at download time |
| `RVB_INSTAFEL_FALLBACK_COMMIT`, `RVB_INSTAFEL_DEFAULT_PATCHES` | see source | used when the InstaFel CLI manifest has no commit hash or a config omits `included-patches` |

Signature identity is not cosmetic: patched apps that lose the expected signer
cannot update in place, so `check_sig` exists and the keystore is a CI secret
rather than a repository default.

## Guardrails

The tool-decision branches of `utils.sh` are covered by the offline trace
harness — fixtures, stubbed `curl`/`java`, golden argv files, verified on every
push to `build.sh`/`utils.sh`. See
[.github/traces/README.md](../.github/traces/README.md). Helper-level tests for
cache and bundle functions sit beside it; behavioural tests for individual shell
fixes live in `temp/` (gitignored) by convention, and the ones worth keeping are
listed in [contributing.md](contributing.md).
