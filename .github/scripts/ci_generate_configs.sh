#!/bin/bash
set -euo pipefail

# Convert utils.sh to Unix line endings if needed
dos2unix scripts/utils.sh 2>/dev/null || true
source scripts/utils.sh

[ -f active_apps.json ] || echo '[]' > active_apps.json
[ -f active_patch_apps.json ] || echo '[]' > active_patch_apps.json

# The changed-source diff is not re-derived here. changed_sources.json is written once by Sync
# Patch Sources (derive_source_changes.py), so this step, ci_check_app_patches.py and the
# TRIGGER_* flags can never disagree about which sources moved.
if [ ! -f changed_sources.json ]; then
  echo "::error::changed_sources.json missing - Sync Patch Sources must run first."
  exit 1
fi

jq -c '[ .[] | .repo ] | unique' changed_sources.json > active.json

# Compile the base config if missing
if [ ! -f config.json ]; then
  python3 .github/scripts/compile_patch_configs.py
fi

# configs/build.json is what the next build runs: config.json (every enabled app of
# configs/config.toml) with each app left enabled only when
#   - a source it uses published a new release AND the bundle changed for that app
#     (active_patch_apps.json, from ci_check_app_patches.py), or
#   - the app's own APK updated (active_apps.json, from the app-version compare).
#
# No concrete tag is stamped into the config. An app whose patches-version is the keyword
# "stable" keeps it, and the build resolves it against the same watcher snapshot
# (state/patch_sources.json, via _patch_source_state_tag in utils.sh). The job checks out
# configs/ and state/ from one main commit, so every app in a run resolves from the same snapshot.
#
# Quoted heredoc: no shell expansion, so jq's single-quoted strings stay ordinary single quotes.
read -r -d '' POOL_PROGRAM <<'JQ' || true
  { "patches-version": "stable" } as $force |
  ($force + . + $force) |
  with_entries(
    if .value | type == "object" then
      .key as $k |
      (((.value["patches-source"]) // "morpheapp/morphe-patches") | ascii_downcase | gsub("[\"'\n\r\t]"; " ") | split(" ") | map(select(. != ""))) as $srcs |
      # Membership only: the trigger rules decide who is enabled, and a written
      # version - the keyword or a concrete pin - is never rewritten here.
      if ((($srcs - $active[0]) != $srcs) and ($activePatchApps[0] | index($k))) or ($activeApps[0] | index($k)) then
        .
      else
        (.value.enabled = false)
      end
    else . end
  )
JQ

# Regenerated when a source moved, or when any structural event that can change membership
# happened (app updates, blocked sources).
if [ "${TRIGGER_BLOCKED:-0}" = "1" ] || [ "${TRIGGER_APP_UPDATE:-0}" = "1" ] || [ "${TRIGGER_PATCHES:-0}" = "1" ]; then
  jq --slurpfile active active.json \
     --slurpfile activeApps active_apps.json \
     --slurpfile activePatchApps active_patch_apps.json \
     "$POOL_PROGRAM" config.json > configs/build.json
fi
