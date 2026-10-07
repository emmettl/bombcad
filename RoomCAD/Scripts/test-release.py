"""Exercise RoomCAD release validation and failure handling without signing or uploading anything."""

import argparse
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("release", Path(__file__).with_name("release.py"))
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.info = {"CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1",
                     "CFBundleIdentifier": "dev.roomcad.RoomCAD", "LSMinimumSystemVersion": "15.0"}

    def test_metadata_rejects_unsafe_names_and_wrong_baseline(self):
        self.assertEqual(release.metadata(self.info)["version"], "0.1.0")
        for key, value in [("CFBundleShortVersionString", "../0.1"), ("CFBundleVersion", "0"),
                           ("LSMinimumSystemVersion", "26.0"), ("CFBundleIdentifier", "")]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                release.metadata({**self.info, key: value})

    def test_only_an_unambiguous_developer_id_is_accepted(self):
        fingerprint = "A" * 40
        development = f'1) {fingerprint} "Apple Development: Example"'
        with self.assertRaises(ValueError):
            release.choose_identity(development, None)
        identity = f'1) {fingerprint} "Developer ID Application: Example (TEAM)"'
        self.assertEqual(release.choose_identity(identity, None), fingerprint)
        duplicate = identity + '\n2) ' + "B" * 40 + ' "Developer ID Application: Other (OTHER)"'
        with self.assertRaises(ValueError):
            release.choose_identity(duplicate, None)
        self.assertEqual(release.choose_identity(duplicate, fingerprint), fingerprint)

    def test_checksum_can_be_verified_in_the_download_directory(self):
        archive = self.root / "RoomCAD-0.1.0-macos-arm64.zip"
        archive.write_bytes(b"fixture")
        release.write_checksums(archive, {"version": "0.1.0", "notarized": True})
        manifest = json.loads(archive.with_suffix(".json").read_text())
        self.assertEqual(archive.with_suffix(".zip.sha256").read_text(),
                         manifest["sha256"] + "  " + archive.name + "\n")
        self.assertTrue(manifest["notarized"])

    def test_rejected_notarization_never_produces_a_release_archive(self):
        self.make_app()
        calls = []

        def command(*arguments, capture=False):
            calls.append(arguments)
            if arguments[0] == "lipo":
                return "arm64"
            if arguments[:3] == ("xcrun", "notarytool", "submit"):
                return '{"id":"test-submission","status":"Invalid"}'
            return ""

        args = argparse.Namespace(command="prepare", identity="A" * 40, notary_profile="test")
        with patch.object(release, "ROOT", self.root), patch.object(release, "run", command), \
                patch.object(release, "preflight", return_value=(args.identity, release.metadata(self.info))):
            with self.assertRaisesRegex(ValueError, "Notarization was not accepted"):
                release.release(args)
        self.assertFalse(any(call[:2] == ("xcrun", "stapler") for call in calls))
        self.assertFalse(list((self.root / "dist").glob("RoomCAD-*.zip")))
        self.assertEqual(json.loads((self.root / "dist/notarization.json").read_text())["status"], "Invalid")

    def test_release_archive_is_created_only_after_stapling_and_gatekeeper_acceptance(self):
        self.complete_pipeline(gatekeeper_accepts=True)

    def test_gatekeeper_failure_never_creates_the_release_archive(self):
        self.complete_pipeline(gatekeeper_accepts=False)

    def test_an_app_without_its_recordings_is_never_signed(self):
        self.make_app()
        (self.root / "dist/RoomCAD.app" / release.REQUIRED[0]).unlink()
        self.assert_never_signed("files every copy needs")

    def test_an_app_without_its_licences_is_never_signed(self):
        for path in ["Contents/Resources/LICENSE", "Contents/Resources/THIRD-PARTY-NOTICES.md"]:
            with self.subTest(path=path):
                self.make_app()
                (self.root / "dist/RoomCAD.app" / path).unlink()
                self.assert_never_signed("files every copy needs")

    def assert_never_signed(self, reason):
        calls = []

        def command(*arguments, capture=False):
            calls.append(arguments)
            return "arm64" if arguments[0] == "lipo" else ""

        args = argparse.Namespace(command="prepare", identity="A" * 40, notary_profile="test")
        with patch.object(release, "ROOT", self.root), patch.object(release, "run", command), \
                patch.object(release, "preflight", return_value=(args.identity, release.metadata(self.info))):
            with self.assertRaisesRegex(ValueError, reason):
                release.release(args)
        self.assertFalse(any(call[0] == "codesign" for call in calls))

    def make_app(self):
        app = self.root / "dist/RoomCAD.app"
        (app / "Contents").mkdir(parents=True, exist_ok=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(self.info))
        for path in release.REQUIRED:
            (app / path).parent.mkdir(parents=True, exist_ok=True)
            (app / path).write_text("fixture")

    def complete_pipeline(self, gatekeeper_accepts):
        self.make_app()
        calls = []

        def command(*arguments, capture=False):
            calls.append(arguments)
            if arguments[0] == "lipo":
                return "arm64"
            if arguments[:3] == ("xcrun", "notarytool", "submit"):
                return '{"id":"test-submission","status":"Accepted"}'
            if arguments[0] == "spctl" and not gatekeeper_accepts:
                raise subprocess.CalledProcessError(1, arguments)
            if arguments[0] == "ditto":
                Path(arguments[-1]).write_bytes(b"test archive")
            return ""

        args = argparse.Namespace(command="prepare", identity="A" * 40, notary_profile="test")
        with patch.object(release, "ROOT", self.root), patch.object(release, "run", command), \
                patch.object(release, "preflight", return_value=(args.identity, release.metadata(self.info))):
            if gatekeeper_accepts:
                release.release(args)
            else:
                with self.assertRaises(subprocess.CalledProcessError):
                    release.release(args)
        archive = self.root / "dist/RoomCAD-0.1.0-macos-arm64.zip"
        self.assertEqual(archive.exists(), gatekeeper_accepts)
        self.assertTrue(any(call[:3] == ("xcrun", "stapler", "validate") for call in calls))
        if gatekeeper_accepts:
            self.assertEqual(calls[-1][0], "ditto")
            self.assertTrue(json.loads(archive.with_suffix(".json").read_text())["notarized"])
            subprocess.run(["shasum", "-a", "256", "-c", archive.name + ".sha256"],
                           cwd=archive.parent, check=True, capture_output=True)


if __name__ == "__main__":
    unittest.main()
