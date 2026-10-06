#!/usr/bin/env bash
# Regression test for build_plan_configs.sh: which configs one run of build.yml builds.
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
cd "$WORK" || exit 1
mkdir configs
echo '{"patches-version":"stable","Reddit":{"pkg-name":"a"},"Xodo":{"pkg-name":"b"}}' > configs/stable_build.json
echo '{"patches-version":"beta","Instagram":{"pkg-name":"c"}}' > configs/beta_build.json
echo 'x = 1' > configs/config.manual.toml
plan() { CONFIG_FILE="$1" GITHUB_OUTPUT="$WORK/out" bash "$REPO_ROOT/.github/scripts/build_plan_configs.sh" 2>"$WORK/err"; }

# all: both pools, stable first
: > "$WORK/out"; plan all || fail "all should succeed: $(cat "$WORK/err")"
[ "$(cat "$WORK/out")" = 'configs=["configs/stable_build.json","configs/beta_build.json"]' ] || fail "all: $(cat "$WORK/out")"

# an empty pool is left out (the scalar default beside it does not count as an app)
echo '{"patches-version":"beta"}' > configs/beta_build.json
: > "$WORK/out"; plan all || fail "empty beta"
[ "$(cat "$WORK/out")" = 'configs=["configs/stable_build.json"]' ] || fail "empty beta pool must be left out: $(cat "$WORK/out")"
grep -q "no apps" "$WORK/err" || fail "should say why it was left out"

# no app anywhere is an error, not an empty matrix
echo '{"patches-version":"stable"}' > configs/stable_build.json
: > "$WORK/out"; plan all && fail "no apps at all must fail"
[ ! -s "$WORK/out" ] || fail "nothing may be written on failure"

# a missing pool means the watcher never ran: loud
rm configs/beta_build.json
plan all && fail "a missing pool must fail"
grep -q "missing" "$WORK/err" || fail "should say it is missing: $(cat "$WORK/err")"

# an explicit file passes through untouched (the watcher's calls, Manual CI)
: > "$WORK/out"; plan configs/config.manual.toml || fail "explicit file"
[ "$(cat "$WORK/out")" = 'configs=["configs/config.manual.toml"]' ] || fail "explicit: $(cat "$WORK/out")"

# a typo is rejected, not turned into nothing
plan alll && fail "an unknown name must fail"
grep -q "does not exist" "$WORK/err" || fail "should explain: $(cat "$WORK/err")"
echo "BUILD PLAN TESTS: PASS"
