import BlastModel
import Foundation
import simd

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
        let mask = maskContents.bindMemory(to: UInt8.self, capacity: grid.cellCount)
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
                concurrently(iterations: nz) { k in
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
