#!/usr/bin/env bash
# Regression test for commit_to_main.sh, the one writer CI uses for everything it stores on main.
# Offline: a local bare origin and a working clone that is deliberately dirty and behind.
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK=$(mktemp -d)
trap '[ -n "${KEEP:-}" ] || rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
quiet() { grep -v -E "acknowledg|negotiation" || true; }
SCRIPT="$REPO_ROOT/.github/scripts/commit_to_main.sh"

git init -q --bare "$WORK/origin.git"
git init -q -b main "$WORK/work"
cd "$WORK/work" || exit 1
git config user.email t@t; git config user.name t
git remote add origin "$WORK/origin.git"
mkdir -p configs/patches state/manifests
echo 'a = 1' > configs/patches/app.toml
echo '{"v":1}' > configs/stable_build.json
echo '{"old":true}' > state/manifests/260001.json
echo '{"keep":true}' > state/manifests/260002.json
echo readme > README.md
git add -A; git commit -qm init; git push -q origin main 2>&1 | quiet
tip() { git -C "$WORK/origin.git" rev-parse main; }
files_changed() { git -C "$WORK/origin.git" diff --name-only "$1" "$2" | sort | tr '\n' ' '; }

# 1. add + update + remove in one commit; a hand-edited TOML and a scratch file stay behind
base=$(tip)
echo '{"v":2}' > configs/stable_build.json            # update
echo '{"new":true}' > state/app_versions.json         # add
rm state/manifests/260001.json                        # remove
echo 'a = 2' > configs/patches/app.toml               # NOT named: must not be committed
echo scratch > temp.txt
out=$(bash "$SCRIPT" "chore: test" configs/stable_build.json state/app_versions.json state/manifests/260001.json state/manifests/never-existed.json 2>&1 | quiet)
new=$(tip)
[ "$base" != "$new" ] || fail "expected a commit: $out"
[ "$(files_changed "$base" "$new")" = "configs/stable_build.json state/app_versions.json state/manifests/260001.json " ] || fail "wrong files changed: $(files_changed "$base" "$new")"
[ "$(git -C "$WORK/origin.git" show main:configs/stable_build.json)" = '{"v":2}' ] || fail "update not applied"
git -C "$WORK/origin.git" cat-file -e main:state/manifests/260001.json 2>/dev/null && fail "removal not applied"
[ "$(git -C "$WORK/origin.git" show main:configs/patches/app.toml)" = 'a = 1' ] || fail "an unnamed (dirty) TOML must not be committed"
git -C "$WORK/origin.git" cat-file -e main:temp.txt 2>/dev/null && fail "scratch must not be committed"
[ "$(git -C "$WORK/origin.git" log -1 --format=%s main)" = "chore: test [skip ci]" ] || fail "message: $(git -C "$WORK/origin.git" log -1 --format=%s main)"
[ "$(git -C "$WORK/origin.git" log -1 --format=%an main)" = "github-actions[bot]" ] || fail "author should be the bot"
[ "$(git -C "$WORK/origin.git" rev-parse main~1)" = "$base" ] || fail "must build on the previous tip"
# the local branch, index and worktree are untouched
[ "$(git rev-parse HEAD)" = "$base" ] || fail "local HEAD moved"
[ "$(cat configs/patches/app.toml)" = 'a = 2' ] || fail "worktree edit lost"
git diff --cached --quiet || fail "index touched"

# 2. nothing differs -> no commit (negative control for 1: the commit above was real)
before=$(tip)
out=$(bash "$SCRIPT" "chore: again" configs/stable_build.json state/app_versions.json state/manifests/260001.json 2>&1 | quiet)
[ "$(tip)" = "$before" ] || fail "an unchanged state must not create a commit: $out; $(git -C "$WORK/origin.git" log --oneline -3 main)"
grep -q "Nothing to commit" <<<"$out" || fail "should say so: $out"

# 3. a human push lands first: its change is kept, ours is applied on top
git clone -q -b main "$WORK/origin.git" "$WORK/human" 2>&1 | quiet
( cd "$WORK/human" && git config user.email h@h && git config user.name h && echo 'edited by a human' > README.md && git commit -qam human && git push -q origin main 2>&1 | quiet )
echo '{"v":3}' > configs/stable_build.json
bash "$SCRIPT" "chore: after human" configs/stable_build.json > /dev/null 2>&1 || fail "should succeed on a moved main"
[ "$(git -C "$WORK/origin.git" show main:README.md)" = 'edited by a human' ] || fail "the human's change must survive"
[ "$(git -C "$WORK/origin.git" show main:configs/stable_build.json)" = '{"v":3}' ] || fail "our file should be applied"

# 4. loud failures: no message/paths, unreachable origin
bash "$SCRIPT" "only a message" > /dev/null 2>&1; [ "$?" = 2 ] || fail "missing paths must be a usage error"
git remote set-url origin "$WORK/missing.git"
t=$(tip)
echo '{"v":4}' > configs/stable_build.json
bash "$SCRIPT" "chore: unreachable" configs/stable_build.json > "$WORK/err.log" 2>&1; rc=$?
[ "$rc" != 0 ] || fail "an unreachable origin must fail, not pass as saved"
grep -q "FATAL" "$WORK/err.log" || fail "failure should be explained: $(cat "$WORK/err.log")"
[ "$(tip)" = "$t" ] || fail "nothing may be written on failure"
echo "COMMIT TO MAIN TESTS: PASS"
