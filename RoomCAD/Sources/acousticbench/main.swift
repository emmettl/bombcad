import AcousticCore
import Foundation
import ImpulseResponseKit

// Renders RoomCAD's reference room, checks the image-source renderer against analytical results and
// exports stereo 32-bit float WAV files for auditioning in a convolution engine.
//
//   acousticbench [--out DIRECTORY]

let arguments = CommandLine.arguments
var outputDirectory = URL(fileURLWithPath: "roomcad-reference")
if let flag = arguments.firstIndex(of: "--out"), flag + 1 < arguments.count {
    outputDirectory = URL(fileURLWithPath: arguments[flag + 1])
}

func format(_ value: Double?, _ digits: Int = 3) -> String {
    guard let value else { return "—" }
    return String(format: "%.\(digits)f", value)
}

/// Index of the largest absolute sample.
func peakIndex(_ samples: [Float]) -> Int {
    samples.indices.max { abs(samples[$0]) < abs(samples[$1]) } ?? 0
}

let source = RoomPoint(name: "Source", position: [2.1, 2.7, 1.4])
let left = RoomPoint(name: "Left", position: [5.6, 3.4, 1.2])
let right = RoomPoint(name: "Right", position: [5.8, 2.6, 1.2])
let size: SIMD3<Double> = [8, 6, 3]
let fs = 48_000

do {
    // 1. Arrival timing: one reflecting surface at a time, so each response holds one reflection.
    print("Arrival timing (rendered peak against path length / sound speed)")
    var worst = 0.0
    var direct = RoomResponseSettings(
        room: ShoeboxRoom(size: size, material: .anechoic), source: source, receivers: [left],
        airAbsorption: false, duration: 0.1, maximumReflectionOrder: 0)
    let directResponse = try RoomResponseGenerator.generate(direct)
    let expectedDirect = directResponse.diagnostics.directDelay[0] * Double(fs)
    let directError = Double(peakIndex(directResponse.response.channels[0])) - expectedDirect
    worst = max(worst, abs(directError))
    print("  direct    expected \(format(expectedDirect, 2)) samples, error \(format(directError, 2))")
    for surface in Surface.allCases {
        var room = ShoeboxRoom(size: size, material: .anechoic)
        room[surface] = .rigid
        direct.room = room
        direct.maximumReflectionOrder = 1
        direct.content = .reflectionsOnly
        let model = ImageSourceModel(
            room: room, source: source.position, atmosphere: .standard, airAbsorption: false)
        var expected = 0.0
        model.forEachArrival(at: left.position, duration: 0.1, maximumOrder: 1, includeDirect: false) {
            delay, _, _ in expected = delay * Double(fs)
        }
        let rendered = try RoomResponseGenerator.generate(direct).response.channels[0]
        let error = Double(peakIndex(rendered)) - expected
        worst = max(worst, abs(error))
        print(
            "  \(surface.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)) expected "
                + "\(format(expected, 2)) samples, error \(format(error, 2))")
    }
    print("  worst error \(format(worst, 2)) samples (target: within one sample)\n")

    // 2. Anechoic distance scaling and absence of a tail, without and with the 20 Hz cutoff, whose
    // removal of sub-audio content spreads a little energy around each arrival.
    print("Anechoic room: energy against 1/r² and fraction of energy more than 1 ms after the arrival")
    let distances = [0.5, 1.0, 2.0, 4.0]
    let receivers = distances.map { RoomPoint(name: "\($0) m", position: [1 + $0, 3, 1.5]) }
    for cutoff in [0.0, 20.0] {
        let anechoic = try RoomResponseGenerator.generate(
            RoomResponseSettings(
                room: ShoeboxRoom(size: size, material: .anechoic),
                source: RoomPoint(name: "S", position: [1, 3, 1.5]), receivers: receivers,
                airAbsorption: false,
                duration: 0.1, lowFrequencyCutoff: cutoff))
        let energies = anechoic.response.channels.map { $0.reduce(0) { $0 + Double($1) * Double($1) } }
        print(cutoff == 0 ? "  raw model" : "  with the \(Int(cutoff)) Hz cutoff")
        for (i, r) in distances.enumerated() {
            let samples = anechoic.response.channels[i]
            let arrival = Int((anechoic.diagnostics.directDelay[i] * Double(fs)).rounded())
            let late = samples[min(samples.count, arrival + fs / 1000)...].reduce(0) {
                $0 + Double($1) * Double($1)
            }
            print(
                "    \(format(r, 1)) m: energy × r² relative to 1 m \(format(energies[i] * r * r / energies[1], 4)), "
                    + "late \(String(format: "%.1e", late / energies[i]))")
        }
    }
    print("")

    // 3. Reference room, without and with scattering.
    let specularMaterial = SurfaceMaterial.uniform(0.2, name: "Uniform 0.2", reference: "Illustrative")
    var scatteringMaterial = specularMaterial
    scatteringMaterial.scattering = [0.1, 0.15, 0.2, 0.3, 0.4, 0.5, 0.6, 0.6]
    var settings = RoomResponseSettings(
        room: ShoeboxRoom(size: size, material: specularMaterial), source: source, receivers: [left, right],
        duration: 1.5, maximumReflectionOrder: 250)
    let specular = try RoomResponseGenerator.generate(settings)
    settings.room = ShoeboxRoom(size: size, material: scatteringMaterial)
    let complete = try RoomResponseGenerator.generate(settings)
    settings.content = .reflectionsOnly
    let reflections = try RoomResponseGenerator.generate(settings)
    let d = complete.diagnostics
    print("Reference room 8 × 6 × 3 m, alpha 0.2 everywhere, air at 20 °C and 50% RH, 1.5 s")
    print("  specular only: generated in \(format(specular.diagnostics.generationSeconds, 2)) s")
    print(
        "  with scattering 0.1 (63 Hz) rising to 0.6 (4–8 kHz): generated in \(format(d.generationSeconds, 2)) s, "
            + "\(d.diffuseRays ?? 0) rays, scattered energy \((d.scatteredFraction ?? []).map { format($0, 2) })"
    )
    print("  order limit reached after \(d.orderLimitedAfter.map { format($0) })")
    print("  Schroeder frequency \(format(d.schroederFrequency, 0)) Hz")
    print("  band (Hz)  Sabine T  Eyring T  T30 specular  T30 scattering (left, right)")
    func t30(_ result: RoomResponse, _ band: Int) -> [String] {
        result.response.channels.map {
            format(
                DecayAnalysis.reverberationTime(
                    DecayAnalysis.octaveBand($0, sampleRate: fs, band: band), sampleRate: fs), 2)
        }
    }
    for (b, centre) in OctaveBands.nominalCentres.enumerated() {
        print(
            "  \(String(centre).padding(toLength: 9, withPad: " ", startingAt: 0))  "
                + "\(format(d.sabineReverberationTime[b], 2)) s    \(format(d.eyringReverberationTime[b], 2)) s    "
                + "\(t30(specular, b).joined(separator: ", ")) s    \(t30(complete, b).joined(separator: ", ")) s"
        )
    }

    // 4. Export, with one common gain and a short fade so the files are ready to audition.
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    for (name, result) in [("reference-complete", complete), ("reference-reflections", reflections)] {
        var conditioned = result
        try conditioned.response.normalizePeak(to: 0.5)
        try conditioned.response.fadeOut(seconds: 0.01)
        let url = outputDirectory.appendingPathComponent("\(name).wav")
        try conditioned.write(wav: url)
        print("  wrote \(url.path)")
    }
} catch {
    FileHandle.standardError.write(Data("acousticbench: \(error.localizedDescription)\n".utf8))
    exit(1)
}
