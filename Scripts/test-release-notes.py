"""Release-note fragments: parsing, refusal of malformed ones, and assembly order."""

import importlib.util
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("release_notes", Path(__file__).with_name("release-notes.py"))
notes = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(notes)


class FragmentTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.folder = Path(self.directory.name)

    def write(self, name, text):
        path = self.folder / name
        path.write_text(text)
        return path

    def test_kinds_parse_and_bad_ones_are_refused(self):
        self.assertEqual(notes.parse(self.write("a.md", "kind: fixed\n\n**A fix.**\n")),
                         ("fixed", "**A fix.**"))
        for text in ("kind: other\n\nx\n", "no kind\n\nx\n", "kind: added\n\n\n"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                notes.parse(self.write("b.md", text))

    def test_assembly_groups_by_kind_in_order(self):
        text = notes.assembled([("fixed", "F1"), ("added", "A1"), ("limitation", "L1"), ("added", "A2")])
        self.assertLess(text.index("## New"), text.index("## Fixed"))
        self.assertLess(text.index("## Fixed"), text.index("## Known limitations"))
        self.assertIn("A1\n\nA2", text)
        self.assertNotIn("## Changed", text)

    def test_fragments_join_the_notes_own_sections(self):
        existing = "# BombCAD 9\n\nIntro.\n\n## New\n\nN0\n\n## Fixed\n\nF0\n"
        text = notes.merged(existing, [("fixed", "F1"), ("added", "A1"), ("limitation", "L1")])
        self.assertEqual(text.count("## New"), 1)
        self.assertEqual(text.count("## Fixed"), 1)
        self.assertIn("N0\n\nA1\n\n## Fixed", text)
        self.assertIn("F0\n\nF1\n", text)
        self.assertLess(text.index("F1"), text.index("## Known limitations"))
        self.assertTrue(text.endswith("L1\n"))
        self.assertEqual(notes.merged(existing, []), existing)

    def test_readme_is_not_a_fragment(self):
        self.write("README.md", "about")
        self.write("x.md", "kind: added\n\nX\n")
        self.assertEqual([p.name for p in notes.fragments(self.folder)], ["x.md"])

    def test_the_repository_fragments_are_well_formed(self):
        for path in notes.fragments():
            notes.parse(path)


if __name__ == "__main__":
    unittest.main()
