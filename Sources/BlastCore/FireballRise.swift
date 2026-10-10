import Foundation
import simd

/// A study of the fireball's rise and cloud after the blast: what it is asked for. Any field
/// left out of its JSON takes its default.
public struct CloudSpec: Codable, Sendable, Equatable {
    /// Gas at least this hot at the end of the run, once brought to the ambient pressure, is
    /// handed over as the cloud, in kelvin.
    public var handOverTemperature: Float = 500
    /// The entrainment coefficient: the speed at which the surrounding air is drawn in, as a
    /// share of the cloud's rise speed. In the self-similar regime the cloud's radius grows by
    /// this much for each metre it rises.
    public var entrainment = 0.25
    /// The added mass of the air the cloud pushes aside, as a share of the air it displaces; a
    /// half for a sphere.
    public var addedMass = 0.5
    /// The cloud's emissivity for the heat it radiates; 0 keeps all its heat.
    public var emissivity = 0.0
    /// The atmosphere's lapse rate up to the tropopause, in kelvin a metre; isothermal above.
    public var lapseRate = 0.0065
    public var tropopause = 11_000.0
    /// The specific heat of the cloud's gas and of the air it draws in, in J/(kg K).
    public var specificHeat = 1005.0
    /// The wind `windHeight` up, in metres a second, and the direction it blows towards, in
    /// degrees anticlockwise from the scene's x axis towards its y axis.
    public var windSpeed = 0.0
    public var windDirection = 0.0
    public var windHeight = 10.0
    /// The wind grows with height as (z / windHeight)^windExponent, a seventh for open country in
    /// neutral air, up to `windCeiling`, and is steady above it.
    public var windExponent = 1.0 / 7
    public var windCeiling = 1000.0
    /// The air's relative humidity, the same at every height up to the tropopause, which is dry
    /// above; 0, dry air, by default.
    public var relativeHumidity = 0.0
    /// The water in the charge's products, in kilograms a kilogram of charge: TNT's hydrogen
    /// makes a fifth of its mass in water whether it burns or not.
    public var productWater = 0.2
    /// The share of the cloud's condensed water beyond `rainThreshold` (kilograms a kilogram)
    /// that falls out as rain or snow each second, as in Kessler's (1969) scheme; 0 keeps it all.
    public var rainRate = 0.001
    public var rainThreshold = 0.0005
    /// The atmospheric boundary layer's turbulence, which draws air into the cloud as well as its
    /// own motion does: its friction velocity u* and convective velocity w*, in metres a second,
    /// and its depth, above which the air is still. None by default.
    public var frictionVelocity = 0.0
    public var convectiveVelocity = 0.0
    public var boundaryLayerHeight = 1000.0
    /// The entrainment coefficient of the ambient turbulence, ADMS's α₃.
    public var turbulentEntrainment = 0.655
    /// A measured atmosphere in place of the standard one, with its own wind and humidity, and
    /// the direction of north in it, in degrees anticlockwise from the scene's x axis.
    public var sounding: CloudSounding?
    public var northDirection = 90.0
    /// Once it stops rising, the cloud spreads at its level as a gravity current where the air
    /// is stable, and grows as a passive puff in the air's turbulence, drifting with the wind;
    /// false follows the rising thermal on instead.
    public var spread = true
    /// The Froude number at the gravity current's front, u = Fr N h / 2; 1.19 after Ungarish.
    public var frontFroude = 1.19
    /// The Pasquill stability class, "A" (very unstable) to "F" (moderately stable), that sets
    /// the puff's growth; nil, the default, takes it from the air's lapse rate at the cloud.
    public var stabilityClass: String?
    /// The puff's growth is given against the distance it has travelled; in calmer air than
    /// this, in metres a second, it is taken to travel at this speed.
    public var leastTransportSpeed = 1.0
    /// Seconds of the cloud's rise followed after the run.
    public var duration = 600.0
    /// Seconds of the cloud's rise between frames of the USD scene.
    public var frameInterval = 1.0

    public init() {}

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CloudSpec()
        handOverTemperature =
            try values.decodeIfPresent(Float.self, forKey: .handOverTemperature)
            ?? defaults.handOverTemperature
        entrainment = try values.decodeIfPresent(Double.self, forKey: .entrainment) ?? defaults.entrainment
        addedMass = try values.decodeIfPresent(Double.self, forKey: .addedMass) ?? defaults.addedMass
        emissivity = try values.decodeIfPresent(Double.self, forKey: .emissivity) ?? defaults.emissivity
        lapseRate = try values.decodeIfPresent(Double.self, forKey: .lapseRate) ?? defaults.lapseRate
        tropopause = try values.decodeIfPresent(Double.self, forKey: .tropopause) ?? defaults.tropopause
        specificHeat = try values.decodeIfPresent(Double.self, forKey: .specificHeat) ?? defaults.specificHeat
        windSpeed = try values.decodeIfPresent(Double.self, forKey: .windSpeed) ?? defaults.windSpeed
        windDirection =
            try values.decodeIfPresent(Double.self, forKey: .windDirection) ?? defaults.windDirection
        windHeight = try values.decodeIfPresent(Double.self, forKey: .windHeight) ?? defaults.windHeight
        windExponent = try values.decodeIfPresent(Double.self, forKey: .windExponent) ?? defaults.windExponent
        windCeiling = try values.decodeIfPresent(Double.self, forKey: .windCeiling) ?? defaults.windCeiling
        relativeHumidity =
            try values.decodeIfPresent(Double.self, forKey: .relativeHumidity) ?? defaults.relativeHumidity
        productWater = try values.decodeIfPresent(Double.self, forKey: .productWater) ?? defaults.productWater
        rainRate = try values.decodeIfPresent(Double.self, forKey: .rainRate) ?? defaults.rainRate
        rainThreshold =
            try values.decodeIfPresent(Double.self, forKey: .rainThreshold) ?? defaults.rainThreshold
        frictionVelocity =
            try values.decodeIfPresent(Double.self, forKey: .frictionVelocity) ?? defaults.frictionVelocity
        convectiveVelocity =
            try values.decodeIfPresent(Double.self, forKey: .convectiveVelocity)
            ?? defaults.convectiveVelocity
        boundaryLayerHeight =
            try values.decodeIfPresent(Double.self, forKey: .boundaryLayerHeight)
            ?? defaults.boundaryLayerHeight
        turbulentEntrainment =
            try values.decodeIfPresent(Double.self, forKey: .turbulentEntrainment)
            ?? defaults.turbulentEntrainment
        sounding = try values.decodeIfPresent(CloudSounding.self, forKey: .sounding)
        northDirection =
            try values.decodeIfPresent(Double.self, forKey: .northDirection) ?? defaults.northDirection
        spread = try values.decodeIfPresent(Bool.self, forKey: .spread) ?? defaults.spread
        frontFroude = try values.decodeIfPresent(Double.self, forKey: .frontFroude) ?? defaults.frontFroude
        stabilityClass = try values.decodeIfPresent(String.self, forKey: .stabilityClass)
        leastTransportSpeed =
            try values.decodeIfPresent(Double.self, forKey: .leastTransportSpeed)
            ?? defaults.leastTransportSpeed
        duration = try values.decodeIfPresent(Double.self, forKey: .duration) ?? defaults.duration
        frameInterval =
            try values.decodeIfPresent(Double.self, forKey: .frameInterval) ?? defaults.frameInterval
    }

    public func validate() throws {
        let finite = [
            Double(handOverTemperature), entrainment, addedMass, emissivity, lapseRate, tropopause,
            specificHeat,
            duration, frameInterval, windSpeed, windDirection, windHeight, windExponent, windCeiling,
            relativeHumidity, productWater, rainRate, rainThreshold, frictionVelocity, convectiveVelocity,
            boundaryLayerHeight, turbulentEntrainment, northDirection, frontFroude, leastTransportSpeed,
        ]
        guard finite.allSatisfy(\.isFinite), handOverTemperature > 300, entrainment > 0, entrainment <= 1,
            addedMass >= 0, addedMass <= 2, emissivity >= 0, emissivity <= 1, lapseRate >= 0,
            lapseRate < CloudRise.gravity / specificHeat, tropopause > 0, specificHeat >= 500,
            specificHeat <= 3000,
            duration > 0, duration <= 7200, frameInterval >= 0.01, duration / frameInterval <= 100_000,
            windSpeed >= 0, windSpeed <= 100, windHeight > 0, windExponent >= 0, windExponent <= 1,
            windCeiling >= windHeight, relativeHumidity >= 0, relativeHumidity <= 1, productWater >= 0,
            productWater <= 1, rainRate >= 0, rainRate <= 1, rainThreshold >= 0, rainThreshold <= 0.01,
            frictionVelocity >= 0, frictionVelocity <= 3, convectiveVelocity >= 0, convectiveVelocity <= 5,
            boundaryLayerHeight >= 10, boundaryLayerHeight <= 5000, turbulentEntrainment >= 0,
            turbulentEntrainment <= 2, frontFroude >= 0, frontFroude <= 3, leastTransportSpeed >= 0.1,
            leastTransportSpeed <= 10, stabilityClass.map({ PasquillClass(rawValue: $0) != nil }) ?? true
        else {
            throw CocoaError(
                .coderInvalidValue,
                userInfo: [NSLocalizedDescriptionKey: "The cloud description is out of range."])
        }
        if let sounding {
            guard windSpeed == 0, relativeHumidity == 0 else {
                throw CocoaError(
                    .coderInvalidValue,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "A sounding brings its own wind and humidity: leave windSpeed and relativeHumidity at 0."
                    ])
            }
            try sounding.validate()
        }
    }
}

/// The hot gas left in the air at the end of a run, as the cloud model takes it over: its mass,
/// and its volume, centre and temperature once brought to the ambient pressure.
public struct CloudHandOver: Codable, Sendable, Equatable {
    public var time: Double
    /// Of the gas at least `handOverTemperature`, in kilograms; zero if there is none.
    public var mass: Double
    /// At the ambient pressure, in cubic metres.
    public var volume: Double
    /// The centre of its mass.
    public var centre: SIMD3<Float>
    /// Its mass-weighted mean temperature at the ambient pressure, p / (ρR), in kelvin: what makes
    /// its volume, and so its buoyancy, right.
    public var temperature: Double
    /// The mean vertical velocity of its mass, in metres a second.
    public var riseSpeed: Double
    /// The mean horizontal velocity of its mass.
    public var horizontalVelocity: SIMD2<Double>
    /// The charges' mass, in kilograms of TNT, whose products are taken to be in the gas handed
    /// over and bring their water with them.
    public var chargeMass: Double
    /// The hottest of it, in kelvin.
    public var hottest: Double
    /// Its buoyancy, its weight less that of the air it displaces, in newtons.
    public var buoyancy: Double
    /// The buoyancy of all the gas warmer than the ambient air, handed over or not.
    public var warmBuoyancy: Double
    /// The air at the ground.
    public var ambientTemperature: Double
    public var ambientPressure: Double

    public init(
        time: Double, mass: Double, volume: Double, centre: SIMD3<Float>, temperature: Double,
        riseSpeed: Double,
        hottest: Double, buoyancy: Double, warmBuoyancy: Double, ambientTemperature: Double,
        ambientPressure: Double, horizontalVelocity: SIMD2<Double> = .zero, chargeMass: Double = 0
    ) {
        self.time = time
        self.chargeMass = chargeMass
        self.horizontalVelocity = horizontalVelocity
        self.mass = mass
        self.volume = volume
        self.centre = centre
        self.temperature = temperature
        self.riseSpeed = riseSpeed
        self.hottest = hottest
        self.buoyancy = buoyancy
        self.warmBuoyancy = warmBuoyancy
        self.ambientTemperature = ambientTemperature
        self.ambientPressure = ambientPressure
    }

    /// The radius of a sphere of its volume.
    public var radius: Double { cbrt(3 * volume / (4 * .pi)) }

    /// The same gas in other air at the ground, as in a sounding: as many times as hot as that
    /// air as it was in the run's, so of the same buoyancy, at its pressure.
    public func inAir(_ air: (temperature: Double, pressure: Double)) -> CloudHandOver {
        var moved = self
        guard ambientTemperature > 0 else { return moved }
        moved.temperature *= air.temperature / ambientTemperature
        moved.hottest *= air.temperature / ambientTemperature
        moved.volume *= (air.temperature / ambientTemperature) * (ambientPressure / air.pressure)
        moved.ambientTemperature = air.temperature
        moved.ambientPressure = air.pressure
        return moved
    }
}

extension BlastSolver {
    /// The gas at least `hotterThan` kelvin once brought to the ambient pressure, to hand over to
    /// the cloud model. Each cell of air is brought to the ambient pressure isentropically, with
    /// the configuration's gamma; its temperature is then p / (ρR), which for dissociating air
    /// is above the true temperature but gives its density. Reads the state, spread across the
    /// CPU's cores; call it only while no batch is in flight.
    public func cloudHandOver(hotterThan threshold: Float) -> CloudHandOver {
        let (nx, ny, nz) = (grid.nx, grid.ny, grid.nz)
        let cellVolume = pow(Double(grid.cellSize), 3)
        let h = Double(grid.cellSize)
        let gamma = configuration.gamma
        let airModel = configuration.airModel
        let ambientPressure = Double(configuration.ambientPressure)
        let gasConstant = Double(AirModel.gasConstant)
        let ambientTemperature = ambientPressure / (Double(ambientDensity) * gasConstant)
        // Under gravity, each plane's own ambient pressure and temperature, the atmosphere the air
        // rests in, so that gas risen high is relaxed to the pressure around it and judged against
        // the air beside it.
        let gravity = configuration.gravity
        let ground = gravityGround
        let planeAmbient: [(pressure: Double, temperature: Double)] = (0..<nz).map { k in
            guard let gravity else { return (ambientPressure, ambientTemperature) }
            let air = gravity.atmosphere(at: (Float(k) + 0.5) * grid.cellSize, ground: ground)
            // A hundred-thousandth above it, so that the rounding between the background the GPU
            // holds and this one reads as no warmth.
            return (
                Double(air.pressure), 1.00001 * Double(air.pressure) / (Double(air.density) * gasConstant)
            )
        }
        let mask = maskBuffer.contents().bindMemory(to: UInt8.self, capacity: grid.cellCount)
        struct Sums {
            var mass = 0.0
            var heat = 0.0
            var position = SIMD3<Double>.zero
            var momentum = SIMD3<Double>.zero
            var hottest = 0.0
            var warm = 0.0
        }
        var planes = [Sums](repeating: Sums(), count: nz)
        withState { cells in
            planes.withUnsafeMutableBufferPointer { planes in
                DispatchQueue.concurrentPerform(iterations: nz) { k in
                    var sums = Sums()
                    let (planePressure, planeTemperature) = planeAmbient[k]
                    for j in 0..<ny {
                        for i in 0..<nx {
                            let index = grid.index(i, j, k)
                            guard mask[index] == 0 else { continue }
                            let air = Self.primitive(of: cells[index], gamma: gamma, airModel: airModel)
                            let density = Double(air.density)
                            let pressure = Double(air.pressure)
                            guard density > 0, pressure > 0, density.isFinite, pressure.isFinite else {
                                continue
                            }
                            let relaxed = density * pow(planePressure / pressure, 1 / Double(gamma))
                            let t = planePressure / (relaxed * gasConstant)
                            guard t > planeTemperature else { continue }
                            let mass = density * cellVolume
                            sums.warm += mass * (t / planeTemperature - 1)
                            guard t >= Double(threshold) else { continue }
                            sums.mass += mass
                            sums.heat += mass * t
                            sums.position +=
                                mass * SIMD3<Double>(Double(i) + 0.5, Double(j) + 0.5, Double(k) + 0.5)
                            sums.momentum += mass * SIMD3<Double>(air.velocity)
                            sums.hottest = max(sums.hottest, t)
                        }
                    }
                    planes[k] = sums
                }
            }
        }
        let total = planes.reduce(into: Sums()) { total, plane in
            total.mass += plane.mass
            total.heat += plane.heat
            total.position += plane.position
            total.momentum += plane.momentum
            total.hottest = max(total.hottest, plane.hottest)
            total.warm += plane.warm
        }
        let g = CloudRise.gravity
        guard total.mass > 0 else {
            return CloudHandOver(
                time: time, mass: 0, volume: 0, centre: .zero, temperature: 0, riseSpeed: 0, hottest: 0,
                buoyancy: 0, warmBuoyancy: g * total.warm, ambientTemperature: ambientTemperature,
                ambientPressure: ambientPressure)
        }
        let temperature = total.heat / total.mass
        let centre = SIMD3<Float>(total.position / total.mass * h)
        // Under gravity, its volume and buoyancy in the air at its centre's height.
        let around: (pressure: Double, temperature: Double) =
            gravity.map { gravity in
                let air = gravity.atmosphere(at: centre.z, ground: ground)
                return (Double(air.pressure), Double(air.pressure) / (Double(air.density) * gasConstant))
            } ?? (ambientPressure, ambientTemperature)
        return CloudHandOver(
            time: time, mass: total.mass, volume: total.mass * gasConstant * temperature / around.pressure,
            centre: centre, temperature: temperature,
            riseSpeed: total.momentum.z / total.mass, hottest: total.hottest,
            buoyancy: g * total.mass * (temperature / around.temperature - 1), warmBuoyancy: g * total.warm,
            ambientTemperature: ambientTemperature, ambientPressure: ambientPressure,
            horizontalVelocity: SIMD2(total.momentum.x, total.momentum.y) / total.mass)
    }
}

/// The still air the cloud rises through: the temperature falling at a steady lapse rate up to
/// the tropopause and constant above it, and the pressure in hydrostatic balance, as in the
/// International Standard Atmosphere's lower layers.
public struct CloudAtmosphere: Sendable, Equatable {
    public var groundTemperature: Double
    public var groundPressure: Double
    /// In kelvin a metre.
    public var lapseRate: Double
    public var tropopause: Double

    public init(groundTemperature: Double, groundPressure: Double, lapseRate: Double, tropopause: Double) {
        self.groundTemperature = groundTemperature
        self.groundPressure = groundPressure
        self.lapseRate = lapseRate
        self.tropopause = tropopause
    }

    /// The temperature (K) and pressure (Pa) at `height` metres above the ground.
    public func callAsFunction(_ height: Double) -> (temperature: Double, pressure: Double) {
        let g = CloudRise.gravity
        let r = CloudRise.gasConstant
        let z = min(height, tropopause)
        let temperature = groundTemperature - lapseRate * z
        let pressure =
            lapseRate > 0
            ? groundPressure * pow(temperature / groundTemperature, g / (r * lapseRate))
            : groundPressure * exp(-g * z / (r * groundTemperature))
        guard height > tropopause else { return (temperature, pressure) }
        return (temperature, pressure * exp(-g * (height - tropopause) / (r * temperature)))
    }
}

/// The wind the cloud drifts in: steady, from one direction, and growing with height as a power
/// law, the usual description of the wind near the ground in neutral air, up to a ceiling.
public struct CloudWind: Sendable, Equatable {
    /// At `height`, in metres a second.
    public var speed: Double
    /// The direction it blows towards, in radians anticlockwise from the x axis.
    public var direction: Double
    public var height: Double
    public var exponent: Double
    public var ceiling: Double

    public init(
        speed: Double, direction: Double, height: Double = 10, exponent: Double = 1.0 / 7, ceiling: Double
    ) {
        self.speed = speed
        self.direction = direction
        self.height = height
        self.exponent = exponent
        self.ceiling = ceiling
    }

    /// The wind's velocity at `height` metres above the ground; none below it.
    public func callAsFunction(_ z: Double) -> SIMD2<Double> {
        guard speed > 0, z > 0 else { return .zero }
        return speed * pow(min(z, ceiling) / height, exponent) * SIMD2(cos(direction), sin(direction))
    }
}

/// The water vapour in the air the cloud rises through: a steady relative humidity up to the
/// tropopause, and dry air above.
public struct CloudHumidity: Sendable, Equatable {
    public var relativeHumidity: Double
    public var atmosphere: CloudAtmosphere

    public init(relativeHumidity: Double, atmosphere: CloudAtmosphere) {
        self.relativeHumidity = relativeHumidity
        self.atmosphere = atmosphere
    }

    /// The air's specific humidity at `height`, in kilograms of vapour a kilogram of air.
    public func callAsFunction(_ height: Double) -> Double {
        guard relativeHumidity > 0, height <= atmosphere.tropopause else { return 0 }
        let air = atmosphere(height)
        return relativeHumidity
            * CloudRise.saturationHumidity(temperature: air.temperature, pressure: air.pressure)
    }
}

/// The turbulence of the atmospheric boundary layer, which draws air into the cloud however it
/// moves: its profiles as ADMS gives them (CERC's boundary layer structure specification, after
/// Hunt, Holroyd and Carruthers, 1988), from a friction velocity u*, a convective velocity w*
/// and the layer's depth h, with still air above it, and the entrainment speed they add, as in
/// ADMS's plume rise model.
public struct CloudTurbulence: Sendable, Equatable {
    public var frictionVelocity: Double
    public var convectiveVelocity: Double
    public var height: Double
    /// ADMS's α₃.
    public var coefficient: Double
    static let karman = 0.4

    public init(
        frictionVelocity: Double, convectiveVelocity: Double, height: Double, coefficient: Double = 0.655
    ) {
        self.frictionVelocity = frictionVelocity
        self.convectiveVelocity = convectiveVelocity
        self.height = height
        self.coefficient = coefficient
    }

    /// The root mean square vertical velocity σ_w, in metres a second, the rate of dissipation
    /// of turbulent kinetic energy ε, in m²/s³, and the Lagrangian time scale T_L, in seconds,
    /// `z` metres above the ground; nil where there is none. Taken from 1 m up nearer the
    /// ground.
    public func callAsFunction(_ z: Double) -> (velocity: Double, dissipation: Double, timescale: Double)? {
        let (ustar, wstar, h) = (frictionVelocity, convectiveVelocity, height)
        guard ustar > 0 || wstar > 0, z < h else { return nil }
        let z = max(z, 1)
        let mechanical = 1 - 0.8 * z / h
        let convective = 2.1 * cbrt(z / h) * mechanical
        let velocity = sqrt(pow(1.3 * ustar * mechanical, 2) + 0.4 * pow(wstar * convective, 2))
        // The vertical length scale, without its terms for the shear, the stratification and
        // the capping inversion; near the ground it is κz, so that ε is u*³ / κz there.
        let length = wstar > 0 ? 1 / (0.6 / z + 2 / h) : 1 / (2.5 / z + 4 / h)
        let dissipation = pow(ustar * mechanical, 3) / length + 0.4 * pow(wstar, 3) / h
        // |h / L|, the Monin–Obukhov length L from w*³ = h u*³ / κ|L|.
        let instability = ustar > 0 ? Self.karman * pow(wstar / ustar, 3) : .infinity
        let timescale =
            wstar > 0
            ? (instability.isFinite ? (instability + 1 / 1.3) / (instability + 1) : 1) * length / velocity
            : length / (1.3 * velocity)
        return (velocity, dissipation, timescale)
    }

    /// The speed at which the turbulence draws air in across the surface of a cloud of `radius`
    /// `height` up, `time` seconds after the detonation: α₃ min((εb)^⅓, σ_w (1 + t / 2T_L)^−½),
    /// eddies smaller than the cloud mixing into it and the larger ones' share falling as they
    /// come to carry it about rather than mix it.
    public func entrainmentSpeed(height: Double, radius: Double, time: Double) -> Double {
        guard coefficient > 0, let air = self(height) else { return 0 }
        return coefficient
            * min(cbrt(air.dissipation * radius), air.velocity / sqrt(1 + max(time, 0) / (2 * air.timescale)))
    }
}

/// The cloud at one moment: a sphere of well-mixed gas at the ambient pressure.
public struct CloudSample: Codable, Sendable, Equatable {
    /// Since the detonation, in seconds.
    public var time: Double
    /// Of its centre above the ground, in metres.
    public var height: Double
    public var radius: Double
    /// In kelvin, and the air's around it.
    public var temperature: Double
    public var ambientTemperature: Double
    /// Upward, in metres a second.
    public var riseSpeed: Double
    /// In kilograms: what was handed over and all the air drawn in since.
    public var mass: Double
    /// Of its centre across the ground, in the scene's x and y.
    public var position: SIMD2<Double>
    /// Across the ground, in metres a second.
    public var velocity: SIMD2<Double>
    /// All its water, and the liquid and frozen parts of it, in kilograms a kilogram of cloud.
    public var water: Double
    public var liquidWater: Double
    public var ice: Double
    /// The water that has fallen out of it so far, in kilograms, and how much of that as snow.
    public var precipitation: Double
    public var snow: Double
    /// Once it has stopped rising and spreads, its half-depth, the vertical semi-axis of an
    /// ellipsoid whose horizontal semi-axis is `radius`; nil while it is a rising sphere.
    public var thickness: Double?
    /// The Pasquill stability class its growth took then.
    public var stabilityClass: String?

    public init(
        time: Double, height: Double, radius: Double, temperature: Double, ambientTemperature: Double,
        riseSpeed: Double, mass: Double, position: SIMD2<Double> = .zero, velocity: SIMD2<Double> = .zero,
        water: Double = 0, liquidWater: Double = 0, ice: Double = 0, precipitation: Double = 0,
        snow: Double = 0, thickness: Double? = nil, stabilityClass: String? = nil
    ) {
        self.thickness = thickness
        self.stabilityClass = stabilityClass
        self.water = water
        self.liquidWater = liquidWater
        self.ice = ice
        self.precipitation = precipitation
        self.snow = snow
        self.position = position
        self.velocity = velocity
        self.time = time
        self.height = height
        self.radius = radius
        self.temperature = temperature
        self.ambientTemperature = ambientTemperature
        self.riseSpeed = riseSpeed
        self.mass = mass
    }

    /// Its vertical semi-axis: its radius while it rises, its half-depth once it spreads.
    public var halfDepth: Double { thickness ?? radius }

    /// The top of the cloud above the ground.
    public var top: Double { height + halfDepth }

    /// Its bottom, at the ground once it reaches it.
    public var bottom: Double { max(height - halfDepth, 0) }

    /// Its volume, a sphere's or an ellipsoid's.
    public var volume: Double { 4 / 3 * Double.pi * radius * radius * halfDepth }
}

/// The rise of a buoyant cloud as an integral model of a turbulent thermal: Morton, Taylor and
/// Turner's (1956) entrainment assumption, the air drawn in across the cloud's surface at a
/// fixed share of its speed through that air, in the form Escudier and Maxworthy (1973) gave for
/// any density difference and with the added mass of the air pushed aside. The cloud is a sphere
/// of well-mixed gas at the ambient pressure, rising through air whose temperature and pressure
/// fall with height, which may blow and may be humid; it cools by mixing with that air, by
/// expanding as it rises, and, if it is given an emissivity, by radiating, it is carried along by
/// the wind's momentum in the air it draws in, and the water it carries condenses once it is
/// saturated, releasing its latent heat, as in Morton's (1957) and Squires and Turner's (1962)
/// moist plumes.
public enum CloudRise {
    public static let gravity = 9.806_65
    public static let gasConstant = Double(AirModel.gasConstant)
    /// Water's latent heats of vaporisation and of fusion, in J/kg, and the ratio of its gas
    /// constant to dry air's.
    public static let latentHeat = 2.501e6
    public static let fusionHeat = 3.34e5
    public static let molarRatio = 0.622
    /// Condensed water is all liquid above the first and all ice below the second, in kelvin.
    public static let freezingPoint = 273.16
    public static let iceTemperature = 250.16

    /// The saturation vapour pressure over water at `temperature` kelvin, in pascals: Bolton's
    /// (1980) fit, within 0.1% from −30 °C to 35 °C.
    public static func saturationPressure(temperature: Double) -> Double {
        611.2 * exp(17.67 * (temperature - 273.15) / (temperature - 29.65))
    }

    /// The saturation vapour pressure over ice, in pascals: Tetens' form with the constants of
    /// ECMWF's IFS.
    public static func saturationPressureOverIce(temperature: Double) -> Double {
        611.21 * exp(22.587 * (temperature - freezingPoint) / (temperature + 0.7))
    }

    /// The share of condensed water that is liquid at `temperature`: all of it at the freezing
    /// point and above, none at `iceTemperature` and below, and the square of the way between in
    /// between, as in ECMWF's IFS.
    public static func liquidFraction(temperature: Double) -> Double {
        let x = (temperature - iceTemperature) / (freezingPoint - iceTemperature)
        return min(max(x, 0), 1) * min(max(x, 0), 1)
    }

    /// The specific humidity of air saturated over water, in kilograms of vapour a kilogram of
    /// moist air; infinite where water would boil.
    public static func saturationHumidity(temperature: Double, pressure: Double) -> Double {
        humidity(vapourPressure: saturationPressure(temperature: temperature), pressure: pressure)
    }

    /// The same over the cloud's condensed water, liquid and ice in the shares
    /// `liquidFraction` gives, its saturation vapour pressure blended in those shares.
    public static func cloudSaturationHumidity(temperature: Double, pressure: Double) -> Double {
        let liquid = liquidFraction(temperature: temperature)
        let vapour =
            liquid == 1
            ? saturationPressure(temperature: temperature)
            : liquid * saturationPressure(temperature: temperature) + (1 - liquid)
                * saturationPressureOverIce(temperature: temperature)
        return humidity(vapourPressure: vapour, pressure: pressure)
    }

    static func humidity(vapourPressure vapour: Double, pressure: Double) -> Double {
        guard vapour < pressure else { return .infinity }
        return molarRatio * vapour / (pressure - (1 - molarRatio) * vapour)
    }

    /// The temperature, vapour and ice of gas with frozen moist enthalpy `enthalpy`
    /// (c_p T + L_v q_v − L_f q_i, in J/kg) and `water` kilograms of water a kilogram at
    /// `pressure`: all vapour if that leaves it unsaturated, and otherwise saturated, the rest
    /// condensed, liquid and ice in the shares `liquidFraction` gives.
    public static func split(enthalpy: Double, water: Double, pressure: Double, specificHeat: Double) -> (
        temperature: Double, vapour: Double, ice: Double
    ) {
        let dry = (enthalpy - latentHeat * water) / specificHeat
        guard water > 0, water > cloudSaturationHumidity(temperature: dry, pressure: pressure) else {
            return (dry, water, 0)
        }
        func state(_ t: Double) -> (residual: Double, vapour: Double, ice: Double) {
            let vapour = min(water, cloudSaturationHumidity(temperature: t, pressure: pressure))
            let ice = (1 - liquidFraction(temperature: t)) * (water - vapour)
            return (specificHeat * t + latentHeat * vapour - fusionHeat * ice - enthalpy, vapour, ice)
        }
        // The residual rises with T, between all vapour and all condensed and frozen: Newton's
        // method on a numerical slope, kept within that bracket.
        var low = dry
        var high = (enthalpy + fusionHeat * water) / specificHeat
        var t = dry
        for _ in 0..<80 {
            let residual = state(t).residual
            if residual > 0 { high = t } else { low = t }
            let slope = (state(t + 1e-4).residual - residual) / 1e-4
            var next = t - residual / max(slope, specificHeat)
            if !(next > low && next < high) { next = (low + high) / 2 }
            if abs(next - t) < 1e-10 || high - low < 1e-10 { break }
            t = next
        }
        let final = state(t)
        return (t, final.vapour, final.ice)
    }

    /// The temperature that gives dry air the density of moist air with `vapour` and `water`
    /// kilograms a kilogram at `temperature`, the condensate's volume neglected.
    static func densityTemperature(_ temperature: Double, vapour: Double, water: Double) -> Double {
        temperature * (1 + vapour / molarRatio - water)
    }

    /// The cloud's state for integration: height and place across the ground, mass, upward
    /// impulse (its own momentum and its added mass's), horizontal impulse (its own momentum and
    /// its added mass's relative to the wind), frozen moist enthalpy and water, each a kilogram,
    /// and the water fallen out of it, in all and as snow.
    struct State {
        var height: Double
        var position: SIMD2<Double>
        var mass: Double
        var impulse: Double
        var drift: SIMD2<Double>
        var enthalpy: Double
        var water: Double
        var fallen = 0.0
        var fallenIce = 0.0

        static func + (a: State, b: State) -> State {
            State(
                height: a.height + b.height, position: a.position + b.position, mass: a.mass + b.mass,
                impulse: a.impulse + b.impulse, drift: a.drift + b.drift, enthalpy: a.enthalpy + b.enthalpy,
                water: a.water + b.water, fallen: a.fallen + b.fallen, fallenIce: a.fallenIce + b.fallenIce)
        }

        static func * (a: State, s: Double) -> State {
            State(
                height: a.height * s, position: a.position * s, mass: a.mass * s, impulse: a.impulse * s,
                drift: a.drift * s, enthalpy: a.enthalpy * s, water: a.water * s, fallen: a.fallen * s,
                fallenIce: a.fallenIce * s)
        }
    }

    /// The cloud from `handOver`, followed through `atmosphere`, `wind`, `humidity` (the air's
    /// specific humidity) and `turbulence` (the speed at which it draws air in across a cloud's
    /// surface, at a height and of a radius, a time after the detonation) and sampled at `times`, which must be ascending and no earlier than the
    /// hand-over; also the first moment it stopped rising, if it did by the last of them.
    public static func follow(
        _ handOver: CloudHandOver, spec: CloudSpec,
        atmosphere: @escaping (Double) -> (temperature: Double, pressure: Double),
        wind: @escaping (Double) -> SIMD2<Double> = { _ in .zero },
        humidity: @escaping (Double) -> Double = { _ in 0 },
        turbulence: @escaping (_ height: Double, _ radius: Double, _ time: Double) -> Double = { _, _, _ in 0
        },
        at times: [Double]
    ) -> (samples: [CloudSample], stabilised: CloudSample?) {
        guard handOver.mass > 0, let end = times.last else { return ([], nil) }
        let model = Model(
            spec: spec, atmosphere: atmosphere, wind: wind, humidity: humidity, turbulence: turbulence)
        let start = Double(handOver.centre.z)
        let air = atmosphere(start)
        // The products' water, and the air's in the rest of the gas.
        let products = min(handOver.chargeMass, handOver.mass)
        let water =
            (spec.productWater * products + humidity(start) * (handOver.mass - products)) / handOver.mass
        // The hand-over's temperature gives its density: all its water is vapour, lighter than
        // air, so it is that much cooler. Then brought from the ground's pressure to that at its
        // height.
        let temperature =
            handOver.temperature / (1 + water / molarRatio - water)
            * pow(air.pressure / handOver.ambientPressure, gasConstant / spec.specificHeat)
        let vapour = min(water, cloudSaturationHumidity(temperature: temperature, pressure: air.pressure))
        let ice = (1 - liquidFraction(temperature: temperature)) * (water - vapour)
        var state = State(
            height: start, position: SIMD2(Double(handOver.centre.x), Double(handOver.centre.y)),
            mass: handOver.mass, impulse: 0, drift: .zero,
            enthalpy: spec.specificHeat * temperature + latentHeat * vapour - fusionHeat * ice, water: water)
        let d = model.derived(state)
        let added = spec.addedMass * d.ambientDensity * d.volume
        let velocity = handOver.horizontalVelocity
        state.impulse = (handOver.mass + added) * handOver.riseSpeed
        state.drift = handOver.mass * velocity + added * (velocity - wind(start))
        var time = handOver.time
        var samples: [CloudSample] = []
        var stabilised: CloudSample?
        var next = 0
        while next < times.count, times[next] <= time + 1e-12 {
            samples.append(model.sample(state, time: time))
            next += 1
        }
        var rising = model.sample(state, time: time).riseSpeed > 0
        while time < end - 1e-12 {
            let step = min(model.step(state, time: time), times[next] - time)
            let k1 = model.rate(state, time: time)
            let k2 = model.rate(state + k1 * (step / 2), time: time + step / 2)
            let k3 = model.rate(state + k2 * (step / 2), time: time + step / 2)
            let k4 = model.rate(state + k3 * step, time: time + step)
            state = state + (k1 + k2 * 2 + k3 * 2 + k4) * (step / 6)
            time += step
            let now = model.sample(state, time: time)
            if rising, now.riseSpeed <= 0, stabilised == nil {
                stabilised = now
                if spec.spread {
                    samples += model.spread(from: state, time: time, at: Array(times[next...]))
                    break
                }
            }
            rising = now.riseSpeed > 0
            while next < times.count, times[next] <= time + 1e-9 {
                samples.append(now)
                next += 1
            }
            if next == times.count { break }
        }
        return (samples, stabilised)
    }

    struct Model {
        let spec: CloudSpec
        let atmosphere: (Double) -> (temperature: Double, pressure: Double)
        let wind: (Double) -> SIMD2<Double>
        let humidity: (Double) -> Double
        let turbulence: (Double, Double, Double) -> Double
        static let stefanBoltzmann = 5.670_374e-8

        struct Derived {
            var temperature: Double
            var vapour: Double
            var ice: Double
            var ambientTemperature: Double
            var ambientPressure: Double
            var ambientDensity: Double
            var ambientHumidity: Double
            var volume: Double
            var radius: Double
            var riseSpeed: Double
            var velocity: SIMD2<Double>
            var wind: SIMD2<Double>
            /// Through the air around it.
            var relativeSpeed: Double
        }

        func derived(_ state: State) -> Derived {
            let air = atmosphere(state.height)
            let (temperature, vapour, ice) = CloudRise.split(
                enthalpy: state.enthalpy, water: state.water, pressure: air.pressure,
                specificHeat: spec.specificHeat)
            let ambientHumidity = humidity(state.height)
            let ambientDensity =
                air.pressure
                / (gasConstant
                    * densityTemperature(air.temperature, vapour: ambientHumidity, water: ambientHumidity))
            let volume =
                state.mass * gasConstant * densityTemperature(temperature, vapour: vapour, water: state.water)
                / air.pressure
            let added = spec.addedMass * ambientDensity * volume
            let wind = wind(state.height)
            let velocity = (state.drift + added * wind) / (state.mass + added)
            let riseSpeed = state.impulse / (state.mass + added)
            return Derived(
                temperature: temperature, vapour: vapour, ice: ice, ambientTemperature: air.temperature,
                ambientPressure: air.pressure, ambientDensity: ambientDensity,
                ambientHumidity: ambientHumidity,
                volume: volume, radius: cbrt(3 * volume / (4 * .pi)), riseSpeed: riseSpeed,
                velocity: velocity,
                wind: wind, relativeSpeed: simd_length(SIMD3(velocity - wind, riseSpeed)))
        }

        /// The time derivative of `state` at `time`: the air drawn in across the surface at the
        /// entrainment coefficient times the cloud's speed through it, and by the turbulence; the upward impulse changed
        /// by the buoyancy and the horizontal by the wind's momentum in the air drawn in; the
        /// water by the air's vapour drawn in; and the frozen moist enthalpy by the air's drawn
        /// in, by expanding as the pressure falls (dh = dp / ρ, which in hydrostatic air is about
        /// −(T / T_air) g dz), and by radiating. Condensing, evaporating, freezing and melting move
        /// heat between c_p T, L_v q_v and L_f q_i within the enthalpy, so they need no term of
        /// their own. Condensed water beyond the threshold falls out at the rain rate, taking its
        /// mass, its share of the enthalpy and its momentum with it.
        func rate(_ state: State, time: Double) -> State {
            let d = derived(state)
            let area = 4 * Double.pi * d.radius * d.radius
            let entrained = area * d.ambientDensity * entrainmentSpeed(d, height: state.height, time: time)
            let buoyancy = (d.ambientDensity * d.volume - state.mass) * gravity
            let radiated =
                spec.emissivity * Self.stefanBoltzmann
                * (pow(d.temperature, 4) - pow(d.ambientTemperature, 4))
                * area
            let gradient = (atmosphere(state.height + 1).pressure - atmosphere(state.height - 1).pressure) / 2
            let ambientEnthalpy = spec.specificHeat * d.ambientTemperature + latentHeat * d.ambientHumidity
            let condensed = state.water - d.vapour
            let falling = state.mass * spec.rainRate * max(condensed - spec.rainThreshold, 0)
            let frozen = condensed > 0 ? d.ice / condensed : 0
            let fallingEnthalpy = spec.specificHeat * d.temperature - fusionHeat * frozen
            let heating =
                (ambientEnthalpy - state.enthalpy) * entrained + d.volume * gradient * d.riseSpeed - radiated
                - falling * (fallingEnthalpy - state.enthalpy)
            return State(
                height: d.riseSpeed, position: d.velocity, mass: entrained - falling,
                impulse: buoyancy - falling * d.riseSpeed, drift: d.wind * entrained - falling * d.velocity,
                enthalpy: heating / state.mass,
                water: ((d.ambientHumidity - state.water) * entrained - falling * (1 - state.water))
                    / state.mass,
                fallen: falling, fallenIce: falling * frozen)
        }

        /// The speed at which air is drawn in across the surface: the entrainment coefficient
        /// times the cloud's speed through the air, and the turbulence's.
        func entrainmentSpeed(_ d: Derived, height: Double, time: Double) -> Double {
            spec.entrainment * d.relativeSpeed + turbulence(height, d.radius, time)
        }

        /// A step short against the time the cloud takes to move its own radius through the air,
        /// from rest or at its speed, to draw in its own mass, and to cool by radiation.
        func step(_ state: State, time: Double) -> Double {
            let d = derived(state)
            let inertia = state.mass + spec.addedMass * d.ambientDensity * d.volume
            let acceleration = abs(d.ambientDensity * d.volume - state.mass) * gravity / inertia
            let entrained =
                4 * Double.pi * d.radius * d.radius * d.ambientDensity
                * entrainmentSpeed(d, height: state.height, time: time)
            var step = min(
                0.02 * d.radius / max(d.relativeSpeed, 1e-6), 0.02 * sqrt(d.radius / max(acceleration, 1e-9)),
                0.02 * state.mass / max(entrained, 1e-30), 0.5)
            if spec.emissivity > 0 {
                let radiated =
                    spec.emissivity * Self.stefanBoltzmann * pow(d.temperature, 4) * 4 * .pi * d.radius
                    * d.radius
                step = min(step, 0.02 * state.mass * spec.specificHeat * d.temperature / radiated)
            }
            return max(step, 1e-7)
        }

        func sample(_ state: State, time: Double) -> CloudSample {
            let d = derived(state)
            return CloudSample(
                time: time, height: state.height, radius: d.radius, temperature: d.temperature,
                ambientTemperature: d.ambientTemperature, riseSpeed: d.riseSpeed, mass: state.mass,
                position: state.position, velocity: d.velocity, water: state.water,
                liquidWater: state.water - d.vapour - d.ice, ice: d.ice, precipitation: state.fallen,
                snow: state.fallenIce)
        }
    }
}

/// The cloud after a run: what was handed over and how it rose.
public struct CloudResult: Codable, Sendable, Equatable {
    public var spec: CloudSpec
    public var handOver: CloudHandOver
    /// From the hand-over, closer together early on when the cloud changes fastest.
    public var samples: [CloudSample]
    /// The first moment the cloud stopped rising, if it did.
    public var stabilised: CloudSample?

    /// Follows `handOver` through the standard atmosphere, the wind, the humidity and the
    /// turbulence `spec` describes, from the hand-over's own air at the ground, or through its
    /// sounding.
    public init(spec: CloudSpec, handOver: CloudHandOver) {
        self.spec = spec
        self.handOver = handOver
        let start = handOver.time
        var times = [start]
        var offset = 0.01
        while offset < spec.duration {
            times.append(start + offset)
            offset *= 1.05
        }
        times.append(start + spec.duration)
        (samples, stabilised) = Self.follow(handOver, spec: spec, at: times)
    }

    /// The cloud every `frameInterval` from the hand-over, for the USD scene.
    public func frames() -> [CloudSample] {
        let count = Int((spec.duration / spec.frameInterval).rounded(.down))
        return Self.follow(
            handOver, spec: spec, at: (0...count).map { handOver.time + Double($0) * spec.frameInterval }
        ).samples
    }

    private static func follow(_ handOver: CloudHandOver, spec: CloudSpec, at times: [Double]) -> (
        samples: [CloudSample], stabilised: CloudSample?
    ) {
        let turbulence = spec.turbulence
        if let sounding = spec.sounding {
            let north = spec.northDirection * .pi / 180
            return CloudRise.follow(
                handOver.inAir(sounding(0)), spec: spec, atmosphere: sounding.callAsFunction,
                wind: { sounding.wind($0, north: north) }, humidity: sounding.humidity,
                turbulence: turbulence.entrainmentSpeed, at: times)
        }
        return CloudRise.follow(
            handOver, spec: spec, atmosphere: spec.atmosphere(handOver).callAsFunction,
            wind: spec.wind.callAsFunction, humidity: spec.humidity(handOver).callAsFunction,
            turbulence: turbulence.entrainmentSpeed, at: times)
    }

    public var summary: [String] {
        guard handOver.mass > 0 else {
            return [
                String(
                    format: "Cloud: no gas at least %.0f K left at %.0f ms to hand over.",
                    Double(spec.handOverTemperature), handOver.time * 1000)
            ]
        }
        let start = SIMD2(Double(handOver.centre.x), Double(handOver.centre.y))
        let drift = { (sample: CloudSample) in
            self.spec.windSpeed > 0 || self.spec.sounding != nil
                ? String(format: ", %.0f m downwind", simd_length(sample.position - start)) : ""
        }
        var lines = [
            String(
                format:
                    "Cloud: %.0f kg of gas at least %.0f K handed over at %.0f ms, %.1f m across at %.0f K, its centre %.1f m up, rising at %.1f m/s; %.0f%% of the warm gas's buoyancy",
                handOver.mass, Double(spec.handOverTemperature), handOver.time * 1000, 2 * handOver.radius,
                handOver.temperature, Double(handOver.centre.z), handOver.riseSpeed,
                100 * handOver.buoyancy / max(handOver.warmBuoyancy, 1e-30))
        ]
        if let stabilised {
            lines.append(
                String(
                    format:
                        "  stopped rising at %.0f s: centre %.0f m up, top %.0f m, %.0f m across, %.1f K above the air",
                    stabilised.time, stabilised.height, stabilised.top, 2 * stabilised.radius,
                    stabilised.temperature - stabilised.ambientTemperature) + drift(stabilised))
        }
        let condensate = { (sample: CloudSample) in sample.liquidWater + sample.ice }
        if let wettest = samples.max(by: { condensate($0) < condensate($1) }), condensate(wettest) > 0 {
            let condensed = samples.filter { condensate($0) > 0 }
            lines.append(
                String(
                    format:
                        "  condensed from %.0f s to %.0f s, most %.2f g of water a kilogram (%.0f%% ice) at %.0f s, %.0f m up",
                    condensed.first?.time ?? 0, condensed.last?.time ?? 0, 1000 * condensate(wettest),
                    100 * wettest.ice / condensate(wettest), wettest.time, wettest.height))
        }
        if let last = samples.last, last.precipitation > 0 {
            let start = samples.first { $0.precipitation > 0 }?.time ?? last.time
            lines.append(
                String(
                    format: "  %.0f kg of water fell out from %.0f s, %.0f kg of it as snow",
                    last.precipitation,
                    start, last.snow))
        }
        if let last = samples.last {
            if let depth = last.thickness, let stabilised {
                lines.append(
                    String(
                        format:
                            "  at %.0f s: spread at %.0f m up, %.0f m across and %.0f m deep, its top %.0f m, class %@, %.1f times the gas it held when it stopped",
                        last.time, last.height, 2 * last.radius, 2 * depth, last.top,
                        last.stabilityClass ?? "?",
                        last.mass / stabilised.mass) + drift(last))
            } else {
                lines.append(
                    String(
                        format:
                            "  at %.0f s: centre %.0f m up, top %.0f m, %.0f m across, rising at %.1f m/s",
                        last.time, last.height, last.top, 2 * last.radius, last.riseSpeed) + drift(last))
            }
        }
        return lines
    }

    /// How far the cloud's centre has drifted across the ground from over the hand-over, in metres.
    public func drift(_ sample: CloudSample) -> Double {
        simd_length(sample.position - SIMD2(Double(handOver.centre.x), Double(handOver.centre.y)))
    }
}

extension CloudSpec {
    /// The standard atmosphere this describes, from `handOver`'s air at the ground.
    public func atmosphere(_ handOver: CloudHandOver) -> CloudAtmosphere {
        CloudAtmosphere(
            groundTemperature: handOver.ambientTemperature, groundPressure: handOver.ambientPressure,
            lapseRate: lapseRate, tropopause: tropopause)
    }

    /// The humidity this describes, in the standard atmosphere from `handOver`'s air.
    public func humidity(_ handOver: CloudHandOver) -> CloudHumidity {
        CloudHumidity(relativeHumidity: relativeHumidity, atmosphere: atmosphere(handOver))
    }

    /// The boundary layer's turbulence this describes.
    public var turbulence: CloudTurbulence {
        CloudTurbulence(
            frictionVelocity: frictionVelocity, convectiveVelocity: convectiveVelocity,
            height: boundaryLayerHeight, coefficient: turbulentEntrainment)
    }

    /// The wind this describes.
    public var wind: CloudWind {
        CloudWind(
            speed: windSpeed, direction: windDirection * .pi / 180, height: windHeight,
            exponent: windExponent,
            ceiling: windCeiling)
    }
}
