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

# The same default in patchers.py: does this pool need the Bouncy Castle keystore? An Xposed app
# that never writes `enabled` is enabled; an explicit false is the control that says no.
bks() { echo "$1" > "$WORK/bks.json"; python3 "$REPO_ROOT/.github/scripts/patchers.py" needs-bks "$WORK/bks.json"; }
bks '{"X": {"cli-source": "7723mod/NPatch"}}' || fail "an Xposed app with the default enabled must need BKS"
bks '{"X": {"enabled": true, "cli-source": "7723mod/NPatch"}}' || fail "an explicitly enabled Xposed app must need BKS"
bks '{"X": {"enabled": false, "cli-source": "7723mod/NPatch"}}' && fail "a disabled Xposed app must not need BKS"
bks '{"X": {"cli-source": "MorpheApp/morphe-desktop"}}' && fail "a non-Xposed app must not need BKS"
echo "CI APP VERSION TESTS: PASS"
