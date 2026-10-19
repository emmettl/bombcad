import BlastModel
import Foundation
import Metal
import simd

extension PrecastSeatTest {
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
