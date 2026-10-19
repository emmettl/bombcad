import Foundation
import simd

/// Layout matches `DeflagrationUniforms` in `Deflagration.metal`.
package struct DeflagrationUniforms {
    package var nx: UInt32 = 0
    package var ny: UInt32 = 0
    package var nz: UInt32 = 0
    package var dx: Float = 0
    package var ignitionCell: UInt32 = 0
    package var heat: Float = 0
    package var cloudFraction: Float = 0
    package var stoichiometricFraction: Float = 0
    package var lowerLimit: Float = 0
    package var upperLimit: Float = 0
    package var speedScale: Float = 0
    package var speedPower: Float = 0
    package var speedWidth: Float = 0
    package var speedFactor: Float = 1
    package var wrinklingRadius: Float = 0
    package var wrinklingPower: Float = 0
    package var wrinklingLimit: Float = 0
    package var turbulenceScale: Float = 0
    package var velocityPerViscosity: Float = 0
    package var ignitionX: Float = 0
    package var ignitionY: Float = 0
    package var ignitionZ: Float = 0
    package var densityFloor: Float = 0
    package var ambientPressure: Float = 0
    package var gamma: Float = 0
    package var airModel: UInt32 = 0
    package var panelCellCount: UInt32 = 0
    package var unburntDensity: Float = 0
    package var unburntGamma: Float = 0
    package var expansionRatio: Float = 0
    package var kinematicViscosity: Float = 0
    package var externalFactor: Float = 1
    package var regionMinX: Float = 0
    package var regionMinY: Float = 0
    package var regionMinZ: Float = 0
    package var regionMaxX: Float = 0
    package var regionMaxY: Float = 0
    package var regionMaxZ: Float = 0
    package var marksteinNumber: Float = 0
    /// A tabulated laminar burning velocity (`FlammableGas.burningVelocityTable`): how many points,
    /// their equivalence ratios and speeds (m/s); none uses Gülder's fit above.
    var speedTableCount: UInt32 = 0
    var speedPhi: SpeedTable = DeflagrationUniforms.emptyTable
    var speedValue: SpeedTable = DeflagrationUniforms.emptyTable

    package typealias SpeedTable = (
        Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float,
        Float, Float
    )
    static let emptyTable: SpeedTable = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    static let speedTableCapacity = 16

    /// Puts `points` (equivalence ratio, m/s) in the table.
    package mutating func setSpeedTable(_ points: [SIMD2<Float>]) {
        precondition(points.count <= Self.speedTableCapacity, "at most 16 burning-velocity points")
        speedTableCount = UInt32(points.count)
        withUnsafeMutableBytes(of: &speedPhi) { raw in
            let values = raw.bindMemory(to: Float.self)
            for (n, point) in points.enumerated() { values[n] = point.x }
        }
        withUnsafeMutableBytes(of: &speedValue) { raw in
            let values = raw.bindMemory(to: Float.self)
            for (n, point) in points.enumerated() { values[n] = point.y }
        }
    }

    /// The memberwise initialiser, written out so that BlastCore can use it.
    package init(
        nx: UInt32 = 0,
        ny: UInt32 = 0,
        nz: UInt32 = 0,
        dx: Float = 0,
        ignitionCell: UInt32 = 0,
        heat: Float = 0,
        cloudFraction: Float = 0,
        stoichiometricFraction: Float = 0,
        lowerLimit: Float = 0,
        upperLimit: Float = 0,
        speedScale: Float = 0,
        speedPower: Float = 0,
        speedWidth: Float = 0,
        speedFactor: Float = 1,
        wrinklingRadius: Float = 0,
        wrinklingPower: Float = 0,
        wrinklingLimit: Float = 0,
        turbulenceScale: Float = 0,
        velocityPerViscosity: Float = 0,
        ignitionX: Float = 0,
        ignitionY: Float = 0,
        ignitionZ: Float = 0,
        densityFloor: Float = 0,
        ambientPressure: Float = 0,
        gamma: Float = 0,
        airModel: UInt32 = 0,
        panelCellCount: UInt32 = 0,
        unburntDensity: Float = 0,
        unburntGamma: Float = 0,
        expansionRatio: Float = 0,
        kinematicViscosity: Float = 0,
        externalFactor: Float = 1,
        regionMinX: Float = 0,
        regionMinY: Float = 0,
        regionMinZ: Float = 0,
        regionMaxX: Float = 0,
        regionMaxY: Float = 0,
        regionMaxZ: Float = 0,
        marksteinNumber: Float = 0,
        speedTableCount: UInt32 = 0,
        speedPhi: SpeedTable = DeflagrationUniforms.emptyTable,
        speedValue: SpeedTable = DeflagrationUniforms.emptyTable
    ) {
        self.nx = nx
        self.ny = ny
        self.nz = nz
        self.dx = dx
        self.ignitionCell = ignitionCell
        self.heat = heat
        self.cloudFraction = cloudFraction
        self.stoichiometricFraction = stoichiometricFraction
        self.lowerLimit = lowerLimit
        self.upperLimit = upperLimit
        self.speedScale = speedScale
        self.speedPower = speedPower
        self.speedWidth = speedWidth
        self.speedFactor = speedFactor
        self.wrinklingRadius = wrinklingRadius
        self.wrinklingPower = wrinklingPower
        self.wrinklingLimit = wrinklingLimit
        self.turbulenceScale = turbulenceScale
        self.velocityPerViscosity = velocityPerViscosity
        self.ignitionX = ignitionX
        self.ignitionY = ignitionY
        self.ignitionZ = ignitionZ
        self.densityFloor = densityFloor
        self.ambientPressure = ambientPressure
        self.gamma = gamma
        self.airModel = airModel
        self.panelCellCount = panelCellCount
        self.unburntDensity = unburntDensity
        self.unburntGamma = unburntGamma
        self.expansionRatio = expansionRatio
        self.kinematicViscosity = kinematicViscosity
        self.externalFactor = externalFactor
        self.regionMinX = regionMinX
        self.regionMinY = regionMinY
        self.regionMinZ = regionMinZ
        self.regionMaxX = regionMaxX
        self.regionMaxY = regionMaxY
        self.regionMaxZ = regionMaxZ
        self.marksteinNumber = marksteinNumber
        self.speedTableCount = speedTableCount
        self.speedPhi = speedPhi
        self.speedValue = speedValue
    }
}

/// What has burnt so far, and when the panels opened.
public struct DeflagrationState: Sendable, Hashable {
    /// Unburnt mixture left, kg, and what was laid down.
    public var unburnt: Double
    public var initialUnburnt: Double
    /// Volume of the cells of mostly cloud gas that is mostly burnt, m³.
    public var burntVolume: Double
    /// When each panel with a release pressure opened (s), in scenario order, or nil.
    public var panelOpenTimes: [Double?]

    public var burntFraction: Double { initialUnburnt > 0 ? 1 - unburnt / initialUnburnt : 0 }

    /// The memberwise initialiser, written out so that BlastCore can use it.
    package init(
        unburnt: Double,
        initialUnburnt: Double,
        burntVolume: Double,
        panelOpenTimes: [Double?]
    ) {
        self.unburnt = unburnt
        self.initialUnburnt = initialUnburnt
        self.burntVolume = burntVolume
        self.panelOpenTimes = panelOpenTimes
    }
}
