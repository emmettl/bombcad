import Foundation
import simd

/// A footing rocked slowly to and fro on dry sand, against a measured one: test SSG02_03 of
/// S. Gajan and B. L. Kutter's centrifuge experiments at UC Davis ("Capacity, settlement, and
/// energy dissipation of shallow footings subjected to rocking", J. Geotech. Geoenviron. Eng.
/// 134(8), 2008), from the FoRCy database (M. Hakhamaneshi, B. L. Kutter, A. G. Gavras and
/// others, DesignSafe PRJ-6414, doi:10.13019/t0cq-qf64, Open Data Commons Attribution).
///
/// In prototype units: an essentially rigid shear wall of 29.0 Mg, its centre of mass 4.5 m above
/// the base of a surface footing 2.8 m long (along the load) and 0.65 m wide, on dry Nevada sand
/// at a relative density of 80% (1,657 kg/m³, friction angle about 42°), its ultimate bearing
/// pressure 814 kPa against the 157 kPa the wall puts on it. An actuator pinned to the wall
/// 4.9 m above the footing's base pushed it to and fro in five packets of three slow sinusoidal
/// cycles, each larger than the last. The measured values here are from the database's time
/// histories (`Samples/FoRCy`): the moment about the base centre normalized by L P / 2, the
/// settlement by L.
///
/// The model: the wall as a stiff elastic block 2.8 × 0.6 × 8.6 m on a footing 0.65 m thick
/// reaching 25 mm beyond it each side across, so 0.65 m wide; their densities set so that the two
/// weigh 29.0 Mg with their centre of mass 4.5 m up. A uniform push on the wall's end face acts
/// 4.95 m above the footing's base. It is driven, as the actuator drove the wall, by the
/// displacement there: each millisecond the push is set by a spring and dashpot to the
/// displacement asked for, with a slow integral to make up what the spring leaves short.
/// Bearings with friction 0.1 against the wall's faces near its top stand for the test's Teflon
/// guides, without which the wall falls over sideways. The soil is the footing's elastic
/// half-space with a bearing capacity, the sand's shear modulus the one input not measured.
public enum FootingRockingTest {
    /// One packet of three cycles.
    public struct Packet: Sendable {
        public var name: String
        /// The actuator's amplitude, in metres.
        public var amplitude: Float
        /// Measured: the largest rotation either way (radians), the largest normalized moment
        /// each way, and the settlement at the packet's end, over L.
        public var peakRotation: Float
        public var moment: SIMD2<Float>
        public var settlement: Float

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            name: String,
            amplitude: Float,
            peakRotation: Float,
            moment: SIMD2<Float>,
            settlement: Float
        ) {
            self.name = name
            self.amplitude = amplitude
            self.peakRotation = peakRotation
            self.moment = moment
            self.settlement = settlement
        }
    }

    /// SSG02_03's packets a to e, from the database's time histories.
    public static let packets: [Packet] = [
        Packet(
            name: "a", amplitude: 0.015, peakRotation: 0.0032, moment: SIMD2(0.525, 0.366), settlement: 0.0027
        ),
        Packet(
            name: "b", amplitude: 0.0335, peakRotation: 0.0066, moment: SIMD2(0.691, 0.623),
            settlement: 0.0065),
        Packet(
            name: "c", amplitude: 0.0715, peakRotation: 0.0140, moment: SIMD2(0.779, 0.779),
            settlement: 0.0108),
        Packet(
            name: "d", amplitude: 0.1493, peakRotation: 0.0296, moment: SIMD2(0.837, 0.908),
            settlement: 0.0173),
        Packet(
            name: "e", amplitude: 0.307, peakRotation: 0.0629, moment: SIMD2(0.874, 0.960), settlement: 0.0295
        ),
    ]

    public static let length: Float = 2.8
    public static let width: Float = 0.65
    public static let mass: Float = 29_000
    public static let bearingCapacity: Float = 814e3

    public struct Result: Sendable {
        public struct Packet: Sendable {
            public var name: String
            public var peakRotation: Float = 0
            /// Largest normalized moment pushing forward and back.
            public var moment = SIMD2<Float>.zero
            /// Settlement of the base centre at its largest in the packet's last cycle, over L.
            public var settlement: Float = 0
            /// The largest the actuator's displacement fell short of what was asked, in metres.
            public var lag: Float = 0

            /// The memberwise initialiser, written out so that BlastCore can use it.
            package init(
                name: String,
                peakRotation: Float = 0,
                moment: SIMD2<Float> = SIMD2<Float>.zero,
                settlement: Float = 0,
                lag: Float = 0
            ) {
                self.name = name
                self.peakRotation = peakRotation
                self.moment = moment
                self.settlement = settlement
                self.lag = lag
            }
        }
        public var packets: [Packet] = []
        /// (rotation, normalized moment, settlement over L) every 10 ms.
        public var history: [SIMD3<Float>] = []
        public var wallSeconds: Double = 0
        /// After each packet or event: how far the soil under the footing has sunk for good
        /// (m), against x along the footing, averaged across it.
        public var profiles: [[SIMD2<Float>]] = []

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            packets: [Packet] = [],
            history: [SIMD3<Float>] = [],
            wallSeconds: Double = 0,
            profiles: [[SIMD2<Float>]] = []
        ) {
            self.packets = packets
            self.history = history
            self.wallSeconds = wallSeconds
            self.profiles = profiles
        }
    }
}
