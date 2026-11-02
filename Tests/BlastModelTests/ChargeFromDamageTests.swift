import Foundation
import Testing
import simd

@testable import BlastModel

/// The charge read back from marked damage (`ChargeFromDamage`, emmettl/bombcad-work#116): the
/// chance tables, their full posterior, drawn cases and the learned network's reading of its weights.
@Suite("The charge from marked damage")
struct ChargeFromDamageTests {
    /// A made-up table: 11 × 11 nodes 100 m apart, 12 yields from 100 kg doubling, 300 buildings out
    /// to 1.5 km, each chance a step in scaled distance from the node (glass broken within 15
    /// m/kg^(1/3), walls moderate within 4, heavy within 3, smoothed).
    static func table(masonry: Bool = false) -> ChargeFromDamage.ChanceTable {
        var random = ChargeFromDamage.SplitMix(seed: 3)
        let buildings = (0..<300).map { _ -> ChargeFromDamage.Building in
            let r = 1500 * random.uniform().squareRoot()
            let a = 2 * Double.pi * random.uniform()
            return ChargeFromDamage.Building(
                east: r * cos(a), north: r * sin(a), heightM: 6 + 20 * random.uniform(),
                footprintM2: 100 + 400 * random.uniform(), builtShare: random.uniform(), walls: .concrete,
                glazed: random.uniform() < 0.9)
        }
        let yields = (0..<12).map { 100 * pow(2.0, Double($0)) }
        let channels = Array(ChargeFromDamage.ChanceTable.channels.prefix(masonry ? 5 : 3))
        var values: [UInt8] = []
        for node in 0..<121 {
            let place = SIMD2(-500 + Double(node % 11) * 100, -500 + Double(node / 11) * 100)
            for mass in yields {
                for b in buildings {
                    let z = simd_distance(SIMD2(b.east, b.north), place) / cbrt(mass)
                    func step(_ limit: Double) -> UInt8 {
                        UInt8((255 / (1 + exp(6 * log(z / limit)))).rounded())
                    }
                    values += [step(15), step(4), step(3)] + (masonry ? [step(5), step(5)] : [])
                }
            }
        }
        let header = ChargeFromDamage.ChanceTable.Header(
            format: ChargeFromDamage.ChanceTable.magic, district: "test", reference: [0, 0],
            origin: [-500, -500],
            spacingM: 100, columns: 11, rows: 11, yieldsKg: yields, channels: channels, buildings: buildings,
            objects: Array(0..<300), draws: 1, cellSizeM: 4, terms: "test", placeRadiusM: 400,
            sceneRadiusM: 1500,
            seconds: 0, firstNode: 0, nodeCount: 121)
        return ChargeFromDamage.ChanceTable(header: header, values: values)
    }

    @Test("A table keeps its chances through a file, joins from parts, and interpolates between nodes")
    func tableFile() throws {
        let table = Self.table(masonry: true)
        let folder = FileManager.default.temporaryDirectory.appending(path: "cfd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try table.write(to: folder.appending(path: "t.bcct"))
        let read = try ChargeFromDamage.ChanceTable(contentsOf: folder.appending(path: "t.bcct"))
        #expect(read.values == table.values)
        #expect(read.header.buildings == table.header.buildings)
        #expect(read.hasMasonry)
        // Two parts joined are the whole.
        let per = table.values.count / 121
        var first = table
        first.header.nodeCount = 60
        first.values = Array(table.values[0..<(60 * per)])
        var second = table
        second.header.firstNode = 60
        second.header.nodeCount = 61
        second.values = Array(table.values[(60 * per)...])
        let joined = try ChargeFromDamage.ChanceTable.merge([second, first])
        #expect(joined.values == table.values)
        // At a node and its yield, the stored chance; halfway, between its neighbours'.
        let node = SIMD2(-500.0 + 300, -500.0 + 200)
        let logMass = log(table.header.yieldsKg[4])
        let at = table.chance(building: 7, channel: 0, place: node, logMass: logMass)
        #expect(abs(at - table.value(node: 2 * 11 + 3, yield: 4, building: 7, channel: 0)) < 1e-12)
        let a = table.chance(building: 7, channel: 0, place: node, logMass: logMass)
        let b = table.chance(building: 7, channel: 0, place: node + SIMD2(100, 0), logMass: logMass)
        let middle = table.chance(building: 7, channel: 0, place: node + SIMD2(50, 0), logMass: logMass)
        #expect(abs(middle - 0.5 * (a + b)) < 1e-12)
    }

    @Test("Only the buildings a table judged as masonry are drawn as masonry")
    func masonrySubset() {
        var table = Self.table(masonry: true)
        table.header.masonryBuildings = Array(0..<150)
        #expect(table.judgesMasonry(3))
        #expect(!table.judgesMasonry(200))
        var random = ChargeFromDamage.SplitMix(seed: 21)
        var seen = 0
        for _ in 0..<40 {
            let drawn = table.drawCase(&random, grid: 12, halfWidthM: 400, placeRadiusM: 400, markCount: 30)
            for m in drawn.marks where m.masonry {
                seen += 1
                #expect(m.building < 150)
            }
        }
        #expect(seen > 0)
    }

    @Test("Each mark's classes' chances sum to one and keep the floor")
    func classes() {
        for p in [0.0, 0.3, 1.0] {
            let g = ChargeFromDamage.glassClasses(broken: p)
            #expect(abs(g.whole + g.broken - 1) < 1e-12)
            #expect(min(g.whole, g.broken) >= 0.02 - 1e-12)
            for h in [0.0, p / 2, p] {
                let w = ChargeFromDamage.wallsClasses(moderate: p, heavy: h)
                #expect(abs(w.undamaged + w.damaged + w.heavy - 1) < 1e-12)
                #expect(min(w.undamaged, w.damaged, w.heavy) >= 0.02 - 1e-12)
            }
        }
    }

    @Test("The full posterior holds the charge that drew the marks, as often as it says")
    func fullPosterior() {
        let table = Self.table()
        var random = ChargeFromDamage.SplitMix(seed: 11)
        var in90 = 0
        var yieldIn90 = 0
        let cases = 12
        for _ in 0..<cases {
            let drawn = table.drawCase(&random, grid: 12, halfWidthM: 400, placeRadiusM: 400, markCount: 30)
            #expect(drawn.marks.count == 30)
            #expect(simd_length(drawn.place) <= 400 + 34)
            let p = table.posterior(marks: drawn.marks, grid: 12, halfWidthM: 400, placeRadiusM: 400, sub: 1)
            #expect(abs(p.cellProbabilities.reduce(0, +) - 1) < 1e-9)
            #expect(abs(p.yieldProbabilities.reduce(0, +) - 1) < 1e-9)
            if p.regionHolds(drawn.place, mass: 0.9) { in90 += 1 }
            let u = p.yieldCDF(exp(drawn.logMass))
            if u >= 0.05, u <= 0.95 { yieldIn90 += 1 }
        }
        #expect(in90 >= 8, "\(in90) of \(cases)")
        #expect(yieldIn90 >= 8, "\(yieldIn90) of \(cases)")
    }

    /// A small network with weights from a seed, each exactly a float16.
    static func network(maxMarks: Int = 64) throws -> (ChargeFromDamage.Network.Header, [Float]) {
        let grid = 6
        var tensors: [ChargeFromDamage.Network.Tensor] = []
        var offset = 0
        func add(_ name: String, _ shape: [Int]) {
            tensors.append(.init(name: name, shape: shape, offset: offset))
            offset += shape.reduce(1, *)
        }
        add("phi.0.weight", [8, 15])
        add("phi.0.bias", [8])
        add("phi.1.weight", [6, 8])
        add("phi.1.bias", [6])
        add("rho.0.weight", [10, 13])
        add("rho.0.bias", [10])
        add("rho.1.weight", [3 * grid * grid, 10])
        add("rho.1.bias", [3 * grid * grid])
        var random = ChargeFromDamage.SplitMix(seed: 5)
        let values = (0..<offset).map { _ in Float(Float16(Float(random.uniform() - 0.5))) }
        let header = ChargeFromDamage.Network.Header(
            format: ChargeFromDamage.Network.magic, name: "test", inputs: 15, phi: [8, 6], rho: [10],
            grid: grid,
            halfWidthM: 300, placeRadiusM: 300, yieldRangeKg: [100, 204_800], logYieldMid: log(4525.5),
            logYieldScale: 3.8, maxMarks: maxMarks, trainedOn: ["test"], source: "test", tensors: tensors,
            references: nil)
        return (header, values)
    }

    @Test("The network reads its file, and its posterior is a distribution over the disc and the yields")
    func network() throws {
        let (header, values) = try Self.network()
        let direct = try ChargeFromDamage.Network(header: header, values: values)
        // The file: magic, length, header, padding, float16 values.
        var data = Data(ChargeFromDamage.Network.magic.utf8)
        let json = try JSONEncoder().encode(header)
        var length = UInt32(json.count).littleEndian
        data.append(Data(bytes: &length, count: 4))
        data.append(json)
        while data.count % 8 != 0 { data.append(0) }
        for v in values {
            var bits = Float16(v).bitPattern.littleEndian
            data.append(Data(bytes: &bits, count: 2))
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "cfd-\(UUID().uuidString).bccd")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let read = try ChargeFromDamage.Network(contentsOf: url)
        let table = Self.table()
        let marks = (0..<5).map {
            table.mark(
                .init(building: $0, masonry: false, glass: .broken, walls: $0 % 2 == 0 ? .damaged : nil))
        }
        let a = direct.outputs(marks: marks, reference: .zero)
        let b = read.outputs(marks: marks, reference: .zero)
        #expect(a.logits == b.logits)
        #expect(a.mu == b.mu)
        let p = read.posterior(marks: marks, reference: .zero)
        #expect(abs(p.cellProbabilities.reduce(0, +) - 1) < 1e-9)
        #expect(abs(p.yieldProbabilities.reduce(0, +) - 1) < 1e-6)
        for c in p.cellProbabilities.indices where !read.inDisc[c] { #expect(p.cellProbabilities[c] == 0) }
        #expect(p.yieldQuantile(0.05) <= p.yieldQuantile(0.5))
        #expect(p.yieldQuantile(0.5) <= p.yieldQuantile(0.95))
        #expect(abs(p.yieldCDF(p.yieldQuantile(0.5)) - 0.5) < 0.02)
        #expect(p.regionRadius(0.5) <= p.regionRadius(0.9))
        // Marks beyond its number are weighed in groups: the same marks twice weigh as one group
        // squared, each cell's weight squared over its log yield's spread (the integral of its
        // normal squared), the spread itself narrowed by √2.
        let (small, _) = try Self.network(maxMarks: 5)
        let grouped = try ChargeFromDamage.Network(header: small, values: values)
        let once = grouped.posterior(marks: marks, reference: .zero)
        let twice = grouped.posterior(marks: marks + marks, reference: .zero)
        let sd = try #require(once.cellLogYieldSD)
        let squared = once.cellProbabilities.indices.map {
            once.cellProbabilities[$0] * once.cellProbabilities[$0] / sd[$0]
        }
        let total = squared.reduce(0, +)
        for c in squared.indices {
            #expect(abs(twice.cellProbabilities[c] - squared[c] / total) < 1e-9)
            if grouped.inDisc[c] { #expect(abs(twice.cellLogYieldSD![c] - sd[c] / 2.0.squareRoot()) < 1e-9) }
        }
    }

    @Test("The summed surfaces weigh each mark as its own evidence, any number of them")
    func surfaces() throws {
        let grid = 6
        var tensors: [ChargeFromDamage.Network.Tensor] = []
        var offset = 0
        for (name, shape) in [
            ("phi.0.weight", [8, 15]), ("phi.0.bias", [8]), ("head.0.weight", [2 * 2 * grid * grid, 8]),
            ("head.0.bias", [2 * 2 * grid * grid]),
        ] {
            tensors.append(.init(name: name, shape: shape, offset: offset))
            offset += shape.reduce(1, *)
        }
        var random = ChargeFromDamage.SplitMix(seed: 9)
        let values = (0..<offset).map { _ in Float(Float16(Float(random.uniform() - 0.5))) }
        var header = try Self.network().0
        header.kind = "surfaces"
        header.phi = [8]
        header.rho = []
        header.surfaces = 2
        header.yieldBins = 10
        header.tensors = tensors
        let network = try ChargeFromDamage.Network(header: header, values: values)
        #expect(network.summed)
        let table = Self.table()
        let marks = (0..<4).map {
            table.mark(.init(building: $0, masonry: false, glass: .whole, walls: .undamaged))
        }
        let once = network.joint(marks: marks, reference: .zero)
        let twice = network.joint(marks: marks + marks, reference: .zero)
        for c in once.indices where once[c].isFinite {
            #expect(abs(twice[c] - 2 * once[c]) < 1e-4 * max(1, abs(once[c])))
        }
        let p = network.posterior(marks: marks + marks + marks, reference: .zero)
        #expect(abs(p.cellProbabilities.reduce(0, +) - 1) < 1e-9)
        #expect(abs(p.yieldProbabilities.reduce(0, +) - 1) < 1e-9)
        #expect(p.logYields.count == 10)
        for c in p.cellProbabilities.indices where !network.inDisc[c] { #expect(p.cellProbabilities[c] == 0) }
    }

    @Test("The distance network weighs a mark by its distance from each cell alone, its marks summed")
    func distance() throws {
        let grid = 6
        var tensors: [ChargeFromDamage.Network.Tensor] = []
        var offset = 0
        for (name, shape) in [
            ("mlp.0.weight", [6, 13]), ("mlp.0.bias", [6]), ("mlp.1.weight", [4, 6]), ("mlp.1.bias", [4]),
        ] {
            tensors.append(.init(name: name, shape: shape, offset: offset))
            offset += shape.reduce(1, *)
        }
        var random = ChargeFromDamage.SplitMix(seed: 13)
        let values = (0..<offset).map { _ in Float(Float16(Float(2 * random.uniform() - 1))) }
        var header = try Self.network().0
        header.kind = "distance"
        header.phi = [6]
        header.rho = []
        header.yieldBins = 8
        header.distanceNodes = 12
        header.distanceRangeM = [1, 8000]
        header.floor = 0.02
        header.tensors = tensors
        let network = try ChargeFromDamage.Network(header: header, values: values)
        #expect(network.summed)
        let building = ChargeFromDamage.Building(
            east: 120, north: 0, heightM: 12, footprintM2: 300, builtShare: 0.4, walls: .concrete,
            glazed: true)
        var turned = building
        turned.east = 0
        turned.north = 120
        let east = network.joint(marks: [.init(building: building, glass: .broken)], reference: .zero)
        let north = network.joint(marks: [.init(building: turned, glass: .broken)], reference: .zero)
        // A quarter turn anticlockwise takes cell (i, j) to (g - 1 - j, i).
        for c in 0..<(grid * grid) where network.inDisc[c] {
            let (i, j) = (c % grid, c / grid)
            let d = i * grid + (grid - 1 - j)
            for k in 0..<8 { #expect(abs(east[c * 8 + k] - north[d * 8 + k]) < 1e-4) }
        }
        let both = network.joint(
            marks: [.init(building: building, glass: .broken), .init(building: turned, glass: .broken)],
            reference: .zero)
        for c in both.indices where both[c].isFinite { #expect(abs(both[c] - east[c] - north[c]) < 1e-4) }
        // The likelihood keeps its floor: no mark can rule a cell out.
        for v in east where v.isFinite { #expect(v >= log(0.02) - 1e-3 && v <= 1e-4) }
        let p = network.posterior(joint: both, reference: .zero)
        #expect(abs(p.cellProbabilities.reduce(0, +) - 1) < 1e-9)
        #expect(abs(p.yieldProbabilities.reduce(0, +) - 1) < 1e-9)
    }

    @Test("A district's buildings: each its middle, height, footprint and the share built round it")
    func buildings() throws {
        let layout = try DistrictLayoutTests.layout()
        let half = layout.halfSide(radius: 250, cellSize: 4)
        let (scene, _) = try layout.scene(halfSide: half, cellSize: 4)
        let buildings = ChargeFromDamage.buildings(scene: scene)
        #expect(buildings.count == scene.envelopeObjects.count)
        #expect(buildings.count > 20)
        for b in buildings {
            #expect(b.heightM > 0)
            #expect(b.footprintM2 >= 4)
            #expect(b.builtShare > 0 && b.builtShare <= 1)
        }
    }

    @Test("The trained network gives PyTorch's outputs on the cases its file carries")
    func againstPyTorch() throws {
        let path =
            ProcessInfo.processInfo.environment["BOMBCAD_CHARGE_MODEL"]
            ?? "/Volumes/StudioData/bombcad/ml/charge-net-2/out/charge-net.bccd"
        guard FileManager.default.fileExists(atPath: path) else { return }
        let network = try ChargeFromDamage.Network(contentsOf: URL(filePath: path))
        let references = try #require(network.header.references)
        #expect(!references.isEmpty)
        for r in references where network.summed {
            let joint = network.joint(marks: r.marks, reference: .zero)
            let bins = network.header.yieldBins ?? 1
            let cells = r.cells ?? Array(0..<(joint.count / bins))
            for (n, c) in cells.enumerated() {
                for k in 0..<bins where joint[c * bins + k].isFinite {
                    let given = r.logits[n * bins + k]
                    #expect(abs(Double(joint[c * bins + k]) - given) < 2e-3 * max(1, abs(given)))
                }
            }
        }
        for r in references where !network.summed {
            let (logits, mu, sigma) = network.outputs(marks: r.marks, reference: .zero)
            for c in logits.indices where logits[c].isFinite {
                #expect(abs(logits[c] - r.logits[c]) < 2e-3)
                #expect(abs(mu[c] - r.mu[c]) < 2e-3)
                #expect(abs(log(sigma[c]) - r.logSigma[c]) < 2e-3)
            }
        }
    }
}
