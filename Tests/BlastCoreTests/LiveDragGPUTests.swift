import Foundation
import Metal
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

/// The live drag's GPU work (emmettl/bombcad-work#112; LiveDrag.metal) against the CPU's reference
/// (`LiveResponse.CPUEngine`): each chosen component's features and loads, and the learned response's
/// dense layers.
@Suite("Live drag on the GPU", .serialized)
struct LiveDragGPUTests {
    static var available: Bool { MTLCreateSystemDefaultDevice() != nil }

    /// A street of map-like buildings, with terrain, a block in the way and outlines turned off the
    /// grid, so that the sight lines cross buildings, ridges and canyons.
    static func district() throws -> Scenario {
        var scene = Scenario(
            name: "Street", domainSize: SIMD3(240, 160, 40),
            boxes: [Box(min: SIMD3(60, 70, 0), max: SIMD3(64, 90, 6))],
            charge: Charge(mass: 500, position: SIMD3(20, 80, 1)))
        var heights: [Float] = []
        for j in 0..<41 {
            for i in 0..<61 { heights.append(0.5 + 0.02 * Float(i) + 0.3 * sin(Float(j) / 6)) }
        }
        scene.terrain = Terrain(origin: .zero, spacing: 4, columns: 61, rows: 41, heights: heights)
        for (n, x) in [Float(40), 80, 120, 160, 200].enumerated() {
            for y: Float in [40, 100] {
                let height: Float = 9 + 3 * Float(n % 3)
                let id = try scene.addEnvelopeObject(
                    BuildingEnvelope(solids: [Box(min: SIMD3(x, y, 0), max: SIMD3(x + 24, y + 20, height))]),
                    name: "B\(n)-\(Int(y))")
                var construction = EnvelopeConstruction(objectID: id, source: .user, detail: "glazed block")
                construction.glazing = n % 2 == 0 ? .apartments : .commercial
                scene.setEnvelopeConstruction(construction)
            }
        }
        return scene
    }

    @Test("Each item's features and loads, as the CPU's to float rounding", .enabled(if: available))
    func loads() throws {
        let scene = try Self.district()
        let prepared = FacadeLoadSurrogate.Prepared(scene: scene, cellSize: 2)
        let gpu = try LiveDragGPU(weights: nil)
        let cpu = LiveResponse.CPUEngine(weights: nil)
        for place in [scene.charge.position, SIMD3<Float>(100, 80, 1.5), SIMD3<Float>(230, 20, 1)] {
            let (request, _, _) = prepared.liveRequest(charge: place, mass: 500)
            #expect(request.count >= 30, "\(request.count) items")
            let a = try gpu.loads(request)
            let b = try cpu.loads(request)
            #expect(a.count == b.count)
            var crossings = 0
            for item in 0..<request.count {
                let o = item * LiveResponse.itemWidth
                func close(_ k: Int, _ tolerance: Float) -> Bool {
                    abs(a[o + k] - b[o + k]) <= tolerance * max(1, abs(b[o + k]))
                }
                // A line passing a cell's edge may cross a block more or fewer, and its loads with it.
                if a[o + 2] != b[o + 2] || !close(3, 1e-3) {
                    crossings += 1
                    continue
                }
                #expect(close(0, 1e-5), "distance, item \(item)")
                #expect(close(1, 1e-5), "cosine, item \(item)")
                for k in [4, 5, 6, 8, 16, 17] { #expect(close(k, 1e-3), "feature \(k), item \(item)") }
                for k in 18..<25 {
                    #expect(close(k, 1e-3), "load \(k - 18), item \(item): \(a[o + k]) \(b[o + k])")
                }
            }
            #expect(crossings <= request.count / 50)
        }
    }

    @Test(
        "A barrier wall's own shelter on the GPU as on the CPU, and lower behind it", .enabled(if: available))
    func barrierShelter() throws {
        // The street's block in the way stands for a barrier wall: one of the scene's fixed blocks.
        let scene = try Self.district()
        let prepared = FacadeLoadSurrogate.Prepared(scene: scene, cellSize: 2)
        let gpu = try LiveDragGPU(weights: nil)
        let cpu = LiveResponse.CPUEngine(weights: nil)
        let (request, _, _) = prepared.liveRequest(
            charge: scene.charge.position, mass: 500, coefficients: .deepCityOutlineBarriers)
        let (plain, _, _) = prepared.liveRequest(
            charge: scene.charge.position, mass: 500, coefficients: .deepCityOutline)
        let (a, b, open) = (try gpu.loads(request), try cpu.loads(request), try gpu.loads(plain))
        var lowered = 0
        for item in 0..<request.count {
            let o = item * LiveResponse.itemWidth
            // A line crossing one block more or fewer is let off, as in `loads`.
            guard a[o + 2] == b[o + 2], abs(a[o + 3] - b[o + 3]) <= 1e-3 * max(1, abs(b[o + 3])) else {
                continue
            }
            for k in 18..<20 {
                #expect(
                    abs(a[o + k] - b[o + k]) <= 1e-3 * max(1, abs(b[o + k])), "load \(k - 18), item \(item)")
            }
            #expect(a[o + 18] <= open[o + 18] * 1.0001)
            if a[o + 18] < 0.999 * open[o + 18] { lowered += 1 }
        }
        #expect(lowered > 0)
    }

    @Test("The networks' layers on the GPU as on the CPU", .enabled(if: available))
    func layers() throws {
        let scene = try Self.district()
        var data = Data("BCLR".utf8)
        // One network of each kind, of the widths the scene's rows take, from made-up weights.
        let prepared = FacadeLoadSurrogate.Prepared(scene: scene, cellSize: 2)

        let widths = [
            "component": 3 + LiveResponse.constructionWidth + LiveResponse.shapeWidth,
            "side": 9 * LiveResponse.sideStrips + 5 + LiveResponse.glazingWidth,
            "building": LiveResponse.slotWidth * (LiveResponse.buildingWalls + 1) + 1
                + LiveResponse.constructionWidth,
        ]
        let outputs = ["component": 6, "side": 5, "building": 3]
        var values: [Float] = []
        var networks: [String: LiveResponse.Weights.Network] = [:]
        var state: UInt64 = 3
        for name in ["component", "side", "building"] {
            let sizes = [widths[name]!, 32, 16, outputs[name]!]
            var layers: [LiveResponse.Weights.Layer] = []
            for (a, b) in zip(sizes.dropLast(), sizes.dropFirst()) {
                layers.append(.init(inputs: a, outputs: b, offset: values.count))
                values += (0..<(a * b + b)).map { _ in
                    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    return Float(Int64(bitPattern: state >> 11) % 2000) / 8000
                }
            }
            networks[name] = .init(
                inputs: sizes[0], mean: (0..<sizes[0]).map { Double($0 % 3) * 0.1 },
                std: (0..<sizes[0]).map { 1 + Double($0 % 5) * 0.2 }, layers: layers, outputs: [])
        }
        let header = LiveResponse.Weights.Header(
            format: "bclr", version: 2, constructionWidth: LiveResponse.constructionWidth,
            glazingWidth: LiveResponse.glazingWidth,
            slopeStep: LiveResponse.slopeStep,
            sideStrips: LiveResponse.sideStrips, buildingWalls: LiveResponse.buildingWalls, networks: networks
        )
        let text = try JSONEncoder().encode(header)
        for word in [UInt32(2), UInt32(text.count)] {
            withUnsafeBytes(of: word.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(text)
        values.withUnsafeBytes { data.append(contentsOf: $0) }
        let weights = try LiveResponse.Weights(data: data)
        let gpu = try LiveDragGPU(weights: weights)
        for name in ["component", "side", "building"] {
            let width = widths[name]!
            let count = 300
            let rows = (0..<(count * width)).map { Float(($0 * 7919) % 1000) / 250 - 2 }
            let a = try gpu.run(name, rows: rows, count: count)
            let b = weights.run(name, rows: rows, count: count)
            #expect(a.count == b.count)
            #expect(zip(a, b).allSatisfy { abs($0 - $1) <= 1e-4 * max(1, abs($1)) })
        }

        // And a whole live look on the GPU as on the CPU, the same components judged.
        let model = LiveResponse.Model(weights: weights, engine: gpu)
        let reference = LiveResponse.Model(weights: weights, engine: LiveResponse.CPUEngine(weights: weights))
        let uncertainty = FacadeLoadSurrogate.Uncertainty(yieldLogSD: log(1.5) / 1.645)
        let (onGPU, _) = try #require(
            try prepared.livePreview(
                charge: scene.charge.position, mass: 500, uncertainty: uncertainty, model: model))
        let (onCPU, _) = try #require(
            try prepared.livePreview(
                charge: scene.charge.position, mass: 500, uncertainty: uncertainty, model: reference))
        #expect(onGPU.learnedResponse == "GPU")
        #expect(onGPU.estimate.components.map(\.id) == onCPU.estimate.components.map(\.id))
        #expect(onGPU.glass.map(\.owner) == onCPU.glass.map(\.owner))
        let close = zip(onGPU.glass, onCPU.glass).filter { abs($0.blownOut - $1.blownOut) <= 0.02 }.count
        #expect(close >= onCPU.glass.count * 9 / 10)
    }
}
