#!/usr/bin/env python3
"""Obtainium entries for this repository's releases — one definition, three consumers.

Obtainium tracks a GitHub repository, not an app: every app here lives in the same
repository, so each one needs its own APK filter regex and a few settings that make the
build-number release tags (`260142`) work. This module is the single place those settings
and the filter live. It is imported by

  * generate_release_notes.py  per-app links inside each release body (exact file names)
  * obtainium.py (CLI below)   OBTAINIUM.md, the README app table and the importable
                               obtainium-apps.json (names derived from the TOML config)

Why the settings are what they are:

  versionDetection = false    Release tags are build numbers, not app versions. With
                              Obtainium's default "compare against the installed
                              versionName" the two never match, so the app would show an
                              update forever. Obtainium records the tag it installed and
                              compares tags instead.
  fallbackToOlderReleases     A build only contains the apps that changed, so the newest
                              release usually has no APK for a given app; Obtainium walks
                              back to the newest release that does.
  includePrereleases          Only for apps built in the beta pool, whose releases GitHub
                              marks as pre-releases.
  apkFilterRegEx              `^<file-prefix>-v.+-<arch>\\.apk$`, the asset grammar
                              documented in docs/storage-and-branches.md.

Stdlib only. The CLI imports compile_patch_configs for the pool routing rules rather than
re-implementing them.
"""
import argparse
import json
import os
import re
import sys
from urllib.parse import quote

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

REDIRECT_BASE = "https://apps.obtainium.imranr.dev/redirect?r="


def slug(value):
    """The engine's resolve_slug (scripts/utils.sh): lowercase, runs of non-alphanumerics
    become one '-', no leading/trailing '-'. test_release_notes.sh runs both over the seed
    config and fails on any difference, so the two cannot drift silently."""
    return re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9]+", "-", (value or "").lower()))


def regex_escape(text):
    """Escape for Dart's RegExp (Obtainium). Only characters that are special are escaped."""
    return re.sub(r"([.^$*+?()\[\]{}|\\])", r"\\\1", text)


def apk_regex(prefix, arch):
    """Filter for `<prefix>-v<version>-<arch>.apk`; `all` also accepts the universal alias."""
    arch_re = "(all|universal)" if arch in ("all", "universal") else regex_escape(arch)
    return f"^{regex_escape(prefix)}-v.+-{arch_re}\\.apk$"


def exact_regex(file_name):
    """Filter for one file that keeps its source's own name (mirror + keep-filename)."""
    return f"^{regex_escape(file_name)}$"


def kept_file_regex(file_name):
    """Filter for a file that keeps its source's own name (mirror + keep-filename).

    Such names usually embed what changes from build to build - a date, a hash, a version
    (`Duck.Detector-2026.10.06-82566ffa96bb.apk`) - so matching the published name exactly would
    never match the next build. The stable lead is kept (everything before the first `-` that is
    followed by a digit) and the rest may vary. A name with no such split stays exact."""
    m = re.match(r"^(.+?)-(?=\d)", file_name)
    if m and file_name.lower().endswith(".apk"):
        return f"^{regex_escape(m.group(1))}-.+\\.apk$"
    return exact_regex(file_name)


def additional_settings(apk_filter, prerelease):
    # Every key Obtainium's GitHub source reads is written, so an import is deterministic
    # instead of inheriting whatever default the installed Obtainium version has.
    return {
        "includePrereleases": bool(prerelease),
        "fallbackToOlderReleases": True,
        "filterReleaseTitlesByRegEx": "",
        "filterReleaseNotesByRegEx": "",
        "verifyLatestTag": False,
        "dontSortReleasesList": False,
        "useLatestAssetDateAsReleaseDate": False,
        "trackOnly": False,
        "versionExtractionRegEx": "",
        "matchGroupToUse": "",
        "versionDetection": False,
        "useVersionCodeAsOSVersion": False,
        "apkFilterRegEx": apk_filter,
        "invertAPKFilter": False,
        "autoApkFilterByArch": False,
        "appName": "",
        "appAuthor": "",
        "shizukuPretendToBeGooglePlay": False,
        "allowInsecure": False,
        "exemptFromBackgroundUpdates": False,
        "skipUpdateNotifications": False,
        "about": "",
        "refreshBeforeDownload": False,
    }


def app_entry(package, name, repo, apk_filter, prerelease=False):
    """One app as Obtainium's own export/deep link spells it.

    The whole object is written, not just the fields that matter here: Obtainium reads an app
    back with every one of these keys (latestVersion, apkUrls, pinned, ... are not optional on
    import), and the shape below is the one a working deep link of a sibling project carries.
    `additionalSettings` is a JSON *string* inside the JSON, which is how Obtainium stores it."""
    owner = repo.split("/")[0]
    return {
        "id": package,
        "url": f"https://github.com/{repo}",
        "author": owner,
        "name": name,
        "installedVersion": "",
        "latestVersion": "",
        "apkUrls": "[]",
        "otherAssetUrls": "[]",
        "preferredApkIndex": 0,
        "additionalSettings": json.dumps(additional_settings(apk_filter, prerelease), separators=(",", ":")),
        "lastUpdateCheck": None,
        "pinned": False,
        "categories": [],
        "releaseDate": None,
        "changeLog": None,
        "overrideSource": None,
        "allowIdChange": False,
        "pendingRepoRenameUrl": None,
    }


def deep_link(entry):
    """obtainium://app/<the JSON, as is>. GitHub strips non-http(s) links from Markdown, so a
    README or release body must use redirect_link instead."""
    return "obtainium://app/" + json.dumps(entry, separators=(",", ":"))


def redirect_link(entry):
    """An https link that bounces into Obtainium (a page hosted by Obtainium's author). The
    deep link is percent-encoded once, whole. Parentheses are encoded too (a filter like
    `(all|universal)` would otherwise sit raw inside a Markdown link's own parentheses)."""
    return REDIRECT_BASE + quote(deep_link(entry), safe="*")


# ---------------------------------------------------------------------------------------
# Config -> apps (static view: README, OBTAINIUM.md, obtainium-apps.json)
# ---------------------------------------------------------------------------------------

def _truthy(value):
    return value.lower() == "true" if isinstance(value, str) else bool(value)


# The engine's download-source order (DL_SRCS in scripts/utils.sh) and how each is named.
DL_ORDER = ("cache_repo", "direct", "github", "archive", "apkmirror", "uptodown", "apkpure", "apkcombo")
DL_LABEL = {"cache_repo": "Cache", "direct": "Direct", "github": "GitHub", "archive": "Archive",
            "apkmirror": "APKMirror", "uptodown": "Uptodown", "apkpure": "APKPure", "apkcombo": "APKCombo"}


def _first_source(entry):
    src = str(entry.get("patches-source") or "MorpheApp/morphe-patches")
    first = (re.findall(r"'([^']*)'|\"([^\"]*)\"|(\S+)", src.strip()) or [("", "", "")])[0]
    return first[0] or first[1] or first[2]


def _first_source_owner(entry):
    src = str(entry.get("patches-source") or "MorpheApp/morphe-patches")
    first = (re.findall(r"'([^']*)'|\"([^\"]*)\"|(\S+)", src.strip()) or [("", "", "")])[0]
    return (first[0] or first[1] or first[2]).split("/")[0]


def spec_from_entry(key, entry, prerelease):
    """What the engine would build for one pool entry, as plain data."""
    mirror = _truthy(entry.get("mirror", False))
    name = entry.get("app-name") or key
    prefix = slug(name)
    if not mirror:
        brand = entry.get("brand") or _first_source_owner(entry)
        parts = [prefix, slug(brand)]
        variant = slug(entry.get("variant"))
        if variant and variant != "default":
            parts.append(variant)
        if slug(entry.get("sub-variant")):
            parts.append(slug(entry.get("sub-variant")))
        prefix = "-".join(p for p in parts if p)
    arch = str(entry.get("arch") or "both").replace(" ", "")
    if arch in ("both", "auto"):
        arch = "arm64-v8a"  # one Obtainium app per package id; the modern ABI
    package = entry.get("patched-pkg-name") or entry.get("pkg-name") or ""
    keep = _truthy(entry.get("keep-filename", False))
    return {
        "key": key,
        "name": name.strip(),
        "display": name.strip() if "app-name" in entry else key.replace("-", " ").strip(),
        "package": package,
        "mirror": mirror,
        "prerelease": prerelease,
        "keep_filename": keep,
        "arch": arch,
        "prefix": prefix,
        "color": str(entry.get("badge-color") or "").lstrip("#"),
        "icon": str(entry.get("badge-icon") or ""),
        "version_mode": str(entry.get("version") or "auto"),
        "source": "" if mirror else _first_source(entry),
        "host": str(entry.get("patches-source-host") or "github").replace("'", "").replace('"', "").split()[0].lower(),
        "urls": {k: str(entry[f"{k}-dlurl"]).rstrip("/") for k in DL_ORDER if entry.get(f"{k}-dlurl")},
        "patcher_args": str(entry.get("patcher-args") or ""),
    }


def specs_from_configs(patches_dir):
    """Enabled apps from configs/patches/*.toml, routed exactly like the watcher does."""
    import compile_patch_configs  # imported here so --help works without tomllib
    stable, beta = compile_patch_configs.compile_configs(patches_dir)
    specs = [spec_from_entry(k, v, False) for k, v in stable.items()]
    specs += [spec_from_entry(k, v, True) for k, v in beta.items() if k not in stable]
    return specs


def entry_for_spec(spec, repo):
    if spec["keep_filename"]:
        # The asset's own name is only known at build time. Package id first is how the
        # `github` source selects release files (see dl_github), so it is the best static guess.
        apk_filter = f"^{regex_escape(spec['package'])}[-._].*\\.apk$"
    else:
        apk_filter = apk_regex(spec["prefix"], spec["arch"])
    return app_entry(spec["package"], spec["display"], repo, apk_filter, spec["prerelease"])


def import_document(specs, repo):
    return {"apps": [entry_for_spec(s, repo) for s in specs if s["package"]]}


def _shield_text(text):
    """Escape a label for shields.io's static-badge path (-, _ and space are syntax)."""
    return quote(text.replace("-", "--").replace("_", "__").replace(" ", "_"), safe="_-")


DEFAULT_BADGE_COLOR = "4500FF"
DEFAULT_BADGE_ICON = "android"
OBTAINIUM_BADGE = ("![Add to Obtainium](https://img.shields.io/badge/Add_to_Obtainium-8b5cf6"
                   "?style=flat-square&logo=android&logoColor=white)")
_PLAY_ID = re.compile(r"^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$")


def obtainium_badge_link(spec, repo):
    """The purple "Add to Obtainium" badge, linking to this app's redirect link."""
    return f"[{OBTAINIUM_BADGE}]({redirect_link(entry_for_spec(spec, repo))})"


def app_badge(spec):
    """The app's flat badge, in its own colour and logo, linking to its Play Store page - or,
    for a package id that cannot be a Play listing (`Duck.Detector`), to where it is downloaded."""
    name = spec["display"]
    color = spec["color"] if re.fullmatch(r"[0-9A-Fa-f]{6}", spec["color"] or "") else DEFAULT_BADGE_COLOR
    icon = quote(spec["icon"] or DEFAULT_BADGE_ICON, safe="")
    url = (f"https://img.shields.io/badge/{quote(name.replace('-', '--'), safe='')}-{color}"
           f"?style=flat-square&logo={icon}&logoColor=%23FFFFFF")
    badge = f"![{name}]({url})"
    if spec["package"] and _PLAY_ID.match(spec["package"]):
        return f"[{badge}](https://play.google.com/store/apps/details?id={spec['package']})"
    first = next(iter(spec["urls"].values()), "")
    return f"[{badge}]({first})" if first else badge


def apk_sources(spec):
    """Where the stock APK comes from: every configured source, in the engine's own order."""
    if not spec["urls"]:
        return "N/A"
    return "<br>".join(f"[{DL_LABEL.get(k, k.title())}]({u})" for k, u in spec["urls"].items())


def version_label(spec, data):
    """The version shield: the version last published when a manifest says so, else what the
    config asks for (Auto / Latest / a pinned version)."""
    color = spec["color"] if re.fullmatch(r"[0-9A-Fa-f]{6}", spec["color"] or "") else "3e9cfb"
    known = (data.get(spec["prefix"]) or {}).get("version")
    mode = spec["version_mode"]
    if known:
        label = known if known.startswith("v") or not known[:1].isdigit() else f"v{known}"
    elif mode == "auto":
        label = "Auto"
    elif mode == "latest":
        label = "Latest (pre-release)" if spec["prerelease"] else "Latest"
    else:
        label = mode if not mode[:1].isdigit() else f"v{mode}"
    # _shield_text, not a bare quote(): a dash in the message ("v12.19.1-release.0") would
    # otherwise split it into message and colour in shields.io's path syntax.
    return f"![version](https://img.shields.io/badge/version-{_shield_text(label)}-{color}?logo=android&logoColor=white)"


def patches_cell(spec, data):
    """The Patches column: a dropdown of what the last build actually applied (from its manifest),
    plus any -O option the config sets; `Pending` until a build has published."""
    if spec["mirror"]:
        return "*(None - Stock Mirror)*"
    options = re.findall(r"-O(\w+)=(?:'([^']*)'|\"([^\"]*)\"|(\S+))", spec["patcher_args"])
    options_str = ""
    if options:
        options_str = "<br>⚙️ " + ", ".join(f"{k}={a or b or c}" for k, a, b, c in options)
    applied = (data.get(spec["prefix"]) or {}).get("applied")
    if not applied:
        return f"*(Pending first build)*{options_str}"
    names = sorted(set(applied), key=str.lower)
    noun = "patch" if len(names) == 1 else "patches"
    listing = "<br>".join(f"`{n}`" for n in names)
    return f"<details><summary><b>{len(names)} {noun}</b></summary><br>{listing}{options_str}</details>"


def _source_badge_name(source):
    parts = source.split("/")
    if len(parts) > 1:
        return f"{parts[0].replace('-', ' ').title()} / {parts[1].replace('-', ' ').title()}"
    return parts[0].replace("-", " ").title()


def _source_url(source, host):
    return f"https://{'gitlab.com' if host == 'gitlab' else 'github.com'}/{source}"


def _group_header(badge, logo, alt=None):
    return (f'### <img src="https://img.shields.io/badge/{quote(badge, safe="")}-4500FF?style=for-the-badge'
            f'&logo={logo}&logoColor=white" alt="{alt or badge}">')


TABLE_HEAD = ["<div align=\"center\">", "", "| App | Arch | Version | APK Source | Patches | Obtainium |",
              "|:---|:----:|:-------:|:----------:|:--------|:---------:|"]


def _row(spec, repo, data):
    return (f"| {app_badge(spec)} | `{spec['arch']}` | {version_label(spec, data)} | {apk_sources(spec)} "
            f"| {patches_cell(spec, data)} | {obtainium_badge_link(spec, repo)} |")


def render_apps_section(specs, repo, data=None):
    """The apps section of the README: one group per patch source (in config order), then the
    stock mirrors, each a centred table - App, Arch, Version, APK Source, Patches, Obtainium."""
    data = data or {}
    groups, mirrors = {}, []
    for spec in specs:
        if spec["mirror"]:
            mirrors.append(spec)
        else:
            groups.setdefault((spec["source"], spec["host"]), []).append(spec)

    blocks = []
    # MorpheApp's own bundle first, the others A-Z (the config files are read in file-name order,
    # which would otherwise decide what the reader sees first).
    for (source, host), apps in sorted(groups.items(), key=lambda kv: (not kv[0][0].lower().startswith("morpheapp/"), kv[0][0].lower())):
        where = " (GitLab)" if host == "gitlab" else ""
        lines = [_group_header(_source_badge_name(source), "gitlab" if host == "gitlab" else "github"), "",
                 f"> **Source:** [`{source}`]({_source_url(source, host)}){where}", "", *TABLE_HEAD]
        lines += [_row(a, repo, data) for a in apps]
        lines += ["", "</div>"]
        blocks.append("\n".join(lines))
    if mirrors:
        lines = [_group_header("Stock Mirrors / Unpatched APKs", "android"), "",
                 "> **Source:** Direct stock APK mirrors (Unpatched)", "", *TABLE_HEAD]
        lines += [_row(m, repo, data) for m in mirrors]
        lines += ["", "</div>"]
        blocks.append("\n".join(lines))
    return "\n\n---\n\n".join(blocks)


def load_manifest_data(paths):
    """Per app (keyed by file prefix): the version and applied patches of its newest published
    file, from the `website` branch's archive manifests (archive/stable.json, archive/beta.json)."""
    best = {}
    for path in paths:
        try:
            with open(path, encoding="utf-8") as f:
                files = (json.load(f) or {}).get("files") or {}
        except (OSError, ValueError):
            continue
        for entry in files.values():
            if entry.get("fileType") != "APK":
                continue
            key, stamp = entry.get("name") or "", entry.get("publishedAt") or ""
            if key and (key not in best or stamp > best[key][0]):
                best[key] = (stamp, {"version": entry.get("version") or "",
                                     "applied": entry.get("appliedPatches") or []})
    return {k: v for k, (_, v) in best.items()}


def table_markdown(specs, repo):
    """Compact table for OBTAINIUM.md: one row per app, no build data (that page is static)."""
    rows = ["| App | Package | Source | Channel | Obtainium |", "|:--|:--|:--|:--:|:--:|"]
    for s in sorted(specs, key=lambda s: s["display"].lower()):
        source = "📦 stock APK, unmodified" if s["mirror"] else f"🧩 `{s['source']}`"
        channel = "🧪 pre-release" if s["prerelease"] else "✅ stable"
        link = obtainium_badge_link(s, repo) if s["package"] else "—"
        rows.append(f"| {app_badge(s)} | `{s['package']}` | {source} | {channel} | {link} |")
    return "\n".join(rows)


def obtainium_page(specs, repo):
    """The OBTAINIUM.md document."""
    patched = sum(1 for s in specs if not s["mirror"])
    mirrored = len(specs) - patched
    lines = [
        "<!-- Generated by .github/scripts/obtainium.py — edit that script or the config, not this file. -->",
        "",
        '<div align="center">',
        "",
        "# 🔔 Obtainium",
        "",
        "**One tap per app. Updates arrive on their own.**",
        "",
        f"![apps](https://img.shields.io/badge/apps-{len(specs)}-21a378?style=for-the-badge) "
        f"![patched](https://img.shields.io/badge/patched-{patched}-2f81f7?style=for-the-badge) "
        f"![mirrored](https://img.shields.io/badge/mirrored-{mirrored}-8957e5?style=for-the-badge)",
        "",
        "</div>",
        "",
        "## How it works",
        "",
        "1. Install [Obtainium](https://github.com/ImranR98/Obtainium/releases/latest).",
        "2. Tap the **Add to Obtainium** badge next to an app below (open this page on the phone), then **Add** in Obtainium.",
        "3. Obtainium installs the newest build of *that app only* and keeps it updated.",
        "",
        "Or add everything at once: Obtainium → **Import/Export** → **Import from file**, "
        f"and pick [`obtainium-apps.json`](https://raw.githubusercontent.com/{repo}/main/obtainium-apps.json).",
        "",
        "## Apps",
        "",
        table_markdown(specs, repo),
        "",
        "## What the one-tap links set",
        "",
        "Every app lives in the same repository, so each link carries the settings Obtainium needs to "
        "tell them apart. You can check or change them under the app's ⚙ settings in Obtainium.",
        "",
        "| Setting | Value | Why |",
        "|:--|:--|:--|",
        "| Source | GitHub · `https://github.com/" + repo + "` | the numbered releases (`260142`, …) hold the files |",
        "| APK filter (regex) | `^<app>-v.+-<arch>\\.apk$` | picks one app out of a release that holds many |",
        "| Standard version detection | **off** | release tags are build numbers, not app versions; with it on, Obtainium would offer the same update forever |",
        "| Fall back to older releases | on | a build only contains the apps that changed |",
        "| Include pre-releases | only for 🧪 apps | beta-channel builds are published as GitHub pre-releases |",
        "",
        "## Good to know",
        "",
        "- **Patched apps need MicroG.** Google apps need [MicroG-RE](https://github.com/MorpheApp/MicroG-RE/releases/latest) "
        "to sign in; install it once.",
        "- **Package ids.** The link uses the id from the config. If a patch renames the package, the app "
        "shows as *not installed* in Obtainium until you open the entry once and let it re-detect — the release "
        "notes of every build list the exact id that shipped.",
        "- **📦 Mirrored apps** are the vendor's APK, unmodified, republished here so Obtainium has something to "
        "follow. They only appear in a release when the vendor ships a new version.",
        "- **Stock apps from a store are re-hosted, not re-signed**, unless the store only offers a split bundle; "
        "see [CONFIG.md](CONFIG.md#mirrored-apps).",
        "- An app that keeps its source's own file name (`keep-filename`) uses a best-guess filter "
        "(`^<package>[-._].*\\.apk$`) here, because the name is only known once it is built; every release's "
        "own 🔔 link carries the exact name, and you can adjust the filter in Obtainium.",
        "",
        "<sub>Regenerate with <code>python3 .github/scripts/obtainium.py --configs configs/patches --repo "
        + repo + " --page OBTAINIUM.md --json obtainium-apps.json</code></sub>",
        "",
    ]
    return "\n".join(lines)


README_START = "<!-- APPS_START -->"
README_END = "<!-- APPS_END -->"


def update_readme(readme_text, specs, repo, data=None):
    """Replace the first START..END pair with the freshly rendered apps section. Only the first
    pair: a later mention of the markers in prose must not be replaced by a second table."""
    if README_START not in readme_text or README_END not in readme_text:
        raise SystemExit(f"README is missing the {README_START} / {README_END} markers")
    head, rest = readme_text.split(README_START, 1)
    _, tail = rest.split(README_END, 1)
    return f"{head}{README_START}\n\n{render_apps_section(specs, repo, data)}\n\n{README_END}{tail}"


def main(argv=None):
    ap = argparse.ArgumentParser(description="Generate Obtainium artifacts from the TOML app config.")
    ap.add_argument("--configs", default="configs/patches", help="directory of per-source TOMLs")
    ap.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", ""), help="owner/repo that hosts the releases")
    ap.add_argument("--json", help="write the Obtainium import file here")
    ap.add_argument("--page", help="write OBTAINIUM.md here")
    ap.add_argument("--readme", help="rewrite the apps section between the markers in this README")
    ap.add_argument("--manifest", action="append", default=[], metavar="FILE",
                    help="an archive manifest (archive/stable.json) to read versions and applied patches from; repeatable")
    args = ap.parse_args(argv)
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", args.repo or ""):
        raise SystemExit("--repo owner/repo is required (or set GITHUB_REPOSITORY)")
    specs = specs_from_configs(args.configs)
    if not specs:
        raise SystemExit(f"no enabled apps found under {args.configs}")
    if args.json:
        with open(args.json, "w", encoding="utf-8", newline="\n") as f:
            json.dump(import_document(specs, args.repo), f, indent=2, ensure_ascii=False)
            f.write("\n")
    if args.page:
        with open(args.page, "w", encoding="utf-8", newline="\n") as f:
            f.write(obtainium_page(specs, args.repo))
    if args.readme:
        with open(args.readme, encoding="utf-8") as f:
            text = f.read()
        with open(args.readme, "w", encoding="utf-8", newline="\n") as f:
            f.write(update_readme(text, specs, args.repo, load_manifest_data(args.manifest)))
    print(f"{len(specs)} app(s): " + ", ".join(s["display"] for s in specs))


if __name__ == "__main__":
    main()
