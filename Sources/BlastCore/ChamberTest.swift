import Foundation
import Metal
import simd

/// A full-scale internal explosion: H. Shang, W. Guo, Y. Li, W. Pang and H. Liu, "Experimental
/// Study on the Damage Mechanism of Reinforced Concrete Shear Walls Under Internal Explosion",
/// *Applied Sciences* 16, 48 (2026).
///
/// Two reinforced concrete chambers (0.8 m walls and roof, C40 concrete, 16 mm HPB400 bars at
/// 150 mm in both faces both ways) stand either side of a 1 m partition, through which four open
/// steel sleeves, 1 m across, each held 50 kg of TNT at mid-thickness, fired together. Each
/// chamber is 3.8 m long inside, 6.4 m wide and 5.35 m high, with a 1.2 m strip beside the
/// partition left open to the sky as a vent. The paper reports peak reflected pressures at six
/// wall sensors and, after the test, the residual deflection along the free edge of the roof.
///
/// The model is one chamber, with the partition's mid-plane as a mirror: each sleeve's charge
/// then counts as 25 kg on the mirror. Read from the paper's figures, and assumed:
/// - the partition and the foundation are rigid; the side walls are held where they meet them;
/// - of the 1.8 m end wall (which the paper treats as rigid) the inner 0.6 m is modelled, held at
///   its outer face, so that the roof's and walls' bars run on into it and the hinges at its
///   face can spread into it; it has mats on its inner face like the walls';
/// - the sleeves are 0.9 m square holes, of the same area as the 1 m circles;
/// - the roof's free edge has a down-stand 0.8 m wide and 1.85 m deep overall;
/// - the 0.5 m chamfers at the inside corners are steps of elements, without their diagonal bars;
/// - bars are 50 mm from the faces to their centres; the ties (8 mm on a 450 mm grid) are
///   smeared through the walls and roof.
public enum ChamberTest {
    /// Peak reflected pressures at the six sensors (P1-P6, both chambers), in pascals.
    public static let measuredPeaks: [(sensor: String, pressure: Float)] = [
        ("P1", 4.13e6), ("P2", 4.42e6), ("P3", 3.17e6), ("P4", 3.16e6), ("P5", 3.90e6), ("P6", 3.98e6),
    ]
    /// Residual deflection of the roof's free edge at mid-span after the test, in metres, read
    /// off the paper's Figure 21 (their own LS-DYNA model gave 61 mm).
    public static let measuredResidual: Float = 0.095

    // Coordinates: x from the held face of the end wall's modelled part towards the partition,
    // y across the chamber (outer faces at 1 and 9 m, leaving air either side), z up from the
    // foundation's underside.
    static let endWallFace: Float = 0.6
    static let sideWalls = (low: Float(1.0), high: Float(9.0))
    static let inside = (low: Float(1.8), high: Float(8.2))
    static let floorTop: Float = 0.8
    static let roof = (low: Float(6.15), high: Float(6.95))
    static let roofEdge: Float = endWallFace + 3.8
    static let partitionFace: Float = endWallFace + 5.0
    static let mirror: Float = endWallFace + 5.5

    /// The charges' centres, on the mirror.
    public static let chargePositions: [SIMD3<Float>] = [
        SIMD3(mirror, 3.8, 1.5), SIMD3(mirror, 6.2, 1.5), SIMD3(mirror, 3.8, 3.5), SIMD3(mirror, 6.2, 3.5),
    ]

    public static func material() -> StructureMaterial {
        // C40: the measured cube strength, 41 MPa, is about 33 MPa as a cylinder; E as measured.
        var steel = SteelProperties(
            yieldStress: 469e6, ultimateStress: 663e6, ultimateStrain: 0.10, ruptureStrain: 0.12)
        steel.youngsModulus = 201e9
        var concrete = StructureMaterial.concrete(
            name: "C40", compressiveStrength: 33e6, density: 2410, steel: steel)
        concrete.youngsModulus = 31.4e9
        return concrete
    }

    public static func scenario(
        elementSize: Float = 0.1, downstand: Bool = true, ties: Bool = true, elastic: Bool = false,
        chargeScale: Float = 1, haunches: Bool = true
    ) -> Scenario {
        let w1 = Box(min: SIMD3(0, sideWalls.low, 0), max: SIMD3(partitionFace, inside.low, roof.high))
        let w3 = Box(min: SIMD3(0, inside.high, 0), max: SIMD3(partitionFace, sideWalls.high, roof.high))
        let s1 = Box(min: SIMD3(0, sideWalls.low, roof.low), max: SIMD3(roofEdge, sideWalls.high, roof.high))
        // The modelled part of the end wall.
        let endWall = Box(min: SIMD3(0, sideWalls.low, 0), max: SIMD3(endWallFace, sideWalls.high, roof.high))
        var solids = [w1, w3, s1, endWall]
        if downstand {
            solids.append(
                Box(
                    min: SIMD3(roofEdge - 0.8, inside.low, roof.high - 1.85),
                    max: SIMD3(roofEdge, inside.high, roof.low)))
        }
        if haunches {
            let room = (x: endWallFace, y: inside, z: floorTop)
            // Along the roof's underside: at both side walls and at the end wall.
            solids += haunch(
                along: 0, from: room.x, to: roofEdge, corner: [1: room.y.low, 2: roof.low],
                into: [1: 1, 2: -1],
                h: elementSize)
            solids += haunch(
                along: 0, from: room.x, to: roofEdge, corner: [1: room.y.high, 2: roof.low],
                into: [1: -1, 2: -1],
                h: elementSize)
            solids += haunch(
                along: 1, from: room.y.low, to: room.y.high, corner: [0: room.x, 2: roof.low],
                into: [0: 1, 2: -1], h: elementSize)
            // At the foot of the side walls, and where they meet the end wall.
            solids += haunch(
                along: 0, from: room.x, to: partitionFace, corner: [1: room.y.low, 2: room.z],
                into: [1: 1, 2: 1],
                h: elementSize)
            solids += haunch(
                along: 0, from: room.x, to: partitionFace, corner: [1: room.y.high, 2: room.z],
                into: [1: -1, 2: 1], h: elementSize)
            solids += haunch(
                along: 2, from: room.z, to: roof.low, corner: [0: room.x, 1: room.y.low], into: [0: 1, 1: 1],
                h: elementSize)
            solids += haunch(
                along: 2, from: room.z, to: roof.low, corner: [0: room.x, 1: room.y.high],
                into: [0: 1, 1: -1],
                h: elementSize)
        }
        var model = StructureModel(
            solids: solids, material: material(), elementSize: elementSize, fixedBase: true)
        // Held at the end wall's outer face, in the partition and in the foundation.
        model.supports = [
            Box(min: SIMD3(-1, 0, -1), max: SIMD3(0, 10, 10)),
            Box(min: SIMD3(partitionFace, 0, -1), max: SIMD3(mirror + 1, 10, 10)),
            Box(min: SIMD3(-1, 0, -1), max: SIMD3(mirror + 1, 10, floorTop)),
        ]
        // 16 mm bars at 150 mm, both faces, both ways: 1,340 mm² per metre.
        let area: Float = 201e-6 / 0.15
        for (box, axis) in [(w1, 1), (w3, 1), (s1, 2)] where !elastic {
            model.addMat(to: box, thicknessAxis: axis, areaPerMetre: area, depth: 0.05)
        }
        if !elastic {
            model.addMat(
                to: endWall, thicknessAxis: 0, areaPerMetre: area, depth: 0.05,
                faces: (low: false, high: true))
        }
        if elastic {
            let concrete = model.material
            model.material = .elastic(
                density: concrete.density, youngsModulus: concrete.youngsModulus,
                poissonRatio: concrete.poissonRatio)
        }
        if downstand && !elastic, let beam = solids.last {
            model.addMat(to: beam, thicknessAxis: 0, areaPerMetre: area, depth: 0.05)
        }
        // Ties through the thickness: 8 mm bars on a 450 mm square grid.
        if ties && !elastic {
            let tieRatio: Float = 50.3e-6 / (0.45 * 0.45)
            for (box, axis) in [(w1, 1), (w3, 1), (s1, 2)] {
                var ratio = SIMD3<Float>(repeating: 0)
                ratio[axis] = tieRatio
                model.reinforcement.append(ReinforcementLayer(region: box, ratio: ratio))
            }
        }

        // The partition, half of it, with the four sleeves as square holes; the floor.
        var boxes: [Box] = [
            Box(min: SIMD3(endWallFace, inside.low, 0), max: SIMD3(mirror, inside.high, floorTop))
        ]
        let hole: Float = 0.45
        let ys = [chargePositions[0].y, chargePositions[1].y]
        let zs = [chargePositions[0].z, chargePositions[2].z]
        // Cut the partition into strips around the holes.
        var yCuts = [inside.low] + ys.flatMap { [$0 - hole, $0 + hole] } + [inside.high]
        yCuts.sort()
        var zCuts = [floorTop] + zs.flatMap { [$0 - hole, $0 + hole] } + [roof.high]
        zCuts.sort()
        for (y0, y1) in zip(yCuts, yCuts.dropFirst()) {
            for (z0, z1) in zip(zCuts, zCuts.dropFirst()) {
                let centre = SIMD2(0.5 * (y0 + y1), 0.5 * (z0 + z1))
                let isHole =
                    ys.contains { abs($0 - centre.x) < hole } && zs.contains { abs($0 - centre.y) < hole }
                if !isHole {
                    boxes.append(Box(min: SIMD3(partitionFace, y0, z0), max: SIMD3(mirror, y1, z1)))
                }
            }
        }
        // Sensors: on the side wall and the roof, nearest the charges' row, and on the end wall.
        let gauges = [
            Gauge("Side wall W1, 2.3 m in", at: SIMD3(endWallFace + 2.3, inside.low + 0.05, 2.8)),
            Gauge("Side wall W3, 1.5 m in", at: SIMD3(endWallFace + 1.5, inside.high - 0.05, 2.8)),
            Gauge("Roof, 1.5 m in", at: SIMD3(endWallFace + 1.5, 5.0, roof.low - 0.05)),
            Gauge("End wall, middle", at: SIMD3(endWallFace + 0.05, 5.0, 2.8)),
        ]
        var scenario = Scenario(
            name: "Internal explosion (Shang et al.)", domainSize: SIMD3(mirror, 10, 9), boxes: boxes,
            charge: Charge(mass: 25 * chargeScale, position: chargePositions[0]), gauges: gauges,
            structure: model)
        scenario.additionalCharges = chargePositions.dropFirst().map {
            Charge(mass: 25 * chargeScale, position: $0)
        }
        // The end wall's held face and the mirror bound the air at x; the ground below.
        scenario.reflectiveFaces = [.zMin, .xMin, .xMax]
        return scenario
    }

    /// A 0.5 m chamfer in an inside corner, as steps one element high. The corner runs along
    /// axis `along`; `corner` gives its position on the other two axes and `into` the direction
    /// of the room from it on each.
    static func haunch(
        along: Int, from: Float, to: Float, corner: [Int: Float], into: [Int: Float], h: Float
    ) -> [Box] {
        let size: Float = 0.5
        let axes = corner.keys.sorted()
        var boxes: [Box] = []
        for (first, second) in [(axes[0], axes[1]), (axes[1], axes[0])] {
            // Steps up the first face; the second axis's steps are the mirror image, so each
            // takes half of the diagonal.
            for n in 0..<Int((size / h).rounded()) {
                var low = SIMD3<Float>(repeating: 0)
                var high = SIMD3<Float>(repeating: 0)
                low[along] = from
                high[along] = to
                let a = (corner[first]!, corner[first]! + into[first]! * (Float(n) + 1) * h)
                let b = (corner[second]!, corner[second]! + into[second]! * (size - (Float(n) + 0.5) * h))
                low[first] = min(a.0, a.1)
                high[first] = max(a.0, a.1)
                low[second] = min(b.0, b.1)
                high[second] = max(b.0, b.1)
                boxes.append(Box(min: low, max: high))
            }
        }
        return boxes
    }

    public struct Result: Sendable {
        public var gaugePeaks: [(name: String, pressure: Float)]
        public var gaugeHistories: [[GaugeSample]]
        /// Deflection of the roof's free edge at mid-span against time (seconds, metres; up, out
        /// of the chamber, is positive).
        public var edgeHistory: [SIMD2<Float>]
        /// Outward deflection of other points against time: the middle of side wall W1's outer
        /// face, and the middle of the roof.
        public var probes: [(name: String, history: [SIMD2<Float>])]
        public var summary: StructureSummary
        /// Failed elements in each part of the structure.
        public var failures: [(part: String, failed: Int, total: Int)]
        public var wallSeconds: Double

        /// Mean of the edge deflection over the last fifth of the run.
        public var residual: Float {
            let tail = edgeHistory.suffix(max(1, edgeHistory.count / 5))
            return tail.reduce(0) { $0 + $1.y } / Float(tail.count)
        }
        public var peakDeflection: Float { edgeHistory.map(\.y).max() ?? 0 }
    }

    public static func run(
        device: MTLDevice, cellSize: Float = 0.1, elementSize: Float = 0.1, downstand: Bool = true,
        ties: Bool = true, elastic: Bool = false, chargeScale: Float = 1, duration: Double = 0.3
    ) throws -> Result {
        try run(
            device: device,
            scenario: scenario(
                elementSize: elementSize, downstand: downstand, ties: ties, elastic: elastic,
                chargeScale: chargeScale),
            cellSize: cellSize, duration: duration)
    }

    /// The chamber with its vent closed and no charge, filled with air at `overpressure` (Pa)
    /// from the start: a step load on the walls and roof that lasts, from which the pressure the
    /// roof can resist is found as the largest that does not throw it.
    public static func pressureTest(
        device: MTLDevice, overpressure: Float, cellSize: Float = 0.1, elementSize: Float = 0.1,
        duration: Double = 0.3
    ) throws -> Result {
        var scenario = scenario(elementSize: elementSize, chargeScale: 0)
        scenario.boxes.append(
            Box(min: SIMD3(roofEdge, inside.low, roof.low), max: SIMD3(mirror, inside.high, roof.high)))
        return try run(
            device: device, scenario: scenario, cellSize: cellSize, duration: duration,
            interiorOverpressure: overpressure)
    }

    /// Runs a variant of the test's scenario, with the air inside the chamber raised by
    /// `interiorOverpressure` (Pa) at the start.
    public static func run(
        device: MTLDevice, scenario: Scenario, cellSize: Float, duration: Double,
        interiorOverpressure: Float = 0
    ) throws -> Result {
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: cellSize)
        if interiorOverpressure != 0 {
            let grid = solver.grid
            let room = Box(
                min: SIMD3(endWallFace, inside.low, floorTop), max: SIMD3(mirror, inside.high, roof.high))
            let pressure = scenario.atmosphere.pressure + interiorOverpressure
            let gamma = solver.configuration.gamma
            solver.mutateState { cells in
                for k in 0..<grid.nz {
                    for j in 0..<grid.ny {
                        for i in 0..<grid.nx where !solver.isSolid(i, j, k) {
                            let centre = (SIMD3(Float(i), Float(j), Float(k)) + 0.5) * grid.cellSize
                            guard room.contains(centre) else { continue }
                            cells[grid.index(i, j, k)] = CellState(
                                Primitive(density: scenario.atmosphere.density, pressure: pressure),
                                gamma: gamma)
                        }
                    }
                }
            }
            solver.restart()
        }
        guard let structure = solver.structure else { throw BlastError.allocationFailed("structure") }
        let h = structure.model.elementSize
        let edge = SIMD3<Float>(roofEdge, 5.0, roof.high)
        let start = ContinuousClock.now
        var history: [SIMD2<Float>] = []
        // The top node of the roof at the edge, at mid-span.
        let i = Int(((edge.x - structure.origin.x) / h).rounded())
        let j = Int(((edge.y - structure.origin.y) / h).rounded())
        let k = (0...structure.ez).last { structure.storedNode(i, j, $0) != nil } ?? 0
        func lattice(_ point: SIMD3<Float>) -> (Int, Int, Int) {
            let index = ((point - structure.origin) / h).rounded(.toNearestOrAwayFromZero)
            return (Int(index.x), Int(index.y), Int(index.z))
        }
        let probePoints: [(String, (Int, Int, Int), SIMD3<Float>)] = [
            ("Side wall W1, middle", lattice(SIMD3(endWallFace + 2.5, sideWalls.low, 3.5)), SIMD3(0, -1, 0)),
            (
                "Roof, middle", lattice(SIMD3((endWallFace + roofEdge) / 2, 5.0, roof.high - 0.5 * h)),
                SIMD3(0, 0, 1)
            ),
        ]
        var probes = probePoints.map { ($0.0, [SIMD2<Float>]()) }
        while solver.time < duration {
            let result = solver.advance(steps: 16, timeLimit: duration)
            if result.steps == 0 && !solver.airIsAsleep { break }
            history.append(SIMD2(Float(solver.time), structure.displacement(i, j, k).z))
            for (n, probe) in probePoints.enumerated() {
                let (a, b, c) = probe.1
                probes[n].1.append(SIMD2(Float(solver.time), dot(structure.displacement(a, b, c), probe.2)))
            }
        }
        let elapsed = ContinuousClock.now - start
        let parts: [(String, (SIMD3<Float>) -> Bool)] = [
            ("End wall", { $0.x < endWallFace }),
            ("Side walls, below 4 m", { $0.z < 4 && ($0.y < inside.low || $0.y > inside.high) }),
            (
                "Side walls, above 4 m",
                { $0.z >= 4 && $0.z < roof.low && ($0.y < inside.low || $0.y > inside.high) }
            ),
            ("Roof slab, within 0.5 m of the end wall", { $0.z >= roof.low && $0.x < endWallFace + 0.5 }),
            (
                "Roof slab, over the side walls",
                { $0.z >= roof.low && ($0.y < inside.low || $0.y > inside.high) }
            ),
            ("Roof slab, elsewhere", { $0.z >= roof.low }),
            (
                "Down-stand",
                {
                    $0.z < roof.low && $0.x > roofEdge - 0.8 && $0.y > inside.low + 0.5
                        && $0.y < inside.high - 0.5
                }
            ),
            ("Chamfers", { $0.z < roof.low && $0.y > inside.low && $0.y < inside.high }),
        ]
        var failures = parts.map { ($0.0, 0, 0) }
        for k in 0..<structure.ez {
            for j in 0..<structure.ey {
                for i in 0..<structure.ex {
                    let flag = structure.flag(i, j, k)
                    guard flag != .empty else { continue }
                    let centre = structure.referencePosition(i, j, k) + 0.5 * h
                    guard let part = parts.firstIndex(where: { $0.1(centre) }) else { continue }
                    failures[part].2 += 1
                    if flag == .eroded { failures[part].1 += 1 }
                }
            }
        }
        let ambient = scenario.atmosphere.pressure
        let peaks = zip(scenario.gauges, solver.gaugeHistories).map { gauge, samples in
            (gauge.name, (samples.map(\.pressure).max() ?? ambient) - ambient)
        }
        return Result(
            gaugePeaks: peaks, gaugeHistories: solver.gaugeHistories, edgeHistory: history,
            probes: probes.map { (name: $0.0, history: $0.1) },
            summary: structure.summary(), failures: failures,
            wallSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18)
    }
}
