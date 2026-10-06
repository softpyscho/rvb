#!/usr/bin/env bash
# Regression test for merge_archive_manifest.sh and cleanup_manifests.sh: the build's manifests are
# kept on main under state/ (they used to live on a `website` branch). Offline: a local bare origin
# and a stub `gh` that answers from files.
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
quiet() { grep -v -E "acknowledg|negotiation" || true; }

mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'SH'
#!/usr/bin/env bash
# gh api ... releases/tags/<tag> -q ...  -> one asset name per line from $GH_ASSETS (<tag>.txt)
# gh release list ...                    -> tags from $GH_ASSETS/releases.txt
case "$1" in
  api) tag="${*: -3:1}"; for a in "$@"; do case "$a" in repos/*/releases/tags/*) tag="${a##*/}";; esac; done
       cat "$GH_ASSETS/$tag.txt" ;;
  release) cat "$GH_ASSETS/releases.txt" ;;
esac
SH
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH" GH_ASSETS="$WORK/assets"
mkdir -p "$GH_ASSETS"

git init -q --bare "$WORK/origin.git"
git init -q -b main "$WORK/work"
cd "$WORK/work" || exit 1
git config user.email t@t; git config user.name t
git remote add origin "$WORK/origin.git"
echo readme > README.md
git add -A; git commit -qm init; git push -q origin main 2>&1 | quiet
tip() { git -C "$WORK/origin.git" rev-parse main; }
show() { git -C "$WORK/origin.git" show "main:$1"; }
has() { git -C "$WORK/origin.git" cat-file -e "main:$1" 2>/dev/null; }

build() { # <build tag> <archive tag> <file> <version>
  mkdir -p temp/manifest
  printf '{"schema":1,"kind":"build","files":{"%s":{"version":"%s"}}}' "$3" "$4" > temp/manifest/build.json
  GITHUB_REPOSITORY=o/rvb BUILD_TAG="$1" ARCHIVE_TAG="$2" bash "$REPO_ROOT/.github/scripts/merge_archive_manifest.sh" 2>&1 | quiet
}

# 1. the first build: no archive manifest exists yet -> a fresh one, per-build copy next to it
printf 'reddit-v1-arm64.apk\n' > "$GH_ASSETS/stable.txt"
out=$(build 260010 stable reddit-v1-arm64.apk 1)
has state/manifests/260010.json || fail "per-build manifest missing: $out"
[ "$(show state/archive/stable.json | jq -c '.files|keys')" = '["reddit-v1-arm64.apk"]' ] || fail "archive: $(show state/archive/stable.json)"
[ "$(git -C "$WORK/origin.git" log -1 --format=%s main)" = "chore: update stable manifest for build 260010 [skip ci]" ] || fail "message"
[ "$(git -C "$WORK/origin.git" diff --name-only main~1 main | sort | tr '\n' ' ')" = "state/archive/stable.json state/manifests/260010.json " ] || fail "only the two manifests may be committed"

# 2. a later build is merged into the archive read from main (not from the stale worktree)
printf 'reddit-v1-arm64.apk\nreddit-v2-arm64.apk\n' > "$GH_ASSETS/stable.txt"
build 260011 stable reddit-v2-arm64.apk 2 > /dev/null
[ "$(show state/archive/stable.json | jq -c '.files|keys')" = '["reddit-v1-arm64.apk","reddit-v2-arm64.apk"]' ] || fail "archive should accumulate: $(show state/archive/stable.json)"

# 3. an asset gone from the release drops out of the archive (the live filter)
printf 'reddit-v2-arm64.apk\nx-v1.apk\n' > "$GH_ASSETS/stable.txt"
build 260012 stable x-v1.apk 1 > /dev/null
[ "$(show state/archive/stable.json | jq -c '.files|keys')" = '["reddit-v2-arm64.apk","x-v1.apk"]' ] || fail "dead asset should be dropped: $(show state/archive/stable.json)"

# 4. channels are kept apart
printf 'b-v1.apk\n' > "$GH_ASSETS/beta.txt"
build 260013 beta b-v1.apk 1 > /dev/null
[ "$(show state/archive/beta.json | jq -c '.files|keys')" = '["b-v1.apk"]' ] || fail "beta archive"
[ "$(show state/archive/stable.json | jq '.files|length')" = 2 ] || fail "stable must not change"

# 5. unreachable origin: fails loudly instead of restarting the cumulative manifest
git remote set-url origin "$WORK/missing.git"
t=$(tip)
mkdir -p temp/manifest; echo '{"files":{}}' > temp/manifest/build.json
GITHUB_REPOSITORY=o/rvb BUILD_TAG=260014 ARCHIVE_TAG=stable bash "$REPO_ROOT/.github/scripts/merge_archive_manifest.sh" > "$WORK/err.log" 2>&1; rc=$?
[ "$rc" != 0 ] || fail "an unreachable origin must fail the merge"
[ "$(tip)" = "$t" ] || fail "nothing may be written on failure"
git remote set-url origin "$WORK/origin.git"

# cleanup: manifests of deleted releases go, live ones and the archive stay
printf '260013\n260012\n' > "$GH_ASSETS/releases.txt"   # 260010, 260011 were deleted
before=$(tip)
out=$(bash "$REPO_ROOT/.github/scripts/cleanup_manifests.sh" 2>&1 | quiet)
has state/manifests/260010.json && fail "orphan 260010 should be pruned: $out"
has state/manifests/260011.json && fail "orphan 260011 should be pruned"
has state/manifests/260012.json || fail "live manifest 260012 must stay"
has state/manifests/260013.json || fail "live manifest 260013 must stay"
has state/archive/stable.json && has state/archive/beta.json || fail "archive manifests must never be pruned"
[ "$(git -C "$WORK/origin.git" log -1 --format=%s main)" = "chore: prune orphaned manifests [skip ci]" ] || fail "cleanup message"

# control: nothing orphaned -> no commit
t=$(tip)
bash "$REPO_ROOT/.github/scripts/cleanup_manifests.sh" > /dev/null 2>&1
[ "$(tip)" = "$t" ] || fail "no orphans must mean no commit"

# control: a failed `gh release list` must not prune everything
: > "$GH_ASSETS/releases.txt"
bash "$REPO_ROOT/.github/scripts/cleanup_manifests.sh" > /dev/null 2>&1
[ "$(tip)" = "$t" ] || fail "an empty release list must not prune"
has state/manifests/260012.json || fail "manifests wiped on an empty release list"
echo "MANIFEST SCRIPT TESTS: PASS"
