#!/usr/bin/env bash
# Regression test for how a `github` download source reports versions (get_github_vers) and for
# the asset-name version parser it shares with the archive source.
#
# The bug this pins: for a release-per-package layout (tag == package name, assets named
# <pkg>-<version>-<arch>.apk) the tag was returned as the version, so "latest" resolved to the
# package id and every build of that app failed with "No compatible patches ... vcom.x.y".
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
# shellcheck disable=SC1091
source scripts/utils.sh >/dev/null 2>&1
fail() { echo "FAIL: $*"; exit 1; }

assets=$'com.instagram.android-428.0.0.1-arm64-v8a.apk\ncom.instagram.android-427.1.0.9-arm64-v8a.apk\ncom.instagram.android-427.1.0.9-123456-arm-v7a.apk\ncom.instagram.android-nightly-all.apk'

# release-per-package: versions come from the asset names (versionCode and arch stripped)
__GITHUB_TAG__=com.instagram.android __GITHUB_RESP__=$assets pkg_name=com.instagram.android
got=$(get_github_vers | tr '\n' ' ')
[ "$got" = "428.0.0.1 427.1.0.9 427.1.0.9 nightly " ] || fail "release-per-package versions were: '$got'"
# the highest of them is what the engine picks for "latest"
[ "$(get_github_vers | get_highest_ver)" = "428.0.0.1" ] || fail "highest version"

# a raw store download kept under its own name (the real shape of a self-hosted release) says nothing
# about its version: it must contribute nothing, never a version made of the file name
__GITHUB_TAG__=com.instagram.android pkg_name=com.instagram.android
__GITHUB_RESP__=$'com.instagram.android-384510833_2dpi_9feat_3919c8a7e7a3d863f8881e4cfef992a7_apkmirror.com.apkm'
[ -z "$(get_github_vers)" ] || fail "an assets-only-by-store-name release must report no version, got '$(get_github_vers)'"
# ...while a grammar-named asset next to it still counts
__GITHUB_RESP__+=$'\ncom.instagram.android-428.0.0.1-arm64-v8a.apk'
[ "$(get_github_vers)" = "428.0.0.1" ] || fail "only the grammar-named asset may count, got '$(get_github_vers)'"

# the predicate the source loops use to refuse a release-per-package as a version authority
__GITHUB_TAG__=com.x pkg_name=com.x; _github_release_per_package || fail "tag == pkg is a release-per-package"
__GITHUB_TAG__=v1.0 pkg_name=com.x; _github_release_per_package && fail "an ordinary tag is not"
__GITHUB_TAG__=com.x; unset pkg_name; _github_release_per_package && fail "no package name known: not decidable, so not"
__GITHUB_TAG__=com.instagram.android pkg_name=com.instagram.android __GITHUB_RESP__=$assets

# control 1: an ordinary release is still its tag, minus the v
__GITHUB_TAG__=v1.2.3 __GITHUB_RESP__=$'app-1.2.3-all.apk' pkg_name=com.x
[ "$(get_github_vers)" = "1.2.3" ] || fail "ordinary release must report its tag"
# control 2: with no package name known (the watcher) the tag is reported as before
__GITHUB_TAG__=com.instagram.android __GITHUB_RESP__=$assets
unset pkg_name
[ "$(get_github_vers)" = "com.instagram.android" ] || fail "without a package name the tag must be reported"

# the archive source reads the same names the same way (it now shares the parser)
__ARCHIVE_RESP__=$assets
[ "$(get_archive_vers | head -1)" = "428.0.0.1" ] || fail "archive versions"
echo "GITHUB VERSION TESTS: PASS"
