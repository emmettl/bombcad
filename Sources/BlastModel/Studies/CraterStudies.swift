import Foundation

package enum CraterStudies {
    /// `craters-cooper` (`--fixture` the path of Fixtures/Cooper1976/craters.json): BombCAD's crater
    /// against H. F. Cooper's 1976 high-explosive craters, by medium and by height or depth of
    /// burst (docs/cratering.md#against-cooper-1976).
    package static func cooper1976(_ args: [String]) throws {
        func value(_ name: String) -> String? { SurrogateBench.value(args, name) }
        let url = URL(filePath: value("fixture") ?? "Fixtures/Cooper1976/craters.json")
        let fixture = try CooperCraters1976.fixture(from: url)
        typealias C = CooperCraters1976
        func f(_ x: Double, _ digits: Int = 2) -> String { String(format: "%.\(digits)f", x) }

        print("Surface bursts: BombCAD's crater for a ton of TNT centred on the surface, against Cooper's V₀")
        print("ground | BombCAD V₀ (ft³/ton) | Cooper's medium V₀ (range) | ratio")
        for medium in C.Medium.allCases {
            guard let row = fixture.row(medium) else { continue }
            for ground in medium.grounds {
                let v = C.bombcadVolume(
                    radius: C.bombcadRadius(ground: ground, centreHeight: 0, datum: .centre))
                print(
                    "\(ground.rawValue) | \(Int(v.rounded())) | \(medium.title) \(Int(row.v0)) "
                        + "(\(Int(row.v0Range[0]))–\(Int(row.v0Range[1]))) | \(f(row.v0 / v)) of BombCAD's")
            }
        }

        print(
            "\nA sphere resting on the ground, Cooper's best estimate against BombCAD's (radius, ft/ton^(1/3)):"
        )
        for medium in C.Medium.allCases {
            let h = C.restingSphereHeight(fixture, medium: medium)
            let v = C.cooperEstimate(fixture, medium: medium, h: h) ?? 0
            let cooper = fixture.shape.radius.best * cbrt(v)
            let ground = medium.grounds[0]
            let under = C.bombcadRadius(ground: ground, centreHeight: 1, datum: .underside)
            let centre = C.bombcadRadius(ground: ground, centreHeight: 1, datum: .centre)
            print(
                "\(medium.title): H \(f(h, 3)), Cooper \(f(cooper, 1)); BombCAD \(f(under, 1)) to the underside "
                    + "(Cooper's \(f(cooper / under))), \(f(centre, 1)) to the centre (\(f(cooper / centre)))"
            )
        }

        for datum in C.Datum.allCases {
            print("\nCooper's points over BombCAD's, height to the charge's \(datum.rawValue):")
            print(
                "medium (BombCAD's ground) | band | n | radius: geometric mean (range), within ±1/3 | volume: mean"
            )
            let pairs = C.pairs(fixture, datum: datum)
            for medium in C.Medium.allCases {
                for band in C.Band.allCases {
                    let set = pairs.filter { $0.medium == medium && C.Band(h: $0.h) == band }
                    guard let r = C.Summary(set.map(\.radiusRatio)), let v = C.Summary(set.map(\.volumeRatio))
                    else { continue }
                    print(
                        "\(medium.title) (\(medium.grounds[0].rawValue)) | \(band.rawValue) | \(r.count) | "
                            + "\(f(r.geometricMean)) (\(f(r.low))–\(f(r.high))), \(Int((r.withinBand * 100).rounded()))% | "
                            + "\(f(v.geometricMean))")
                }
            }
            for band in C.Band.allCases {
                let set = pairs.filter { C.Band(h: $0.h) == band }
                guard let r = C.Summary(set.map(\.radiusRatio)) else { continue }
                print(
                    "all | \(band.rawValue) | \(r.count) | \(f(r.geometricMean)) (\(f(r.low))–\(f(r.high))), "
                        + "\(Int((r.withinBand * 100).rounded()))%")
            }
        }

        // The six measured craters of docs/cratering.md, by Cooper's own method: his medium's V₀,
        // e^(−5.2 H) with H to the charge's centre, and R = 1.2 V^(1/3) (his equation 14).
        print("\nThe six measured craters by Cooper's own method (diameter, m):")
        let events:
            [(name: String, tons: Double, medium: C.Medium, resting: Bool, measured: ClosedRange<Double>)] = [
                ("Prairie Flat (sphere resting, wet)", 500, .wetSoil, true, 85.5...85.5),
                ("Dial Pack (sphere resting, wet)", 500, .wetSoil, true, 70.1...70.1),
                ("Snowball (hemisphere, wet)", 500, .wetSoil, false, 73...73),
                ("Sailor Hat Bravo (stack, rock)", 500, .hardRock, false, 69...69),
                ("Minor Scale (about 4 kt TNT, dry lake bed)", 4000 / 0.907_185, .drySoil, false, 105...105),
                ("Beirut (0.5 kt, saturated fill)", 500 / 0.907_185, .wetSoil, false, 117...124),
            ]
        for event in events {
            var h = 0.0
            if event.resting {
                let radius = C.chargeRadiusFeet * cbrt(event.tons)
                for _ in 0..<50 {
                    h =
                        radius
                        / cbrt((C.cooperEstimate(fixture, medium: event.medium, h: h) ?? 1) * event.tons)
                }
            }
            let volume = (C.cooperEstimate(fixture, medium: event.medium, h: h) ?? 0) * event.tons
            let diameter = 2 * fixture.shape.radius.best * cbrt(volume) * 0.3048
            let mid = (event.measured.lowerBound + event.measured.upperBound) / 2
            print(
                "\(event.name): H \(f(h, 3)), \(f(diameter, 0)) m; measured \(f(mid, 0)), \(f(mid / diameter))"
            )
        }

        print(
            "\nCooper's own best estimate (V₀ e^(−5.2 H), |H| < 0.4) through his points, radius as (V/V_est)^(1/3):"
        )
        for medium in C.Medium.allCases {
            let ratios = fixture.points(medium).filter { abs($0.h) < 0.4 }.compactMap { point in
                C.cooperEstimate(fixture, medium: medium, h: point.h).map { cbrt(point.efficiency / $0) }
            }
            guard let r = C.Summary(ratios) else { continue }
            print(
                "\(medium.title) | \(r.count) | \(f(r.geometricMean)) (\(f(r.low))–\(f(r.high))), "
                    + "\(Int((r.withinBand * 100).rounded()))% within ±1/3")
        }
    }
}
