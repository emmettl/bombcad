import BlastCore
import Foundation
import simd

/// `scenebench field-surrogate <field-export's inputs> [--radius 1024] [--dx 4] [--height m] --out
/// strips.csv`: the façade load surrogate's first look at a `field-export` run's district, for
/// judging the learned field model beside it (Scripts/ml/judge_field.py, docs/learned-models.md).
/// The district is laid out as `field-export` lays it out, from the same arguments, and each façade
/// strip with a face on the air gets its features and the surrogate's peak and impulse
/// (`FacadeLoadSurrogate.estimate`), with Kingery–Bulmash's incident values and the surrogate's
/// base beside them. Nothing is run: it takes seconds, on the CPU.
///
/// Each row's box is in the run's metres (the field's plan cells are `dx` across from the origin),
/// so the cells of the field in front of a strip can be found from it.
enum FieldSurrogate {
    static func run(_ args: [String]) throws {
        func value(_ name: String) -> String? {
            args.firstIndex(of: "--\(name)").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        guard let out = value("out") else { throw BlastError.allocationFailed("--out strips.csv") }
        let start = ContinuousClock.now
        let inputs = try DistrictInputs.read(args)
        let radius = Float(value("radius").flatMap(Double.init) ?? 1024)
        let dx = inputs.cellSize
        var layout = DistrictLayout(buildings: inputs.buildings, charge: inputs.centre, mass: inputs.mass)
        layout.ground = inputs.ground
        layout.heights = inputs.heights
        layout.seaBase = inputs.seaBase
        layout.attributions = inputs.attributions
        layout.readsWoodTags = inputs.readsWoodTags
        let (scene, report) = try layout.scene(
            halfSide: radius, cellSize: dx, height: value("height").flatMap(Float.init),
            name: value("id"))
        print(report.summary)
        let mass = Double(scene.charge.mass)
        let root = cbrt(mass)
        let estimate = FacadeLoadSurrogate.estimate(scene: scene, cellSize: dx)
        var rows: [String] = []
        rows.reserveCapacity(estimate.components.count)
        for (n, component) in estimate.components.enumerated() where component.kind == .facade {
            let f = estimate.features[n]
            let p = estimate.predictions[n]
            let base = FacadeLoadSurrogate.base(f, mass: mass)
            let kb = FieldExport.kingeryBulmash(z: max(f.distanceM, Double(dx) / 2) / root, mass: mass)
            let r = component.region
            let (centre, _) = FacadeLoadSurrogate.outerFace(component)
            let ground = scene.terrain?.height(at: centre) ?? 0
            rows.append(
                [
                    "\(estimate.owners[n])", "\(component.axis)", "\(component.outward)",
                    String(format: "%.2f", r.min.x), String(format: "%.2f", r.min.y),
                    String(format: "%.2f", r.min.z),
                    String(format: "%.2f", r.max.x), String(format: "%.2f", r.max.y),
                    String(format: "%.2f", r.max.z),
                    String(format: "%.2f", ground), String(format: "%.2f", f.heightM),
                    String(format: "%.2f", f.distanceM), String(format: "%.5f", f.cosIncidence),
                    "\(f.buildingsCrossed)", String(format: "%.2f", f.blockedM),
                    String(format: "%.1f", f.shadowM),
                    String(format: "%.1f", f.frontM), String(format: "%.1f", f.canyonM),
                    String(format: "%.2f", f.canyonHeightM),
                    f.edgeM.isFinite ? String(format: "%.2f", f.edgeM) : "-999",
                    String(format: "%.2f", f.ridgeM), String(format: "%.2f", f.groundRiseM),
                    String(format: "%.1f", p.peakPa), String(format: "%.5f", p.impulsePaS),
                    p.outsideFit ? "1" : "0",
                    String(format: "%.1f", kb.peak), String(format: "%.5f", kb.impulse),
                    String(format: "%.1f", base.peak), String(format: "%.5f", base.impulse),
                ].joined(separator: ","))
        }
        let header =
            "object,axis,outward,x0,y0,z0,x1,y1,z1,ground,height,distance,cos,crossed,blocked,shadow,front,"
            + "canyon,canyonheight,edge,ridge,rise,peak,impulse,outside,kbpeak,kbimpulse,basepeak,baseimpulse\n"
        try (header + rows.joined(separator: "\n") + "\n").write(
            to: URL(filePath: out), atomically: true, encoding: .utf8)
        print(
            String(
                format: "Wrote %@: %d façade strips of %d components in %.1f s (the estimate %.1f s)", out,
                rows.count, estimate.components.count, DistrictBenchmark.seconds(start), estimate.seconds))
    }
}
