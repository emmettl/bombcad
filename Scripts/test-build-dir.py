"""Tests of build-dir.py, which links a checkout's .build to its build folder: python3 Scripts/test-build-dir.py"""

import contextlib
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("build_dir", os.path.join(here, "build-dir.py"))
build_dir = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build_dir)


class BuildDirTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory(prefix="build-dir-test-")
        self.addCleanup(folder.cleanup)
        base = Path(folder.name).resolve()
        self.root, self.builds = base / "worktrees" / "agent-x", base / "data" / "builds"
        self.root.mkdir(parents=True)
        (self.root / "Package.swift").write_text("// a package\n")
        # Both in one temporary folder, so on one disk: the checkout counts as on another one.
        self.same_volume, self.busy = build_dir.same_volume, build_dir.busy
        build_dir.same_volume = lambda a, b: str(Path(a).resolve()).startswith(str(self.builds.parent))
        build_dir.busy = lambda folder, built=None: []
        self.addCleanup(self.restore)

    def restore(self):
        build_dir.same_volume, build_dir.busy = self.same_volume, self.busy

    def ensure(self):
        with contextlib.redirect_stderr(io.StringIO()):
            return build_dir.ensure(self.root, self.builds)

    def test_names_are_stable_and_differ_by_path(self):
        self.assertEqual(build_dir.name(self.root), build_dir.name(str(self.root) + "/"))
        self.assertTrue(build_dir.name(self.root).startswith("agent-x-"))
        self.assertNotEqual(build_dir.name(self.root), build_dir.name(self.root.parent / "other" / "agent-x"))

    def test_no_builds_folder_keeps_build_a_folder(self):
        self.assertEqual(build_dir.builds_folder({"BOMBCAD_BUILDS": ""}), None)
        self.assertEqual(build_dir.builds_folder({"BOMBCAD_BUILDS": "/x/builds"}), Path("/x/builds"))
        with mock.patch.dict(os.environ, {"BOMBCAD_BUILDS": ""}), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(build_dir.ensure(self.root), self.root / ".build")
        self.assertFalse((self.root / ".build").exists())

    def test_a_checkout_on_the_data_disk_keeps_its_own_build(self):
        checkout = self.builds.parent / "perf-wt"
        checkout.mkdir(parents=True)
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(build_dir.ensure(checkout, self.builds), checkout / ".build")
        self.assertFalse((checkout / ".build").is_symlink())

    def test_a_new_checkout_is_linked_and_relinked(self):
        target = self.ensure()
        self.assertEqual(target, self.builds / build_dir.name(self.root))
        link = self.root / ".build"
        self.assertTrue(link.is_symlink())
        self.assertEqual(link.resolve(), target)
        self.assertEqual((target / build_dir.CHECKOUT).read_text().strip(), str(self.root))
        (link / "kept").write_text("object file")
        link.unlink()  # `rm -rf .build`, which drops only the link
        self.assertEqual(self.ensure(), target)
        self.assertEqual((link / "kept").read_text(), "object file")

    def test_a_folder_on_the_boot_disk_is_moved_with_its_links(self):
        link = self.root / ".build"
        (link / "out" / "Products" / "Release").mkdir(parents=True)
        (link / "out" / "Products" / "Release" / "blastbench").write_text("binary")
        (link / "release").symlink_to("out/Products/Release")
        target = self.ensure()
        self.assertTrue(link.is_symlink())
        self.assertEqual((link / "release" / "blastbench").read_text(), "binary")
        self.assertTrue((target / "release").is_symlink())
        self.assertFalse((self.root / build_dir.MOVING).exists())

    def test_a_checkout_holds_what_is_in_it_but_not_its_worktrees(self):
        self.assertTrue(build_dir.inside("/w/bombcad", "/w/bombcad"))
        self.assertTrue(build_dir.inside("/w/bombcad/.build/release/blastbench", "/w/bombcad"))
        self.assertFalse(build_dir.inside("/w/bombcad/.claude/worktrees/agent-x", "/w/bombcad"))
        self.assertFalse(build_dir.inside("/w/bombcad-2", "/w/bombcad"))

    def test_a_busy_folder_is_left_for_next_time(self):
        link = self.root / ".build"
        link.mkdir()
        build_dir.busy = lambda folder, built=None: [12345]
        self.assertEqual(self.ensure(), link)
        self.assertFalse(link.is_symlink())
        build_dir.busy = lambda folder, built=None: []
        self.assertTrue(self.ensure() != link and link.is_symlink())

    def test_a_dangling_link_is_replaced_and_one_made_by_hand_kept(self):
        link = self.root / ".build"
        link.symlink_to(self.root / "nowhere")
        self.assertEqual(self.ensure(), self.builds / build_dir.name(self.root))
        link.unlink()
        mine = self.builds.parent / "build" / "agent-x"
        mine.mkdir(parents=True)
        link.symlink_to(mine)
        self.assertEqual(self.ensure(), mine)
        self.assertEqual(link.resolve(), mine)

    def test_clean_removes_the_folder_and_the_link(self):
        target = self.ensure()
        (target / "kept").write_text("object file")
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(build_dir.clean(self.root, self.builds), 0)
        self.assertFalse(target.exists())
        self.assertFalse((self.root / ".build").is_symlink())

    def test_git_ignores_the_link(self):
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        (self.root / ".gitignore").write_text((Path(here).parent / ".gitignore").read_text())
        self.ensure()
        status = subprocess.run(["git", "-C", str(self.root), "status", "--porcelain", "--untracked-files=all"],
                                check=True, capture_output=True, text=True).stdout
        self.assertNotIn(".build", status)


if __name__ == "__main__":
    unittest.main()
