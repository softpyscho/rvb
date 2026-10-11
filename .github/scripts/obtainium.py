#!/usr/bin/env python3
"""Obtainium entries for this repository's releases — one definition, three consumers.

Obtainium tracks a source, not an app: every app here lives in the same repository, so each one
needs its own link filter and a few settings that make a shared place work. This module is the
single place those settings live. It is imported by

  * generate_release_notes.py  per-app links inside each release body (exact file names)
  * obtainium.py (CLI below)   OBTAINIUM.md, the README app table and the importable
                               obtainium-apps.json (names derived from the TOML config)

Why the entries are what they are:

  HTML source on the archive    Obtainium's GitHub source can only call a release by its tag or
  release's asset list          title, and here those are build numbers (`260035`) - an update
  (`releases/expanded_assets/   read "260035", not "11.2.0". The HTML source reads the version out
  stable|beta`)                 of the file name instead. That page is the rolling `stable` /
                              `beta` archive, which holds the newest files of every app whichever
                              build made them (a build only contains the apps that changed), and
                              is plain web HTML with no API rate limit.
  customLinkFilterRegex       `/<file-prefix>-v[^/]+-<arch>\\.apk$`, the asset grammar documented
                              in docs/storage-and-branches.md, matched against the whole link.
  versionExtractionRegEx      `/<file-prefix>-v(.+)-<arch>\\.apk$`, group 1 = the app's version.
  sortByLastLinkSegment       Obtainium sorts the matching links by file name and takes the last,
                              i.e. the highest version.
  versionDetection = false    Obtainium records the version it extracted rather than comparing it
                              with what the phone reports (a patch may rewrite versionName).
  `beta` page for 🧪 apps      apps built in the beta pool are archived in the `beta` release.

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
    become one '-', no leading/trailing '-'. test_release_notes.sh runs both over the configured apps
    config and fails on any difference, so the two cannot drift silently."""
    return re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9]+", "-", (value or "").lower()))


def regex_escape(text):
    """Escape for Dart's RegExp (Obtainium). Only characters that are special are escaped."""
    return re.sub(r"([.^$*+?()\[\]{}|\\])", r"\\\1", text)


def archive_tag(prerelease):
    """The rolling archive release an app's newest file lives in: `beta` for the pre-release
    channel, `stable` otherwise. Each keeps the newest versions of every app, whichever build
    produced them."""
    return "beta" if prerelease else "stable"


def archive_page(repo, prerelease):
    """The page Obtainium reads: GitHub's asset list of the archive release (plain HTML, no API
    token or rate limit; `/releases/expanded_assets/<tag>` is what the release page itself loads)."""
    return f"https://github.com/{repo}/releases/expanded_assets/{archive_tag(prerelease)}"


def _arch_re(arch):
    return "(all|universal)" if arch in ("all", "universal") else regex_escape(arch)


def name_patterns(prefix, arch):
    """(link filter, version regex) for `<prefix>-v<version>-<arch>.apk`. Both run against the
    decoded link (the whole URL), so they start at the `/` before the file name; the version
    regex captures the app's own version out of the file name."""
    return (f"/{regex_escape(prefix)}-v[^/]+-{_arch_re(arch)}\\.apk$",
            f"/{regex_escape(prefix)}-v(.+)-{_arch_re(arch)}\\.apk$")


def kept_lead(file_name):
    """The stable lead of a name that keeps its source's own spelling: everything before the first
    `-` followed by a digit (`Duck.Detector-2026.10.06-82566ffa96bb.apk` -> `Duck.Detector`), or
    None when the name has nothing to split on."""
    m = re.match(r"^(.+?)-(?=\d)", file_name)
    return m.group(1) if m and file_name.lower().endswith(".apk") else None


def kept_patterns(file_name):
    """(link filter, version regex) for a file that keeps its source's own name (mirror +
    keep-filename). Such names embed what changes per build - a date, a hash - so only the lead is
    matched and the rest is the version. A name with no lead is matched whole and yields no version
    (Obtainium then falls back to its pseudo-version)."""
    lead = kept_lead(file_name)
    if lead:
        return f"/{regex_escape(lead)}-[^/]+\\.apk$", f"/{regex_escape(lead)}-(.+)\\.apk$"
    return f"/{regex_escape(file_name)}$", ""


def guessed_kept_patterns(name):
    """Same, before the file name is known: the app's own words with any separator the source may
    have used between them (`Duck Detector` -> `Duck[._-]?Detector`)."""
    words = re.findall(r"[A-Za-z0-9]+", name) or [name]
    lead = "[._-]?".join(regex_escape(w) for w in words)
    return f"/{lead}-[^/]+\\.apk$", f"/{lead}-(.+)\\.apk$"


def html_settings(link_filter, version_re):
    """Obtainium's HTML-source settings. The GitHub source can only call a release by its tag or
    title - here a build number (`260035`) - so an update would read "260035". The HTML source
    reads the version out of the file name instead. Every key it reads is written (a deterministic
    import) and the shape is the one a working HTML entry of a sibling project carries."""
    return {
        "intermediateLink": [],
        "customLinkFilterRegex": link_filter,
        "filterByLinkText": False,
        "matchLinksOutsideATags": False,
        "skipSort": False,
        "reverseSort": False,
        "sortByLastLinkSegment": True,
        "versionExtractWholePage": False,
        "requestHeader": [{"requestHeader": "User-Agent: Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 "
                                            "(KHTML, like Gecko) Chrome/114.0.0.0 Mobile Safari/537.36"}],
        "defaultPseudoVersioningMethod": "partialAPKHash",
        "trackOnly": False,
        "versionExtractionRegEx": version_re,
        "matchGroupToUse": "1" if version_re else "",
        # off: the version Obtainium records is the one it extracted, so there is nothing to
        # reconcile with what the phone reports (a patch may rewrite its versionName)
        "versionDetection": False,
        "useVersionCodeAsOSVersion": False,
        "apkFilterRegEx": "",
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


def app_entry(package, name, repo, link_filter, version_re, prerelease=False):
    """One app as Obtainium's own export/deep link spells it.

    The whole object is written, not just the fields that matter here: Obtainium reads an app
    back with every one of these keys (latestVersion, apkUrls, pinned, ... are not optional on
    import). `additionalSettings` is a JSON *string* inside the JSON, which is how Obtainium
    stores it. `overrideSource: HTML` is what makes the app use the HTML source for a github.com URL."""
    owner = repo.split("/")[0]
    return {
        "id": package,
        "url": archive_page(repo, prerelease),
        "author": owner,
        "name": name,
        "installedVersion": "",
        "latestVersion": "",
        "apkUrls": "[]",
        "otherAssetUrls": "[]",
        "preferredApkIndex": 0,
        "additionalSettings": json.dumps(html_settings(link_filter, version_re), separators=(",", ":")),
        "lastUpdateCheck": None,
        "pinned": False,
        "categories": [],
        "releaseDate": None,
        "changeLog": None,
        "overrideSource": "HTML",
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


def entry_for_spec(spec, repo, data=None):
    """The Obtainium entry of one configured app. `data` (load_manifest_data) supplies the real
    file name of an app that keeps its source's own - the lead of it is stable across builds."""
    if spec["keep_filename"]:
        known = ((data or {}).get(spec["prefix"]) or {}).get("file")
        link_filter, version_re = kept_patterns(known) if known else guessed_kept_patterns(spec["name"])
    else:
        link_filter, version_re = name_patterns(spec["prefix"], spec["arch"])
    return app_entry(spec["package"], spec["display"], repo, link_filter, version_re, spec["prerelease"])


def import_document(specs, repo, data=None):
    return {"apps": [entry_for_spec(s, repo, data) for s in specs if s["package"]]}


def _shield_text(text):
    """Escape a label for shields.io's static-badge path (-, _ and space are syntax)."""
    return quote(text.replace("-", "--").replace("_", "__").replace(" ", "_"), safe="_-")


DEFAULT_BADGE_COLOR = "4500FF"
DEFAULT_BADGE_ICON = "android"
OBTAINIUM_BADGE = ("![Add to Obtainium](https://img.shields.io/badge/Add_to_Obtainium-8b5cf6"
                   "?style=flat-square&logo=android&logoColor=white)")
STORE_SOURCES = {"apkmirror", "uptodown", "apkpure", "apkcombo"}  # sources that are app stores
_PLAY_ID = re.compile(r"^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$")


def obtainium_badge_link(spec, repo, data=None):
    """The purple "Add to Obtainium" badge, linking to this app's redirect link."""
    return f"[{OBTAINIUM_BADGE}]({redirect_link(entry_for_spec(spec, repo, data))})"


def app_badge(spec):
    """The app's flat badge, in its own colour and logo, linking to its Play Store page - or, when
    the app cannot be a Play listing, to where it is downloaded: a package id that is not one
    (`Duck.Detector`), or an app that only comes from a GitHub release or a direct link (no store
    among its sources), such as an APK its author publishes themselves."""
    name = spec["display"]
    color = spec["color"] if re.fullmatch(r"[0-9A-Fa-f]{6}", spec["color"] or "") else DEFAULT_BADGE_COLOR
    icon = quote(spec["icon"] or DEFAULT_BADGE_ICON, safe="")
    url = (f"https://img.shields.io/badge/{quote(name.replace('-', '--'), safe='')}-{color}"
           f"?style=flat-square&logo={icon}&logoColor=%23FFFFFF")
    badge = f"![{name}]({url})"
    on_a_store = not spec["urls"] or bool(set(spec["urls"]) & STORE_SOURCES)
    if spec["package"] and _PLAY_ID.match(spec["package"]) and on_a_store:
        return f"[{badge}](https://play.google.com/store/apps/details?id={spec['package']})"
    first = next(iter(spec["urls"].values()), "")
    return f"[{badge}]({first})" if first else badge


def apk_source(spec, data):
    """Where the stock APK of the latest build came from - the one source that supplied it, linked
    to the page the config names for it. Not every configured source: those are only fallbacks.
    Before a build has recorded it, say so rather than list candidates."""
    d = data.get(spec["prefix"]) or {}
    used = d.get("apk_source")
    if not used:
        return "*(pending)*" if not d else "*(not recorded)*"
    label = DL_LABEL.get(used, used.replace("_", " ").title())
    url = spec["urls"].get(used)
    return f"[{label}]({url})" if url else label


def _vlabel(version):
    """`v` in front of a number only: a nightly's version is the word "nightly"."""
    return version if version.startswith("v") or not version[:1].isdigit() else f"v{version}"


def _version_badge(spec, label, name="version"):
    color = spec["color"] if re.fullmatch(r"[0-9A-Fa-f]{6}", spec["color"] or "") else "3e9cfb"
    # _shield_text, not a bare quote(): a dash in the message ("v12.19.1-release.0") would
    # otherwise split it into message and colour in shields.io's path syntax.
    return f"![{name}](https://img.shields.io/badge/{name}-{_shield_text(label)}-{color}?logo=android&logoColor=white)"


def _configured_version_label(spec):
    """What the config asks for (Auto / Latest / a pinned version), for an app not built yet."""
    mode = spec["version_mode"]
    if mode == "auto":
        return "Auto (pre-release)" if spec["prerelease"] else "Auto"
    if mode == "latest":
        return "Latest (pre-release)" if spec["prerelease"] else "Latest"
    return mode if not mode[:1].isdigit() else f"v{mode}"


def version_label(spec, data):
    """One version shield: the version last published when a manifest says so, else what the
    config asks for. Used where there is no patch recommendation to set it against (the mirrors)."""
    known = (data.get(spec["prefix"]) or {}).get("version")
    return _version_badge(spec, _vlabel(known) if known else _configured_version_label(spec))


def versions_cell(spec, data):
    """The Version cell of a patched app: two labelled badges in one column, what the patches
    recommend above what was built. The recommendation is always a version number (or "Any" when
    the bundle names none) as the last build recorded it - never the config's `auto`, which is a
    setting, not a version. Where nothing has been recorded yet it says pending."""
    d = data.get(spec["prefix"]) or {}
    # manifests written before 2026-10-09 may hold every tied version, newest first
    rec = ((d.get("recommended") or "").splitlines() or [""])[0].strip()
    if d.get("has_record"):
        recommended = _version_badge(spec, _vlabel(rec) if rec else "Any", "recommended")
    else:
        recommended = "*recommended: pending*"
    known = d.get("version")
    built = _version_badge(spec, _vlabel(known), "built") if known else "*built: pending*"
    return f"{recommended}<br>{built}"


def patches_cell(spec, data):
    """The Patches column: a dropdown of what the last build actually applied (from its manifest),
    plus any -O option the config sets; `Pending` until a build has published."""
    if spec["mirror"]:
        return "*(None - Stock Mirror)*"
    options = re.findall(r"-O(\w+)=(?:'([^']*)'|\"([^\"]*)\"|(\S+))", spec["patcher_args"])
    options_str = ""
    if options:
        options_str = "<br>⚙️ " + ", ".join(f"{k}={a or b or c}" for k, a, b, c in options)
    d = data.get(spec["prefix"]) or {}
    applied = d.get("applied") or []
    skipped, failed, excluded = d.get("skipped") or [], d.get("failed") or [], d.get("excluded") or []
    if not (applied or skipped or failed):
        return f"*(Pending first build)*{options_str}"
    names = sorted(set(applied), key=str.lower)
    noun = "patch" if len(names) == 1 else "patches"
    problems = len(skipped) + len(failed)
    summary = f"<b>{len(names)} {noun}</b>" + (f" · ⚠️ {problems} not applied" if problems else "")
    parts = ["<br>".join(f"`{n}`" for n in names)] if names else []
    # a patch the bundle meant to apply that did not, and why - the point of this column
    if skipped:
        parts.append("⚠️ <b>Skipped</b> — " + ", ".join(f"`{x['name']}` ({_short_reason(x.get('reason', ''))})" for x in skipped))
    if failed:
        parts.append("❌ <b>Failed</b> — " + ", ".join(f"`{n}`" for n in failed))
    if excluded:
        parts.append("🚫 <b>Excluded by config</b> — " + ", ".join(f"`{n}`" for n in excluded))
    if options_str:
        parts.append(options_str.removeprefix("<br>"))
    return f"<details><summary>{summary}</summary><br>{'<br>'.join(parts)}</details>"


def _short_reason(reason):
    """"incompatible with com.pkg 2.5.0.2 (supported: ...)" -> "incompatible with v2.5.0.2"."""
    m = re.match(r"incompatible with \S+ (\S+)", reason or "")
    return f"incompatible with {_vlabel(m.group(1))}" if m else (reason or "not applied")[:60]


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


TABLE_HEAD = ["<div align=\"center\">", "", "| App | Version | APK Source | Patches | Obtainium |",
              "|:---|:-------:|:----------:|:--------|:---------:|"]
MIRROR_HEAD = ["<div align=\"center\">", "", "| App | Version | APK Source | Obtainium |",
               "|:---|:-------:|:----------:|:---------:|"]


def _row(spec, repo, data):
    return (f"| {app_badge(spec)} | {versions_cell(spec, data)} "
            f"| {apk_source(spec, data)} | {patches_cell(spec, data)} | {obtainium_badge_link(spec, repo, data)} |")


def _mirror_row(spec, repo, data):
    return (f"| {app_badge(spec)} | {version_label(spec, data)} | {apk_source(spec, data)} "
            f"| {obtainium_badge_link(spec, repo, data)} |")


def render_apps_section(specs, repo, data=None):
    """The apps section of the README: one group per patch source (in config order), then the
    stock mirrors, each a centred table. Patched apps: App, Version (what the patches recommend and
    what was built, two badges in the one column), APK Source (the one used), Patches (with what was
    not applied), Obtainium. Mirrors have nothing patched or recommended: App, Version, APK Source, Obtainium."""
    data = data or {}
    groups, mirrors = {}, []
    for spec in specs:
        if spec["mirror"]:
            mirrors.append(spec)
        else:
            groups.setdefault((spec["source"], spec["host"]), []).append(spec)

    legend = ("> **Version** shows the version the patches *recommend* above the version that was *built* "
              "(they differ when a source no longer offers the recommended one). **APK Source** is where the "
              "stock APK of that build came from. ⚠️ in **Patches** means a patch the build meant to apply was "
              "skipped or failed - open the row to see which and why.")
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
                 "> **Source:** Direct stock APK mirrors (Unpatched)", "", *MIRROR_HEAD]
        lines += [_mirror_row(m, repo, data) for m in mirrors]
        lines += ["", "</div>"]
        blocks.append("\n".join(lines))
    return legend + "\n\n" + "\n\n---\n\n".join(blocks)


def load_manifest_data(paths):
    """Per app (keyed by file prefix): the version and applied patches of its newest published
    file, from the archive manifests (state/archive/stable.json, state/archive/beta.json)."""
    best = {}
    for path in paths:
        try:
            with open(path, encoding="utf-8") as f:
                files = (json.load(f) or {}).get("files") or {}
        except (OSError, ValueError):
            continue
        for file_name, entry in files.items():
            if entry.get("fileType") != "APK":
                continue
            key, stamp = entry.get("name") or "", entry.get("publishedAt") or ""
            if key and (key not in best or stamp > best[key][0]):
                best[key] = (stamp, {"version": entry.get("version") or "",
                                     "file": file_name,
                                     "applied": entry.get("appliedPatches") or [],
                                     # the keys below exist only on builds from 2026-10 on; has_record
                                     # tells "the build said nothing was recommended" from "no record"
                                     "has_record": "apkSource" in entry,
                                     "apk_source": entry.get("apkSource") or "",
                                     "recommended": entry.get("recommendedVersion") or "",
                                     "skipped": entry.get("skippedPatches") or [],
                                     "failed": entry.get("failedPatches") or [],
                                     "excluded": entry.get("excludedPatches") or []})
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
        "3. Obtainium installs the newest build of *that app only* and keeps it updated, showing the app's own "
        "version (e.g. `11.2.0`) in its update list.",
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
        "tell them apart and to read each app's real version. You can check or change them under the "
        "app's ⚙ settings in Obtainium.",
        "",
        "| Setting | Value | Why |",
        "|:--|:--|:--|",
        "| Source | **HTML** · `https://github.com/" + repo + "/releases/expanded_assets/stable` (`beta` for 🧪 apps) | "
        "the rolling archive release always lists the newest files of *every* app, whichever build made them; "
        "it is plain web HTML, so there is no API rate limit |",
        "| Link filter (regex) | `/<app>-v[^/]+-<arch>\\.apk$` | picks one app's file out of the list |",
        "| Version (regex, group 1) | `/<app>-v(.+)-<arch>\\.apk$` | the version comes from the file name, so the update "
        "list shows `11.2.0` and not the build number (`260035`) |",
        "| Sort | by file name | the highest version is taken |",
        "| Standard version detection | **off** | Obtainium records the version it extracted; a patch may rewrite what "
        "the phone reports as the app's version |",
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
        "- **Only the newest two versions of an app are kept** in the archive, so an app that is rebuilt often "
        "(a nightly) always has its latest file there. An app whose file name has no version in it "
        "(`keep-filename`) is matched by the lead of its name and shows the rest (a date and hash) as its version.",
        "",
        "<sub>Regenerate with <code>python3 .github/scripts/obtainium.py --configs configs/patches --repo "
        + repo + " --page OBTAINIUM.md --json obtainium-apps.json --readme README.md "
        "--manifest state/archive/stable.json --manifest state/archive/beta.json</code></sub>",
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
    data = load_manifest_data(args.manifest)
    if args.json:
        with open(args.json, "w", encoding="utf-8", newline="\n") as f:
            json.dump(import_document(specs, args.repo, data), f, indent=2, ensure_ascii=False)
            f.write("\n")
    if args.page:
        with open(args.page, "w", encoding="utf-8", newline="\n") as f:
            f.write(obtainium_page(specs, args.repo))
    if args.readme:
        with open(args.readme, encoding="utf-8") as f:
            text = f.read()
        with open(args.readme, "w", encoding="utf-8", newline="\n") as f:
            f.write(update_readme(text, specs, args.repo, data))
    print(f"{len(specs)} app(s): " + ", ".join(s["display"] for s in specs))


if __name__ == "__main__":
    main()
