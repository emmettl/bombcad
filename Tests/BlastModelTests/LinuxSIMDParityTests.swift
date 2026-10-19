import Foundation
import Testing

@testable import BlastModel

/// Whether BlastModel's simd results on Linux (Sources/BlastModel/LinuxSIMD.swift) are Apple's, bit
/// for bit. `SIMDParity` digests each function's results over fixed inputs; the digests below were
/// recorded on Linux. On Linux this guards the shim; on the Mac it checks Apple's simd against
/// it, so a difference there means Linux's results differ from the Mac's in that function.
struct LinuxSIMDParityTests {
    /// Recorded on Linux (x86_64, Swift 6.4, Glibc) with `BLASTMODEL_RECORD_SIMD=1 swift test
    /// --filter LinuxSIMDParityTests`, except four rows changed on the Mac on 19 October 2026
    /// (`cross.float3`, `cross.double3`, `determinant.double3x3`, `quatd.from_to`) when the shim
    /// learnt that Apple fuses the cross product and the determinant, and the macOS 27 SDK's
    /// from-to rotation. They are the shim's results run on the Mac, which for functions that
    /// call no C maths library are its results on Linux; the Linux workflow confirms them.
    static let recorded: [String: UInt64] = [
        "abs.float3": 0x4685_72cb_a753_d04f,
        "clamp.float3": 0x434a_aad4_99c0_c5d7,
        "cross.double3": 0xe2d5_55fd_d87d_d4d2,
        "cross.float3": 0x4645_4d9f_16ca_8615,
        "determinant.double3x3": 0x6e3c_a638_7c63_9e5b,
        "distance.double3": 0x13b1_eaef_5644_eab7,
        "distance.float3": 0x2f24_3510_af12_04ce,
        "distance_squared.float3": 0x2b76_831f_87e3_6c6f,
        "dot.double3": 0xa95f_1148_a0a6_43f5,
        "dot.double4": 0x737f_cf22_6ff9_d96f,
        "dot.float2": 0x1b43_029c_9e02_f949,
        "dot.float3": 0x30c5_4bf9_c304_d76e,
        "floor.float3": 0x3d1a_bfdf_1377_461b,
        "inverse.double3x3": 0xa8ca_94ec_6d2a_b8df,
        "length.double3": 0x599a_39b3_72ff_9344,
        "length.float2": 0x8601_cb4c_575d_5a26,
        "length.float3": 0x7b94_c09a_b3b6_cea4,
        "length_squared.double3": 0x6c25_47be_3f57_1834,
        "matrix.matrix.double3x3": 0x758a_7b04_484a_d512,
        "matrix.vector.double3x3": 0x8fce_0181_f450_4c90,
        "matrix.vector.float3x3": 0x66f0_9342_b21b_0e12,
        "max.double3": 0x92a7_b951_f94d_6026,
        "min.float": 0xd592_8736_b934_8eaf,
        "min.float3": 0xbd2a_3fa6_f1be_6835,
        "normalize.double3": 0x6369_bce9_1ce5_ff3d,
        "normalize.float2": 0x7f40_637b_5b43_f271,
        "normalize.float3": 0x7eaf_55a8_914d_87b4,
        "quatd.act": 0xa120_1eed_b98e_57e7,
        "quatd.angle": 0xffee_9c7a_2e21_163b,
        "quatd.angle_axis": 0x4117_d6a4_cf6f_0ef9,
        "quatd.axis": 0x6369_bce9_1ce5_ff3d,
        "quatd.from_to": 0x61b_50cf_dd64_49b0,
        "quatd.inverse": 0x3017_0e8a_ac40_9f3f,
        "quatd.normalized": 0xcd7e_ddaa_1eb7_8a12,
        "quatd.product": 0x2e79_1a95_b477_6825,
        "quatf.act": 0xfd37_5e3f_b7ba_a2fc,
        "quatf.angle_axis": 0xb902_84c8_0329_8bd0,
        "reduce_max.double3": 0xdb37_52ac_8690_d495,
        "reduce_min.float3": 0xe48_db39_113c_961a,
        "scaled.sum.float3x3": 0xf2e_3f61_e1e6_39a0,
    ]

    /// Functions whose results go through the C library's sine, cosine or arc tangent, or through
    /// Apple's matrix inverse, whose method is not published: Glibc and Apple may round these
    /// differently in the last place, so a difference is printed, not failed.
    static let unmatchable: Set<String> = [
        "inverse.double3x3", "quatd.angle_axis", "quatd.angle", "quatf.angle_axis",
    ]

    @Test func digestsMatchLinux() {
        let found = SIMDParity.digests()
        #expect(Set(found.keys) == Set(Self.recorded.keys))
        for (name, digest) in Self.recorded.sorted(by: { $0.key < $1.key }) {
            if Self.unmatchable.contains(name) {
                if found[name] != digest { print("LinuxSIMDParityTests: \(name) differs from Linux's") }
                continue
            }
            #expect(found[name] == digest, "\(name) differs from Linux's\(Self.hint(name, found[name]))")
        }
    }

    /// For the cross product, which of clang's two ways of compiling it this platform's is.
    static func hint(_ name: String, _ digest: UInt64?) -> String {
        guard name == "cross.float3" else { return "" }
        let variants = SIMDParity.crossVariants()
        if digest == variants.fused {
            return "; this platform fuses a*b - c*d: set appleFusesCross to true in LinuxSIMD.swift"
        }
        if digest == variants.rounded { return "; this platform rounds each product" }
        return "; it matches neither way of compiling it"
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BLASTMODEL_RECORD_SIMD"] != nil))
    func record() {
        for (name, digest) in SIMDParity.digests().sorted(by: { $0.key < $1.key }) {
            // Grouped by four hexadecimal digits, as the house style for literals has it.
            let hex = String(String(digest, radix: 16).reversed())
            let groups = stride(from: 0, to: hex.count, by: 4).map { start in
                String(hex.dropFirst(start).prefix(4).reversed())
            }
            print("        \"\(name)\": 0x\(groups.reversed().joined(separator: "_")),")
        }
    }
}
