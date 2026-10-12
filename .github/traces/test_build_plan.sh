#!/usr/bin/env bash
# Regression test for build_plan_configs.sh and build_prepare_config.sh: which configs one run of
# build.yml builds, and how a matrix value becomes the config file. Offline (python3 + jq).
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
cd "$WORK" || exit 1
mkdir -p configs
cat > configs/config.toml <<'TOML'
patches-source = "MorpheApp/morphe-patches"
[Reddit]
pkg-name = "com.reddit.frontpage"
[Xodo]
pkg-name = "com.xodo.pdf.reader"
[Off]
pkg-name = "com.off"
enabled = false
[Instagram]
patches-source = "crimera/piko"
pkg-name = "com.instagram.android"
patches-version = "beta"
TOML
# the watcher's generated pool for beta says nobody is due (this is what broke "all" before)
echo '{"patches-version":"beta","Instagram":{"pkg-name":"com.instagram.android","enabled":false}}' > configs/beta_build.json
echo 'x = 1' > configs/config.manual.toml
plan() { CONFIG_FILE="$1" GITHUB_OUTPUT="$WORK/out" bash "$REPO_ROOT/.github/scripts/build_plan_configs.sh" 2>"$WORK/err" >/dev/null; }
prep() { CONFIG_FILE="$1" GITHUB_OUTPUT="$WORK/out" bash "$REPO_ROOT/.github/scripts/build_prepare_config.sh" 2>"$WORK/err" >/dev/null; }

# all: both pools compiled from the config, stable first, whatever the generated beta pool says
: > "$WORK/out"; plan all || fail "all should succeed: $(cat "$WORK/err")"
[ "$(cat "$WORK/out")" = 'configs=["all:stable","all:beta"]' ] || fail "all: $(cat "$WORK/out")"

# the compiled pools hold every enabled app, disabled ones out, routed by patches-version
: > "$WORK/out"; prep all:stable || fail "prepare stable: $(cat "$WORK/err")"
[ "$(cat "$WORK/out")" = 'config=config.stable.json' ] || fail "prepare stable out: $(cat "$WORK/out")"
[ "$(jq -c '[to_entries[]|select(.value|type=="object")|.key]|sort' config.stable.json)" = '["Reddit","Xodo"]' ] || fail "stable pool: $(jq -c . config.stable.json)"
: > "$WORK/out"; prep all:beta || fail "prepare beta: $(cat "$WORK/err")"
[ "$(cat "$WORK/out")" = 'config=config.beta.json' ] || fail "prepare beta out: $(cat "$WORK/out")"
[ "$(jq -c '[to_entries[]|select(.value|type=="object")|.key]' config.beta.json)" = '["Instagram"]' ] || fail "beta pool: $(jq -c . config.beta.json)"
[ "$(jq -r .Instagram.\"patches-source\" config.beta.json)" = "crimera/piko" ] || fail "an app's own patches-source wins over the file default"
# negative control: the watcher's generated pool would have built nothing
[ "$(jq '[to_entries[]|select((.value|type=="object") and (.value.enabled!=false))]|length' configs/beta_build.json)" = 0 ] || fail "control: the generated beta pool should have no enabled app"
# beta stays recognisable as a pre-release pool by name, as build_resolve_context.sh needs
case "config.beta.json" in *beta*) ;; *) fail "beta pool name";; esac

# stable and beta build just that pool, from the same config
: > "$WORK/out"; plan stable || fail "stable should succeed: $(cat "$WORK/err")"
[ "$(cat "$WORK/out")" = 'configs=["all:stable"]' ] || fail "stable: $(cat "$WORK/out")"
: > "$WORK/out"; plan beta || fail "beta should succeed: $(cat "$WORK/err")"
[ "$(cat "$WORK/out")" = 'configs=["all:beta"]' ] || fail "beta: $(cat "$WORK/out")"
# manual is the scratch config of Manual CI
: > "$WORK/out"; plan manual || fail "manual: $(cat "$WORK/err")"
[ "$(cat "$WORK/out")" = 'configs=["configs/config.manual.toml"]' ] || fail "manual: $(cat "$WORK/out")"
mv configs/config.manual.toml configs/config.manual.keep
plan manual && fail "manual without its file must fail"
grep -q "config.manual.toml does not exist" "$WORK/err" || fail "should say why: $(cat "$WORK/err")"
mv configs/config.manual.keep configs/config.manual.toml

# a pool with no app is left out of `all`, but an error when asked for by name
python3 - <<'PY'
import re
s = open("configs/config.toml").read()
open("configs/config.toml", "w").write(s[:s.index("[Instagram]")])
PY
: > "$WORK/out"; plan all || fail "no beta apps"
[ "$(cat "$WORK/out")" = 'configs=["all:stable"]' ] || fail "empty beta pool must be left out: $(cat "$WORK/out")"
grep -q "no apps" "$WORK/err" || fail "should say why it was left out"
prep all:beta && fail "preparing an empty pool must fail"
grep -q "no enabled app" "$WORK/err" || fail "should explain: $(cat "$WORK/err")"
: > "$WORK/out"; plan beta && fail "asking for an empty beta pool by name must fail"
grep -q 'patches-version = "beta"' "$WORK/err" || fail "should say how an app opts in: $(cat "$WORK/err")"
[ ! -s "$WORK/out" ] || fail "nothing may be written on failure"
: > "$WORK/out"; plan stable || fail "control: stable still builds without a beta app"

# no app anywhere is an error, not an empty matrix
printf 'patches-source = "x/y"\n[Off]\npkg-name="c"\nenabled = false\n' > configs/config.toml
: > "$WORK/out"; plan all && fail "no apps at all must fail"
[ ! -s "$WORK/out" ] || fail "nothing may be written on failure"

# an explicit file passes through untouched (the watcher's calls, Manual CI)
: > "$WORK/out"; plan configs/config.manual.toml || fail "explicit file"
[ "$(cat "$WORK/out")" = 'configs=["configs/config.manual.toml"]' ] || fail "explicit: $(cat "$WORK/out")"
: > "$WORK/out"; prep configs/beta_build.json || fail "prepare passthrough"
[ "$(cat "$WORK/out")" = 'config=configs/beta_build.json' ] || fail "passthrough: $(cat "$WORK/out")"

# a typo is rejected, not turned into nothing
plan alll && fail "an unknown name must fail"
grep -q "does not exist" "$WORK/err" || fail "should explain: $(cat "$WORK/err")"
grep -q "all, stable, beta, manual" "$WORK/err" || fail "should list the choices: $(cat "$WORK/err")"
prep all:dev && fail "an unknown pool must fail"
grep -q "unknown pool" "$WORK/err" || fail "should explain: $(cat "$WORK/err")"
echo "BUILD PLAN TESTS: PASS"
