import Foundation
import simd

/// A study of the fireball's thermal radiation: what it is asked for. Any field left out of its
/// JSON takes its default.
public struct ThermalSpec: Codable, Sendable, Equatable {
    /// Gas at least this hot is luminous, part of the fireball, in kelvin.
    public var luminousTemperature: Float = 1500
    /// The fireball's emissivity: 1, a black body, is the most it could radiate.
    public var emissivity: Float = 1
    /// Receivers' spacing on the faces of blocks and structure, and on the ground, in metres.
    public var surfaceSpacing: Float = 1
    public var groundSpacing: Float = 2
    /// Points on the fireball's surface sampled for each receiver's view of it.
    public var samples = 128
    /// The fireball cell by cell as a partly transparent volume, or as its own opaque shape or
    /// one equivalent sphere, each radiating at `emissivity`.
    public var fireball = FireballModel.volume
    /// The volume's grey absorption coefficient for the luminous gas itself, its water vapour and
    /// carbon dioxide, in 1/m: an assumption (see docs/thermal-radiation.md).
    public var absorption: Float = 0.1
    /// The volume's soot, as a share of the mass of its unburnt detonation products, which only
    /// afterburning keeps track of: 0.185 for TNT, whose products by the H₂O–CO rule keep half its
    /// carbon as soot. Zero leaves the soot out.
    public var sootYield: Float = 0.185
    /// The volume's step through the gas, as a share of its voxels' edge.
    public var marchStep: Float = 0.5
    /// How the receivers' surfaces heat up (see `SurfaceHeating`); on unless turned off.
    public var heating = SurfaceHeatingSpec()

    public init() {}

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ThermalSpec()
        luminousTemperature =
            try values.decodeIfPresent(Float.self, forKey: .luminousTemperature)
            ?? defaults.luminousTemperature
        emissivity = try values.decodeIfPresent(Float.self, forKey: .emissivity) ?? defaults.emissivity
        surfaceSpacing =
            try values.decodeIfPresent(Float.self, forKey: .surfaceSpacing) ?? defaults.surfaceSpacing
        groundSpacing =
            try values.decodeIfPresent(Float.self, forKey: .groundSpacing) ?? defaults.groundSpacing
        samples = try values.decodeIfPresent(Int.self, forKey: .samples) ?? defaults.samples
        fireball = try values.decodeIfPresent(FireballModel.self, forKey: .fireball) ?? defaults.fireball
        absorption = try values.decodeIfPresent(Float.self, forKey: .absorption) ?? defaults.absorption
        sootYield = try values.decodeIfPresent(Float.self, forKey: .sootYield) ?? defaults.sootYield
        marchStep = try values.decodeIfPresent(Float.self, forKey: .marchStep) ?? defaults.marchStep
        heating = try values.decodeIfPresent(SurfaceHeatingSpec.self, forKey: .heating) ?? defaults.heating
    }

    public func validate() throws {
        guard luminousTemperature.isFinite, luminousTemperature > 300, emissivity.isFinite, emissivity > 0,
            emissivity <= 1, surfaceSpacing.isFinite, surfaceSpacing >= 0.05, groundSpacing.isFinite,
            groundSpacing >= 0.05, (16...4096).contains(samples), absorption.isFinite,
            (0...1000).contains(absorption), sootYield.isFinite, (0...1).contains(sootYield),
            marchStep.isFinite, (0.05...2).contains(marchStep)
        else {
            throw CocoaError(
                .coderInvalidValue,
                userInfo: [NSLocalizedDescriptionKey: "The thermal radiation description is out of range."])
        }
        try heating.validate()
    }
}

extension ThermalSpec {
    /// The most receivers the ground is given: over a larger floor they stand further apart than
    /// `groundSpacing` (a square kilometre at 2 m has 250,000).
    public static let maximumGroundReceivers = 250_000

    /// The ground receivers' spacing over a floor of `domain`: `groundSpacing`, or wider where
    /// that would give more than `maximumGroundReceivers`.
    public func groundSpacing(over domain: SIMD3<Float>) -> Float {
        max(groundSpacing, (max(domain.x * domain.y, 0) / Float(Self.maximumGroundReceivers)).squareRoot())
    }
}

/// The fireball at one moment as the blast sees it: the luminous gas, reduced to the volume,
/// centre and temperature of an equivalent sphere, and its shape in blocks. A few numbers and a
/// few kilobytes a frame, so the radiation can be worked out anywhere.
public struct FireballFrame: Codable, Sendable, Equatable {
    public var time: Double
    /// Volume of luminous gas, in cubic metres; zero once none is left.
    public var volume: Double
    public var centre: SIMD3<Float>
    /// The fourth root of the luminous gas's mean T⁴, in kelvin: the temperature of a black body
    /// that radiates as the gas does on average.
    public var temperature: Float
    /// The hottest cell, in kelvin.
    public var hottest: Float
    /// The luminous gas's shape; nil where no block of it is half luminous, and in the frames a
    /// result keeps (see `withoutShape`).
    public var shape: FireballShape?
    /// The luminous gas cell by cell, for the volume model; nil unless asked for, and in the
    /// frames a result keeps.
    public var cells: LuminousCells?
    /// What the fireball radiated at this moment, in watts, as the volume model measured it
    /// round it (see `ThermalExposure.radiatedPower`); nil where it was not.
    public var radiatedPower: Double?

    public init(
        time: Double, volume: Double, centre: SIMD3<Float>, temperature: Float, hottest: Float,
        shape: FireballShape? = nil, cells: LuminousCells? = nil
    ) {
        self.time = time
        self.volume = volume
        self.centre = centre
        self.temperature = temperature
        self.hottest = hottest
        self.shape = shape
        self.cells = cells
    }

    /// The equivalent sphere's radius.
    public var radius: Float { Float(cbrt(3 * volume / (4 * .pi))) }

    /// The frame without its cells, as they travel apart from it.
    public var withoutCells: FireballFrame {
        var frame = self
        frame.cells = nil
        return frame
    }

    /// The frame without its shape or cells, as a result keeps it: tens of kilobytes to
    /// megabytes a frame is too much to save with a run.
    public var withoutShape: FireballFrame {
        var frame = self
        frame.shape = nil
        frame.cells = nil
        return frame
    }
}

/// A point on a surface where the radiation is reckoned.
public struct ThermalReceiver: Codable, Sendable, Equatable {
    public var position: SIMD3<Float>
    /// Out of the surface.
    public var normal: SIMD3<Float>
    /// `ground`, `block <n>` or `structure`.
    public var surface: String

    public init(position: SIMD3<Float>, normal: SIMD3<Float>, surface: String) {
        self.position = position
        self.normal = normal
        self.surface = surface
    }
}

/// A rectangle of the scene's surface and the receivers on it, a grid of `columns` by `rows`
/// at the centres of equal cells: the ground, or a face of a block or of the structure.
public struct ThermalSurfaceGrid: Sendable, Equatable {
    /// `ground`, `block <n>` or `structure`, as its receivers'.
    public var surface: String
    /// One corner, and the edges from it along which the columns and the rows run.
    public var origin: SIMD3<Float>
    public var u: SIMD3<Float>
    public var v: SIMD3<Float>
    /// Out of the surface.
    public var normal: SIMD3<Float>
    public var columns: Int
    public var rows: Int
    /// The face's solid, as an index into the scene's blocks then its structure; nil for the ground.
    public var solid: Int?
    /// The receiver at each cell, row by row, as an index into the scene's receivers; nil where
    /// the cell's centre is inside a solid or out of the domain, and left out.
    public var indices: [Int?]
    /// The receivers on it, in order.
    public private(set) var receivers: [ThermalReceiver] = []

    package init(
        surface: String, origin: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>, normal: SIMD3<Float>,
        columns: Int, rows: Int, solid: Int? = nil
    ) {
        self.solid = solid
        self.surface = surface
        self.origin = origin
        self.u = u
        self.v = v
        self.normal = normal
        self.columns = columns
        self.rows = rows
        indices = []
        indices.reserveCapacity(columns * rows)
    }

    package mutating func add(
        _ point: SIMD3<Float>, column: Int, row: Int, buried: Bool, first: inout Int,
        normal: SIMD3<Float>? = nil
    ) {
        guard !buried else {
            indices.append(nil)
            return
        }
        indices.append(first)
        first += 1
        receivers.append(ThermalReceiver(position: point, normal: normal ?? self.normal, surface: surface))
    }

    /// Values at its cells, row by row, from values at the scene's receivers, each cell with no
    /// receiver taking the mean of its nearest neighbours that have one, so that a surface
    /// interpolated between the cells' centres has no holes at its edges; nil if none has one.
    public func filled(_ values: (Int) -> Float) -> [Float]? {
        var result = indices.map { $0.map(values) }
        guard result.contains(where: { $0 != nil }) else { return nil }
        while result.contains(where: { $0 == nil }) {
            let previous = result
            for row in 0..<rows {
                for column in 0..<columns where previous[row * columns + column] == nil {
                    var sum: Float = 0
                    var count: Float = 0
                    for (dc, dr) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                        let (c, r) = (column + dc, row + dr)
                        guard c >= 0, c < columns, r >= 0, r < rows, let value = previous[r * columns + c]
                        else {
                            continue
                        }
                        sum += value
                        count += 1
                    }
                    if count > 0 { result[row * columns + column] = sum / count }
                }
            }
        }
        return result.map { $0! }
    }
}

/// What a thermal radiation study found.
public struct ThermalResult: Codable, Sendable, Equatable {
    public var spec: ThermalSpec
    public var receivers: [ThermalReceiver]
    /// In watts a square metre, one a receiver.
    public var peakIrradiance: [Float]
    /// In joules a square metre, one a receiver.
    public var fluence: [Float]
    public var fireball: [FireballFrame]
    /// The charge's energy, in joules.
    public var chargeEnergy: Double
    /// The receivers' surfaces heated by it; nil where that was not reckoned, as before it was.
    public var heating: SurfaceHeatingResult?

    public init(
        spec: ThermalSpec, receivers: [ThermalReceiver], peakIrradiance: [Float], fluence: [Float],
        fireball: [FireballFrame], chargeEnergy: Double, heating: SurfaceHeatingResult? = nil
    ) {
        self.heating = heating
        self.spec = spec
        self.receivers = receivers
        self.peakIrradiance = peakIrradiance
        self.fluence = fluence
        self.fireball = fireball
        self.chargeEnergy = chargeEnergy
    }

    /// Whether every frame with a fireball measured what it radiated.
    public var isRadiationMeasured: Bool {
        fireball.contains { $0.radiatedPower != nil }
            && fireball.allSatisfy { $0.radiatedPower != nil || $0.volume == 0 }
    }
}
