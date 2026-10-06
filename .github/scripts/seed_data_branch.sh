#!/bin/bash
set -euo pipefail

# One-time bootstrap of the branches a fresh fork needs before any workflow can run:
#   data     configs/ + state/   (fetch_data_branch.sh hard-fails without it)
#   website  manifests/ archive/ (merge_archive_branch.sh hard-fails without it)
# Content comes from .github/seed/<branch>/ — the seed is a starting point, after which
# the branch itself is canonical (edit TOMLs with push_data_configs.sh, never here).
#
# Refuses to touch a branch that already exists on the remote: both branches are
# single-writer stores and "re-seed over it" is exactly the data loss the fail-loud
# stance elsewhere in this repo exists to prevent.
#
# Plumbing only (temporary index + commit-tree + direct ref push), so the working
# tree is never touched, matching push_data_configs.sh / commit_data_branch.sh.
#
# Usage: bash .github/scripts/seed_data_branch.sh [data|website ...]   (default: both)
# Env:   SEED_REMOTE   remote to push to            (default: origin)
#        SEED_DRY_RUN  1 = print what would be pushed, push nothing

REMOTE="${SEED_REMOTE:-origin}"
SEED_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../seed" && pwd)"
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-$(git config user.name || echo seed)}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-$(git config user.email || echo seed@localhost)}"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

BRANCHES=("$@")
[ ${#BRANCHES[@]} -gt 0 ] || BRANCHES=(data website)

seed_branch() {
	local branch=$1 src="$SEED_DIR/$1" idx f rel blob tree commit rc
	[ -d "$src" ] || { echo "FATAL: no seed for '$branch' at $src" >&2; return 1; }

	# ls-remote distinguishes "absent" (rc 2 with --exit-code) from "unreachable"
	# (any other failure); only the first may proceed.
	rc=0
	git ls-remote --exit-code --heads "$REMOTE" "$branch" > /dev/null 2>&1 || rc=$?
	if [ "$rc" = 0 ]; then
		echo "FATAL: '$branch' already exists on $REMOTE — refusing to overwrite it." >&2
		return 1
	elif [ "$rc" != 2 ]; then
		echo "FATAL: could not query $REMOTE for '$branch' (git ls-remote exit $rc)." >&2
		return 1
	fi

	idx=$(mktemp)
	rm -f "$idx" # an empty path, not an empty file: read-tree --empty creates it
	GIT_INDEX_FILE=$idx git read-tree --empty
	while IFS= read -r f; do
		rel=${f#"$src"/}
		blob=$(git hash-object -w "$f")
		GIT_INDEX_FILE=$idx git update-index --add --cacheinfo "100644,$blob,$rel"
	done < <(find "$src" -type f | LC_ALL=C sort)
	tree=$(GIT_INDEX_FILE=$idx git write-tree)
	rm -f "$idx"
	commit=$(git commit-tree "$tree" -m "chore: seed $branch branch from .github/seed/$branch")

	if [ "${SEED_DRY_RUN:-0}" = 1 ]; then
		echo "[dry-run] would push $commit to $REMOTE/$branch:"
		git ls-tree -r --name-only "$commit" | sed 's/^/  /'
		return 0
	fi
	git push -q "$REMOTE" "$commit:refs/heads/$branch"
	echo "Seeded $branch ($commit):"
	git ls-tree -r --name-only "$commit" | sed 's/^/  /'
}

for b in "${BRANCHES[@]}"; do
	case "$b" in
		data | website) seed_branch "$b" ;;
		*) echo "FATAL: unknown branch '$b' (expected data or website)." >&2; exit 2 ;;
	esac
done
