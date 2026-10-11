#!/usr/bin/env bash
# Regression test for `version = "waenhancer"`: waenhancer_vers (which versions the latest
# WaEnhancer release supports, out of what a source lists) and its use by mirror_rv (which
# source supplies the version, and that a failed download falls back to the next source for the
# SAME version). Offline: curl, the store scrapers and the downloads are fakes, so the real
# parsing (arrays.xml, apkmirror_search.py), filtering and fallback logic are what is under test.
#
# Every absence assertion has a negative control next to it.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
REPO_ROOT=$(pwd)
# shellcheck disable=SC1091
source scripts/utils.sh >/dev/null 2>&1

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

# --- WaEnhancer, as GitHub serves it -------------------------------------------------------
WAE_TAG="1.6.1-1da24d77"
WAE_ARRAYS=$'<?xml version="1.0" encoding="utf-8"?>\n<resources>\n    <string-array name="supported_versions_wpp">\n        <item>2.26.38.xx</item>\n        <item>2.26.39.xx</item>\n        <item>2.26.40.xx</item>\n    </string-array>\n    <string-array name="supported_versions_business">\n        <item>2.26.39.xx</item>\n        <item>2.26.40.5</item>\n    </string-array>\n    <string-array name="scope">\n        <item>com.whatsapp</item>\n        <item>9.9.9.xx</item>\n    </string-array>\n</resources>'
# curl, as a function so the real one is never reached: /releases/latest answers with a redirect
# to the tag, and the raw arrays.xml is served only under that exact tag.
curl() {
	case "$*" in
	*" -I "* | *"-sfI "*) [ -n "$WAE_TAG" ] || return 22
		printf 'HTTP/2 302\r\nlocation: https://github.com/Dev4Mod/WaEnhancer/releases/tag/%s\r\n\r\n' "$WAE_TAG" ;;
	*"raw.githubusercontent.com/Dev4Mod/WaEnhancer/${WAE_TAG}/app/src/main/res/values/arrays.xml"*) printf '%s\n' "$WAE_ARRAYS" ;;
	*) return 22 ;;
	esac
}

# --- the stores ------------------------------------------------------------------------------
# an APKMirror app page: releases as the real markup links them; a beta's link does not say beta
# but its title does
apkm_page() { # $@ = "version" or "version beta"
	local v out=""
	for v in "$@"; do
		out+="<a class=\"fontBlack\" href=\"/apk/whatsapp-inc/whatsapp-messenger/whatsapp-messenger-${v%% *}-release/\">WhatsApp Messenger ${v}</a>"$'\n'
	done
	printf '%s' "$out"
}
FEED_LOG="$WORK/feed_calls" # a file, because waenhancer_vers runs in a $( ) subshell
: > "$FEED_LOG"
feed_calls() { wc -l < "$FEED_LOG" | tr -d ' '; }
declare -A FEED=() # page -> html
get_apkmirror_listing_vers() { echo "$1" >> "$FEED_LOG"; python3 "$REPO_ROOT/scripts/apkmirror_search.py" vers false <<<"${FEED[$1]:-}"; }
UPTODOWN_LISTING=""
get_uptodown_vers() { printf '%s' "$UPTODOWN_LISTING"; }

vers_of() { # waenhancer_vers <src> <pkg>: sets VERS_OUT and VERS_RC (no subshell, so both survive)
	VERS_OUT=$(waenhancer_vers "$1" "$2" 2>/dev/null)
	VERS_RC=$?
}
lines() { tr '\n' ' ' <<<"$1" | sed 's/ $//'; }

# 1. APKMirror, answered by the app page: only supported minors, no beta -------------------
__APKMIRROR_RESP__=$(apkm_page 2.26.39.79 "2.26.40.7 beta" 2.26.41.3 2.26.40.72 2.26.39.80 2.26.37.9)
: > "$FEED_LOG"
vers_of apkmirror com.whatsapp; got=$(sort <<<"$VERS_OUT")
[ "$VERS_RC" = 0 ] || fail "1: rc $VERS_RC"
[ "$(lines "$got")" = "2.26.39.79 2.26.39.80 2.26.40.72" ] || fail "1: expected the 2.26.39/40 stable builds only, got: $(lines "$got")"
# controls: the beta of a supported minor, an unsupported newer minor and an old minor are listed on the page
grep -q '2.26.40.7 beta' <<<"$__APKMIRROR_RESP__" && grep -q 2.26.41.3 <<<"$__APKMIRROR_RESP__" && grep -q 2.26.37.9 <<<"$__APKMIRROR_RESP__" \
	|| fail "1: control page does not hold the excluded versions"
grep -qx '2.26.40.7' <<<"$got" && fail "1: a beta must not be taken"
[ "$(feed_calls)" = 0 ] || fail "1: a match on the app page must not fetch the uploads feed ($(feed_calls) calls)"

# 2. nothing on the app page: the uploads feed is paged until a page matches ----------------
__APKMIRROR_RESP__=$(apkm_page 2.26.41.3 2.26.41.2)
FEED=([1]="$(apkm_page 2.26.41.1 2.26.41.0)" [2]="$(apkm_page 2.26.40.72 2.26.40.5)" [3]="$(apkm_page 2.26.40.4)")
: > "$FEED_LOG"
vers_of apkmirror com.whatsapp; got=$VERS_OUT
[ "$(lines "$(sort <<<"$got")")" = "2.26.40.5 2.26.40.72" ] || fail "2: expected the page-2 matches, got: $(lines "$got")"
[ "$(feed_calls)" = 2 ] || fail "2: must stop at the first page with a match (feed calls: $(feed_calls))"

# 3. a feed that repeats itself has run out: stop, report nothing (rc 0, empty) -------------
FEED=([1]="$(apkm_page 2.26.41.1)" [2]="$(apkm_page 2.26.41.1)" [3]="$(apkm_page 2.26.40.72)")
: > "$FEED_LOG"
vers_of apkmirror com.whatsapp; got=$VERS_OUT
[ "$VERS_RC" = 0 ] || fail "3: nothing supported is not a failure (rc $VERS_RC)"
[ -z "$got" ] || fail "3: expected no version, got: $got"
[ "$(feed_calls)" = 2 ] || fail "3: a repeated page must end the paging (feed calls: $(feed_calls))"
# control: without the repeat the third page IS reached and matches
FEED=([1]="$(apkm_page 2.26.41.1)" [2]="$(apkm_page 2.26.41.0)" [3]="$(apkm_page 2.26.40.72)")
vers_of apkmirror com.whatsapp; got=$VERS_OUT
[ "$got" = "2.26.40.72" ] || fail "3 control: expected 2.26.40.72 from page 3, got: $got"

# 4. another source gives one list, filtered the same way, with no paging ------------------
UPTODOWN_LISTING=$'2.26.41.3\n2.26.40.72\n2.26.38.1\n2.26.36.9'
: > "$FEED_LOG"
vers_of uptodown com.whatsapp; got=$VERS_OUT
[ "$(lines "$got")" = "2.26.40.72 2.26.38.1" ] || fail "4: got: $(lines "$got")"
[ "$(feed_calls)" = 0 ] || fail "4: uptodown must not touch the APKMirror feed"

# 5. a package is matched against ITS array: Business lists 2.26.39.xx and the build 2.26.40.5
UPTODOWN_LISTING=$'2.26.40.72\n2.26.40.5\n2.26.39.8\n2.26.38.1'
vers_of uptodown com.whatsapp.w4b; got=$VERS_OUT
[ "$(lines "$got")" = "2.26.40.5 2.26.39.8" ] || fail "5: Business must use its own list, got: $(lines "$got")"
vers_of uptodown com.whatsapp; got=$VERS_OUT
[ "$(lines "$got")" = "2.26.40.72 2.26.40.5 2.26.39.8 2.26.38.1" ] || fail "5 control: WhatsApp must use its own list, got: $(lines "$got")"

# 6. failures that no source can fix: rc 1 --------------------------------------------------
vers_of uptodown com.example.other >/dev/null; [ "$VERS_RC" = 1 ] || fail "6: another package must be refused (rc $VERS_RC)"
WAE_TAG="" vers_of uptodown com.whatsapp >/dev/null; [ "$VERS_RC" = 1 ] || fail "6: an unresolvable release must fail (rc $VERS_RC)"
WAE_ARRAYS='<resources></resources>' vers_of uptodown com.whatsapp >/dev/null; [ "$VERS_RC" = 1 ] || fail "6: a release with no list must fail (rc $VERS_RC)"
vers_of uptodown com.whatsapp >/dev/null; [ "$VERS_RC" = 0 ] || fail "6 control: the same call with a readable list succeeds (rc $VERS_RC)"

# ===== mirror_rv ============================================================================
TEMP_DIR="$WORK/temp"
BUILD_DIR="$WORK/build"
BUILD_JSON_FILE="$WORK/build.json"
mkdir -p "$TEMP_DIR" "$BUILD_DIR"
cd "$WORK" # sig.txt is read relative to the cwd by check_sig
: > sig.txt
cat > "$WORK/aapt2" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
	"dump packagename") printf '%s\n' "${FAKE_PKG:-}" ;;
	"dump badging") printf "package: name='%s' versionCode='1' versionName='%s'\n" "${FAKE_PKG:-}" "${FAKE_VERNAME-}" ;;
esac
STUB
chmod +x "$WORK/aapt2"
AAPT2="$WORK/aapt2"
export FAKE_PKG="com.whatsapp" FAKE_VERNAME=""

mkapk() { # $1=output
	local d
	d=$(mktemp -d "$WORK/apk.XXXXXX")
	echo manifest > "$d/AndroidManifest.xml"
	mkdir -p "$d/lib/arm64-v8a"; echo so > "$d/lib/arm64-v8a/libx.so"
	rm -f "$1"
	( cd "$d" && zip -qr "$1" . )
	rm -rf "$d"
}
APKM_OK=true APKM_RESP_OK=true
CALLS=""
get_apkmirror_resp() { $APKM_RESP_OK; }
get_apkmirror_pkg_name() { echo com.whatsapp; }
dl_apkmirror() { CALLS+="apkmirror:$2 "; $APKM_OK || return 1; mkapk "$3"; }
get_uptodown_resp() { :; }
get_uptodown_pkg_name() { echo com.whatsapp; }
dl_uptodown() { CALLS+="uptodown:$2 "; mkapk "$3"; }

reset() {
	rm -rf "$BUILD_DIR"/* "$TEMP_DIR"/apks_dl "$TEMP_DIR"/build_info "$BUILD_JSON_FILE"; echo '{}' > "$BUILD_JSON_FILE"
	CALLS="" APKM_OK=true APKM_RESP_OK=true WAE_TAG="1.6.1-1da24d77"
	WAE_ARRAYS=$'<resources>\n<string-array name="supported_versions_wpp">\n<item>2.26.39.xx</item>\n<item>2.26.40.xx</item>\n</string-array>\n</resources>'
	__APKMIRROR_RESP__=$(apkm_page 2.26.41.3 2.26.40.72 2.26.40.7)
	FEED=() UPTODOWN_LISTING=$'2.26.40.72\n2.26.40.5'; : > "$FEED_LOG"
}
run_wa() { # $@ = key=value overrides
	declare -A app_args=([table]="WhatsApp (arm64-v8a)" [app_name]="WhatsApp" [pkg_name]="com.whatsapp"
		[version]="waenhancer" [arch]="arm64-v8a" [brand]="Mirror" [mirror]=true [keep_filename]=false
		[dpi]="" [uptodown_dlurl]="https://wa.example/android" [apkmirror_dlurl]="https://www.apkmirror.com/apk/whatsapp-inc/whatsapp-messenger/"
		[github_dlurl]="" [cache_repo_dlurl]="" [archive_dlurl]="" [direct_dlurl]="" [apkpure_dlurl]="" [apkcombo_dlurl]="")
	local kv
	for kv in "$@"; do app_args["${kv%%=*}"]="${kv#*=}"; done
	build_rv "$(declare -p app_args)" >/dev/null 2>&1
	merge_build_info
}
built() { ls "$BUILD_DIR" 2>/dev/null | tr '\n' ' '; }
src_of() { jq -r '.WhatsApp.apk_source // ""' "$BUILD_JSON_FILE"; }

# 7. APKMirror lists a supported build and serves it ---------------------------------------
reset; run_wa
[ -f "$BUILD_DIR/whatsapp-v2.26.40.72-arm64-v8a.apk" ] || fail "7: expected whatsapp-v2.26.40.72-arm64-v8a.apk (the supported stable build, not the 2.26.41 beta line), got: $(built)"
[ "$(src_of)" = apkmirror ] || fail "7: source '$(src_of)'"
[ "$CALLS" = "apkmirror:2.26.40.72 " ] || fail "7: only APKMirror is asked when it works, got: $CALLS"

# 8. APKMirror lists it but the download fails: Uptodown is asked for the SAME build --------
reset; APKM_OK=false; run_wa
[ -f "$BUILD_DIR/whatsapp-v2.26.40.72-arm64-v8a.apk" ] || fail "8: expected the same version from Uptodown, got: $(built)"
[ "$(src_of)" = uptodown ] || fail "8: source '$(src_of)'"
[ "$CALLS" = "apkmirror:2.26.40.72 uptodown:2.26.40.72 " ] || fail "8: both sources must be asked for 2.26.40.72, got: $CALLS"
# control: with a working APKMirror the same setup never reaches Uptodown (case 7 above)

# 9. APKMirror cannot be reached at all (Cloudflare): the version AND the file come from Uptodown
reset; APKM_RESP_OK=false; run_wa
[ -f "$BUILD_DIR/whatsapp-v2.26.40.72-arm64-v8a.apk" ] || fail "9: got: $(built)"
[ "$(src_of)" = uptodown ] && [ "$CALLS" = "uptodown:2.26.40.72 " ] || fail "9: source '$(src_of)', calls: $CALLS"

# 10. APKMirror answers but lists nothing supported: Uptodown names the version ------------
reset; __APKMIRROR_RESP__=$(apkm_page 2.26.41.3 2.26.41.2); FEED=([1]="$(apkm_page 2.26.41.1)" [2]="$(apkm_page 2.26.41.1)")
UPTODOWN_LISTING=$'2.26.41.3\n2.26.40.5\n2.26.39.8'
APKM_OK=false # it does not have that build either, which is why it listed none
run_wa
[ -f "$BUILD_DIR/whatsapp-v2.26.40.5-arm64-v8a.apk" ] || fail "10: expected Uptodown's highest supported build 2.26.40.5, got: $(built)"
[ "$(src_of)" = uptodown ] || fail "10: source '$(src_of)'"
# APKMirror is still asked for the build Uptodown named (it may hold it past the pages read): the
# version is one, whichever source ends up serving it
[ "$CALLS" = "apkmirror:2.26.40.5 uptodown:2.26.40.5 " ] || fail "10: calls: $CALLS"

# 11. no source lists a supported build: nothing is mirrored and nothing downloaded ---------
reset; __APKMIRROR_RESP__=$(apkm_page 2.26.41.3); FEED=([1]="$(apkm_page 2.26.41.1)" [2]="$(apkm_page 2.26.41.1)")
UPTODOWN_LISTING=$'2.26.41.3\n2.26.41.1'; run_wa
[ -z "$(built)" ] || fail "11: nothing supported must publish nothing, got: $(built)"
[ -z "$CALLS" ] || fail "11: nothing supported must download nothing, got: $CALLS"
# control: the same harness with a supported build on Uptodown publishes it
UPTODOWN_LISTING=$'2.26.41.3\n2.26.40.5'; run_wa
[ -f "$BUILD_DIR/whatsapp-v2.26.40.5-arm64-v8a.apk" ] || fail "11 control: got: $(built)"

# 12. an unreadable WaEnhancer release stops the app: no guess, no download -----------------
reset; WAE_TAG=""; run_wa
[ -z "$(built)" ] && [ -z "$CALLS" ] || fail "12: built '$(built)', calls '$CALLS'"
reset; run_wa
[ -n "$(built)" ] || fail "12 control: the same app builds once the release resolves"

# 13. the mode is for the WhatsApp apps only ---------------------------------------------
reset; FAKE_PKG=com.example.other run_wa pkg_name=com.example.other
[ -z "$(built)" ] && [ -z "$CALLS" ] || fail "13: another package must not be mirrored by waenhancer, got '$(built)'"
FAKE_PKG=com.whatsapp

echo "WAENHANCER TESTS: PASS"
