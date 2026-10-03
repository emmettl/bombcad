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
/// - the 1.8 m end wall, the partition and the foundation are rigid (the paper treats the end
///   walls so); the side walls are held where they meet the end wall, the partition and the
///   foundation;
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

    // Coordinates: x from the inner face of the end wall towards the partition, y across the
    // chamber (outer faces at 1 and 9 m, leaving air either side), z up from the foundation's
    // underside.
    static let sideWalls = (low: Float(1.0), high: Float(9.0))
    static let inside = (low: Float(1.8), high: Float(8.2))
    static let floorTop: Float = 0.8
    static let roof = (low: Float(6.15), high: Float(6.95))
    static let roofEdge: Float = 3.8
    static let partitionFace: Float = 5.0
    static let mirror: Float = 5.5

    /// The charges' centres, on the mirror.
    public static let chargePositions: [SIMD3<Float>] = [
        SIMD3(5.5, 3.8, 1.5), SIMD3(5.5, 6.2, 1.5), SIMD3(5.5, 3.8, 3.5), SIMD3(5.5, 6.2, 3.5),
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
        var solids = [w1, w3, s1]
        if downstand {
            solids.append(
                Box(
                    min: SIMD3(roofEdge - 0.8, inside.low, roof.high - 1.85),
                    max: SIMD3(roofEdge, inside.high, roof.low)))
        }
        if haunches {
            let room = (x: Float(0), y: inside, z: floorTop)
            // Along the roof's underside: at both side walls and at the end wall.
            solids += haunch(
                along: 0, from: 0, to: roofEdge, corner: [1: room.y.low, 2: roof.low], into: [1: 1, 2: -1],
                h: elementSize)
            solids += haunch(
                along: 0, from: 0, to: roofEdge, corner: [1: room.y.high, 2: roof.low], into: [1: -1, 2: -1],
                h: elementSize)
            solids += haunch(
                along: 1, from: room.y.low, to: room.y.high, corner: [0: 0, 2: roof.low],
                into: [0: 1, 2: -1], h: elementSize)
            // At the foot of the side walls, and where they meet the end wall.
            solids += haunch(
                along: 0, from: 0, to: partitionFace, corner: [1: room.y.low, 2: room.z], into: [1: 1, 2: 1],
                h: elementSize)
            solids += haunch(
                along: 0, from: 0, to: partitionFace, corner: [1: room.y.high, 2: room.z],
                into: [1: -1, 2: 1], h: elementSize)
            solids += haunch(
                along: 2, from: room.z, to: roof.low, corner: [0: 0, 1: room.y.low], into: [0: 1, 1: 1],
                h: elementSize)
            solids += haunch(
                along: 2, from: room.z, to: roof.low, corner: [0: 0, 1: room.y.high], into: [0: 1, 1: -1],
                h: elementSize)
        }
        var model = StructureModel(
            solids: solids, material: material(), elementSize: elementSize, fixedBase: true)
        // Held at the end wall's face, in the partition and in the foundation.
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
        var boxes: [Box] = [Box(min: SIMD3(0, inside.low, 0), max: SIMD3(mirror, inside.high, floorTop))]
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
            Gauge("Side wall W1, 2.3 m in", at: SIMD3(2.3, inside.low + 0.05, 2.8)),
            Gauge("Side wall W3, 1.5 m in", at: SIMD3(1.5, inside.high - 0.05, 2.8)),
            Gauge("Roof, 1.5 m in", at: SIMD3(1.5, 5.0, roof.low - 0.05)),
            Gauge("End wall, middle", at: SIMD3(0.05, 5.0, 2.8)),
        ]
        var scenario = Scenario(
            name: "Internal explosion (Shang et al.)", domainSize: SIMD3(mirror, 10, 9), boxes: boxes,
            charge: Charge(mass: 25 * chargeScale, position: chargePositions[0]), gauges: gauges,
            structure: model)
        scenario.additionalCharges = chargePositions.dropFirst().map {
            Charge(mass: 25 * chargeScale, position: $0)
        }
        // The end wall's inner face and the mirror bound the air at x; the ground below.
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
        public var summary: StructureSummary
        /// Failed elements in each part: side walls below and above 4 m, the roof slab, and the
        /// down-stand with the chamfers inside the chamber.
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

    /// Runs a variant of the test's scenario.
    public static func run(device: MTLDevice, scenario: Scenario, cellSize: Float, duration: Double) throws
        -> Result
    {
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: cellSize)
        guard let structure = solver.structure else { throw BlastError.allocationFailed("structure") }
        let h = structure.model.elementSize
        let edge = SIMD3<Float>(roofEdge, 5.0, roof.high)
        let start = ContinuousClock.now
        var history: [SIMD2<Float>] = []
        // The top node of the roof at the edge, at mid-span.
        let i = Int(((edge.x - structure.origin.x) / h).rounded())
        let j = Int(((edge.y - structure.origin.y) / h).rounded())
        let k = (0...structure.ez).last { structure.storedNode(i, j, $0) != nil } ?? 0
        while solver.time < duration {
            let result = solver.advance(steps: 16, timeLimit: duration)
            if result.steps == 0 && !solver.airIsAsleep { break }
            history.append(SIMD2(Float(solver.time), structure.displacement(i, j, k).z))
        }
        let elapsed = ContinuousClock.now - start
        let parts: [(String, (SIMD3<Float>) -> Bool)] = [
            ("Side walls, below 4 m", { $0.z < 4 && ($0.y < inside.low || $0.y > inside.high) }),
            (
                "Side walls, above 4 m",
                { $0.z >= 4 && $0.z < roof.low && ($0.y < inside.low || $0.y > inside.high) }
            ),
            ("Roof slab", { $0.z >= roof.low }),
            ("Down-stand and chamfers", { $0.z < roof.low && $0.y > inside.low && $0.y < inside.high }),
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
            summary: structure.summary(), failures: failures,
            wallSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18)
    }
}
