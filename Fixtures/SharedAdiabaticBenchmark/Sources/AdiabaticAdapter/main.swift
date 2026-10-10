import BenchmarkSupport
import simd

// SourceTransport.swift is copied from the current production reference when the script runs.
try AdiabaticCommand.run(
    model: "BombCAD.SharedPrescribedGasTransport+frozen-pressure-work",
    refinementMetric: "pressure", expectedOrder: 0.85...1.15
) { specification, steps in
    guard specification.heatCapacityRatio == 1.4 else {
        throw BenchmarkFailure.unsupported("FractionalGasTransport validates pressure with gamma 1.4")
    }
    var cells = [
        FractionalGasTransport.Cell(
            volume: specification.initialVolumeM3,
            density: 1.225, pressure: specification.initialPressurePa)
    ]
    var workByGas = 0.0
    var samples: [AdiabaticSample] = []
    for index in 0...steps {
        let fraction = Double(index) / Double(steps)
        if index > 0 {
            let nextVolume = specification.volume(atFraction: fraction)
            let gasWork = cells[0].pressure() * (cells[0].volume - nextVolume)
            workByGas -= gasWork
            cells = try FractionalGasTransport.advance(
                cells, newVolumes: [nextVolume], transfers: [],
                walls: [.init(cell: 0, impulse: .zero, gasWork: gasWork)])
        }
        let cell = cells[0]
        samples.append(
            AdiabaticSample(
                timeS: specification.durationS * fraction, volumeM3: cell.volume,
                energyJ: cell.amount[4], pressurePa: cell.pressure(), workByReservoirJ: workByGas,
                massKg: cell.amount[0]))
    }
    return samples
}
