#!/usr/bin/env bash
# Regression test for build_prepare_config.sh and compile_patch_configs.py: how the `config_file`
# input of build.yml becomes the config one build reads, and what the compiled pool holds.
# Offline (python3 + jq).
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
patches-version = "v1.2.3"
[Off]
pkg-name = "com.off"
enabled = false
[Instagram]
patches-source = "crimera/piko"
pkg-name = "com.instagram.android"
TOML
echo 'x = 1' > configs/config.manual.toml
echo '{"patches-version":"stable","Reddit":{"pkg-name":"com.reddit.frontpage"}}' > configs/build.json
prep() { CONFIG_FILE="$1" GITHUB_OUTPUT="$WORK/out" bash "$REPO_ROOT/.github/scripts/build_prepare_config.sh" 2>"$WORK/err" >/dev/null; }
apps() { jq -c '[to_entries[]|select(.value|type=="object")|.key]' "$1"; }

# all: every enabled app, one pool; a disabled app is out
: > "$WORK/out"; prep all || fail "all should succeed: $(cat "$WORK/err")"
[ "$(cat "$WORK/out")" = 'config=config.json' ] || fail "all: $(cat "$WORK/out")"
[ "$(apps config.json)" = '["Reddit","Xodo","Instagram"]' ] || fail "pool: $(apps config.json)"
[ "$(jq -r '."patches-version"' config.json)" = "stable" ] || fail "the pool's default channel is stable"
[ "$(jq -r '.Instagram."patches-source"' config.json)" = "crimera/piko" ] || fail "an app's own patches-source wins over the file default"
# "stable" is the default and is not written per app; a pin is carried verbatim
[ "$(jq -r '.Reddit | has("patches-version")' config.json)" = "false" ] || fail "the default channel must not be written per app"
[ "$(jq -r '.Xodo."patches-version"' config.json)" = "v1.2.3" ] || fail "a pinned release must be carried verbatim"
# negative control: the disabled app is in the TOML
grep -q '\[Off\]' configs/config.toml && [ "$(jq 'has("Off")' config.json)" = "false" ] || fail "control: a disabled app must be in the TOML and out of the pool"
[ ! -e config.beta.json ] && [ ! -e config.stable.json ] || fail "there is one pool file, config.json"

# manual: the scratch config; without its file, an error
: > "$WORK/out"; prep manual || fail "manual: $(cat "$WORK/err")"
[ "$(cat "$WORK/out")" = 'config=configs/config.manual.toml' ] || fail "manual: $(cat "$WORK/out")"
mv configs/config.manual.toml configs/config.manual.keep
prep manual && fail "manual without its file must fail"
grep -q "config.manual.toml does not exist" "$WORK/err" || fail "should say why: $(cat "$WORK/err")"
mv configs/config.manual.keep configs/config.manual.toml

# an explicit file passes through untouched (the watcher's configs/build.json)
: > "$WORK/out"; prep configs/build.json || fail "explicit file: $(cat "$WORK/err")"
[ "$(cat "$WORK/out")" = 'config=configs/build.json' ] || fail "explicit: $(cat "$WORK/out")"

# a typo is rejected, not turned into nothing; the old pool names are not choices any more
for bad in alll stable beta all:stable all:beta; do
	prep "$bad" && fail "'$bad' must be rejected"
	grep -q "does not exist (use all, manual, or a path" "$WORK/err" || fail "'$bad' should list the choices: $(cat "$WORK/err")"
done

# the retired channel words are errors, at file level and per app, never a quiet guess
for w in beta both; do
	sed "s/^pkg-name = \"com.instagram.android\"/&\npatches-version = \"$w\"/" configs/config.toml > bad.toml
	python3 "$REPO_ROOT/.github/scripts/compile_patch_configs.py" bad.toml 2>"$WORK/err" && fail "per-app $w must be rejected"
	grep -q "no beta channel any more" "$WORK/err" || fail "per-app $w should explain: $(cat "$WORK/err")"
	{ echo "patches-version = \"$w\""; cat configs/config.toml; } > bad.toml
	python3 "$REPO_ROOT/.github/scripts/compile_patch_configs.py" bad.toml 2>"$WORK/err" && fail "file-level $w must be rejected"
	grep -q "no beta channel any more" "$WORK/err" || fail "file-level $w should explain: $(cat "$WORK/err")"
done
# control: the same file without the word compiles
python3 "$REPO_ROOT/.github/scripts/compile_patch_configs.py" configs/config.toml >/dev/null 2>&1 || fail "control: the clean config must compile"

# the engine refuses them too (a hand-written config, e.g. Manual CI's, never passes through the compiler)
for w in beta both; do
	printf 'patches-source = "o/r"\n[App]\npkg-name = "a.b"\npatches-version = "%s"\n' "$w" > engine.toml
	out=$(cd "$REPO_ROOT" && timeout 120 bash scripts/build.sh "$WORK/engine.toml" 2>&1) && fail "build.sh must refuse patches-version = $w"
	grep -q "no beta channel any more" <<<"$out" || fail "build.sh should explain ($w): $(tail -2 <<<"$out")"
done

# github-newest: a boolean, and meaningless (so refused) without the regex that says which releases count
printf 'patches-source = "o/r"\n[App]\nmirror = true\npkg-name = "a.b"\ngithub-dlurl = "https://github.com/o/r"\ngithub-newest = true\n' > engine.toml
out=$(cd "$REPO_ROOT" && timeout 120 bash scripts/build.sh "$WORK/engine.toml" 2>&1) && fail "github-newest without github-release-regex must be refused"
grep -q "github-newest needs github-release-regex" <<<"$out" || fail "should explain: $(tail -2 <<<"$out")"
printf 'patches-source = "o/r"\n[App]\nmirror = true\npkg-name = "a.b"\ngithub-dlurl = "https://github.com/o/r"\ngithub-release-regex = "^n"\ngithub-newest = "yes"\n' > engine.toml
out=$(cd "$REPO_ROOT" && timeout 120 bash scripts/build.sh "$WORK/engine.toml" 2>&1) && fail "a non-boolean github-newest must be refused"

# no enabled app at all is an error, not an empty build
printf 'patches-source = "x/y"\n[Off]\npkg-name="c"\nenabled = false\n' > configs/config.toml
: > "$WORK/out"; prep all && fail "no apps at all must fail"
grep -q "No enabled app" "$WORK/err" || fail "should explain: $(cat "$WORK/err")"
[ ! -s "$WORK/out" ] || fail "nothing may be written on failure"
echo "BUILD CONFIG TESTS: PASS"
