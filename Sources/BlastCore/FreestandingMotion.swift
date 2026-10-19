import BlastModel
import Foundation
import Metal
import simd

extension FreestandingMotion {
    /// Runs `duration` seconds, recording every `frameInterval`. `progress` gets the simulated
    /// time; returning false from `shouldContinue` stops early with what has been recorded.
    /// `cellSize` and `refinement` default to `defaultResolution`, and the patches' memory to
    /// 64 MB an object, at least 512 MB.
    public static func compute(
        device: MTLDevice, scenario: Scenario, duration: Double = 1.5, frameInterval: Double = 0.02,
        cellSize: Float? = nil, refinement: Int? = nil, coupled: [Int]? = nil, held: Bool = false,
        refinementMemory: Int? = nil, progress: ((Double) -> Void)? = nil,
        shouldContinue: (() -> Bool)? = nil
    ) throws -> FreestandingMotion {
        let count = (scenario.rigidObjects?.count ?? 0) + (scenario.rigidCars?.count ?? 0)
        let structure = !scenario.structuralObjects.isEmpty
        let resolution = defaultResolution(objects: count, structure: structure)
        let cellSize = cellSize ?? resolution.cellSize
        let refinement = refinement ?? resolution.refinement
        guard !structure || refinement <= 1 else { throw Failure.structure }
        let refinementMemory = refinementMemory ?? max(512 << 20, count * (64 << 20))
        let (scene, offset) = try cropped(scenario, cellSize: Double(cellSize))
        // Tilt from the ground's normal under the object's centre: on a slope, lying on it is
        // upright.
        func tilt(_ member: ExperimentalRigidWorldSimulation.Member) -> Double {
            guard let terrain = scene.terrain else { return member.tilt }
            let centre = member.centreOfMass
            return member.tilt(from: terrain.surface(at: SIMD2(centre.x, centre.y)).normal)
        }
        var configuration = SolverConfiguration()
        configuration.refinement = refinement
        if refinement > 1 { configuration.refinementMemory = refinementMemory }
        let simulation = try ExperimentalRigidWorldSimulation(
            device: device, scenario: scene, cellSize: cellSize, configuration: configuration,
            motion: held ? .held : .free, coupled: coupled)
        let ids = (scenario.rigidObjects ?? []).map(\.id) + (scenario.rigidCars ?? []).map(\.id)
        let start = simulation.members
        var peakSpeed = [Double](repeating: 0, count: start.count)
        var peakTilt = [Double](repeating: 0, count: start.count)
        var frames: [Frame] = []
        func record() {
            frames.append(
                Frame(
                    time: simulation.air.time,
                    poses: simulation.members.map { member in
                        let corners = member.corners
                        return Pose(
                            centre: (corners[0] + corners[7]) / 2 + offset, orientation: member.orientation)
                    }))
        }
        record()
        var failure: String?
        var next = frameInterval
        var reported = 0.0
        while simulation.air.time < duration - 1e-8, shouldContinue?() ?? true {
            do { try simulation.advance(steps: 1, timeLimit: duration) } catch {
                failure = "\(error)"
                break
            }
            for (n, member) in simulation.members.enumerated() {
                peakSpeed[n] = max(peakSpeed[n], simd_length(member.velocity))
                peakTilt[n] = max(peakTilt[n], tilt(member))
            }
            if simulation.air.time >= next - 1e-9 {
                record()
                next += frameInterval
            }
            if simulation.air.time >= reported + 0.01 {
                reported = simulation.air.time
                progress?(reported)
            }
        }
        let objects = zip(start, simulation.members).enumerated().map { n, pair -> Object in
            let (first, last) = pair
            let size = simd_quatd(vector: first.orientation).inverse.act(first.corners[7] - first.corners[0])
            let balance: Double
            if first.isCar, let car = (scenario.rigidCars ?? []).first(where: { $0.id == ids[n] }) {
                balance = atan(car.staticStabilityFactor)
            } else {
                // A box tips over an edge of its base: the narrower half-width over the height.
                balance = atan(min(size.x, size.y) / size.z)
            }
            return Object(
                id: ids[n], name: last.name, isCar: last.isCar, size: size,
                displacement: last.centreOfMass - first.centreOfMass, peakSpeed: peakSpeed[n],
                peakTilt: peakTilt[n], finalTilt: tilt(last), overturned: tilt(last) > balance * 180 / .pi,
                leftAir: simulation.leftAir[n])
        }
        return FreestandingMotion(
            objects: objects, coupled: simulation.coupled, frames: frames, duration: simulation.air.time,
            failure: failure, timings: simulation.timings, cellSize: cellSize, refinement: refinement,
            steps: simulation.air.stepCount, cells: simulation.air.grid.cellCount, held: held,
            scenario: scenario, structureReaction: structure ? simulation.reaction : nil)
    }
}
