import Foundation
import Metal
import simd

/// How a scene's freestanding objects move after the blast: displacement, speed and tipping, and
/// their poses over time, from `ExperimentalRigidWorldSimulation` on a domain cropped around the
/// objects and the charge. Every object is in the air, with finer patches over each (see
/// `defaultResolution`), and they strike each other and the scene's blocks.
public struct FreestandingMotion: Codable, Sendable {
    public struct Object: Codable, Sendable {
        public let id: UUID
        public let name: String
        public let isCar: Bool
        /// The box: a car's shell, or the object itself.
        public let size: SIMD3<Double>
        public let displacement: SIMD3<Double>
        public let peakSpeed: Double
        public let peakTilt: Double
        public let finalTilt: Double
        /// Tipped past the angle it balances at, on its side or roof.
        public let overturned: Bool
        /// When it left the air, nearing the cropped domain's edge, to carry on without its load.
        public let leftAir: Double?
    }

    public struct Pose: Codable, Sendable {
        /// The box's geometric centre and its body-to-world quaternion (x, y, z, w), in the
        /// scene's own coordinates.
        public let centre: SIMD3<Double>
        public let orientation: SIMD4<Double>
    }

    public struct Frame: Codable, Sendable {
        public let time: Double
        public let poses: [Pose]
    }

    public enum Failure: Error, LocalizedError {
        case noObjects, structure
        case tooLarge(cells: Int, cellSize: Double)

        public var errorDescription: String? {
            switch self {
            case .noObjects: "The scene has no freestanding objects."
            case .structure: "Freestanding motion needs a scene without a deformable structure."
            case .tooLarge(let cells, let cellSize):
                "The objects and the charge span \(cells) air cells of \(cellSize) m; place them closer together (at most 3 million)."
            }
        }
    }

    public let objects: [Object]
    /// The objects in the air (all of them unless `compute` was told otherwise).
    public let coupled: [Int]
    public let frames: [Frame]
    public let duration: Double
    /// Where it stopped early, if the reference failed (an object left the cropped domain).
    public let failure: String?
    /// Wall-clock seconds in the air solver, the coupling, and motion and contact.
    public let timings: ExperimentalRigidCarSimulation.Timings
    public let cellSize: Float
    public let refinement: Int
    /// Air steps taken, and cells of the cropped air grid.
    public let steps: Int
    public let cells: Int
    /// Every object was held still: the same geometry, for the air's own cost.
    public let held: Bool
    /// The scene this was computed for, to tell when it is out of date.
    public let scenario: Scenario

    public static let maximumCells = 3_000_000

    /// Up to four objects, 0.2 m air with patches four times finer over them, as the car's
    /// resolution study supports (0.05 m cells resolve its 0.15 m gap; the early impulse is
    /// within about a tenth of 0.025 m cells'); more, 0.15 m air twice finer, 0.075 m cells
    /// that also resolve the gap exactly (the study's 10 kg car overturns on them too) at a
    /// fraction of the coupling's cost.
    public static func defaultResolution(objects: Int) -> (cellSize: Float, refinement: Int) {
        objects <= 4 ? (0.2, 4) : (0.15, 2)
    }

    /// The scene cropped to the objects and the charge with `margin` metres around them (and
    /// above), shifted so the crop starts at the origin; blocks inside it are kept, clipped.
    static func cropped(_ scenario: Scenario, margin: Double = 2.4, cellSize: Double = 0.2) throws -> (
        scene: Scenario, offset: SIMD3<Double>
    ) {
        let world = try RigidBodyWorld(scenario: scenario)
        guard !world.members.isEmpty else { throw Failure.noObjects }
        guard scenario.structure == nil else { throw Failure.structure }
        var low = SIMD3<Double>(scenario.charge.position)
        var high = low
        for member in world.members {
            for point in member.body.corners + member.supports.map(member.body.worldPoint) {
                low = simd_min(low, point)
                high = simd_max(high, point)
            }
        }
        // Whole multiples of 0.6 m, which 0.2, 0.15 and 0.1 m cells all divide.
        let step = 0.6
        low = ((low - margin) / step).rounded(.down) * step
        high = ((high + margin) / step).rounded(.up) * step
        low.z = 0
        let size = high - low
        let cells = Int(
            (size.x / cellSize).rounded() * (size.y / cellSize).rounded() * (size.z / cellSize).rounded())
        guard cells <= maximumCells else { throw Failure.tooLarge(cells: cells, cellSize: cellSize) }
        var scene = scenario
        scene.domainSize = SIMD3<Float>(size)
        let shift = SIMD3<Float>(-low)
        scene.charge.position += shift
        scene.additionalCharges = scenario.additionalCharges?.map { charge in
            var moved = charge
            moved.position += shift
            return moved
        }
        scene.rigidObjects = try scenario.rigidObjects?.map {
            try RigidObjectDefinition(
                id: $0.id, name: $0.name, shape: $0.shape, position: $0.position - low, mass: $0.mass,
                orientation: $0.orientation, centreOfMass: $0.centreOfMass, inertia: $0.inertia,
                staticFriction: $0.staticFriction, slidingFriction: $0.slidingFriction)
        }
        scene.rigidCars = try scenario.rigidCars?.map { try $0.moved(to: $0.position - low) }
        let domain = SIMD3<Float>(size)
        scene.boxes = scenario.boxes.compactMap { box in
            let lo = simd_max(box.min + shift, .zero)
            let hi = simd_min(box.max + shift, domain)
            guard all(lo .< hi) else { return nil }
            return Box(min: lo, max: hi)
        }
        scene.gauges = []
        return (scene, low)
    }

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
        let resolution = defaultResolution(objects: count)
        let cellSize = cellSize ?? resolution.cellSize
        let refinement = refinement ?? resolution.refinement
        let refinementMemory = refinementMemory ?? max(512 << 20, count * (64 << 20))
        let (scene, offset) = try cropped(scenario, cellSize: Double(cellSize))
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
                peakTilt[n] = max(peakTilt[n], member.tilt)
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
                peakTilt: peakTilt[n], finalTilt: last.tilt, overturned: last.tilt > balance * 180 / .pi,
                leftAir: simulation.leftAir[n])
        }
        return FreestandingMotion(
            objects: objects, coupled: simulation.coupled, frames: frames, duration: simulation.air.time,
            failure: failure, timings: simulation.timings, cellSize: cellSize, refinement: refinement,
            steps: simulation.air.stepCount, cells: simulation.air.grid.cellCount, held: held,
            scenario: scenario)
    }

    /// The frame nearest a time.
    public func frame(at time: Double) -> Frame? {
        frames.min { abs($0.time - time) < abs($1.time - time) }
    }
}

extension RigidCarDefinition {
    /// The same car with some inputs changed, validated as on construction. A new mass scales the
    /// moments of inertia with it; `id` gives a duplicate its own identity.
    public func edited(
        id: UUID? = nil, name: String? = nil, position: SIMD3<Double>? = nil,
        orientation: SIMD4<Double>? = nil,
        mass: Double? = nil, staticFriction: Double? = nil, slidingFriction: Double? = nil
    ) throws -> RigidCarDefinition {
        let newMass = mass ?? self.mass
        return try RigidCarDefinition(
            id: id ?? self.id, name: name ?? self.name, position: position ?? self.position, mass: newMass,
            wheelbase: wheelbase, track: track, centreOfMass: centreOfMass,
            inertia: inertia * (newMass / self.mass),
            shellSize: shellSize, groundClearance: groundClearance,
            orientation: orientation ?? self.orientation,
            wheels: wheels, suspension: suspension, staticFriction: staticFriction ?? self.staticFriction,
            slidingFriction: slidingFriction ?? self.slidingFriction)
    }

    /// The same car with its footprint centre moved.
    public func moved(to position: SIMD3<Double>) throws -> RigidCarDefinition {
        try edited(position: position)
    }
}

extension RigidObjectDefinition {
    /// The same object with some inputs changed, validated as on construction. Explicit moments
    /// of inertia scale with a new mass and are kept otherwise; a uniform box's follow its size.
    public func edited(
        id: UUID? = nil, name: String? = nil, position: SIMD3<Double>? = nil,
        orientation: SIMD4<Double>? = nil,
        mass: Double? = nil, size: SIMD3<Double>? = nil, staticFriction: Double? = nil,
        slidingFriction: Double? = nil
    ) throws -> RigidObjectDefinition {
        let newMass = mass ?? self.mass
        let shape = size.map { Shape.box(size: $0) } ?? self.shape
        return try RigidObjectDefinition(
            id: id ?? self.id, name: name ?? self.name, shape: shape, position: position ?? self.position,
            mass: newMass, orientation: orientation ?? self.orientation, centreOfMass: centreOfMass,
            inertia: inertia.map { $0 * (newMass / self.mass) },
            staticFriction: staticFriction ?? self.staticFriction,
            slidingFriction: slidingFriction ?? self.slidingFriction)
    }
}
