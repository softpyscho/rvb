"""
compile_patch_configs.py
Parses the app configuration, configs/config.toml, and generates config.json: the one build
pool, every enabled app.
- apps with enabled = false are omitted
- patches-version is "stable" (the default: the source's latest release) or a pinned release tag;
  "beta" and "both" no longer exist and are rejected loudly rather than guessed at

The config is one file. A directory of TOML files is read too (tests build small ones), each file
with its own file-level defaults; an app key must be unique across them.

Which release "stable" means is not resolved here: the generated config keeps the keyword and the
build looks the tag up in state/patch_sources.json. A pinned patches-version is copied verbatim.
"""

import os
import sys
import glob
import json

try:
    import tomllib
except ImportError:
    try:
        import tomli as tomllib
    except ImportError:
        print("Error: neither tomllib nor tomli is available.", file=sys.stderr)
        sys.exit(1)


RETIRED_CHANNELS = ("beta", "both")


def normalize_channel(val, where="patches-version"):
    """Canonicalize a patches-version value to "stable", or return a pinned tag unchanged.
    The retired channel words are an error: an app left on "beta" would otherwise be read as
    a release tag and fail much later, on the release lookup. utils.sh mirrors the keyword in
    _release_channel_of."""
    if not val or not isinstance(val, str):
        return None
    v = val.strip().lower()
    if v == "stable":
        return "stable"
    if v in RETIRED_CHANNELS:
        print(
            f"Error: {where} = \"{val.strip()}\": there is one build and no beta channel any more. "
            "Remove the key (the latest stable release is the default) or pin a release tag.",
            file=sys.stderr)
        sys.exit(1)
    return val.strip()  # Pinned version string like "v1.41.0"


CONFIG_PATH = "configs/config.toml"


def toml_sources(path=CONFIG_PATH):
    """The TOML files behind a config path: the file itself, or the *.toml files of a directory."""
    if os.path.isdir(path):
        return sorted(glob.glob(os.path.join(path, "*.toml")))
    return [path] if os.path.isfile(path) else []


def compile_configs(config_path=CONFIG_PATH):
    pool = {}

    toml_files = toml_sources(config_path)
    if not toml_files:
        print(
            f"Warning: No TOML config found at {config_path}", file=sys.stderr)
        return pool

    seen = {}

    for filepath in toml_files:
        filename = os.path.basename(filepath)
        try:
            with open(filepath, "rb") as f:
                data = tomllib.load(f)
        except Exception as e:
            print(f"Error parsing {filepath}: {e}", file=sys.stderr)
            sys.exit(1)

        # File-level defaults are keys defined before tables
        file_defaults = {k: v for k,
                         v in data.items() if not isinstance(v, dict)}
        file_pv = normalize_channel(
            file_defaults.get("patches-version"), f"{filename}: patches-version") or "stable"

        for app_key, app_table in data.items():
            if not isinstance(app_table, dict):
                continue

            merged = dict(file_defaults)
            merged.update(app_table)

            enabled = merged.get("enabled", True)
            if isinstance(enabled, str):
                enabled = enabled.lower() == "true"
            if not enabled:
                continue

            channel = normalize_channel(
                app_table.get("patches-version"), f"[{app_key}] patches-version") or file_pv

            if app_key in pool:
                print(
                    f"Error: Duplicate app key '[{app_key}]' in {filename} (already defined in {seen[app_key]})", file=sys.stderr)
                sys.exit(1)
            seen[app_key] = filename
            entry = dict(merged)
            if channel == "stable":
                # Omit the redundant key: it matches the pool default
                entry.pop("patches-version", None)
            else:
                # A pin is carried exactly as written; the build resolves the "stable" keyword from
                # state/patch_sources.json itself (see _patch_source_state_tag in utils.sh).
                entry["patches-version"] = channel
            pool[app_key] = entry

    return pool


def main():
    config_path = sys.argv[1] if len(sys.argv) > 1 else CONFIG_PATH
    pool = compile_configs(config_path)

    out = {"patches-version": "stable"}
    out.update(pool)

    with open("config.json", "w", encoding="utf-8") as f:
        json.dump(out, f, indent=2)

    print("Base patch configuration compiled successfully.")
    print(f"Apps: {len(pool)}")


if __name__ == "__main__":
    main()
