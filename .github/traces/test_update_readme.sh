#!/usr/bin/env bash
# Regression test for update_readme.sh: the CI step that refreshes the README app table on main.
# Offline: a local bare origin whose `main` carries the README (with the markers), the app config
# and the archive manifest (state/archive/); the real obtainium.py generates the section.
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
quiet() { grep -v -E "acknowledg|negotiation" || true; }

git init -q --bare "$WORK/origin.git"
git init -q -b main "$WORK/work"
cd "$WORK/work" || exit 1
git config user.email t@t; git config user.name t
git remote add origin "$WORK/origin.git"
mkdir -p configs/patches .github
ln -s "$REPO_ROOT/.github/scripts" .github/scripts
cat > configs/patches/m.toml <<'TOML'
patches-source = "MorpheApp/morphe-patches"
brand = "Morphe"
arch = "arm64-v8a"
[Reddit]
pkg-name = "com.reddit.frontpage"
apkmirror-dlurl = "https://www.apkmirror.com/apk/redditinc/reddit"
TOML
# main: a README with prose around the markers (which must survive untouched), plus the archive
# manifest the last build left
printf '# Title\n\nintro text\n\n<!-- APPS_START -->\nold table\n<!-- APPS_END -->\n\noutro text\n' > README.md
mkdir -p state/archive
cat > state/archive/stable.json <<'JSON'
{"schema":1,"kind":"archive","files":{"reddit-morphe-v2026.39.0-arm64-v8a.apk":{"name":"reddit-morphe","fileType":"APK","version":"2026.39.0","appliedPatches":["Hide ads","App icon"],"publishedAt":"2026-10-06T07:21:01Z"}}}
JSON
git add README.md configs state; git commit -qm init; git push -q origin main 2>&1 | quiet

run() { GITHUB_REPOSITORY=o/rvb BUILD_TAG=260042 bash "$REPO_ROOT/.github/scripts/update_readme.sh" 2>&1 | quiet; }
tip() { git -C "$WORK/origin.git" rev-parse main; }

before=$(tip)
out=$(run)
after=$(tip)
[ "$before" != "$after" ] || fail "the README should have been refreshed: $out"
new=$(git -C "$WORK/origin.git" show main:README.md)
grep -q "built-v2026.39.0-" <<<"$new" || fail "the section should carry the published version: $new"
grep -q '<b>2 patches</b>' <<<"$new" && grep -q '`App icon`<br>`Hide ads`' <<<"$new" || fail "the section should list the applied patches, sorted"
grep -q '^# Title$' <<<"$new" && grep -q '^intro text$' <<<"$new" && grep -q '^outro text$' <<<"$new" || fail "text outside the markers must be untouched"
grep -q "old table" <<<"$new" && fail "the old section content should be replaced"
msg=$(git -C "$WORK/origin.git" log -1 --format=%s main)
[ "$msg" = "docs: refresh the app table after build 260042 [skip ci]" ] || fail "commit message was: $msg"
[ "$(git -C "$WORK/origin.git" log -1 --format=%an main)" = "github-actions[bot]" ] || fail "authored by the bot"
git -C "$WORK/origin.git" diff --name-only "$before" "$after" | grep -qx README.md || fail "README.md should be the changed file"
[ "$(git -C "$WORK/origin.git" diff --name-only "$before" "$after" | wc -l)" = 1 ] || fail "only README.md may change"

# control 1: run again with nothing new -> no commit
out=$(run)
[ "$(tip)" = "$after" ] || fail "an unchanged table must not create a commit: $out"
grep -q "already up to date" <<<"$out" || fail "should say it is current: $out"

# control 2: a new build moves the version -> a new commit builds on the tip
cat > "$WORK/new.json" <<'JSON'
{"schema":1,"kind":"archive","files":{"reddit-morphe-v2026.40.0-arm64-v8a.apk":{"name":"reddit-morphe","fileType":"APK","version":"2026.40.0","appliedPatches":["Hide ads"],"publishedAt":"2026-10-07T07:00:00Z"},"reddit-morphe-v2026.39.0-arm64-v8a.apk":{"name":"reddit-morphe","fileType":"APK","version":"2026.39.0","appliedPatches":["Hide ads","App icon"],"publishedAt":"2026-10-06T07:21:01Z"}}}
JSON
git pull -q --ff-only origin main 2>&1 | quiet; cp "$WORK/new.json" state/archive/stable.json; git commit -qam newer; git push -q origin main 2>&1 | quiet
after=$(tip)
out=$(run)
[ "$(tip)" != "$after" ] || fail "a new version must produce a commit: $out"
git -C "$WORK/origin.git" show main:README.md | grep -q "built-v2026.40.0-" || fail "the newest published version should win"
[ "$(git -C "$WORK/origin.git" rev-parse main~1)" = "$after" ] || fail "the refresh must build on the previous tip, not replace it"

# control 3: without the markers the step fails loudly instead of rewriting anything
git -C "$WORK/origin.git" update-ref refs/heads/other "$(tip)"
git checkout -q -b nomarkers; printf 'no markers here\n' > README.md; git add README.md; git commit -qm x; git push -q -f origin nomarkers:main 2>&1 | quiet; git checkout -q main
t=$(tip)
GITHUB_REPOSITORY=o/rvb bash "$REPO_ROOT/.github/scripts/update_readme.sh" > "$WORK/nm.log" 2>&1; rc=$?
[ "$rc" != 0 ] || fail "a README without markers must fail the step, not pass as up to date: $(tail -3 "$WORK/nm.log")"
grep -q "markers" "$WORK/nm.log" || fail "the failure should say why: $(tail -3 "$WORK/nm.log")"
[ "$(tip)" = "$t" ] || fail "a README without markers must not be changed"
echo "UPDATE README TESTS: PASS"
