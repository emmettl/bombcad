import Foundation

extension FireSpread {
    /// What a fire keeps of its district between layers while the charge is dragged or a slider
    /// moves (emmettl/bombcad-work#113): its buildings' fixed parts (outline, height, cladding, roof,
    /// use, fuel, windows), laid out again only when the scene's buildings or their construction, the
    /// use taken for untagged buildings or the cladding override change; its neighbours
    /// (`exposures`), again only when their reach (the wind's speed) first grows past the first
    /// list's, then for the strongest wind's reach, cut to each wind's after; and its fires'
    /// stages, again only when the buildings or the fire's parameters change. Each layer then
    /// refreshes only each building's broken glass and failed walls from the estimate. A layer made
    /// through the cache is the one made without it, to the bit (`FireSpreadCacheTests`): the same
    /// values, worked out by the same code in the same order.
    public final class LayerCache: @unchecked Sendable {
        private struct Fixed {
            /// The scene's objects, every one (compared at once while their storage is the same).
            var objects: [SceneObject]
            var constructions: [EnvelopeConstruction]?
            var untaggedUse: BuildingUse
            var cladding: Cladding?
            var buildings: [Building]
            /// Each id's first building: glass and walls are summed per id, as a scene's ids are its own.
            var index: [UUID: Int]
            /// Any later buildings of the same id, given the first's shares as the uncached path gives them.
            var repeats: [(first: Int, later: Int)]
        }

        private var fixed: Fixed?
        /// The last glass's and walls' owners, and each one's building (nil for none): a drag's
        /// estimates give the same sides in the same order, so their buildings are looked up once.
        private var glassSlots: (owners: [UUID], slots: [Int?]) = ([], [])
        private var structureSlots: (owners: [UUID], slots: [Int?]) = ([], [])
        /// The neighbours within `built`, the most any wind reaches, and those within the last reach.
        private var neighbours: (built: Double, all: [[Exposure]], reach: Double, within: [[Exposure]])?
        private var stages: (parameters: Parameters, stages: [Stages])?
        /// The last scene a what-if was laid on, and the constructions it gave.
        private var whatIf:
            (
                objects: [SceneObject], constructions: [EnvelopeConstruction]?, whatIf: LiveResponse.WhatIf,
                built: [EnvelopeConstruction]?
            )?
        private let lock = NSLock()
        /// What the last layer through the cache laid out again: its buildings, neighbours, stages.
        public private(set) var rebuilt: (buildings: Bool, neighbours: Bool, stages: Bool) = (
            false, false, false
        )

        public init() {}

        /// `whatIf.applied(to: scene)`, the quick estimate's what-if laid on the fire's buildings as on
        /// the estimate's, the project unchanged: laid on again only when the scene's buildings, their
        /// constructions or the what-if change, so that a drag keeps the buildings' fixed parts and a
        /// what-if picked or cleared lays them out again.
        public func scene(_ scene: Scenario, as whatIf: LiveResponse.WhatIf) -> Scenario {
            guard !whatIf.isEmpty else { return scene }
            return lock.withLock {
                if let kept = self.whatIf, kept.whatIf == whatIf, kept.objects == scene.objects,
                    kept.constructions == scene.envelopeConstructions
                {
                    var copy = scene
                    copy.envelopeConstructions = kept.built
                    return copy
                }
                let built = whatIf.applied(to: scene)
                self.whatIf = (
                    scene.objects, scene.envelopeConstructions, whatIf, built.envelopeConstructions
                )
                return built
            }
        }

        /// `District(buildings: buildings(scene:glass:structure:untaggedUse:cladding:), wind:,
        /// parameters:)`, its fixed parts kept: under one lock, so that a layer cancelled while the
        /// next is made never pairs one scene's buildings with another's neighbours.
        func district(
            scene: Scenario, glass: [FacadeLoadSurrogate.SideGlass],
            structure: [FacadeLoadSurrogate.StructureChance],
            untaggedUse: BuildingUse, cladding: Cladding?, wind: Wind, parameters: Parameters
        ) -> District {
            lock.withLock {
                let buildings = buildings(
                    scene: scene, glass: glass, structure: structure, untaggedUse: untaggedUse,
                    cladding: cladding)
                // A list for a lesser reach is the longer list's start (`exposures` sorts by separation,
                // then target, and each pair's exposure is the reach's own): the wind's speed moved
                // takes the list the strongest wind's reach gives, once, and then cuts it.
                let reach = parameters.reach(wind: wind)
                func cut(_ all: [[Exposure]]) -> [[Exposure]] {
                    all.map { list in Array(list.prefix { $0.separation <= reach }) }
                }
                rebuilt.neighbours = false
                if let kept = neighbours, reach <= kept.built {
                    if kept.reach != reach { neighbours = (kept.built, kept.all, reach, cut(kept.all)) }
                } else {
                    // The first list, for this reach; past it, for any wind's.
                    let built =
                        neighbours == nil ? reach : max(reach, parameters.reach(wind: Wind(speedMS: 1e3)))
                    let all = FireSpread.exposures(buildings, reach: built)
                    neighbours = (built, all, reach, built == reach ? all : cut(all))
                    rebuilt.neighbours = true
                }
                rebuilt.stages = stages?.parameters != parameters
                if rebuilt.stages {
                    stages = (parameters, buildings.map { FireSpread.stages(of: $0, parameters: parameters) })
                }
                return District(
                    buildings: buildings, wind: wind, parameters: parameters, exposures: neighbours!.within,
                    stages: stages!.stages)
            }
        }

        /// The buildings, their fixed parts kept and their glass and walls refreshed; under the lock.
        private func buildings(
            scene: Scenario, glass: [FacadeLoadSurrogate.SideGlass],
            structure: [FacadeLoadSurrogate.StructureChance],
            untaggedUse: BuildingUse, cladding: Cladding?
        ) -> [Building] {
            let objects = scene.objects
            if let fixed, fixed.untaggedUse == untaggedUse, fixed.cladding == cladding,
                fixed.constructions == scene.envelopeConstructions, fixed.objects == objects
            {
                rebuilt.buildings = false
            } else {
                let laid = FireSpread.buildings(scene: scene, untaggedUse: untaggedUse, cladding: cladding)
                fixed = Fixed(
                    objects: objects, constructions: scene.envelopeConstructions, untaggedUse: untaggedUse,
                    cladding: cladding, buildings: laid,
                    index: Dictionary(laid.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a }),
                    repeats: [])
                let index = fixed!.index
                fixed!.repeats = laid.indices.compactMap { n in
                    let first = index[laid[n].id]!
                    return first == n ? nil : (first, n)
                }
                neighbours = nil
                stages = nil
                glassSlots = ([], [])
                structureSlots = ([], [])
                rebuilt.buildings = true
            }
            var buildings = fixed!.buildings
            let index = fixed!.index
            // Each side's share broken, summed in the glass's order as `buildings(scene:glass:…)` sums it.
            var broken = [Double](repeating: 0, count: 4 * buildings.count)
            var counted = [Double](repeating: 0, count: 4 * buildings.count)
            func slots(_ owners: some Collection<UUID>, _ kept: inout (owners: [UUID], slots: [Int?]))
                -> [Int?]
            {
                if !owners.elementsEqual(kept.owners) { kept = (Array(owners), owners.map { index[$0] }) }
                return kept.slots
            }
            let glassSlot = slots(glass.lazy.map(\.owner), &glassSlots)
            for (side, slot) in zip(glass, glassSlot) where (0...1).contains(side.axis) {
                guard let n = slot else { continue }
                let k = 2 * side.axis + (side.outward > 0 ? 1 : 0)
                broken[4 * n + k] += side.fractionBroken
                counted[4 * n + k] += 1
            }
            for n in buildings.indices {
                for k in 0..<4 where counted[4 * n + k] > 0 {
                    buildings[n].brokenGlass[k] = min(max(broken[4 * n + k] / counted[4 * n + k], 0), 1)
                }
            }
            for (c, slot) in zip(structure, slots(structure.lazy.map(\.owner), &structureSlots)) {
                if let n = slot { buildings[n].wallsFailed = c.wallsHeavy }
            }
            for (first, later) in fixed!.repeats {
                buildings[later].brokenGlass = buildings[first].brokenGlass
                buildings[later].wallsFailed = buildings[first].wallsFailed
            }
            return buildings
        }
    }
}
