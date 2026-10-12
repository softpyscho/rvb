#!/usr/bin/env python3
"""Single source of truth for "which patch sources changed since the last run".

The same diff used to be re-derived in several places with subtly different rules. It is derived
here once and every consumer projects from the records:
  * sync_patch_sources.py   -> TRIGGER_PATCHES
  * ci_check_app_patches.py -> which repos' bundles to download and hash
  * ci_generate_configs.sh  -> active.json

Reads   : tags_old.json, tags_new.json   (written by sync_patch_sources.py)
Writes  : changed_sources.json           (records; consumers project from it)
"""
import json
import os
import sys

OLD_FILE = "tags_old.json"
NEW_FILE = "tags_new.json"
OUT_FILE = "changed_sources.json"


def _repo_name(key, entry):
    """Mirror the historical jq fallback chain: repo, else key, else skip."""
    return ((entry.get("repo") if isinstance(entry, dict) else None) or key or "").strip()


def derive(tags_old, tags_new):
    """Return one record per source whose latest stable release moved since last run.

    A source that is blocked, or explicitly disabled, never yields records.
    """
    records = []
    for key, new in tags_new.items():
        if not isinstance(new, dict):
            continue
        # blocked = API/access failure; enabled:false = operator opt-out.
        if new.get("blocked") is True or new.get("enabled") is False:
            continue

        old = tags_old.get(key) or {}
        if not isinstance(old, dict):
            old = {}
        repo = _repo_name(key, new).lower()
        if not repo:
            continue

        stable_tag = new.get("stable") or ""
        stable_date = new.get("stable_date") or ""
        if stable_tag and stable_tag != (old.get("stable") or ""):
            records.append({
                "key": key, "repo": repo, "channel": "stable",
                "tag": stable_tag, "tag_date": stable_date,
                "base_date": stable_date, "newer_than_base": True,
            })
    return records


def load_json(path):
    if not os.path.exists(path):
        return {}
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def main():
    records = derive(load_json(OLD_FILE), load_json(NEW_FILE))
    with open(OUT_FILE, "w", encoding="utf-8") as f:
        json.dump(records, f, indent=2, sort_keys=True)

    repos = sorted({r["repo"] for r in records})
    print(f"Changed sources: {len(repos)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
