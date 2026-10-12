#!/usr/bin/env bash
# What a build records about itself beyond the applied patches: the download source of the stock
# APK, the version the patches recommend, and the patches that were meant to apply but did not
# (skipped by the patcher, failed, excluded by the config). Sources utils.sh and drives the real
# write_build_info / merge_build_info with a Morphe-shaped log and result file; then runs
# build_make_manifest.py over the merged record. Offline.
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT" || exit 1
# shellcheck disable=SC1091
source scripts/utils.sh >/dev/null 2>&1
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
TEMP_DIR="$WORK/temp"; BUILD_JSON_FILE="$WORK/build.json"; mkdir -p "$TEMP_DIR"
declare -A args=([arch]="arm64-v8a" [patches_src]="x/y" [brand]="Morphe" [variant]="" [sub_variant]="" [included_patches]="" [excluded_patches]="")
PATCHER_FLOW=cli-patch; PATCHER_KIND=morphe

record() { # key pkg source recommended [resigned] [experimental]
	write_build_info "$1" "arm64-v8a" ".apk" "$(tr 'A-Z' 'a-z' <<<"$1")-morphe" "2.5.0.2" "x/patches-1.0.mpp" "" "$2" "$1" "x/y" "Morphe" "" "" "" "$3" "$4" "${5:-}" "${6:-}"
}

# 1. Battery Guru as it really failed: one patch skipped as incompatible, none applied
PATCH_OUTPUT='INFO: Filtering patches for com.paget96.batteryguru v2.5.0.2...
WARNING: Skipping "Unlock PRO": incompatible with com.paget96.batteryguru 2.5.0.2 (supported: com.paget96.batteryguru 2.4.8.1, 2.5.0.2-beta1)
INFO: Applying 0 patches...'
PATCH_RESULT_FILE="$WORK/bg.json"; echo '{"appliedPatches":[],"failedPatches":[]}' > "$PATCH_RESULT_FILE"
record Battery-Guru com.paget96.batteryguru uptodown 2.5.0.6 >/dev/null 2>&1

# 2. a healthy app: two applied, one failed, one excluded by the config, source = archive
PATCH_OUTPUT='INFO: Applied: Hide ads
INFO: Applied: Premium'
PATCH_RESULT_FILE="$WORK/tc.json"; echo '{"appliedPatches":["Hide ads","Premium"],"failedPatches":[{"name":"Flaky patch"}]}' > "$PATCH_RESULT_FILE"
args[excluded_patches]="'Telemetry' 'Update check'"
record Truecaller com.truecaller archive 26.10.6 >/dev/null 2>&1
args[excluded_patches]=""

# 2b. the bundle ties several versions: the record keeps the newest (first) line only
PATCH_OUTPUT='INFO: Applied: A'
PATCH_RESULT_FILE="$WORK/tie.json"; echo '{"appliedPatches":["A"],"failedPatches":[]}' > "$PATCH_RESULT_FILE"
record Tied com.tied archive $'2026.40.0\n2026.39.0' >/dev/null 2>&1

# 3. nothing wrong, nothing recommended (the patches name no version)
PATCH_OUTPUT='INFO: Applied: Only patch'
PATCH_RESULT_FILE="$WORK/ok.json"; echo '{"appliedPatches":["Only patch"],"failedPatches":[]}' > "$PATCH_RESULT_FILE"
record Plain com.plain cache "" >/dev/null 2>&1

# 4. the signature of a mirror: true / false as given, null for a patched app (the 17th argument is
# empty there), and nothing else turns into a boolean
record Resigned com.resigned apkmirror "" true >/dev/null 2>&1
record Original com.original uptodown "" false >/dev/null 2>&1

merge_build_info >/dev/null 2>&1
[ -s "$BUILD_JSON_FILE" ] || fail "no merged build record"
q() { jq -c "$1" "$BUILD_JSON_FILE"; }

[ "$(q '.["Battery-Guru"].skipped_patches | map(.name)')" = '["Unlock PRO"]' ] || fail "skipped: $(q '.["Battery-Guru"].skipped_patches')"
jq -e '.["Battery-Guru"].skipped_patches[0].reason | test("incompatible with com.paget96.batteryguru 2.5.0.2")' "$BUILD_JSON_FILE" >/dev/null || fail "the reason should be kept"
[ "$(q '.["Battery-Guru"].applied_patches')" = '[]' ] || fail "nothing applied there"
[ "$(q '.["Battery-Guru"].apk_source')" = '"uptodown"' ] || fail "source: $(q '.["Battery-Guru"].apk_source')"
[ "$(q '.["Battery-Guru"].recommended_version')" = '"2.5.0.6"' ] || fail "recommended"

[ "$(q '.Truecaller.apk_source')" = '"archive"' ] || fail "archive source"
[ "$(q '.Truecaller.failed_patches')" = '["Flaky patch"]' ] || fail "failed: $(q '.Truecaller.failed_patches')"
[ "$(q '.Truecaller.excluded_patches')" = '["Telemetry","Update check"]' ] || fail "excluded: $(q '.Truecaller.excluded_patches')"
[ "$(q '.Truecaller.skipped_patches')" = '[]' ] || fail "nothing skipped there (control)"

[ "$(q '.Resigned.resigned')" = 'true' ] && [ "$(q '.Original.resigned')" = 'false' ] || fail "resigned: $(q '[.Resigned.resigned, .Original.resigned]')"
[ "$(q '.Plain.resigned')" = 'null' ] || fail "a patched app records null, got: $(q '.Plain.resigned')"
# negative control: a clean app carries empty lists, not leftovers from the app before it
[ "$(q '.Plain | [.skipped_patches, .failed_patches, .excluded_patches]')" = '[[],[],[]]' ] || fail "leak into a clean app: $(q '.Plain')"
[ "$(q '.Plain.recommended_version')" = '""' ] || fail "no recommendation is the empty string"

# the manifest: additive keys, lists only when non-empty
mkdir -p "$WORK/mf/build" "$WORK/mf/temp" && cp "$BUILD_JSON_FILE" "$WORK/mf/build.json"
for f in resigned-morphe-v2.5.0.2-arm64-v8a.apk original-morphe-v2.5.0.2-arm64-v8a.apk tied-morphe-v2.5.0.2-arm64-v8a.apk battery-guru-morphe-v2.5.0.2-arm64-v8a.apk truecaller-morphe-v2.5.0.2-arm64-v8a.apk plain-morphe-v2.5.0.2-arm64-v8a.apk; do : > "$WORK/mf/build/$f"; done
( cd "$WORK/mf" && NEXT_VER_CODE=260100 IS_PRERELEASE=false python3 "$REPO_ROOT/.github/scripts/build_make_manifest.py" >/dev/null 2>&1 ) || fail "build_make_manifest.py failed"
M="$WORK/mf/temp/manifest/build.json"
mq() { jq -c "$1" "$M"; }
[ "$(mq '.files["battery-guru-morphe-v2.5.0.2-arm64-v8a.apk"] | [.apkSource, .recommendedVersion, (.skippedPatches|map(.name))]')" = '["uptodown","2.5.0.6",["Unlock PRO"]]' ] || fail "manifest battery guru: $(mq '.files')"
[ "$(mq '.files["truecaller-morphe-v2.5.0.2-arm64-v8a.apk"] | [.apkSource, .failedPatches, .excludedPatches, has("skippedPatches")]')" = '["archive",["Flaky patch"],["Telemetry","Update check"],false]' ] || fail "manifest truecaller"
[ "$(mq '.files["plain-morphe-v2.5.0.2-arm64-v8a.apk"] | [.apkSource, .recommendedVersion, has("skippedPatches"), has("failedPatches")]')" = '["cache",null,false,false]' ] || fail "manifest plain: $(mq '.files')"
[ "$(mq '.files["resigned-morphe-v2.5.0.2-arm64-v8a.apk"].resigned')" = 'true' ] && [ "$(mq '.files["original-morphe-v2.5.0.2-arm64-v8a.apk"].resigned')" = 'false' ] || fail "manifest resigned: $(mq '.files')"
[ "$(mq '.files["plain-morphe-v2.5.0.2-arm64-v8a.apk"] | has("resigned")')" = 'false' ] || fail "a patched app writes no resigned key"

[ "$(mq '.files["tied-morphe-v2.5.0.2-arm64-v8a.apk"].recommendedVersion')" = '"2026.40.0"' ] || fail "a tie must collapse to the first version: $(mq '.files["tied-morphe-v2.5.0.2-arm64-v8a.apk"].recommendedVersion')"

# a record that predates these fields yields none of the keys (readers treat that as unknown)
printf '{"Old":{"exts":[".apk"],"name":"old-morphe","arch":"arm64-v8a","version":"1.0","patches":"","changelog":"","package_name":"com.old","display_name":"Old","patches_source":"x/y","brand":"Morphe","variant":"","sub_variant":"","file":"","applied_patches":["A"]}}' > "$WORK/mf/build.json"
: > "$WORK/mf/build/old-morphe-v1.0-arm64-v8a.apk"
( cd "$WORK/mf" && NEXT_VER_CODE=260101 IS_PRERELEASE=false python3 "$REPO_ROOT/.github/scripts/build_make_manifest.py" >/dev/null 2>&1 ) || fail "old record"
[ "$(mq '.files["old-morphe-v1.0-arm64-v8a.apk"] | has("apkSource")')" = false ] || fail "an old record must not grow an apkSource"

# _skipped_patches_json: reads only what the patcher said, nothing from a quiet log
[ "$(_skipped_patches_json 'INFO: Applying 3 patches...')" = '[]' ] || fail "a quiet log has no skipped patches"
# ===== which channel a version came from (README: Channel column) ================================
# A fake list-versions: without -x the stable targets, with -x the experimental ones as well, shaped like
# the Morphe CLI's output (verified against morphe-desktop 1.18.1 for Reddit, 2026-10-12).
patches_list_versions() { # cli patches pkg cli_source [extra]
	if [ "${5:-}" = "-x" ]; then
		printf 'INFO: Package name: %s\nMost common compatible versions:\n\t2026.41.0 (18 patches)\n\t2026.40.0 (18 patches)\n\t2026.24.0 (18 patches)\n\t2026.10.0 (18 patches)\n' "$3"
	else
		printf 'INFO: Package name: %s\nMost common compatible versions:\n\t2026.24.0 (18 patches)\n\t2026.10.0 (18 patches)\n' "$3"
	fi
}
MORPHE="MorpheApp/morphe-desktop"
[ "$(_version_is_experimental cli.jar p.mpp com.reddit.frontpage 2026.41.0 "$MORPHE")" = true ] || fail "2026.41.0 is only in the -x list: experimental"
[ "$(_version_is_experimental cli.jar p.mpp com.reddit.frontpage v2026.40.0 "$MORPHE")" = true ] || fail "a leading v is ignored"
[ "$(_version_is_experimental cli.jar p.mpp com.reddit.frontpage 2026.24.0 "$MORPHE")" = false ] || fail "2026.24.0 is on the stable list: not experimental (control)"
[ -z "$(_version_is_experimental cli.jar p.mpp com.reddit.frontpage 1.2.3 "$MORPHE")" ] || fail "a version listed nowhere is unknown, not 'stable'"
[ -z "$(_version_is_experimental cli.jar p.mpp com.reddit.frontpage 2026.41.0 "some/revanced-cli")" ] || fail "a CLI with no experimental flag cannot say"

# exp = the experimental-only versions, newest first; when none are left it takes the newest listed
got=$(get_patch_exp_ver cli.jar p.mpp com.reddit.frontpage "$MORPHE" 2>/dev/null | head -1)
[ "$got" = "2026.41.0" ] || fail "exp must name the newest experimental version, got: '$got'"
patches_list_versions() { # everything promoted to stable: both lists are the same
	printf 'INFO: Package name: %s\nMost common compatible versions:\n\t2026.41.0 (18 patches)\n\t2026.24.0 (18 patches)\n' "$3"
}
got=$(get_patch_exp_ver cli.jar p.mpp com.reddit.frontpage "$MORPHE" 2>/dev/null | head -1)
[ "$got" = "2026.41.0" ] || fail "with nothing experimental left exp must fall back to the newest listed, not skip: '$got'"
patches_list_versions() { printf 'INFO: Package name: %s\nMost common compatible versions:\nAny\n' "$3"; }
got=$(get_patch_exp_ver cli.jar p.mpp com.reddit.frontpage "$MORPHE" 2>/dev/null | head -1)
[ "$got" = "Any" ] || [ -z "$got" ] || fail "control: a bundle that names no version still resolves to nothing usable: '$got'"

# the record: true / false as given, null when unknown, and the manifest writes a key only when known
record Exp1 com.exp1 apkmirror "" "" true >/dev/null 2>&1
record Exp2 com.exp2 apkmirror "" "" false >/dev/null 2>&1
merge_build_info >/dev/null 2>&1
[ "$(q '.Exp1.experimental')" = 'true' ] && [ "$(q '.Exp2.experimental')" = 'false' ] || fail "experimental: $(q '[.Exp1.experimental, .Exp2.experimental]')"
[ "$(q '.Plain.experimental')" = 'null' ] || fail "an app that said nothing records null, got: $(q '.Plain.experimental')"

echo "BUILD RECORD TESTS: PASS"
