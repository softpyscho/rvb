#!/usr/bin/env python3
"""Write build.md — the body of a numbered release — from build.json and build/.

Run by scripts/build.sh after the last build. build.md is rendered on GitHub and also
relayed to Telegram by build_notify_telegram.sh, which keeps only the plain grammar
(`### heading`, `* bullet`, `  * sub-bullet`, `**bold**`, `` `code` ``, `[text](url)`) and
drops what GitHub alone can show: lines starting with `<`, `![`, `> `, and any line that
carries a long Obtainium link. Anything added here must either use that grammar or sit on
such a line.

Env (all optional):
    NEXT_VER_CODE                    release tag (links point at it)
    GITHUB_REPOSITORY, GITHUB_SERVER_URL
    IS_PRERELEASE                    "true" for the beta pool
    RELEASE_NOTES_TG_LINK / _DONATE_LINK / _WEBSITE_LINK
                                     footer links; a link that is not set is left out
"""
import json
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import obtainium  # noqa: E402
from naming import extract_arch, normalize_arch  # noqa: E402

ARCH_ORDER = {"arm64": 0, "arm": 1, "all": 2, "universal": 3, "x86_64": 4, "x86": 5}
ARCH_LABEL = {"arm64": "arm64", "arm": "arm-v7a", "all": "universal", "universal": "universal",
              "x86_64": "x86_64", "x86": "x86"}


def resolve_display_name(target_key, info):
    base_name = info.get("display_name") or target_key
    variant = (info.get("variant") or "").strip()
    sub_variant = (info.get("sub_variant") or "").strip()
    extras = []
    if variant and variant.lower() != "default":
        extras.append(variant)
    if sub_variant:
        extras.append(sub_variant)
    return f"{base_name} ({' - '.join(extras)})" if extras else base_name


def patch_tag(changelog_url, patches_ref):
    """The patch bundle's release tag, from its changelog link or, failing that, its file name."""
    first_url = changelog_url.split()[0] if changelog_url else ""
    for marker in ("/tag/", "/-/releases/", "/releases/"):
        if marker in first_url:
            return first_url.split(marker)[-1].strip("/")
    if patches_ref:
        ref_part = re.sub(r"\.(mpp|jar|rvp|apk|zip)$", "", patches_ref.split()[0], flags=re.IGNORECASE)
        m = re.search(r"v?\d+(\.\d+)+([.-][a-zA-Z0-9]+)*", ref_part)
        if m:
            return m.group(0) if m.group(0).startswith("v") else f"v{m.group(0)}"
    return ""


def is_mirror(info):
    """A mirrored app names no patch source and applied no patches."""
    return not (info.get("patches_source") or "").strip() and not (info.get("patches") or "").strip()


def collect(build_info, built_files, base_url):
    """Group the build's apps by patch source (mirrored apps last)."""
    groups = {}
    for target_key, info in build_info.items():
        mirrored = is_mirror(info)
        patches_source = (info.get("patches_source") or "").strip()
        patches_ref = (info.get("patches") or "").strip()
        changelog_url = (info.get("changelog") or "").strip()
        if mirrored:
            gkey, source, tag, cl = "~mirror", "", "", ""
        else:
            source = patches_source.split()[0] if patches_source else \
                (patches_ref.split()[0].split("/")[0] if "/" in patches_ref else "Patched")
            gkey, tag, cl = source, patch_tag(changelog_url, patches_ref), (changelog_url.split() or [""])[0]
        group = groups.setdefault(gkey, {"source": source, "tag": tag, "changelog": cl, "mirrored": mirrored, "apps": {}})

        display_name = resolve_display_name(target_key, info)
        version = info.get("version", "")
        prefix = (info.get("name") or "").lower()
        exact = (info.get("file") or "").strip()
        app = {"display": display_name, "version": version, "package": (info.get("package_name") or "").strip(),
               "apks": [], "modules": [], "applied": info.get("applied_patches") or [], "prefix": info.get("name") or "",
               "exact": exact}
        for fname in built_files:
            lower = fname.lower()
            if exact:
                if fname != exact:
                    continue
                exts = info.get("exts") or [""]
                raw_arch = info.get("arch") or exts[0].rsplit(".", 1)[0]
            elif lower.startswith(prefix + "-v") or lower.startswith(prefix + "-module-"):
                raw_arch = extract_arch(fname, version)
            else:
                continue
            url = f"{base_url}/{fname}"
            if lower.endswith(".apk") and "-module-" not in lower:
                app["apks"].append((normalize_arch(raw_arch), raw_arch, url))
            elif lower.endswith(".zip") and "-module-" in lower:
                app["modules"].append((normalize_arch(raw_arch), raw_arch, url))
        for key in ("apks", "modules"):
            app[key].sort(key=lambda x: ARCH_ORDER.get(x[0], 99))
        if app["apks"] or app["modules"]:
            group["apps"][display_name] = app
    return groups


def badge(label, message, color):
    return f"![{label}](https://img.shields.io/badge/{label}-{message}-{color}?style=for-the-badge)"


def render(build_info, built_files, env):
    repo = (env.get("GITHUB_REPOSITORY") or "").strip()
    server = (env.get("GITHUB_SERVER_URL") or "https://github.com").rstrip("/")
    tag = (env.get("NEXT_VER_CODE") or "").strip()
    prerelease = (env.get("IS_PRERELEASE") or "").lower() == "true"
    base_url = f"{server}/{repo}/releases/download/{tag}" if (repo and tag) else "./build"

    groups = collect(build_info, built_files, base_url)
    # patched sources A-Z, mirrored apps last
    order = sorted(k for k in groups if not groups[k]["mirrored"]) + [k for k in groups if groups[k]["mirrored"]]
    order = [k for k in order if groups[k]["apps"]]
    total = sum(len(groups[k]["apps"]) for k in order)

    lines = []
    if total:
        channel = ("beta", "pre--release", "8957e5") if prerelease else ("stable", "stable", "21a378")
        lines += [
            '<div align="center">', "",
            " ".join(filter(None, [
                badge("build", tag, "2f81f7") if tag else "",
                badge("channel", channel[1], channel[2]),
                badge("apps", str(total), "f78166"),
            ])), "",
            "</div>", "",
        ]
        if repo:
            lines += [
                "> [!TIP]",
                f"> **Following these in Obtainium?** Tap **🔔 Obtainium** under an app to add it with the right "
                f"filter already filled in, or see the [Obtainium guide]({server}/{repo}/blob/main/OBTAINIUM.md).",
                "",
            ]
        if prerelease:
            lines += ["> [!WARNING]", "> Pre-release channel: built from beta patches, expect rough edges.", ""]

    any_patched = False
    for gkey in order:
        group = groups[gkey]
        if group["mirrored"]:
            lines += ["### 📦 Mirrored apps (stock, unmodified)", ""]
        else:
            any_patched = True
            src, tag_s, cl = group["source"], group["tag"], group["changelog"]
            if tag_s and cl:
                tag_str = f" ([{tag_s}]({cl}))"
            elif tag_s:
                tag_str = f" ({tag_s})"
            elif cl:
                tag_str = f" ([changelog]({cl}))"
            else:
                tag_str = ""
            lines += [f"### 🧩 {src}{tag_str}", ""]

        for name in sorted(group["apps"], key=str.lower):
            app = group["apps"][name]
            # "v" only in front of a number: a nightly's version is the word "nightly"
            v = app["version"]
            ver = f" `{'v' if v[:1].isdigit() else ''}{v}`" if v else ""
            lines.append(f"* **{app['display']}**{ver}")
            if app["apks"]:
                lines.append("  * APK: " + " • ".join(f"[{ARCH_LABEL.get(a, raw)}]({u})" for a, raw, u in app["apks"]))
            if app["modules"]:
                lines.append("  * Module: " + " • ".join(f"[{ARCH_LABEL.get(a, raw)}]({u})" for a, raw, u in app["modules"]))
            if repo and app["apks"] and app["package"]:
                links = []
                for a, raw, _ in app["apks"]:
                    flt = obtainium.exact_regex(app["exact"]) if app["exact"] else obtainium.apk_regex(app["prefix"], raw)
                    entry = obtainium.app_entry(app["package"], app["display"], repo, flt, prerelease)
                    links.append(f"[{ARCH_LABEL.get(a, raw)}]({obtainium.redirect_link(entry)})")
                # one line, so Telegram can drop it whole (the links are very long)
                lines.append("  * 🔔 Add to Obtainium: " + " • ".join(links))
            if app["applied"]:
                patches = " · ".join(str(p).replace("<", "&lt;").replace(">", "&gt;") for p in app["applied"])
                lines.append(f"  <details><summary>{len(app['applied'])} patches applied</summary><br>{patches}</details>")
            lines.append("")

    lines += ["---", "", "### ℹ️ Notes"]
    if any_patched:
        lines += [
            "• Install [MicroG-RE](https://github.com/MorpheApp/MicroG-RE/releases/latest) or "
            "[MicroG](https://github.com/ReVanced/GmsCore/releases/latest), required for Google APKs.  ",
            "• Use [Zygisk Detach](https://github.com/j-hc/zygisk-detach) to stop Play Store from updating Modules.  ",
        ]
    if any(groups[k]["mirrored"] for k in order):
        lines.append("• 📦 Mirrored apps are the vendor's own APK, republished as-is so they can be tracked here.  ")
    lines.append("")
    footer = []
    if repo:
        footer.append(f"🌐 [GitHub]({server}/{repo})")
    for var, label, icon in (("RELEASE_NOTES_TG_LINK", "Group", "💬"), ("RELEASE_NOTES_DONATE_LINK", "Donate", "☕"),
                             ("RELEASE_NOTES_WEBSITE_LINK", "Website", "🔗")):
        link = (env.get(var) or "").strip()
        if link:
            footer.append(f"{icon} [{label}]({link})")
    if footer:
        lines += [" | ".join(footer), ""]
    return "\n".join(lines)


def main():
    build_dir = Path("build")
    build_json_file = Path("build.json")
    build_info = {}
    if build_json_file.exists():
        try:
            with open(build_json_file, "r", encoding="utf-8") as f:
                build_info = json.load(f)
        except Exception as e:
            print(f"Warning: Could not read {build_json_file}: {e}")
    built_files = []
    if build_dir.exists():
        built_files = sorted(f.name for f in build_dir.iterdir() if f.is_file() and f.suffix.lower() in [".apk", ".zip"])
    content = render(build_info, built_files, os.environ)
    with open("build.md", "w", encoding="utf-8") as f:
        f.write(content)
    print("Successfully generated build.md")


if __name__ == "__main__":
    main()
