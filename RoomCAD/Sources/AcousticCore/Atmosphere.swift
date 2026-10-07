import Foundation

/// Still air through which sound propagates.
public struct Atmosphere: Codable, Equatable, Sendable {
    public var temperatureCelsius: Double
    /// Relative humidity in percent.
    public var relativeHumidity: Double
    public var pressureKilopascals: Double

    public static let standard = Atmosphere(
        temperatureCelsius: 20, relativeHumidity: 50, pressureKilopascals: 101.325)

    public init(temperatureCelsius: Double, relativeHumidity: Double, pressureKilopascals: Double) {
        self.temperatureCelsius = temperatureCelsius
        self.relativeHumidity = relativeHumidity
        self.pressureKilopascals = pressureKilopascals
    }

    var kelvin: Double { temperatureCelsius + 273.15 }

    /// Speed of sound in dry air as an ideal gas, in m/s (343.2 m/s at 20 °C).
    public var soundSpeed: Double { 331.3 * sqrt(kelvin / 273.15) }

    func validate() throws {
        guard (-20...50).contains(temperatureCelsius) else {
            throw AcousticError.invalid("Temperature must be between -20 and 50 °C.")
        }
        guard (0...100).contains(relativeHumidity) else {
            throw AcousticError.invalid("Relative humidity must be between 0 and 100%.")
        }
        guard (50...120).contains(pressureKilopascals) else {
            throw AcousticError.invalid("Pressure must be between 50 and 120 kPa.")
        }
    }

    /// Pure-tone attenuation by atmospheric absorption in dB/m, from ISO 9613-1:1993, equations 3 to 5
    /// and annex B for the saturation vapour pressure.
    public func absorptionDecibelsPerMetre(frequency f: Double) -> Double {
        let referencePressure = 101.325
        let referenceTemperature = 293.15
        let triplePoint = 273.16
        let t = kelvin
        let pressureRatio = pressureKilopascals / referencePressure
        let saturation = pow(10, -6.8346 * pow(triplePoint / t, 1.261) + 4.6151)
        // Molar concentration of water vapour, in percent.
        let h = relativeHumidity * saturation / pressureRatio
        let tr = t / referenceTemperature
        let oxygen = pressureRatio * (24 + 4.04e4 * h * (0.02 + h) / (0.391 + h))
        let nitrogen = pressureRatio * pow(tr, -0.5) * (9 + 280 * h * exp(-4.170 * (pow(tr, -1.0 / 3) - 1)))
        let f2 = f * f
        return 8.686 * f2
            * (1.84e-11 / pressureRatio * sqrt(tr)
                + pow(tr, -2.5)
                * (0.01275 * exp(-2239.1 / t) / (oxygen + f2 / oxygen)
                    + 0.1068 * exp(-3352.0 / t) / (nitrogen + f2 / nitrogen)))
    }

    /// Pressure-amplitude attenuation in nepers per metre, so amplitude falls as `exp(-value * distance)`.
    public func amplitudeAttenuationPerMetre(frequency: Double) -> Double {
        absorptionDecibelsPerMetre(frequency: frequency) * log(10) / 20
    }
}
