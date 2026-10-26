#!/usr/bin/env bash
# Regression test for the watcher's single-pool bookkeeping: derive_source_changes.py,
# sync_patch_sources.parse_releases, ci_generate_configs.sh, ci_resolve_triggers.sh and
# ci_trigger_flags.sh. Offline (python3 + jq).
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS="$REPO_ROOT/.github/scripts"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

# --- derive_source_changes: a moved stable release is a record, a moved beta is not -------------
mkdir -p "$WORK/d" && cd "$WORK/d" || exit 1
cat > tags_old.json <<'JSON'
{"o/moved":   {"repo": "o/moved",   "stable": "v1", "beta": "v2-beta"},
 "o/same":    {"repo": "o/same",    "stable": "v1"},
 "o/betaonly":{"repo": "o/betaonly","stable": "v1", "beta": "v2-beta"},
 "o/blocked": {"repo": "o/blocked", "stable": "v1"}}
JSON
cat > tags_new.json <<'JSON'
{"o/moved":   {"repo": "o/moved",   "stable": "v2", "stable_date": "2026-10-12T00:00:00Z", "beta": "v2-beta"},
 "o/same":    {"repo": "o/same",    "stable": "v1"},
 "o/betaonly":{"repo": "o/betaonly","stable": "v1", "beta": "v3-beta", "beta_date": "2027-01-01T00:00:00Z"},
 "o/blocked": {"repo": "o/blocked", "stable": "v9", "blocked": true},
 "o/fresh":   {"repo": "o/fresh",   "stable": "v1"}}
JSON
python3 "$SCRIPTS/derive_source_changes.py" > /dev/null || fail "derive failed"
[ "$(jq -c '[.[].repo]|sort' changed_sources.json)" = '["o/fresh","o/moved"]' ] || fail "records: $(jq -c '[.[].repo]' changed_sources.json)"
[ "$(jq -r '[.[]|.channel]|unique|join(",")' changed_sources.json)" = "stable" ] || fail "only the stable channel exists"
# controls: the beta-only source did move, and the blocked one did change tag - neither yields a record
[ "$(jq -r '."o/betaonly".beta' tags_new.json)" != "$(jq -r '."o/betaonly".beta' tags_old.json)" ] || fail "control: the beta must have moved"
jq -e 'map(select(.repo=="o/betaonly" or .repo=="o/blocked"))|length==0' changed_sources.json >/dev/null || fail "beta-only / blocked sources must not trigger"

# --- sync_patch_sources.parse_releases: pre-releases are not releases -------------------------
python3 - "$SCRIPTS" <<'PY' || fail "parse_releases"
import sys
sys.path.insert(0, sys.argv[1])
import sync_patch_sources as s
gh = [{"tag_name": "v3-beta", "prerelease": True,  "published_at": "2026-03"},
      {"tag_name": "v2",      "prerelease": False, "published_at": "2026-02"},
      {"tag_name": "v9",      "prerelease": False, "draft": True, "published_at": "2026-04"},
      {"tag_name": "v1",      "prerelease": False, "published_at": "2026-01"}]
assert s.parse_releases(gh, "github") == ("v2", "2026-02"), s.parse_releases(gh, "github")
assert s.parse_releases(gh[:1], "github") == ("", ""), "a source with only pre-releases has no release"
gl = [{"tag_name": "v1.5.0-dev.2", "released_at": "2026-03"}, {"tag_name": "v1.4.0", "released_at": "2026-02"}]
assert s.parse_releases(gl, "gitlab") == ("v1.4.0", "2026-02"), s.parse_releases(gl, "gitlab")
assert s.parse_releases(None, "github") == ("", "")
PY

# --- ci_generate_configs.sh -------------------------------------------------------------------
G="$WORK/g"; mkdir -p "$G/scripts" "$G/configs"; : > "$G/scripts/utils.sh"
cat > "$G/config.json" <<'JSON'
{"patches-version": "stable",
 "Reddit":  {"patches-source": "MorpheApp/morphe-patches", "pkg-name": "com.reddit.frontpage"},
 "Twitter": {"patches-source": "crimera/piko", "pkg-name": "com.twitter.android", "patches-version": "v3.0"},
 "Bitget":  {"mirror": true, "pkg-name": "com.bitget.exchange"}}
JSON
gen() { # $1=changed_sources.json  $2=active_patch_apps  $3=active_apps ; env TRIGGER_* from caller
	rm -f "$G/configs/build.json"
	printf '%s' "$1" > "$G/changed_sources.json"; printf '%s' "$2" > "$G/active_patch_apps.json"; printf '%s' "$3" > "$G/active_apps.json"
	( cd "$G" && bash "$SCRIPTS/ci_generate_configs.sh" > run.log 2>&1 ) || fail "generate failed: $(tail -3 "$G/run.log")"
}
enabled() { jq -c '[to_entries[]|select((.value|type=="object") and .value.enabled!=false)|.key]' "$G/configs/build.json"; }

TRIGGER_PATCHES=1 TRIGGER_APP_UPDATE=0 TRIGGER_BLOCKED=0 gen '[{"repo":"crimera/piko","channel":"stable"}]' '["Twitter"]' '[]'
[ "$(enabled)" = '["Twitter"]' ] || fail "a moved source enables the apps whose bundle changed, got $(enabled)"
[ "$(jq -r '."patches-version"' "$G/configs/build.json")" = "stable" ] || fail "the pool's channel is stable"
[ "$(jq -r '.Twitter."patches-version"' "$G/configs/build.json")" = "v3.0" ] || fail "a pin must never be rewritten"
# control: Reddit is in the file, just disabled
[ "$(jq -r '.Reddit.enabled' "$G/configs/build.json")" = "false" ] || fail "control: an app that is not due is written disabled"

# a moved source whose bundle did not change for the app enables nothing
TRIGGER_PATCHES=1 TRIGGER_APP_UPDATE=0 TRIGGER_BLOCKED=0 gen '[{"repo":"crimera/piko","channel":"stable"}]' '[]' '[]'
[ "$(enabled)" = '[]' ] || fail "bundle unchanged -> nothing enabled, got $(enabled)"

# an app update enables that app, mirror or not
TRIGGER_PATCHES=0 TRIGGER_APP_UPDATE=1 TRIGGER_BLOCKED=0 gen '[]' '[]' '["Bitget","Reddit"]'
[ "$(enabled)" = '["Reddit","Bitget"]' ] || fail "app updates enable those apps, got $(enabled)"

# no trigger at all leaves configs/build.json alone (it is not regenerated)
echo '{"keep":"me"}' > "$G/configs/build.json"
printf '[]' > "$G/changed_sources.json"
( cd "$G" && TRIGGER_PATCHES=0 TRIGGER_APP_UPDATE=0 TRIGGER_BLOCKED=0 bash "$SCRIPTS/ci_generate_configs.sh" > run.log 2>&1 ) || fail "generate (no trigger) failed"
[ "$(cat "$G/configs/build.json")" = '{"keep":"me"}' ] || fail "nothing to do must not rewrite the config"

# --- ci_resolve_triggers.sh -------------------------------------------------------------------
R="$WORK/r"; mkdir -p "$R/configs"; cd "$R" || exit 1
resolve() { : > out; RAW_TRIGGER_PATCHES="$1" RAW_TRIGGER_APP_UPDATE="$2" GITHUB_OUTPUT="$R/out" bash "$SCRIPTS/ci_resolve_triggers.sh" > log 2>&1 || fail "resolve failed"; cat out; }
echo '{"patches-version":"stable","A":{"enabled":false},"B":{"pkg-name":"b"}}' > configs/build.json
[ "$(resolve 1 0)" = "TRIGGER_BUILD=1" ] || fail "an enabled app triggers the build"
[ "$(resolve 0 1)" = "TRIGGER_BUILD=1" ] || fail "an app update triggers the build"
[ "$(resolve 0 0)" = "TRIGGER_BUILD=0" ] || fail "no raw trigger -> no build (control)"
echo '{"patches-version":"stable","A":{"enabled":false}}' > configs/build.json
[ "$(resolve 1 0)" = "TRIGGER_BUILD=0" ] || fail "nothing enabled -> no build"
grep -q "no enabled apps" log || fail "should say why: $(cat log)"
grep -q "BETA" out && fail "no beta trigger exists"

# --- ci_trigger_flags.sh ----------------------------------------------------------------------
flags() { : > out; TRIGGER_PATCHES="$1" TRIGGER_BLOCKED="$2" TRIGGER_APP_UPDATE="$3" GITHUB_OUTPUT="$R/out" bash "$SCRIPTS/ci_trigger_flags.sh" || fail "flags failed"; tr '\n' ' ' < out; }
[ "$(flags 1 0 0)" = "SOURCES_CHANGED=1 ANYTHING_CHANGED=1 " ] || fail "patches: $(flags 1 0 0)"
[ "$(flags 0 1 0)" = "SOURCES_CHANGED=0 ANYTHING_CHANGED=1 " ] || fail "blocked: $(flags 0 1 0)"
[ "$(flags 0 0 1)" = "SOURCES_CHANGED=0 ANYTHING_CHANGED=1 " ] || fail "app update: $(flags 0 0 1)"
[ "$(flags 0 0 0)" = "SOURCES_CHANGED=0 ANYTHING_CHANGED=0 " ] || fail "idle: $(flags 0 0 0)"
# --- the schedule: one tick a day, 00:00 IST = 18:30 UTC --------------------------------------
crons=$(grep -E '^[[:space:]]*- cron:' "$REPO_ROOT/.github/workflows/ci.yml")
[ "$(wc -l <<<"$crons")" = 1 ] && grep -q '"30 18 \* \* \*"' <<<"$crons" || fail "the watcher must run once a day at 30 18 (00:00 IST), got: $crons"
echo "CI WATCHER TESTS: PASS"
