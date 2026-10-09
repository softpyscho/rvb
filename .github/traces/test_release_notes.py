#!/usr/bin/env python3
"""Offline tests for the release-notes / Obtainium / mirror-manifest tooling.

    python3 .github/traces/test_release_notes.py

Covers .github/scripts/{generate_release_notes,obtainium,build_make_manifest}.py, the Telegram
relay of the release body, and the app configuration (configs/patches) they are generated from. No network.
As everywhere in this repo, an absence assertion is paired with a control that shows the same
harness producing the thing in the other case.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from urllib.parse import unquote, urlparse

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / ".github" / "scripts"
CONFIG_PATCHES = ROOT / "configs" / "patches"
REPO = "softpyscho/rvb"
sys.path.insert(0, str(SCRIPTS))

import build_make_manifest  # noqa: E402,F401  (import check only; run as a script below)
import generate_release_notes as grn  # noqa: E402
import obtainium  # noqa: E402


def decode_link(link):
    """redirect link -> (deep link, entry dict, settings dict). One percent-decode, as the
    redirect page does: the deep link carries the app's JSON as is."""
    assert link.startswith(obtainium.REDIRECT_BASE), link[:80]
    deep = unquote(link[len(obtainium.REDIRECT_BASE):])
    assert deep.startswith("obtainium://app/"), deep[:60]
    entry = json.loads(deep[len("obtainium://app/"):])
    return deep, entry, json.loads(entry["additionalSettings"])


def info(name, display, pkg, **kw):
    base = {"exts": ["arm64-v8a.apk"], "name": name, "arch": "", "version": "1.0", "patches": "", "changelog": "",
            "package_name": pkg, "display_name": display, "patches_source": "", "brand": "", "variant": "",
            "sub_variant": "", "file": "", "applied_patches": []}
    base.update(kw)
    return base


FIXTURE = {
    "Reddit": info("reddit-morphe", "Reddit", "com.reddit.frontpage", version="2026.40.0",
                   patches="MorpheApp/patches-1.20.0.mpp", patches_source="MorpheApp/morphe-patches",
                   changelog="https://github.com/MorpheApp/morphe-patches/releases/tag/v1.20.0",
                   applied_patches=["Hide ads", "Custom branding name for Reddit"]),
    "Twitter": info("twitter-piko", "Twitter", "com.twitter.android", version="11.5",
                    patches="crimera/patches-3.0.mpp", patches_source="crimera/piko",
                    changelog="https://github.com/crimera/piko/releases/tag/v3.0"),
    "Bitget": info("bitget", "Bitget", "com.bitget.exchange", version="9.1", brand="Mirror"),
    "Duck-Detector": info("duck-detector", "Duck Detector", "com.eltavine.duckdetector", version="nightly",
                          exts=["all.apk"], brand="Mirror", file="Duck.Detector-nightly-all.apk"),
}
FIXTURE_FILES = ["reddit-morphe-v2026.40.0-arm64-v8a.apk", "twitter-piko-v11.5-arm64-v8a.apk",
                 "bitget-v9.1-arm64-v8a.apk", "Duck.Detector-nightly-all.apk"]
ENV = {"NEXT_VER_CODE": "260142", "GITHUB_REPOSITORY": REPO}


class Engine(unittest.TestCase):
    def test_slug_matches_the_engine(self):
        """obtainium.slug is a second copy of utils.sh:resolve_slug; run both on awkward input."""
        cases = ["Reddit", "Mix Archive", "Amazon-Prime-Video", "  Padded  ", "Disney+", "A/B.c", "Prime Video (TV)",
                 "ReVanced Advanced", "x", "--lead-and-trail--", "Duck.Detector"]
        for text in cases:
            out = subprocess.run(["bash", "-c", 'source scripts/utils.sh >/dev/null 2>&1; resolve_slug "$1"', "_", text],
                                 cwd=ROOT, capture_output=True, text=True).stdout.strip()
            self.assertEqual(obtainium.slug(text), out, f"slug mismatch for {text!r}")


class Obtainium(unittest.TestCase):
    def test_deep_link_roundtrip_and_settings(self):
        entry = obtainium.app_entry("com.x", "X", REPO, obtainium.apk_regex("x-morphe", "arm64-v8a"), prerelease=False)
        _, got, settings = decode_link(obtainium.redirect_link(entry))
        self.assertEqual((got["id"], got["url"], got["author"]), ("com.x", f"https://github.com/{REPO}", "softpyscho"))
        self.assertIs(settings["versionDetection"], False, "release tags are build numbers")
        self.assertIs(settings["fallbackToOlderReleases"], True)
        self.assertIs(settings["includePrereleases"], False)
        self.assertIs(settings["autoApkFilterByArch"], False)
        # control: the pre-release channel flips exactly that one switch
        beta = json.loads(obtainium.app_entry("com.x", "X", REPO, "^x$", prerelease=True)["additionalSettings"])
        self.assertIs(beta["includePrereleases"], True)

    def test_each_filter_selects_only_its_own_app(self):
        """One repository holds every app, so the filter is the whole identification."""
        specs = obtainium.specs_from_configs(str(CONFIG_PATCHES))
        # add the classic collision: a name that is a prefix of another app's name
        extra = [dict(specs[0], key="WA", prefix="whatsapp", arch="arm64-v8a", mirror=True, keep_filename=False),
                 dict(specs[0], key="WAB", prefix="whatsapp-business", arch="arm64-v8a", mirror=True, keep_filename=False)]
        specs = [s for s in specs if not s["keep_filename"]] + extra
        files = {s["key"]: f"{s['prefix']}-v1.2.3-{s['arch']}.apk" for s in specs}
        for s in specs:
            rx = re.compile(obtainium.apk_regex(s["prefix"], s["arch"]))
            matched = [k for k, f in files.items() if rx.match(f)]
            self.assertEqual(matched, [s["key"]], f"{s['key']}'s filter matched {matched}")
        # control: the filter is not simply matching everything / nothing
        self.assertIsNone(re.compile(obtainium.apk_regex("bitget", "arm64-v8a")).match("bitget-v1-arm-v7a.apk"))
        self.assertIsNotNone(re.compile(obtainium.apk_regex("bitget", "all")).match("bitget-v1-universal.apk"))
        self.assertIsNotNone(re.compile(obtainium.exact_regex("Duck.Detector-nightly-all.apk")).match("Duck.Detector-nightly-all.apk"))
        self.assertIsNone(re.compile(obtainium.exact_regex("Duck.Detector-nightly-all.apk")).match("DuckXDetector-nightly-all.apk"))

    def test_kept_file_filter_survives_the_next_build(self):
        """A kept file name embeds a date/hash, so the filter must match the next build's name."""
        rx = re.compile(obtainium.kept_file_regex("Duck.Detector-2026.10.06-82566ffa96bb.apk"))
        self.assertIsNotNone(rx.match("Duck.Detector-2026.10.07-0a1b2c3d4e5f.apk"), "next nightly")
        self.assertIsNone(rx.match("DuckXDetector-2026.10.07-0a1b2c3d4e5f.apk"), "the '.' is literal")
        self.assertIsNone(rx.match("bitget-v9.1-arm64-v8a.apk"), "another app's file")
        self.assertIsNone(rx.match("Duck.Detector-2026.10.07-0a1b2c3d4e5f.apk.sig"), "anchored at the end")
        # control: a name with nothing stable to split on stays exact, so it cannot over-match
        exact = re.compile(obtainium.kept_file_regex("DuckDetector_nightly_build.apk"))
        self.assertIsNotNone(exact.match("DuckDetector_nightly_build.apk"))
        self.assertIsNone(exact.match("DuckDetector_nightly_build2.apk"))

    def test_release_notes_use_the_stable_filter_for_a_dated_kept_file(self):
        dated = "Duck.Detector-2026.10.06-82566ffa96bb.apk"
        info_map = {"Duck-Detector": dict(FIXTURE["Duck-Detector"], file=dated)}
        md = grn.render(info_map, [dated], ENV)
        link = re.search(r"\((https://apps\.obtainium[^)]+)\)", md).group(1)
        flt = re.compile(decode_link(link)[2]["apkFilterRegEx"])
        self.assertIsNotNone(flt.match(dated))
        self.assertIsNotNone(flt.match("Duck.Detector-2026.10.07-aaaaaaaaaaaa.apk"), "the link must keep working next build")

    def test_beta_pool_apps_include_prereleases(self):
        specs = {s["key"]: s for s in obtainium.specs_from_configs(str(CONFIG_PATCHES))}
        self.assertTrue(specs["Instagram"]["prerelease"])
        # Battery Guru is on the stable patches: the beta line of its source is months behind and
        # supports no current version, so it must not be offered as a pre-release (controls)
        self.assertFalse(specs["Battery-Guru"]["prerelease"])
        self.assertFalse(specs["Reddit"]["prerelease"])
        for key in ("Instagram", "Battery-Guru", "Reddit"):
            _, _, st = decode_link(obtainium.redirect_link(obtainium.entry_for_spec(specs[key], REPO)))
            self.assertEqual(st["includePrereleases"], specs[key]["prerelease"], key)

    def test_disabled_apps_are_not_offered(self):
        keys = {s["key"] for s in obtainium.specs_from_configs(str(CONFIG_PATCHES))}
        self.assertNotIn("WhatsApp", keys)
        self.assertNotIn("WhatsApp-Business", keys)
        self.assertIn("Bitget", keys)  # control: enabled mirror apps are


class ReleaseNotes(unittest.TestCase):
    def render(self, info_map=FIXTURE, files=FIXTURE_FILES, env=ENV):
        return grn.render(info_map, files, env)

    def test_groups_links_and_obtainium(self):
        md = self.render()
        self.assertIn("### 🧩 MorpheApp/morphe-patches ([v1.20.0](https://github.com/MorpheApp/morphe-patches/releases/tag/v1.20.0))", md)
        self.assertIn("### 🧩 crimera/piko", md)
        self.assertIn("### 📦 Mirrored apps (stock, unmodified)", md)
        self.assertLess(md.index("crimera/piko"), md.index("Mirrored apps"), "mirrored apps come last")
        self.assertIn("(https://github.com/softpyscho/rvb/releases/download/260142/reddit-morphe-v2026.40.0-arm64-v8a.apk)", md)
        self.assertIn("* **Reddit** `v2026.40.0`", md)
        self.assertIn("* **Duck Detector** `nightly`", md)  # no "v" in front of a word
        self.assertIn("2 patches applied", md)
        # every Obtainium link decodes to the right app and a filter matching its release file
        links = re.findall(r"\[[^\]]+\]\((https://apps\.obtainium\.imranr\.dev/redirect\?r=[^)]+)\)", md)
        self.assertEqual(len(links), 4)
        by_id = {}
        for link in links:
            _, entry, st = decode_link(link)
            by_id[entry["id"]] = (entry, st)
        for pkg, fname in (("com.reddit.frontpage", FIXTURE_FILES[0]), ("com.twitter.android", FIXTURE_FILES[1]),
                           ("com.bitget.exchange", FIXTURE_FILES[2]), ("com.eltavine.duckdetector", FIXTURE_FILES[3])):
            entry, st = by_id[pkg]
            rx = re.compile(st["apkFilterRegEx"])
            self.assertEqual([f for f in FIXTURE_FILES if rx.match(f)], [fname], pkg)
            self.assertIs(st["includePrereleases"], False)

    def test_prerelease_build_is_flagged_and_links_include_prereleases(self):
        md = self.render(env=dict(ENV, IS_PRERELEASE="true"))
        self.assertIn("pre--release", md)
        self.assertIn("[!WARNING]", md)
        link = re.search(r"\((https://apps\.obtainium[^)]+)\)", md).group(1)
        self.assertIs(decode_link(link)[2]["includePrereleases"], True)
        stable = self.render()  # control
        self.assertNotIn("[!WARNING]", stable)

    def test_no_upstream_defaults_leak(self):
        md = self.render()
        for needle in ("nullcpy", "rvb27", "fahim", "t.me/"):
            self.assertNotIn(needle, md)
        # control: a link that is configured is rendered
        md2 = self.render(env=dict(ENV, RELEASE_NOTES_TG_LINK="https://t.me/mine", RELEASE_NOTES_DONATE_LINK="https://d.example"))
        self.assertIn("[Group](https://t.me/mine)", md2)
        self.assertIn("[Donate](https://d.example)", md2)

    def test_local_build_has_no_dead_links(self):
        md = self.render(env={})
        self.assertNotIn("apps.obtainium", md, "no repository, so no Obtainium link can be right")
        self.assertIn("(./build/reddit-morphe-v2026.40.0-arm64-v8a.apk)", md)

    def test_two_arches_get_two_links_each(self):
        two = {"Reddit": dict(FIXTURE["Reddit"], exts=["arm64-v8a.apk", "arm-v7a.apk"])}
        files = ["reddit-morphe-v2026.40.0-arm64-v8a.apk", "reddit-morphe-v2026.40.0-arm-v7a.apk"]
        md = self.render(two, files)
        self.assertIn("[arm64](", md)
        self.assertIn("[arm-v7a](", md)
        links = re.findall(r"\((https://apps\.obtainium[^)]+)\)", md)
        filters = [decode_link(l)[2]["apkFilterRegEx"] for l in links]
        self.assertEqual(len(filters), 2)
        self.assertEqual(sorted(re.compile(f).match(fn) is not None for f in filters for fn in files).count(True), 2)

    def test_app_without_files_is_left_out(self):
        md = self.render(FIXTURE, FIXTURE_FILES[:1])
        self.assertIn("Reddit", md)
        self.assertNotIn("Bitget", md)
        self.assertNotIn("Mirrored apps", md)


class Telegram(unittest.TestCase):
    def relay(self, body):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            (d / "build.md").write_text(body, encoding="utf-8")
            (d / "stub").mkdir()
            stub = d / "stub" / "curl"
            stub.write_text('#!/usr/bin/env bash\nfor a in "$@"; do case "$a" in text=*) printf "%s\\n" "${a#text=}" >> "$TG_LOG";; esac; done\n')
            stub.chmod(0o755)
            env = dict(os.environ, PATH=f"{d / 'stub'}:{os.environ['PATH']}", TG_LOG=str(d / "log"), TG_TOKEN="t",
                       TG_CHAT_ID="1", NEXT_VER_CODE="260142", TITLE_SUFFIX="")
            (d / "log").write_text("")
            subprocess.run(["bash", str(SCRIPTS / "build_notify_telegram.sh")], cwd=d, env=env, check=True, capture_output=True)
            return (d / "log").read_text(encoding="utf-8")

    def test_github_only_markup_is_dropped_and_apps_survive(self):
        body = grn.render(FIXTURE, FIXTURE_FILES, dict(ENV, IS_PRERELEASE="true"))
        # control: the raw body does carry everything the relay must strip
        for needle in ('<div align="center">', "![build](", "> [!TIP]", "apps.obtainium.imranr.dev", "<details>"):
            self.assertIn(needle, body)
        msg = self.relay(body)
        for needle in ("div align", "![", "[!TIP]", "[!WARNING]", "obtainium.imranr", "details>", "&lt;details"):
            self.assertNotIn(needle, msg, needle)
        for needle in ("<b>Reddit</b>", "<b>Duck Detector</b>", "MorpheApp/morphe-patches", "Mirrored apps"):
            self.assertIn(needle, msg, needle)


class MirrorManifest(unittest.TestCase):
    def run_manifest(self, build_info, files):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            (d / "build").mkdir()
            for f in files:
                (d / "build" / f).write_bytes(b"x")
            (d / "build.json").write_text(json.dumps(build_info))
            subprocess.run([sys.executable, str(SCRIPTS / "build_make_manifest.py")], cwd=d, check=True, capture_output=True,
                           env=dict(os.environ, NEXT_VER_CODE="260142", IS_PRERELEASE="false"))
            return json.loads((d / "temp" / "manifest" / "build.json").read_text())["files"]

    def test_kept_filename_is_found_by_the_recorded_name(self):
        files = self.run_manifest(FIXTURE, FIXTURE_FILES)
        self.assertEqual(sorted(files), sorted(FIXTURE_FILES))
        duck = files["Duck.Detector-nightly-all.apk"]
        self.assertEqual((duck["arch"], duck["appName"], duck["brandName"], duck["fileType"]), ("all", "Duck Detector", "Mirror", "APK"))
        self.assertEqual(duck["patchSources"], [])
        self.assertEqual(files["reddit-morphe-v2026.40.0-arm64-v8a.apk"]["arch"], "arm64")  # untouched path
        self.assertEqual(files["bitget-v9.1-arm64-v8a.apk"]["brandName"], "Mirror")
        self.assertEqual(files["bitget-v9.1-arm64-v8a.apk"]["packageName"], "com.bitget.exchange")

    def test_without_the_recorded_name_the_file_is_not_matched(self):
        """Negative control for the test above: `file` is what makes the entry findable."""
        no_file = {k: dict(v, file="") if k == "Duck-Detector" else v for k, v in FIXTURE.items()}
        files = self.run_manifest(no_file, FIXTURE_FILES)
        self.assertNotIn("Duck.Detector-nightly-all.apk", files)


class AppsSection(unittest.TestCase):
    """The README's apps section: the apkforge layout, filled from the build manifests."""

    SPECS = {s["key"]: s for s in obtainium.specs_from_configs(str(CONFIG_PATCHES))}

    def manifest(self, files):
        return {"schema": 1, "kind": "archive", "files": files}

    def load(self, *docs):
        with tempfile.TemporaryDirectory() as d:
            paths = []
            for i, doc in enumerate(docs):
                (Path(d) / f"{i}.json").write_text(json.dumps(doc))
                paths.append(str(Path(d) / f"{i}.json"))
            paths.append(str(Path(d) / "missing.json"))  # an absent manifest is skipped, not fatal
            return obtainium.load_manifest_data(paths)

    def test_manifest_data_takes_the_newest_apk_of_each_app(self):
        data = self.load(self.manifest({
            "reddit-morphe-v1-arm64-v8a.apk": {"name": "reddit-morphe", "fileType": "APK", "version": "1", "appliedPatches": ["A"], "publishedAt": "2026-01-01T00:00:00Z"},
            "reddit-morphe-v2-arm64-v8a.apk": {"name": "reddit-morphe", "fileType": "APK", "version": "2", "appliedPatches": ["A", "B"], "publishedAt": "2026-02-01T00:00:00Z"},
            "reddit-morphe-module-v9-arm64-v8a.zip": {"name": "reddit-morphe", "fileType": "Module", "version": "9", "appliedPatches": [], "publishedAt": "2027-01-01T00:00:00Z"},
        }))
        got = data["reddit-morphe"]  # not the older, not the module
        self.assertEqual((got["version"], got["applied"]), ("2", ["A", "B"]))
        # a record that predates apkSource says so, instead of passing as "nothing recommended"
        self.assertFalse(got["has_record"])
        self.assertEqual((got["apk_source"], got["recommended"], got["skipped"], got["failed"], got["excluded"]), ("", "", [], [], []))
        new = self.load(self.manifest({"x-v1-arm64-v8a.apk": {
            "name": "x", "fileType": "APK", "version": "1", "appliedPatches": [], "publishedAt": "2026-03-01T00:00:00Z",
            "apkSource": "archive", "recommendedVersion": None, "skippedPatches": [{"name": "P", "reason": "incompatible with a.b 1"}],
            "failedPatches": ["F"], "excludedPatches": ["E"]}}))["x"]
        self.assertTrue(new["has_record"])
        self.assertEqual((new["apk_source"], new["recommended"], new["failed"], new["excluded"]), ("archive", "", ["F"], ["E"]))
        self.assertEqual(new["skipped"][0]["name"], "P")

    def section(self, data=None, keys=None):
        specs = [self.SPECS[k] for k in (keys or self.SPECS)]
        return obtainium.render_apps_section(specs, REPO, data or {})

    def row(self, md, key):
        return next(l for l in md.splitlines() if l.startswith(f"| [![{self.SPECS[key]['display']}]"))

    def test_layout_matches_the_reference(self):
        md = self.section()
        self.assertIn("| App | Version | APK Source | Patches | Obtainium |", md)
        self.assertIn("|:---|:-------:|:----------:|:--------|:---------:|", md)
        self.assertNotIn("| Recommended |", md, "recommended and built share the Version column")
        self.assertIn("| App | Version | APK Source | Obtainium |", md, "the mirrors have no patches column")
        self.assertNotIn("| Arch |", md, "no Arch column anywhere")
        self.assertEqual(md.count("**Version** shows"), 1, "one legend, above the tables")
        self.assertLess(md.index("**Version** shows"), md.index("| App |"))
        self.assertNotIn("Stock Mirror)*", md, "nothing is patched there, so nothing to say about patches")
        self.assertEqual(md.count('<div align="center">'), md.count("</div>"))
        self.assertIn("> **Source:** [`Paresh-Maheshwari/paresh-patches`](https://gitlab.com/Paresh-Maheshwari/paresh-patches) (GitLab)", md)
        self.assertIn("> **Source:** [`MorpheApp/morphe-patches`](https://github.com/MorpheApp/morphe-patches)\n", md)  # GitHub: no suffix
        self.assertIn("> **Source:** Direct stock APK mirrors (Unpatched)", md)
        heads = re.findall(r'### <img src="https://img\.shields\.io/badge/([^-]+)-4500FF', md)
        self.assertEqual(heads[0], "Morpheapp%20%2F%20Morphe%20Patches", "MorpheApp's bundle first")
        self.assertEqual(heads[-1], "Stock%20Mirrors%20%2F%20Unpatched%20APKs", "mirrors last")
        self.assertEqual(heads[1:-1], sorted(heads[1:-1], key=str.lower), "the other sources A-Z")
        self.assertNotIn("---\n\n---", md)
        self.assertFalse(md.rstrip().endswith("---"), "no trailing separator")
        # every row has as many cells as its table's header
        for line in md.splitlines():
            if line.startswith("| [![") and "Add_to_Obtainium" in line:
                cells = len(re.findall(r"(?<!\\)\|", re.sub(r"\([^)]*\)", "", line))) - 1
                self.assertIn(cells, (4, 5), line[:80])

    RECORD = {"has_record": True, "apk_source": "uptodown", "recommended": "2026.39.0", "skipped": [], "failed": [], "excluded": []}

    def test_cells(self):
        data = {"reddit-morphe": dict(self.RECORD, version="2026.39.0", applied=["Hide ads", "App icon", "hide ads 2"]),
                "twitter-morphe": dict(self.RECORD, version="12.19.1-release.0", recommended="12.19.1-release.0", applied=["Only one"], apk_source="apkmirror"),
                "bitget": {"version": "2.94.3", "applied": [], "has_record": True, "apk_source": "apkmirror"}}
        md = self.section(data)
        row = {k: self.row(md, k) for k in ("Reddit", "Twitter", "Truecaller", "Bitget", "Duck-Detector")}
        # patched app with a build: the patches' recommendation and the built version side by side
        self.assertIn("recommended-v2026.39.0-FF4500", row["Reddit"])
        self.assertIn("built-v2026.39.0-FF4500", row["Reddit"])
        self.assertLess(row["Reddit"].index("recommended-"), row["Reddit"].index("built-"), "recommended above built")
        self.assertIn("<summary><b>3 patches</b></summary><br>`App icon`<br>`Hide ads`<br>`hide ads 2`", row["Reddit"])
        self.assertIn("⚙️ appName=Reddit", row["Reddit"])
        self.assertIn("(https://play.google.com/store/apps/details?id=com.reddit.frontpage)", row["Reddit"])
        # the one source that supplied it, linked to the page the config names - not all of them
        self.assertIn(f"[Uptodown]({self.SPECS['Reddit']['urls']['uptodown']})", row["Reddit"])
        self.assertNotIn("[APKMirror](", row["Reddit"])
        self.assertNotIn("`arm64-v8a`", row["Reddit"], "no arch cell")
        # singular noun, and a dash in the version is escaped so it stays in the message
        self.assertIn("<b>1 patch</b>", row["Twitter"])
        self.assertIn("built-v12.19.1--release.0-000000", row["Twitter"])
        # no build yet: "auto" is a setting, not a version, so it is never shown as the recommendation
        self.assertNotIn("Auto", row["Truecaller"])
        self.assertIn("*recommended: pending*", row["Truecaller"])
        self.assertIn("*built: pending*", row["Truecaller"])
        self.assertIn("*(pending)*", row["Truecaller"], "APK Source")
        self.assertIn("*(Pending first build)*", row["Truecaller"])
        # stock mirror: one version, a source, no patches column at all
        self.assertIn("version-v2.94.3-", row["Bitget"])
        self.assertNotIn("recommended", row["Bitget"], "nothing to recommend for an unpatched APK")
        self.assertIn("[APKMirror](", row["Bitget"])
        self.assertNotIn("Stock Mirror", row["Bitget"])
        # an app that cannot be a Play listing - a bad package id, or only a GitHub release as its
        # source - links to where the file comes from instead; one with a store source keeps Play
        self.assertIn("play.google.com/store/apps/details?id=com.bitget.exchange", row["Bitget"])
        self.assertNotIn("play.google.com", row["Duck-Detector"])
        self.assertIn("(https://github.com/eltavine/Duck-Detector-Refactoring/releases/tag/nightly)", row["Duck-Detector"])

    def test_the_source_cell_cites_only_the_source_used(self):
        used = {"instagram-morphe": dict(self.RECORD, version="447.0", recommended="447.0", applied=["x"], apk_source="apkmirror")}
        row = self.row(self.section(used, keys=["Instagram"]), "Instagram")
        self.assertIn("[APKMirror](", row)
        self.assertNotIn("[Uptodown](", row)
        self.assertNotIn("[GitHub](", row)
        # control: the same app has all three configured, so the single citation is a choice
        self.assertGreaterEqual(len(self.SPECS["Instagram"]["urls"]), 3)
        # a source the config has no page for (the cache) is named, not linked; an unknown build says so
        cached = dict(used["instagram-morphe"], apk_source="cache")
        self.assertIn("| Cache |", self.row(self.section({"instagram-morphe": cached}, keys=["Instagram"]), "Instagram"))
        legacy = {"instagram-morphe": {"version": "447.0", "applied": ["x"]}}
        self.assertIn("*(not recorded)*", self.row(self.section(legacy, keys=["Instagram"]), "Instagram"))
        self.assertNotIn("[Uptodown](", self.row(self.section(legacy, keys=["Instagram"]), "Instagram"))

    def test_recommended_and_built_versions_share_one_column(self):
        differs = {"battery-guru-morphe": dict(self.RECORD, version="2.5.0.2", recommended="2.5.0.6", applied=["P"])}
        row = self.row(self.section(differs, keys=["Battery-Guru"]), "Battery-Guru")
        self.assertLess(row.index("recommended-v2.5.0.6-"), row.index("built-v2.5.0.2-"), "recommended above built")
        cell = row.split(" | ")[1]
        self.assertIn("recommended-v2.5.0.6", cell)
        self.assertIn("built-v2.5.0.2", cell)
        self.assertIn("<br>", cell, "stacked in the one cell")
        # a manifest from before the fix may hold every tied version: only the newest is shown
        tied = {"battery-guru-morphe": dict(self.RECORD, version="2.5.0.6", recommended="2.5.0.6\n2.5.0.2-beta1", applied=["P"])}
        r = self.row(self.section(tied, keys=["Battery-Guru"]), "Battery-Guru")
        self.assertIn("recommended-v2.5.0.6-", r)
        self.assertNotIn("%0A", r)
        self.assertNotIn("2.5.0.2", r)
        # the patches name no version: "Any" is shown, not a made-up number
        anyv = {"battery-guru-morphe": dict(self.RECORD, version="1.0", recommended="", applied=["P"])}
        self.assertIn("recommended-Any-", self.row(self.section(anyv, keys=["Battery-Guru"]), "Battery-Guru"))
        # a build from before the record existed: never the config's `auto`, say pending instead
        old = {"battery-guru-morphe": {"version": "1.0", "applied": ["P"]}}
        r = self.row(self.section(old, keys=["Battery-Guru"]), "Battery-Guru")
        self.assertIn("*recommended: pending*", r)
        self.assertIn("built-v1.0-", r)
        self.assertNotIn("Auto", r)
        self.assertNotIn("recommended-Any-", r)

    def test_patches_cell_says_what_was_not_applied(self):
        bg = dict(self.RECORD, version="2.5.0.2", recommended="2.5.0.6", applied=[],
                  skipped=[{"name": "Unlock PRO", "reason": "incompatible with com.paget96.batteryguru 2.5.0.2 (supported: com.paget96.batteryguru 2.4.8.1)"}])
        cell = self.row(self.section({"battery-guru-morphe": bg}, keys=["Battery-Guru"]), "Battery-Guru")
        self.assertIn("<b>0 patches</b> · ⚠️ 1 not applied", cell)
        self.assertIn("⚠️ <b>Skipped</b> — `Unlock PRO` (incompatible with v2.5.0.2)", cell)
        # failed and config-excluded are told apart from skipped
        mixed = dict(self.RECORD, version="1", applied=["A"], skipped=[{"name": "S", "reason": "incompatible with p 1"}],
                     failed=["F1", "F2"], excluded=["E"])
        cell = self.row(self.section({"reddit-morphe": mixed}, keys=["Reddit"]), "Reddit")
        self.assertIn("<b>1 patch</b> · ⚠️ 3 not applied", cell)
        self.assertIn("❌ <b>Failed</b> — `F1`, `F2`", cell)
        self.assertIn("🚫 <b>Excluded by config</b> — `E`", cell)
        # control: nothing wrong -> no warning at all
        clean = dict(self.RECORD, version="1", applied=["A"])
        cell = self.row(self.section({"reddit-morphe": clean}, keys=["Reddit"]), "Reddit")
        for word in ("not applied", "Skipped", "Failed", "Excluded", "⚠️"):
            self.assertNotIn(word, cell)
        # excluding something by choice is not a problem on its own: shown, but not counted as one
        chosen = dict(self.RECORD, version="1", applied=["A"], excluded=["E"])
        cell = self.row(self.section({"reddit-morphe": chosen}, keys=["Reddit"]), "Reddit")
        self.assertIn("Excluded by config", cell)
        self.assertNotIn("not applied", cell)

    def test_an_unbuilt_app_never_shows_the_auto_setting_as_a_version(self):
        # not built yet: pending, and never "Auto" - the setting is not a version
        before = self.row(self.section(keys=["Instagram"]), "Instagram")
        self.assertIn("*built: pending*", before)
        self.assertNotIn("Auto", before)
        built = {"instagram-morphe": dict(self.RECORD, version="450.0", recommended="450.0", applied=["x"])}
        self.assertIn("built-v450.0-", self.section(built, keys=["Instagram"]))

    def test_obtainium_link_is_the_full_app_object_in_the_working_format(self):
        md = self.section(keys=["Reddit"])
        link = re.search(r"\]\((https://apps\.obtainium\.imranr\.dev/redirect\?r=[^)]+)\)", md).group(1)
        deep, entry, settings = decode_link(link)
        self.assertTrue(deep.startswith("obtainium://app/{"), "the app's JSON goes in as is, encoded once overall")
        self.assertEqual(set(entry), {"id", "url", "author", "name", "installedVersion", "latestVersion", "apkUrls", "otherAssetUrls",
                                      "preferredApkIndex", "additionalSettings", "lastUpdateCheck", "pinned", "categories",
                                      "releaseDate", "changeLog", "overrideSource", "allowIdChange", "pendingRepoRenameUrl"})
        self.assertEqual((entry["id"], entry["url"]), ("com.reddit.frontpage", f"https://github.com/{REPO}"))
        self.assertIs(settings["versionDetection"], False)
        # parentheses are encoded so they cannot end a Markdown link early - tested on an entry that has
        # some (an `all` arch filter and a name with a bracketed word), since Reddit's has none
        paren = obtainium.redirect_link(obtainium.app_entry("com.x", "X (beta)", REPO, obtainium.apk_regex("x", "all")))
        self.assertNotIn("(", paren.split("?r=", 1)[1])
        self.assertNotIn(")", paren.split("?r=", 1)[1])
        self.assertEqual(decode_link(paren)[1]["name"], "X (beta)", "and they decode back")
        # control: the same entry with its object cut down is what we must not produce
        self.assertNotEqual(set(entry), {"id", "url", "author", "name", "preferredApkIndex", "additionalSettings"})


class SeedConfig(unittest.TestCase):
    def test_every_configured_app_is_buildable_on_paper(self):
        import compile_patch_configs
        stable, beta = compile_patch_configs.compile_configs(str(CONFIG_PATCHES))  # exits on a duplicate app key
        self.assertEqual(len(stable) + len(beta), 18)
        patch_keys = ("patches-source", "cli-source", "included-patches", "excluded-patches", "exclusive-patches",
                      "inclusive-patches", "patcher-args", "patched-pkg-name", "include-stock")
        for pool in (stable, beta):
            for key, app in pool.items():
                self.assertTrue(app.get("pkg-name"), f"{key}: pkg-name")
                self.assertTrue(any(k.endswith("-dlurl") for k in app), f"{key}: needs a download url")
                if app.get("mirror") is True:
                    for bad in patch_keys:
                        self.assertNotIn(bad, app, f"{key} is mirrored and must not set {bad}")
                    self.assertNotIn("direct-dlurl", app, "a web page is not a direct APK url")
                else:
                    self.assertTrue(app.get("patches-source"), f"{key}: patched apps name their source")
                    self.assertNotIn("keep-filename", app)
        self.assertEqual(set(beta), {"Instagram"})
        self.assertIn("Battery-Guru", stable)
        self.assertEqual(stable["Reddit"]["included-patches"], "'Custom branding name for Reddit'")

    def test_generated_documents_are_in_sync_with_the_config(self):
        specs = obtainium.specs_from_configs(str(CONFIG_PATCHES))
        expected_json = json.dumps(obtainium.import_document(specs, REPO), indent=2, ensure_ascii=False) + "\n"
        self.assertEqual((ROOT / "obtainium-apps.json").read_text(encoding="utf-8"), expected_json,
                         "obtainium-apps.json is stale: run .github/scripts/obtainium.py (see OBTAINIUM.md footer)")
        self.assertEqual((ROOT / "OBTAINIUM.md").read_text(encoding="utf-8"), obtainium.obtainium_page(specs, REPO),
                         "OBTAINIUM.md is stale")
        # The README's apps section carries live build data (versions, applied patches) that CI
        # refreshes, so it cannot be compared byte for byte with a data-less rendering. What must
        # hold is that it lists exactly the configured apps, one group per source, one link each.
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        section = readme[readme.index(obtainium.README_START):readme.index(obtainium.README_END)]
        for s in specs:
            self.assertIn(f"![{s['display']}](https://img.shields.io/badge/", section, f"{s['display']} missing from the README")
        self.assertEqual(section.count("![Add to Obtainium]"), len(specs), "one Obtainium badge per app")
        for source in {s["source"] for s in specs if not s["mirror"]}:
            self.assertIn(f"> **Source:** [`{source}`]", section, f"group for {source} missing")
        self.assertIn("### <img src=\"https://img.shields.io/badge/Stock%20Mirrors", section)
        # control: an app that is not configured is not there, and the comparison can fail
        self.assertNotIn("![WhatsApp](", section)
        self.assertNotEqual(section, obtainium.render_apps_section(specs[:1], REPO))


if __name__ == "__main__":
    unittest.main(verbosity=1)
