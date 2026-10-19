import BlastModel
import Foundation
import simd

extension EnvelopeDebris {
    /// The debris of `damage`'s failed components on `loads` (joined by id), thrown from where
    /// they stood. `centre` is the charge's, for the hazard's rings; `blocks` the scene's rigid
    /// boxes, and `solids` each building's (keyed by its id), of which those holding a failed
    /// component are left out of the flight. Nil when nothing failed with a launch.
    public static func make(
        loads: [EnvelopeComponentLoad], damage: [EnvelopeBuildingDamage], centre: SIMD3<Float>,
        ambient: Primitive, blocks: [Box] = [], solids: [UUID: [Box]] = [:], terrain: Terrain? = nil
    ) -> EnvelopeDebris? {
        make(
            loads: loads, components: damage.flatMap(\.components), centre: centre, ambient: ambient,
            blocks: blocks, solids: solids, terrain: terrain)
    }

    /// The same from the components' damage alone; `dragScale` scales every piece's drag, to see
    /// how much the reach depends on it.
    public static func make(
        loads: [EnvelopeComponentLoad], components: [EnvelopeComponentDamage], centre: SIMD3<Float>,
        ambient: Primitive, blocks: [Box] = [], solids: [UUID: [Box]] = [:], terrain: Terrain? = nil,
        dragScale: Float = 1
    ) -> EnvelopeDebris? {
        let byID = Dictionary(loads.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var sources: [Source] = []
        var particles: [FragmentCloud.Particle] = []
        var failedRegions: [UUID: [Box]] = [:]
        do {
            for component in components {
                guard let launch = component.launch, let load = byID[component.id] else { continue }
                failedRegions[load.owner, default: []].append(load.region)
                let thrown = Self.thrown(
                    load, launch: launch, material: component.material, dragScale: dragScale)
                guard !thrown.particles.isEmpty else { continue }
                sources.append(
                    Source(
                        component: component.id, owner: component.owner, material: component.material,
                        massKg: thrown.massKg, pieces: thrown.pieces, fastestMS: thrown.fastest,
                        meanMS: thrown.mean, failedAtS: launch.timeS, pieceKg: launch.pieceKg,
                        samples: particles.count..<(particles.count + thrown.particles.count)))
                particles += thrown.particles
            }
        }
        guard !particles.isEmpty else { return nil }
        // The buildings' solids that hold no failed component stop what flies into them.
        var standing = blocks
        for (owner, boxes) in solids {
            let failed = failedRegions[owner] ?? []
            standing += boxes.filter { box in
                !failed.contains { region in
                    (0..<3).allSatisfy { region.min[$0] < box.max[$0] && box.min[$0] < region.max[$0] }
                }
            }
        }
        var cloud = FragmentCloud(particles: particles, blocks: standing, terrain: terrain, centre: centre)
        cloud.land(in: ambient)
        let impacts = cloud.impacts.sorted { $0.fragment < $1.fragment }
        return EnvelopeDebris(
            sources: sources, impacts: impacts,
            hazard: GroundHazard(
                impacts: impacts, centre: SIMD2(centre.x, centre.y), crossings: cloud.crossings))
    }

    /// One component's samples: their particles, its mass and pieces, and its launch speeds.
    static func thrown(
        _ load: EnvelopeComponentLoad, launch: DebrisLaunch, material: EnvelopeComponentDamage.Material,
        dragScale: Float = 1
    ) -> (particles: [FragmentCloud.Particle], massKg: Double, pieces: Double, fastest: Double, mean: Double)
    {
        let region = load.region
        let axes = (0..<3).filter { $0 != load.axis }
        let area = Double(region.size[axes[0]] * region.size[axes[1]])
        let massKg = launch.massPerArea * area
        let pieceKg = launch.pieceKg
        guard massKg > 0, pieceKg > 0 else { return ([], 0, 0, 0, 0) }
        let pieces = massKg / pieceKg
        // Concrete, masonry and timber fly at their speed at failure (UFC 3-340-02 §4-58.2.1: "the
        // maximum velocity of the fragment after failure vf is equal to the maximum velocity of the
        // element at incipient failure vi"): broken up, the gas leaves round them. Glass and sheets,
        // thin and whole, go on being pushed, the same for every piece, the way they were moving.
        let pushed = material.isGlass || material == .profiledSteel
        let push = pushed ? Self.freeSpeed(launch: launch, load: load) - launch.speedMS : 0
        let edges =
            (load.supportEdges?.count == 4 && load.supportEdges!.contains(true))
            ? load.supportEdges! : [true, true, true, true]
        let n = samplesEachWay
        let count = n * n
        let weight = Float(pieces / Double(count))
        let piece = launch.piece
        let mean = (2 * (piece.x * piece.y + piece.x * piece.z + piece.y * piece.z)) / 4
        var inward = SIMD3<Float>.zero
        inward[load.axis] = -Float(load.outward)
        var particles: [FragmentCloud.Particle] = []
        var speeds: [Double] = []
        for j in 0..<n {
            for i in 0..<n {
                let s = SIMD2((Float(i) + 0.5) / Float(n), (Float(j) + 0.5) / Float(n))
                let phi =
                    EnvelopeComponentRecorder.shape(s.x, low: edges[0], high: edges[1])
                    * EnvelopeComponentRecorder.shape(s.y, low: edges[2], high: edges[3])
                let speed = launch.speedMS * Double(phi) + push
                speeds.append(abs(speed))
                // At rest it falls where it was, off the face it was going to.
                let going = speed != 0 ? speed : launch.speedMS != 0 ? launch.speedMS : 1
                let normal = going > 0 ? inward : -inward
                // Its section turns about the held edge nearest it (a yield line's segment): it
                // leaves square to the section as turned, towards that edge.
                var toward = SIMD3<Float>.zero
                var nearest = Float.infinity
                for a in 0..<2 {
                    if edges[2 * a], s[a] < nearest {
                        nearest = s[a]
                        toward = .zero
                        toward[axes[a]] = -1
                    }
                    if edges[2 * a + 1], 1 - s[a] < nearest {
                        nearest = 1 - s[a]
                        toward = .zero
                        toward[axes[a]] = 1
                    }
                }
                let turn = Float(launch.rotationRad)
                let direction = simd_normalize(normal * cos(turn) + toward * sin(turn))
                var position = region.min
                position[axes[0]] += s.x * region.size[axes[0]]
                position[axes[1]] += s.y * region.size[axes[1]]
                // From the face it moves to, a little off it.
                position[load.axis] =
                    direction[load.axis] > 0 ? region.max[load.axis] + 0.01 : region.min[load.axis] - 0.01
                var particle = FragmentCloud.Particle(
                    position: position, velocity: direction * Float(abs(speed)), mass: Float(pieceKg),
                    area: mean * dragScale)
                particle.weight = weight
                particles.append(particle)
            }
        }
        return (
            particles, massKg, pieces, speeds.max() ?? 0, speeds.reduce(0, +) / Double(max(speeds.count, 1))
        )
    }
}

extension BlastSolver {
    /// The debris of the envelope components `damage` judged failed on `loads`, thrown and flown to
    /// where it lands (`EnvelopeDebris`); nil when none failed with a launch.
    public func envelopeDebris(
        scenario: Scenario, loads: [EnvelopeComponentLoad], damage: [EnvelopeBuildingDamage]
    ) -> EnvelopeDebris? {
        EnvelopeDebris.make(
            loads: loads, damage: damage, centre: scenario.charge.position,
            ambient: Primitive(density: ambientDensity, pressure: configuration.ambientPressure),
            blocks: scenario.rigidBoxes,
            solids: Dictionary(
                scenario.envelopeObjects.map { ($0.id, $0.envelope?.solids ?? []) },
                uniquingKeysWith: { a, _ in a }),
            terrain: scenario.terrain)
    }
}
