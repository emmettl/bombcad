"""Tests of build-strict.py's reading of swift build's output: python3 Scripts/test-build-strict.py"""

import importlib.util
import os
import unittest

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("build_strict", os.path.join(here, "build-strict.py"))
build_strict = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build_strict)


class WarningsTests(unittest.TestCase):
    root = "/work/bombcad"

    def test_both_forms_of_one_warning_count_once(self):
        lines = [
            "/work/bombcad/Sources/BlastCore/Footing.swift:467:41: \x1b[1;33mwarning: \x1b[1;39m"
            "extraneous duplicate parameter name\x1b[0;0m",
            "warning: /work/bombcad/Sources/BlastCore/Footing.swift:467:41 extraneous duplicate parameter "
            'name: FixIt(sourceRange: XCBuild.SwiftBuildMessage.DiagnosticInfo.SourceRange(path: "x"))',
        ]
        self.assertEqual(
            build_strict.warnings(lines, self.root),
            [("Sources/BlastCore/Footing.swift", 467, "extraneous duplicate parameter name")])

    def test_dependencies_and_build_products_are_not_ours(self):
        lines = [
            "/elsewhere/ContinuumKit/Sources/SceneModel/A.swift:1:1: warning: something",
            "/work/bombcad/.build/checkouts/continuumkit/B.swift:2:1: warning: something",
        ]
        self.assertEqual(build_strict.warnings(lines, self.root), [])

    def test_notes_and_errors_are_not_warnings(self):
        lines = [
            "/work/bombcad/Sources/X.swift:3:1: note: declared here",
            "/work/bombcad/Sources/X.swift:4:1: error: no such thing",
            "Build complete!",
        ]
        self.assertEqual(build_strict.warnings(lines, self.root), [])

    def test_the_diagnostic_group_link_is_dropped(self):
        lines = [
            "/work/bombcad/Sources/Y.swift:5:2: warning: capture of 'x' in a '@Sendable' closure "
            "[#SendableClosureCaptures]"
        ]
        self.assertEqual(
            build_strict.warnings(lines, self.root),
            [("Sources/Y.swift", 5, "capture of 'x' in a '@Sendable' closure")])


    def test_a_warning_in_a_macro_expansion_counts_where_the_code_originates(self):
        lines = [
            "macro expansion #expect:1:90: \x1b[1;33mwarning: \x1b[1;39mexpression of type 'Bool?' is unused "
            "[#\x1b]8;;https://docs.swift.org/compiler/documentation/diagnostics/no-usage\x1b\\NoUsage"
            "\x1b]8;;\x1b\\]\x1b[0;0m",
            "`- /work/bombcad/Tests/BlastCoreTests/StandingTests.swift:119:64: note: expanded code originates here",
            "117 |         #expect(a == true)",
            "    |  |                                 `- warning: expression of type 'Bool?' is unused",
            "macro expansion #expect:1:63: warning: left side of nil coalescing operator '??' has "
            "non-optional type '[Band]?', so the right side is never used",
            "`- /work/bombcad/Tests/BlastCoreTests/StandingTests.swift:119:64: note: expanded code originates here",
            "macro expansion #expect:1:5: warning: something in a dependency",
            "`- /elsewhere/ContinuumKit/Tests/A.swift:3:4: note: expanded code originates here",
        ]
        self.assertEqual(
            build_strict.warnings(lines, self.root),
            [
                ("Tests/BlastCoreTests/StandingTests.swift", 119, "expression of type 'Bool?' is unused"),
                (
                    "Tests/BlastCoreTests/StandingTests.swift", 119,
                    "left side of nil coalescing operator '??' has non-optional type '[Band]?', so the right "
                    "side is never used"),
            ])

if __name__ == "__main__":
    unittest.main()
