import BlastCore
import Foundation
import Metal
import simd

/// `blastbench shearband [--diagonal] [--width 2] [--n 16] [--h 0.016]`: does a crack in one-point
/// hexes slide? A square block in plane strain, cut by a band of concrete that cracks at once and
/// whose cracks carry no shear (no interlock). One side is held; the other is pulled 0.2 mm off
/// the band and then slid along it by 5 mm. Along the lattice (the default) or at 45° across it
/// (`--diagonal`, a staircase `--width` elements wide). A crack that slides freely needs no force;
/// whatever the slide costs is the elements' kinematics, which the work by mechanism names.
func runShearBand(device: MTLDevice) throws {
    let n = option("n").flatMap { Int($0) } ?? 16
    let h = option("h").flatMap { Float($0) } ?? 0.016
    let width = option("width").flatMap { Int($0) } ?? 2
    let diagonal = flag("diagonal")
    let depth = 2
    let fc: Float = 40e6
    var strong = StructureMaterial.concrete(name: "strong", compressiveStrength: fc)
    strong.rateDependent = false
    var weak = strong
    weak.name = "band"
    weak.tensileStrength = 0.05e6
    weak.fractureEnergy = 0.5
    weak.interlockFactor = option("band-interlock").flatMap { Float($0) } ?? 0
    applyRateOptions(&strong)
    // Elements (i, k) of the band: a row through the middle, or a staircase along i - k.
    func inBand(_ i: Int, _ k: Int) -> Bool {
        diagonal ? (0..<width).contains(i - k + width / 2) : (0..<width).contains(k - (n - width) / 2)
    }
    var solids = [Box(min: SIMD3(0, 0, 0.5), max: SIMD3(Float(n) * h, Float(depth) * h, 0.5 + Float(n) * h))]
    var materials: [StructureMaterial?] = [nil]
    for i in 0..<n {
        for k in 0..<n where inBand(i, k) {
            let low = SIMD3(Float(i) * h, 0, 0.5 + Float(k) * h)
            solids.append(Box(min: low, max: low + SIMD3(h, Float(depth) * h, h)))
            materials.append(weak)
        }
    }
    var model = StructureModel(solids: solids, material: strong, elementSize: h, fixedBase: false)
    model.solidMaterial = materials
    applyRateOptions(&model)
    let solver = try StructureSolver(device: device, model: model)
    solver.gravity = 0
    solver.groundContact = false
    prepareTrace(solver)
    // Directions: along the band (t) and off it (normal, towards the moving side).
    let t = diagonal ? simd_normalize(SIMD3<Float>(1, 0, 1)) : SIMD3<Float>(1, 0, 0)
    let normal = diagonal ? simd_normalize(SIMD3<Float>(-1, 0, 1)) : SIMD3<Float>(0, 0, 1)
    // The moving side's outer edges are prescribed, the other side's held; nodes within two of
    // the band's ends are left free.
    var moving: [Int] = []
    var held: [Int] = []
    for i in 0...n {
        for k in 0...n {
            let edge = i == 0 || k == 0 || i == n || k == n
            guard edge else { continue }
            let movingSide: Bool
            if diagonal {
                if abs(i - k) <= 2 { continue }
                movingSide = k > i
            } else {
                if k != 0 && k != n { continue }
                movingSide = k == n
            }
            for j in 0...depth {
                guard let node = solver.storedNode(i, j, k) else { continue }
                if movingSide { moving.append(node) } else { held.append(node) }
            }
        }
    }
    let opening: Float = 0.0002
    let slide: Float = option("slide").flatMap { Float($0) }.map { $0 / 1000 } ?? 0.005
    let openTime: Float = 0.0005
    let slideTime: Float = 0.005
    solver.mutateNodes { nodes in
        for index in nodes.indices { nodes[index].restrain(y: true) }
        for node in held { nodes[node].restrain(x: true, y: true, z: true) }
        for node in moving {
            nodes[node].isPrescribed = true
            nodes[node].velocity = normal * (opening / openTime)
        }
    }
    let length: Float = Float(n) * h * (diagonal ? Float(2).squareRoot() : 1)
    let area: Float = length * Float(depth) * h
    print(
        "Shear band \(diagonal ? "at 45° across the lattice, a staircase \(width) wide" : "along the lattice, \(width) wide"): "
            + "\(n) x \(n) elements of \(format(Double(h) * 1000, 1)) mm, band interlock \(weak.interlockFactor)"
    )
    print("  slide mm   shear MPa   normal MPa")
    func report(_ slid: Float) {
        var force = SIMD3<Float>.zero
        for i in 0...n {
            for k in 0...n {
                for j in 0...depth {
                    guard let node = solver.storedNode(i, j, k), moving.contains(node) else { continue }
                    force += solver.nodalForce(i, j, k)
                }
            }
        }
        print(
            "  " + pad(format(Double(slid) * 1000, 2), 8)
                + pad(format(Double(-simd_dot(force, t) / area / 1e6), 2), 12)
                + pad(format(Double(-simd_dot(force, normal) / area / 1e6), 2), 13))
    }
    let samples = 20
    solver.advance(steps: max(1, Int((Double(openTime) / Double(solver.criticalTimeStep)).rounded())))
    report(0)
    let before = solver.tracesWork ? solver.workTotals() : []
    let beforeBand = solver.tracesWork ? solver.workTotals(where: { i, _, k in inBand(i, k) }) : []
    solver.mutateNodes { nodes in
        for node in moving { nodes[node].velocity = t * (slide / slideTime) }
    }
    let stepsPerSample = max(
        1, Int((Double(slideTime) / Double(samples) / Double(solver.criticalTimeStep)).rounded()))
    for sample in 1...samples {
        solver.advance(steps: stepsPerSample)
        report(slide * Float(sample) / Float(samples))
    }
    if solver.tracesWork {
        let work = zip(solver.workTotals(), before).map { $0 - $1 }
        let band = zip(solver.workTotals(where: { i, _, k in inBand(i, k) }), beforeBand).map { $0 - $1 }
        print("  work while sliding (J):")
        print("  " + workHeader("", 8))
        print("  " + workRow("band", 8, band))
        print("  " + workRow("all", 8, work))
    }
    // The band's middle elements: their cracks' normals (degrees from x in the plane) and the
    // largest compressive strain each axis has seen.
    for (i, k) in diagonal ? [(n / 2, n / 2), (n / 2, n / 2 + 1)] : [(n / 2, n / 2 - 1), (n / 2, n / 2)] {
        let planes = solver.crackPlanes(i, 0, k)
        let angles = planes.normals.map { String(format: "%.0f°", atan2($0.z, $0.x) * 180 / .pi) }
        print(
            "  element (\(i), \(k)): crack normals \(angles.joined(separator: " ")), openings "
                + "\((0..<3).map { String(format: "%.4f", planes.history[$0]) }), crushed \((0..<3).map { String(format: "%.4f", planes.crush[$0]) })"
        )
    }
}
