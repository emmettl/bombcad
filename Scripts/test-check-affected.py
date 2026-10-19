"""The tiers and suite selection of check-affected, on made-up file lists, test files and test-impact
maps; and the map's helpers in test-impact.py (line translation, the shader library's declarations)."""

import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("check_affected",
                                              Path(__file__).with_name("check-affected.py"))
check = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check)
impact = check.impact


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
        self.assertEqual(check.tier(["Scripts/analytic/sedov.py"]), "documents")
        self.assertEqual(check.tier(["Scripts/protective/model.py"]), "documents")


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

    def test_a_suite_declared_on_one_line_is_found(self):
        text = ("@Suite(.timeLimit(.minutes(120))) struct ErrorBandTests {}\n@Suite struct PressureTests {}\n"
                "@Suite(\"Slabs\", .serialized)\n@MainActor final class SlabTests {}\n")
        self.assertEqual(check.suites_in(text), ["ErrorBandTests", "PressureTests", "SlabTests"])

    def test_suites_reading_a_file_by_path_are_chosen(self):
        tests = {"Tests/A.swift": 'struct ImporterTests { let u = root.appending(path: "Samples/Importer") }',
                 "Tests/B.swift": 'struct LayoutTests { let s = source("Sources/BlastRender/Shaders/Render.metal") }',
                 "Tests/C.swift": "struct GlassTests {}"}
        self.assertEqual(check.reading_suites("Samples/Importer/unit-cube.obj", tests), {"ImporterTests"})
        self.assertEqual(check.reading_suites("Sources/BlastRender/Shaders/Render.metal", tests), {"LayoutTests"})
        self.assertEqual(check.reading_suites("Samples/Terrain/a.json", tests), set())


# A made-up map: BlastSolver.swift has two functions and a stored property between them; the
# loader compiles the shaders.
SOLVER = "Sources/BlastCore/BlastSolver.swift"
LOADER = "Sources/BlastCore/StructureTypes.swift"
METAL = "Sources/BlastCore/Shaders/Solver.metal"
SWIFT_AT_BASE = {
    SOLVER: "\n".join([
        "final class BlastSolver {",                                   # 1
        "    let sweepPipeline: MTLComputePipelineState",              # 2
        "    let otherPipeline: MTLComputePipelineState",              # 3
        "    init() {",                                                # 4
        '        sweepPipeline = try pipeline("sweep")',               # 5
        '        otherPipeline = try pipeline("other")',               # 6
        "    }",                                                       # 7
        "    var count = 0",                                           # 8
        "    func step(_ encoder: MTLComputeCommandEncoder) {",        # 9
        "        encoder.setComputePipelineState(sweepPipeline)",      # 10
        "    }",                                                       # 11
        "    func rarely(_ encoder: MTLComputeCommandEncoder) {",      # 12
        "        encoder.setComputePipelineState(otherPipeline)",      # 13
        "    }",                                                       # 14
        "}"]),                                                         # 15
    LOADER: "\n".join([
        "enum ShaderLibrary {",                                        # 1
        "    static func make() {",                                    # 2
        '        let files = ["Solver", "Refine"]',                    # 3
        '        Bundle.module.url(forResource: name, withExtension: "metal")',  # 4
        "    }",                                                       # 5
        "}"]),                                                         # 6
}
SHADER_AT_BASE = "\n".join([
    "#include <metal_stdlib>",                                         # 1
    "using namespace metal;",                                          # 2
    "",                                                                # 3
    "struct Uniforms {",                                               # 4
    "    float dt;",                                                   # 5
    "};",                                                              # 6
    "",                                                                # 7
    "// The flux across a face.",                                      # 8
    "static inline float flux(float a, float b) {",                    # 9
    "    return 0.5f * (a + b);",                                      # 10
    "}",                                                               # 11
    "",                                                                # 12
    "kernel void sweep(device float *q [[buffer(0)]], uint i [[thread_position_in_grid]]) {",  # 13
    "    q[i] = flux(q[i], q[i + 1]);",                                # 14
    "}",                                                               # 15
    "",                                                                # 16
    "kernel void other(constant Uniforms &u [[buffer(0)]], device float *q [[buffer(1)]]) {",  # 17
    "    q[0] = u.dt;",                                                # 18
    "}"])                                                              # 19


def made_up_map():
    return {
        "format": impact.FORMAT, "commit": "a" * 40, "built": "2026-10-19 00:00 UTC", "host": "test",
        "distance": 0,
        "functions": {SOLVER: [[4, 7, "init()"], [9, 11, "step(_:)"], [12, 14, "rarely(_:)"]],
                      LOADER: [[2, 5, "make()"]]},
        "suites": {
            "BlastCoreTests.AirTests": {"seconds": 300, "status": "passed",
                                        "files": {SOLVER: [0, 1], LOADER: [0]}},
            "BlastCoreTests.RareTests": {"seconds": 100, "status": "passed",
                                         "files": {SOLVER: [0, 2], LOADER: [0]}},
            "BlastCoreTests.QuickGPUTests": {"seconds": 5, "status": "passed", "files": {LOADER: [0]}},
            "BlastCoreTests.GlassTests": {"seconds": 50, "status": "passed", "files": {}},
            "BlastCoreTests.HungTests": {"seconds": 5400, "status": "timed out", "files": None},
        },
    }


class FakeRepository:
    """What check-affected asks git, made up: the base and the map's commit are the same unless
    `ages` says how many commits since the map touched a file."""

    def __init__(self, touched, tests=None, ages=None):
        self.touched_lines, self.ages = touched, ages or {}
        self.tests = tests or {
            "Tests/AirTests.swift": "struct AirTests {}\nstruct RareTests {}\nstruct QuickGPUTests {}\n",
            "Tests/GlassTests.swift": "struct GlassTests { let s = BlastSolver() }\n",
            "Tests/HungTests.swift": "struct HungTests {}\n",
            "Tests/NewTests.swift": "struct NewTests {}\n"}

    def touched(self, path):
        return self.touched_lines.get(path)

    def to_map(self, path, lines):
        return set(lines)

    def age(self, path):
        return self.ages.get(path, 0)

    def swift_files(self):
        return SWIFT_AT_BASE

    def library(self, shader):
        return {METAL: impact.metal_declarations(SHADER_AT_BASE)}


class CoverageSelectionTests(unittest.TestCase):
    def select(self, touched, **arguments):
        return check.select_by_map(sorted(touched), made_up_map(), FakeRepository(touched, **arguments))

    def test_a_core_file_runs_only_the_suites_that_executed_the_change(self):
        selection = self.select({SOLVER: {10}})
        self.assertEqual(selection.full, [])
        self.assertIn("AirTests", selection.reasons)
        self.assertIn("step(_:)", selection.reasons["AirTests"][0])
        self.assertNotIn("RareTests", selection.reasons)
        self.assertNotIn("GlassTests", selection.reasons)  # names BlastSolver, never ran it
        for always in check.ALWAYS:
            self.assertEqual(selection.reasons[always], ["always"])

    def test_suites_without_coverage_always_run(self):
        selection = self.select({SOLVER: {10}})
        self.assertEqual(selection.reasons["HungTests"], ["not in the map"])
        self.assertEqual(selection.reasons["NewTests"], ["not in the map"])

    def test_a_change_outside_any_function_counts_as_the_whole_file(self):
        selection = self.select({SOLVER: {8}})
        self.assertIn("AirTests", selection.reasons)
        self.assertIn("RareTests", selection.reasons)
        self.assertNotIn("QuickGPUTests", selection.reasons)

    def test_an_insertion_inside_a_function_is_in_it(self):
        lines = impact.touched_old_lines([(12, 0, 13, 2)])  # two lines after line 12
        self.assertEqual(lines, {12, 13})
        selection = self.select({SOLVER: lines})
        self.assertIn("RareTests", selection.reasons)
        self.assertNotIn("AirTests", selection.reasons)

    def test_a_shader_change_runs_the_suites_dispatching_the_kernels_it_reaches(self):
        # The helper `flux` is used by `sweep` alone, dispatched in step(_:).
        selection = self.select({METAL: {10}})
        self.assertEqual(selection.full, [])
        self.assertIn("AirTests", selection.reasons)
        self.assertIn("Solver.metal kernels", selection.reasons["AirTests"][0])
        self.assertNotIn("RareTests", selection.reasons)
        # The quickest suite that compiles the library catches a shader that no longer compiles.
        self.assertEqual(selection.reasons["QuickGPUTests"], ["compiles Solver.metal"])

    def test_a_shader_type_reaches_the_kernels_using_it(self):
        selection = self.select({METAL: {5}})  # Uniforms, used by `other` alone
        self.assertIn("RareTests", selection.reasons)
        self.assertNotIn("AirTests", selection.reasons)

    def test_a_shader_directive_counts_as_the_whole_file(self):
        selection = self.select({METAL: {1}})
        self.assertIn("RareTests", selection.reasons)
        self.assertIn("AirTests", selection.reasons)

    def test_the_package_still_means_the_full_check(self):
        selection = self.select({"Package.resolved": {3}})
        self.assertEqual(len(selection.full), 1)

    def test_a_stale_map_falls_back_to_the_name_rules(self):
        # A core file touched by more commits than --max-map-age since the map: the full check.
        selection = self.select({SOLVER: {10}}, ages={SOLVER: check.MAX_MAP_AGE + 1})
        self.assertTrue(selection.full)
        self.assertIn("commits since the map", selection.full[0])
        # A file outside the core: the suites that name it.
        footing = "Sources/BlastCore/Footing.swift"
        tests = {"Tests/FootingTests.swift": "struct FootingSlopeTests { let f = Footing() }\n"}
        document = made_up_map()
        document["functions"][footing] = [[1, 9, "settle()"]]
        selection = check.select_by_map([footing], document,
                                        FakeRepository({footing: {3}}, tests=tests,
                                                       ages={footing: check.MAX_MAP_AGE + 1}))
        self.assertEqual(selection.full, [])
        self.assertIn("names Footing", selection.reasons["FootingSlopeTests"][0])

    def test_a_file_the_map_does_not_know_goes_by_name(self):
        selection = self.select({"Sources/BlastCore/Scenario.swift": {3}})  # core, not in the map
        self.assertTrue(selection.full)
        selection = self.select({"Sources/BlastCore/Glass.swift": None})  # new on the branch
        self.assertEqual(selection.full, [])

    def test_changed_test_files_run_their_suites(self):
        selection = self.select({"Tests/GlassTests.swift": {1}})
        self.assertEqual(selection.reasons["GlassTests"], ["changed test file"])

    def test_the_estimate_is_the_share_of_suite_time(self):
        self.assertAlmostEqual(check.estimate(made_up_map(), ["AirTests", "GlassTests"]), 350 / 5855)


class MapHelperTests(unittest.TestCase):
    def test_hunks_and_touched_lines(self):
        diff = "@@ -3,2 +3,1 @@\n-a\n-b\n+c\n@@ -9,0 +9,2 @@\n+d\n+e\n@@ -20 +21 @@\n-f\n+g\n"
        found = impact.hunks(diff)
        self.assertEqual(found, [(3, 2, 3, 1), (9, 0, 9, 2), (20, 1, 21, 1)])
        self.assertEqual(impact.touched_old_lines(found), {3, 4, 9, 10, 20})

    def test_swift_comments_and_blank_lines_count_for_nothing(self):
        old = "func f() {\n    let a = 1\n}\n\n/// Old words.\nfunc g() {\n    let b = 2\n}\n"
        new = "func f() {\n    let a = 1\n}\n\n/// New words,\n/// two lines.\nfunc g() {\n    let b = 3\n}\n"
        # The doc comment's edit is nothing; the change in g's body is line 7 of the old side.
        file_hunks = [(5, 1, 5, 2), (7, 1, 8, 1)]
        self.assertEqual(impact.touched_old_lines(file_hunks, old, new), {7})
        self.assertEqual(impact.touched_old_lines(file_hunks), {5, 7})  # a shader's comments count
        # A comment replaced by code is code inserted where the comment was.
        self.assertEqual(impact.touched_old_lines([(5, 1, 5, 1)], old, old.replace("/// Old words.", "let c = 0")),
                         {4, 6})

    def test_a_kernel_named_like_a_local_reaches_nothing_through_it(self):
        shader = ("kernel void sweep(device float *q [[buffer(0)]]) { q[0] = 1; }\n"
                  "static inline float eigen(float a) { for (int sweep = 0; sweep < 4; sweep++) { a *= 2; } "
                  "return a; }\n"
                  "kernel void elements(device float *q [[buffer(0)]]) { q[0] = eigen(q[1]); }\n")
        library = {METAL: impact.metal_declarations(shader)}
        self.assertEqual(impact.affected_kernels(library, {METAL: [0]}), ["sweep"])
        self.assertEqual(impact.affected_kernels(library, {METAL: [1]}), ["elements"])

    def test_translate_from_the_base_to_the_map(self):
        # From the map's commit to the base: line 5 deleted, two lines inserted after line 10.
        file_hunks = [(5, 1, 4, 0), (10, 0, 10, 2)]
        self.assertEqual(impact.translate({3}, file_hunks), {3})
        self.assertEqual(impact.translate({4, 5, 9}, file_hunks), {4, 6, 10})
        self.assertEqual(impact.translate({11}, file_hunks), {10, 11})  # inserted since the map
        self.assertEqual(impact.translate({12, 13}, file_hunks), {11, 12})

    def test_metal_declarations(self):
        declarations = impact.metal_declarations(SHADER_AT_BASE)
        described = [(d["start"], d["end"], d["kind"], d["name"]) for d in declarations]
        self.assertEqual(described, [(1, 1, "directive", None), (2, 2, "directive", None), (3, 6, "type", "Uniforms"),
                                     (7, 11, "function", "flux"), (12, 15, "kernel", "sweep"),
                                     (16, 19, "kernel", "other")])
        library = {METAL: declarations}
        self.assertEqual(impact.affected_kernels(library, {METAL: [3]}), ["sweep"])
        self.assertEqual(impact.affected_kernels(library, {METAL: [0]}), ["other", "sweep"])

    def test_kernel_sites_follow_the_pipeline_to_its_dispatch(self):
        sites = impact.kernel_sites(["sweep", "other"], SWIFT_AT_BASE)
        self.assertEqual(sites["sweep"], {SOLVER: {10}})
        self.assertEqual(sites["other"], {SOLVER: {13}})
        self.assertEqual(impact.shader_loaders(METAL, SWIFT_AT_BASE), {LOADER: {3}})

    def test_assemble_indexes_each_suites_functions(self):
        table = {SOLVER: {(9, 11): "$s4step", (4, 7): "$s4init", (12, 14): "$s6rarely"}}
        results = {"BlastCoreTests.AirTests": {"seconds": 3, "status": "passed",
                                               "files": {SOLVER: [(9, 11), (4, 7), (9, 11)]}},
                   "BlastCoreTests.HungTests": {"seconds": 9, "status": "timed out", "files": None}}
        names = {"$s4step": "BlastCore.BlastSolver.step(_: __C.MTLComputeCommandEncoder) -> ()",
                 "$s4init": "BlastCore.BlastSolver.init() -> BlastCore.BlastSolver"}
        functions, suites = impact.assemble(table, results, names)
        self.assertEqual(functions[SOLVER], [[4, 7, "BlastCore.BlastSolver.init()"],
                                             [9, 11, "BlastCore.BlastSolver.step(_: __C.MTLComputeCommandEncoder)"],
                                             [12, 14, ""]])
        self.assertEqual(suites["BlastCoreTests.AirTests"]["files"], {SOLVER: [0, 1]})
        self.assertIsNone(suites["BlastCoreTests.HungTests"]["files"])
        self.assertEqual(impact.unit_of("BlastCoreTests.AirTests/Nested/inner()"), "BlastCoreTests.AirTests")

    def test_newest_map_is_an_ancestor_of_the_base(self):
        with tempfile.TemporaryDirectory() as directory:
            root, maps = Path(directory) / "repo", Path(directory) / "maps"
            root.mkdir()
            maps.mkdir()

            def run(*arguments):
                return subprocess.run(["git", *arguments], cwd=root, check=True, text=True,
                                      stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout.strip()
            run("init", "-q")
            commits = []
            for number in range(3):
                (root / "a.txt").write_text(str(number))
                run("add", "a.txt")
                run("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", str(number))
                commits.append(run("rev-parse", "HEAD"))
            self.assertIsNone(impact.newest_map(maps, commits[2], root=root))  # no map: the name rules
            for commit in commits[:2]:
                (maps / f"{commit}.json").write_text(json.dumps({"format": impact.FORMAT, "commit": commit}))
            (maps / f"{commits[2]}-dirty.json").write_text("{}")  # never used
            found = impact.newest_map(maps, commits[2], root=root)
            self.assertEqual((found["commit"], found["distance"]), (commits[1], 1))
            # A map of a commit after the base isn't used.
            self.assertEqual(impact.newest_map(maps, commits[0], root=root)["commit"], commits[0])


if __name__ == "__main__":
    unittest.main()
