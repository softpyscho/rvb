#!/usr/bin/env bash
# Regression test for how dl_apkmirror finds a release page (scripts/utils.sh), offline: the page
# fetcher is a fake that serves crafted APKMirror pages and records every URL asked for.
#
# The bug this pins: when the expected release page could not be fetched, the fallbacks searched
# the whole site for "<version>-release" and took the first hit, which is any app that has the
# same version number ("Resolved APKMirror page is for 'ru.vkusvill', not expected
# 'com.truecaller'"). Every fallback now takes only links under the app's own path, and the
# app's uploads feed - which reaches back further than the app page - is searched too.
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

arch=$(uname -m); [ "$arch" = aarch64 ] && arch=arm64
HTMLQ="$REPO_ROOT/bin/htmlq/htmlq-${arch}"
[ -x "$HTMLQ" ] || fail "no htmlq binary for $arch under bin/htmlq"
TEMP_DIR="$WORK/temp"; mkdir -p "$TEMP_DIR"
declare -A args=()
__APKMIRROR_EXAMPLE_URL__=""
pkg_name=com.truecaller

BASE=https://www.apkmirror.com
APP=$BASE/apk/dev/tc/
FETCHED="$WORK/fetched"
declare -A PAGES=()
# the fake fetcher: serves PAGES[url] into the caller's `html`, fails for any other URL
_cf_get() { echo "$1" >> "$FETCHED"; if [ -n "${PAGES[$1]+x}" ]; then html="${PAGES[$1]}"; return 0; fi; html=""; return 1; }

link() { printf '<a class="fontBlack" href="%s">x</a>\n' "$1"; }
play() { printf '<a href="https://play.google.com/store/apps/details?id=%s">Google Play</a>' "$1"; }
reset() {
	: > "$FETCHED"; PAGES=()
	__APKMIRROR_RESP__='<h1 class="marginZero">Truecaller: Spam Call Blocker</h1>'
	__APKMIRROR_CAT__=tc
	# the app page lists only newer releases, and a widget link to ANOTHER app's release of the
	# very version asked for; its /page/N/ repeats page 1, as APKMirror's does
	local page; page="$(link /apk/dev/tc/tc-26-10-9-release/)$(link /apk/dev/tc/tc-26-10-8-release/)$(link /apk/vkusvill/vk/vk-26-10-6-release/)"
	PAGES[$APP]="$page"
	local n; for n in 2 3 4 5 6 7 8 9 10; do PAGES[${APP}page/$n/]="$page"; done
}
run() { # sets RC and ERR; version 26.10.6
	ERR=$( { dl_apkmirror "$APP" 26.10.6 "$WORK/out.apk" arm64-v8a "nodpi anydpi auto" false "" ; } 2>&1 >/dev/null )
	RC=$?
}
asked() { grep -qF -- "$1" "$FETCHED"; }

# 1. the expected release page exists: it is used, and nothing is searched --------------------
reset
GUESS=${APP}truecaller-spam-call-blocker-26-10-6-release/
PAGES[$GUESS]="$(play com.truecaller)"
run
asked "$GUESS" || fail "1: the expected release page was not fetched"
asked "/uploads/" && fail "1: a found page must not search the uploads feed"
grep -q "Could not find download button" <<<"$ERR" || fail "1: should get past page resolution to the download table, got: $ERR"

# 2. the version is on no page of the app, but ANOTHER app has the same one: refused ----------
reset
PAGES[$BASE/uploads/?appcategory=tc]="$(link /apk/dev/tc/tc-26-10-9-release/)"
PAGES[$BASE/uploads/page/2/?appcategory=tc]="$(link /apk/dev/tc/tc-26-10-7-release/)"
PAGES["$BASE/?post_type=app_release&searchtype=apk&s=tc+26.10.6"]='<div class="appRow"><h5><a href="/apk/vkusvill/vk/vk-26-10-6-release/">VkusVill 26.10.6</a></h5></div>'
VK=$BASE/apk/vkusvill/vk/vk-26-10-6-release/
PAGES[$VK]="$(play ru.vkusvill)"
run
[ "$RC" = 1 ] || fail "2: expected failure, rc=$RC"
asked "/apk/vkusvill/" && grep -qF "$VK" "$FETCHED" && fail "2: another app's release page must never be fetched"
grep -q "Could not find version 26.10.6 under /apk/dev/tc/" <<<"$ERR" || fail "2: expected the not-found message naming the app path, got: $ERR"
# control: the same site-wide search result, but under the app's own path, IS taken
reset
PAGES["$BASE/?post_type=app_release&searchtype=apk&s=tc+26.10.6"]='<div class="appRow"><h5><a href="/apk/dev/tc/tc-26-10-6-release/">26.10.6</a></h5></div>'
PAGES[$BASE/apk/dev/tc/tc-26-10-6-release/]="$(play com.truecaller)"
run
asked "$BASE/apk/dev/tc/tc-26-10-6-release/" || fail "2 control: the app's own search hit must be followed"

# 3. the app page does not reach back, the uploads feed does -----------------------------
reset
PAGES[$BASE/uploads/?appcategory=tc]="$(link /apk/dev/tc/tc-26-10-9-release/)"
PAGES[$BASE/uploads/page/2/?appcategory=tc]="$(link /apk/dev/tc/tc-26-10-7-release/)$(link /apk/dev/tc/tc-26-10-6-release/)"
FOUND=$BASE/apk/dev/tc/tc-26-10-6-release/
PAGES[$FOUND]="$(play com.truecaller)"
run
asked "$FOUND" || fail "3: the release found in the uploads feed was not fetched"
grep -q "Could not find download button" <<<"$ERR" || fail "3: should get past page resolution, got: $ERR"
asked "post_type=app_release" && fail "3: a feed hit must end the search"
# control: with the release missing from the feed too, the feed is not what made case 3 pass
reset
PAGES[$BASE/uploads/?appcategory=tc]="$(link /apk/dev/tc/tc-26-10-9-release/)"
PAGES[$BASE/uploads/page/2/?appcategory=tc]="$(link /apk/dev/tc/tc-26-10-7-release/)"
run
[ "$RC" = 1 ] && asked "$FOUND" && fail "3 control: nothing may be fetched for a release no page lists"

# 4. a feed that repeats itself has run out: stop paging --------------------------------------
reset
PAGES[$BASE/uploads/?appcategory=tc]="$(link /apk/dev/tc/tc-26-10-9-release/)"
for n in 2 3 4 5 6 7 8; do PAGES[$BASE/uploads/page/$n/?appcategory=tc]="$(link /apk/dev/tc/tc-26-10-9-release/)"; done
run
[ "$(grep -c '/uploads/' "$FETCHED")" = 2 ] || fail "4: a repeated feed page must end the paging, fetched: $(grep '/uploads/' "$FETCHED" | tr '\n' ' ')"

# 5. a different patch version of the same app is not the version asked for -------------------
# the app page lists 26.10.9 and 26.10.8; asking for 26.10.6 must not be answered by either
reset
run
[ "$RC" = 1 ] || fail "5: expected failure, rc=$RC"
asked "$BASE/apk/dev/tc/tc-26-10-9-release/" && fail "5: 26.10.9 must not answer for 26.10.6"
asked "$BASE/apk/dev/tc/tc-26-10-8-release/" && fail "5: 26.10.8 must not answer for 26.10.6"
# control: the grouped form the short match is for - the slug without the last part - still works
reset
PAGES[$APP]="$(link /apk/dev/tc/tc-26-10-release/)$(link /apk/dev/tc/tc-26-10-9-release/)"
PAGES[$BASE/apk/dev/tc/tc-26-10-release/]="$(play com.truecaller)"
run
asked "$BASE/apk/dev/tc/tc-26-10-release/" || fail "5 control: the exact short slug must still be followed"
asked "$BASE/apk/dev/tc/tc-26-10-9-release/" && fail "5 control: and it must not be the 26.10.9 page"

echo "APKMIRROR RESOLVE TESTS: PASS"
