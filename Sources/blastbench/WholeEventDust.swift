import BlastCore
import BlastModel
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// `blastbench wholeevent`'s dust: the collapse's dust carried by the air (AirDust; emmettl/bombcad-work#36,
// docs/whole-event.md, "Dust, stage 1"), by default since 1 November 2026 (adopted: the dust);
// `--no-dust` leaves it out, as runs before then did. Its coefficients by option:
// `--dust-energy <J/kg>` (5e4), `--dust-impact-share <0-1>` (0.2), `--dust-fine-share <0-1>` (0.15).
// Each sample appends a row to `<dir>/dust.csv`: what has been made (by class and source), what is
// airborne, settled (on the ground beyond and under the plan, on solids) and gone out of the domain,
// what the ledger cannot place, and the cloud bounded at 10 mg/m³ and at 1 g/m³ (its volume, its top,
// its reach beyond the plan and whether it touches an open face) and its peak concentration.
// `--dust-maps 1,2,3,5,7` writes the mass in each column of air (kg/m²) at those times, as
// `dust-column-<ms>.csv` (x across, y down) and a picture of it (log scale, 1 g/m² to 10 kg/m²).

/// The dust's coefficients as the options give them.
func wholeEventDustSettings() -> DustSettings {
    var settings = DustSettings.standard
    if let value = option("dust-energy").flatMap(Double.init) { settings.energyPerKilogram = value }
    if let value = option("dust-impact-share").flatMap(Double.init) { settings.impactShare = value }
    if let value = option("dust-fine-share").flatMap(Double.init) { settings.fineShare = value }
    return settings
}

enum WholeEventDust {
    /// The concentrations (kg/m³) the cloud is bounded at: 10 mg/m³, a haze well past air-quality
    /// limits, and 1 g/m³, a cloud dense enough to hide what is 30 m inside it; and 5 and 20 mg/m³,
    /// which bound the 10 mg/m³ cloud as it would be with half and twice the energy per kilogram of
    /// fines (the fines scale as its inverse, the dust being passive).
    static let thresholds: [Double] = [1e-5, 1e-3, 5e-6, 2e-5]

    static func tag(_ threshold: Double) -> String {
        threshold >= 1e-4 ? "\(Int((threshold * 1e3).rounded()))g" : "\(Int((threshold * 1e6).rounded()))mg"
    }

    static let header =
        "t,step,made_fine_kg,made_coarse_kg,from_elements_kg,from_impacts_kg,made_outside_kg,airborne_fine_kg,"
        + "airborne_coarse_kg,in_solids_kg,ground_outside_kg,ground_within_kg,on_solids_kg,left_domain_kg,"
        + "unplaced_kg,"
        + thresholds.map { t in
            let tag = tag(t)
            return "cloud_\(tag)_m3,top_\(tag)_m,reach_\(tag)_m,at_open_face_\(tag)"
        }.joined(separator: ",") + ",peak_kg_m3"

    /// The plan the deposits under the pile and the cloud's reach are told by: the structure's
    /// bounds in x and y.
    static func plan(_ scenario: Scenario) -> (min: SIMD2<Float>, max: SIMD2<Float>) {
        let bounds = scenario.structure?.bounds ?? Box(min: .zero, max: .zero)
        return (SIMD2(bounds.min.x, bounds.min.y), SIMD2(bounds.max.x, bounds.max.y))
    }

    /// The row for the dust now, and its field.
    static func row(_ solver: BlastSolver, scenario: Scenario, time: Double, step: Int) -> (
        row: String, field: DustField
    )? {
        let plan = plan(scenario)
        guard let (ledger, field) = solver.dustReading(plan: plan) else { return nil }
        let planD = (min: SIMD2<Double>(plan.min), max: SIMD2<Double>(plan.max))
        var values = [String(format: "%.5f", time), "\(step)"]
        values += [
            ledger.made.x, ledger.made.y, ledger.fromElements, ledger.fromImpacts, ledger.madeOutside,
            ledger.airborne.x, ledger.airborne.y, ledger.inSolids.x + ledger.inSolids.y,
            ledger.onGroundOutside.x + ledger.onGroundOutside.y,
            ledger.onGroundWithin.x + ledger.onGroundWithin.y,
            ledger.onSolids.x + ledger.onSolids.y,
            ledger.leftDomain.x + ledger.leftDomain.y + ledger.madeOutside,
            ledger.unplaced,
        ].map { String(format: "%.6g", $0) }
        var peak = 0.0
        for threshold in thresholds {
            let cloud = field.cloud(threshold: threshold, plan: planD)
            peak = cloud.peak
            values += [
                String(format: "%.1f", cloud.volume), String(format: "%.2f", cloud.top),
                String(format: "%.2f", cloud.reach), cloud.atOpenFace ? "1" : "0",
            ]
        }
        values.append(String(format: "%.4g", peak))
        return (values.joined(separator: ","), field)
    }

    /// Writes the mass in each column of air at `time` to `dir`.
    static func writeMap(_ field: DustField, time: Double, to dir: URL) {
        let columns = field.columnMass()
        let (nx, ny) = (field.dims.x, field.dims.y)
        var text = ""
        for y in 0..<ny {
            text +=
                (0..<nx).map { String(format: "%.4g", columns[$0 + nx * y]) }.joined(separator: ",") + "\n"
        }
        let stem = String(format: "dust-column-%05.0fms", time * 1000)
        try? text.write(to: dir.appending(path: stem + ".csv"), atomically: true, encoding: .utf8)
        // The picture: y up, a log scale from 1 g/m² (black) to 10 kg/m² (white), through warm tones.
        let scale = 4
        let (width, height) = (nx * scale, ny * scale)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for py in 0..<height {
            for px in 0..<width {
                let (x, y) = (px / scale, ny - 1 - py / scale)
                let value = columns[x + nx * y]
                let s = value > 0 ? min(max((log10(value) + 3) / 4, 0), 1) : 0
                let n = 4 * (px + width * py)
                pixels[n] = UInt8(255 * min(1, 1.6 * s))
                pixels[n + 1] = UInt8(255 * min(1, max(0, 1.6 * s - 0.4)))
                pixels[n + 2] = UInt8(255 * max(0, 2.5 * s - 1.5))
                pixels[n + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
            let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
            let destination = CGImageDestinationCreateWithURL(
                dir.appending(path: stem + ".png") as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
