import BlastCore
import Foundation
import Metal
import simd

struct EnvelopeReport: Codable {
    var schemaVersion = 1
    var sourceRevision: String
    var device: String
    var system: String
    var completeMatrix: Bool
    var referenceElementKind = "solid"
    var notes = [
        "Stationary conventional exposure study; invented buildings, no measured validation or failure prediction.",
        "Detailed references use 0.5 m solid elements and pin every node. Envelopes retain solids, openings and object IDs.",
        "Shared air, 2 kg TNT equivalent, fixed 1 m source radius. Spatial probes at 0.5 m spacing and 1.5 m height.",
        "Surface loads sample adjacent coarse fluid centres, including restricted fine state; not wall Riemann fluxes.",
        "Faces follow each run's voxel boundary, include interior and exterior, omit domain boundaries; area is dx squared.",
        "Positive and signed surface impulses accumulate every full fluid step with right endpoints.",
        "Force histories sample batch endpoints; integrated loads include every step. Surface pressures are overpressure.",
        "Scaling windows end at 60 ms and need not expose every building. Counts change domain size and air-cell count.",
        "Scaling pairs alternate execution order across three repeats; ordinary replay disables surface recording.",
        "Timings are local observations under background work, not portable performance guarantees.",
    ]
    var observations: [StreetRun]
}

enum EnvelopeBenchmark {
    static func reference(_ layout: StreetInteractionStudy.Layout) throws -> Scenario {
        var scene = try StreetInteractionStudy.make(layout, clamped: true)
        for object in scene.structuralObjects {
            var model = object.structure!
            model.elementKind = .solid
            try scene.updateStructureObject(id: object.id, model: model)
        }
        return scene
    }
    static func approximated(_ scene: Scenario) throws -> Scenario {
        var result = scene
        for object in scene.structuralObjects { try result.useEnvelope(id: object.id) }
        return result
    }

    static func scaled(count: Int, detailed: Bool) throws -> Scenario {
        let template = try reference(.isolated).structuralObjects[0].structure!
        let side = Int(ceil(sqrt(Double(count))))
        let extent = Float(side * 10 + 16)
        var scene = Scenario(
            name: "Scaling \(count) buildings", domainSize: SIMD3(extent, extent, 8),
            boxes: [], charge: Charge(mass: 2, position: SIMD3(4, 4, 1)),
            gauges: [Gauge("Near", at: SIMD3(7, 4, 1.5))])
        for index in 0..<count {
            var model = template
            let offset = SIMD3<Float>(
                10 + Float(index % side) * 10 - 16,
                10 + Float(index / side) * 10 - 6, 0)
            model.solids = model.solids.map { Box(min: $0.min + offset, max: $0.max + offset) }
            model.supports = [Box(min: model.bounds.min - 0.01, max: model.bounds.max + 0.01)]
            let id = UUID(uuidString: String(format: "00000000-0000-4000-8100-%012d", index + 1))!
            // Build as an envelope first so counts above the structural limit are supported.
            if detailed {
                try scene.addStructureObject(model, name: "Building \(index + 1)", id: id)
            } else {
                try scene.addEnvelopeObject(
                    BuildingEnvelope(solids: model.solids, openings: model.openings),
                    name: "Building \(index + 1)", id: id)
            }
        }
        return scene
    }

    static func run(_ args: [String]) throws {
        guard let destination = args.first, !destination.hasPrefix("--"),
            let device = MTLCreateSystemDefaultDevice()
        else { throw BlastError.allocationFailed("envelope output and Metal") }
        let directory = URL(filePath: destination)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let quick = args.contains("--quick")
        var runs: [StreetRun] = []
        func execute(
            _ scene: Scenario, layout: String, setting: StreetBenchmark.Setting,
            id: String, purpose: String, duration: Double, profile: Bool = false,
            observe: Bool = true
        ) throws {
            print("Running \(id)")
            runs.append(
                try StreetBenchmark.execute(
                    device: device, scene: scene, layout: layout,
                    setting: setting, id: id, purpose: purpose, duration: duration,
                    directory: directory, profile: profile, observeEnvelopes: observe))
            try StreetBenchmark.write(runs, to: directory.appending(path: "progress.json"))
        }
        let settings =
            quick
            ? [StreetBenchmark.Setting(name: "medium", dx: 0.5)]
            : [
                StreetBenchmark.Setting(name: "medium", dx: 0.5),
                StreetBenchmark.Setting(name: "fine", dx: 0.25),
                StreetBenchmark.Setting(name: "finest", dx: 0.125),
                StreetBenchmark.Setting(name: "adaptive", dx: 0.5, refinement: 2),
            ]
        for layout in StreetInteractionStudy.Layout.allCases {
            let detailed = try reference(layout)
            let envelope = try approximated(detailed)
            for (mode, scene) in [("detailed", detailed), ("envelope", envelope)] {
                try StreetBenchmark.write(
                    scene, to: directory.appending(path: "\(layout.rawValue)-\(mode)-layout.json"))
                for setting in settings {
                    try execute(
                        scene, layout: layout.rawValue, setting: setting,
                        id: "\(layout.rawValue)-\(mode)-\(setting.name)", purpose: "comparison",
                        duration: quick ? 0.012 : 0.12)
                }
            }
        }
        if !quick {
            // A doorway and roof opening exercise access to the building's interior.
            var opened = try reference(.isolated)
            let owner = opened.structuralObjects[0]
            var model = owner.structure!
            model.openings = [
                Box(min: SIMD3(15.5, 8, 0), max: SIMD3(17, 10, 2.5)),
                Box(min: SIMD3(18, 8, 3.5), max: SIMD3(20, 10, 5)),
            ]
            try opened.updateStructureObject(id: owner.id, model: model)
            for (mode, scene) in [("detailed", opened), ("envelope", try approximated(opened))] {
                try StreetBenchmark.write(scene, to: directory.appending(path: "opened-\(mode)-layout.json"))
                for setting in settings.prefix(2) {
                    try execute(
                        scene, layout: "opened", setting: setting,
                        id: "opened-\(mode)-\(setting.name)", purpose: "openings", duration: 0.12)
                }
                var closed = scene
                closed.reflectiveFaces = .all
                try execute(
                    closed, layout: "opened", setting: settings[0],
                    id: "closed-\(mode)", purpose: "conservation", duration: 0.06)
            }
            let street = try reference(.street)
            for (mode, scene) in [("detailed", street), ("envelope", try approximated(street))] {
                try execute(
                    scene, layout: "street", setting: .init(name: "half-cfl", dx: 0.25, cfl: 0.225),
                    id: "street-\(mode)-half-cfl", purpose: "temporal", duration: 0.12)
                try execute(
                    scene, layout: "street", setting: settings[1],
                    id: "profiled-\(mode)", purpose: "profile", duration: 0.12, profile: true)
                try execute(
                    scene, layout: "street", setting: settings[1],
                    id: "ordinary-\(mode)", purpose: "recorder-control", duration: 0.12, observe: false)
            }
            for count in [1, 4, 16, 64] {
                for repeatIndex in 0..<3 {
                    let modes =
                        count > Scenario.maximumStructures
                        ? ["envelope"]
                        : repeatIndex.isMultiple(of: 2)
                            ? ["detailed", "envelope"] : ["envelope", "detailed"]
                    for mode in modes {
                        let scene = try scaled(count: count, detailed: mode == "detailed")
                        if repeatIndex == 0 {
                            try StreetBenchmark.write(
                                scene, to: directory.appending(path: "scaling-\(count)-\(mode)-layout.json"))
                        }
                        try execute(
                            scene, layout: "scaling-\(count)", setting: settings[0],
                            id: "scaling-\(count)-\(mode)-\(repeatIndex)", purpose: "scaling", duration: 0.06,
                            observe: false)
                    }
                }
            }
        }
        try StreetBenchmark.write(
            EnvelopeReport(
                sourceRevision: args.first { $0.hasPrefix("--source-revision=") }
                    .map { String($0.dropFirst(18)) } ?? "working-tree", device: device.name,
                system: ProcessInfo.processInfo.operatingSystemVersionString, completeMatrix: !quick,
                observations: runs), to: directory.appending(path: "report.json"))
        try FileManager.default.removeItem(at: directory.appending(path: "progress.json"))
    }
}
