#!/usr/bin/env python3
"""Regression test for cleanup-archive-assets.py's plan_prune.

The bug this pins: a mirrored nightly that keeps its source's own name ("Duck.Detector-<date>-
<hash>.apk") was never pruned, so the archive held several, and two from the same day differ only
by a hash. Obtainium takes the highest name, which is the older upload as often as the newer. Such
assets are now kept one per app+arch by upload time, found through the archive manifest; names the
grammar covers keep the 2 newest versions as before.
"""
import importlib.util
import pathlib
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "scripts" / "cleanup-archive-assets.py"
spec = importlib.util.spec_from_file_location("cleanup_archive_assets", SCRIPT)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


def asset(name, created, id_=None):
    return {"name": name, "created_at": created, "id": id_ or abs(hash(name)) % 10**6}


def entry(app_key, arch):
    return {"appKey": app_key, "arch": arch}


# the real archive, 2026-10-11: the lower-sorting hash is the NEWER upload
DUCK = [
    asset("Duck.Detector-2026.10.06-82566ffa96bb.apk", "2026-10-06T14:45:23Z"),
    asset("Duck.Detector-2026.10.09-6125c4271db5.apk", "2026-10-09T08:41:11Z"),
    asset("Duck.Detector-2026.10.11-78aabb41c513.apk", "2026-10-11T09:05:00Z"),
    asset("Duck.Detector-2026.10.11-40c8a9a3dbb8.apk", "2026-10-11T19:50:00Z"),
]
DUCK_MANIFEST = {a["name"]: entry("duckdetector", "all") for a in DUCK}


def names(pairs):
    return sorted(a["name"] for _, a in pairs)


class PlanPrune(unittest.TestCase):
    def test_own_names_keep_only_the_newest_upload(self):
        kept, deleted = mod.plan_prune(DUCK, DUCK_MANIFEST)
        self.assertEqual(names(kept), ["Duck.Detector-2026.10.11-40c8a9a3dbb8.apk"])
        self.assertEqual(len(deleted), 3)
        # control: the older same-day file sorts HIGHER by name, which is why the name cannot decide
        older, newer = "Duck.Detector-2026.10.11-78aabb41c513.apk", "Duck.Detector-2026.10.11-40c8a9a3dbb8.apk"
        self.assertGreater(older, newer)
        self.assertIn(older, names(deleted))

    def test_an_asset_the_manifest_does_not_know_is_left_alone(self):
        manifest = {k: v for k, v in DUCK_MANIFEST.items() if "40c8a9a3dbb8" not in k}
        kept, deleted = mod.plan_prune(DUCK, manifest)
        self.assertNotIn("Duck.Detector-2026.10.11-40c8a9a3dbb8.apk", names(kept) + names(deleted))
        # control: the three it does know are still pruned to one
        self.assertEqual(len(kept), 1)
        self.assertEqual(len(deleted), 2)

    def test_an_unreadable_manifest_deletes_nothing(self):
        for manifest in ({}, None):
            kept, deleted = mod.plan_prune(DUCK, manifest)
            self.assertEqual((kept, deleted), ([], []))

    def test_apps_and_architectures_are_pruned_separately(self):
        a = [asset("Other-2026.10.11-aaa.apk", "2026-10-11T01:00:00Z"), asset("Other-2026.10.10-bbb.apk", "2026-10-10T01:00:00Z"),
             asset("Other-2026.10.11-ccc-arm64.apk", "2026-10-11T02:00:00Z")]
        manifest = {a[0]["name"]: entry("other", "all"), a[1]["name"]: entry("other", "all"), a[2]["name"]: entry("other", "arm64-v8a")}
        manifest.update(DUCK_MANIFEST)
        kept, deleted = mod.plan_prune(a + DUCK, manifest)
        self.assertEqual(names(deleted).count("Other-2026.10.10-bbb.apk"), 1)
        self.assertIn("Other-2026.10.11-aaa.apk", names(kept))
        self.assertIn("Other-2026.10.11-ccc-arm64.apk", names(kept), "another arch is its own group")
        self.assertIn("Duck.Detector-2026.10.11-40c8a9a3dbb8.apk", names(kept), "and so is another app")

    def test_grammar_names_still_keep_two_versions(self):
        a = [asset("reddit-morphe-v2026.39.0-arm64-v8a.apk", "2026-10-01T00:00:00Z"),
             asset("reddit-morphe-v2026.40.0-arm64-v8a.apk", "2026-10-05T00:00:00Z"),
             asset("reddit-morphe-v2026.41.0-arm64-v8a.apk", "2026-10-09T00:00:00Z"),
             asset("warp-morphe-v6.38.9-arm64-v8a.apk", "2026-10-09T00:00:00Z")]
        kept, deleted = mod.plan_prune(a, {})
        self.assertEqual(names(deleted), ["reddit-morphe-v2026.39.0-arm64-v8a.apk"])
        self.assertEqual(len(kept), 3)

    def test_a_manifest_entry_does_not_shorten_a_grammar_group(self):
        # a grammar-named file is never regrouped by the manifest: control for the own-name rule
        a = [asset("reddit-morphe-v2026.40.0-arm64-v8a.apk", "2026-10-05T00:00:00Z"),
             asset("reddit-morphe-v2026.41.0-arm64-v8a.apk", "2026-10-09T00:00:00Z")]
        manifest = {x["name"]: entry("reddit", "arm64-v8a") for x in a}
        kept, deleted = mod.plan_prune(a, manifest)
        self.assertEqual((len(kept), len(deleted)), (2, 0))


if __name__ == "__main__":
    unittest.main()
