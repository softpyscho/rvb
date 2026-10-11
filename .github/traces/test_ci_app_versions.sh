#!/usr/bin/env bash
# Regression test for ci_fetch_app_versions.sh: which apps does the watcher check for a new
# version? Run offline against a sandbox whose scripts/utils.sh is a stub that "scrapes" a fixed
# version, so what is under test is only the selection of apps from the compiled pool configs.
#
# The bug this pins: selection required `enabled == true`, so an app whose TOML relied on the
# documented default (enabled = true, key omitted) was never version-checked.
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

mkdir -p "$WORK/scripts" "$WORK/state" "$WORK/stub" "$WORK/.github"
ln -s "$REPO_ROOT/.github/scripts" "$WORK/.github/scripts"
cat > "$WORK/scripts/utils.sh" <<'STUB'
set_prebuilts() { :; }
get_uptodown_resp() { :; }
get_uptodown_vers() { echo "3.1.4"; }
get_highest_ver() { tee | head -1; }
STUB
printf '#!/bin/sh\nexit 0\n' > "$WORK/stub/sleep" # the script pauses between scrapes
chmod +x "$WORK/stub/sleep"
echo '{}' > "$WORK/state/app_versions.json"
cat > "$WORK/config.stable.json" <<'JSON'
{"patches-version": "stable",
 "Implicit":   {"uptodown-dlurl": "https://x/implicit"},
 "Explicit":   {"enabled": true,  "uptodown-dlurl": "https://x/explicit"},
 "Switched":   {"enabled": false, "uptodown-dlurl": "https://x/off"}}
JSON
cat > "$WORK/config.beta.json" <<'JSON'
{"patches-version": "beta",
 "BetaImplicit": {"uptodown-dlurl": "https://x/beta"}}
JSON

( cd "$WORK" && PATH="$WORK/stub:$PATH" bash .github/scripts/ci_fetch_app_versions.sh > run.log 2>&1 ) \
	|| fail "ci_fetch_app_versions.sh failed: $(tail -5 "$WORK/run.log")"
got=$(jq -r 'keys | join(",")' "$WORK/fetched_app_versions.json")
[ "$got" = "BetaImplicit,Explicit,Implicit" ] || fail "checked apps were '$got', expected BetaImplicit,Explicit,Implicit (run log: $(tail -3 "$WORK/run.log"))"
# the control is the disabled app: it is in the config and has a scrapeable URL, yet is not checked
jq -e 'has("Switched") | not' "$WORK/fetched_app_versions.json" >/dev/null || fail "a disabled app must not be version-checked"

# `version = "waenhancer"` apps: the watcher asks the sources in the engine's order (APKMirror,
# then Uptodown), hands over to the next source when one lists no supported build, and stops on an
# unreadable support list. An ordinary app in the same pool keeps the usual Uptodown-first order -
# that is the control for the ordering assertions.
WA="$WORK/wa"
mkdir -p "$WA/scripts" "$WA/state" "$WA/.github"
ln -s "$REPO_ROOT/.github/scripts" "$WA/.github/scripts"
cat > "$WA/scripts/utils.sh" <<'STUB'
set_prebuilts() { :; }
get_uptodown_resp() { :; }
get_uptodown_vers() { echo "9.9.9"; }
get_apkmirror_resp() { :; }
get_apkmirror_vers() { echo "8.8.8"; }
get_highest_ver() { tee | head -1; }
waenhancer_vers() {
	echo "$1 $2" >> "$WA_LOG"
	case "$1" in
	apkmirror) printf '%s' "$WA_APKM" ;;
	uptodown) printf '%s' "$WA_UP" ;;
	esac
	return "${WA_RC:-0}"
}
STUB
echo '{}' > "$WA/state/app_versions.json"
cat > "$WA/config.stable.json" <<'JSON'
{"patches-version": "stable", "mirror": true, "version": "latest",
 "WA":    {"version": "waenhancer", "pkg-name": "com.whatsapp",
           "uptodown-dlurl": "https://x/wa-up", "apkmirror-dlurl": "https://x/wa-apkm"},
 "Plain": {"uptodown-dlurl": "https://x/plain-up", "apkmirror-dlurl": "https://x/plain-apkm"}}
JSON
wa_watch() { # env WA_APKM WA_UP WA_RC; leaves fetched_app_versions.json and $WA_LOG
	export WA_LOG="$WA/order.log"; : > "$WA_LOG"
	rm -f "$WA/fetched_app_versions.json"
	( cd "$WA" && PATH="$WORK/stub:$PATH" bash .github/scripts/ci_fetch_app_versions.sh > run.log 2>&1 ) \
		|| fail "watcher failed on a waenhancer app: $(tail -5 "$WA/run.log")"
}
wa_ver() { jq -r --arg k "$1" '.[$k] // "-"' "$WA/fetched_app_versions.json"; }

WA_APKM=$'2.26.40.72\n2.26.39.80' WA_UP=$'2.26.40.5' WA_RC=0 wa_watch
[ "$(wa_ver WA)" = "2.26.40.72" ] || fail "waenhancer: APKMirror's supported build must win, got '$(wa_ver WA)'"
[ "$(cat "$WA_LOG")" = "apkmirror com.whatsapp" ] || fail "waenhancer: only APKMirror is asked while it lists a build: $(tr '\n' ';' < "$WA_LOG")"
[ "$(wa_ver Plain)" = "9.9.9" ] || fail "an ordinary app keeps the Uptodown-first order, got '$(wa_ver Plain)' (control)"

WA_APKM='' WA_UP=$'2.26.40.5' WA_RC=0 wa_watch
[ "$(wa_ver WA)" = "2.26.40.5" ] || fail "waenhancer: Uptodown must supply the version when APKMirror lists none, got '$(wa_ver WA)'"
[ "$(tr '\n' ';' < "$WA_LOG")" = "apkmirror com.whatsapp;uptodown com.whatsapp;" ] || fail "waenhancer: source order was $(tr '\n' ';' < "$WA_LOG")"

WA_APKM='' WA_UP='' WA_RC=0 wa_watch
[ "$(wa_ver WA)" = "-" ] || fail "waenhancer: no supported build anywhere must record nothing, got '$(wa_ver WA)'"
[ "$(wa_ver Plain)" = "9.9.9" ] || fail "waenhancer: one app without a version must not affect the others"

WA_APKM=$'2.26.40.72' WA_UP=$'2.26.40.5' WA_RC=1 wa_watch
[ "$(wa_ver WA)" = "-" ] || fail "waenhancer: an unreadable support list must record nothing, got '$(wa_ver WA)'"
[ "$(cat "$WA_LOG")" = "apkmirror com.whatsapp" ] || fail "waenhancer: an unreadable list ends the app, no other source is tried: $(tr '\n' ';' < "$WA_LOG")"

# The same default in patchers.py: does this pool need the Bouncy Castle keystore? An Xposed app
# that never writes `enabled` is enabled; an explicit false is the control that says no.
bks() { echo "$1" > "$WORK/bks.json"; python3 "$REPO_ROOT/.github/scripts/patchers.py" needs-bks "$WORK/bks.json"; }
bks '{"X": {"cli-source": "7723mod/NPatch"}}' || fail "an Xposed app with the default enabled must need BKS"
bks '{"X": {"enabled": true, "cli-source": "7723mod/NPatch"}}' || fail "an explicitly enabled Xposed app must need BKS"
bks '{"X": {"enabled": false, "cli-source": "7723mod/NPatch"}}' && fail "a disabled Xposed app must not need BKS"
bks '{"X": {"cli-source": "MorpheApp/morphe-desktop"}}' && fail "a non-Xposed app must not need BKS"
echo "CI APP VERSION TESTS: PASS"
