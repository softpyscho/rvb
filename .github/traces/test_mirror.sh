#!/usr/bin/env bash
# Functional regression test for mirror_rv (scripts/utils.sh) and the mirror/keep-filename
# parsing in scripts/build.sh. The trace goldens never reach build_rv's download loop, so a
# mirrored app (stock APK re-hosted unmodified) is covered here, offline: the download
# helpers are replaced by fakes that write small zip files, and aapt2 by a stub that reports
# the package the fake "downloaded" - so every gate (package identity, ABI honesty, version
# pick, naming) is driven by bytes and names, not by the network.
#
# Every absence assertion has a negative control next to it: "rejected" only counts because
# the same harness shows the accepting case producing the file.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
REPO_ROOT=$(pwd)
# shellcheck disable=SC1091
source scripts/utils.sh >/dev/null 2>&1

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

TEMP_DIR="$WORK/temp"
BUILD_DIR="$WORK/build"
BUILD_JSON_FILE="$WORK/build.json"
mkdir -p "$TEMP_DIR" "$BUILD_DIR"
cd "$WORK" # sig.txt is read relative to the cwd by check_sig
: > sig.txt

# aapt2 stub: `dump packagename <apk>` -> $FAKE_PKG, `dump badging` -> a package line.
cat > "$WORK/aapt2" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
	"dump packagename") printf '%s\n' "${FAKE_PKG:-}" ;;
	"dump badging") printf "package: name='%s' versionCode='1' versionName='1'\n" "${FAKE_PKG:-}" ;;
esac
STUB
chmod +x "$WORK/aapt2"
AAPT2="$WORK/aapt2"

# The real dl_github, kept under another name: the fake below replaces it for the mirror_rv
# cases, but what it publishes through __DL_ASSET_NAME__ has to be tested on the real one.
eval "$(declare -f dl_github | sed '1s/^dl_github/real_dl_github/')"

# --- fakes for one store-like source (uptodown) and for github -------------------------
FAKE_VERSIONS=$'1.9.0\n1.10.0\n1.2.3'
FAKE_ABIS="arm64-v8a"   # ABIs the next fake download carries; "" = arch-agnostic
FAKE_ASSET="Duck.Detector-nightly-all.apk"
export FAKE_PKG=""  # read by the aapt2 stub, so it has to be exported
DL_CALLS=0
mkapk() { # $1=output $2...=ABIs
	local out=$1 d; shift
	d=$(mktemp -d "$WORK/apk.XXXXXX")
	echo manifest > "$d/AndroidManifest.xml"
	# build-arch tokens in, real ABI directory names out (arm-v7a lives in lib/armeabi-v7a)
	for a in "$@"; do a=${a/arm-v7a/armeabi-v7a}; mkdir -p "$d/lib/$a"; echo so > "$d/lib/$a/libx.so"; done
	rm -f "$out"
	( cd "$d" && zip -qr "$out" . )
	rm -rf "$d"
}
get_uptodown_resp() { :; }
get_uptodown_vers() { printf '%s\n' "$FAKE_VERSIONS"; }
get_uptodown_pkg_name() { echo "$FAKE_PKG"; }
dl_uptodown() { DL_CALLS=$((DL_CALLS + 1)); mkapk "$3" $FAKE_ABIS; }
get_github_resp() { :; }
get_github_vers() { echo nightly; }
get_github_pkg_name() { echo "$FAKE_PKG"; }
dl_github() { DL_CALLS=$((DL_CALLS + 1)); __DL_ASSET_NAME__="$FAKE_ASSET"; mkapk "$3" $FAKE_ABIS; }

# 0. the real dl_github reports which asset it picked (curl is stubbed: it just writes a file)
mkdir -p "$WORK/stubbin"
printf '#!/usr/bin/env bash\nwhile [ $# -gt 0 ]; do [ "$1" = -o ] && out=$2; shift; done\necho x > "$out"\n' > "$WORK/stubbin/curl"
chmod +x "$WORK/stubbin/curl"
(
	PATH="$WORK/stubbin:$PATH"
	declare -A args=([github_regex]="")
	__GITHUB_RESP__=$'Duck.Detector-nightly-arm64-v8a.apk\nDuck.Detector-nightly-all.apk'
	__GITHUB_TAG__=nightly
	__DL_ASSET_NAME__=""
	real_dl_github "https://github.com/o/r/releases/tag/nightly" nightly "$WORK/real-out.apk" all >/dev/null 2>&1 || exit 2
	[ "$__DL_ASSET_NAME__" = "Duck.Detector-nightly-all.apk" ] || exit 3
	# control: another arch request picks the other asset, so the value is not a constant
	rm -f "$WORK/real-out2.apk"; __DL_ASSET_NAME__=""
	real_dl_github "https://github.com/o/r/releases/tag/nightly" nightly "$WORK/real-out2.apk" arm64-v8a >/dev/null 2>&1 || exit 4
	[ "$__DL_ASSET_NAME__" = "Duck.Detector-nightly-arm64-v8a.apk" ] || exit 5
) ; rc=$?
[ "$rc" = 0 ] || fail "real dl_github must publish the chosen asset name (subshell rc=$rc)"

reset() { rm -rf "$BUILD_DIR"/* "$TEMP_DIR"/apks_dl "$TEMP_DIR"/build_info "$BUILD_JSON_FILE"; echo '{}' > "$BUILD_JSON_FILE"; DL_CALLS=0; }
# args_for <overrides...> -> declare -p of an app_args array, the way build.sh hands it over
run_mirror() { # $@ = key=value overrides on top of a baseline app
	declare -A app_args=([table]="Bitget (arm64-v8a)" [app_name]="Bitget" [pkg_name]="com.bitget.exchange"
		[version]="latest" [arch]="arm64-v8a" [brand]="Mirror" [mirror]=true [keep_filename]=false
		[dpi]="" [uptodown_dlurl]="https://x.example/android" [github_dlurl]="" [cache_repo_dlurl]="" [archive_dlurl]=""
		[direct_dlurl]="" [apkmirror_dlurl]="" [apkpure_dlurl]="" [apkcombo_dlurl]="")
	local kv
	for kv in "$@"; do app_args["${kv%%=*}"]="${kv#*=}"; done
	build_rv "$(declare -p app_args)" >/dev/null 2>&1
	merge_build_info
}
built() { ls "$BUILD_DIR" 2>/dev/null | tr '\n' ' '; }

# 1. baseline: highest of the listed versions, grammar name, honest metadata ---------------
reset; FAKE_PKG=com.bitget.exchange FAKE_ABIS="arm64-v8a"
run_mirror
[ -f "$BUILD_DIR/bitget-v1.10.0-arm64-v8a.apk" ] || fail "baseline: expected bitget-v1.10.0-arm64-v8a.apk, got: $(built)"
e=$(jq -c '.Bitget' "$BUILD_JSON_FILE")
[ "$(jq -r '.version' <<<"$e")" = "1.10.0" ] || fail "baseline version: $e"
[ "$(jq -r '.brand' <<<"$e")" = "Mirror" ] || fail "baseline brand: $e"
[ "$(jq -r '.package_name' <<<"$e")" = "com.bitget.exchange" ] || fail "baseline package: $e"
[ "$(jq -r '.patches_source' <<<"$e")" = "" ] || fail "mirror must name no patch source: $e"
[ "$(jq -r '.applied_patches | length' <<<"$e")" = "0" ] || fail "mirror must list no applied patches: $e"
[ "$(jq -r '.file' <<<"$e")" = "" ] || fail "grammar-named file must not carry an explicit file: $e"
[ "$(jq -r '.exts[0]' <<<"$e")" = "arm64-v8a.apk" ] || fail "baseline ext: $e"

# 2. patched-build state must not leak into a mirror ---------------------------------------
reset; PATCH_OUTPUT='INFO: Applied: Leaked Patch'; PATCH_RESULT_FILE=/nonexistent
run_mirror
[ "$(jq -r '.Bitget.applied_patches | length' "$BUILD_JSON_FILE")" = "0" ] || fail "applied patches leaked from a previous build"

# 3. pinned version is used verbatim, no discovery -----------------------------------------
reset; run_mirror version=1.2.3
[ -f "$BUILD_DIR/bitget-v1.2.3-arm64-v8a.apk" ] || fail "pinned: got $(built)"

# 4. identity gate: wrong package from a store is rejected (control: right one built above)
reset; FAKE_PKG=com.somebody.else run_mirror
[ -z "$(built)" ] || fail "wrong package from a store must be rejected, got: $(built)"
[ "$DL_CALLS" -ge 1 ] || fail "negative control: the download was never attempted"
FAKE_PKG=com.bitget.exchange

# 5. ABI honesty: a wrong single ABI is rejected; arch-agnostic and matching ones pass ----
reset; FAKE_ABIS="arm-v7a" run_mirror
[ -z "$(built)" ] || fail "an arm-v7a-only APK must not be published as arm64-v8a: $(built)"
reset; FAKE_ABIS="" run_mirror
[ -n "$(built)" ] || fail "an arch-agnostic APK must satisfy arm64-v8a"
reset; FAKE_ABIS="arm64-v8a arm-v7a" run_mirror
[ -n "$(built)" ] || fail "a multi-ABI APK carrying arm64-v8a must satisfy it"

# 6. versions that need a patch bundle are refused, loudly and without a download ----------
for v in auto exp beta; do
	reset; run_mirror version=$v
	[ -z "$(built)" ] || fail "version '$v' must be refused for a mirror"
	[ "$DL_CALLS" = 0 ] || fail "version '$v' must be refused before any download"
done
reset; run_mirror arch=auto
[ -z "$(built)" ] || fail "arch auto must be refused for a mirror"

# 7. github + keep-filename: the asset keeps its name; a package mismatch is a warning -----
reset; FAKE_PKG=com.eltavine.duckdetector FAKE_ABIS=""
run_mirror table="Duck-Detector" app_name="Duck Detector" pkg_name="Duck.Detector" version=nightly arch=all \
	keep_filename=true uptodown_dlurl="" github_dlurl="https://github.com/o/r/releases/tag/nightly"
[ -f "$BUILD_DIR/Duck.Detector-nightly-all.apk" ] || fail "keep-filename: expected the asset's own name, got: $(built)"
e=$(jq -c '."Duck-Detector"' "$BUILD_JSON_FILE")
[ "$(jq -r '.file' <<<"$e")" = "Duck.Detector-nightly-all.apk" ] || fail "keep-filename must be recorded: $e"
[ "$(jq -r '.package_name' <<<"$e")" = "com.eltavine.duckdetector" ] || fail "the id found in the APK is what is published: $e"
# control: same app without keep-filename uses the grammar
reset; run_mirror table="Duck-Detector" app_name="Duck Detector" pkg_name="Duck.Detector" version=nightly arch=all \
	uptodown_dlurl="" github_dlurl="https://github.com/o/r/releases/tag/nightly"
[ -f "$BUILD_DIR/duck-detector-vnightly-all.apk" ] || fail "control: grammar name expected, got: $(built)"
[ "$(jq -r '."Duck-Detector".file' "$BUILD_JSON_FILE")" = "" ] || fail "control: no explicit file expected"
# a hostile asset name stays one safe path segment
reset; FAKE_ASSET='../evil name (1).apk'
run_mirror table="Duck-Detector" app_name="Duck Detector" pkg_name="Duck.Detector" version=nightly arch=all \
	keep_filename=true uptodown_dlurl="" github_dlurl="https://github.com/o/r/releases/tag/nightly"
[ "$(built)" = "evil-name-1-.apk " ] || fail "asset name must be sanitised to one segment, got: '$(built)'"
FAKE_ASSET="Duck.Detector-nightly-all.apk"

# 8. build.sh: configuration that contradicts a mirror is refused at parse time ------------
# A sandbox repo root: the engine writes under module/, temp/ and build/ relative to the cwd, so
# module/ is copied and bin/ rebuilt (symlinks to the vendored tools, a stub aapt2) rather than
# letting a test run leave files in the checkout.
SANDBOX="$WORK/sandbox"
mkdir -p "$SANDBOX/bin/aapt2"
cp -r "$REPO_ROOT/module" "$SANDBOX/module"
for d in scripts .github; do ln -s "$REPO_ROOT/$d" "$SANDBOX/$d"; done
for f in "$REPO_ROOT"/bin/*; do [ "$(basename "$f")" = aapt2 ] || ln -s "$f" "$SANDBOX/bin/$(basename "$f")"; done
for arch in x86_64 arm64 arm; do cp "$WORK/aapt2" "$SANDBOX/bin/aapt2/aapt2-$arch"; done
: > "$SANDBOX/sig.txt"
run_build() { ( cd "$SANDBOX" && printf '%s\n' "$1" > cfg.toml && bash scripts/build.sh cfg.toml >out.log 2>&1; echo $? ); }
rc=$(run_build $'[A]\nmirror = true\npatches-source = "x/y"\nuptodown-dlurl = "https://u/android"')
[ "$rc" != 0 ] && grep -q "patches-source' is set for 'A'" "$SANDBOX/out.log" || fail "patches-source on a mirror must abort (rc=$rc): $(tail -3 "$SANDBOX/out.log")"
rc=$(run_build $'[A]\nmirror = true\nincluded-patches = "\'P\'"\nuptodown-dlurl = "https://u/android"')
[ "$rc" != 0 ] && grep -q "included-patches' is set for 'A'" "$SANDBOX/out.log" || fail "included-patches on a mirror must abort"
rc=$(run_build $'[A]\nmirror = true\nbuild-mode = "module"\nuptodown-dlurl = "https://u/android"')
[ "$rc" != 0 ] && grep -q "build-mode 'module'" "$SANDBOX/out.log" || fail "module build-mode on a mirror must abort"
rc=$(run_build $'[A]\nkeep-filename = true\nuptodown-dlurl = "https://u/android"')
[ "$rc" != 0 ] && grep -q "keep-filename only applies to mirrored apps" "$SANDBOX/out.log" || fail "keep-filename on a patched app must abort"
rc=$(run_build $'[A]\nmirror = "maybe"\nuptodown-dlurl = "https://u/android"')
[ "$rc" != 0 ] && grep -q "'maybe' is not a valid option for 'mirror'" "$SANDBOX/out.log" || fail "a non-boolean mirror must abort"
# an explicit `false` on the two boolean patch keys is not a configuration (control for the aborts above)
rc=$(run_build $'[A]\nmirror = true\nexclusive-patches = false\ninclusive-patches = false\npkg-name = "com.a"\nversion = "1.0"\narch = "arm64-v8a"\nuptodown-dlurl = "https://127.0.0.1:9/android"')
if grep -q "is set for 'A'" "$SANDBOX/out.log"; then fail "a spelled-out false must not be refused: $(tail -3 "$SANDBOX/out.log")"; fi
rc=$(run_build $'[A]\nmirror = true\nexclusive-patches = true\nuptodown-dlurl = "https://u/android"')
[ "$rc" != 0 ] && grep -q "exclusive-patches' is set for 'A'" "$SANDBOX/out.log" || fail "exclusive-patches = true on a mirror must abort"
# control: a clean mirror config gets past parsing (it then fails to download - no network, and
# no source answers - which is a per-app failure, not a parse abort)
rc=$(run_build $'[A]\nmirror = true\npkg-name = "com.a"\nversion = "1.0"\narch = "arm64-v8a"\nuptodown-dlurl = "https://127.0.0.1:9/android"')
if grep -q "is set for 'A'\|is not a valid option" "$SANDBOX/out.log"; then fail "control: a clean mirror config must not be rejected at parse time: $(tail -3 "$SANDBOX/out.log")"; fi
grep -q "Could not get\|No valid download source\|Mirroring 'A" "$SANDBOX/out.log" || fail "control: clean mirror config should reach the download stage: $(tail -5 "$SANDBOX/out.log")"

# 9. end to end through build.sh: a mirrored app via the github source, stubbed curl --------
mkdir -p "$WORK/e2ebin"
mkapk "$WORK/served.apk"   # arch-agnostic APK the "release" serves
cat > "$WORK/e2ebin/curl" <<STUB
#!/usr/bin/env bash
url=""; out=""
while [ \$# -gt 0 ]; do
	case "\$1" in
		-o) out=\$2; shift 2 ;;
		-c|-b|--connect-timeout|--retry|--max-time|--speed-limit|--speed-time|-H|--header) shift 2 ;;
		http://*|https://*) url=\$1; shift ;;
		*) shift ;;
	esac
done
case "\$url" in
	https://api.github.com/repos/o/r/releases/tags/nightly)
		body='{"tag_name":"nightly","prerelease":false,"assets":[{"name":"Duck.Detector-nightly-all.apk"}]}'
		if [ -z "\$out" ] || [ "\$out" = - ]; then printf '%s\\n' "\$body"; else printf '%s\\n' "\$body" > "\$out"; fi ;;
	https://github.com/o/r/releases/download/nightly/Duck.Detector-nightly-all.apk)
		[ -n "\${E2E_NO_ASSET:-}" ] && exit 22
		cp "$WORK/served.apk" "\$out" ;;
	*) echo "curl-stub: unexpected \$url" >&2; exit 22 ;;
esac
STUB
chmod +x "$WORK/e2ebin/curl"
cat > "$SANDBOX/cfg.toml" <<'CFG'
mirror = true
brand = "Mirror"
arch = "all"
[Duck-Detector]
app-name = "Duck Detector"
pkg-name = "Duck.Detector"
keep-filename = true
version = "nightly"
github-dlurl = "https://github.com/o/r/releases/tag/nightly"
CFG
( cd "$SANDBOX" && PATH="$WORK/e2ebin:$PATH" FAKE_PKG=com.eltavine.duckdetector GITHUB_REPOSITORY=o/rvb NEXT_VER_CODE=260142 \
	bash scripts/build.sh cfg.toml > e2e.log 2>&1 ); rc=$?
[ "$rc" = 0 ] || fail "build.sh on a mirror-only config failed (rc=$rc): $(tail -5 "$SANDBOX/e2e.log")"
[ -f "$SANDBOX/build/Duck.Detector-nightly-all.apk" ] || fail "e2e: expected the kept file name, got: $(ls "$SANDBOX/build" 2>&1)"
[ "$(jq -r '."Duck-Detector".file' "$SANDBOX/build.json")" = "Duck.Detector-nightly-all.apk" ] || fail "e2e: build.json lacks the kept file"
[ "$(jq -r '."Duck-Detector".package_name' "$SANDBOX/build.json")" = "com.eltavine.duckdetector" ] || fail "e2e: published package id"
grep -q "Duck Detector" "$SANDBOX/build.md" && grep -q "Mirrored apps" "$SANDBOX/build.md" || fail "e2e: release notes should list the mirrored app"
grep -q "apps.obtainium.imranr.dev" "$SANDBOX/build.md" || fail "e2e: release notes should carry the Obtainium link"
# control: the same config when the asset cannot be fetched publishes nothing and fails the run
# ("All builds failed."), which is how an absent file is told apart from a skipped assertion
( cd "$SANDBOX" && : > build.md && rm -r build build.json temp && E2E_NO_ASSET=1 PATH="$WORK/e2ebin:$PATH" FAKE_PKG=com.eltavine.duckdetector \
	bash scripts/build.sh cfg.toml > e2e2.log 2>&1 ); rc=$?
[ "$rc" != 0 ] && grep -q "All builds failed" "$SANDBOX/e2e2.log" || fail "e2e control: an unfetchable asset must fail the run (rc=$rc): $(tail -3 "$SANDBOX/e2e2.log")"
[ -z "$(ls "$SANDBOX/build" 2>/dev/null)" ] || fail "e2e control: nothing may be published when the download failed"

echo "MIRROR TESTS: PASS"
