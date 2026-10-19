import BlastModel
import Foundation
import Metal
import RadialBlast
import simd

// The air solver's checkpoints: the state saved part by part and restored, and the digest of the
// state that says a restored run is the same.

// MARK: - Checkpoints

// The air's own state for a checkpoint (`SolverCheckpoint`): both copies of the cells (a tile never
// swept holds the same in each, but a copy costs little once compressed), the outline, the peaks
// and impulse, the fastest wave carried between batches, the tiles awake, the cut cells' carried
// differences, the clocks and the pools' bookkeeping. Each refinement level saves its own.
extension BlastSolver: SolverCheckpointing {
    var checkpointName: String { "air" }
    var checkpointVersion: Int { 1 }

    func checkpointParts() -> [SolverCheckpoint.Part] {
        var scalars = SolverCheckpoint.Writer()
        scalars.append(time)
        scalars.append(stepCount)
        scalars.append(clockTicks)
        scalars.append(current)
        scalars.append(airIsAsleep)
        scalars.append(lastFluidStep)
        scalars.append(checkpointSubsteps)
        scalars.append(stillCell)
        scalars.append(largestCharge)
        scalars.append(gravityGround)
        scalars.append(needsRigidMaskCapture)
        scalars.appendArray(poolGrowth)
        scalars.appendArray(poolLive)
        scalars.appendArray(poolCouldGrow.map { UInt8($0 ? 1 : 0) })
        scalars.append(stepsSincePoolLook)
        scalars.append(refinementPoolGrewLate)
        scalars.append(radiatedEnergy)
        scalars.appendArray(radiationHistory.map(\.time))
        scalars.appendArray(radiationHistory.map(\.energy))
        scalars.append(gaugeHistories.count)
        for history in gaugeHistories { scalars.appendArray(history) }
        var parts: [SolverCheckpoint.Part] = [.bytes("scalars", scalars.data)]
        for (name, buffer) in checkpointBuffers { parts.append(.buffer(name, buffer, 0..<buffer.length)) }
        return parts
    }

    /// The air's buffers a checkpoint saves whole, by name.
    private var checkpointBuffers: [(String, MTLBuffer)] {
        var buffers: [(String, MTLBuffer)] = [
            ("stateA", stateBuffers[0]), ("stateB", stateBuffers[1]), ("mask", maskBuffer),
            ("rigidMask", rigidMaskBuffer), ("peak", peakBuffer), ("impulse", impulseBuffer),
            ("maxSpeed", maxSpeedBuffer), ("tileFlags", tileFlagBuffer),
        ]
        if hasSpecies { buffers += [("speciesA", speciesBuffers[0]), ("speciesB", speciesBuffers[1])] }
        if let cappedSliverBuffer { buffers.append(("cappedSlivers", cappedSliverBuffer)) }
        if let defects = terrainCut?.defects { buffers.append(("terrainCutDefects", defects)) }
        return buffers
    }

    func restoreCheckpoint(_ parts: [String: Data]) throws {
        var scalars = SolverCheckpoint.Reader(parts["scalars"] ?? Data())
        time = scalars.read(Double.self)
        stepCount = scalars.read(Int.self)
        clockTicks = scalars.read(UInt64.self)
        current = scalars.read(Int.self)
        airIsAsleep = scalars.readBool()
        lastFluidStep = scalars.read(Float.self)
        checkpointSubsteps = scalars.read(Int.self)
        stillCell = scalars.read(CellState.self)
        largestCharge = scalars.read(Float.self)
        gravityGround = scalars.read(Primitive.self)
        needsRigidMaskCapture = scalars.readBool()
        poolGrowth = scalars.readArray(Double.self)
        poolLive = scalars.readArray(Int.self)
        poolCouldGrow = scalars.readArray(UInt8.self).map { $0 != 0 }
        stepsSincePoolLook = scalars.read(Int.self)
        refinementPoolGrewLate = scalars.readBool()
        radiatedEnergy = scalars.read(Double.self)
        let times = scalars.readArray(Double.self)
        let energies = scalars.readArray(Double.self)
        radiationHistory = zip(times, energies).map { (time: $0, energy: $1) }
        let gauges = scalars.read(Int.self)
        guard gauges == gaugeHistories.count else {
            throw SolverCheckpoint.Refusal(
                description: "\(gauges) gauges were saved where the solver has \(gaugeHistories.count)")
        }
        gaugeHistories = (0..<gauges).map { _ in scalars.readArray(GaugeSample.self) }
        try scalars.finish("air")
        for (name, buffer) in checkpointBuffers {
            try SolverCheckpoint.restore(
                parts[name], into: buffer, offset: 0, length: buffer.length, name: "air.\(name)")
        }
    }

    /// Why the solver cannot be checkpointed as it is, or nil. The first stage covers the air, its
    /// refinement and its clocks; a part not yet covered refuses rather than be left out.
    public var checkpointUnsupported: String? {
        if batchInFlight { return "a batch is in flight" }
        if !bodies.isEmpty { return "structures are not yet checkpointed" }
        if !experimentalBoxes.isEmpty { return "the experimental rigid boxes are not checkpointed" }
        if deflagrationStage != nil || congestion != nil { return "deflagrations are not yet checkpointed" }
        if exposurePlane != nil || envelopeExposure != nil || envelopeComponentRecorder != nil {
            return "envelopes' and exposure planes' recorders are not yet checkpointed"
        }
        if envelopeVenting != nil { return "envelope venting is not yet checkpointed" }
        return nil
    }

    /// The parts whose state a checkpoint holds, the air's first.
    private var checkpointSubsystems: [any SolverCheckpointing] {
        var parts: [any SolverCheckpointing] = [self]
        parts += refinementLevels.map { $0 as any SolverCheckpointing }
        if let radiativeCoolingStage { parts.append(radiativeCoolingStage) }
        return parts
    }

    /// About the bytes a checkpoint holds before compression (cells and fine cells as they stand).
    public var checkpointBytes: Int {
        checkpointSubsystems.reduce(0) { sum, part in
            sum + part.checkpointParts().reduce(0) { $0 + $1.data.count }
        }
    }

    /// Saves the solver's state to `folder` (made if need be), between batches and at a 64-step
    /// boundary (`checkpointInterval`), with the fingerprint of `scene`, the scene it was built
    /// from. Throws `SolverCheckpoint.Refusal` where it cannot (`checkpointUnsupported`).
    @discardableResult
    public func saveCheckpoint(to folder: URL, scene: Scenario) throws -> SolverCheckpoint.Header {
        if let reason = checkpointUnsupported { throw SolverCheckpoint.Refusal(description: reason) }
        guard stepCount % Self.checkpointInterval == 0 else {
            throw SolverCheckpoint.Refusal(
                description: "step \(stepCount) is not at a \(Self.checkpointInterval)-step boundary")
        }
        // The cooling takes its loss every few steps and at each batch's end: a checkpoint on a step
        // it takes it at leaves a run cut there the same as one that is not.
        if let radiativeCoolingStage,
            !stepCount.isMultiple(of: max(radiativeCoolingStage.settings.interval, 1))
        {
            throw SolverCheckpoint.Refusal(
                description: "step \(stepCount) is not one the radiative cooling takes its loss at")
        }
        let header = SolverCheckpoint.Header(
            format: SolverCheckpoint.format, scene: SolverCheckpoint.fingerprint(scene: scene),
            configuration: SolverCheckpoint.fingerprint(configuration: configuration),
            grid: [grid.nx, grid.ny, grid.nz], cellSize: grid.cellSize, stepCount: stepCount, time: time,
            pools: refinementLevels.map(\.maxPatches),
            covers: ["air", "clocks"] + (refinementLevels.isEmpty ? [] : ["refinement"])
                + (radiativeCoolingStage == nil ? [] : ["radiativeCooling"]),
            complete: true, parts: [], rawBytes: 0, storedBytes: 0, seconds: 0)
        return try SolverCheckpoint.write(checkpointSubsystems, header: header, to: folder)
    }

    /// Takes back the state saved in `folder` into this solver, which must have been built from the
    /// same scene (`scene`) and configuration, on the same grid: the run then carries on from the
    /// saved step exactly as the run it was saved from would have.
    @discardableResult
    public func restoreCheckpoint(from folder: URL, scene: Scenario) throws -> SolverCheckpoint.Header {
        if let reason = checkpointUnsupported { throw SolverCheckpoint.Refusal(description: reason) }
        let header = try SolverCheckpoint.header(in: folder)
        guard header.scene == SolverCheckpoint.fingerprint(scene: scene) else {
            throw SolverCheckpoint.Refusal(description: "the checkpoint was saved from another scene")
        }
        guard header.configuration == SolverCheckpoint.fingerprint(configuration: configuration) else {
            throw SolverCheckpoint.Refusal(description: "the checkpoint was saved with another configuration")
        }
        guard header.grid == [grid.nx, grid.ny, grid.nz], header.cellSize == grid.cellSize else {
            throw SolverCheckpoint.Refusal(description: "the checkpoint was saved on another grid")
        }
        guard header.pools.count == refinementLevels.count else {
            throw SolverCheckpoint.Refusal(description: "the checkpoint has another number of refined levels")
        }
        // The pools as they were: grown as the run grew them (a pool never shrinks, so this one's,
        // from its own start, is never larger).
        growPools(to: header.pools)
        guard refinementLevels.map(\.maxPatches) == header.pools else {
            throw SolverCheckpoint.Refusal(description: "the pools could not grow to their saved sizes")
        }
        try SolverCheckpoint.read(checkpointSubsystems, header: header, from: folder)
        frameExtractor?.invalidate()
        exposureNeedsInitialSample = false
        envelopeNeedsInitialSample = false
        componentsNeedInitialSample = false
        return header
    }
}

extension BlastSolver {
    /// A hash of the air's state: the cells, peaks and impulse, the clocks, and each refinement
    /// level's fine cells block by block; equal for two runs whose states are equal to the bit.
    public func stateDigest() -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func fold(_ word: UInt32) { hash = (hash ^ UInt64(word)) &* 0x100_0000_01b3 }
        func fold(_ buffer: MTLBuffer, _ length: Int) {
            let words = buffer.contents().bindMemory(to: UInt32.self, capacity: length / 4)
            for n in 0..<(length / 4) { fold(words[n]) }
        }
        fold(stateBuffers[current], stateBuffers[current].length)
        if hasSpecies { fold(speciesBuffers[current], speciesBuffers[current].length) }
        fold(peakBuffer, peakBuffer.length)
        fold(impulseBuffer, impulseBuffer.length)
        for word in [
            UInt32(truncatingIfNeeded: time.bitPattern), UInt32(truncatingIfNeeded: time.bitPattern >> 32),
            UInt32(stepCount), UInt32(truncatingIfNeeded: clockTicks),
            UInt32(truncatingIfNeeded: clockTicks >> 32),
        ] {
            fold(word)
        }
        for level in refinementLevels { level.digest(into: &hash) }
        return hash
    }
}
