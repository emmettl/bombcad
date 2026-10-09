import Foundation
import simd

/// A measured atmosphere for the cloud to rise through: a radiosonde's temperature, dew point,
/// pressure and wind against height, in place of the standard atmosphere. The scene's ground is
/// the first level's height.
public struct CloudSounding: Codable, Sendable, Equatable {
    /// One level of the sounding, in the units of the model.
    public struct Level: Codable, Sendable, Equatable {
        /// Above sea level, in geopotential metres.
        public var height: Double
        /// In pascals.
        public var pressure: Double
        /// The temperature and dew point, in kelvin.
        public var temperature: Double
        public var dewPoint: Double
        /// In metres a second, and the direction it blows from, in degrees clockwise from north, as
        /// weather observations give it.
        public var windSpeed: Double
        public var windDirection: Double

        public init(
            height: Double, pressure: Double, temperature: Double, dewPoint: Double, windSpeed: Double,
            windDirection: Double
        ) {
            self.height = height
            self.pressure = pressure
            self.temperature = temperature
            self.dewPoint = dewPoint
            self.windSpeed = windSpeed
            self.windDirection = windDirection
        }
    }

    /// From the ground up, each higher than the last.
    public var levels: [Level]

    public init(levels: [Level]) {
        self.levels = levels
    }

    /// Reads the comma-separated values of the University of Wyoming's upper-air archive
    /// (`type=TEXT:CSV`), its columns found by their headings; rows with a value missing, and
    /// rows no higher than the last, are left out.
    public init(wyomingCSV text: String) throws {
        func invalid(_ message: String) -> CocoaError {
            CocoaError(.coderReadCorrupt, userInfo: [NSLocalizedDescriptionKey: message])
        }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let header = lines.first else { throw invalid("The sounding is empty.") }
        let headings = header.split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        let wanted = [
            "pressure_hPa", "geopotential height_m", "temperature_C", "dew point temperature_C",
            "wind direction_degree", "wind speed_m/s",
        ]
        let columns = try wanted.map { heading in
            guard let column = headings.firstIndex(of: heading) else {
                throw invalid("The sounding has no \(heading) column.")
            }
            return column
        }
        var levels: [Level] = []
        for line in lines.dropFirst() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            let values = columns.map { $0 < fields.count ? Double(fields[$0]) : nil }
            guard let pressure = values[0], let height = values[1], let temperature = values[2],
                let dewPoint = values[3], let direction = values[4], let speed = values[5],
                height > levels.last?.height ?? -.infinity
            else { continue }
            levels.append(
                Level(
                    height: height, pressure: 100 * pressure, temperature: temperature + 273.15,
                    dewPoint: dewPoint + 273.15, windSpeed: speed, windDirection: direction))
        }
        self.init(levels: levels)
        try validate()
    }

    public func validate() throws {
        let finite = levels.allSatisfy {
            [$0.height, $0.pressure, $0.temperature, $0.dewPoint, $0.windSpeed, $0.windDirection].allSatisfy(
                \.isFinite)
        }
        guard levels.count >= 2, finite,
            zip(levels, levels.dropFirst()).allSatisfy({ $0.height < $1.height && $0.pressure > $1.pressure }
            ),
            levels.allSatisfy({
                $0.pressure > 0 && $0.temperature > 150 && $0.temperature < 350 && $0.dewPoint > 100
                    && $0.dewPoint <= $0.temperature + 0.5 && $0.windSpeed >= 0 && $0.windSpeed <= 150
            })
        else {
            throw CocoaError(
                .coderInvalidValue,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The sounding needs two levels or more, rising with the pressure falling, and values in range."
                ])
        }
    }

    /// The level below `z` metres above the ground, or the last, and how far `z` is towards the
    /// next, from 0 to 1.
    private func bracket(_ z: Double) -> (index: Int, share: Double) {
        let height = levels[0].height + z
        guard height > levels[0].height else { return (0, 0) }
        guard height < levels[levels.count - 1].height else { return (levels.count - 2, 1) }
        var low = 0
        var high = levels.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if levels[middle].height <= height { low = middle } else { high = middle }
        }
        return (low, (height - levels[low].height) / (levels[low + 1].height - levels[low].height))
    }

    /// The temperature (K) and pressure (Pa) `height` metres above the ground: the temperature
    /// linear and the logarithm of the pressure linear between levels; above the last level the
    /// temperature stays constant and the pressure falls hydrostatically, and below the first,
    /// likewise.
    public func callAsFunction(_ height: Double) -> (temperature: Double, pressure: Double) {
        let top = levels[levels.count - 1]
        let z = levels[0].height + height
        let g = CloudRise.gravity
        let r = CloudRise.gasConstant
        if z > top.height {
            return (top.temperature, top.pressure * exp(-g * (z - top.height) / (r * top.temperature)))
        }
        if z < levels[0].height {
            let ground = levels[0]
            return (
                ground.temperature, ground.pressure * exp(-g * (z - ground.height) / (r * ground.temperature))
            )
        }
        let (index, share) = bracket(height)
        let (a, b) = (levels[index], levels[index + 1])
        return (
            a.temperature + share * (b.temperature - a.temperature),
            exp(log(a.pressure) + share * (log(b.pressure) - log(a.pressure)))
        )
    }

    /// The air's specific humidity `height` metres above the ground, from the dew point, the
    /// vapour pressure being the saturation vapour pressure over water at the dew point; none
    /// above the last level.
    public func humidity(_ height: Double) -> Double {
        guard levels[0].height + height <= levels[levels.count - 1].height else { return 0 }
        let (index, share) = bracket(height)
        let (a, b) = (levels[index], levels[index + 1])
        let dewPoint = a.dewPoint + share * (b.dewPoint - a.dewPoint)
        return CloudRise.humidity(
            vapourPressure: CloudRise.saturationPressure(temperature: dewPoint),
            pressure: self(height).pressure)
    }

    /// The wind's velocity `height` metres above the ground in the scene's x and y, north being
    /// `north` radians anticlockwise from the x axis: its eastward and northward parts each linear
    /// between levels, and the last level's above it.
    public func wind(_ height: Double, north: Double) -> SIMD2<Double> {
        func velocity(_ level: Level) -> SIMD2<Double> {
            // Blowing from the direction given, clockwise from north: towards the opposite one.
            let from = level.windDirection * .pi / 180
            return -level.windSpeed * SIMD2(sin(from), cos(from))
        }
        let (index, share) = bracket(height)
        let eastNorth =
            velocity(levels[index]) + share * (velocity(levels[index + 1]) - velocity(levels[index]))
        let east = SIMD2(sin(north), -cos(north))
        let northward = SIMD2(cos(north), sin(north))
        return eastNorth.x * east + eastNorth.y * northward
    }
}
