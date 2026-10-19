"""The BlastModel split's tools on made-up sources: the Swift reader, the classification, and the
split itself, run twice on a small package in a temporary git repository.

    python3 Scripts/split/test-split.py
"""

import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import blastcore_graph as graph  # noqa: E402
import swift_source as ss  # noqa: E402

SPEC = importlib.util.spec_from_file_location("split_blastmodel", HERE / "split_blastmodel.py")
split = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(split)


class ReaderTests(unittest.TestCase):
    def test_comments_strings_and_interpolation(self):
        source = '/* a /* nested */ comment */\nlet s = "x \\(Scenario.name) \\("y")" // Metal\n'
        names = [t.text for t in ss.tokenize(source) if t.kind == "ident"]
        self.assertEqual(names, ["let", "s", "Scenario", "name"])

    def test_declarations_and_bodies(self):
        sf = ss.parse(
            "import Foundation\n"
            "public struct A: Codable {\n"
            "    var x: Int { didSet { } }\n"
            "    class func make() -> A { let local = 1; return A(x: local) }\n"
            "    enum Kind { case one, two }\n"
            "}\n"
            "extension A.Kind where Self: Sendable { func f() {} }\n")
        kinds = [(d.kind, d.name) for d in sf.decls]
        self.assertEqual(kinds, [("import", "Foundation"), ("struct", "A"),
                                 ("extension", "A.Kind")])
        members = [(m.kind, m.name) for m in sf.decls[1].members]
        self.assertEqual(members, [("var", "x"), ("func", "make"), ("enum", "Kind")])
        self.assertEqual(sf.decls[1].access, "public")
        self.assertEqual(sf.lines(sf.decls[1]), (2, 6))

    def test_initialiser_calls(self):
        sf = ss.parse("func f() { let g = Grid(cells: 3); self.init(raster: r); Box.init(min: a) }\n")
        self.assertEqual(ss.init_calls(sf, 0, len(sf.tokens) - 1),
                         {("Grid", "cells"), ("self", "raster"), ("Box", "min")})


class InferenceTests(unittest.TestCase):
    def test_types_plain_from_the_text(self):
        cases = {"0": "Int", "-3": "Int", "0.5": "Double", "1e-3": "Double", "true": "Bool",
                 '"a"': "String", "Summary()": "Summary", "[Float]()": "[Float]",
                 "SIMD3<Float>.zero": "SIMD3<Float>", "Float.infinity": "Float",
                 "[]": None, ".zero": None, "make()": None}
        for value, expected in cases.items():
            with self.subTest(value=value):
                self.assertEqual(split.inferred_type(value), expected)


class SeamTests(unittest.TestCase):
    def test_applied_once_and_recognised_after(self):
        seam = [{"id": "s", "edits": [{"file": "F.swift", "old": "struct S {\n",
                                       "new": "struct S {\n    static let n = 9\n"}]}]
        once = graph.apply_seams("F.swift", "struct S {\n}\n", seam)
        self.assertEqual(once, "struct S {\n    static let n = 9\n}\n")
        self.assertEqual(graph.apply_seams("F.swift", once, seam), once)
        with self.assertRaises(graph.SeamError):
            graph.apply_seams("F.swift", "struct T {\n}\n", seam)


PACKAGE = '''// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "BombCAD",
    dependencies: [
        .package(url: "https://github.com/emmettl/ContinuumKit.git", exact: "0.1.0-alpha.28")
    ],
    targets: [
        .target(name: "RadialBlast"),
        // Shaders are copied verbatim and compiled at runtime.
        .target(
            name: "BlastCore",
            dependencies: [
                "RadialBlast",
            ]),
        // ContinuumKit's SolidMechanics is the reference the shells' timber law is checked against.
        .testTarget(
            name: "BlastCoreTests",
            dependencies: [
                "BlastCore", "RadialBlast",
            ]),
        .testTarget(
            name: "BombCADTests",
            dependencies: [
                "BombCAD", "BlastCore",
            ]),
    ]
)
'''

RESOLVED = '''{
  "pins" : [
    {
      "identity" : "continuumkit",
      "state" : {
        "revision" : "872b204d377a53f3d4eaf5d48cf5f847e5867897",
        "version" : "0.1.0-alpha.28"
      }
    }
  ]
}
'''

SOURCES = {
    "Plain.swift": '''import Foundation
import simd

/// A plain type.
public struct Plain: Sendable {
    var a: Int
    var scale = 1.5

    func twice() -> Int { 2 * a }
}
''',
    "Solver.swift": '''import Foundation
import Metal

/// The GPU side.
final class Solver {
    let device: MTLDevice
    let plain = Plain(a: 1, scale: 2)

    init(device: MTLDevice) { self.device = device }
}
''',
    "Mixed.swift": '''import Foundation
import Metal

/// A charge, which moves.
public struct Charge: Sendable {
    public var mass: Float

    /// The charge's buffer, which stays.
    func buffer(device: MTLDevice) -> MTLBuffer? { nil }

    func doubled() -> Float { 2 * mass }

    /// The charge's mass in grams.
    var grams: Float { 1000 * mass }

    /// The charge's mass in pounds.
    var pounds: Float {
        mass / 0.453_592
    }

    /// The charge's mass in ounces.
    var ounces: Float {
        16 * pounds
    }
}

extension Solver {
    /// Loads a charge.
    func load(_ charge: Charge) { _ = charge.doubled() }
}
''',
}

TESTS = {
    "PlainTests.swift": '''import Testing

@testable import BlastCore

struct PlainTests {
    @Test func twice() { #expect(Plain(a: 2).twice() == 4) }
}
''',
    "SolverTests.swift": '''import Metal
import Testing

@testable import BlastCore

struct SolverTests {
    @Test func plain() { #expect(Plain(a: 1).a == 1) }
}
''',
}


class SplitTests(unittest.TestCase):
    """The split on a package of three source files and two test files."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        root = self.root = Path(self.directory.name)
        (root / "Scripts/split").mkdir(parents=True)
        for name in ("swift_source.py", "blastcore_graph.py", "split_blastmodel.py",
                     "import-graph.py", "split-blastmodel.sh", "LinuxSIMD.swift",
                     "SIMDParity.swift", "LinuxSIMDParityTests.swift"):
            shutil.copy(HERE / name, root / "Scripts/split" / name)
        (root / "Scripts/split/seams.json").write_text('{"seams": []}\n')
        (root / "Scripts/split/overrides.json").write_text('{"stay": {}}\n')
        (root / "Scripts/moore-glass").mkdir()
        (root / "Scripts/moore-glass/tabulate.py").write_text('"""Sources/BlastCore/Plain.swift"""\n')
        (root / "Scripts/shader-mirrors-allow.txt").write_text("size X = Sources/BlastCore/Solver.swift:x\n")
        (root / "Scripts/check-affected.py").write_text(
            '    re.compile(r"^Sources/BlastCore/(BlastSolver|Scenario)\\.swift$"),\n')
        (root / "Makefile").write_text("test-core:\n\tswift test --filter 'BlastCoreTests\\.'\n")
        shutil.copy(HERE.parents[1] / ".swift-format", root / ".swift-format")
        (root / "Package.swift").write_text(PACKAGE)
        (root / "Package.resolved").write_text(RESOLVED)
        for folder, files in (("Sources/BlastCore", SOURCES), ("Tests/BlastCoreTests", TESTS)):
            (root / folder).mkdir(parents=True)
            for name, text in files.items():
                (root / folder / name).write_text(text)
        (root / "Tests/BombCADTests").mkdir(parents=True)
        (root / "Tests/BombCADTests/AppTests.swift").write_text("@testable import BlastCore\n")
        self.git("init", "-q", "-b", "main")
        self.run_python("Scripts/split/import-graph.py", "--write")
        self.git("add", "-A")
        self.git("commit", "-qm", "start")
        self.git("checkout", "-qb", "split")

    def tearDown(self):
        self.directory.cleanup()

    def git(self, *args):
        return subprocess.run(["git", "-c", "user.email=t@example.com", "-c", "user.name=t", *args],
                              cwd=self.root, check=True, capture_output=True, text=True).stdout

    def run_python(self, *args):
        return subprocess.run([sys.executable, *args], cwd=self.root, check=True,
                              capture_output=True, text=True)

    def run_split(self):
        return subprocess.run(["bash", "Scripts/split/split-blastmodel.sh"], cwd=self.root,
                              capture_output=True, text=True)

    def read(self, path):
        return (self.root / path).read_text()

    def test_classification(self):
        plan = json.loads(self.read("Scripts/split/classification.json"))
        files = {Path(e["path"]).name: e for e in plan["files"]}
        self.assertEqual(files["Plain.swift"]["class"], "cpu")
        self.assertEqual(files["Solver.swift"]["class"], "gpu")
        mixed = files["Mixed.swift"]
        self.assertEqual(mixed["class"], "mixed")
        self.assertTrue(mixed["clean"])
        self.assertEqual([c["unit"] for c in mixed["cut"]], ["extension Solver"])
        self.assertEqual([c["member"] for c in mixed["cut_members"]], ["func buffer"])
        tests = {Path(e["path"]).name: e["moves"] for e in plan["test_files"]}
        self.assertEqual(tests, {"PlainTests.swift": True, "SolverTests.swift": False})

    def test_split_and_again(self):
        first = self.run_split()
        self.assertEqual(first.returncode, 0, first.stderr + first.stdout)
        self.assertTrue((self.root / "Sources/BlastModel/Plain.swift").exists())
        self.assertFalse((self.root / "Sources/BlastCore/Plain.swift").exists())
        self.assertTrue((self.root / "Sources/BlastModel/Mixed.swift").exists())
        gpu = self.read("Sources/BlastCore/Mixed+GPU.swift")
        self.assertIn("import BlastModel", gpu)
        self.assertIn("extension Solver {", gpu)
        self.assertIn("extension Charge {\n    /// The charge's buffer, which stays.", gpu)
        model = self.read("Sources/BlastModel/Mixed.swift")
        self.assertNotIn("Metal", model)
        self.assertIn("package func doubled()", model)
        plain = self.read("Sources/BlastModel/Plain.swift")
        self.assertIn("package init(\n        a: Int,\n        scale: Double = 1.5\n    )", plain)
        manifest = self.read("Package.swift")
        self.assertIn('name: "BlastModel"', manifest)
        self.assertIn('"BlastModel", "RadialBlast",', manifest)
        self.assertIn("#if os(Linux)", manifest)
        self.assertIn('exact: "0.1.0-alpha.29"', manifest)
        self.assertIn("0.1.0-alpha.29", self.read("Package.resolved"))
        self.assertIn("@testable import BlastModel",
                      self.read("Tests/BlastModelTests/PlainTests.swift"))
        self.assertIn("@testable import BlastCore\n@testable import BlastModel\n",
                      self.read("Tests/BlastCoreTests/SolverTests.swift"))
        self.assertIn("BlastModelTests", self.read("Makefile"))
        self.assertIn("Blast(Core|Model)", self.read("Scripts/check-affected.py"))
        self.assertTrue((self.root / "Sources/BlastModel/LinuxSIMD.swift").exists())
        self.git("add", "-A")
        self.git("commit", "-qm", "split")
        second = self.run_split()
        self.assertEqual(second.returncode, 0, second.stderr + second.stdout)
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_stale_map_stops_before_any_change(self):
        path = self.root / "Sources/BlastCore/Plain.swift"
        path.write_text(path.read_text().replace("var a: Int", "var a: Int\n    var d: MTLDevice?"))
        self.git("commit", "-qam", "Plain uses Metal now")
        result = self.run_split()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no longer describes this tree", result.stderr)
        self.assertIn("Sources/BlastCore/Plain.swift", result.stderr)
        self.assertFalse((self.root / "Sources/BlastModel").exists())

    def test_moved_file_stops_before_any_change(self):
        self.git("mv", "Sources/BlastCore/Plain.swift", "Sources/BlastCore/Simple.swift")
        self.git("commit", "-qm", "rename")
        result = self.run_split()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Plain.swift", result.stderr)
        self.assertFalse((self.root / "Sources/BlastModel").exists())

    def test_refuses_main(self):
        self.git("checkout", "-q", "main")
        result = self.run_split()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("on a branch", result.stderr)


if __name__ == "__main__":
    unittest.main()
