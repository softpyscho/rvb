#!/bin/bash
set -euo pipefail

# Merge this build's manifest into the repository (committed to main):
#   state/manifests/<tag>.json     (per-build copy, appended every run)
#   state/archive/<channel>.json   (cumulative: union + live-filter against the archive release;
#                                   the previous state is read from origin/main, so there is no
#                                   download that can silently fail into an empty base)
#
# Run AFTER the archive file upload so the live-asset filter sees new files.
# Env: ARCHIVE_TAG (stable|beta), BUILD_TAG (release tag of this build),
#      GITHUB_REPOSITORY; git credentials from the workflow's checkout token.
# Reads: temp/manifest/build.json (from build_make_manifest.py)
#
# Concurrency: build.yml holds a single "build" concurrency group, so two builders never merge
# against the files at the same time; commit_to_main.sh is the only writer.

ARCHIVE_TAG="${ARCHIVE_TAG:?ARCHIVE_TAG not set}"
BUILD_TAG="${BUILD_TAG:?BUILD_TAG not set}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY not set}"
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRANCH="${COMMIT_BRANCH:-main}"
NEW_MANIFEST="temp/manifest/build.json"
OLD_MANIFEST="temp/manifest/archive-old.json"
LIVE_LIST="temp/manifest/archive-live-assets.txt"
OUT_ARCHIVE="state/archive/$ARCHIVE_TAG.json"
OUT_BUILD="state/manifests/$BUILD_TAG.json"

if [ ! -f "$NEW_MANIFEST" ]; then
  echo "No $NEW_MANIFEST present — skipping archive manifest merge."
  exit 0
fi

# 1. Previous state, from the tip of main. A fetch failure is fatal by design: there is no
#    "start fresh from empty" path, the job must fail loudly rather than restart the
#    cumulative manifest. Only a manifest that was never written starts one.
git fetch -q origin "$BRANCH"
mkdir -p state/manifests state/archive temp/manifest
cp "$NEW_MANIFEST" "$OUT_BUILD"

if git cat-file -e "origin/$BRANCH:$OUT_ARCHIVE" 2>/dev/null; then
  git show "origin/$BRANCH:$OUT_ARCHIVE" > "$OLD_MANIFEST"
else
  echo "No $OUT_ARCHIVE on $BRANCH yet — starting a fresh cumulative manifest."
  echo 'null' > "$OLD_MANIFEST"
fi

# 2. APK/ZIP assets actually present in the archive release right now
#    (releases remain the source of truth for file existence).
gh api --paginate "repos/$REPO/releases/tags/$ARCHIVE_TAG" -q '.assets[].name' \
  | grep -E '\.(apk|zip)$' > "$LIVE_LIST" || true
jq -Rn '[inputs]' "$LIVE_LIST" > temp/manifest/archive-live.json

# 3. Union (new entries override same-filename old entries), keep only keys
#    whose file exists in the release, stamp archive meta.
jq -s --slurpfile live temp/manifest/archive-live.json \
  --arg tag "$ARCHIVE_TAG" \
  --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    ((.[0].files // {}) + (.[1].files // {})) as $merged
    | {schema: 1,
       kind: "archive",
       meta: {build: $tag, channel: $tag, publishedAt: $now},
       files: ($merged | with_entries(select(.key as $k | $live[0] | index($k))))}
  ' "$OLD_MANIFEST" "$NEW_MANIFEST" > "$OUT_ARCHIVE"

ENTRIES=$(jq '.files | length' "$OUT_ARCHIVE")
# Sanity gate: every old/new entry whose file still lives on the release must
# have survived the merge. A shortfall means something upstream went wrong —
# refuse to publish instead of silently shrinking the archive manifest.
EXPECTED=$(jq -s --slurpfile live temp/manifest/archive-live.json '
  (((.[0].files // {}) | keys) + ((.[1].files // {}) | keys) | unique) as $keys
  | [$keys[] | select(. as $k | $live[0] | index($k))] | length
' "$OLD_MANIFEST" "$NEW_MANIFEST")
if [ "$ENTRIES" -lt "$EXPECTED" ]; then
  echo "::error::Merge kept $ENTRIES entries but $EXPECTED archived files still have manifest entries — refusing to push" >&2
  exit 1
fi
LIVE_COUNT=$(grep -c . "$LIVE_LIST" || true)
echo "Merged archive manifest for $ARCHIVE_TAG: $ENTRIES entries ($LIVE_COUNT live assets, $EXPECTED expected minimum)."

# 4. Commit just these two files onto main.
bash "$SCRIPTS/commit_to_main.sh" "chore: update $ARCHIVE_TAG manifest for build $BUILD_TAG" "$OUT_BUILD" "$OUT_ARCHIVE"
