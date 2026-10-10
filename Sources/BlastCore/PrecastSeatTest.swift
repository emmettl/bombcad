import Foundation
import Metal
import simd

/// A precast beam's seat on a column corbel, pushed slowly to and fro along it, against measured
/// ones: N. Batalha, H. Rodrigues, A. Arêde, A. Furtado, R. Sousa and H. Varum's twelve full-scale
/// tests ("Cyclic behaviour of precast beam-to-column connections with low seismic detailing",
/// *Earthquake Eng. Struct. Dyn.*, 2022, doi:10.1002/eqe.3606; data on Mendeley Data,
/// doi:10.17632/46xpgbhsw6.1, CC BY 4.0, in `Samples/PrecastSeat`).
///
/// Each test pressed a beam end on its corbel with an axial load of 50, 100 or 150 kN and pushed
/// it along the seat in cycles of growing amplitude, to about ±48 mm, at 0.2 mm/s. The interface
/// was concrete on concrete (i0), one or two neoprene pads (i1, i2), or concrete with two dowels
/// 16 mm across 13 or 6 cm from the column's face (c1, c2). The data are the actuator's
/// displacement and force.
///
/// The model: the beam's seated end as a stiff elastic block 0.35 m square and as high, resting on
/// a bearing (a support region's connection) with the given law, for the corbel of a stiff
/// column. (On a corbel block of its own across a joint between parts, the corbel's undamped
/// ringing makes the seat stick now and then as it slides, and it dissipated 5 to 10% less.) The
/// axial load is the seat's weight. An actuator, a block beside the seat whose nodes are moved as asked, is pinned to it
/// across a gap by a second joint between parts that pushes and pulls but carries nothing along
/// it; it follows the measured displacement's reversals in turn at up to 0.25 m/s, speeding up and
/// slowing down at 2 m/s² (the law has no rate dependence), the seat damped in proportion to its
/// mass at 3,000/s so that the pin does not ring. The energy the bearing dissipates, and the force
/// at which it slides, are compared with the test's ∮ F du and its plateau.
public enum PrecastSeatTest {
    /// One test's name, as the data's files are named, and its axial load in newtons.
    public static func axialLoad(of test: String) -> Float {
        Float(test.split(separator: "_").last.flatMap { Double($0) } ?? 0) * 1000
    }

    public struct Measured: Sendable {
        /// Displacement (m) and force (N), every tenth sample of the test.
        public var samples: [SIMD2<Float>]
        /// The displacement's reversals, ignoring wiggles under 0.3 mm, in metres, and the
        /// samples they are at.
        public var reversals: [Float]
        public var reversalSamples: [Int]
        /// ∮ F du, joules, and the path's whole length, metres.
        public var energy: Float
        public var path: Float
    }

    /// Reads `test` (as `spc_i0_100`) from the folder `samples`.
    public static func measured(_ test: String, samples folder: URL) throws -> Measured {
        let text = try String(contentsOf: folder.appendingPathComponent(test + ".csv"), encoding: .utf8)
        let samples = text.split(separator: "\n").dropFirst().compactMap { line -> SIMD2<Float>? in
            let parts = line.split(separator: ",").compactMap { Float($0) }
            return parts.count == 2 ? SIMD2(parts[0] / 1000, parts[1] * 1000) : nil
        }
        var energy: Float = 0
        var path: Float = 0
        for (a, b) in zip(samples, samples.dropFirst()) {
            energy += 0.5 * (a.y + b.y) * (b.x - a.x)
            path += abs(b.x - a.x)
        }
        // Reversals: the extremes between swings of more than 0.3 mm.
        var reversals: [Float] = [0]
        var at: [Int] = [0]
        var extreme = (value: samples.first?.x ?? 0, index: 0)
        var rising = true
        for (index, sample) in samples.enumerated() {
            let d = sample.x
            if rising ? d > extreme.value : d < extreme.value {
                extreme = (d, index)
            } else if abs(d - extreme.value) > 3e-4 {
                reversals.append(extreme.value)
                at.append(extreme.index)
                rising.toggle()
                extreme = (d, index)
            }
        }
        reversals.append(extreme.value)
        at.append(extreme.index)
        return Measured(
            samples: samples, reversals: reversals, reversalSamples: at, energy: energy, path: path)
    }

    /// The force at which a test's seat slides: the median of its forces' sizes where it is 5 mm
    /// or more from the middle, in newtons.
    public static func plateau(_ samples: [SIMD2<Float>]) -> Float {
        let sliding = samples.filter { abs($0.x) >= 5e-3 }.map { abs($0.y) }.sorted()
        return sliding.isEmpty ? 0 : sliding[sliding.count / 2]
    }

    public struct Result: Sendable {
        public var test: String
        /// The force while the seat slides: the model's, the work its joint dissipated over the
        /// distance it slid; the test's, its `plateau`; in newtons. And the energy dissipated, in joules: the model's joint's own sliding work,
        /// the test's ∮ F du. (The force at any instant chatters about its mean as the seat hops
        /// on its joint, and rings on the actuator's pin, so the joint's own work is the measure.)
        public var sliding: Float = 0
        /// How far the model's seat slid along the corbel, in metres.
        public var slid: Float = 0
        public var energy: Float = 0
        public var measuredSliding: Float = 0
        public var measuredEnergy: Float = 0
        /// The largest the seat fell short of the path, in metres.
        public var lag: Float = 0
        /// (displacement, force) every 10 ms.
        public var history: [SIMD2<Float>] = []
        public var wallSeconds: Double = 0
    }

    /// Runs `test` with the seat tied by `law`, along at most `reversals` of its reversals (all by
    /// default), on elements of `elementSize`.
    public static func run(
        device: MTLDevice, test: String, samples folder: URL, law: Anchorage, reversals limit: Int? = nil,
        elementSize: Float = 0.175
    ) throws -> Result {
        let started = ContinuousClock.now
        let measured = try measured(test, samples: folder)
        let h = elementSize
        let side: Float = 0.35
        let top = 2 * side + h
        let seat = Box(min: SIMD3(0, 0, side + h), max: SIMD3(side, side, top))
        // The actuator: a block beside the seat, across a gap of an element, moved as asked.
        let actuator = Box(min: SIMD3(-2 * h, 0, side + h), max: SIMD3(-h, side, top))
        let material = StructureMaterial.elastic(density: 2400, youngsModulus: 30e9, poissonRatio: 0.2)
        var model = StructureModel(
            solids: [seat, actuator], material: material, elementSize: h, fixedBase: false)
        var joint = law
        joint.betweenParts = nil
        // The actuator's pin: push and pull across, nothing along.
        let pin = Anchorage(
            shearStiffness: 1, tensileStrength: 1e9, tensionOpening: 1, cohesion: 0, cohesionSlip: 0,
            friction: 0,
            side: .negativeX, betweenParts: true)
        model.supports = [
            Box(
                min: SIMD3(0.01, -0.01, side + h - 0.01),
                max: SIMD3(side + 0.01, side + 0.01, side + h + 0.01)),
            Box(min: SIMD3(-h - 0.01, -0.01, side + h - 0.01), max: SIMD3(0.01, side + 0.01, top + 0.01)),
        ]
        model.supportAnchorages = [joint, pin]
        let solver = try StructureSolver(device: device, model: model)
        solver.groundContact = false

        var seatNodes: [Int] = []
        var driven: [Int] = []
        var seatMass: Float = 0
        solver.mutateNodes { nodes in
            for k in 0...solver.ez {
                for j in 0...solver.ey {
                    for i in 0...solver.ex {
                        guard let n = solver.storedNode(i, j, k) else { continue }
                        let p = solver.referencePosition(i, j, k)
                        if p.x < -h + 1e-3 {
                            driven.append(n)
                            nodes[n].flags |= 8
                        } else if p.z > side + h / 2 {
                            seatNodes.append(n)
                            seatMass += nodes[n].mass
                        }
                    }
                }
            }
        }
        func seatDisplacement() -> Float {
            var total: Float = 0
            solver.mutateNodes { nodes in for n in seatNodes { total += nodes[n].mass * nodes[n].ux } }
            return total / seatMass
        }
        func drive(_ speed: Float) {
            solver.mutateNodes { nodes in for n in driven { nodes[n].velocity = SIMD3(speed, 0, 0) } }
        }
        // The axial load, as the seat's weight, brought on over 50 ms.
        let load = axialLoad(of: test)
        let dt = Double(solver.criticalTimeStep)
        solver.damping = 100
        drive(0)
        for n in 1...10 {
            solver.gravity = load / seatMass * Float(n) / 10
            solver.advance(steps: Int((0.005 / dt).rounded()))
        }
        solver.advance(steps: Int((0.05 / dt).rounded()))
        // The pin rings undamped in tension, and once the ringing outran the actuator the seat stuck
        // and slipped by turns (its bearing then dissipated half what it should). Damping in
        // proportion to mass stops it: it drags the seat, which the pin makes up, and leaves the
        // bearing's own work alone.
        solver.damping = 3000
        let start = seatDisplacement()

        let control = 0.005
        let stepsPerControl = max(1, Int((control / dt).rounded()))
        let step = Float(stepsPerControl) * Float(dt)
        let speed: Float = 0.25
        var position: Float = 0  // the actuator's
        var result = Result(test: test)
        var previous = (displacement: Float(0), force: Float(0))

        var recorded = 0.0
        let path = Array(measured.reversals.prefix(limit ?? measured.reversals.count))
        // It speeds up and slows down at 2 m/s², so as not to strike the seat at each reversal.
        let acceleration: Float = 2
        var velocity: Float = 0
        for goal in path.dropFirst() {
            while abs(goal - position) > 1e-7 {
                let remaining = goal - position
                let wanted =
                    (remaining > 0 ? 1 : -1) * min(speed, (2 * acceleration * abs(remaining)).squareRoot())
                velocity += max(-acceleration * step, min(acceleration * step, wanted - velocity))
                var move = velocity * step
                if abs(move) >= abs(remaining) || move * remaining <= 0 && abs(remaining) < 1e-6 {
                    move = remaining
                    velocity = 0
                }
                drive(move / step)
                solver.advance(steps: stepsPerControl)
                position += move
                // The actuator's force on the seat, along the push.
                let force = solver.pairSummary(support: 1)?.force.x ?? 0
                let moved = seatDisplacement() - start
                result.slid += abs(moved - previous.displacement)
                previous = (moved, force)

                result.lag = max(result.lag, abs(position - moved))
                if solver.time - recorded >= 0.01 {
                    result.history.append(SIMD2(moved, force))
                    recorded = solver.time
                }
            }
        }
        // Over the same reversals, the test's own energy and largest forces.
        let end = measured.reversalSamples[path.count - 1]
        let span = measured.samples[0...end]
        result.measuredEnergy = zip(span, span.dropFirst()).reduce(0) {
            $0 + 0.5 * ($1.0.y + $1.1.y) * ($1.1.x - $1.0.x)
        }
        result.measuredSliding = Self.plateau(Array(span))
        result.energy = solver.anchorSummary()?.dissipated ?? 0
        result.sliding = result.energy / max(result.slid, 1e-9)
        let elapsed = ContinuousClock.now - started
        result.wallSeconds =
            Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        return result
    }
}
