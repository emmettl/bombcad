import Foundation

/// A whole room: size, every surface's material and where the source and listener are.
///
/// Absorption always comes from `MaterialPresets`. Scattering comes from a published scattering preset
/// where one fits and is otherwise illustrative, said so in each material's reference.
public struct RoomPreset: Identifiable, Sendable {
    public var id: String
    public var name: String
    public var summary: String
    public var size: SIMD3<Double>
    /// For each surface, an absorption preset ID and its scattering.
    var surfaces: [Surface: (absorption: String, scattering: Scattering)]
    /// Source and listener positions as fractions of the room's length and width, at fixed heights.
    var source: SIMD2<Double> = [0.25, 0.45]
    var listener: SIMD2<Double> = [0.65, 0.55]
    var sourceHeight = 1.5

    enum Scattering: Sendable {
        /// A published scattering preset, by ID.
        case published(String)
        /// Values chosen to suggest the surface, without a measurement behind them.
        case illustrative([Double], String)
    }

    /// Scattering for plain walls with some detail: low at low frequencies, rising to 0.2.
    static let plainWalls = Scattering.illustrative(
        [0.05, 0.05, 0.08, 0.1, 0.12, 0.15, 0.2, 0.2], "plain surface with some detail")
    /// A furnished room's floor and walls.
    static let furnished = Scattering.illustrative(
        [0.1, 0.15, 0.25, 0.35, 0.45, 0.5, 0.55, 0.55], "furniture and fittings")
    /// Large smooth surfaces.
    static let smooth = Scattering.illustrative(
        [0.02, 0.03, 0.05, 0.05, 0.08, 0.1, 0.1, 0.1], "large smooth surface")
    /// Rows of pews or chairs.
    static let pews = Scattering.illustrative(
        [0.2, 0.3, 0.4, 0.5, 0.6, 0.6, 0.6, 0.6], "rows of seating")
    /// Walls with mouldings, pilasters or panelling.
    static let ornate = Scattering.illustrative(
        [0.1, 0.2, 0.3, 0.4, 0.5, 0.5, 0.5, 0.5], "mouldings and panelling")

    /// The room's material for `surface`.
    func material(_ surface: Surface) -> SurfaceMaterial {
        let choice = surfaces[surface]!
        let absorption = MaterialPresets.absorption.first { $0.id == choice.absorption }!
        var material = SurfaceMaterial.uniform(0, name: "").applying(absorption: absorption)
        switch choice.scattering {
        case .published(let id):
            material = material.applying(scattering: MaterialPresets.scattering.first { $0.id == id }!)
        case .illustrative(let values, let description):
            material.scattering = values
            material.reference += " Scattering: illustrative, \(description)."
        }
        return material
    }

    /// `settings` with this room, its source and two listeners, and a duration and reflection order that
    /// fit its reverberation. Sample rate, air, low cut, rays, seed and content are kept, as are the
    /// identities and names of the source and the first two receivers.
    public func applied(to settings: RoomResponseSettings) -> RoomResponseSettings {
        var result = settings
        var room = ShoeboxRoom(size: size, material: .rigid)
        for surface in Surface.allCases { room[surface] = material(surface) }
        result.room = room
        result.source.position = [source.x * size.x, source.y * size.y, min(sourceHeight, 0.6 * size.z)]
        let centre = SIMD3(listener.x * size.x, listener.y * size.y, min(1.2, 0.5 * size.z))
        let spread = min(0.6, 0.15 * size.y)
        let names = ["Left", "Right"]
        result.receivers = (0..<2).map { index in
            let existing = index < settings.receivers.count ? settings.receivers[index] : nil
            var position = centre
            position.y += index == 0 ? spread / 2 : -spread / 2
            return RoomPoint(
                id: existing?.id ?? UUID(), name: existing?.name ?? names[index], position: position)
        }
        // Longer than the slowest band's Eyring time from 125 Hz to 4 kHz, which rooms that are not
        // diffuse exceed.
        let times = room.eyringReverberationTime(atmosphere: settings.atmosphere, airAbsorption: true)
        let slowest = times[1...6].compactMap { $0 }.max() ?? 1
        result.duration = min(max(1.5 * slowest, 0.5), 8).rounded(toPlaces: 1)
        // Enough order for the shortest dimension, capped so the image sources stay quick; scattering
        // carries the late energy that a cap omits.
        let reach = result.duration * settings.atmosphere.soundSpeed
        result.maximumReflectionOrder = min(120, Int((reach / size.min()).rounded(.up)) + 2)
        return result
    }
}

extension Double {
    fileprivate func rounded(toPlaces places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (self * scale).rounded(.up) / scale
    }
}

public enum RoomPresets {
    public static let all: [RoomPreset] = [
        RoomPreset(
            id: "living-room", name: "Living room",
            summary: "5.5 × 4.2 × 2.5 m: carpet, plastered walls and ceiling, curtained window",
            size: [5.5, 4.2, 2.5],
            surfaces: [
                .floor: ("carpet_tufted_9m", RoomPreset.furnished),
                .ceiling: ("hard_surface", RoomPreset.plainWalls),
                .west: ("hard_surface", RoomPreset.furnished), .east: ("hard_surface", RoomPreset.furnished),
                .south: ("hard_surface", RoomPreset.furnished),
                .north: ("curtains_cotton_0.5", RoomPreset.plainWalls),
            ]),
        RoomPreset(
            id: "office", name: "Office",
            summary: "6 × 5 × 2.8 m: carpet tiles, suspended tile ceiling, plasterboard, a glazed wall",
            size: [6, 5, 2.8],
            surfaces: [
                .floor: ("carpet_6mm_closed_cell_foam", .published("classroom_tables")),
                .ceiling: ("ceiling_fissured_tile", RoomPreset.plainWalls),
                .west: ("plasterboard", RoomPreset.furnished), .east: ("plasterboard", RoomPreset.furnished),
                .north: ("plasterboard", RoomPreset.furnished), .south: ("glass_window", RoomPreset.smooth),
            ]),
        RoomPreset(
            id: "classroom", name: "Classroom",
            summary: "9 × 7 × 3.2 m: linoleum under rows of desks, tile ceiling, hard walls, windows",
            size: [9, 7, 3.2],
            surfaces: [
                .floor: ("linoleum_on_concrete", .published("classroom_tables")),
                .ceiling: ("ceiling_fissured_tile", RoomPreset.plainWalls),
                .west: ("hard_surface", RoomPreset.furnished), .east: ("hard_surface", RoomPreset.furnished),
                .south: ("hard_surface", RoomPreset.furnished), .north: ("glass_window", RoomPreset.smooth),
            ],
            source: [0.12, 0.5], listener: [0.6, 0.5]),
        RoomPreset(
            id: "tiled-bathroom", name: "Tiled bathroom",
            summary: "2.6 × 2 × 2.4 m: ceramic tiles throughout, plastered ceiling; empty and very live",
            size: [2.6, 2, 2.4],
            surfaces: [
                .floor: ("ceramic_tiles", RoomPreset.plainWalls),
                .ceiling: ("hard_surface", RoomPreset.smooth),
                .west: ("ceramic_tiles", RoomPreset.plainWalls),
                .east: ("ceramic_tiles", RoomPreset.plainWalls),
                .south: ("ceramic_tiles", RoomPreset.plainWalls),
                .north: ("ceramic_tiles", RoomPreset.plainWalls),
            ],
            source: [0.3, 0.4], listener: [0.7, 0.55]),
        RoomPreset(
            id: "vocal-booth", name: "Vocal booth",
            summary: "2.4 × 2 × 2.3 m: fabric-covered rockwool panels, foam ceiling, carpet; very dead",
            size: [2.4, 2, 2.3],
            surfaces: [
                .floor: ("carpet_tufted_9.5mm", RoomPreset.plainWalls),
                .ceiling: ("ceiling_melamine_foam", RoomPreset.plainWalls),
                .west: ("panel_fabric_covered_6pcf", RoomPreset.plainWalls),
                .east: ("panel_fabric_covered_6pcf", RoomPreset.plainWalls),
                .south: ("panel_fabric_covered_6pcf", RoomPreset.plainWalls),
                .north: ("panel_fabric_covered_6pcf", RoomPreset.plainWalls),
            ],
            source: [0.35, 0.5], listener: [0.65, 0.5]),
        RoomPreset(
            id: "concrete-hall", name: "Concrete hall",
            summary: "24 × 16 × 5 m: bare rough concrete, like an empty car park level",
            size: [24, 16, 5],
            surfaces: [
                .floor: ("concrete_floor", RoomPreset.smooth),
                .ceiling: ("rough_concrete", RoomPreset.smooth),
                .west: ("rough_concrete", RoomPreset.smooth), .east: ("rough_concrete", RoomPreset.smooth),
                .south: ("rough_concrete", RoomPreset.smooth), .north: ("rough_concrete", RoomPreset.smooth),
            ]),
        RoomPreset(
            id: "chamber-hall", name: "Chamber music hall",
            summary: "28 × 18 × 11 m: audience in upholstered seats, wooden linings, hard ceiling",
            size: [28, 18, 11],
            surfaces: [
                .floor: ("audience_upholstered_chairs_1", .published("theatre_audience")),
                .ceiling: ("hard_surface", RoomPreset.ornate),
                .west: ("wooden_lining", RoomPreset.ornate), .east: ("wooden_lining", RoomPreset.ornate),
                .south: ("wooden_lining", RoomPreset.ornate), .north: ("wooden_lining", RoomPreset.ornate),
            ],
            source: [0.1, 0.5], listener: [0.55, 0.5], sourceHeight: 2),
        RoomPreset(
            id: "stone-church", name: "Stone church",
            summary: "36 × 14 × 16 m: limestone walls and vault, wooden pews over the floor",
            size: [36, 14, 16],
            surfaces: [
                .floor: ("chairs_wooden", RoomPreset.pews), .ceiling: ("limestone_wall", RoomPreset.ornate),
                .west: ("limestone_wall", RoomPreset.ornate), .east: ("limestone_wall", RoomPreset.ornate),
                .south: ("limestone_wall", RoomPreset.ornate), .north: ("limestone_wall", RoomPreset.ornate),
            ],
            source: [0.1, 0.5], listener: [0.5, 0.5], sourceHeight: 2),
    ]
}
