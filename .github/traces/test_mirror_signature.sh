#!/usr/bin/env bash
# Regression test: a mirror never re-signs. Merging a split bundle into one APK signs the result
# with this repository's key, so the file is no longer the publisher's app (it cannot update over
# the store install). Offline: the downloads are fakes, so the real merge gate in
# _merge_splits_locked and the source fallback in mirror_rv are what is under test.
#
# The bug this pins: Bitget, Stremio, RedotPay 3.14.3 and WhatsApp Business were published signed
# with this repository's key because their sources served split bundles and the engine merged them.
#
# Every absence assertion has a negative control next to it.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
REPO_ROOT=$(pwd)
# shellcheck disable=SC1091
source scripts/utils.sh >/dev/null 2>&1
set +e

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
TEMP_DIR="$WORK/temp"; BUILD_DIR="$WORK/build"; BUILD_JSON_FILE="$WORK/build.json"
mkdir -p "$TEMP_DIR" "$BUILD_DIR"
cd "$WORK"; : > sig.txt
cat > "$WORK/aapt2" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
	"dump packagename") printf '%s\n' "${FAKE_PKG:-}" ;;
	"dump badging") printf "package: name='%s' versionCode='1' versionName='%s'\n" "${FAKE_PKG:-}" "${FAKE_VERNAME-}" ;;
esac
STUB
chmod +x "$WORK/aapt2"; AAPT2="$WORK/aapt2"
export FAKE_PKG=com.bitget.exchange FAKE_VERNAME=""

mkapk() { # $1=output : a plain APK carrying arm64
	local d; d=$(mktemp -d "$WORK/apk.XXXXXX")
	echo manifest > "$d/AndroidManifest.xml"; mkdir -p "$d/lib/arm64-v8a"; echo so > "$d/lib/arm64-v8a/libx.so"
	rm -f "$1"; ( cd "$d" && zip -qr "$1" . ); rm -rf "$d"
}
mkbundle() { # $1=output $2...=member names : a split bundle (zip of apks)
	local out=$1 d; shift
	d=$(mktemp -d "$WORK/bun.XXXXXX")
	for m in "$@"; do echo "$m" > "$d/$m"; done
	rm -f "$out"; ( cd "$d" && zip -qr "$out" . ); rm -rf "$d"
}
LOG="$WORK/log"
# get_apkeditor stands in for "the merge would run": reaching it is the observable. MERGE_OK=true
# lets the merge go on, with `java` standing in for APKEditor (merge) and apksigner (sign).
MERGE_OK=false
get_apkeditor() { echo "REACHED-MERGE" >> "$LOG"; $MERGE_OK; }
APKSIGNER="$WORK/apksigner.jar" RVB_KEYSTORE_P12=x RVB_KEYSTORE_PASS=x RVB_KEY_ALIAS=x
java() {
	local out="" last="" a prev=""
	for a in "$@"; do
		case "$prev" in -o | --out) out=$a ;; esac
		prev=$a; last=$a
	done
	case "$*" in
	*merge*) mkapk "$out" ;;
	*sign*) cp "$last" "$out" ;;
	esac
}
logged() { grep -qF -- "$1" "$LOG"; }

# ===== the gate in _merge_splits_locked ====================================================
# 1. a real multi-split bundle is refused in mirror mode: no output, the bundle is untouched
: > "$LOG"; mkbundle "$WORK/b1.apkm" base.apk split_config.arm64_v8a.apk
__MIRROR_RESIGN_REFUSED__=false
__MIRROR_NO_RESIGN__=true _merge_splits_locked "$WORK/b1.apkm" "$WORK/o1.apk" 2>> "$LOG"; rc=$?
[ "$rc" = 1 ] || fail "1: a split bundle must be refused for a mirror (rc=$rc)"
[ ! -e "$WORK/o1.apk" ] && [ -e "$WORK/b1.apkm" ] || fail "1: no output may be written and the bundle must stay"
[ "$__MIRROR_RESIGN_REFUSED__" = true ] || fail "1: the refusal must be recorded for the final message"
logged "REACHED-MERGE" && fail "1: the merge must not even start"
logged "re-sign it with this repository's key" || fail "1: the refusal must say why"

# 2. control: the same bundle without the flag goes on to merge, which is what re-signs
: > "$LOG"; __MIRROR_RESIGN_REFUSED__=false
_merge_splits_locked "$WORK/b1.apkm" "$WORK/o1.apk" 2>> "$LOG"
logged "REACHED-MERGE" || fail "2 control: without the mirror flag the bundle must reach the merge"
[ "$__MIRROR_RESIGN_REFUSED__" = false ] || fail "2 control: nothing was refused"

# 3. what keeps the publisher's signature is still fine in mirror mode
: > "$LOG"; mkapk "$WORK/std.apkm"
__MIRROR_NO_RESIGN__=true _merge_splits_locked "$WORK/std.apkm" "$WORK/o3.apk" 2>> "$LOG"; rc=$?
[ "$rc" = 0 ] && [ -e "$WORK/o3.apk" ] || fail "3: a 'bundle' that is really a standard APK must pass (rc=$rc)"
mkbundle "$WORK/only-base.apkm" base.apk
__MIRROR_NO_RESIGN__=true _merge_splits_locked "$WORK/only-base.apkm" "$WORK/o3b.apk" 2>> "$LOG"; rc=$?
[ "$rc" = 0 ] && [ -e "$WORK/o3b.apk" ] || fail "3b: a bundle holding only base.apk must pass (rc=$rc)"
logged "REACHED-MERGE" && fail "3: neither may reach the merge"

# ===== mirror_rv ============================================================================
APKM_KIND=bundle UPT_KIND=plain CALLS=""
get_apkmirror_resp() { :; }
get_apkmirror_vers() { echo "2.94.4"; }
get_apkmirror_pkg_name() { echo com.bitget.exchange; }
get_uptodown_resp() { :; }
get_uptodown_vers() { echo "2.94.4"; }
get_uptodown_pkg_name() { echo com.bitget.exchange; }
fake_dl() { # $1=source $2=kind $3=output : what the real helpers do after a download
	CALLS+="$1 "
	if [ "$2" = plain ]; then mkapk "$3"; return 0; fi
	mkbundle "${3%.apk}.apkm" base.apk split_config.arm64_v8a.apk
	_bundle_to_apk "${3%.apk}.apkm" "$3" || { rm -f "${3%.apk}.apkm"; return 1; }
}
dl_apkmirror() { fake_dl apkmirror "$APKM_KIND" "$3"; }
dl_uptodown() { fake_dl uptodown "$UPT_KIND" "$3"; }

reset() { rm -rf "$BUILD_DIR"/* "$TEMP_DIR"/apks_dl "$TEMP_DIR"/build_info "$BUILD_JSON_FILE"; echo '{}' > "$BUILD_JSON_FILE"; CALLS=""; : > "$LOG"; MERGE_OK=false; }
ALLOW=false
run() {
	declare -A app_args=([table]="Bitget (arm64-v8a)" [app_name]="Bitget" [pkg_name]="com.bitget.exchange"
		[version]="latest" [arch]="arm64-v8a" [brand]="Mirror" [mirror]=true [keep_filename]=false [allow_resign]="$ALLOW" [dpi]=""
		[uptodown_dlurl]="https://x.example/android" [apkmirror_dlurl]="https://www.apkmirror.com/apk/x/bitget/"
		[github_dlurl]="" [cache_repo_dlurl]="" [archive_dlurl]="" [direct_dlurl]="" [apkpure_dlurl]="" [apkcombo_dlurl]="")
	build_rv "$(declare -p app_args)" >/dev/null 2>> "$LOG"
	merge_build_info
}
built() { ls "$BUILD_DIR" 2>/dev/null | tr '\n' ' '; }

# 4. APKMirror serves a bundle: it is skipped and Uptodown's plain APK is published, same version
reset; APKM_KIND=bundle UPT_KIND=plain; run
[ -f "$BUILD_DIR/bitget-v2.94.4-arm64-v8a.apk" ] || fail "4: expected the plain APK from the next source, got: $(built)"
[ "$(jq -r '.Bitget.apk_source' "$BUILD_JSON_FILE")" = uptodown ] || fail "4: source '$(jq -r '.Bitget.apk_source' "$BUILD_JSON_FILE")'"
[ "$CALLS" = "apkmirror uptodown " ] || fail "4: both sources must be asked in order, got: $CALLS"
logged "REACHED-MERGE" && fail "4: nothing may be merged"

# 5. control: when the first source serves a plain APK it is used and the second is not asked
reset; APKM_KIND=plain UPT_KIND=plain; run
[ "$(jq -r '.Bitget.apk_source' "$BUILD_JSON_FILE")" = apkmirror ] && [ "$CALLS" = "apkmirror " ] || fail "5 control: source '$(jq -r '.Bitget.apk_source' "$BUILD_JSON_FILE")', calls: $CALLS"
[ "$(jq -r '.Bitget.resigned' "$BUILD_JSON_FILE")" = false ] || fail "5: a plain APK is recorded as not re-signed, got: $(jq -c '.Bitget.resigned' "$BUILD_JSON_FILE")"

# 6. every source serves a bundle: nothing is published, and the message says why
reset; APKM_KIND=bundle UPT_KIND=bundle; run
[ -z "$(built)" ] || fail "6: a mirror must not publish a re-signed file, got: $(built)"
logged "split bundles" || fail "6: the failure must name the reason, log: $(tail -3 "$LOG")"
[ "$CALLS" = "apkmirror uptodown " ] || fail "6: every source is still tried, got: $CALLS"
# control: the same run with one plain source publishes (case 4), so '$(built)' empty is the rule's doing

# 6b. a bundle-only app with allow-resign set is still refused when the setting is absent: the
# default is the strict rule (case 6 above), so the opt-in below is what changes the outcome

# 8. allow-resign: only after EVERY source failed to give a plain APK does a bundle get merged
reset; APKM_KIND=bundle UPT_KIND=bundle; ALLOW=true; MERGE_OK=true; run
[ -f "$BUILD_DIR/bitget-v2.94.4-arm64-v8a.apk" ] || fail "8: with allow-resign and only bundles the merged file is published, got: $(built)"
[ "$(jq -r '.Bitget.resigned' "$BUILD_JSON_FILE")" = true ] || fail "8: the file must be recorded as re-signed, got: $(jq -c '.Bitget.resigned' "$BUILD_JSON_FILE")"
[ "$CALLS" = "apkmirror uptodown apkmirror " ] || fail "8: both sources are asked strictly first, then the merge is accepted, got: $CALLS"

# 9. control: allow-resign set but a plain APK exists on a later source: it wins, nothing is merged
reset; APKM_KIND=bundle UPT_KIND=plain; ALLOW=true; MERGE_OK=true; run
[ "$(jq -r '.Bitget.apk_source' "$BUILD_JSON_FILE")" = uptodown ] && [ "$(jq -r '.Bitget.resigned' "$BUILD_JSON_FILE")" = false ] || fail "9: the plain APK must win over a merge, got: $(jq -c '.Bitget' "$BUILD_JSON_FILE")"
logged "REACHED-MERGE" && fail "9: nothing may be merged while a plain APK is available"
[ "$CALLS" = "apkmirror uptodown " ] || fail "9: calls: $CALLS"

# 10. control: bundles only and NO allow-resign (the default) publish nothing, as in case 6
reset; APKM_KIND=bundle UPT_KIND=bundle; ALLOW=false; MERGE_OK=true; run
[ -z "$(built)" ] || fail "10: without allow-resign nothing may be published even if the merge would work, got: $(built)"
logged "REACHED-MERGE" && fail "10: the merge must not be reached"
ALLOW=false

# 7. the flag does not leak: a patched build in the same shell is not under the mirror rule
[ "${__MIRROR_NO_RESIGN__:-false}" != true ] || fail "7: __MIRROR_NO_RESIGN__ must not stay set after a mirror build"

echo "MIRROR SIGNATURE TESTS: PASS"
