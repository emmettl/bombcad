import Foundation

/// The fixed ideal-gas controls accompanying two open benchmark cases, not solver defaults.
/// See Benchmarks/open/decks/README.md. Sparse initial cells contain conserved state at t = 0.
public struct OpenBenchmarkDeck: Decodable {
    public struct Ambient: Decodable {
        public var pressurePa: Double
        public var densityKgM3: Double
    }
    public struct Physics: Decodable, Equatable {
        public var eos: String
        public var gamma: Double
        public var afterburning: Bool
        public var gravity: Bool
        public var radiation: Bool
        public var mappedStart: Bool
    }
    public struct Numerics: Decodable {
        public var riemannSolver: String
        public var limiterTheta: Double
        public var cfl: Double
        public var startupSteps: Int
        public var densityFloor: Double
        public var pressureFloorPa: Double
    }
    public struct Mesh: Decodable {
        public var counts: [Int]
        public var cellSizeM: Double
        public var originM: [Double]
    }
    public struct Boundaries: Decodable {
        public var reflectingFaces: [Int]
        public var otherFaces: String
    }
    public struct Sampling: Decodable {
        public var intervalS: Double
        public var stopS: Double
        public var timeToleranceS: Double
        public var observable: String
    }
    public struct Run: Decodable {
        public struct Source: Decodable {
            public var representedChargeKg: Double
            public var excessEnergyJ: Double
            public var excessMassKg: Double
        }
        public struct InitialCell: Decodable {
            public var index: [Int]
            public var densityKgM3: Double
            public var internalEnergyJM3: Double
        }
        public struct Gauge: Decodable {
            public var id: String
            public var positionM: [Double]?
        }
        public var id: String
        public var source: Source
        public var initialCells: [InitialCell]
        public var gauges: [Gauge]
    }
    public var format: String
    public var formatVersion: Int
    public var `protocol`: String
    public var caseId: String
    public var ambient: Ambient
    public var physics: Physics
    public var numerics: Numerics
    public var mesh: Mesh
    public var boundaries: Boundaries
    public var sampling: Sampling
    public var runs: [Run]

    /// Read the protocol's SI snake-case keys and validate before allocating a solver.
    public static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let deck = try decoder.decode(Self.self, from: data)
        try deck.validate()
        return deck
    }

    public enum Invalid: Error { case deck(String) }

    /// The adapter supports this exact protocol; it must not quietly ignore changed physics.
    public func validate() throws {
        guard format == "open-blast-benchmark-deck", formatVersion == 1,
            `protocol` == "ideal-gas-balloon-v1", mesh.counts.count == 3,
            mesh.counts.allSatisfy({ $0 > 0 && $0 <= 256 }), mesh.originM == [0, 0, 0],
            mesh.cellSizeM.isFinite, mesh.cellSizeM > 0,
            physics.eos == "ideal-gas", physics.gamma == 1.4, !physics.afterburning,
            !physics.gravity, !physics.radiation, !physics.mappedStart,
            ambient.pressurePa == 101325, ambient.densityKgM3 == 1.225,
            numerics.riemannSolver == "HLLC", numerics.limiterTheta == 1.5,
            numerics.cfl == 0.45, numerics.startupSteps == 6,
            numerics.densityFloor == 1e-6, numerics.pressureFloorPa == 1e-3,
            boundaries.otherFaces == "zero-gradient",
            boundaries.reflectingFaces.allSatisfy({ (0..<6).contains($0) }),
            sampling.intervalS == 0.00005, sampling.timeToleranceS == 2e-8,
            !runs.isEmpty, Set(runs.map(\.id)).count == runs.count
        else { throw Invalid.deck("Unsupported protocol or numerical inputs") }
        let room = caseId == "ufc-closed-room-gas-pressure"
        guard room || caseId == "kb-surface-burst-free-field",
            sampling.stopS == (room ? 0.12 : 0.1),
            mesh.counts == (room ? [24, 24, 24] : [128, 128, 128]),
            mesh.cellSizeM == (room ? 0.25 : 0.5),
            sampling.observable == (room ? "volume-mean-overpressure" : "trilinear-cell-centre-overpressure"),
            boundaries.reflectingFaces == (room ? [0, 1, 2, 3, 4, 5] : [0, 2, 4])
        else { throw Invalid.deck("Unsupported case or observable") }
        for run in runs {
            var seen = Set<[Int]>()
            var mass = 0.0
            var energy = 0.0
            let volume = pow(mesh.cellSizeM, 3)
            for cell in run.initialCells {
                guard cell.index.count == 3,
                    zip(cell.index, mesh.counts).allSatisfy({ $0 >= 0 && $0 < $1 }),
                    seen.insert(cell.index).inserted, cell.densityKgM3.isFinite,
                    cell.internalEnergyJM3.isFinite, cell.densityKgM3 > ambient.densityKgM3,
                    cell.internalEnergyJM3 > ambient.pressurePa / (physics.gamma - 1)
                else { throw Invalid.deck("Invalid or duplicate initial cell") }
                mass += (cell.densityKgM3 - ambient.densityKgM3) * volume
                energy += (cell.internalEnergyJM3 - ambient.pressurePa / (physics.gamma - 1)) * volume
            }
            guard run.source.representedChargeKg.isFinite, run.source.representedChargeKg > 0,
                run.source.excessEnergyJ == run.source.representedChargeKg * 4_184_000,
                abs(run.source.excessMassKg / (run.source.representedChargeKg * (1 - 1.225 / 1600)) - 1)
                    < 1e-12,
                abs(energy / run.source.excessEnergyJ - 1) < 1e-10,
                abs(mass / run.source.excessMassKg - 1) < 1e-10,
                !run.gauges.isEmpty, Set(run.gauges.map(\.id)).count == run.gauges.count,
                run.gauges.allSatisfy({ gauge in
                    if room { return run.gauges.count == 1 && gauge.id == "room" && gauge.positionM == nil }
                    guard let position = gauge.positionM, position.count == 3 else { return false }
                    return zip(position, mesh.counts).allSatisfy {
                        $0.isFinite && $0 >= 0 && $0 <= Double($1) * mesh.cellSizeM
                    }
                })
            else { throw Invalid.deck("Source budget or gauges invalid") }
        }
    }
}
