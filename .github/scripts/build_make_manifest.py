#!/usr/bin/env python3
"""Convert the builder's raw build.json into the unified filename-keyed manifest.

The numbered release gets this file uploaded as build.json, and the archive
releases (stable/beta) get a cumulative merge of it (see merge_archive_manifest.sh).
Schema matches .github/scripts/backfill_manifests.py output (schema version 1).

A build record may carry `file`, the exact asset name of an artifact that keeps its source's
own name (mirror apps with keep-filename); such an entry is matched by that name instead of by
the <name>-v / <name>-module- prefix, and its arch comes from the record's own fields.

Additive keys per file, from the record's apk_source / recommended_version / skipped_patches /
failed_patches / excluded_patches: apkSource, recommendedVersion, skippedPatches ([{name, reason}]),
failedPatches, excludedPatches. See docs/storage-and-branches.md for what each means.

Env:
    NEXT_VER_CODE   release tag / build number (required)
    IS_PRERELEASE   true -> beta channel, else stable
Writes:
    temp/manifest/build.json
"""
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from naming import extract_arch, normalize_arch, normalize_key, parse_patch_info  # noqa: E402


def main():
    next_ver_code = os.environ.get("NEXT_VER_CODE", "").strip()
    if not next_ver_code:
        print("Error: NEXT_VER_CODE not set.", file=sys.stderr)
        sys.exit(1)
    is_prerelease = os.environ.get("IS_PRERELEASE", "false").lower() == "true"
    channel = "beta" if is_prerelease else "stable"
    now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    build_json_file = Path("build.json")
    if not build_json_file.exists():
        print("No build.json found — writing empty manifest.")
        build_info = {}
    else:
        with open(build_json_file, encoding="utf-8") as f:
            build_info = json.load(f)

    build_dir = Path("build")
    built_files = [f for f in build_dir.iterdir() if f.is_file()] if build_dir.exists() else []

    files = {}
    for target_key, info in build_info.items():
        file_prefix = info.get("name") or target_key
        prefix_lower = file_prefix.lower()
        # `file` is set only for an artifact that keeps its source's own name (mirror
        # apps with keep-filename) and so cannot be found by the <prefix>-v grammar.
        exact_file = (info.get("file") or "").strip()
        if exact_file:
            matching_files = [f for f in built_files if f.name == exact_file]
        else:
            matching_files = [
                f for f in built_files
                if f.name.lower().startswith(prefix_lower + "-v") or f.name.lower().startswith(prefix_lower + "-module-")
            ]
        if not matching_files:
            continue

        app_name = (info.get("display_name") or target_key).strip()
        app_key = normalize_key(app_name) or normalize_key(target_key)

        brand_cfg = (info.get("brand") or "").strip()
        if brand_cfg:
            brand_key, brand_name = normalize_key(brand_cfg), brand_cfg
        else:
            brand_key, brand_name = parse_patch_info(info.get("patches_source"), info.get("patches"))

        variant_cfg = (info.get("variant") or "").strip()
        variant_val = variant_cfg if (variant_cfg and variant_cfg.lower() != "default") else None
        sub_variant_cfg = (info.get("sub_variant") or "").strip()
        sub_variant_val = sub_variant_cfg if sub_variant_cfg else None
        version = info.get("version", "")
        patches_ref = (info.get("patches") or "").strip()
        changelog_url = (info.get("changelog") or "").strip()

        # A kept name carries no reliable arch token, so read it from what the build
        # recorded (exts look like "arm64-v8a.apk").
        exact_arch = ""
        if exact_file:
            exts = info.get("exts") or [""]
            exact_arch = info.get("arch") or exts[0].rsplit(".", 1)[0]
        for f in matching_files:
            fname = f.name
            lower = fname.lower()
            if not (lower.endswith(".apk") or lower.endswith(".zip")):
                continue
            files[fname] = {
                "name": file_prefix,
                "version": version,
                "appKey": app_key,
                "appName": app_name,
                "arch": normalize_arch(exact_arch if exact_file else extract_arch(fname, version)),
                "fileType": "APK" if lower.endswith(".apk") else "Module",
                "brandKey": brand_key,
                "brandName": brand_name,
                "variant": variant_val,
                "subVariant": sub_variant_val,
                "packageName": (info.get("package_name") or "").strip() or None,
                "patchSources": patches_ref.split() if patches_ref else [],
                "changelogs": changelog_url.split() if changelog_url else [],
                "appliedPatches": info.get("applied_patches") or [],
                "originBuild": next_ver_code,
                "publishedAt": now_iso,
            }
            # What this build actually used and left out (added 2026-10; older records have none of
            # these keys, which readers must treat as "unknown"). apkSource: the download source that
            # supplied the stock APK; recommendedVersion: what the patches recommend (null = they
            # name no version). The three lists appear only when they have something to say.
            if "apk_source" in info:
                files[fname]["apkSource"] = (info.get("apk_source") or "").strip() or None
                # a bundle can tie several versions; the first listed is the newest, the one the build takes
                files[fname]["recommendedVersion"] = ((info.get("recommended_version") or "").strip().splitlines() or [""])[0].strip() or None
            for rec_key, out_key in (("skipped_patches", "skippedPatches"), ("failed_patches", "failedPatches"),
                                     ("excluded_patches", "excludedPatches")):
                if info.get(rec_key):
                    files[fname][out_key] = info[rec_key]

    manifest = {
        "schema": 1,
        "kind": "build",
        "meta": {"build": next_ver_code, "channel": channel, "publishedAt": now_iso},
        "files": files,
    }

    out_dir = Path("temp/manifest")
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / "build.json"
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, separators=(",", ":"))
    print(f"Wrote {out_path} with {len(files)} file entries (build {next_ver_code}, channel {channel}).")


if __name__ == "__main__":
    main()
