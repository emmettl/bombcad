import Foundation
import simd

func nodes(_ centre: SIMD3<Double>, _ index: Int) -> [SIMD3<Double>] {
    let rotation = simd_quatd(angle: 0.04 * Double(index), axis: simd_normalize(SIMD3<Double>(1, 2, 3)))
    let extent = SIMD3<Double>(0.1 + 0.003 * Double(index), 0.15, 0.08 + 0.002 * Double(index))
    return (0..<8).map { n in
        centre
            + rotation.act(
                extent * SIMD3<Double>(n & 1 == 0 ? -1 : 1, n & 2 == 0 ? -1 : 1, n & 4 == 0 ? -1 : 1)
                    / sqrt(3.0))
    }
}
func laboratoryDensity(_ p: SIMD3<Double>, family: String, boost: SIMD3<Double>) -> SIMD8<Double> {
    var value: SIMD8<Double>
    if family == "pressure" || family == "constant" {
        let pressure = family == "constant" ? 101325 : 101325 + 2500 * p.x + 900 * p.y * p.y
        value = SIMD8(1.225, 0, 0, 0, pressure / (1.4 - 1), 0, 0, 0)
    } else {
        value = SIMD8(
            2 + 0.1 * p.x + 0.02 * p.x * p.x - 0.01 * p.y * p.z,
            0.3 + 0.12 * p.y + 0.02 * p.x * p.z,
            -0.2 + 0.15 * p.z - 0.01 * p.y * p.y,
            0.05 + 0.1 * p.x - 0.02 * p.x * p.y,
            3 + 0.2 * p.y + 0.04 * p.z * p.z + 0.02 * p.x * p.y, 0, 0, 0)
    }
    // Fixture-side independent algebra; do not call the production frame transform.
    let momentum = SIMD3(value[1], value[2], value[3])
    value[1] += value[0] * boost.x
    value[2] += value[0] * boost.y
    value[3] += value[0] * boost.z
    value[4] += simd_dot(boost, momentum) + 0.5 * value[0] * simd_length_squared(boost)
    return value
}
func sample(_ centre: SIMD3<Double>, _ index: Int, _ family: String, _ boost: SIMD3<Double>)
    -> ConservedGasReconstruction.Sample
{
    var covariance = FiniteVolumePressureFit.zero
    var average = SIMD8<Double>.zero
    for point in nodes(centre, index) {
        let d = point - centre
        covariance += (1.0 / 8) * simd_double3x3(columns: (d * d.x, d * d.y, d * d.z))
        average += laboratoryDensity(point, family: family, boost: boost) / 8
    }
    return .init(centre: centre, covariance: covariance, density: average)
}
func sampleInput(_ s: ConservedGasReconstruction.Sample, _ points: [SIMD3<Double>]) -> [String: Any] {
    var result = gasSample(s)
    result["volumePoints"] = points.map(native)
    return result
}
var cases: [[String: Any]] = []
@MainActor func gasCase(
    _ id: String, parameters: [String: Any], cell: ConservedGasReconstruction.Sample,
    neighbours: [ConservedGasReconstruction.Sample], controls: [SIMD3<Double>],
    volume: [SIMD3<Double>], scale: Double, bound: Bool, samplePoints: [[SIMD3<Double>]]
) {
    ReconstructionTrace.reset()
    var record: [String: Any] = [
        "id": id, "kind": "gas", "parameters": parameters,
        "cell": sampleInput(cell, volume),
        "neighbours": neighbours.enumerated().map { i, s in sampleInput(s, samplePoints[i]) },
        "controls": controls.map(native), "scale": native(scale), "bound": bound,
    ]
    do {
        let fit = try ConservedGasReconstruction.fit(
            cell: cell, neighbours: neighbours, controls: controls, scale: scale, boundComponents: bound)
        record["result"] = [
            "velocityFrame": native(fit.velocityFrame), "factor": native(fit.factor),
            "reduced": fit.positivityReduced, "fallback": fit.rankFallback,
            "polynomials": fit.polynomials.map(polynomialRecord),
            "queries": (controls + volume).map { point in
                let state = fit.state(at: point)
                return [
                    "point": native(point), "volume": native(state.volume), "amount": native(state.amount),
                    "velocity": native(state.velocity), "pressure": native(state.pressure()),
                ] as [String: Any]
            },
        ]
    } catch { record["error"] = String(describing: error) }
    record["events"] = ReconstructionTrace.events
    cases.append(record)
}
let boosts = [SIMD3<Double>.zero, SIMD3(300, -200, 70)]
for (fi, family) in ["polynomial", "pressure"].enumerated() {
    for origin in [0, 1] {
        let translation = origin == 0 ? SIMD3<Double>.zero : SIMD3(17, -8, 31)
        for (bi, boost) in boosts.enumerated() {
            var samples: [ConservedGasReconstruction.Sample] = []
            var points: [[SIMD3<Double>]] = []
            for z in -1...1 {
                for y in -1...1 {
                    for x in -1...1 {
                        let centre = translation + SIMD3<Double>(Double(x), Double(y), Double(z))
                        points.append(nodes(centre, samples.count))
                        samples.append(sample(centre, samples.count, family, boost))
                    }
                }
            }
            for (si, scale) in [0.1, 0.4, 2.0].enumerated() {
                for reverse in [false, true] {
                    for bound in [false, true] {
                        let indices = (0..<27).filter { $0 != 13 }
                        let ordered = reverse ? Array(indices.reversed()) : indices
                        let controls =
                            points[13] + [
                                translation + SIMD3(0.2, -0.1, 0.17), translation + SIMD3(-0.3, 0.4, -0.2),
                            ]
                        gasCase(
                            "dense/\(fi)/\(origin)/\(bi)/\(si)/\(reverse)/\(bound)",
                            parameters: [
                                "family": family, "origin": origin, "boost": bi, "scaleIndex": si,
                                "reverse": reverse,
                            ],
                            cell: samples[13], neighbours: ordered.map { samples[$0] }, controls: controls,
                            volume: points[13], scale: scale, bound: bound,
                            samplePoints: ordered.map { points[$0] })
                    }
                }
            }
        }
    }
}
let axes = [
    SIMD3<Double>(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(-1, 0, 0), SIMD3(0, -1, 0), SIMD3(0, 0, -1),
]
for family in ["axes", "planar", "single", "empty"] {
    let centres =
        family == "axes"
        ? axes
        : family == "planar" ? axes.filter { $0.z == 0 } : family == "single" ? Array(axes.prefix(1)) : []
    for (bi, boost) in boosts.enumerated() {
        for bound in [false, true] {
            gasCase(
                "sparse/\(family)/\(bi)/\(bound)", parameters: ["family": family, "boost": bi],
                cell: sample(.zero, 0, "polynomial", boost),
                neighbours: centres.enumerated().map {
                    sample($0.element, $0.offset + 1, "polynomial", boost)
                },
                controls: nodes(.zero, 0) + [SIMD3(0.2, -0.1, 0.17)], volume: nodes(.zero, 0), scale: 1,
                bound: bound,
                samplePoints: centres.enumerated().map { nodes($0.element, $0.offset + 1) })
        }
    }
}
for (bi, boost) in boosts.enumerated() {
    for bound in [false, true] {
        func boostDensity(_ u: SIMD8<Double>) -> SIMD8<Double> {
            var v = u
            let momentum = SIMD3(u[1], u[2], u[3])
            v[1] += u[0] * boost.x
            v[2] += u[0] * boost.y
            v[3] += u[0] * boost.z
            v[4] += simd_dot(boost, momentum) + 0.5 * u[0] * simd_length_squared(boost)
            return v
        }
        let volume = (0..<8).map { n in
            SIMD3<Double>(n & 1 == 0 ? -1 : 1, n & 2 == 0 ? -1 : 1, n & 4 == 0 ? -1 : 1) / sqrt(3.0)
        }
        let cell = ConservedGasReconstruction.Sample(
            centre: .zero, covariance: simd_double3x3(diagonal: SIMD3(repeating: 1.0 / 3)),
            density: boostDensity(SIMD8(1, 0, 0, 0, 1, 0, 0, 0)))
        let neighbours = axes.map { p in
            ConservedGasReconstruction.Sample(
                centre: p, covariance: FiniteVolumePressureFit.zero,
                density: boostDensity(SIMD8(1, 1.3 * p.x, 1.3 * p.y, 0, 1, 0, 0, 0)))
        }
        gasCase(
            "positivity/\(bi)/\(bound)", parameters: ["family": "positivity", "boost": bi], cell: cell,
            neighbours: neighbours, controls: volume + [SIMD3(1, 1, 0)], volume: volume, scale: 1,
            bound: bound, samplePoints: axes.map { [$0] })
    }
}
for (di, delta) in [1e-4, 1e-8, 1e-10, 1e-12].enumerated() {
    for bound in [false, true] {
        let centres = (0..<12).map { i -> SIMD3<Double> in
            let t = 2 * Double.pi * Double(i) / 12
            return SIMD3(cos(t), sin(t), delta * sin(3 * t))
        }
        gasCase(
            "ring/\(di)/\(bound)", parameters: ["family": "ring", "deltaIndex": di],
            cell: sample(.zero, 0, "polynomial", .zero),
            neighbours: centres.enumerated().map { sample($0.element, $0.offset + 1, "polynomial", .zero) },
            controls: nodes(.zero, 0) + [SIMD3(0.2, -0.1, 0.17)], volume: nodes(.zero, 0), scale: 0.4,
            bound: bound, samplePoints: centres.enumerated().map { nodes($0.element, $0.offset + 1) })
    }
}
for (si, scale) in [1e-200, 1e-100, 1e100, 1e200].enumerated() {
    for bound in [false, true] {
        let centres = axes
        gasCase(
            "extreme/\(si)/\(bound)", parameters: ["family": "extreme", "scaleIndex": si],
            cell: sample(.zero, 0, "polynomial", .zero),
            neighbours: centres.enumerated().map { sample($0.element, $0.offset + 1, "polynomial", .zero) },
            controls: nodes(.zero, 0) + [SIMD3(0.2, -0.1, 0.17)], volume: nodes(.zero, 0), scale: scale,
            bound: bound, samplePoints: centres.enumerated().map { nodes($0.element, $0.offset + 1) })
    }
}
for (bi, boost) in boosts.enumerated() {
    gasCase(
        "constant/\(bi)", parameters: ["family": "constant", "boost": bi],
        cell: sample(.zero, 0, "constant", boost),
        neighbours: axes.enumerated().map { sample($0.element, $0.offset + 1, "constant", boost) },
        controls: nodes(.zero, 0), volume: nodes(.zero, 0), scale: 1, bound: true,
        samplePoints: axes.enumerated().map { nodes($0.element, $0.offset + 1) })
    gasCase(
        "far-bound/\(bi)", parameters: ["family": "far-bound", "boost": bi],
        cell: sample(.zero, 0, "polynomial", boost),
        neighbours: axes.enumerated().map { sample($0.element, $0.offset + 1, "polynomial", boost) },
        controls: nodes(.zero, 0) + [SIMD3(3, 2, -1), SIMD3(-3, -2, 1)], volume: nodes(.zero, 0), scale: 1,
        bound: true, samplePoints: axes.enumerated().map { nodes($0.element, $0.offset + 1) })
}
for failure in [
    "empty-controls", "nan-control", "duplicate-centre", "invalid-density", "invalid-energy", "zero-scale",
    "nan-geometry",
] {
    var cell = sample(.zero, 0, "polynomial", .zero)
    var neighbours = [sample(SIMD3(1, 0, 0), 1, "polynomial", .zero)]
    var controls = nodes(.zero, 0)
    var scale = 1.0
    if failure == "empty-controls" { controls = [] }
    if failure == "nan-control" { controls[0] = SIMD3(.nan, 0, 0) }
    if failure == "duplicate-centre" { neighbours = [cell] }
    if failure == "invalid-density" {
        var d = cell.density
        d[0] = -1
        cell = .init(centre: cell.centre, covariance: cell.covariance, density: d)
    }
    if failure == "invalid-energy" {
        var d = cell.density
        d[4] = -1
        cell = .init(centre: cell.centre, covariance: cell.covariance, density: d)
    }
    if failure == "zero-scale" { scale = 0 }
    if failure == "nan-geometry" {
        cell = .init(centre: SIMD3(.nan, 0, 0), covariance: cell.covariance, density: cell.density)
    }
    gasCase(
        "invalid/" + failure, parameters: ["family": "invalid", "failure": failure], cell: cell,
        neighbours: neighbours, controls: controls, volume: nodes(.zero, 0), scale: scale, bound: true,
        samplePoints: failure == "duplicate-centre" ? [nodes(.zero, 0)] : [nodes(SIMD3(1, 0, 0), 1)])
}
for origin in [0, 1] {
    for aware in [false, true] {
        for quadratic in [false, true] {
            for reverse in [false, true] {
                for (si, scale) in [0.1, 0.4, 2.0].enumerated() {
                    let translation = origin == 0 ? SIMD3<Double>.zero : SIMD3(17, -8, 31)
                    let cell = sample(translation, 0, "polynomial", .zero)
                    let nearby = axes.enumerated().map {
                        sample(translation + $0.element, $0.offset + 1, "polynomial", .zero)
                    }
                    let neighbours = reverse ? Array(nearby.reversed()) : nearby
                    ReconstructionTrace.reset()
                    let scalarCell = FiniteVolumePressureFit.Sample(
                        centre: cell.centre, covariance: cell.covariance, average: cell.density[0])
                    let scalarNeighbours = neighbours.map {
                        FiniteVolumePressureFit.Sample(
                            centre: $0.centre, covariance: $0.covariance, average: $0.density[0])
                    }
                    let stencil = FiniteVolumePressureFit.Stencil(
                        cell: scalarCell, neighbours: scalarNeighbours, scale: scale, volumeAware: aware)
                    let queries = nodes(translation, 0) + [translation + SIMD3(0.2, -0.1, 0.17)]
                    var results: [[String: Any]] = []
                    for c in [0, 1, 2, 3, 4, 0] {
                        ReconstructionTrace.currentComponent = c
                        let fit = stencil.fit(
                            average: cell.density[c], neighbourAverages: neighbours.map { $0.density[c] },
                            quadratic: quadratic)
                        results.append([
                            "component": c, "polynomial": polynomialRecord(fit),
                            "queries": queries.map {
                                ["point": native($0), "value": native(fit.value(at: $0))]
                            },
                        ])
                    }
                    cases.append([
                        "id": "scalar/\(origin)/\(aware)/\(quadratic)/\(reverse)/\(si)", "kind": "scalar",
                        "parameters": [
                            "origin": origin, "aware": aware, "quadratic": quadratic, "reverse": reverse,
                            "scaleIndex": si,
                        ],
                        "cell": sampleInput(cell, nodes(translation, 0)),
                        "neighbours": neighbours.enumerated().map { i, sample in
                            sampleInput(sample, nodes(sample.centre, reverse ? 6 - i : i + 1))
                        }, "scale": native(scale),
                        "queries": queries.map(native), "results": results,
                        "events": ReconstructionTrace.events,
                    ])
                }
            }
        }
    }
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let variant = ProcessInfo.processInfo.environment["BOMBCAD_QR_VARIANT"]!
try JSONSerialization.data(
    withJSONObject: ["schemaVersion": 1, "variant": variant, "cases": cases],
    options: [.prettyPrinted, .sortedKeys]
).write(to: output)
print(
    "Retained \(cases.count) complete actual reconstruction cases and passive source-bound histories: \(variant)"
)
