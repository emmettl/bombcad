import Foundation
import simd

/// Reinforcement read from IFC, and how it becomes the structure's reinforcement (`IFCStructure`).
///
/// An IFC can carry reinforcement two ways:
/// - as elements: reinforcing bars, meshes and tendons (`IfcReinforcingBar`, `IfcReinforcingMesh`,
///   `IfcTendon`), each a swept solid along its path, with its diameter, area and role on it or
///   on its type. Each converted bar is measured from its own geometry (`Bar.init(globalID:
///   triangles:)`) and hosted by the concrete element it lies in (`host`).
/// - as properties of a concrete element: its cover, and its steel as a ratio of area or of mass to
///   the concrete's (`Pset_ConcreteElementGeneral` and the like).
///
/// A member with bars takes them; one with only properties takes a ratio from them; one with
/// neither takes the stated default (`IFCStructure.Options.reinforcement`), flagged.
public enum IFCReinforcement {
    /// One reinforcing bar, mesh or tendon as converted, in the building's coordinates (metres).
    public struct Bar: Sendable, Hashable, Codable {
        public enum Kind: String, Sendable, Hashable, Codable {
            case bar, mesh, tendon
        }

        public var globalID: String
        public var kind: Kind
        /// Its role as the IFC gives it (MAIN, SHEAR, LIGATURE, …), if it does.
        public var role: String?
        /// Its diameter and steel area (m, m²), and where they came from.
        public var diameter: Float
        public var area: Float
        public var sizeSource: String
        /// The bar's length along its path (m), the middle of its points and the direction they
        /// spread along most (a unit vector).
        public var length: Float
        public var centre: SIMD3<Float>
        public var axis: SIMD3<Float>
        /// Its points' bounds.
        public var low: SIMD3<Float>
        public var high: SIMD3<Float>
        /// Straight: its points spread along `axis` over at least nine tenths of its length.
        public var straight: Bool

        public init(
            globalID: String, kind: Kind = .bar, role: String? = nil, diameter: Float, area: Float? = nil,
            sizeSource: String, length: Float, centre: SIMD3<Float>, axis: SIMD3<Float>, low: SIMD3<Float>,
            high: SIMD3<Float>, straight: Bool
        ) {
            self.globalID = globalID
            self.kind = kind
            self.role = role
            self.diameter = diameter
            self.area = area ?? .pi * diameter * diameter / 4
            self.sizeSource = sizeSource
            self.length = length
            self.centre = centre
            self.axis = axis
            self.low = low
            self.high = high
            self.straight = straight
        }

        /// A straight bar from `start` to `end`.
        public init(
            globalID: String, kind: Kind = .bar, role: String? = nil, from start: SIMD3<Float>,
            to end: SIMD3<Float>, diameter: Float, sizeSource: String = "given"
        ) {
            let length = simd_distance(start, end)
            self.init(
                globalID: globalID, kind: kind, role: role, diameter: diameter, sizeSource: sizeSource,
                length: length, centre: 0.5 * (start + end),
                axis: length > 0 ? (end - start) / length : SIMD3(1, 0, 0),
                low: simd_min(start, end), high: simd_max(start, end), straight: true)
        }

        /// A bar measured from its converted surface: a tube of diameter d and length L has volume
        /// V = πd²L/4 and side S = πdL, so d = 4V/S and L = S/(πd) whatever its path. Its axis is the
        /// direction its points spread along most. Nil for a surface with no volume.
        public init?(
            globalID: String, kind: Kind = .bar, role: String? = nil, triangles: [ImportedMesh.Triangle]
        ) {
            var volume: Float = 0
            var surface: Float = 0
            var centroid = SIMD3<Float>.zero
            for t in triangles {
                let normal = simd_cross(t.b - t.a, t.c - t.a)
                let area = 0.5 * simd_length(normal)
                surface += area
                centroid += area * (t.a + t.b + t.c) / 3
                volume += simd_dot(t.a, simd_cross(t.b, t.c)) / 6
            }
            volume = abs(volume)
            guard surface > 0, volume > 0 else { return nil }
            centroid /= surface
            let diameter = 4 * volume / surface
            let length = surface / (.pi * diameter)
            // The spread of the surface about its middle; its largest eigenvector by power iteration.
            var spread = simd_float3x3()
            var low = SIMD3<Float>(repeating: .infinity)
            var high = SIMD3<Float>(repeating: -.infinity)
            for t in triangles {
                let weight = 0.5 * simd_length(simd_cross(t.b - t.a, t.c - t.a)) / 3
                for p in [t.a, t.b, t.c] {
                    let d = p - centroid
                    spread += weight * simd_float3x3(columns: (d * d.x, d * d.y, d * d.z))
                    low = simd_min(low, p)
                    high = simd_max(high, p)
                }
            }
            var axis = SIMD3<Float>(0.577, 0.577, 0.577)
            for _ in 0..<64 {
                let next = spread * axis
                guard simd_length(next) > 0 else { break }
                axis = simd_normalize(next)
            }
            let extent = (high - low)
            let along = simd_dot(simd_abs(axis), extent)
            self.init(
                globalID: globalID, kind: kind, role: role, diameter: diameter,
                sizeSource: "measured from its shape",
                length: length, centre: centroid, axis: axis, low: low, high: high,
                straight: along >= 0.9 * length && along <= 1.1 * length + diameter)
        }

        /// Takes the IFC's own diameter and area, where it gives them, over the measured ones.
        public mutating func size(diameter: Float?, area: Float?, source: String) {
            guard let diameter, diameter > 0 else {
                if let area, area > 0 {
                    self.area = area
                    self.diameter = (4 * area / .pi).squareRoot()
                    sizeSource = source
                }
                return
            }
            // The measured length came from the measured diameter; the side is what was measured.
            length *= self.diameter / diameter
            self.diameter = diameter
            self.area = area.flatMap { $0 > 0 ? $0 : nil } ?? .pi * diameter * diameter / 4
            sizeSource = source
        }

        /// The steel's volume (m³).
        public var volume: Float { area * length }
    }

    /// A concrete element's reinforcement as its properties give it.
    public struct Properties: Sendable, Hashable, Codable {
        /// Cover to the bars' surface (m).
        public var cover: Float?
        /// Steel area over concrete area.
        public var areaRatio: Float?
        /// Steel mass over concrete volume (kg/m³).
        public var massRatio: Float?
        /// The property sets they came from.
        public var source: String

        public init(cover: Float? = nil, areaRatio: Float? = nil, massRatio: Float? = nil, source: String) {
            self.cover = cover
            self.areaRatio = areaRatio
            self.massRatio = massRatio
            self.source = source
        }

        /// The steel's volume over the concrete's, from the area ratio or else the mass ratio (at
        /// 7,850 kg/m³ of steel).
        public var ratio: Float? {
            if let areaRatio, areaRatio > 0 { return areaRatio }
            if let massRatio, massRatio > 0 { return massRatio / 7850 }
            return nil
        }
    }

    /// What an element of the IFC carries.
    public struct Hosted: Sendable, Hashable, Codable {
        public var bars: [Bar]
        public var properties: Properties?
        public init(bars: [Bar] = [], properties: Properties? = nil) {
            self.bars = bars
            self.properties = properties
        }
    }

    /// Bars given to the elements that hold them: the element the IFC nests a bar in, where it
    /// does (`hosts`, by the bar's GlobalId) and that element is among `elements` (or one of its
    /// parts is, the one holding the bar's middle where any does); else the
    /// concrete element whose bounds hold the bar's middle, the smallest if several do; else the
    /// one whose bounds overlap most of the bar's (a U-bar's middle lies in the open part of the
    /// U), at least half. Bars no element holds are returned apart.
    public static func host(
        _ bars: [Bar], in elements: [ImportedMesh.BuildingElement], hosts: [String: String] = [:]
    ) -> (elements: [ImportedMesh.BuildingElement], unhosted: [Bar]) {
        var result = elements
        let boxes = elements.map { element -> (low: SIMD3<Float>, high: SIMD3<Float>) in
            let points = element.mesh.triangles.flatMap { [$0.a, $0.b, $0.c] }
            return (
                points.reduce(SIMD3(repeating: .infinity), simd_min),
                points.reduce(SIMD3(repeating: -.infinity), simd_max)
            )
        }
        let concrete = elements.indices.filter { index in
            let layers = elements[index].materials ?? []
            return layers.isEmpty || layers.contains { IFCStructure.classify($0.name) == .concrete }
        }
        var unhosted: [Bar] = []
        for bar in bars {
            var index = hosts[bar.globalID].flatMap { id in
                elements.firstIndex { $0.globalID == id }
                    ?? {
                        let parts = elements.indices.filter { elements[$0].assembly?.id == id }
                        return parts.first { n in
                            all(bar.centre .>= boxes[n].low - 1e-3)
                                && all(bar.centre .<= boxes[n].high + 1e-3)
                        } ?? parts.first
                    }()
            }
            if index == nil {
                let tolerance: Float = 1e-3
                index = concrete.filter { n in
                    all(bar.centre .>= boxes[n].low - tolerance)
                        && all(bar.centre .<= boxes[n].high + tolerance)
                }
                .min { n, m in
                    let a = boxes[n].high - boxes[n].low
                    let b = boxes[m].high - boxes[m].low
                    return a.x * a.y * a.z < b.x * b.y * b.z
                }
            }
            if index == nil {
                // The share of the bar's bounds (grown by its radius, as a flat bar's are thin)
                // inside each element's.
                let low = bar.low - bar.diameter / 2
                let high = bar.high + bar.diameter / 2
                let own = (high - low).x * (high - low).y * (high - low).z
                func share(_ n: Int) -> Float {
                    let overlap = simd_max(simd_min(high, boxes[n].high) - simd_max(low, boxes[n].low), .zero)
                    return own > 0 ? overlap.x * overlap.y * overlap.z / own : 0
                }
                index = concrete.filter { share($0) >= 0.5 }.max { share($0) < share($1) }
            }
            guard let index else {
                unhosted.append(bar)
                continue
            }
            var hosted = result[index].reinforcement ?? Hosted()
            hosted.bars.append(bar)
            result[index].reinforcement = hosted
        }
        return (result, unhosted)
    }

    /// The mats a shell's bars make: for each face, the steel per metre of width in each of the
    /// shell's two directions and the depth of its bars' centres from that face, the mean
    /// weighted by steel. Bars are counted by their volume over the shell's face, so that a bar
    /// shorter than the wall counts for its share; through-thickness bars (links) are left out.
    struct ShellMats {
        /// Per face (low, high), per in-plane axis: steel per metre (m²/m) and its depth (m).
        var areas: [[Float]] = [[0, 0, 0], [0, 0, 0]]
        var depths: [Float] = [0, 0]
        var steel: [Float] = [0, 0]
        var links = 0
        var bars = 0
    }

    static func shellMats(_ bars: [Bar], box: Box, axis k: Int, transform: (SIMD3<Float>) -> SIMD3<Float>)
        -> ShellMats
    {
        var mats = ShellMats()
        let (first, second) = ((k + 1) % 3, (k + 2) % 3)
        let face = box.size[first] * box.size[second]
        let thickness = box.size[k]
        guard face > 0, thickness > 0 else { return mats }
        let mid = 0.5 * (box.min[k] + box.max[k])
        for bar in bars {
            let centre = transform(bar.centre)
            let axis = simd_abs(transform(bar.centre + bar.axis) - centre)
            guard axis[k] < 0.5 else {
                mats.links += 1
                continue
            }
            let along = axis[first] >= axis[second] ? first : second
            let side = centre[k] < mid ? 0 : 1
            let depth = side == 0 ? centre[k] - box.min[k] : box.max[k] - centre[k]
            let clamped = min(max(depth, 0.5 * bar.diameter), 0.5 * thickness)
            let perMetre = bar.volume / face
            mats.areas[side][along] += perMetre
            mats.depths[side] += perMetre * clamped
            mats.steel[side] += perMetre
            mats.bars += 1
        }
        for side in 0..<2 where mats.steel[side] > 0 { mats.depths[side] /= mats.steel[side] }
        return mats
    }

    /// The longitudinal bars and ties a beam's bars make. Longitudinal bars (straight, along the
    /// beam) are merged into at most eight (the beam's limit), each at the steel-weighted middle
    /// of those nearest one of the section's corners or the middles of its sides; the rest are
    /// ties, as a ratio of their volume to the beam's.
    struct BeamBars {
        /// Position in the section (m, from its centre) and area (m²).
        var bars: [(position: SIMD2<Float>, area: Float)] = []
        var tieRatio: Float = 0
        var longitudinal = 0
        var ties = 0
    }

    static func beamBars(_ bars: [Bar], box: Box, axis k: Int, transform: (SIMD3<Float>) -> SIMD3<Float>)
        -> BeamBars
    {
        var result = BeamBars()
        let (first, second) = ((k + 1) % 3, (k + 2) % 3)
        let section = SIMD2(box.size[first], box.size[second])
        let middle = SIMD2(0.5 * (box.min[first] + box.max[first]), 0.5 * (box.min[second] + box.max[second]))
        let volume = box.size.x * box.size.y * box.size.z
        guard volume > 0 else { return result }
        // Corners and the middles of the sides, in units of the half section.
        let anchors: [SIMD2<Float>] = [
            SIMD2(-1, -1), SIMD2(1, -1), SIMD2(-1, 1), SIMD2(1, 1), SIMD2(0, -1), SIMD2(0, 1), SIMD2(-1, 0),
            SIMD2(1, 0),
        ]
        var sums = [(moment: SIMD2<Float>, area: Float)](repeating: (.zero, 0), count: anchors.count)
        var tieVolume: Float = 0
        for bar in bars {
            let centre = transform(bar.centre)
            let axis = simd_abs(transform(bar.centre + bar.axis) - centre)
            if bar.straight && axis[k] > 0.9 {
                // Its steel over the beam's length: a bar shorter than the beam counts for its share.
                let area = bar.volume / box.size[k]
                let position = SIMD2(centre[first], centre[second]) - middle
                let unit = 2 * position / section
                let nearest = anchors.indices.min {
                    simd_distance(anchors[$0], unit) < simd_distance(anchors[$1], unit)
                }!
                sums[nearest].moment += area * position
                sums[nearest].area += area
                result.longitudinal += 1
            } else {
                tieVolume += bar.volume
                result.ties += 1
            }
        }
        for sum in sums where sum.area > 0 {
            let half = 0.5 * section
            result.bars.append((simd_clamp(sum.moment / sum.area, -half, half), sum.area))
        }
        result.tieRatio = tieVolume / volume
        return result
    }

    /// The region a shell's mats cover: its box grown by half an element in its plane, so that
    /// the edge elements the mesh stretches to meet the plates it ends on (a wall's bottom row,
    /// down to a slab's midsurface) take its steel too.
    static func matRegion(_ box: Box, elementSize h: Float) -> Box {
        let thin = (0..<3).min { box.size[$0] < box.size[$1] } ?? 0
        var region = box
        for axis in 0..<3 where axis != thin {
            region.min[axis] -= h / 2
            region.max[axis] += h / 2
        }
        return region
    }

    /// The structure's reinforcement for one member: regions (`ReinforcementLayer`) for the
    /// reinforcement read from the IFC, and what it was, in words; nil where the IFC gives none.
    static func layers(
        for hosted: Hosted, box: Box, isShell: Bool, elementSize h: Float,
        transform: (SIMD3<Float>) -> SIMD3<Float>
    ) -> (layers: [ReinforcementLayer], description: String)? {
        let thin = (0..<3).min { box.size[$0] < box.size[$1] } ?? 0
        let spread = matRegion(box, elementSize: h)
        let long = (0..<3).max { box.size[$0] < box.size[$1] } ?? 2
        func centimetres(_ area: Float) -> String { String(format: "%.1f", area * 1e4) }
        if !hosted.bars.isEmpty {
            if isShell {
                let mats = shellMats(hosted.bars, box: box, axis: thin, transform: transform)
                guard mats.bars > 0 else { return nil }
                var model = StructureModel(solids: [], elementSize: h)
                let (first, second) = ((thin + 1) % 3, (thin + 2) % 3)
                var words: [String] = []
                for side in 0..<2 where mats.steel[side] > 0 {
                    model.addMat(
                        to: spread, thicknessAxis: thin, areaPerMetre: mats.areas[side][first],
                        transverseAreaPerMetre: mats.areas[side][second], longitudinalAxis: first,
                        depth: mats.depths[side], faces: (side == 0, side == 1))
                    words.append(
                        "\(side == 0 ? "one" : "the other") face \(centimetres(mats.areas[side][first])) and "
                            + "\(centimetres(mats.areas[side][second])) cm²/m each way at "
                            + "\(String(format: "%.0f", mats.depths[side] * 1000)) mm")
                }
                var text =
                    "From the IFC: \(mats.bars) bar\(mats.bars == 1 ? "" : "s"), "
                    + words.joined(separator: "; ")
                if mats.links > 0 { text += "; \(mats.links) through its thickness left out" }
                return (model.reinforcement, text + ".")
            }
            let beam = beamBars(hosted.bars, box: box, axis: long, transform: transform)
            guard beam.longitudinal > 0 else { return nil }
            let (first, second) = ((long + 1) % 3, (long + 2) % 3)
            let middle = 0.5 * (box.min + box.max)
            var layers: [ReinforcementLayer] = []
            for bar in beam.bars {
                // A square region a centimetre across at the bar, along the beam: the beam reads a
                // region covering part of its section as a bar at its middle.
                let side: Float = 0.01
                var low = box.min
                var high = box.max
                low[first] = middle[first] + bar.position.x - side / 2
                high[first] = low[first] + side
                low[second] = middle[second] + bar.position.y - side / 2
                high[second] = low[second] + side
                var ratio = SIMD3<Float>(repeating: beam.tieRatio / 2)
                ratio[long] = bar.area / (side * side)
                layers.append(ReinforcementLayer(region: Box(min: low, max: high), ratio: ratio))
            }
            let total = beam.bars.reduce(0) { $0 + $1.area }
            var text =
                "From the IFC: \(beam.longitudinal) bar\(beam.longitudinal == 1 ? "" : "s") along it, "
                + "\(centimetres(total)) cm² in \(beam.bars.count) place\(beam.bars.count == 1 ? "" : "s")"
            if beam.ties > 0 {
                text += String(
                    format: ", and %d ties or links, %.2f%% of its volume", beam.ties, beam.tieRatio * 100)
            }
            return (layers, text + ".")
        }
        guard let properties = hosted.properties, let ratio = properties.ratio else { return nil }
        // The properties give only a ratio: half in each face of a shell, the same each way, or in
        // four corner bars of a beam; at the given cover, or 30 mm, to the centre of a 12 mm bar.
        let cover = (properties.cover ?? 0.03) + 0.006
        let coverNote = properties.cover == nil ? ", cover 30 mm assumed" : ""
        let percent = String(format: "%.2f%%", ratio * 100)
        if isShell {
            var model = StructureModel(solids: [], elementSize: h)
            let thickness = box.size[thin]
            model.addMat(
                to: spread, thicknessAxis: thin, areaPerMetre: ratio * thickness / 4,
                depth: min(cover, 0.5 * thickness))
            return (
                model.reinforcement,
                "From the IFC's properties (\(properties.source)): \(percent) of steel, a quarter each way in each "
                    + "face\(coverNote)."
            )
        }
        let (first, second) = ((long + 1) % 3, (long + 2) % 3)
        let section = box.size[first] * box.size[second]
        var layers: [ReinforcementLayer] = []
        for corner in 0..<4 {
            let side: Float = 0.01
            var low = box.min
            var high = box.max
            let inset = SIMD2(min(cover, 0.25 * box.size[first]), min(cover, 0.25 * box.size[second]))
            low[first] = (corner & 1 == 0 ? box.min[first] + inset.x : box.max[first] - inset.x) - side / 2
            high[first] = low[first] + side
            low[second] = (corner & 2 == 0 ? box.min[second] + inset.y : box.max[second] - inset.y) - side / 2
            high[second] = low[second] + side
            var region = SIMD3<Float>.zero
            region[long] = ratio * section / 4 / (side * side)
            layers.append(ReinforcementLayer(region: Box(min: low, max: high), ratio: region))
        }
        return (
            layers,
            "From the IFC's properties (\(properties.source)): \(percent) of steel, in four corner bars\(coverNote)."
        )
    }
}

extension ImportedMesh.Triangle {
    /// A triangle of three points, for building shapes outside BlastCore (the app's reading of a
    /// converter's reinforcement).
    public init(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) {
        self.init(a: a, b: b, c: c)
    }
}
