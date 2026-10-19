import simd

/// Digests of the simd functions BlastModel uses, each over the same few thousand inputs: on Linux
/// of the stand-ins in LinuxSIMD.swift, on the Mac of Apple's simd. Computed here, inside
/// BlastModel, so that each call reaches what BlastModel's own code reaches.
/// Tests/BlastModelTests/LinuxSIMDParityTests.swift compares them with the digests recorded on
/// Linux, so that a run on the Mac shows whether the two agree bit for bit.
enum SIMDParity {
    static let samples = 4096

    /// A digest (FNV-1a, 64 bits, of each result's bits; every NaN counts alike) by function name.
    static func digests() -> [String: UInt64] {
        var out: [String: UInt64] = [:]
        func record(_ name: String, _ body: (inout Digest, inout Inputs) -> Void) {
            var digest = Digest()
            var inputs = Inputs()
            for _ in 0..<samples { body(&digest, &inputs) }
            out[name] = digest.value
        }
        record("dot.float3") { d, i in d.add(simd_dot(i.float3(), i.float3())) }
        record("dot.double3") { d, i in d.add(simd_dot(i.double3(), i.double3())) }
        record("dot.float2") { d, i in d.add(simd_dot(i.float2(), i.float2())) }
        record("dot.double4") { d, i in d.add(simd_dot(i.double4(), i.double4())) }
        record("length.float3") { d, i in d.add(simd_length(i.float3())) }
        record("length.double3") { d, i in d.add(simd_length(i.double3())) }
        record("length.float2") { d, i in d.add(simd_length(i.float2())) }
        record("length_squared.double3") { d, i in d.add(simd_length_squared(i.double3())) }
        record("distance.float3") { d, i in d.add(simd_distance(i.float3(), i.float3())) }
        record("distance.double3") { d, i in d.add(simd_distance(i.double3(), i.double3())) }
        record("distance_squared.float3") { d, i in d.add(simd_distance_squared(i.float3(), i.float3())) }
        record("normalize.float3") { d, i in d.add(simd_normalize(i.scaledFloat3())) }
        record("normalize.double3") { d, i in d.add(simd_normalize(i.scaledDouble3())) }
        record("normalize.float2") { d, i in d.add(simd_normalize(i.float2())) }
        record("cross.float3") { d, i in d.add(simd_cross(i.float3(), i.float3())) }
        record("cross.double3") { d, i in d.add(simd_cross(i.double3(), i.double3())) }
        record("min.float3") { d, i in d.add(simd_min(i.edgyFloat3(), i.edgyFloat3())) }
        record("max.double3") { d, i in d.add(simd_max(i.edgyDouble3(), i.edgyDouble3())) }
        record("min.float") { d, i in d.add(simd_min(i.edgyFloat3().x, i.edgyFloat3().y)) }
        record("clamp.float3") { d, i in
            let a = i.float3()
            let b = i.float3()
            d.add(simd_clamp(i.edgyFloat3(), simd_min(a, b), simd_max(a, b)))
        }
        record("abs.float3") { d, i in d.add(simd_abs(i.edgyFloat3())) }
        record("reduce_min.float3") { d, i in d.add(simd_reduce_min(i.edgyFloat3())) }
        record("reduce_max.double3") { d, i in d.add(simd_reduce_max(i.edgyDouble3())) }
        record("floor.float3") { d, i in d.add(floor(i.float3())) }
        record("matrix.vector.double3x3") { d, i in d.add(i.double3x3() * i.double3()) }
        record("matrix.matrix.double3x3") { d, i in
            let m = i.double3x3() * i.double3x3()
            d.add(m.columns.0, m.columns.1, m.columns.2)
        }
        record("determinant.double3x3") { d, i in d.add(simd_determinant(i.double3x3())) }
        record("inverse.double3x3") { d, i in
            let m = simd_inverse(i.double3x3())
            d.add(m.columns.0, m.columns.1, m.columns.2)
        }
        record("matrix.vector.float3x3") { d, i in
            d.add(simd_float3x3(columns: (i.float3(), i.float3(), i.float3())) * i.float3())
        }
        record("scaled.sum.float3x3") { d, i in
            var m = simd_float3x3()
            m += i.float3().x * simd_float3x3(columns: (i.float3(), i.float3(), i.float3()))
            d.add(m.columns.0, m.columns.1, m.columns.2)
        }
        record("quatd.angle_axis") { d, i in
            d.add(simd_quatd(angle: i.double3().x, axis: simd_normalize(i.double3())).vector)
        }
        record("quatd.act") { d, i in d.add(i.quatd().act(i.double3())) }
        record("quatd.product") { d, i in d.add((i.quatd() * i.quatd()).vector) }
        record("quatd.inverse") { d, i in d.add(i.quatd().inverse.vector) }
        record("quatd.normalized") { d, i in d.add(simd_quatd(vector: i.double4()).normalized.vector) }
        record("quatd.angle") { d, i in d.add(i.quatd().angle) }
        record("quatd.axis") { d, i in d.add(i.quatd().axis) }
        record("quatd.from_to") { d, i in
            d.add(simd_quatd(from: simd_normalize(i.double3()), to: simd_normalize(i.double3())).vector)
        }
        record("quatf.angle_axis") { d, i in
            d.add(simd_quatf(angle: i.float3().x, axis: simd_normalize(i.float3())).vector)
        }
        record("quatf.act") { d, i in
            let q = simd_quatf(vector: simd_normalize(i.float3()).x * SIMD4(i.float3(), i.float3().y))
            d.add(q.act(i.float3()))
        }
        return out
    }

    /// The two ways clang could have compiled `simd_cross`, written out, for telling which one
    /// Apple's is when its digest differs from the one recorded.
    static func crossVariants() -> (rounded: UInt64, fused: UInt64) {
        var rounded = Digest()
        var fused = Digest()
        var inputs = Inputs()
        for _ in 0..<samples {
            let a = inputs.float3()
            let b = inputs.float3()
            rounded.add(SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x))
            fused.add(
                SIMD3(
                    (-(a.z * b.y)).addingProduct(a.y, b.z), (-(a.x * b.z)).addingProduct(a.z, b.x),
                    (-(a.y * b.x)).addingProduct(a.x, b.y)))
        }
        return (rounded.value, fused.value)
    }

    struct Digest {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325

        mutating func add(bits: UInt64) {
            for shift in stride(from: 0, to: 64, by: 8) {
                value ^= (bits >> UInt64(shift)) & 0xff
                value = value &* 0x0000_0100_0000_01b3
            }
        }

        mutating func add(_ x: Float) { add(bits: x.isNaN ? 0x7fc0_0000 : UInt64(x.bitPattern)) }

        mutating func add(_ x: Double) { add(bits: x.isNaN ? 0x7ff8_0000_0000_0000 : x.bitPattern) }

        mutating func add<V: SIMD>(_ v: V) where V.Scalar == Float { for k in v.indices { add(v[k]) } }

        mutating func add<V: SIMD>(_ v: V) where V.Scalar == Double { for k in v.indices { add(v[k]) } }

        mutating func add(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>) {
            add(a)
            add(b)
            add(c)
        }

        mutating func add(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) {
            add(a)
            add(b)
            add(c)
        }
    }

    /// Fixed pseudo-random inputs (SplitMix64), the same on every machine.
    struct Inputs {
        var state: UInt64 = 0x2545_f491_4f6c_dd1d

        mutating func next() -> UInt64 {
            state = state &+ 0x9e37_79b9_7f4a_7c15
            var z = state
            z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
            z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
            return z ^ (z >> 31)
        }

        /// Uniform in [-8, 8), with 53 random bits.
        mutating func double() -> Double { Double(next() >> 11) * 0x1p-53 * 16 - 8 }

        mutating func float() -> Float { Float(double()) }

        /// A value or, one time in eight, a zero of either sign or a NaN.
        mutating func edgyDouble() -> Double {
            switch next() % 32 {
            case 0: return 0
            case 1: return -0.0
            case 2: return .nan
            case 3: return .infinity
            default: return double()
            }
        }

        mutating func float2() -> SIMD2<Float> { SIMD2(float(), float()) }
        mutating func float3() -> SIMD3<Float> { SIMD3(float(), float(), float()) }
        mutating func double3() -> SIMD3<Double> { SIMD3(double(), double(), double()) }
        mutating func double4() -> SIMD4<Double> { SIMD4(double(), double(), double(), double()) }
        mutating func edgyFloat3() -> SIMD3<Float> {
            SIMD3(Float(edgyDouble()), Float(edgyDouble()), Float(edgyDouble()))
        }
        mutating func edgyDouble3() -> SIMD3<Double> { SIMD3(edgyDouble(), edgyDouble(), edgyDouble()) }

        /// Scaled by 2^-40 to 2^40, so that the reciprocal square roots see many exponents.
        mutating func scaledFloat3() -> SIMD3<Float> {
            float3() * Float(sign: .plus, exponent: Int(next() % 81) - 40, significand: 1)
        }

        mutating func scaledDouble3() -> SIMD3<Double> {
            double3() * Double(sign: .plus, exponent: Int(next() % 81) - 40, significand: 1)
        }

        mutating func double3x3() -> simd_double3x3 {
            simd_double3x3(columns: (double3(), double3(), double3()))
        }

        mutating func quatd() -> simd_quatd { simd_quatd(vector: double4() / 8) }
    }
}
