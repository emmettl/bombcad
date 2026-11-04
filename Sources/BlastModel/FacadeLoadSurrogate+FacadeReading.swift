import Foundation

extension FacadeLoadSurrogate {
    /// How the preview reads each façade group (`Prepared.facadeBands`; emmettl/bombcad-work#117),
    /// by name: three bands of equal area by distance, adopted on 8 November 2026, or the nearest
    /// strip for the whole group, as before, kept to reproduce an earlier preview.
    public enum FacadeReading: String, CaseIterable, Sendable {
        /// Three bands: the nearest strip for the nearest band, each further band's middle strip for
        /// its own (the glass alone). The default since 8 November 2026.
        case threeBands = "three-bands"
        /// The nearest strip for each whole façade group: the preview until 8 November 2026.
        case nearestStrip = "nearest-strip"

        /// The reading adopted.
        public static let adopted = FacadeReading.threeBands

        /// The strips that stand for each façade group.
        public var bands: Int {
            switch self {
            case .threeBands: 3
            case .nearestStrip: 1
            }
        }

        /// In a few words, as the app offers it.
        public var label: String {
            switch self {
            case .threeBands: "Three bands of each façade (since 8 November 2026)"
            case .nearestStrip: "Each façade read by its nearest strip (before 8 November 2026)"
            }
        }
    }
}

extension FacadeLoadSurrogate.Prepared {
    /// The same layout read as `reading` names.
    public func reading(_ reading: FacadeLoadSurrogate.FacadeReading) -> FacadeLoadSurrogate.Prepared {
        withFacadeBands(reading.bands)
    }
}
