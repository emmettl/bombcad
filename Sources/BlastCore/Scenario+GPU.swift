import BlastModel
import Foundation
import Metal
import RadialBlast
import simd

extension BlastSolver {
    /// Creates a solver sized for `scenario` and loads it, with `configuration` but the
    /// scenario's atmosphere and reflecting faces.
    public convenience init(
        device: MTLDevice, commandQueue: MTLCommandQueue? = nil, scenario: Scenario, cellSize: Float,
        configuration: SolverConfiguration = SolverConfiguration()
    ) throws {
        var configuration = configuration
        configuration.ambientPressure = scenario.atmosphere.pressure
        configuration.reflectiveFaces = scenario.reflectiveFaces
        try self.init(
            device: device, commandQueue: commandQueue, grid: scenario.grid(cellSize: cellSize),
            configuration: configuration)
        try load(scenario)
    }

    /// Voxelises the scenario's blocks and structure, fills the air, deposits the charge, places
    /// the gauges and builds the structural mesh.
    ///
    /// The scenario's domain must match the solver's grid.
    public func load(_ scenario: Scenario) throws {
        // On earth or rock, the charges as the air sees them: part of their energy goes into the
        // ground. Rigid ground leaves the scene as it is.
        let scenario = configuration.ground.map { scenario.coupled(to: $0) } ?? scenario
        try scenario.validateObjectOwnership()
        clearEnvelopeExposure()
        mappedStart = []
        configuration.ambientPressure = scenario.atmosphere.pressure
        configuration.reflectiveFaces = scenario.reflectiveFaces
        ambientSoundSpeed = scenario.atmosphere.soundSpeed(gamma: configuration.gamma)
        ambientDensity = scenario.atmosphere.density
        let grid = self.grid
        let dx = grid.cellSize

        mutateMask { mask in
            mask.update(repeating: 0)
            for box in scenario.rigidBoxes.map({ $0.holdingCells(of: dx) }) {
                // A cell is solid when its centre lies inside the block (widened where it is too thin
                // to hold one; see `Box.holdingCells`).
                let low = box.min / dx - 0.5
                let high = box.max / dx - 0.5
                let iRange = cellRange(low.x, high.x, count: grid.nx)
                let jRange = cellRange(low.y, high.y, count: grid.ny)
                let kRange = cellRange(low.z, high.z, count: grid.nz)
                for k in kRange {
                    for j in jRange {
                        let row = grid.index(0, j, k)
                        for i in iRange { mask[row + i] = 1 }
                    }
                }
            }
            // Glazing closes its window even where it is thinner than a cell (`paneCells`).
            for object in scenario.envelopeObjects {
                guard let envelope = object.envelope else { continue }
                for pane in envelope.panes.indices {
                    for cell in envelope.paneCells(pane, grid: grid) { mask[cell] = 1 }
                }
            }
        }
        var cut: TerrainCutGeometry?
        if let terrain = scenario.terrain, configuration.cutsTerrain(of: scenario, cellSize: grid.cellSize) {
            try terrain.validate(domain: scenario.domainSize)
            // A surface that crosses no cell (one lying on cells' faces) is its staircase.
            cut = TerrainCutGeometry(
                terrain: terrain, grid: grid,
                samples: TerrainCutGeometry.samples(
                    ratio: Self.keepsAirUnrefined(scenario) ? 1 : configuration.refinement,
                    levels: configuration.refinementLevels))
            if cut?.cutColumns.isEmpty == true { cut = nil }
        }
        if let cut {
            // The cells below each column's first cell of air are solid; the cut cells hold air.
            // A cell less than half air with a block standing on it is solid too: its air would be
            // shut in between the ground and the block, and the difference it could pass up no
            // further would come back to it, magnified as many times as it is small, every step
            // (see `redistributeCutDefects`). A building whose base lies below the ground makes them.
            let firstAir = cut.firstAirCells
            mutateMask { mask in
                for j in 0..<grid.ny {
                    for i in 0..<grid.nx {
                        let first = Int(firstAir[i + grid.nx * j])
                        for k in 0..<first { mask[grid.index(i, j, k)] = 1 }
                        if first + 1 < grid.nz, mask[grid.index(i, j, first + 1)] != 0,
                            cut.alpha(i, j, first) < TerrainCutGeometry.receivingShare
                        {
                            mask[grid.index(i, j, first)] = 1
                        }
                    }
                }
            }
            terrainSurface = cut.surfaceCells
        } else if let terrain = scenario.terrain {
            try terrain.validate(domain: scenario.domainSize)
            // A cell is solid when its centre lies below the surface, as for a block.
            let surface = terrain.surfaceCells(grid: grid)
            mutateMask { mask in
                for j in 0..<grid.ny {
                    for i in 0..<grid.nx {
                        for k in 0..<Int(surface[i + grid.nx * j]) { mask[grid.index(i, j, k)] = 1 }
                    }
                }
            }
            terrainSurface = surface
        }
        rigidBoxes = scenario.rigidBoxes
        terrain = scenario.terrain
        try loadCongestion(scenario.congestion ?? [])
        terrainCut = try cut.map { try TerrainCutBuffers(geometry: $0, device: device) }
        cappedSliverBuffer = nil
        // The structure is added to the mask on the GPU, by the same rule that later tracks it.
        try scenario.validateStructuralSeparation()
        // Each structure runs with the regime and loading the scene gives it, for its defaults.
        try setStructures(
            scenario.structuralObjects.map { object in
                var object = object
                if let model = object.structure {
                    object.setStructure(model.detectingRegime(in: scenario).standing(on: scenario.terrain))
                }
                return object
            })
        // Soft ground, if chosen, under every structure's solid elements (shells keep the hard ground).
        for body in bodies { body.solids?.groundStiffness = configuration.groundStiffness ?? 0 }

        try loadDeflagration(scenario)
        fill(
            uniform: Primitive(density: scenario.atmosphere.density, pressure: scenario.atmosphere.pressure))
        // A charge inside a block, the ground or a structure releases nothing, on uniform cells and
        // refined alike. The balloon would otherwise lay it in whatever air lies within its two
        // cells: on uniform cells the air around a building's block, on refined air's finer cells
        // none, the charge lost (a district's charge on a map building, claim #54).
        let all = charges(of: scenario)
        blockedCharges = all.indices.filter { all[$0].mass > 0 && scenario.blocks(all[$0].position) }
        let mappings = mappings(for: scenario)
        let gaugeCells = scenario.gauges.map { gauge -> (i: Int, j: Int, k: Int) in
            var cell = nearestFluidCell(to: gauge.position)
            // On cut cells a gauge in a cell less than half air reads the first one above that is.
            if let column = terrainCut?.geometry.column(cell.i, cell.j) {
                cell.k = max(cell.k, Int(column.w))
            }
            return cell
        }
        let gaugeCentres = gaugeCells.map { grid.cellCentre($0.i, $0.j, $0.k) }
        let positions = all.map(\.position)
        pendingFirings = []
        firings = []
        firingCharges = all
        firingProbes = gaugeCentres
        var laid: [(blast: SphericalBlast, mapping: ChargeMapping)] = []
        var clockStart = 0.0
        if !mappings.isEmpty {
            let (solutions, start) = solveMapped(mappings, probes: gaugeCentres)
            clockStart = start
            // Charges too near anything to be mapped are laid as the balloon, first, so that the
            // mapped ones are laid over nothing of theirs; the balloon stands for its charge some
            // time after it fired, and is laid as the mapped ones are, at their clock. Those that
            // fire after it are laid when they do.
            for (k, charge) in all.enumerated()
            where !mappings.contains(where: { $0.index == k }) && !blockedCharges.contains(k) {
                if charge.firingTime <= start {
                    deposit(charge)
                    if charge.firingTime > 0 {
                        firings.append(Firing(charge: charge, laidAt: start, how: .balloon))
                    }
                } else {
                    pendingFirings.append(
                        PendingFiring(time: charge.firingTime, charge: charge, stage: .balloon))
                }
            }
            for (blast, mapping) in zip(solutions, mappings) {
                if mapping.charge.firingTime < start {
                    laid.append((blast, mapping))
                    if mapping.charge.firingTime > 0 {
                        firings.append(Firing(charge: mapping.charge, laidAt: start, how: .mapped))
                    }
                } else {
                    pendingFirings.append(
                        PendingFiring(
                            time: mapping.charge.firingTime, charge: mapping.charge,
                            stage: .check(mapping, blast)))
                }
            }
            layMapped(laid, among: positions)
        } else if let deflagration = scenario.deflagration {
            deflagrationStage?.initialUnburnt = depositCloud(deflagration)
        } else {
            for (k, charge) in all.enumerated() where !blockedCharges.contains(k) {
                if charge.firingTime == 0 {
                    deposit(charge)
                } else {
                    pendingFirings.append(
                        PendingFiring(time: charge.firingTime, charge: charge, stage: .balloon))
                }
            }
        }
        pendingFirings.sort { $0.time < $1.time }
        setGauges(cells: gaugeCells, points: scenario.gauges.map(\.position))
        restart()
        // Bodies must start apart: contact between them is no reason to bond them.
        if bodyEnvelopesOverlap { throw SceneObjectError.interObjectContact }
        if couplingCapacityExceeded {
            throw BlastError.allocationFailed("local coupling tiles for the current geometry")
        }
        if scenario.structuralObjects.count > 1, configuration.refinement > 1, refinement == nil {
            throw BlastError.allocationFailed("multi-body air refinement")
        }
        if !laid.isEmpty {
            recordMapped(laid, among: positions, gauges: gaugeCentres, start: clockStart)
        }
        // The refinement's ceiling spares each charge's near field (`refinementCeilingExemption`).
        ceilingExemptions = charges(of: scenario).filter { $0.mass > 0 }.map {
            (position: $0.position, radius: SolverConfiguration.refinementCeilingExemption * cbrt($0.mass))
        }
        // Every load: a solver loaded again without a ceiling must not keep the last one's.
        applyFacadeBand()
    }

    /// A charge laid down from its own one-dimensional solution: which of the scene's charges
    /// (0 the main one, then the additional ones), how far out, and how many reflecting faces it
    /// lies on (the ground, a model's mirror planes), each of which mirrors it.
    struct ChargeMapping {
        var index: Int
        var charge: Charge
        var radius: Float
        var mirrors: Int
    }

    /// The scene's charges, the main one first, at t = 0 whatever delay it was given.
    func charges(of scenario: Scenario) -> [Charge] {
        var main = scenario.charge
        main.delay = nil
        return [main] + (scenario.additionalCharges ?? [])
    }

    /// The charges whose blast can be solved in one dimension before it meets anything, each as
    /// far as it can (`mapping(of:among:scenario:)`); the rest are laid as the balloon. Empty if
    /// mapping is off or not possible.
    func mappings(for scenario: Scenario) -> [ChargeMapping] {
        // The one-dimensional solution has the ideal gas and hot air, and afterburning without its
        // extinction limit; not gravity or sub-grid mixing. It does not radiate: with radiative
        // cooling the gas starts losing its heat once mapped, the fireball's first moments radiating
        // little of it.
        guard configuration.mappedCharge, configuration.airModel != .dissociating,
            configuration.afterburnLimit == nil, configuration.gravity == nil, configuration.mixing == nil,
            scenario.deflagration == nil
        else { return [] }
        let charges = charges(of: scenario)
        return charges.indices.compactMap { k in
            // A blocked charge is not laid at all (`blockedCharges`).
            guard charges[k].mass > 0, !scenario.blocks(charges[k].position) else { return nil }
            let others = charges.indices.filter { $0 != k }.map { charges[$0].position }
            return mapping(of: charges[k], among: others, scenario: scenario).map {
                ChargeMapping(index: k, charge: charges[k], radius: $0.radius, mirrors: $0.mirrors)
            }
        }
    }

    /// How far a charge's blast can be solved in one dimension before it meets anything: 0.8 of
    /// the distance to the nearest block, structure, pane or open face of the domain (a reflecting
    /// face the charge sits on, the ground or a mirror plane, mirrors it instead), half the way to the nearest of the scene's
    /// `others` charges (where their shells could first meet), and within the cells' and the
    /// scaled reach's caps; nil if that would not reach 3 cells.
    func mapping(of charge: Charge, among others: [SIMD3<Float>], scenario: Scenario)
        -> (radius: Float, mirrors: Int)?
    {
        let c = charge.position
        let dx = grid.cellSize
        let shaped = scenario.terrain.map { !$0.isFlat } ?? false
        let size = scenario.domainSize
        let faces: [(BoundaryFaces, Float)] = [
            (.xMin, c.x), (.xMax, size.x - c.x), (.yMin, c.y), (.yMax, size.y - c.y), (.zMin, c.z),
            (.zMax, size.z - c.z),
        ]
        // The reflecting faces the charge lies on (the ground unless it is shaped, a model's mirror
        // planes): each mirrors the blast, as a charge of twice the mass in free air.
        let mirrors = faces.filter { face, distance in
            distance <= 0.5 * dx && scenario.reflectiveFaces.contains(face) && !(face == .zMin && shaped)
        }.map(\.0)
        var nearest = Float.infinity
        if shaped, let terrain = scenario.terrain {
            // The surface, sampled a quarter cell apart within the furthest the blast may be mapped.
            let reach = min(
                configuration.mappedChargeCells * dx,
                configuration.mappedChargeScaledReach * cbrt(charge.mass))
            let step = 0.25 * dx
            let count = Int((2 * reach / step).rounded(.up))
            for b in 0...count {
                for a in 0...count {
                    let p = SIMD2(c.x, c.y) - reach + step * SIMD2(Float(a), Float(b))
                    nearest = min(nearest, simd_distance(SIMD3(p.x, p.y, terrain.height(at: p)), c))
                }
            }
        }
        var obstacles = scenario.rigidBoxes
        obstacles.append(contentsOf: scenario.structuralObjects.compactMap { $0.structure?.bounds })
        obstacles.append(contentsOf: (scenario.ventPanels ?? []).filter { $0.releasePressure > 0 }.map(\.box))
        for box in obstacles {
            nearest = min(nearest, simd_distance(simd_clamp(c, box.min, box.max), c))
        }
        for (face, distance) in faces where !mirrors.contains(face) {
            nearest = min(nearest, distance)
        }
        let cap = min(
            configuration.mappedChargeCells * dx, configuration.mappedChargeScaledReach * cbrt(charge.mass))
        // Glazing, which closes its cells of the mask without a block (envelopes' walls are blocks).
        for object in scenario.envelopeObjects {
            guard let envelope = object.envelope else { continue }
            for pane in envelope.panes.indices {
                for cell in envelope.paneCells(pane, grid: grid) {
                    let i = cell % grid.nx
                    let j = (cell / grid.nx) % grid.ny
                    let k = cell / (grid.nx * grid.ny)
                    let corner = SIMD3(Float(i), Float(j), Float(k)) * dx
                    nearest = min(nearest, simd_distance(simd_clamp(c, corner, corner + dx), c))
                }
            }
        }
        var radius = min(0.8 * nearest, cap)
        for other in others { radius = min(radius, 0.5 * simd_distance(other, c)) }
        return radius >= 3 * dx ? (radius, mirrors.count) : nil
    }

    /// The ratio the air's finest level will be refined by at the next `restart()`, or 1.
    var refinementAtRestart: Int {
        guard configuration.refinement > 1 else { return 1 }
        return configuration.refinementLevels > 1
            ? configuration.refinement * configuration.refinement : configuration.refinement
    }

    /// Radius of the sphere the charge's energy is spread over: the physical charge size,
    /// but never fewer than a couple of cells (fine cells, where the air is refined) so the
    /// initial discontinuity is resolvable.
    public func balloonRadius(for charge: Charge) -> Float {
        let explosiveDensity: Float = 1600
        let physical = Float(cbrt(3 * Double(charge.mass) / (4 * Double.pi * Double(explosiveDensity))))
        return max(physical, configuration.minimumBalloonCells * grid.cellSize / Float(refinementAtRestart))
    }

    /// Adds the charge's mass and energy to the fluid cells inside its balloon radius.
    ///
    /// Cells are weighted by the fraction of their volume inside the sphere, and the totals are
    /// normalised over fluid cells only, so a charge resting on the ground (or against a wall)
    /// still releases all of its energy into the air.
    public func deposit(_ charge: Charge) {
        guard charge.mass > 0 else { return }
        // Where the fine cells' smaller balloon holds no air (the charge hard against a block whose
        // coarse cells are solid), the coarse cells' takes it, as on uniform cells.
        if refinementAtRestart > 1, depositRefined(charge) { return }
        depositCoarse(charge)
    }

    /// The balloon laid on the grid's own cells, refined or not.
    func depositCoarse(_ charge: Charge) {
        guard charge.mass > 0 else { return }
        let grid = self.grid
        let dx = grid.cellSize
        // The coarse cells' balloon (refinement's minimum is of fine cells).
        let radius = max(balloonRadius(for: charge), configuration.minimumBalloonCells * dx)
        let low = grid.cell(containing: charge.position - radius)
        let high = grid.cell(containing: charge.position + radius)
        let samples = 5

        var weights: [(index: Int, fraction: Float)] = []
        for k in low.k...high.k {
            for j in low.j...high.j {
                for i in low.i...high.i where !isSolid(i, j, k) {
                    var inside = 0
                    for c in 0..<samples {
                        for b in 0..<samples {
                            for a in 0..<samples {
                                let offset = (SIMD3(Float(a), Float(b), Float(c)) + 0.5) / Float(samples)
                                let point = (SIMD3(Float(i), Float(j), Float(k)) + offset) * dx
                                if simd_distance_squared(point, charge.position) <= radius * radius {
                                    inside += 1
                                }
                            }
                        }
                    }
                    if inside > 0 {
                        let fraction = Float(inside) / Float(samples * samples * samples)
                        weights.append((grid.index(i, j, k), fraction))
                    }
                }
            }
        }
        // A cut cell holds air in only its fluid share of the sphere's part of it, a porous cell
        // in its open share.
        let total = weights.reduce(Float(0)) { $0 + $1.fraction * Float(openShare($1.index)) }
        guard total > 0 else { return }

        let volume = total * dx * dx * dx
        let massDensity = charge.mass / volume
        let energyDensity = charge.energy / volume
        // Keeping other charges' fine cells (none on uniform cells).
        editState { cells in
            for (index, fraction) in weights {
                cells[index].density += massDensity * fraction
                cells[index].energy += energyDensity * fraction
            }
        }
        largestCharge = max(largestCharge, charge.mass)
        // The products, all unburnt; the air they displace keeps its oxygen.
        mutateSpecies { species in
            for (index, fraction) in weights { species[index].x += massDensity * fraction }
        }
    }

    /// Where the air will be refined, the charge is laid down in the fine cells, as on a grid that
    /// fine: a sphere a couple of coarse cells across is a blocky cube, which the fine cells
    /// resolve, and which then drives a stronger blast along its faces' normals than the sphere it
    /// stands for (30% higher peaks 1.5 radii out). The coarse cells take the mean of their fine
    /// cells, and `restart()` gives the fine cells their own share once the patches are placed.
    /// Whether any fine cell within the balloon was air: if none was, nothing is laid.
    private func depositRefined(_ charge: Charge) -> Bool {
        let grid = self.grid
        let r = refinementAtRestart
        let fine = grid.cellSize / Float(r)
        let radius = balloonRadius(for: charge)
        let low = SIMD3<Int>(simd_max((charge.position - radius) / fine, .zero).rounded(.down))
        let high = simd_min(
            SIMD3<Int>(((charge.position + radius) / fine).rounded(.down)),
            SIMD3(grid.nx, grid.ny, grid.nz) &* r &- 1)
        let samples = 5
        // Sample points are measured from the cell's centre, relative to the charge, so that cells
        // mirrored about it do mirrored arithmetic and count the same points.
        let charged = charge.position / fine
        var weights: [(fine: SIMD3<Int>, fraction: Float)] = []
        for k in low.z...high.z {
            for j in low.y...high.y {
                for i in low.x...high.x {
                    let cell = SIMD3(i, j, k) / r
                    let centre = SIMD3<Float>(Float(i), Float(j), Float(k)) + 0.5
                    guard !isSolid(cell.x, cell.y, cell.z),
                        !(rigidBoxes ?? []).contains(where: { $0.contains(centre * fine) }),
                        terrain?.contains(centre * fine) != true
                    else { continue }
                    let fromCharge = centre - charged
                    var inside = 0
                    for c in 0..<samples {
                        for b in 0..<samples {
                            for a in 0..<samples {
                                let offset = (SIMD3(Float(a), Float(b), Float(c)) - 2) / Float(samples)
                                if simd_length_squared((fromCharge + offset) * fine) <= radius * radius {
                                    inside += 1
                                }
                            }
                        }
                    }
                    if inside > 0 {
                        weights.append((SIMD3(i, j, k), Float(inside) / Float(samples * samples * samples)))
                    }
                }
            }
        }
        let total = weights.reduce(Float(0)) { $0 + $1.fraction }
        guard total > 0 else { return false }
        let volume = total * fine * fine * fine
        let massDensity = charge.mass / volume
        let energyDensity = charge.energy / volume
        // Each coarse cell's share is summed in double precision, where the sum of its fine cells'
        // is exact, so that it does not depend on their order (a centred charge stays symmetric).
        var coarse: [Int: SIMD2<Double>] = [:]
        for (cell, fraction) in weights {
            let added = SIMD2(massDensity, energyDensity) * fraction
            fineDeposit[cell, default: .zero] += added
            coarse[grid.index(cell.x / r, cell.y / r, cell.z / r), default: .zero] += SIMD2<Double>(added)
        }
        let share = 1 / Double(r * r * r)
        editState { cells in
            for (index, added) in coarse {
                cells[index].density += Float(added.x * share)
                cells[index].energy += Float(added.y * share)
            }
        }
        largestCharge = max(largestCharge, charge.mass)
        mutateSpecies { species in
            for (index, added) in coarse { species[index].x += Float(added.x * share) }
        }
        return true
    }

    /// The cell containing `point`, or the closest fluid cell if that one is solid.
    public func nearestFluidCell(to point: SIMD3<Float>) -> (i: Int, j: Int, k: Int) {
        let home = grid.cell(containing: point)
        guard isSolid(home.i, home.j, home.k) else { return home }
        var best = home
        var bestDistance = Float.infinity
        let reach = 4
        for k in (home.k - reach)...(home.k + reach) {
            for j in (home.j - reach)...(home.j + reach) {
                for i in (home.i - reach)...(home.i + reach)
                where grid.contains(i, j, k) && !isSolid(i, j, k) {
                    let distance = simd_distance_squared(grid.cellCentre(i, j, k), point)
                    if distance < bestDistance {
                        bestDistance = distance
                        best = (i, j, k)
                    }
                }
            }
        }
        return best
    }
}

private func cellRange(_ low: Float, _ high: Float, count: Int) -> Range<Int> {
    let lower = min(max(Int(low.rounded(.up)), 0), count)
    let upper = min(max(Int(high.rounded(.up)), lower), count)
    return lower..<upper
}
