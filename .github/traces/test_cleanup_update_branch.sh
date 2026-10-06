#!/usr/bin/env bash
# Regression test for cleanup_update_branch.sh when the repository has no `update` branch.
#
# The branch is created by the first build that produces a module zip, so an apk-only repository
# never has one. The script used to die on `git checkout -B update origin/update`, which failed
# the Cleanup job and skipped everything after it (website manifests, the catalogue dispatch).
# Offline: a local bare origin and a stub `gh`.
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

git init -q --bare "$WORK/origin.git"
git init -q -b main "$WORK/work"
cd "$WORK/work" || exit 1
git config user.email t@t; git config user.name t
git remote add origin "$WORK/origin.git"
echo x > f; git add f; git commit -qm init; git push -q origin main 2>/dev/null

mkdir -p "$WORK/stub"
cat > "$WORK/stub/gh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
	release) printf '260002\nstable\n' ;;
	api) printf 'other-file.apk\n' ;;   # the live asset list of the archive releases
esac
STUB
chmod +x "$WORK/stub/gh"
run() { PATH="$WORK/stub:$PATH" GITHUB_REPOSITORY=o/r bash "$REPO_ROOT/.github/scripts/cleanup_update_branch.sh" 2>&1; }

# 1. no update branch: nothing to prune, and that is success
out=$(run); rc=$?
[ "$rc" = 0 ] || fail "a repository without an update branch must not fail the cleanup (rc=$rc): $out"
grep -q "nothing to prune" <<<"$out" || fail "should say why it did nothing: $out"

# 2. control: with an update branch holding a dead pointer, the script does its job and prunes it
git checkout -q --orphan update
git rm -rfq . 2>/dev/null; mkdir -p stable
printf '{"zipUrl":"https://github.com/o/r/releases/download/stable/gone-module.zip","version":"1"}\n' > stable/gone.json
git add stable/gone.json; git commit -qm pointer; git push -q origin update 2>/dev/null
git checkout -q main
out=$(run); rc=$?
[ "$rc" = 0 ] || fail "control: cleanup with an update branch failed (rc=$rc): $out"
grep -q "Pruning dead pointer: stable/gone.json" <<<"$out" || fail "control: the dead pointer should be pruned: $out"
git -C "$WORK/origin.git" cat-file -e update:stable/gone.json 2>/dev/null && fail "control: the pruned pointer must be gone from origin/update"

# 3. an unreachable remote is still an error (only a definite 'absent' is a state)
git remote set-url origin "$WORK/does-not-exist.git"
out=$(run); rc=$?
[ "$rc" != 0 ] || fail "an unreachable origin must fail loudly: $out"
echo "CLEANUP UPDATE BRANCH TESTS: PASS"
