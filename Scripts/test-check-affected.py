"""The tiers and suite selection of check-affected, on made-up file lists and test files."""

import importlib.util
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("check_affected",
                                              Path(__file__).with_name("check-affected.py"))
check = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check)


class TierTests(unittest.TestCase):
    def test_documents_only(self):
        self.assertEqual(check.tier(["docs/validation.md", "README.md", "docs/office-tower.png"]),
                         "documents")
        self.assertEqual(check.tier([]), "documents")

    def test_core_forces_the_full_check(self):
        for path in ("Sources/BlastCore/Shaders/Solver.metal", "Package.resolved",
                     "Sources/BlastCore/BlastSolver.swift", "Sources/BlastRender/Shaders/Render.metal",
                     "Sources/RadialBlast/SphericalBlast.swift"):
            with self.subTest(path=path):
                self.assertEqual(check.tier(["docs/a.md", path]), "full")

    def test_other_code_is_affected(self):
        self.assertEqual(check.tier(["Sources/BlastCore/Footing.swift", "docs/a.md"]), "affected")
        self.assertEqual(check.tier(["Scripts/build-app.sh"]), "affected")
        self.assertEqual(check.tier(["Scripts/release.py", "docs/a.md"]), "documents")
        self.assertEqual(check.tier(["Scripts/reference/compare.py", "Scripts/reference/tables/blast1d-tnt.json",
                                     "Makefile"]), "affected")
        self.assertEqual(check.tier(["Scripts/reference/compare.py", "Scripts/reference/tables/blast1d-tnt.json"]),
                         "documents")


class SuiteTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.tests = Path(self.directory.name)
        (self.tests / "FootingTests.swift").write_text(
            "import Testing\n@Suite(.serialized)\nstruct FootingSlopeTests {\n  let f = Footing()\n}\n")
        (self.tests / "OtherTests.swift").write_text("struct GlassTests {}\nstruct Helper {}\n")

    def test_suites_naming_a_changed_type_are_chosen(self):
        suites = check.affected_suites(["Sources/BlastCore/Footing.swift"], tests_root=self.tests)
        self.assertIn("FootingSlopeTests", suites)
        self.assertNotIn("GlassTests", suites)
        for always in check.ALWAYS:
            self.assertIn(always, suites)

    def test_helpers_are_not_suites(self):
        self.assertEqual(check.suites_in((self.tests / "OtherTests.swift").read_text()), ["GlassTests"])


if __name__ == "__main__":
    unittest.main()
