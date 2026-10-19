import Foundation

extension ThermalExposure {
    /// The irradiance from `frame`'s fireball at `points`, which need not lie on the scene's
    /// surfaces: instruments aimed at a fireball, say, far beyond the air's domain. Each is
    /// reckoned as a receiver on the scene would be, by the description's model, with the
    /// ground and the scene's solids in the way, W/m².
    public func irradiance(_ frame: FireballFrame, at points: [ThermalReceiver]) -> [Float] {
        guard !points.isEmpty else { return [] }
        if let medium = medium(frame), let march {
            return march.irradiance(medium, receivers: ThermalReceiverSet(points), occluded: true)
        }
        guard frame.volume > 0, frame.temperature > 0 else {
            return [Float](repeating: 0, count: points.count)
        }
        let power = Float(Double(spec.emissivity) * Self.stefanBoltzmann * pow(Double(frame.temperature), 4))
        return points.map { irradiance(at: $0, frame, power: power) }
    }
}
