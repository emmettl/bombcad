"""narrow_access.py's reading of the compiler's errors, on made-up sources and build output.

    python3 Scripts/split/test-narrow-access.py
"""

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import narrow_access as na  # noqa: E402

MODEL = """public struct Layout {
    package var cells: Int
    package init(cells: Int) { self.cells = cells }
    package static func make(grid: Int, bodies: Int) -> Layout { Layout(cells: grid) }
    package static func make(grid: Int, footprints: Int) -> Layout { Layout(cells: grid) }
}

package struct Hidden {
    package var x: Int
}

public struct Recorder {
    public package(set) var count = 0
    package func coreRange(cell: Double) -> Double { cell }
}
"""


class NeededTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.model = root / "Model.swift"
        self.model.write_text(MODEL)
        self.user = root / "User.swift"
        self.user.write_text("let range = 1.0\nlet a = coreRange(cell: 2)\nlet l = Layout.make(grid: 1, footprints: 2)\n")
        self.edits = na.package_edits(self.model)

    def tearDown(self):
        self.temp.cleanup()

    def given_back(self, *lines):
        found, unexplained = na.needed(list(lines), self.edits, "package")
        return {self.edits[k].qualified + (f"({self.edits[k].labels})" if self.edits[k].labels else "")
                for k in found}, unexplained

    def test_edits(self):
        self.assertEqual(len(self.edits), 8)
        setter = next(e for e in self.edits if e.name == "count")
        self.assertEqual((setter.wide, setter.narrow), ("package(set)", "internal(set)"))

    def test_note_by_qualified_name(self):
        found, _ = self.given_back(
            f"{self.user}:1:9: error: 'Layout' initializer is inaccessible due to 'internal' protection level",
            "Model.Layout.init:3:10: note: 'init(cells:)' declared here")
        self.assertEqual(found, {"Layout.init(cells:)"})

    def test_note_by_place(self):
        found, _ = self.given_back(
            f"{self.user}:1:9: error: 'x' is inaccessible due to 'internal' protection level",
            f"{self.model}:9:17: note: 'x' declared here")
        self.assertEqual(found, {"Hidden.x"})

    def test_quoted_name(self):
        found, _ = self.given_back(f"{self.user}:1:9: error: cannot find type 'Hidden' in scope")
        self.assertEqual(found, {"Hidden"})

    def test_overload_labels(self):
        found, _ = self.given_back(
            f"{self.user}:3:9: error: incorrect argument label in call (have 'grid:footprints:', expected "
            "'grid:bodies:')")
        self.assertEqual(found, {"Layout.make(grid:footprints:)"})

    def test_function_hidden_by_a_variable(self):
        found, _ = self.given_back(f"{self.user}:2:9: error: cannot call value of non-function type 'Double'")
        self.assertEqual(found, {"Recorder.coreRange(cell:)"})

    def test_write_narrows_and_restores(self):
        everything = set(range(len(self.edits)))
        na.ORIGINAL.clear()
        na.write(self.edits, everything)
        text = self.model.read_text()
        self.assertNotIn("package", text)
        self.assertIn("public internal(set) var count", text)
        na.write(self.edits, set())
        self.assertEqual(self.model.read_text(), MODEL)


if __name__ == "__main__":
    unittest.main()
