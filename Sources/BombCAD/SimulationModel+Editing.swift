import BlastCore
import BlastRender
import DocumentKit
import Foundation
import Metal
import Observation
import simd

// SimulationModel's selection and editing: the structure and envelope picked out for editing, undo,
// and the layout's edits. Split from SimulationModel.swift (emmettl/bombcad-work#52).
extension SimulationModel {
    var editedObject: SceneObject? {
        let scene = settings.scenario
        switch selection {
        case .solid(let ref), .opening(let ref), .support(let ref): return scene.object(id: ref.objectID)
        case .part(let ref): return scene.structuralObject(sourceID: ref.modelID)
        case .imported(let id):
            if let object = scene.structuralObject(sourceID: id) { return object }
        default: break
        }
        return selectedStructureID.flatMap { scene.object(id: $0) }.flatMap { $0.structure == nil ? nil : $0 }
            ?? scene.structuralObject
    }
    var editedStructure: StructureModel? { editedObject?.structure }
    var editedMaterial: StructureMaterial { editedStructure?.material ?? .reinforcedConcrete }
    /// Shells where every piece is meshed so, as timber always is, whatever was chosen.
    var editedElementKind: ElementKind {
        guard let structure = editedStructure else { return .solid }
        return structure.isAllShells ? .shell : structure.elementKind
    }
    var editedSolidElementSize: Float { editedObject?.preferredSolidElementSize ?? settings.solidElementSize }
    func rememberSolidElementSize(_ size: Float, objectID: UUID? = nil) {
        guard let id = objectID ?? editedObject?.id else { return }
        do { try settings.scenario.setPreferredSolidElementSize(id: id, size: size) } catch {
            errorMessage = error.localizedDescription
        }
        if settings.scenario.structuralObject?.id == id { settings.solidElementSize = size }
    }
    func selectStructure(id: UUID?) {
        selectedStructureID = id
        selection = nil
    }

    func addIndependentStructure() {
        let scene = settings.scenario
        let centre = scene.domainSize / 2
        let x =
            scene.structuralObjects.compactMap { $0.structure?.bounds.max.x }.max().map { $0 + 1 } ?? centre.x
        var body = StructureModel(
            solids: [Box(x: x...(x + 0.25), y: (centre.y - 2)...(centre.y + 2), height: 3)],
            elementSize: settings.solidElementSize)
        body.autoReinforce()
        do {
            let id = try settings.scenario.addStructureObject(
                body, name: "Structure \(scene.structuralObjects.count + 1)")
            selectStructure(id: id)
        } catch { errorMessage = error.localizedDescription }
    }

    func removeEditedStructure() {
        guard let object = editedObject else { return }
        if let source = object.sourceModelID {
            guard settings.scenario.importedModels?.first(where: { $0.id == source })?.isAttached != true
            else {
                errorMessage = "Detach or remove this imported model through its source controls."
                return
            }
        }
        do { try settings.scenario.updateStructureObject(id: object.id, model: nil) } catch {
            errorMessage = error.localizedDescription
            return
        }
        selectedStructureID = nil
        selection = nil
    }

    func useEditedEnvelope() {
        guard !isPreparingImports, let object = editedObject else { return }
        do {
            var scene = settings.scenario
            try scene.useEnvelope(id: object.id)
            try scene.validateObjectOwnership()
            settings.scenario = scene
            selectedStructureID = nil
            selection = nil
        } catch { errorMessage = error.localizedDescription }
    }

    /// The refinement toward the chosen buildings priced against refining everywhere, by the
    /// advisor's estimate of the run's time (s); nil where the refinement goes anywhere.
    var refineTowardCost: (toward: Double, everywhere: Double)? {
        guard settings.sharpShocks, !settings.refineToward.isEmpty else { return nil }
        let run = ProjectRunSettings(model: self)
        var everywhere = run
        everywhere.refineToward = nil
        return (
            run.costEstimate(settings.scenario).seconds, everywhere.costEstimate(settings.scenario).seconds
        )
    }

    /// Whether the refinement goes toward the scene's object `id` (`SimulationSettings.refineToward`).
    func refinesToward(_ id: UUID) -> Bool { settings.refineToward.contains(id) }

    /// Adds the object `id` to the buildings the refinement goes toward, along corridors from each
    /// charge, or takes it away; the refinement is turned on with it.
    func toggleRefineToward(_ id: UUID) {
        if let index = settings.refineToward.firstIndex(of: id) {
            settings.refineToward.remove(at: index)
        } else {
            settings.refineToward.append(id)
            settings.sharpShocks = true
        }
    }

    func removeEnvelope(id: UUID) {
        guard !isPreparingImports, settings.scenario.object(id: id)?.envelope != nil else { return }
        do { try settings.scenario.removeObject(id: id) } catch { errorMessage = error.localizedDescription }
        settings.refineToward.removeAll { $0 == id }
    }

    /// Sets what an envelope's walls are built of, as the user's choice, keeping its other
    /// properties (or the default's).
    func setEnvelopeWalls(id: UUID, to walls: EnvelopeConstruction.Kind) {
        guard settings.scenario.object(id: id)?.envelope != nil else { return }
        let old = settings.scenario.envelopeConstruction(for: id)
        guard old.walls != walls || old.source != .user else { return }
        var construction = old
        construction.walls = walls
        if walls != old.walls {
            construction.wallThicknessM = EnvelopeConstruction.defaultThickness(walls)
        }
        construction.source = .user
        construction.detail = "chosen in the editor"
        settings.scenario.setEnvelopeConstruction(construction)
    }

    /// Changes an envelope's construction as the user's choice: `edit` applied to the one
    /// recorded for it (or the default).
    func editEnvelopeConstruction(id: UUID, _ edit: (inout EnvelopeConstruction) -> Void) {
        guard settings.scenario.object(id: id)?.envelope != nil else { return }
        let old = settings.scenario.envelopeConstruction(for: id)
        var construction = old
        edit(&construction)
        construction.source = .user
        construction.detail = "set in the editor"
        guard construction != old else { return }
        settings.scenario.setEnvelopeConstruction(construction)
    }

    /// Colours each side by `chances` (a protective plan's residual chances), or stops.
    func showProtectionPlan(_ chances: [UUID: [(axis: Int, outward: Int, chance: Double)]]) {
        protectionPlanChances = chances
        applyEnvelopeDamageColours()
    }

    /// Writes a protective plan's glazing into the project: each building it changes given its
    /// sides' new windows (`EnvelopeConstruction.sideGlazing`), as the user's choice.
    func applyProtectionPlan(_ plan: ProtectionSearch.Plan, model: ProtectionModel.Model, label: String) {
        for var construction in ProtectionModel.constructions(plan, model: model, scene: settings.scenario) {
            construction.source = .user
            construction.detail = "glazing from protective plan \(label)"
            settings.scenario.setEnvelopeConstruction(construction)
        }
    }

    /// Makes the current layout a step that can be undone back to, if it has changed.
    func recordEdit() {
        guard !sweep.isActive else { return }
        let inputs = currentInputs
        guard let previous = settledInputs, inputs != previous else {
            settledInputs = inputs
            return
        }
        undoStack.append(previous)
        if undoStack.count > Self.undoLimit { undoStack.removeFirst(undoStack.count - Self.undoLimit) }
        redoStack.removeAll()
        settledInputs = inputs
    }

    func undo() {
        guard !sweep.isActive else { return }
        recordEdit()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(currentInputs)
        settledInputs = previous
        applyInputs(previous)
    }

    func redo() {
        guard !sweep.isActive, let next = redoStack.popLast() else { return }
        undoStack.append(currentInputs)
        settledInputs = next
        applyInputs(next)
    }

    var currentInputs: SimulationInputs {
        SimulationInputs(
            scenario: settings.scenario, settings: ProjectRunSettings(model: self), fragments: fragmentSpec,
            groundShock: groundShockSpec,
            thermal: thermalSpec, cloud: cloudSpec)
    }

    /// Inputs from the undo history, fragments and all.
    private func applyInputs(_ inputs: SimulationInputs) {
        fragmentEdit?.cancel()
        groundShockEdit?.cancel()
        thermalEdit?.cancel()
        cloudEdit?.cancel()
        isApplyingInputs = true
        fragmentSpec = inputs.fragments
        groundShockSpec = inputs.groundShock
        thermalSpec = inputs.thermal
        cloudSpec = inputs.cloud
        isApplyingInputs = false
        applyExperimentInputs(inputs)
    }

    var runtimeInputsMatch: Bool {
        guard var loaded = loadedRunSettings else { return false }
        loaded.duration = duration
        return scenario == settings.scenario && loaded == ProjectRunSettings(model: self)
    }

    var hasPendingGPUWork: Bool { batchInFlight || rebuildPending || isPreparingImports || isLoadingInputs }
    var experimentIsReady: Bool {
        runtimeInputsMatch && !hasPendingGPUWork && !isRunning && time == 0 && errorMessage == nil
    }

    func useRunInputs(id: UUID) throws {
        guard !sweep.isActive, let run = savedRuns.first(where: { $0.id == id }) else {
            throw ProjectFileError.invalid("Finish the sweep before restoring a saved run's inputs.")
        }
        let inputs = SimulationInputs(
            scenario: run.scenario, settings: run.settings, fragments: run.fragments?.spec,
            groundShock: run.groundShock?.spec,
            thermal: run.thermal?.spec, cloud: run.cloud?.spec)
        try inputs.validate()
        recordEdit()
        if inputs != currentInputs {
            undoStack.append(currentInputs)
            if undoStack.count > Self.undoLimit { undoStack.removeFirst(undoStack.count - Self.undoLimit) }
            redoStack.removeAll()
        }
        settledInputs = inputs
        applyInputs(inputs)
        camera = .framing(inputs.scenario)
    }

    /// Experiment cases bypass debounce and undo. Their owner preserves the document's baseline.
    func applyExperimentInputs(_ inputs: SimulationInputs) {
        isLoadingInputs = true
        rebuildTask?.cancel()
        isRunning = false
        completedRunSettings = nil
        selection = nil
        inspectedImportID = nil
        settings.scenario = inputs.scenario
        settings.resolution = Resolution(rawValue: inputs.settings.resolution)!
        settings.detailedCharge = inputs.settings.detailedCharge
        settings.sharpShocks = inputs.settings.sharpShocks
        settings.shockLevels = inputs.settings.shockLevels ?? 1
        settings.shockThreshold = inputs.settings.shockThreshold ?? 0.1
        settings.refinementCeiling = inputs.settings.refinementCeiling
        settings.adaptiveSubsteps = inputs.settings.adaptiveSubsteps ?? false
        settings.gravity = inputs.settings.gravity ?? false
        settings.terrainCutCells = inputs.settings.cutsTerrain(over: inputs.scenario)
        settings.outlineByOverlap = inputs.settings.countsByOverlap(over: inputs.scenario)
        settings.ventsGlazing = inputs.settings.ventsGlazing(over: inputs.scenario)
        settings.settlesStructures = inputs.settings.settlesStructures(over: inputs.scenario)
        settings.mappedStart = inputs.settings.startsMapped
        settings.radiativeCooling = inputs.settings.cools
        settings.refineToward = inputs.settings.refineToward ?? []
        settings.softGround = inputs.settings.groundStiffness != nil
        settings.groundStiffness = inputs.settings.groundStiffness ?? SolverConfiguration.soilSubgradeModulus
        settings.ground = inputs.settings.ground ?? .rigid
        settings.waterTable = inputs.settings.waterTable
        settings.solidElementSize = inputs.settings.solidElementSize
        duration = inputs.settings.duration
        handledSettings = settings
        if importsNeedResampling {
            settingsChanged()
        } else {
            isPreparingImports = false
            requestRebuild()
        }
    }

    var domainSize: SIMD3<Float> { settings.scenario.domainSize }

    /// The farthest the view zooms out (`zoomLimits`): three times the domain's longest side, and
    /// no less than SceneView's own 600 m.
    var farthestZoom: Float { max(3 * max(domainSize.x, domainSize.y, domainSize.z, farFieldSpan), 600) }
    /// The width of the square about the domain's centre that holds the far set's buildings, m.
    private var farFieldSpan: Float {
        let centre = SIMD2(settings.scenario.domainSize.x, settings.scenario.domainSize.y) / 2
        var reach: Float = 0
        for building in farFieldSet?.buildings ?? [] {
            for block in building.envelope.blocks {
                reach = max(
                    reach, abs(block.min.x - centre.x), abs(block.max.x - centre.x),
                    abs(block.min.y - centre.y),
                    abs(block.max.y - centre.y))
            }
        }
        return 2 * reach
    }

    /// The inspected building's blocks, its name, and whether it lies beyond the air.
    var inspectedEnvelopeBuilding: (name: String, blocks: [Box], far: Bool)? {
        guard let id = inspectedEnvelope else { return nil }
        if let object = settings.scenario.object(id: id), let envelope = object.envelope {
            return (object.name, envelope.blocks, false)
        }
        if let building = farFieldSet?.buildings.first(where: { $0.id == id }) {
            return (building.name, building.envelope.blocks, true)
        }
        return nil
    }

    /// The box picked out for editing, if it still exists; else the inspected building's bounds.
    var highlightedBox: Box? {
        let scenario = settings.scenario
        if selection == nil, let blocks = inspectedEnvelopeBuilding?.blocks, let first = blocks.first {
            return blocks.dropFirst().reduce(first) {
                Box(min: simd_min($0.min, $1.min), max: simd_max($0.max, $1.max))
            }
        }
        switch selection {
        case .block(let id): return scenario.object(id: id)?.fixedBox
        case .solid(let reference):
            guard let index = scenario.componentIndex(reference) else { return nil }
            guard let solids = scenario.object(id: reference.objectID)?.structure?.solids,
                solids.indices.contains(index)
            else { return nil }
            return solids[index]
        case .opening(let reference):
            guard let index = scenario.componentIndex(reference) else { return nil }
            guard let openings = scenario.object(id: reference.objectID)?.structure?.openings,
                openings.indices.contains(index)
            else {
                return nil
            }
            return openings[index]
        case .support(let reference):
            guard let index = scenario.componentIndex(reference) else { return nil }
            guard let supports = scenario.object(id: reference.objectID)?.structure?.supports,
                supports.indices.contains(index)
            else {
                return nil
            }
            return supports[index]
        case .part(let reference):
            guard let body = scenario.structuralObject(sourceID: reference.modelID)?.structure,
                let part = StructureEditing.parts(in: scenario).first(where: { $0.id == reference })
            else { return nil }
            return StructureEditing.bounds(of: part.regions, in: body)
        case .gauge(let index):
            guard scenario.gauges.indices.contains(index) else { return nil }
            let position = scenario.gauges[index].position
            return Box(min: position - 0.25, max: position + 0.25)
        case .building(let id):
            return scenario.object(id: id)?.bounds
        case .imported(let id):
            guard let imported = scenario.importedModels?.first(where: { $0.id == id && $0.isAttached })
            else { return nil }
            let volumes =
                imported.behavior == .deformable
                ? scenario.structuralObject(sourceID: id)?.structure?.solids ?? [] : imported.preview.boxes
            return volumes.first.map { first in
                volumes.dropFirst().reduce(first) {
                    Box(min: simd_min($0.min, $1.min), max: simd_max($0.max, $1.max))
                }
            }
        case nil: return nil
        }
    }
    var inspectedImport: ImportedModel? {
        settings.scenario.importedModels?.first { $0.id == inspectedImportID }
    }
    func inspectImport(id: UUID) {
        guard let imported = settings.scenario.importedModels?.first(where: { $0.id == id }) else { return }
        isRunning = false
        selection = imported.isAttached ? .imported(id) : nil
        inspectedImportID = id
    }

    /// Whether another gauge can be added; the solver records at most `BlastSolver.maxGauges`.
    var canAddGauge: Bool { settings.scenario.gauges.count < BlastSolver.maxGauges }

    /// Adds a gauge 1.5 m above the middle of the ground.
    func addGauge() {
        guard canAddGauge else { return }
        let centre = settings.scenario.domainSize / 2
        let name = "Gauge \(settings.scenario.gauges.count + 1)"
        settings.scenario.gauges.append(Gauge(name, at: SIMD3(centre.x, centre.y, 1.5)))
        selection = .gauge(settings.scenario.gauges.count - 1)
    }

    /// Resizes the domain from its origin, everything staying where it is (gauges left outside are
    /// removed), and frames the view on it.
    func resizeDomain(to size: SIMD3<Float>) {
        var scenario = settings.scenario
        do {
            let removed = try scenario.resizeDomain(to: size)
            settings.scenario = scenario
            camera = .framing(scenario)
            if !removed.isEmpty {
                errorMessage =
                    "Gauges outside the new domain were removed: \(removed.joined(separator: ", "))."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The domain whose far faces meet the open faces' clearance (`Scenario.grownToTheRule`), with
    /// the advisor's estimate of a run on it and on the domain as it is, and the faces at the origin
    /// still tight; nil when no face is tight.
    var wideningToTheRule:
        (
            domain: SIMD3<Float>, now: RunCostEstimate, widened: RunCostEstimate,
            left: [(name: String, clearance: Float)]
        )?
    {
        guard let grown = settings.scenario.grownToTheRule() else { return nil }
        let inputs = SimulationInputs(
            scenario: settings.scenario, settings: ProjectRunSettings(model: self), thermal: thermalSpec)
        return (
            grown.domain, inputs.cost(domain: settings.scenario.domainSize),
            inputs.cost(domain: grown.domain),
            grown.left
        )
    }

    /// Grows the domain from its origin so that its far faces meet the open faces' clearance,
    /// nothing in the scene moving (`Scenario.grownToTheRule`).
    func widenToTheRule() {
        guard let grown = settings.scenario.grownToTheRule(), grown.domain != domainSize else { return }
        resizeDomain(to: grown.domain)
    }

    /// Whether the scene is open, with nothing in it but its charge, gauges and terrain, and so
    /// can be fitted to its charge.
    var canFitOpenScene: Bool { settings.scenario.contentBounds == nil }

    /// The most cells a fitted open scene's grid is given: enough for its peaks with the shocks
    /// sharpened, few enough to run in minutes.
    static let fittedCellBudget = 20_000_000

    /// Fits an open scene to its charge out to `scaledReach` m/kg^(1/3) (see
    /// `Scenario.fitOpenScene(scaledReach:)`), with the finest grid scaled to the charge that keeps
    /// within `fittedCellBudget`, and frames the view on it.
    func fitOpenScene(scaledReach: Float) {
        var scenario = settings.scenario
        do {
            try scenario.fitOpenScene(scaledReach: scaledReach)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let mass = scenario.charge.mass
        let candidates =
            Resolution.scaledCells.reversed().compactMap { Resolution.scaled($0, mass: mass) }
            + Resolution.allCases.reversed()
        let fits = candidates.first {
            scenario.grid(cellSize: $0.cellSize).cellCount <= Self.fittedCellBudget
        }
        settings.resolution =
            fits ?? Resolution(
                cellSize: cbrt(
                    Float(scenario.domainSize.x * scenario.domainSize.y * scenario.domainSize.z)
                        / Float(Self.fittedCellBudget)
                ).rounded(.up)) ?? settings.resolution
        settings.scenario = scenario
        camera = .framing(scenario)
    }

    /// Adds gauges 1.5 m above the ground on a line from the charge, where it has the most room,
    /// at the scaled distances of the Kingery-Bulmash curves that fit in the domain, as many as the
    /// solver can record; gauges already there by those names are kept.
    func addGaugeLine() {
        let scenario = settings.scenario
        let names = Set(scenario.gauges.map(\.name))
        let line = scenario.gaugeLine(direction: scenario.roomiestGaugeLineDirection).filter {
            !names.contains($0.name)
        }
        let room = BlastSolver.maxGauges - scenario.gauges.count
        guard room > 0, !line.isEmpty else { return }
        settings.scenario.gauges.append(contentsOf: line.prefix(room))
        selection = nil
    }

    func removeGauge(at index: Int) {
        guard settings.scenario.gauges.indices.contains(index) else { return }
        settings.scenario.gauges.remove(at: index)
        selection = nil
    }

    /// Adds a rigid block in the middle of the domain.
    func addBlock() {
        guard settings.scenario.rigidBoxes.count < SceneRenderer.maxBoxes else {
            errorMessage =
                "The layout has reached the \(SceneRenderer.maxBoxes.formatted()) rigid region limit."
            return
        }
        let centre = settings.scenario.domainSize / 2
        let id = settings.scenario.addFixedObject(
            Box(x: (centre.x - 3)...(centre.x + 3), y: (centre.y - 3)...(centre.y + 3), height: 9),
            name: "Block \(settings.scenario.fixedObjects.count + 1)")
        selection = .block(id)
    }

    func removeBlock(at index: Int) {
        guard settings.scenario.fixedObjects.indices.contains(index) else { return }
        removeBlock(id: settings.scenario.fixedObjects[index].id)
    }

    func removeBlock(id: UUID) {
        do { try settings.scenario.removeObject(id: id) } catch {
            errorMessage = error.localizedDescription
            return
        }
        if selection == .block(id) { selection = nil }
    }

    func updateBlock(id: UUID, box: Box) {
        guard settings.scenario.object(id: id)?.fixedBox != nil else { return }
        do { try settings.scenario.updateFixedObject(id: id, box: box) } catch {
            errorMessage = error.localizedDescription
        }
    }

    func duplicateBlock(id: UUID) {
        guard settings.scenario.rigidBoxes.count < SceneRenderer.maxBoxes else {
            errorMessage =
                "The layout has reached the \(SceneRenderer.maxBoxes.formatted()) rigid region limit."
            return
        }
        do { selection = .block(try settings.scenario.duplicateFixedObject(id: id)) } catch {
            errorMessage = error.localizedDescription
        }
    }

    func componentSelection(_ kind: SceneObject.ComponentKind, at index: Int) -> EditSelection? {
        let references = editedObject?.references(kind) ?? []
        guard references.indices.contains(index) else { return nil }
        switch kind {
        case .solid: return .solid(references[index])
        case .opening: return .opening(references[index])
        case .support: return .support(references[index])
        }
    }

    struct ComponentRow: Identifiable {
        var reference: SceneObject.ComponentReference
        var index: Int
        var id: SceneObject.ComponentReference { reference }
    }

    func componentRows(_ kind: SceneObject.ComponentKind) -> [ComponentRow] {
        (editedObject?.references(kind) ?? []).enumerated().map {
            ComponentRow(reference: $0.element, index: $0.offset)
        }
    }

    /// A stale editor row must never fall through to another component's array index.
    func editComponent(
        _ reference: SceneObject.ComponentReference,
        _ change: (inout StructureModel, Int) -> Void
    ) {
        guard let index = settings.scenario.componentIndex(reference) else { return }
        editStructure(objectID: reference.objectID, retainingComponents: true) { change(&$0, index) }
    }

    func removeComponent(_ reference: SceneObject.ComponentReference) {
        guard let index = settings.scenario.componentIndex(reference) else { return }
        editStructure(objectID: reference.objectID, removing: reference) { body in
            switch reference.kind {
            case .solid: body.removeSolid(at: index)
            case .opening: body.openings.remove(at: index)
            case .support: body.removeSupport(at: index)
            }
        }
        selection = nil
    }

    /// Adds a 250 mm wall, 4 m long and 3 m high, to the deformable structure, creating the
    /// structure if the layout has none.
    func addWall() {
        let centre = settings.scenario.domainSize / 2
        let wall = Box(x: centre.x...(centre.x + 0.25), y: (centre.y - 2)...(centre.y + 2), height: 3)
        editStructure { $0.solids.append(wall) }
        selection = componentSelection(.solid, at: (editedStructure?.solids.count ?? 1) - 1)
    }

    /// Puts a pitched roof over the edited structure's plan, from eaves at the tops of its walls
    /// (`StructureModel.addPitchedRoof`). Only a structure meshed as shells takes one: the slopes
    /// cut the walls under them to their line as shells.
    func addPitchedRoof(_ roof: PitchedRoof) {
        guard let body = editedStructure, body.isAllShells else { return }
        let pieces = body.solids.indices.filter { body.inclination(of: $0) == nil }.map { body.solids[$0] }
        guard let first = pieces.first else { return }
        let plan = pieces.dropFirst().reduce(first) {
            Box(min: simd_min($0.min, $1.min), max: simd_max($0.max, $1.max))
        }
        editStructure { $0.addPitchedRoof(roof, over: plan, eaves: plan.max.z) }
        selection = componentSelection(.solid, at: (editedStructure?.solids.count ?? 1) - 1)
    }

    func removeSolid(at index: Int) {
        let references = editedObject?.references(.solid) ?? []
        guard references.indices.contains(index) else { return }
        editStructure(removing: references[index]) { $0.removeSolid(at: index) }
        selection = nil
    }

    /// Sets the material of one piece of the structure; nil returns it to the structure's own.
    func setMaterial(_ material: StructureMaterial?, ofSolid index: Int, objectID: UUID? = nil) {
        editStructure(objectID: objectID) { $0.setMaterial(material, of: index) }
    }

    /// Makes one piece a profiled steel sheet of `profile` (nil: a plain piece again), its ribs
    /// along `ribAxis` or, if nil, as cladding and roofs usually run. A sheet is meshed as shells,
    /// of structural steel unless the piece is already of a steel.
    func setSheet(_ profile: SheetProfile?, ribAxis: Int? = nil, ofSolid index: Int, objectID: UUID? = nil) {
        if profile != nil { setElementKind(.shell, ofSolid: index, objectID: objectID) }
        editStructure(objectID: objectID) { structure in
            guard let profile, structure.solids.indices.contains(index) else {
                structure.setSheet(nil, of: index)
                return
            }
            var sheet = SheetAssignment(profile: profile, on: structure.solids[index])
            if let ribAxis { sheet.ribAxis = ribAxis }
            structure.setSheet(sheet, of: index)
            if structure.material(of: index).model != .vonMises {
                structure.setMaterial(.structuralSteel, of: index)
            }
        }
    }

    /// Meshes one piece of the structure with solid elements or shells. A structure of both
    /// kinds keeps solid elements at their own size and shells at theirs.
    func setElementKind(_ kind: ElementKind, ofSolid index: Int, objectID: UUID? = nil) {
        let target = objectID.flatMap { settings.scenario.object(id: $0) } ?? editedObject
        let solidSize = target?.preferredSolidElementSize ?? settings.solidElementSize
        if let target, let body = target.structure, body.elementKind == .solid {
            rememberSolidElementSize(body.elementSize, objectID: target.id)
        }
        editStructure(objectID: target?.id) { structure in
            structure.setElementKind(kind, of: index)
            if structure.isMixed {
                structure.elementSize = structure.elementKind == .solid ? structure.elementSize : solidSize
                structure.shellElementSize = SimulationSettings.shellSize
                // The size is that of the solid elements, whichever kind the rest of the body is.
                if structure.elementKind == .shell {
                    let kinds = structure.solids.indices.map { structure.elementKind(of: $0) }
                    structure.elementKind = .solid
                    structure.solidElementKind = []
                    for (n, own) in kinds.enumerated() { structure.setElementKind(own, of: n) }
                }
            } else {
                // All one kind again: that is the body's kind, at its own size.
                let kind =
                    structure.solids.indices.first.map { structure.elementKind(of: $0) }
                    ?? structure.elementKind
                structure.solidElementKind = []
                structure.shellElementSize = nil
                if kind != structure.elementKind {
                    structure.elementKind = kind
                    structure.elementSize = kind == .shell ? SimulationSettings.shellSize : solidSize
                }
            }
        }
    }

    /// Sets how one piece of the structure is reinforced.
    func setReinforcement(_ spec: Reinforcement, ofSolid index: Int, objectID: UUID? = nil) {
        editStructure(objectID: objectID) { $0.setReinforcement(spec, of: index) }
    }

    /// Adds an opening (a window or door) to cut out of the structure.
    func addOpening() {
        guard let body = editedStructure, !body.solids.isEmpty else { return }
        let target = selectedStructureBounds ?? body.solids[0]
        let centre = (target.min + target.max) / 2
        var half = simd_min(target.size / 4, SIMD3<Float>(repeating: 0.5))
        let thin = (0..<3).min { target.size[$0] < target.size[$1] } ?? 0
        half[thin] = target.size[thin] / 2 + settings.resolution.cellSize
        let opening = Box(min: centre - half, max: centre + half)
        editStructure { $0.openings.append(opening) }
        selection = componentSelection(.opening, at: (editedStructure?.openings.count ?? 1) - 1)
    }

    func removeOpening(at index: Int) {
        let references = editedObject?.references(.opening) ?? []
        guard references.indices.contains(index) else { return }
        editStructure(removing: references[index]) { structure in
            guard structure.openings.indices.contains(index) else { return }
            structure.openings.remove(at: index)
        }
        selection = nil
    }

    /// Changes the deformable structure and re-derives its reinforcement from the new shapes.
    /// A structure left with no solids is removed.
    func editStructure(
        objectID: UUID? = nil, removing reference: SceneObject.ComponentReference? = nil,
        retainingComponents: Bool = false, _ change: (inout StructureModel) -> Void
    ) {
        guard !isPreparingImports else { return }
        do {
            settings.scenario = try StructureEditing.changing(
                settings.scenario, objectID: objectID ?? editedObject?.id,
                removing: reference, retainingComponents: retainingComponents, change)
        } catch { errorMessage = error.localizedDescription }
    }

    var structuralParts: [StructureEditing.Part] {
        StructureEditing.parts(in: settings.scenario).filter { $0.objectID == editedObject?.id }
    }

    var selectedStructureBounds: Box? {
        switch selection {
        case .solid, .part: highlightedBox
        case .imported(let id):
            settings.scenario.importedModels?.first(where: { $0.id == id })?.behavior == .deformable
                ? highlightedBox : nil
        default: nil
        }
    }

    func setPartMaterial(_ material: StructureMaterial?, for part: StructureModel.SourcePart) {
        guard !isPreparingImports else { return }
        do {
            settings.scenario = try StructureEditing.settingMaterial(
                material, for: part, in: settings.scenario)
        } catch { errorMessage = error.localizedDescription }
    }

    func setPartReinforcement(_ spec: Reinforcement, for part: StructureModel.SourcePart) {
        guard let selected = structuralParts.first(where: { $0.id == part }), !selected.regions.isEmpty else {
            return
        }
        editStructure { body in
            for index in selected.regions { body.setReinforcement(spec, of: index) }
        }
    }

    func setStructureMaterial(_ material: StructureMaterial) {
        editStructure { $0.material = material }
    }

    func setFixedBase(_ fixed: Bool) {
        let imported = settings.scenario.importedModels?.first {
            $0.behavior == .deformable && $0.canRegenerate(editedStructure)
        }
        editStructure { body in
            body.fixedBase = fixed
            if let imported {
                body.supports = imported.supports(fixedBase: fixed)
                body.supportAnchorages = fixed && body.baseAnchorage != nil ? [body.baseAnchorage] : []
            }
        }
    }

    func setBaseAnchorage(_ law: Anchorage?) {
        let imported = settings.scenario.importedModels?.first {
            $0.behavior == .deformable && $0.canRegenerate(editedStructure)
        }
        editStructure { body in
            body.baseAnchorage = law
            if imported != nil {
                body.supportAnchorages = law == nil || !body.fixedBase ? [] : [law]
            }
        }
    }

    func supportBearingArea(at index: Int) -> Float? {
        guard runtimeInputsMatch, !hasPendingGPUWork, !isRunning, let solver else { return nil }
        guard let id = editedObject?.id, let body = solver.body(id: id) else { return nil }
        return (body.solids?.supportBearingArea(at: index) ?? 0)
            + (body.shells?.supportBearingArea(at: index) ?? 0)
    }

    func setSupportAnchorage(_ law: Anchorage?, at index: Int) {
        editStructure { $0.setAnchorage(law, ofSupport: index) }
    }

    func addSupport() {
        guard let body = editedStructure, !body.solids.isEmpty else { return }
        let target = selectedStructureBounds ?? body.bounds
        let thickness = max(body.elementSize, 0.01)
        let support = Box(
            min: target.min - SIMD3(repeating: thickness * 0.01),
            max: SIMD3(
                target.max.x + thickness * 0.01, target.max.y + thickness * 0.01,
                target.min.z + thickness * 0.5))
        editStructure { $0.supports.append(support) }
        selection = componentSelection(.support, at: (editedStructure?.supports.count ?? 1) - 1)
    }

    func removeSupport(at index: Int) {
        let references = editedObject?.references(.support) ?? []
        guard references.indices.contains(index) else { return }
        editStructure(removing: references[index]) { body in
            body.removeSupport(at: index)
        }
        selection = nil
    }

    /// Handles a click in the view, at a point in normalised device coordinates. In placing
    /// mode it moves the selected gauge there, or the charge if no gauge is selected.
    func click(ndc: SIMD2<Float>, aspectRatio: Float) {
        guard !sweep.isActive else { return }
        if !isPlacingCharge {
            guard !isRunning, !isPreparingImports else { return }
            let ray = camera.ray(ndc: ndc, aspectRatio: aspectRatio)
            if time == 0,
                let id = ScenePicking.importedModel(
                    in: settings.scenario, origin: ray.origin, direction: ray.direction)
            {
                inspectImport(id: id)
                return
            } else if time == 0,
                let id = ScenePicking.building(
                    in: settings.scenario, origin: ray.origin, direction: ray.direction)
            {
                // A building picked, for the refinement to go toward (`toggleRefineToward`).
                selection = .building(id)
            } else if case .imported = selection {
                selection = nil
            } else if case .building = selection {
                selection = nil
            }
            // A building judged, near or far: its damage in the sidebar.
            inspectedEnvelope =
                envelopeDamage.isEmpty && farFieldDamage.isEmpty
                ? nil
                : ScenePicking.envelope(
                    in: settings.scenario, far: farFieldSet, origin: ray.origin, direction: ray.direction)
            return
        }
        guard isPlacingCharge, let point = camera.groundPoint(ndc: ndc, aspectRatio: aspectRatio) else {
            return
        }
        let size = settings.scenario.domainSize
        // Snap to 0.25 m so the charge stays aligned with every grid resolution.
        let snapped = (point * Float(4)).rounded(.toNearestOrEven) / Float(4)
        let x = min(max(snapped.x, 1), size.x - 1)
        let y = min(max(snapped.y, 1), size.y - 1)
        if case .gauge(let index) = selection, settings.scenario.gauges.indices.contains(index) {
            settings.scenario.gauges[index].position.x = x
            settings.scenario.gauges[index].position.y = y
        } else {
            settings.chargePosition.x = x
            settings.chargePosition.y = y
        }
    }
}
