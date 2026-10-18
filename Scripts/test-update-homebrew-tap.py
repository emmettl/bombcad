"""Exercise the Homebrew tap update without the network: gh is stubbed out."""

import base64
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "update_homebrew_tap", Path(__file__).with_name("update-homebrew-tap.py"))
tap = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(tap)

CASK = '''cask "bombcad" do
  version "0.4.0"
  sha256 "78e1fe35e64abc82305fb383aacf2cf3164e733f2f43d25d8b8914ee06e44826"

  url "https://github.com/emmettl/bombcad/releases/download/v#{version}/BombCAD-#{version}-macos-arm64.zip"
end
'''
DIGEST = "a" * 64


class TapTests(unittest.TestCase):
    def test_version_and_checksum_replaced_once(self):
        text = tap.updated_cask(CASK, "0.5.0", DIGEST)
        self.assertIn('  version "0.5.0"', text)
        self.assertIn(f'  sha256 "{DIGEST}"', text)
        self.assertNotIn("0.4.0", text)
        self.assertIn("v#{version}", text)

    def test_cask_without_single_lines_refused(self):
        for broken in (CASK.replace('  version "0.4.0"\n', ""), CASK + '  sha256 "x"\n'):
            with self.subTest(broken=broken), self.assertRaises(ValueError):
                tap.updated_cask(broken, "0.5.0", DIGEST)

    def test_checksum_must_name_the_release_zip(self):
        good = f"{DIGEST}  BombCAD-0.5.0-macos-arm64.zip\n"
        with patch.object(tap, "gh", return_value=good):
            self.assertEqual(tap.published_sha256("0.5.0"), DIGEST)
        for bad in (f"{DIGEST}  BombCAD-0.4.0-macos-arm64.zip\n", "nothing  here\n",
                    f"{'g' * 64}  BombCAD-0.5.0-macos-arm64.zip\n"):
            with self.subTest(bad=bad), patch.object(tap, "gh", return_value=bad), \
                    self.assertRaises(ValueError):
                tap.published_sha256("0.5.0")

    def test_commit_sends_the_new_cask_against_its_blob(self):
        calls = []

        def fake(*arguments, stdin=None):
            calls.append((arguments, stdin))
            return ""

        with patch.object(tap, "gh", side_effect=fake):
            tap.commit("new cask", "blob123", "0.5.0")
        arguments, stdin = calls[0]
        self.assertIn("PUT", arguments)
        body = json.loads(stdin)
        self.assertEqual(body["sha"], "blob123")
        self.assertEqual(base64.b64decode(body["content"]).decode(), "new cask")
        self.assertEqual(body["message"], "BombCAD 0.5.0")


if __name__ == "__main__":
    unittest.main()
