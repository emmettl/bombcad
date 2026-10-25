import Foundation

extension FacadeLoadSurrogate {
    /// Which façade terms and load scatter the surrogate takes (emmettl/bombcad-work#98, #99;
    /// docs/surrogate-first-look.md): the terms refitted on runs whose top clears the far façades
    /// (`Coefficients.clearTop`, `Uncertainty.clearTopLeaveOneOut`), adopted by the user on 25
    /// October 2026 and the default (`adopted`); or those of 23 October, fitted on runs whose top
    /// drained the far loads (`Coefficients.fitted`, `Uncertainty.leaveOneOut`), kept by name so
    /// that earlier records can be reproduced.
    public enum TermSet: String, CaseIterable, Codable, Sendable {
        case clearTop = "clear-top"
        case fitted
        /// `clearTop` with the glass chances' pulses arriving with a front
        /// (`Coefficients.GlassFront.clearTop`; emmettl/bombcad-work#103): a candidate, off by
        /// default. Its loads, its walls and its scatter are `clearTop`'s.
        case clearTopFront = "clear-top-front"
        /// `clearTop` with far terms for façades deep in a city (`Coefficients.deepCity`;
        /// emmettl/bombcad-work#104), fitted on runs that reach 3 km across a city: a candidate,
        /// off by default. Its near and in-district terms and its scatter are `clearTop`'s.
        case deepCity = "deep-city"
        /// `deepCity` with the glass's front refitted alongside (`Coefficients.GlassFront.deepCity`):
        /// a candidate, off by default.
        case deepCityFront = "deep-city-front"

        /// The set in use unless another is named: `clearTop` since 25 October 2026.
        public static let adopted = TermSet.clearTop

        /// The façade terms.
        public var coefficients: Coefficients {
            switch self {
            case .fitted: .fitted
            case .clearTop: .clearTop
            case .clearTopFront: .clearTopFront
            case .deepCity: .deepCity
            case .deepCityFront: .deepCityFront
            }
        }

        /// The load scatter the chances draw.
        public var loadScatter: [Uncertainty.LoadScatter] {
            switch self {
            case .fitted: Uncertainty.leaveOneOut
            case .clearTop, .clearTopFront, .deepCity, .deepCityFront: Uncertainty.clearTopLeaveOneOut
            }
        }
    }
}

extension FacadeLoadSurrogate.Coefficients {
    /// The façade terms in use unless others are given: `TermSet.adopted`'s, `clearTop` since 25
    /// October 2026 (emmettl/bombcad-work#99); `fitted` before.
    public static let adopted = FacadeLoadSurrogate.TermSet.adopted.coefficients
}

extension FacadeLoadSurrogate.Uncertainty {
    /// The load scatter the chances draw unless another is given: `TermSet.adopted`'s,
    /// `clearTopLeaveOneOut` since 25 October 2026; `leaveOneOut` before.
    public static let adoptedLoadScatter = FacadeLoadSurrogate.TermSet.adopted.loadScatter
}

extension FacadeLoadSurrogate.Coefficients {
    /// Adopted on 25 October 2026 (emmettl/bombcad-work#98, #99): `fitted` with the peak's, impulse's and
    /// rise share's terms refitted by #56's fit on its runs remade with their top clear of the far façades
    /// (#96's rule, the highest ground plus a fifth of the farthest fitted strip's distance; the
    /// runs #56 fitted on had tops of 112–320 m, which drained their loads from about five times the
    /// top's clearance over the ground): the made-up fit set on air refined to 2 m (dense at 20,
    /// 100 and 500 t under a 400 m top, sparse at 20 t under 200 m) and Beirut's near boxes at
    /// 150, 300, 500, 850 and 1300 t (refined to 2 m, a 440 m top, run to 5 s: full length), each
    /// run alike, the impulse's on all nine too (with the boxes full length their impulses no longer
    /// scatter as the cut ones did). The rise share is refitted on the same runs' rise time
    /// (docs/surrogate-first-look.md, "The rise share's fit": `fitted`'s was fitted to the ground
    /// rise, and its slow rise, 0.6–0.9 of the pulse against the runs' 0.3, offset impulses the
    /// drained runs read low) for the loads and the glass; the walls' chances keep `fitted`'s rise
    /// (`structureRise`), on which their load factor ×1.15 was set: with the refitted rise concrete
    /// walls' chances lose their tenths test at every factor from ×1.0 to ×1.15. The canyon terms,
    /// the close-in branch and its shielding, the range and the scatter are `fitted`'s.
    public static let clearTop: FacadeLoadSurrogate.Coefficients = {
        var c = FacadeLoadSurrogate.Coefficients.fitted
        c.peak = [
            -2.1111, -0.4391, -0.1242, -0.0656, 0.0010, 0.7050, -0.3155, -0.0934, 0.0378, -0.1222, -0.4139,
            0.0000, 0.6830, 0.0000,
        ]
        c.impulse = [
            -0.1079, -0.5416, -0.1176, 0.0042, -0.0024, 0.0756, -0.0746, -0.1171, 0.1313, 0.0021, 0.0385,
            0.0000, 0.0000, 1.3340,
        ]
        c.rise = [
            0.3745, -0.0045, 0.0350, 0.0307, -0.0048, 0.0657, -0.0092, -0.0167, 0.0462, -0.0187, 0.0679,
            0.0000, 0.0000, 0.0000,
        ]
        c.structureRise = FacadeLoadSurrogate.Coefficients.fitted.rise
        c.fittedTo =
            "made-up districts (dense at 20, 100 and 500 t, sparse at 20 t) and Beirut's near boxes at 150, 300, "
            + "500, 850 and 1300 t, on air refined to 2 m with the top clear of the far façades, full length"
        return c
    }()
}

extension FacadeLoadSurrogate.Coefficients.GlassFront {
    /// Fitted on 25 October 2026 (emmettl/bombcad-work#103; docs/glass-probability.md) on the
    /// surrogate's clear-top fit runs (#98's: the made-up districts at 20, 100 and 500 t and sparse at
    /// 20 t, Beirut's near boxes at 150, 300, 500, 850 and 1300 t, on air refined to 2 m): in each band
    /// of scaled distance, the share at which a triangle of each strip's own peak, first impulse and
    /// rise gives its mix's panes the 60 s stress the strip's own history gives them, the median of
    /// the log ratio, each run alike. Within Z 8 the history and the triangle agree to 1%, so none.
    /// Judged on Beirut's clear-top references, which none of the fit runs is. Below 20 t, the fit's
    /// smallest charge, none.
    public static let clearTop = Self(
        points: [
            SIMD2(8.4, 0), SIMD2(11.8, 0.05), SIMD2(16.7, 0.10), SIMD2(23.7, 0.19), SIMD2(33.5, 0.28),
            SIMD2(49.0, 0.54),
        ],
        minimumMassKg: 20_000,
        fittedTo:
            "the clear-top fit runs (made-up districts at 20, 100 and 500 t, sparse at 20 t, Beirut's near boxes at "
            + "150, 300, 500, 850 and 1300 t; 2 m air), the panes' stress under each strip's own history")
}

extension FacadeLoadSurrogate.Coefficients {
    /// `clearTop` with the glass's front (`GlassFront.clearTop`), for `TermSet.clearTopFront`.
    public static let clearTopFront: FacadeLoadSurrogate.Coefficients = {
        var c = FacadeLoadSurrogate.Coefficients.clearTop
        c.glassFront = .clearTop
        return c
    }()
}

extension FacadeLoadSurrogate.Uncertainty {
    /// The clear-top runs' scatter about `Coefficients.clearTop` beyond Z 7, each of the nine held
    /// out of a fit to the other eight (emmettl/bombcad-work#98), as `leaveOneOut` is the first
    /// fit's: the root of the mean square, bias and spread together, each run alike. Within Z 7,
    /// where the top drains nothing, `leaveOneOut`'s (on which the walls' load factor was set).
    /// Adopted with `Coefficients.clearTop` on 25 October 2026.
    public static let clearTopLeaveOneOut: [LoadScatter] = [
        LoadScatter(upToZ: 7, peak: 0.41, impulse: 0.26, correlation: 0.51),
        LoadScatter(upToZ: 10, peak: 0.28, impulse: 0.16, correlation: 0.41),
        LoadScatter(upToZ: 14, peak: 0.24, impulse: 0.14, correlation: 0.37),
        LoadScatter(upToZ: 20, peak: 0.21, impulse: 0.14, correlation: 0.39),
        LoadScatter(upToZ: 28, peak: 0.19, impulse: 0.11, correlation: 0.42),
        LoadScatter(upToZ: .infinity, peak: 0.19, impulse: 0.12, correlation: 0.44),
    ]
}

extension FacadeLoadSurrogate.Coefficients.Far {
    /// Fitted on 25 October 2026 (emmettl/bombcad-work#104; docs/surrogate-first-look.md) on the
    /// clear-top fit runs (#98's nine, 2 m air) and five more that reach 3 km across a city: two
    /// made-up districts 5 km across, dense to their corners (3–7 storeys at 50, 200 and 1000 t;
    /// taller, with more towers, at 100 and 500 t), on 8 m air refined once to 4 m (#97's setup)
    /// under a 672 m top (the highest ground plus a fifth of the fair part's farthest corner, #96's
    /// rule), run to 9.5 s. Each run alike, the fourteen terms held at `clearTop`'s, the impulse and
    /// the rise left as they are. Of the forms tried (distance in metres and its square, the depth
    /// beyond a few dozen buildings, the depth times the distance, the incident wave's length,
    /// scaled distance past the fitted range), these two did as well as any held out run by run.
    /// Beirut's clear-top references, which no fit saw, judge it.
    public static let deepCity = Self(
        depthFrom: 30, distanceFromM: 1_750, peakDepth: 0.0673, peakAway: 0.4181,
        fittedTo:
            "the clear-top fit runs and five runs to 3 km across made-up dense districts (50 t to 1 kt, 8 m air "
            + "refined to 4 m, the top clear)")
}

extension FacadeLoadSurrogate.Coefficients {
    /// `clearTop` with the far terms (`Far.deepCity`), for `TermSet.deepCity`
    /// (emmettl/bombcad-work#104): a candidate, off by default.
    public static let deepCity: FacadeLoadSurrogate.Coefficients = {
        var c = FacadeLoadSurrogate.Coefficients.clearTop
        c.far = .deepCity
        c.fittedTo = clearTop.fittedTo + "; far terms on runs to 3 km across made-up dense districts"
        return c
    }()

    /// `deepCity` with the glass's front refitted alongside (`GlassFront.deepCity`), for
    /// `TermSet.deepCityFront`.
    public static let deepCityFront: FacadeLoadSurrogate.Coefficients = {
        var c = FacadeLoadSurrogate.Coefficients.deepCity
        c.glassFront = .deepCity
        return c
    }()
}

extension FacadeLoadSurrogate.Coefficients.GlassFront {
    /// Refitted on 25 October 2026 (emmettl/bombcad-work#104) as `clearTop` was (#103), on its
    /// nine runs and the five deep ones that reach 3 km across a city (8 m air refined to 4 m),
    /// each run alike: the same within Z 24, a little less beyond (0.46 against 0.54 at Z 49), and
    /// a point at Z 73.5, which only the deep runs reach. None within Z 8, as before.
    public static let deepCity = Self(
        points: [
            SIMD2(8.4, 0), SIMD2(11.8, 0.05), SIMD2(16.7, 0.11), SIMD2(23.7, 0.18), SIMD2(33.5, 0.26),
            SIMD2(49.0, 0.46), SIMD2(73.5, 0.64),
        ],
        minimumMassKg: 20_000,
        fittedTo:
            "the clear-top fit runs and the five deep runs (50 t to 1 kt, 8 m air refined to 4 m), the panes' "
            + "stress under each strip's own history")
}
