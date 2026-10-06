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

REDIRECT_BASE = "https://apps.obtainium.imranr.dev/redirect.html?r="


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
        "shizukuPretendToBeGooglePlay": False,
        "allowInsecure": False,
        "exemptFromBackgroundUpdates": False,
        "skipUpdateNotifications": False,
        "about": "",
    }


def app_entry(package, name, repo, apk_filter, prerelease=False):
    """One app in Obtainium's own export/deep-link shape. `additionalSettings` is a JSON
    *string* inside the JSON, which is how Obtainium stores it."""
    owner = repo.split("/")[0]
    return {
        "id": package,
        "url": f"https://github.com/{repo}",
        "author": owner,
        "name": name,
        "preferredApkIndex": 0,
        "additionalSettings": json.dumps(additional_settings(apk_filter, prerelease), separators=(",", ":")),
    }


def deep_link(entry):
    """obtainium://app/<url-encoded JSON>. GitHub strips non-http(s) links from Markdown,
    so a README or release body must use redirect_link instead."""
    return "obtainium://app/" + quote(json.dumps(entry, separators=(",", ":")), safe="")


def redirect_link(entry):
    """An https link that bounces into Obtainium (a page hosted by Obtainium's author)."""
    return REDIRECT_BASE + quote(deep_link(entry), safe="")


# ---------------------------------------------------------------------------------------
# Config -> apps (static view: README, OBTAINIUM.md, obtainium-apps.json)
# ---------------------------------------------------------------------------------------

def _truthy(value):
    return value.lower() == "true" if isinstance(value, str) else bool(value)


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
        "source": "" if mirror else str(entry.get("patches-source") or "MorpheApp/morphe-patches").replace("'", "").replace('"', ""),
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


def app_badge(spec):
    """A colour-coded badge for the app, from its badge-color / badge-icon keys. An icon slug
    shields.io does not know simply renders without a logo, so a guessed slug cannot break the
    image (a hot-linked icon CDN would show a broken-image box)."""
    color = spec["color"] if re.fullmatch(r"[0-9A-Fa-f]{6}", spec["color"] or "") else "555555"
    logo = f"&logo={spec['icon']}&logoColor=white" if re.fullmatch(r"[a-z0-9]+", spec["icon"] or "") else ""
    url = f"https://img.shields.io/badge/{_shield_text(spec['display'])}-{color}?style=for-the-badge{logo}"
    return f"![{spec['display']}]({url})"


def table_markdown(specs, repo):
    rows = ["| App | Package | Source | Channel | Obtainium |", "|:--|:--|:--|:--:|:--:|"]
    for s in sorted(specs, key=lambda s: s["display"].lower()):
        source = "📦 stock APK, unmodified" if s["mirror"] else f"🧩 `{s['source']}`"
        channel = "🧪 pre-release" if s["prerelease"] else "✅ stable"
        link = f"[**➕ Add**]({redirect_link(entry_for_spec(s, repo))})" if s["package"] else "—"
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
        "2. Tap **➕ Add** next to an app below (open this page on the phone), then **Add** in Obtainium.",
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


README_START = "<!-- apps:start -->"
README_END = "<!-- apps:end -->"


def update_readme(readme_text, specs, repo):
    if README_START not in readme_text or README_END not in readme_text:
        raise SystemExit(f"README is missing the {README_START} / {README_END} markers")
    head, rest = readme_text.split(README_START, 1)
    _, tail = rest.split(README_END, 1)
    return f"{head}{README_START}\n{table_markdown(specs, repo)}\n{README_END}{tail}"


def main(argv=None):
    ap = argparse.ArgumentParser(description="Generate Obtainium artifacts from the TOML app config.")
    ap.add_argument("--configs", default="configs/patches", help="directory of per-source TOMLs")
    ap.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", ""), help="owner/repo that hosts the releases")
    ap.add_argument("--json", help="write the Obtainium import file here")
    ap.add_argument("--page", help="write OBTAINIUM.md here")
    ap.add_argument("--readme", help="rewrite the app table between the markers in this README")
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
            f.write(update_readme(text, specs, args.repo))
    print(f"{len(specs)} app(s): " + ", ".join(s["display"] for s in specs))


if __name__ == "__main__":
    main()
