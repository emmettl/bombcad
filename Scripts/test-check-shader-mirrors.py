"""check-shader-mirrors on made-up shader and Swift sources: the layout rules, pairing, copies,
the allow-list, and the mismatches it exists to catch (among them 18 October 2026's, a field added
to the solver's `ShellElement` and not to the renderer's copy)."""

import importlib.util
import io
from contextlib import redirect_stdout
from pathlib import Path
import tempfile
import textwrap
import unittest

SPEC = importlib.util.spec_from_file_location("check_shader_mirrors",
                                              Path(__file__).with_name("check-shader-mirrors.py"))
check = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check)


class Tree:
    """A made-up repository: `files` maps paths to sources."""

    def __init__(self, files):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        for path, text in files.items():
            target = self.root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(textwrap.dedent(text), encoding="utf-8")

    def run(self, allow=""):
        findings, checked, copies, parsed = check.check(self.root, textwrap.dedent(allow))
        return findings, checked, copies, parsed

    def keys(self, allow=""):
        return sorted(f.key for f in self.run(allow)[0])

    def main(self, allow=""):
        (self.root / "allow.txt").write_text(textwrap.dedent(allow), encoding="utf-8")
        out = io.StringIO()
        with redirect_stdout(out):
            code = check.main(["--root", str(self.root), "--allow", str(self.root / "allow.txt")])
        return code, out.getvalue()

    def close(self):
        self.directory.cleanup()


def tree(test, files):
    made = Tree(files)
    test.addCleanup(made.close)
    return made


NODE_METAL = """
    struct Node {
        packed_float3 displacement;
        float mass;
        float3 velocity;   // 16 bytes, aligned to 16
        uint node[4];
        half rate;
        bool open;
    };
"""
NODE_SWIFT = """
    /// Layout matches `Node` in `Core.metal`.
    struct NodeData {
        var ux: Float = 0, uy: Float = 0, uz: Float = 0
        var mass: Float = 0
        var velocity: SIMD3<Float> = .zero
        var nodes: (UInt32, UInt32, UInt32, UInt32) = (0, 0, 0, 0)
        var rate: Float16 = 0
        var open = false
        static var count = 0
        var speed: Float { simd_length(velocity) }
    }
"""


class LayoutRules(unittest.TestCase):
    def metal(self, body, extra=""):
        structs = check.parse_metal(extra + f"struct S {{ {body} }};", "a.metal", "lib")
        return check.metal_layout(structs[-1], structs, {"lib": check.metal_constants(extra)})

    def swift(self, body, extra=""):
        source = check.parse_swift(extra + f"struct S {{\n{body}\n}}\n", "a.swift")
        types = check.SwiftTypes([source])
        return types.layout(types.structs["S"])

    def test_metal_vectors_and_packing(self):
        self.assertEqual(self.metal("float a; float3 b;").size, 32)
        self.assertEqual(self.metal("float a; packed_float3 b;").size, 16)
        self.assertEqual(self.metal("half a; half b; bool c;").size, 6)
        self.assertEqual(self.metal("packed_float3 a; packed_half4 b; float c;").size, 24)
        self.assertEqual(self.metal("float3x3 m;").size, 48)
        self.assertEqual(self.metal("float2 a; float b;").size, 16)
        self.assertEqual(self.metal("uchar a; float4 b;").size, 32)

    def test_metal_array_lengths_from_constants(self):
        layout = self.metal("float steel[SLOTS];", "constant constexpr uint SLOTS = 8;\n")
        self.assertEqual(layout.size, 32)
        self.assertEqual(self.metal("float x0, y0, x1;").size, 12)

    def test_swift_rules(self):
        self.assertEqual(self.swift("var a: Float\nvar b: SIMD3<Float>").stride, 32)
        self.assertEqual(self.swift("var a: Float\nvar b: Bool").size, 5)
        self.assertEqual(self.swift("var a: Float\nvar b: Bool").stride, 8)
        self.assertEqual(self.swift("var a: (Float, Float, Float)\nvar b: UInt32").stride, 16)
        self.assertEqual(self.swift("var m: simd_float3x3").stride, 48)
        self.assertEqual(self.swift("var a: MTLPackedFloat3\nvar b: Float").stride, 16)

    def test_swift_places_a_field_in_a_nested_struct_s_tail_padding(self):
        # Swift lays the next field after the inner struct's size (5), C after its sizeof (8).
        layout = self.swift("var inner: Inner\nvar flag: UInt8", "struct Inner { var a: Float; var b: UInt8 }\n")
        self.assertEqual([leaf.offset for leaf in layout.leaves], [0, 4, 5])
        metal = self.metal("Inner inner; uchar flag;", "struct Inner { float a; uchar b; };\n")
        self.assertEqual([leaf.offset for leaf in metal.leaves], [0, 4, 8])

    def test_swift_properties(self):
        source = check.parse_swift(NODE_SWIFT, "a.swift")
        names = [name for name, _ in source.structs[0].fields]
        self.assertEqual(names, ["ux", "uy", "uz", "mass", "velocity", "nodes", "rate", "open"])

    def test_observed_properties_are_stored(self):
        layout = self.swift("var a: Float = 0 {\n didSet { print(a) }\n}\nvar b: UInt32 { 1 }")
        self.assertEqual(layout.size, 4)

    def test_enums_and_arrays_are_not_laid_out(self):
        with self.assertRaises(check.Unresolved):
            self.swift("var kind: Kind", "enum Kind: UInt32 { case a, b }\n")
        with self.assertRaises(check.Unresolved):
            self.swift("var values: [Float]")


class Pairs(unittest.TestCase):
    def test_matching_layouts_pass(self):
        t = tree(self, {"Sources/Core/Shaders/Core.metal": NODE_METAL, "Sources/Core/Node.swift": NODE_SWIFT})
        findings, checked, _, _ = t.run()
        self.assertEqual(findings, [])
        self.assertEqual([(s, m.name, how) for s, m, _, _, how in checked], [("NodeData", "Node", "doc comment")])

    def test_a_field_added_to_the_shader_alone(self):
        metal = NODE_METAL.replace("bool open;", "bool open;\n    float shield;")
        t = tree(self, {"Sources/Core/Shaders/Core.metal": metal, "Sources/Core/Node.swift": NODE_SWIFT})
        findings = t.run()[0]
        self.assertEqual([f.key for f in findings], ["layout NodeData=Node"])
        self.assertNotIn("size", findings[0].message)  # it fits in the tail padding
        self.assertIn("offset 52: Swift has nothing, Metal has shield (f32)", findings[0].message)

    def test_a_float_read_as_a_uint(self):
        swift = NODE_SWIFT.replace("var mass: Float = 0", "var mass: UInt32 = 0")
        t = tree(self, {"Sources/Core/Shaders/Core.metal": NODE_METAL, "Sources/Core/Node.swift": swift})
        findings = t.run()[0]
        self.assertEqual([f.key for f in findings], ["layout NodeData=Node"])
        self.assertIn("offset 12: Swift has mass (u32), Metal has mass (f32)", findings[0].message)

    def test_a_simd3_pad_that_moves_the_stride(self):
        # PaneLookup as it stood on 18 October 2026: three float pads in Metal, one SIMD3 in Swift.
        t = tree(self, {
            "Sources/Core/Shaders/Core.metal": """
                struct Lookup { uint count; uint nx; uint ny; uint nz; float dx; float pad0; float pad1; float pad2; };
            """,
            "Sources/Core/Lookup.swift": """
                struct Lookup {
                    var count: UInt32 = 0
                    var nx: UInt32 = 0
                    var ny: UInt32 = 0
                    var nz: UInt32 = 0
                    var dx: Float = 0
                    var pad = SIMD3<Float>.zero
                }
            """})
        findings = t.run()[0]
        self.assertEqual([f.key for f in findings], ["layout Lookup=Lookup"])
        self.assertIn("Metal size 32, Swift stride 48", findings[0].message)

    def test_pairs_by_name_and_by_allow_list(self):
        t = tree(self, {
            "Sources/Core/Shaders/Core.metal": "struct Uniforms { uint n; float dx; };\nstruct Glass { float m; uint first; };",
            "Sources/Core/A.swift": """
                struct Uniforms { var n: UInt32; var dx: Float }
                final class Venting { struct Glass { var m: Float; var first: UInt32 } }
                final class Faces {
                    struct Face { var fluid: UInt32; var solid: UInt32 }
                    let size = MemoryLayout<Face>.stride
                }
            """})
        self.assertEqual(t.keys(), ["unpaired Faces.Face"])
        _, checked, _, parsed = t.run("pair Venting.Glass = Glass : read by a kernel\npair Faces.Face = uint2 : read as uint2\n")
        self.assertEqual(parsed.errors, [])
        self.assertEqual(sorted((s, m.name) for s, m, _, _, _ in checked),
                         [("Faces.Face", "uint2"), ("Uniforms", "Uniforms"), ("Venting.Glass", "Glass")])
        self.assertEqual(t.keys("pair Faces.Face = uint4 : wrong vector\n"), ["layout Faces.Face=uint4"])

    def test_unpair(self):
        t = tree(self, {"Sources/Core/Shaders/Core.metal": "struct Box { float4 centre; };",
                        "Sources/Core/A.swift": "struct Box { var centre: SIMD3<Float>; var car: Bool }\n"})
        self.assertEqual(t.keys(), ["layout Box=Box"])
        self.assertEqual(t.keys("unpair Box = Box : converted to float4s before upload\n"), [])


RENDER = """
    struct ShellMeshElement {
        uint node[4];
        uint axis;
        float thickness;
    };
"""
SHELL = """
    struct ShellElement {
        uint node[4];
        uint axis;
        float thickness;
        int shield[2];
    };
    static_assert(sizeof(ShellElement) == 32, "");
"""


class Copies(unittest.TestCase):
    def files(self, render=RENDER, shell=SHELL):
        return {"Sources/Core/Shaders/Shell.metal": shell, "Sources/Render/Shaders/Render.metal": render}

    def test_the_renderer_s_copy_left_behind(self):
        t = tree(self, self.files())
        findings = t.run("copy ShellMeshElement = ShellElement : the renderer draws the solver's buffer\n")[0]
        self.assertEqual([f.key for f in findings], ["copy-layout ShellMeshElement=ShellElement"])
        self.assertIn("sizes 24 and 32", findings[0].message)

    def test_copies_kept_in_step(self):
        t = tree(self, self.files(render=RENDER.replace("float thickness;", "float thickness;\n    int shield[2];")))
        self.assertEqual(t.keys("copy ShellMeshElement = ShellElement : the renderer draws it\n"), [])

    def test_same_layout_other_members(self):
        render = RENDER.replace("float thickness;", "float depth;\n    int shield[2];")
        t = tree(self, self.files(render=render))
        self.assertEqual(t.keys("copy ShellMeshElement = ShellElement : the renderer draws it\n"),
                         ["copy-members ShellMeshElement=ShellElement"])

    def test_same_name_in_two_libraries(self):
        t = tree(self, {"Sources/Core/Shaders/Shell.metal": SHELL,
                        "Sources/Render/Shaders/Render.metal": SHELL.replace("int shield[2];", "")
                        .replace("static_assert(sizeof(ShellElement) == 32, \"\");", "")})
        self.assertEqual(t.keys(), ["copy-layout ShellElement=ShellElement"])

    def test_static_assert_checks_the_rules(self):
        t = tree(self, self.files(shell=SHELL.replace("== 32", "== 28")))
        self.assertEqual(t.keys(), ["assert ShellElement"])


class AllowList(unittest.TestCase):
    FILES = {"Sources/Core/Shaders/Core.metal": NODE_METAL.replace("bool open;", "bool open;\n    float shield;"),
             "Sources/Core/Node.swift": NODE_SWIFT,
             "Sources/Core/Strides.swift": "enum Strides { static let nodeStride = 64 }\n"}

    def test_allowed_with_a_reason(self):
        code, out = tree(self, self.FILES).main("allow layout NodeData=Node : the shield is written by a kernel\n")
        self.assertEqual(code, 0, out)
        self.assertIn("0 findings, 1 allowed", out)

    def test_open_finding_fails(self):
        code, out = tree(self, self.FILES).main()
        self.assertEqual(code, 1)
        self.assertIn("layout NodeData=Node", out)

    def test_a_reason_is_required(self):
        code, out = tree(self, self.FILES).main("allow layout NodeData=Node\n")
        self.assertEqual(code, 1)
        self.assertIn("no reason given", out)

    def test_stale_entries_fail(self):
        files = dict(self.FILES, **{"Sources/Core/Shaders/Core.metal": NODE_METAL})
        code, out = tree(self, files).main("allow layout NodeData=Node : was needed once\n")
        self.assertEqual(code, 1)
        self.assertIn("matches no finding", out)

    def test_size_lines(self):
        t = tree(self, self.FILES)
        allow = "allow layout NodeData=Node : the shield\nsize Node = Sources/Core/Strides.swift:nodeStride : raw\n"
        self.assertEqual(t.keys(allow), ["layout NodeData=Node"])
        (t.root / "Sources/Core/Strides.swift").write_text("enum Strides { static let nodeStride = 60 }\n")
        self.assertEqual(t.keys(allow), ["layout NodeData=Node", "size Node"])

    def test_unknown_lines(self):
        parsed = check.parse_allow("forgive everything : please\npair A = : x\n")
        self.assertEqual(len(parsed.errors), 2)


class TodaysTree(unittest.TestCase):
    def test_the_repository_passes(self):
        out = io.StringIO()
        with redirect_stdout(out):
            code = check.main([])
        self.assertEqual(code, 0, out.getvalue())


if __name__ == "__main__":
    unittest.main()
