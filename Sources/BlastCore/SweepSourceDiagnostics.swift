import BlastModel
import Metal

/// Host reads of physical source cells; ghost signs are mapping metadata, not GPU intermediates.
public struct SweepSourceStencilSample: Sendable {
    public let step: Int
    public let time: Double
    public let dt: Float
    /// [selected cell][M2/M1/C/P1/P2][rho/mx/my/mz/energy], without ghost transformations.
    public let conservedBits: [[[UInt32]]]
    /// [selected cell][M2/M1/C/P1/P2][rho error/energy error/mask/floor count].
    public let residualBits: [[[UInt32]]]
}

public struct SweepSourceStencilTrace: Sendable {
    /// Each selected cell's M2/M1/C/P1/P2 physical source indices.
    public let physicalIndices: [[Int]]
    public let ghostVelocitySigns: [[Int]]
    public let samples: [SweepSourceStencilSample]
}

final class SweepSourceCapture {
    let physicalIndices: [[Int]]
    let ghostVelocitySigns: [[Int]]
    let lowWall: Bool
    let highWall: Bool
    var pendingConserved: [[[UInt32]]]?
    var pendingResiduals: [[[UInt32]]]?
    var samples: [SweepSourceStencilSample] = []
    var incomplete = false

    init(indices: [Int], nx: Int, lowWall: Bool, highWall: Bool) {
        self.lowWall = lowWall
        self.highWall = highWall
        var physical: [[Int]] = []
        var signs: [[Int]] = []
        for index in indices {
            var cells: [Int] = []
            var mirrors: [Int] = []
            for offset in -2...2 {
                let at = index + offset
                if at < 0 {
                    cells.append(lowWall ? -at - 1 : 0)
                    mirrors.append(lowWall ? -1 : 1)
                } else if at >= nx {
                    cells.append(highWall ? 2 * nx - at - 1 : nx - 1)
                    mirrors.append(highWall ? -1 : 1)
                } else {
                    cells.append(at)
                    mirrors.append(1)
                }
            }
            physical.append(cells)
            signs.append(mirrors)
        }
        physicalIndices = physical
        ghostVelocitySigns = signs
    }
}

extension BlastSolver {
    var supportsHostSweepSourceDiagnostics: Bool {
        supportsCompensatedSweep && compensatedSweep != nil
            && !configuration.periodicSides && configuration.openFaces == .copy
    }

    /// Called ONLY by blocking advance before encoding, after the preceding GPU wait.
    /// batchInFlight can describe a partly completed logical batch, so public withState is unsuitable.
    func stageHostSweepSources() -> Bool {
        guard let capture = sweepUpdateCapture, let source = capture.sourceCapture else { return true }
        guard supportsHostSweepSourceDiagnostics, let compensation = compensatedSweep else { return false }
        guard source.lowWall == configuration.reflectiveFaces.contains(.xMin),
            source.highWall == configuration.reflectiveFaces.contains(.xMax)
        else { return false }
        source.pendingConserved = nil
        source.pendingResiduals = nil
        guard capture.samples.count < capture.maxSamples else { return true }
        let state = stateContents[current].bindMemory(to: CellState.self, capacity: grid.cellCount)
        let residuals = compensation.residuals.contents().bindMemory(
            to: SIMD4<Float>.self, capacity: grid.cellCount)
        source.pendingConserved = source.physicalIndices.map { cells in
            cells.map { i in
                let c = state[i]
                return [c.density, c.momentumX, c.momentumY, c.momentumZ, c.energy].map(\.bitPattern)
            }
        }
        source.pendingResiduals = source.physicalIndices.map { cells in
            cells.map { i in
                let e = residuals[i]
                return [e.x, e.y, e.z, e.w].map(\.bitPattern)
            }
        }
        return true
    }

    func collectHostSweepSources(_ sample: SweepUpdateSample) {
        guard let source = sweepUpdateCapture?.sourceCapture else { return }
        guard let state = source.pendingConserved, let residuals = source.pendingResiduals else {
            source.incomplete = true
            return
        }
        for q in sample.executed.indices where sample.executed[q] {
            let actual = sample.values[q]
            if state[q][2] != Array(actual.prefix(5)).map(\.bitPattern)
                || residuals[q][2] != [actual[24], actual[25], actual[28], actual[29]].map(\.bitPattern)
            {
                source.incomplete = true
            }
        }
        source.samples.append(
            SweepSourceStencilSample(
                step: sample.step, time: sample.time, dt: sample.dt, conservedBits: state,
                residualBits: residuals))
        source.pendingConserved = nil
        source.pendingResiduals = nil
    }

    /// Refuses incomplete, asynchronous, overflowing or source/update-misaligned observations.
    public func sweepSourceStencilTrace() throws -> SweepSourceStencilTrace {
        precondition(!batchInFlight)
        let updates = try sweepUpdateTrace()
        guard supportsHostSweepSourceDiagnostics, let source = sweepUpdateCapture?.sourceCapture,
            source.lowWall == configuration.reflectiveFaces.contains(.xMin),
            source.highWall == configuration.reflectiveFaces.contains(.xMax),
            !source.incomplete, source.samples.count == updates.samples.count,
            zip(source.samples, updates.samples).allSatisfy({
                $0.step == $1.step && $0.time == $1.time && $0.dt == $1.dt
            })
        else { throw BlastError.allocationFailed("complete aligned blocking host-source observations") }
        return SweepSourceStencilTrace(
            physicalIndices: source.physicalIndices,
            ghostVelocitySigns: source.ghostVelocitySigns, samples: source.samples)
    }
}
