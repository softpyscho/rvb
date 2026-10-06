#!/bin/bash
set -euo pipefail

# Prune orphaned per-build manifests: when the Cleanup workflow deletes a numbered release, its
# state/manifests/<tag>.json goes too (the same pattern cleanup_update_branch.sh applies to
# changelogs on the update branch). The cumulative state/archive/*.json files are never touched
# here — entries for pruned archive assets drop out at the next build's merge via the live-asset
# filter.
#
# The list of manifests is read from the tip of main (not the runner's checkout, which may be
# older); the removal is committed by commit_to_main.sh.
#
# Env: GH_TOKEN/GITHUB_TOKEN (gh and git push use the workflow's credentials).

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRANCH="${COMMIT_BRANCH:-main}"

echo "--- Fetching active releases ---"
ACTIVE_TAGS=$(gh release list -L 200 --json tagName -q '.[].tagName' 2>/dev/null || true)
if [ -z "$ACTIVE_TAGS" ]; then
  echo "No active releases found or gh CLI call failed. Skipping manifest cleanup."
  exit 0
fi

git fetch -q origin "$BRANCH"

orphans=()
while IFS= read -r f; do
  [ -n "$f" ] || continue
  tag=$(basename "$f" .json)
  if ! echo "$ACTIVE_TAGS" | grep -Fxq "$tag"; then
    echo "Pruning orphaned manifest: $f (release tag '$tag' no longer exists)"
    rm -f "$f"
    orphans+=("$f")
  fi
done < <(git ls-tree --name-only "origin/$BRANCH" state/manifests/ | grep -E '\.json$' || true)

echo "Pruned ${#orphans[@]} orphaned manifest(s)."
if [ "${#orphans[@]}" -eq 0 ]; then
  echo "No orphaned manifests to prune."
  exit 0
fi
bash "$SCRIPTS/commit_to_main.sh" "chore: prune orphaned manifests" "${orphans[@]}"
