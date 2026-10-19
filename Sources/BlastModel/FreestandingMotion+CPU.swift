import Foundation
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
        /// Degrees from the ground's normal under the object (the vertical on flat ground).
        public let peakTilt: Double
        public let finalTilt: Double
        /// Tipped past the angle it balances at, on its side or roof.
        public let overturned: Bool
        /// When it left the air, nearing the cropped domain's edge, to carry on without its load.
        public let leftAir: Double?

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            id: UUID, name: String, isCar: Bool, size: SIMD3<Double>, displacement: SIMD3<Double>,
            peakSpeed: Double, peakTilt: Double, finalTilt: Double, overturned: Bool, leftAir: Double?
        ) {
            self.id = id
            self.name = name
            self.isCar = isCar
            self.size = size
            self.displacement = displacement
            self.peakSpeed = peakSpeed
            self.peakTilt = peakTilt
            self.finalTilt = finalTilt
            self.overturned = overturned
            self.leftAir = leftAir
        }
    }

    public struct Pose: Codable, Sendable {
        /// The box's geometric centre and its body-to-world quaternion (x, y, z, w), in the
        /// scene's own coordinates.
        public let centre: SIMD3<Double>
        public let orientation: SIMD4<Double>

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(centre: SIMD3<Double>, orientation: SIMD4<Double>) {
            self.centre = centre
            self.orientation = orientation
        }
    }

    public struct Frame: Codable, Sendable {
        public let time: Double
        public let poses: [Pose]

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(time: Double, poses: [Pose]) {
            self.time = time
            self.poses = poses
        }
    }

    public enum Failure: Error, LocalizedError {
        case noObjects, structure
        case tooLarge(cells: Int, cellSize: Double)

        public var errorDescription: String? {
            switch self {
            case .noObjects: "The scene has no freestanding objects."
            case .structure:
                "Beside a deformable structure, freestanding motion runs on uniform air, without finer patches."
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
    public let timings: RigidSimulationTimings
    public let cellSize: Float
    public let refinement: Int
    /// Air steps taken, and cells of the cropped air grid.
    public let steps: Int
    public let cells: Int
    /// Every object was held still: the same geometry, for the air's own cost.
    public let held: Bool
    /// The scene this was computed for, to tell when it is out of date.
    public let scenario: Scenario
    /// Impulse the objects gave the scene's deformable structures by striking them (N s); nil
    /// without a structure.
    public var structureReaction: SIMD3<Double>? = nil

    /// The memberwise initialiser, written out so that BlastCore can use it.
    package init(
        objects: [Object], coupled: [Int], frames: [Frame], duration: Double, failure: String?,
        timings: RigidSimulationTimings, cellSize: Float, refinement: Int, steps: Int, cells: Int, held: Bool,
        scenario: Scenario, structureReaction: SIMD3<Double>? = nil
    ) {
        self.objects = objects
        self.coupled = coupled
        self.frames = frames
        self.duration = duration
        self.failure = failure
        self.timings = timings
        self.cellSize = cellSize
        self.refinement = refinement
        self.steps = steps
        self.cells = cells
        self.held = held
        self.scenario = scenario
        self.structureReaction = structureReaction
    }

    public static let maximumCells = 3_000_000

    /// Up to four objects, 0.2 m air with patches four times finer over them, as the car's
    /// resolution study supports (0.05 m cells resolve its 0.15 m gap; the early impulse is
    /// within about a tenth of 0.025 m cells'); more, 0.15 m air twice finer, 0.075 m cells
    /// that also resolve the gap exactly (the study's 10 kg car overturns on them too) at a
    /// fraction of the coupling's cost.
    public static func defaultResolution(objects: Int) -> (cellSize: Float, refinement: Int) {
        objects <= 4 ? (0.2, 4) : (0.15, 2)
    }

    /// Beside a deformable structure the objects' finer patches are not yet supported, so the
    /// air is uniform: 0.1 m up to four objects, 0.15 m beyond.
    public static func defaultResolution(objects: Int, structure: Bool) -> (cellSize: Float, refinement: Int)
    {
        guard structure else { return defaultResolution(objects: objects) }
        return objects <= 4 ? (0.1, 1) : (0.15, 1)
    }

    /// The scene cropped to the objects, the charge and any deformable structures with `margin`
    /// metres around them (and above), shifted so the crop starts at the origin; blocks inside it
    /// are kept, clipped. The shift keeps each structure on its own element lattice, so that it
    /// meshes as it would where it stands.
    package static func cropped(_ scenario: Scenario, margin: Double = 2.4, cellSize: Double = 0.2) throws
        -> (
            scene: Scenario, offset: SIMD3<Double>
        )
    {
        let world = try RigidBodyWorld(scenario: scenario)
        guard !world.members.isEmpty else { throw Failure.noObjects }
        var low = SIMD3<Double>(scenario.charge.position)
        var high = low
        for member in world.members {
            for point in member.body.corners + member.supports.map(member.body.worldPoint) {
                low = simd_min(low, point)
                high = simd_max(high, point)
            }
        }
        let structures = scenario.structuralObjects.compactMap(\.structure)
        for model in structures {
            low = simd_min(low, SIMD3<Double>(model.bounds.min))
            high = simd_max(high, SIMD3<Double>(model.bounds.max))
        }
        // Whole multiples of 0.6 m, which 0.2, 0.15 and 0.1 m cells all divide.
        let step = 0.6
        low = ((low - margin) / step).rounded(.down) * step
        high = ((high + margin) / step).rounded(.up) * step
        low.z = 0
        // Further down in steps of 0.6 m until the shift is a whole number of each structure's
        // elements (the origin always is).
        let lattices = structures.flatMap { [$0.elementSize] + ($0.shellElementSize.map { [$0] } ?? []) }
        func onLattices(_ x: Double) -> Bool {
            lattices.allSatisfy { h in abs(x / Double(h) - (x / Double(h)).rounded()) < 1e-4 }
        }
        for axis in 0..<2 {
            while low[axis] > 0, !onLattices(low[axis]) { low[axis] = max(low[axis] - step, 0) }
        }
        // A terrain's nodes over the crop, moved with it; the domain kept above them.
        let terrain = scenario.terrain.flatMap { $0.isFlat ? nil : $0 }.map { whole -> Terrain in
            var piece = whole.cropped(
                low: SIMD2<Float>(Float(low.x), Float(low.y)),
                high: SIMD2<Float>(Float(high.x), Float(high.y)))
            piece.origin -= SIMD2<Float>(Float(low.x), Float(low.y))
            return piece
        }
        if let top = terrain?.highest {
            high.z = max(high.z, ((Double(top) + margin) / step).rounded(.up) * step)
        }
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
        scene.terrain = terrain
        let across = SIMD2<Float>(shift.x, shift.y)
        for object in scene.structuralObjects {
            try scene.updateStructureObject(id: object.id, model: object.structure?.moved(across: across))
        }
        return (scene, low)
    }

    /// The frame nearest a time.
    public func frame(at time: Double) -> Frame? {
        frames.min { abs($0.time - time) < abs($1.time - time) }
    }
}

/// Wall-clock seconds a rigid-body simulation spent in the air solver, the coupling, and motion
/// and contact (`ExperimentalRigidCarSimulation.Timings`).
public struct RigidSimulationTimings: Codable, Sendable {
    public var air = 0.0
    public var coupling = 0.0
    public var mechanics = 0.0

    public init() {}
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
