"""The air solver split's tools (split_solver.py) on made-up sources, in a temporary git repository.

    python3 Scripts/split/test-solver-split.py
"""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import split_solver as split  # noqa: E402
import swift_source as ss  # noqa: E402

SWIFT = """import Foundation
import Metal

/// The solver.
public final class BlastSolver {
    public let grid: Int
    public private(set) var time: Double = 0
    private(set) var steps = 0
    private var cache: [Int] = []
    private lazy var pipeline: Int = { 3 }()
    var observed: Int = 0 {
        didSet { steps += 0 }
    }

    public init(grid: Int) {
        self.grid = grid
    }

    /// How far along.
    public var progress: Double { time / 10 }

    // MARK: - Stepping

    /// Steps once.
    public func advance(steps count: Int) {
        for _ in 0..<count { advanceOnce() }
    }

    public func advance(until end: Double) {
        while time < end { advanceOnce() }
    }

    private func advanceOnce() {
        time += 1
        steps += 1
        cache.append(uniforms())
    }

    private func uniforms() -> Int { grid }

    func readTime() -> Double { time }
}

/// Boxes in the air.
extension BlastSolver {
    func installBox() { cache.removeAll() }
    private func boxCells() -> Int { grid }
}

struct StepRate {
    var target = 1.0
}
"""

METAL = """// The kernels.
#include <metal_stdlib>
using namespace metal;

struct Cell {
    float rho;
};

constant bool gravityConstant [[function_constant(5)]];
constant bool gravity = is_function_constant_defined(gravityConstant) && gravityConstant;

enum Kind { kindFluid = 0, kindWall = 1 };

static inline float pressureOf(Cell c) { return c.rho; }

// Sweeps.
kernel void sweep(device Cell *state [[buffer(0)]], uint id [[thread_position_in_grid]]) {
    state[id].rho = pressureOf(state[id]) + kindWall;
}

static inline float shown(Cell c) { return c.rho; }

kernel void draw(device Cell *state [[buffer(0)]], uint id [[thread_position_in_grid]]) {
    state[id].rho = shown(state[id]);
}
"""

LIBRARY = """enum ShaderLibrary {
    static func make() -> [String] {
        let files = [
            "Solver", "Refine",
        ]
        return files
    }
}
"""

AFFECTED = """CORE = [
    re.compile(r"^Sources/BlastCore/(BlastSolver|SolverTypes)\\.swift$"),
]
"""

DOC = "The sweep (`sweep` in Solver.metal) and `advanceOnce` in BlastSolver.swift.\n"


def plan(base_swift="", base_metal=""):
    return {
        "swift": {
            "source": "Sources/BlastCore/BlastSolver.swift", "folder": "Sources/BlastCore",
            "class": "BlastSolver", "base": base_swift,
            "stays": ["grid", "time", "steps", "cache", "pipeline", "observed", "init(grid:)", "progress",
                      "readTime()", "uniforms()"],
            "files": {
                "BlastSolver+Stepping.swift": {
                    "about": "Stepping.",
                    "moves": ["advance(steps:)", "advance(until:)", "advanceOnce()", "struct StepRate"]},
                "BlastSolver+Boxes.swift": {"about": "Boxes.", "moves": ["extension BlastSolver from installBox()"]},
            },
        },
        "metal": {
            "source": "Sources/BlastCore/Shaders/Solver.metal", "folder": "Sources/BlastCore/Shaders",
            "base": base_metal,
            "stays": ["#include <metal_stdlib>", "using namespace metal;", "Cell", "gravityConstant", "gravity",
                      "Kind", "pressureOf"],
            "files": {
                "SolverSweep.metal": {"about": "Sweeps.", "moves": ["sweep"]},
                "SolverView.metal": {"about": "The view.", "moves": ["shown", "draw"]},
            },
        },
    }


class SplitTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        files = {
            "Sources/BlastCore/BlastSolver.swift": SWIFT,
            "Sources/BlastCore/Shaders/Solver.metal": METAL,
            "Sources/BlastCore/StructureTypes+GPU.swift": LIBRARY,
            "Scripts/check-affected.py": AFFECTED,
            "docs/air.md": DOC,
        }
        for path, text in files.items():
            (root / path).parent.mkdir(parents=True, exist_ok=True)
            (root / path).write_text(text)
        subprocess.run(["git", "init", "-q"], cwd=root, check=True)
        subprocess.run(["git", "add", "-A"], cwd=root, check=True)
        subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "base"], cwd=root,
                       check=True)
        self.root = root
        self.plan_path = root / "plan.json"
        split.ROOT = root
        split.PLAN = self.plan_path
        self.write_plan(plan())

    def tearDown(self):
        self.temp.cleanup()

    def write_plan(self, value):
        self.plan_path.write_text(json.dumps(value))

    def read(self, path):
        return (self.root / path).read_text()

    def test_keys_and_what_cannot_move(self):
        units = split.swift_units(ss.parse(SWIFT), "BlastSolver")
        keys = {u.key: u for u in units}
        self.assertIn("advance(steps:)", keys)
        self.assertIn("advance(until:)", keys)
        self.assertIn("struct StepRate", keys)
        self.assertIn("extension BlastSolver from installBox()", keys)
        self.assertEqual(keys["installBox()"].container, "extension")
        for stored in ("grid", "time", "steps", "cache", "pipeline", "observed", "init(grid:)"):
            self.assertFalse(keys[stored].movable, stored)
        self.assertTrue(keys["progress"].movable)
        items = split.metal_items(METAL)
        self.assertEqual([i.key for i in items],
                         ["#include <metal_stdlib>", "using namespace metal;", "Cell", "gravityConstant", "gravity",
                          "Kind", "pressureOf", "sweep", "shown", "draw"])
        self.assertIn("kindWall", items[5].names)

    def test_check_names_what_the_plan_misses(self):
        self.assertTrue(split.check(split.load_plan(), quiet=True))
        source = self.root / "Sources/BlastCore/BlastSolver.swift"
        source.write_text(SWIFT.replace("    func readTime()", "    func newOne() {}\n\n    func readTime()"))
        self.assertFalse(split.check(split.load_plan(), quiet=True))
        moved = plan()
        moved["swift"]["files"]["BlastSolver+Stepping.swift"]["moves"].append("time")
        source.write_text(SWIFT)
        self.write_plan(moved)
        self.assertFalse(split.check(split.load_plan(), quiet=True))

    def test_metal_order(self):
        wrong = plan()
        wrong["metal"]["stays"].remove("pressureOf")
        wrong["metal"]["files"]["SolverView.metal"]["moves"].insert(0, "pressureOf")
        self.write_plan(wrong)
        _, _, _, problems = split.metal_state(split.load_plan())
        self.assertTrue(any("sweep" in p and "pressureOf" in p for p in problems), problems)

    def test_split(self):
        split.split(split.load_plan())
        stepping = self.read("Sources/BlastCore/BlastSolver+Stepping.swift")
        core = self.read("Sources/BlastCore/BlastSolver.swift")
        boxes = self.read("Sources/BlastCore/BlastSolver+Boxes.swift")
        self.assertIn("extension BlastSolver {\n    /// Steps once.\n    public func advance(steps", stepping)
        self.assertNotIn("MARK", stepping)
        self.assertIn("struct StepRate", stepping)
        self.assertNotIn("func advance", core)
        # Set elsewhere: the setter widens; used elsewhere: private goes; used only at home: kept.
        self.assertIn("public internal(set) var time", core)
        self.assertIn("\n    var steps = 0", core)
        self.assertIn("\n    var cache: [Int]", core)
        self.assertIn("    func uniforms()", core)
        self.assertIn("private lazy var pipeline", core)
        self.assertIn("    private func advanceOnce()", stepping)
        self.assertIn("/// Boxes in the air.\nextension BlastSolver {", boxes)
        self.assertIn("private func boxCells()", boxes)
        sweep = self.read("Sources/BlastCore/Shaders/SolverSweep.metal")
        self.assertIn("// Sweeps.\nkernel void sweep(device Cell *state [[buffer(0)]]", sweep)
        self.assertNotIn("kernel void", self.read("Sources/BlastCore/Shaders/Solver.metal"))
        self.assertIn('"Solver", "SolverSweep", "SolverView", "Refine"', self.read("Sources/BlastCore/StructureTypes+GPU.swift"))
        self.assertIn(r"(BlastSolver(\+\w+)?|SolverTypes)", self.read("Scripts/check-affected.py"))
        self.assertIn("(`sweep` in SolverSweep.metal) and `advanceOnce` in BlastSolver+Stepping.swift",
                      self.read("docs/air.md"))
        # Again: nothing to do.
        before = {p: p.read_text() for p in (self.root / "Sources").rglob("*") if p.is_file()}
        split.split(split.load_plan())
        after = {p: p.read_text() for p in (self.root / "Sources").rglob("*") if p.is_file()}
        self.assertEqual(before, after)

    def test_writes(self):
        tokens = ss.tokenize("a = 1; b[2] += 3; c.append(4); f(&d); e == 5; g.count; h?.x = 6; i.sort()")
        writes = {t.text for k, t in enumerate(tokens) if t.kind == "ident" and split.writes_at(tokens, k)}
        self.assertEqual(writes - {"x"}, {"a", "b", "c", "d", "h", "i"})


if __name__ == "__main__":
    unittest.main()
