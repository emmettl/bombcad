import BlastCore
import Foundation
import simd

/// `blastbench dialpack --budget out.csv`: the fireball's energy budget, frame by frame, read back
/// from the air's state between batches, so that the run is as it is without it
/// (emmettl/bombcad-work#22, stage 1). Each frame it reckons:
/// - the heat afterburning is releasing, Q r min(x, y/s) a cubic metre (Q the energy a kilogram of
///   products releases, r the burning rate, x and y the products' and oxygen's densities, s the
///   oxygen a kilogram of products takes), as the final sweep burns it over a step (to r dt, under
///   a thousandth here), binned by the cell's temperature and its mixture: lean, near
///   stoichiometric or rich by its equivalence ratio s x / y (below 0.7, to 1.4, above);
/// - the luminous gas (at least `luminousTemperature`): its mass, mean and T⁴-mean temperature,
///   its unburnt products, volume, heat above the ambient air's at its density, and mean absorption
///   coefficient, the grey gas's and its soot's, as the volume and the cooling take them;
/// - what the gas has lost to radiation (`BlastSolver.radiatedEnergy`).
/// The heat released is integrated over the frames by the trapezium rule, and checked against the
/// products the air has burnt over the same time. Only the coarse grid's cells are read.
struct DialPackBudget {
    static let temperatureEdges: [Float] = [800, 1500, 1800, 2200, 2600]
    static let temperatureNames = [
        "below800", "800to1500", "1500to1800", "1800to2200", "2200to2600", "above2600",
    ]
    static let mixtureNames = ["lean", "near", "rich"]
    static var binCount: Int { temperatureNames.count * mixtureNames.count }

    /// One frame's reading.
    struct Reading {
        /// Heat being released, W, in each bin (temperature band major, mixture minor).
        var rates = [Double](repeating: 0, count: DialPackBudget.binCount)
        var luminousMass = 0.0
        var luminousHeat = 0.0
        var luminousFuel = 0.0
        var luminousVolume = 0.0
        var massTemperature = 0.0
        var massT4 = 0.0
        var volumeAbsorption = 0.0
        var fuel = 0.0

        mutating func add(_ other: Reading) {
            for n in rates.indices { rates[n] += other.rates[n] }
            luminousMass += other.luminousMass
            luminousHeat += other.luminousHeat
            luminousFuel += other.luminousFuel
            luminousVolume += other.luminousVolume
            massTemperature += other.massTemperature
            massT4 += other.massT4
            volumeAbsorption += other.volumeAbsorption
            fuel += other.fuel
        }
    }

    let luminousTemperature: Float
    let absorption: Float
    let sootYield: Float
    let burnRate: Double
    let burnEnergy: Double
    let oxygenPerFuel: Float
    let ambientTemperature: Float
    /// Heat released so far in each bin, J.
    var released = [Double](repeating: 0, count: DialPackBudget.binCount)
    var last: (time: Double, rates: [Double])?
    var startFuel: Double?
    /// The budget as it stood at the first frame from 1 s on.
    var atOneSecond: (time: Double, released: [Double], lost: Double, fuel: Double)?
    var lines: [String]

    init(configuration: SolverConfiguration, spec: ThermalSpec, chargeMass: Float, ambientTemperature: Float)
    {
        luminousTemperature = spec.luminousTemperature
        absorption = spec.absorption
        sootYield = spec.sootYield
        // As the solver's uniforms take it (BlastSolver+Stepping, `afterburnRate`).
        burnRate = 1 / max(Double(configuration.afterburnTime) * Double(cbrt(max(chargeMass, 1e-3))), 1e-9)
        burnEnergy = Double(configuration.afterburnEnergy)
        // As `BlastSolver.oxygenPerFuel`: C7H5N3O6 + 5.25 O2 -> 7 CO2 + 2.5 H2O + 1.5 N2.
        oxygenPerFuel = 5.25 * 32 / 227.13
        self.ambientTemperature = ambientTemperature
        let bins = Self.temperatureNames.flatMap { t in Self.mixtureNames.map { "released_\(t)_\($0)_J" } }
        lines = [
            ([
                "time_s", "gas_lost_J", "fuel_kg", "released_J", "release_W", "luminous_kg", "luminous_K",
                "luminous_T4_K", "luminous_fuel_kg", "luminous_m3", "luminous_heat_J",
                "luminous_absorption_per_m",
            ] + bins).joined(separator: ",")
        ]
    }

    /// The bin of a cell at `temperature` holding products and oxygen at densities `species`.
    static func bin(temperature: Float, species: SIMD2<Float>, oxygenPerFuel: Float) -> Int {
        let band = temperatureEdges.firstIndex { temperature < $0 } ?? temperatureEdges.count
        let ratio = species.y > 0 ? oxygenPerFuel * species.x / species.y : .infinity
        let mixture = ratio < 0.7 ? 0 : (ratio <= 1.4 ? 1 : 2)
        return band * mixtureNames.count + mixture
    }

    func read(_ solver: BlastSolver) -> Reading {
        let grid = solver.grid
        let volume = pow(Double(grid.cellSize), 3)
        let airModel = solver.configuration.airModel
        let gamma = solver.configuration.gamma
        let gasConstant = AirModel.gasConstant
        // The volume's soot: 1817 f T a metre, f = yield x / 1,800 kg/m³.
        let soot = ThermalMedium.sootAbsorption * sootYield / ThermalMedium.sootDensity
        var planes = [Reading](repeating: Reading(), count: grid.nz)
        solver.withState { cells in
            solver.readSpecies { species in
                guard let species else { return }
                planes.withUnsafeMutableBufferPointer { planes in
                    concurrently(iterations: grid.nz) { k in
                        var sums = Reading()
                        for j in 0..<grid.ny {
                            for i in 0..<grid.nx where !solver.isSolid(i, j, k) {
                                let index = grid.index(i, j, k)
                                let air = solver.primitive(of: cells[index])
                                guard air.density > 0, air.pressure > 0, air.pressure.isFinite else {
                                    continue
                                }
                                let temperature = air.pressure / (air.density * gasConstant)
                                let here = species[index]
                                sums.fuel += Double(here.x) * volume
                                let fuel = min(here.x, here.y / oxygenPerFuel)
                                if fuel > 0 {
                                    let bin = Self.bin(
                                        temperature: temperature, species: here, oxygenPerFuel: oxygenPerFuel)
                                    sums.rates[bin] += burnEnergy * burnRate * Double(fuel) * volume
                                }
                                guard temperature >= luminousTemperature else { continue }
                                let mass = Double(air.density) * volume
                                let t = Double(temperature)
                                sums.luminousMass += mass
                                sums.massTemperature += mass * t
                                sums.massT4 += mass * t * t * t * t
                                sums.luminousFuel += Double(here.x) * volume
                                sums.luminousVolume += volume
                                let thermal =
                                    cells[index].energy - 0.5 * air.density
                                    * simd_length_squared(air.velocity)
                                let cold = airModel.internalEnergy(
                                    density: air.density,
                                    pressure: air.density * gasConstant * ambientTemperature,
                                    gamma: gamma)
                                sums.luminousHeat += Double(thermal - cold) * volume
                                sums.volumeAbsorption +=
                                    Double(absorption + soot * here.x * temperature) * volume
                            }
                        }
                        planes[k] = sums
                    }
                }
            }
        }
        // Summed in the planes' order, so that runs repeat exactly.
        var total = Reading()
        for plane in planes { total.add(plane) }
        return total
    }

    mutating func record(_ solver: BlastSolver, at time: Double) {
        let reading = read(solver)
        if let last {
            for n in released.indices {
                released[n] += 0.5 * (last.rates[n] + reading.rates[n]) * (time - last.time)
            }
        }
        last = (time, reading.rates)
        if startFuel == nil { startFuel = reading.fuel }
        if atOneSecond == nil, time >= 1 - 1e-6 {
            atOneSecond = (time, released, solver.radiatedEnergy, reading.fuel)
        }
        let mass = max(reading.luminousMass, 1e-30)
        let values: [Double] = [
            solver.radiatedEnergy, reading.fuel, released.reduce(0, +), reading.rates.reduce(0, +),
            reading.luminousMass,
            reading.massTemperature / mass, pow(reading.massT4 / mass, 0.25), reading.luminousFuel,
            reading.luminousVolume, reading.luminousHeat,
            reading.volumeAbsorption / max(reading.luminousVolume, 1e-30),
        ]
        lines.append(
            ([String(format: "%.5f", time)] + (values + released).map { String(format: "%.5g", $0) }).joined(
                separator: ","))
    }

    /// The budget's summary: what burnt, where and when, against what the gas radiated.
    func summary(charge: Double, endFuel: Double, lost: Double) -> [String] {
        let total = released.reduce(0, +)
        let burnt = ((startFuel ?? endFuel) - endFuel) * burnEnergy
        var text = [
            String(
                format:
                    "  budget: afterburning released %.3g J on the grid (%.1f%% of the charge's energy; the products burnt account for %.3g J, %+.1f%%); the gas lost %.3g J to radiation",
                total, 100 * total / charge, burnt, 100 * (total / max(burnt, 1e-30) - 1), lost)
        ]
        let late: [Double]
        if let atOneSecond {
            late = zip(released, atOneSecond.released).map { $0 - $1 }
            let after = late.reduce(0, +)
            text.append(
                String(
                    format:
                        "  after %.2f s: released %.3g J (%.1f%% of the charge's energy), the gas lost %.3g J (%.1f%%)",
                    atOneSecond.time, after, 100 * after / charge, lost - atOneSecond.lost,
                    100 * (lost - atOneSecond.lost) / charge))
        } else {
            late = released
        }
        text.append(
            "  released, % of the charge's energy, by the cell's temperature (K) and mixture: all / after 1 s"
        )
        text.append(
            "    " + "band".padding(toLength: 12, withPad: " ", startingAt: 0)
                + Self.mixtureNames.map { $0.padding(toLength: 16, withPad: " ", startingAt: 0) }.joined())
        for (b, name) in Self.temperatureNames.enumerated() {
            let cells = Self.mixtureNames.indices.map { m -> String in
                let n = b * Self.mixtureNames.count + m
                return String(format: "%6.2f / %6.2f   ", 100 * released[n] / charge, 100 * late[n] / charge)
            }
            text.append("    " + name.padding(toLength: 12, withPad: " ", startingAt: 0) + cells.joined())
        }
        return text
    }
}
