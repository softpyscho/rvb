# Config

Adding another revanced app is as easy as this:
```toml
[Some-App]
apkmirror-dlurl = "https://www.apkmirror.com/apk/inc/app"
# or uptodown-dlurl = "https://app.en.uptodown.com/android"
```

> [!WARNING]
> When a patch name itself contains a single quote, double it inside the string (e.g. 'Hide ''Get Music Premium''').

## More about other options:

There exists an example below with all defaults shown and all the keys explicitly set.  
**All keys are optional** (except download urls) and are assigned to their default values if not set explicitly.  

```toml
compression-level = 9                # module zip compression level
remove-rv-integrations-checks = true # remove checks from the revanced integrations
dpi = "320dpi nodpi"            # dpi packages to be searched in order. 'auto' matches whatever is available. default: "nodpi anydpi auto"

patches-source = "revanced/revanced-patches" # where to fetch patches bundle from. default: "MorpheApp/morphe-patches"
patches-source-host = "github"               # source host for patches: "github", "gitlab" or "codeberg". default: "github"
cli-source = "ReVanced/revanced-cli"             # where to fetch cli from. default: "MorpheApp/morphe-desktop"
cli-source-host = "github"                       # source host for cli: "github", "gitlab" or "codeberg". default: "github"
# options like cli-source can also set per app
brand = "Morphe"                     # patch brand/engine identity (e.g. "ReVanced Advanced", "Piko", "Morphe", "Android TV"). default: patches-source owner.

author = "nullcpy"                   # module author name. default: "nullcpy"
author-page = "github.com/nullcpy/rvb" # module author page/link printed during installation. default: "github.com/nullcpy/rvb"

patches-version = "stable"  # 'stable' or a release tag to pin. default: "stable". 'beta' and 'both' are rejected.
cli-version = "stable"      # 'stable', 'beta', or a version number. default: "stable"
# 'stable' is the only channel keyword for patches; it resolves against
# state/patch_sources.json (see One Config File below). There is one build and no beta channel.

> [!TIP]
> **File-Level Defaults in Modular Configs:**  
> Keys defined at the top of the file before the first `[...]` section (such as `patches-source`, `cli-source`, `patches-version`, `brand`, `variant`, `arch`, and `build-mode`) act as file-level defaults for all apps in that file. Apps automatically inherit them unless overridden.

[Some-App]
app-name = "SomeApp"     # clean display name (e.g. "YouTube", "Instagram"). Default is table name.
brand = "Piko"           # per-app patch brand override (e.g. "Piko", "Adobo", "ReVanced Advanced").
variant = "Nord"         # optional feature/visual variant (e.g. "Nord", "Mocha", "MaterialYou").
sub-variant = "clone"    # optional packaging/install variant (e.g. "clone", "alt").
pkg-name = "com.some.app" # stock package name (used by APKMirror/Uptodown scrapers and version checking).
patched-pkg-name = "com.some.app.clone" # optional override for the resulting installed package name (e.g. for clone patches). If omitted, the builder auto-detects the actual package ID from the compiled APK manifest via aapt2.
patch-folder = "someapp" # explicit patch folder name override. forces the CI to strictly match patches inside this exact folder name, bypassing fallback heuristics (useful for resolving collisions like youtube vs youtube-music). Supports multiple folders space-separated (e.g. "ad backup geo"), or a wildcard "*" to force mapping every single patch folder in the repo.
enabled = true       # whether to build the app. default: true
build-mode = "both"  # 'both', 'apk' or 'module'. default: apk
mirror = false       # true: publish the stock APK unmodified instead of patching it (see "Mirrored apps"). default: false
keep-filename = false # mirror + github source only: publish the release asset under its own name (see "Mirrored apps"). default: false
allow-resign = false  # mirror only: when no source gives a plain APK, accept a split bundle merged and signed with THIS repository's key (see "Mirrored apps"). default: false
badge-color = "FF4500"  # presentation only (README / Obtainium tooling read it; the build ignores it): hex colour, no '#'
badge-icon = "reddit"   # presentation only: a simple-icons slug for the README badge
arch = "both"        # 'both', 'auto', 'all', 'arm64-v8a', 'arm-v7a', 'x86_64', or 'x86'. default: both
# A requested arch is a hard requirement: a build is produced only when a download
# actually carries that ABI (or is universal / has no native code at all). A wrong
# single ABI is rejected and the next source tried; if none supplies the arch, that
# channel is simply not built - never shipped under another arch's name. So an
# arm64-only app publishes only its arm64 artifact and no arm-v7a file, and the
# reverse. Universal bundles serve both channels from one fetch.

# 'auto' option gets the latest possible version supported by all the included patches
# 'exp' gets the newest version the patches list as experimental (the README shows it as 🧪 Experimental). When the
# bundle lists none as experimental any more it takes the newest version the patches list at all.
# 'latest' gets the latest stable without checking patches support. 'beta' gets the latest beta/alpha
# whitespace seperated list of patches to exclude. default: ""
version = "auto"     # 'auto', 'exp', 'latest', 'beta' or a version number (e.g. '17.40.41'). default: auto
# target Android versionCode. 'auto' automatically resolves the supported versionCode from patch metadata (e.g. Morphe Desktop).
# can also be set to an explicit versionCode (e.g. '473623755') or mapped per-architecture ('arm64-v8a: 473623755 | arm-v7a: 473623748').
# used by APKMirror and the cache repo to pick the exact build variant, and enforced on
# every download from any source: the APK's own versionCode is read back and a mismatch -
# or a file it cannot read a code from - rejects it and falls through to the next source.
# Also part of the stock-APK cache key (<pkg>-<version>-<code>-<arch>), so two builds that
# share a version string but differ by code never collide. Apps whose patches declare no
# versionCode get no code in the name and no such check. default: "" (or auto when resolved)
version-code = "auto"

# optional args to be passed to cli. can be used to set patch options
# multiline strings in the config is supported
patcher-args = """\
  -OdarkThemeBackgroundColor=#FF0F0F0F \
  -Oanother-option=value \
  """

excluded-patches = """\
  'Some Patch' \
  'Some Other Patch' \
  """                                                      # whitespace seperated list of patches to exclude. When mixing multiple `patches-source` bundles, you can use `|` to separate the patches for each bundle. To skip a bundle, leave the side empty (e.g. `" | 'Patch for second bundle'"`).

included-patches = "'Some Patch'"                          # whitespace seperated list of non-default patches to include. default: "". When mixing multiple `patches-source` bundles, you can use `|` to separate the patches for each bundle. To skip a bundle, leave the side empty (e.g. `" | 'Patch for second bundle'"`).
include-stock = "merged"                                   # 'merged', 'split' or 'disable'. default: merged
exclusive-patches = false                                  # exclude all patches by default. Accepts `true`, `false`, or a string of patch sources (e.g. `"'jkennethcarino/adobo'"`). When a specific patch source is provided, only that bundle becomes exclusive, while others retain their default patches. default: false
inclusive-patches = false                                  # the mirror of `exclusive-patches`: `true` applies **every** patch the CLI lists for this app, so you curate downwards with `excluded-patches` instead of writing out dozens of `included-patches` names. Boolean only (no patch-source list), cannot be combined with `exclusive-patches`, and needs a tool that can list patches (Morphe/ReVanced - not Xposed modules or Instafel). "Every" is the package-filtered listing the builder already reads (`list-patches -f <pkg> -x`), so patches declaring no package are not included. Names are expanded at build time from the live listing: a patch the author adds later is picked up automatically, and since Morphe aborts when a patch fails, that automatic pickup can break a build with no change on your side. default: false

apkmirror-dlurl = "https://www.apkmirror.com/apk/inc/app"
uptodown-dlurl = "https://spotify.en.uptodown.com/android"
# APKPure is the last-resort store: every store app in configs/ names one, and it is only asked when the sources
# before it (APKMirror, Uptodown) failed for that version. The slug may be anything; the package id is what counts.
apkpure-dlurl = "https://apkpure.com/some-app/com.some.app"
apkcombo-dlurl = "https://apkcombo.com/some-app/com.some.app"
# a GitHub Actions workflow whose artifact is the build (a nightly with no release). the newest successful run that
# still holds an artifact is downloaded and its run number is the version. needs a GitHub token (CI has one).
actions-dlurl = "https://github.com/developer/app/actions/workflows/nightly.yml"
# regex on the artifact name, required when a run uploads more than one artifact; it must match exactly one.
actions-artifact = 'Dev \(#[0-9]+\)$'
# github release url or repo url (e.g. 'https://github.com/developer/app', '.../releases/latest', or '.../releases/tag/v1.0').
github-dlurl = "https://github.com/developer/app"
# regex used to filter releases when querying a repo url without a fixed tag (e.g. multi-channel repos).
# if omitted, the script automatically checks if table, brand, or variant targets a channel (beta, nightly, alpha, canary) or filters for stable releases.
github-release-regex = "^Beta"
# regex used to pick the exact apk file from the github release assets. supports {version} and {arch} string interpolation.
# you can define a generic regex, or map architectures to specific regexes using 'arch: regex | arch2: regex2'.
github-regex = "arm64-v8a: 'MyApp-arm64-v{version}\\.apk' | arm-v7a: 'MyApp-arm-v{version}\\.apk'"
# direct download url. the url must have point to an apk file with name format shown in this example
direct-dlurl = "https://website/com.google.android.youtube-20.40.45-all.apk"

module-prop-name = "some-app-module"                       # module prop name. default: "<app>-<author>"
# write an `updateJson=` line into the built Magisk/KernelSU module's module.prop, so a
# manager polls this repo's update branch for a newer build of that module instead of
# the user re-downloading it by hand. The path is the module id without its author and
# channel suffixes, under the pool folder it was built from: `stable/<id>.json` or
# `beta/<id>.json`. That string is a wire format - installed modules on the wild already
# carry it, so changing the layout orphans them.
# FILE-LEVEL ONLY (an app block cannot change it), and forced off for local builds,
# where there is no published update branch to point at. default: true in CI, false locally
enable-module-update = true
dpi = "360-480dpi"                                         # used to select apk variant from apkmirror. 'auto' matches whatever is available. default: nodpi anydpi auto
```

### Naming & Catalog Hierarchy

The declarative keys define both the asset filename and how the app appears in release notes and the website catalog:
- **`app-name`**: Sets the human-readable display name (e.g. `YouTube`, `Instagram`, `Prime Video`).
- **`brand`**: Declares the canonical patch brand or creator identity (e.g. `ReVanced Advanced`, `Piko`, `Adobo`, `Paresh`, `Android TV`, `Morphe`).
- **`variant`**: (Optional) Declares visual or feature variations (e.g. `Nord`, `Mocha`, `MaterialYou`).
- **`sub-variant`**: (Optional) Declares packaging or installation variations (e.g. `clone`, `alt`).
- **`pkg-name`**: Sets the upstream stock application package name (e.g. `com.amazon.amazonvideo.livingroom`), used by scrapers (APKMirror, Uptodown) and patch bytecode checkers.
- **`patched-pkg-name`**: (Optional) Declares the resulting installed package name when changed by a clone patch (e.g. `com.amazon.amazonvideo.livingroom.clone`). Used by the website catalog and Obtainium for installation tracking. If omitted on cloned apps, the build engine automatically extracts the real package ID from the built APK's manifest using `aapt2`.

#### Direct Slug Resolution

The build engine (`utils.sh`) automatically derives filename slugs directly from your declarative configuration using clean kebab-casing:
- `brand = "ReVanced Advanced"` ➔ `revanced-advanced` (or `brand = "Anddea"` ➔ `anddea`)
- `brand = "Android TV"` ➔ `android-tv`
- `brand = "Piko"` ➔ `piko`
- `brand = "Morphe"` ➔ `morphe`
- `app-name = "YouTube Music"` ➔ `youtube-music`

Every configuration is self-contained in its TOML file with zero external lookup files.

**Output Filename Structure:**
```
${app_slug}-${brand_slug}${variant:+-$variant}${sub_variant:+-$sub_variant}-v${version}-${arch}.apk
```

Examples:
- `app-name = "YouTube"`, `brand = "ReVanced Advanced"`, `variant = "Nord"` ➔ `youtube-revanced-advanced-nord-v20.51.39-arm64-v8a.apk`
- `app-name = "YouTube Music"`, `brand = "Anddea"` ➔ `youtube-music-anddea-v8.11.51-arm64-v8a.apk`
- `app-name = "Instagram"`, `brand = "Piko"`, `sub-variant = "clone"` ➔ `instagram-piko-clone-v439.0.0.37.89-arm64-v8a.apk`
- `app-name = "Prime Video"`, `brand = "Android TV"`, `sub-variant = "clone"` ➔ `prime-video-android-tv-clone-v3.0.354-arm-v7a.apk`
- `app-name = "TikTok"`, `brand = "Morphe"`, `sub-variant = "alt"` ➔ `tiktok-morphe-alt-v37.5.4-arm64-v8a.apk`
- `app-name = "Disney+"`, `brand = "Android TV"`, `sub-variant = "clone"` ➔ `disney-android-tv-clone-v3.0.354-arm-v7a.apk`

## Mirrored apps

`mirror = true` turns an app into a plain re-host of its stock APK: nothing is patched, so
no CLI or patch bundle is fetched and none of the patch keys apply. It exists so an app that
publishes no GitHub release of its own can still be tracked (e.g. by Obtainium) from this
repository.

```toml
mirror = true            # file-level default for a "stock apps" file
brand = "Mirror"         # metadata only; a mirrored file name has no brand segment
version = "latest"       # 'latest', 'waenhancer' (WhatsApp / WhatsApp Business only: the newest build the latest Dev4Mod/WaEnhancer release supports, see below) or an explicit version. 'auto', 'exp' and 'beta' are refused: there are no patches to resolve them against
arch = "arm64-v8a"

[Bitget]
app-name = "Bitget"
pkg-name = "com.bitget.exchange"
apkmirror-dlurl = "https://www.apkmirror.com/apk/bg-limited/bitget-buy-sell-crypto/"

[Duck-Detector]
app-name = "Duck Detector"
pkg-name = "com.eltavine.duckdetector"
keep-filename = true     # a nightly has no version number to put in a name: the asset keeps its own
version = "nightly"
arch = "all"
github-dlurl = "https://github.com/eltavine/Duck-Detector-Refactoring/releases/tag/nightly"
```

- **Rejected, not ignored:** `patches-source`, `cli-source`, `included-patches`, `excluded-patches`,
  `exclusive-patches`, `inclusive-patches`, `patcher-args`, `patched-pkg-name`, `include-stock`
  and a `build-mode` other than `apk` on a mirrored app abort the run, as does `keep-filename`
  on an app that is not mirrored. Keep file-level defaults for patched keys out of a file that
  holds mirrored apps.
- **File name:** `<app-slug>-v<version>-<arch>.apk`, the same grammar as every other asset, so
  releases, manifests and Obtainium filters treat it like any build. The `<version>` is what the
  APK calls itself (its `versionName`), not the source's label, with characters a file name cannot
  carry turned into `-` (`nightly-209 (#2062)` → `nightly-209-2062`): the phone and Obtainium
  compare the file's version with the installed app's, and a CI run number would never equal it.
  An APK that reports no version name keeps the source's; `keep-filename` apps are named by their source.
- **Signature:** a mirror is published exactly as its publisher signed it, never re-signed. A plain
  APK is published byte for byte. A split bundle (`.xapk`/`.apkm`/`.apks`) cannot be turned into one
  APK without signing the result with this repository's key, so a mirror **skips that source** and asks
  the next one for the same version (a bundle that is really one APK, or holds only `base.apk`, is
  extracted unchanged). If every source serves a split bundle nothing is published and the log says
  so. Give a mirrored app a store that serves a plain APK (`apkmirror-dlurl` and `uptodown-dlurl`
  are both worth setting).
- **`allow-resign = true`** (per app, default `false`, rejected on a patched app) is the opt-in for an app
  that has no plain-APK source at all. Only after every source has been asked for a plain APK does a
  second pass accept a split bundle, merge it and sign it with this repository's key. Such a file is
  **not** the publisher's app as far as updates go: it cannot update over the store install (and the store
  cannot update it), so the store copy has to be uninstalled first, and an app that checks its own
  signature or account integrity (a messenger, an exchange) may refuse it or flag the account. Use it only
  for an app where that does not matter. The build records whether each file was re-signed
  (`resigned` in the manifest), the release notes flag it with ⚠️, and the README's **Signature** column
  for the stock mirrors shows ✅ original or ⚠️ re-signed per app.
- **Identity:** the APK's real package id is what gets published. For `github`/`direct` sources a
  `pkg-name` that differs from it is a warning (you named the file); for a store scrape it is a
  rejection.
- **When it rebuilds:** only when the app itself updates in a tracked store. A patch release never
  rebuilds a mirrored app.
- **`version = "waenhancer"`** (`com.whatsapp` and `com.whatsapp.w4b` only; any other package is
  refused): WaEnhancer only hooks the WhatsApp builds listed in its `arrays.xml`
  (`2.26.40.xx` names a whole minor) and a newer WhatsApp breaks it, so the mirror takes the highest
  stable build the **latest** WaEnhancer release supports. The first source (the usual order:
  `apkmirror`, then `uptodown`) that lists such a build supplies the version; the download then
  tries the sources in order for exactly that build, so a failed APKMirror download falls back to
  Uptodown for the same version, never to an older one. A WaEnhancer release that widens its list
  moves the version the watcher records and so triggers a build; if the list cannot be read the
  app is not mirrored (nothing is guessed).

  ```toml
  [WhatsApp]
  app-name = "WhatsApp"
  version = "waenhancer"
  pkg-name = "com.whatsapp"
  apkmirror-dlurl = "https://www.apkmirror.com/apk/whatsapp-inc/whatsapp-messenger/"
  uptodown-dlurl = "https://whatsapp-messenger.en.uptodown.com/android"
  ```

## Multiple Patch Sources

You can pass multiple patch bundles to the CLI by specifying `patches-source` as a quoted list (same format as `excluded-patches`).
When using multiple sources, the CLI merges the patch bundles. However, please see the **Current Limitations** below regarding `included-patches` and `excluded-patches`.

```toml
# single-line format
patches-source = "'MorpheApp/morphe-patches' 'other/patches'"

# multiline format
patches-source = """\
  'MorpheApp/morphe-patches' \
  'other/patches' \
  """

# If all sources are on the same host, a single string applies to all:
patches-source-host = "github"

# If sources span different hosts, provide one value per source in order:
patches-source-host = "'github' 'gitlab'"        # any of github | gitlab | codeberg

# Same rule applies to patches-version:
patches-version = "stable"                        # applies to all sources
patches-version = "'stable' 'v1.2.3'"             # per-source versions
```

> [!NOTE]
> **Codeberg sources** (`"codeberg"`) are read through Forgejo's GitHub-compatible API:
> stable vs beta is the same `prerelease` flag GitHub uses, drafts are ignored, and the
> listing is requested with `limit=50` because that API silently ignores `per_page`. The
> bundle is downloaded from the release asset's `browser_download_url`, whatever the file
> is called (`app-release.apk` is common for Xposed modules), and the changelog link is
> built as `https://codeberg.org/<owner>/<repo>/releases/tag/<tag>`.

> [!TIP]
> **Per-bundle patch selection**: When using multiple sources, separate patch lists 
> with `|` to control each bundle independently:
> ```toml
> patches-source = "'MorpheApp/morphe-patches' 'other/patches'"
> excluded-patches = "'Patch A' | 'Patch B'"    # Patch A from bundle 1, Patch B from bundle 2
> included-patches = "'' | 'Patch X'"           # nothing from bundle 1, Patch X from bundle 2
> ```
> Without `|`, the same list applies to all bundles (backward compatible).

## Xposed Modules (NPatch / LSPatch)

You can natively inject Xposed modules into an app using `7723mod/NPatch` or `LSPatch` directly from your config. Simply set the `cli-source` to the NPatch repository and the `patches-source` to the Xposed module repository.

```toml
[Discord]
cli-source = "7723mod/NPatch"                            # Use NPatch as the CLI
cli-version = "stable"
patches-source = "revenge-mod/revenge-xposed"            # Provide the Xposed module as the patches bundle
patches-version = "stable"
version = "auto"                                         # 'auto' safely falls back to 'latest' since modules don't list supported versions
arch = "auto"
github-dlurl = "https://github.com/discord/releases/..." # Or apkmirror, etc.
```

When the script detects `npatch` or `lspatch` in the CLI source, it will automatically bypass ReVanced CLI arguments and execute the correct injection command. You can also pass extra options to NPatch using `patcher-args = "-l 2"`.

## Instafel Patcher (Instagram Alpha)

You can natively build Instagram Alpha using the Instafel Patcher engine (`instafel/p-rel`) and Patcher Core (`instafel/pc-rel`).

```toml
[instagram-instafel]
cli-source = "instafel/p-rel"                            # Use Instafel Patcher CLI
cli-version = "stable"
patches-source = "instafel/pc-rel"                       # Provide Instafel Patcher Core
patches-version = "stable"
included-patches = "'unlock_developer_options' 'remove_snooze_warning' 'remove_ads' 'instafel'"
```

## Morphe Bundle Passthrough

When the tool is **morphe-desktop** (`cli-source = "MorpheApp/morphe-desktop"`,
the default) and the stock download is a bundle format (`.xapk`/`.apkm`/`.apks`),
the engine keeps the vendor bundle as the cache artifact and hands it to morphe
directly instead of pre-merging it with apkeditor. Morphe merges bundles
natively, and some apps misbehave after apkeditor's rewrite+re-sign, so this
produces cleaner patched APKs and avoids caching two copies of the same app.

No merge is performed at all in this mode, for any download source: the engine
extracts the bundle's `base.apk` purely so the usual package / versionName /
versionCode checks have a real APK to read, and leaves the bundle untouched for
patching. (Until now the merge still ran and its output was deleted minutes later
when the bundle was adopted — an apkeditor JVM start and a full archive pass per
bundle download, for nothing.)

- **Scope**: automatic — no per-app config. Applies per build when the download
  is a bundle; plain `.apk` stocks and all other patcher tools (revanced family,
  Xposed, instafel) are untouched.
- **Cache**: a bundle is stored under the ABIs it actually carries, read off its
  contents: `${pkg}-${version}-${versionCode}-all.xapk` when it holds every arm ABI or
  none, and `${pkg}-${version}-${versionCode}-arm64-v8a.xapk` when it holds only that
  one (`.apkm`/`.apks` likewise). A universal bundle is shared: for `arch = all`/`auto`
  it goes to morphe whole, and for `arm64-v8a`/`arm-v7a`/`x86`/`x86_64` the engine
  strips only the *other ABIs'* `config.*` members (a `zip -d`, no merge, no re-sign)
  and passes the trimmed bundle, so switching an app from `all` to `both`/`arm64-v8a`
  reuses the cached bundle rather than re-downloading.
  That sharing rested on a premise that is not always true: APKPure and APKCombo publish
  *per-arch* bundles (atvTools 1.3.2 arm64 = base + `config.arm64_v8a` +
  `config.xxxhdpi`, nothing else). Stored as `-all`, such a bundle was adopted by the
  `arm-v7a` build, which trimmed away the only ABI split it had and then failed in the
  patcher for want of `lib/armeabi-v7a`. Keys now come from the artifact, so a build can
  only find a bundle that is able to serve it.
- **Module stock**: `include-stock = merged` merges from the cached bundle on
  demand (throwaway, never cached); `split` reads the bundle directly; `disable`
  needs nothing. All three work with passthrough active.
- **Cache repo (`nullcpy/apks`)**: the bundle is uploaded as-is (it is the file
  the build used); the downloader side already accepts bundle extensions.
- **Kill switch**: set the repo variable `RVB_MORPHE_PASSTHROUGH=false`
  (Settings → Secrets and variables → Actions → Variables) to revert to the old
  merge-at-download behavior without a code change. Existing merged-`.apk`
  cache entries keep working for any non-morphe tool.

## One Config File

Every app lives in one file, `configs/config.toml`, whatever its patch source. There is one build and no beta channel.

- **Single File**: All apps and patch sources sit in `configs/config.toml`; an app that needs another patch source sets its own `patches-source`.
- **Top-Level Inheritance**: Keys defined at the top of the file before the first `[...]` header (such as `patches-source`, `brand`, `variant`) act as file-level defaults. Apps automatically inherit them, keeping app blocks concise and DRY.
- **Default CLI Engine**: `cli-source` defaults to `"MorpheApp/morphe-desktop"` globally and can be completely omitted unless using alternative tools like `7723mod/NPatch` or `instafel/p-rel`.
- **Patch bundle selection** (`patches-version`):
  - **Stable (default)**: omit the key and the app is built with its source's latest non-pre-release.
  - **No beta**: `patches-version = "beta"` and `"both"` (file-level or per app) are rejected loudly by the compiler and by `build.sh`. An app that needs a pre-release bundle pins its tag.
  - **No Filename Inference**: the channel is a setting, never read from a file name.
  - **Concrete Version Pins**: A version number instead of a channel (e.g. `patches-version = "v4.8.3"`) pins that exact release — one app when written in an app block, every app in the file when written at the top level. The generated config carries it verbatim and nothing rewrites it.
  - **Channel Resolution**: `"stable"` is the only channel keyword, and it stays a keyword in the generated config; the build resolves each source's keyword against `state/patch_sources.json`, the watcher's record of that source's current release per channel. One source of truth instead of a stamped copy that can go stale, and a build run is consistent with the state it was generated from because `configs/` and `state/` come from the same `main` commit. A source with no release recorded on that channel falls back to listing the releases live. Any other word is treated as a release tag, so a mistyped channel fails on the release lookup rather than building the wrong thing.
  - **Blocked Sources**: when the forge answers `404` (deleted or renamed), `451` (legal takedown) or `403` (private or access refused), the watcher marks that source `blocked` and freezes its last known tags. A build then **skips every app using it** - keyword or pinned version alike - instead of querying the releases endpoint, because neither a retry nor a live listing can recover a repository that is gone. The app is logged as "Could not get prebuilts" and the run moves on; it comes back on its own once the source is reachable again.
  - **Disabling an App**: Set `enabled = false` to disable an app.

## Automated Patch Sources State Tracking

> **Where configs and state live:** all on `main`, tracked like code.
>
> - `configs/config.manual.toml`, `configs/config.toml` — **yours**: edit and
>   commit them normally.
> - `configs/build.json` — the generated build config (the apps that are due),
>   written by the watcher only (`commit_to_main.sh`).
> - `state/*.json` (`patch_sources`, `app_versions`, `patch_file_hashes`) —
>   machine state, written by the watcher only.
> - `state/manifests/`, `state/archive/` — build manifests, written by each build.
>
> CI commits those generated files to `main` between your edits, so `git pull`
> before you edit. Never hand-edit the JSON; to force a state change, delete the
> entry and let the watcher rebuild it. Why one branch:
> [docs/decisions/0008](docs/decisions/0008-one-branch.md).

Patch sources and their release versions in `state/patch_sources.json` are **100% automated**:
- The CI automatically scans all `.toml` files, discovers every active `patches-source` repository and host (`github`, `gitlab` or `codeberg`), and checks for new stable releases.
- Unreferenced or deleted patch sources are pruned automatically.
- **You do not need to manually edit `patch_sources.json`.** Simply add or update `patches-source` in your `.toml` files.
- The build reads this file to turn a `patches-version = "stable"|"beta"` keyword into a concrete tag, so it is the answer to "what is the current release" for both the watcher and the builder.
- A `blocked: true` entry is the watcher's record that the repository cannot be reached (404/451/403, on any of the three forges). Its tags are kept as they were, and the build refuses to use them - it skips the app rather than spend a request on a dead repository.

## Automatic App Version Checking

The CI workflow automatically detects when a new version of an app is released on APKMirror, Uptodown, or Archive.org.

### How it Works
1. **Version Fetching**: During the CI run, it reads all enabled apps from `configs/config.toml` and queries the URLs (`uptodown-dlurl`, `apkmirror-dlurl`, etc.).
2. **Comparison**: It checks the newly fetched versions against the currently stored versions in `state/app_versions.json`.
3. **Triggering**: If a new version is detected, the app is added to a temporary `active_apps.json` list, and the CI is triggered to build it.
### Tracking File
App versions are permanently tracked in `state/app_versions.json` (on `main`, see above).
You can manually update this file if you need to force a specific version state, but the CI will automatically manage it during scheduled runs.

**Selective Checking:** If you only want the CI to check specific apps (instead of all enabled apps in your config), you can add `"_check_only_listed": true` to the top level of `app_versions.json`. When this is true, the script will only check for updates for the apps that already exist as keys in the file, saving time and resources.

## Release Cleanup & Catalog Architecture

Maintenance and cleanup workflows keep GitHub Releases and changelogs pruned. The
website catalog (`data.json` on `nullcpy.github.io`) is **derived, not edited**: every
build's metadata lives in a `build.json` manifest under `state/` on the repo's `main` and
the website repo regenerates its catalog from scratch by folding those manifests
against the live releases API.

### Release Manifests (`build.json`)
- **What**: a per-release, filename-keyed JSON manifest describing every APK/module
  in that release — app identity, brand, variant, version, arch, patch sources and
  `appliedPatches`. Schema documented in `.github/scripts/build_make_manifest.py`.
- **Numbered releases**: the builder generates one manifest per build
  (`build_make_manifest.py` → `temp/manifest/build.json`); it is committed to the
  repository as `state/manifests/<tag>.json`, not uploaded as a release asset.
- **Archive release (`stable`)**: after each archive file upload,
  `merge_archive_manifest.sh` reads the cumulative `state/archive/<channel>.json`
  from `main`, unions the new build's entries with it (same filename = file
  replaced = metadata replaced), drops entries whose file no longer exists in
  the release, and commits it with `state/manifests/<tag>.json` alongside. The archive therefore carries cumulative metadata for every file it
  contains, even after the originating numbered release is deleted — and the
  git history makes any manifest loss recoverable via `git log -p` /
  `git show <rev>:state/archive/stable.json`.
- **Backfill**: `.github/scripts/backfill_manifests.py` (run with `--apply`) can
  regenerate manifests on all live releases from a healthy `data.json` (one-time
  migration tool; dry run by default).

### Website Rebuild (nullcpy.github.io repo)
`.github/workflows/rebuild-catalog.yml` runs on `repository_dispatch
(catalog-updated)` — sent fire-and-forget by `build.yml` and `cleanup.yml` — plus a
scheduled safety net. It sparse-clones `state/` of this repo's `main` for the
manifests (plus fetches live releases for existence, sizes, and download
counts), regenerates `data.json` (schema v2) from scratch, and pushes only on
material change. Deletions are automatic: a release or asset that no longer
exists simply doesn't appear. Circuit breakers abort a rebuild (leaving
`data.json` untouched) if the releases API looks empty (< 10 releases) or the
catalog shrinks beyond `MIN_RATIO` (default 0.6); `FORCE=1` overrides.
Releases without a manifest get minimal filename-derived fallback entries.

### Automated Routine Cleanup (`cleanup.yml`)
- **Numbered Releases**: Retains the latest 98 numbered releases via `ophub/delete-releases-workflows`. Keeping 98 *is* the catalog's history window — deleted releases vanish from the website, which is correct since their files are gone.
- **Archive Releases**: Retains the rolling `stable` release (and a retired `beta` one, if it still exists), keeping up to 2 versions per asset group via `cleanup-archive-assets.py`. Pruned assets drop out of the catalog automatically at the next rebuild.
- **Manifests**: `cleanup_manifests.sh` deletes `state/manifests/<tag>.json` for numbered releases that no longer exist (same pattern as the update branch's changelog pruning).
- Ends with a fire-and-forget `catalog-updated` dispatch so the website reflects deletions promptly.

### Full Clean Slate / Rebuilding from Scratch
To completely wipe all historical releases (including `stable` and `beta`):
1. In `.github/workflows/cleanup.yml`, set:
   ```yaml
   releases_keep_latest: 0
   workflows_keep_day: 0
   # (omit releases_keep_keyword: stable/beta)
   ```
2. Trigger the **Cleanup** workflow via `workflow_dispatch`. All past releases, tags,
   and workflow logs are purged.
3. In the **website repo**, run Rebuild Catalog with `FORCE=1` (edit the workflow env or
   temporarily raise `MIN_RELEASES_THRESHOLD=0`) to publish an empty catalog; the
   breaker would otherwise refuse to write with < 10 live releases.
4. Subsequent CI builds author clean numbered releases, rolling archives, and fresh
   manifests; every website rebuild thereafter is derived from whatever is live.
5. **Restoring Routine Configuration**: restore `cleanup.yml` to standard retention:
   ```yaml
   releases_keep_latest: 98
   releases_keep_keyword: stable/beta
   workflows_keep_day: 0
   ```
