#!/bin/bash
set -euo pipefail

# Commit named files from the working tree onto origin/main - the single writer for everything CI
# stores in the repository (watcher state, generated pool configs, build manifests).
#
#   bash .github/scripts/commit_to_main.sh "<commit message>" <path>...
#
# Per path: present in the working tree -> added or updated on main; absent from the working tree
# but present on main -> removed from main; absent from both -> ignored. Paths are explicit files
# (a glob that matches nothing arrives as a literal and is ignored), so nothing else on the
# runner - TOMLs, scratch, a dirty tree - can ride along.
#
# Plumbing only: a temporary index built on origin/main's tip, commit-tree, a direct ref push. The
# checked-out branch, the real index and the worktree are never touched, and a human push to main
# in the meantime is built upon, not overwritten (on a race only the named files are re-applied
# over the new tip: the worktree's copy of those files wins).
#
# The commit carries `[skip ci]`; a push made with GITHUB_TOKEN starts no workflow anyway.
# Fails loudly when main cannot be fetched or the push keeps losing: no "nothing was saved" path.
#
# Env: COMMIT_BRANCH (default main) - only the tests point it elsewhere.

BRANCH="${COMMIT_BRANCH:-main}"
if [ "$#" -lt 2 ]; then
	echo "usage: commit_to_main.sh \"<commit message>\" <path>..." >&2
	exit 2
fi
MSG="$1"
shift
PATHS=("$@")

export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-github-actions[bot]}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

# build_commit <base> - echoes the new commit; returns 1 when nothing differs.
build_commit() {
	local base=$1 idx f blob old changed="" tree
	idx=$(mktemp)
	rm -f "$idx"
	GIT_INDEX_FILE=$idx git read-tree "$base"
	for f in "${PATHS[@]}"; do
		old=$(git rev-parse -q --verify "$base:$f" 2> /dev/null || true)
		if [ -f "$f" ]; then
			blob=$(git hash-object -w "$f")
			if [ "$blob" = "$old" ]; then
				continue
			fi
			GIT_INDEX_FILE=$idx git update-index --add --cacheinfo "100644,$blob,$f"
			changed=1
		elif [ -n "$old" ]; then
			GIT_INDEX_FILE=$idx git update-index --force-remove -- "$f"
			changed=1
		fi
	done
	if [ -z "$changed" ]; then
		rm -f "$idx"
		return 1
	fi
	tree=$(GIT_INDEX_FILE=$idx git write-tree)
	rm -f "$idx"
	git commit-tree "$tree" -p "$base" -m "$MSG [skip ci]"
}

if ! git fetch -q origin "$BRANCH"; then
	echo "FATAL: could not fetch '$BRANCH' from origin." >&2
	exit 1
fi

for attempt in 1 2 3; do
	base=$(git rev-parse FETCH_HEAD)
	if ! new=$(build_commit "$base"); then
		echo "Nothing to commit: $BRANCH already carries these files."
		exit 0
	fi
	if git push -q origin "$new:refs/heads/$BRANCH" 2> /dev/null; then
		echo "Committed to $BRANCH ($new): $MSG"
		exit 0
	fi
	echo "Push attempt $attempt failed ($BRANCH moved?); re-applying on the new tip..."
	sleep 3
	git fetch -q origin "$BRANCH"
done
echo "FATAL: could not push to $BRANCH after 3 attempts." >&2
exit 1
