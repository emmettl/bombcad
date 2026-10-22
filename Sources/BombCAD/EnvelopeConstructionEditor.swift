import BlastCore
import SwiftUI

/// An envelope's construction beyond its walls' kind, for its one-way damage: the walls'
/// thickness and bars, their strengths, reinforced blockwork's grout, a cap carried on a
/// freestanding wall's top, and the roof, concrete or profiled steel sheeting, with the sheets'
/// profiles, the spacing of the rails and purlins they span and their screws; the glass,
/// toughened or with security film; a polyurea liner on masonry walls. The air never sees any of
/// it.
struct EnvelopeConstructionEditor: View {
    let model: SimulationModel
    let id: UUID
    @State private var isExpanded: Bool

    init(model: SimulationModel, id: UUID, isExpanded: Bool = false) {
        self.model = model
        self.id = id
        _isExpanded = State(initialValue: isExpanded)
    }

    var body: some View {
        let construction = model.settings.scenario.envelopeConstruction(for: id)
        let reinforced =
            construction.walls == .reinforcedConcrete || construction.walls == .reinforcedBlockwork
        let sheeted =
            construction.walls == .profiledSteelSheeting || construction.roof == .profiledSteelSheeting
        DisclosureGroup("Construction", isExpanded: $isExpanded) {
            Picker(
                "Roof",
                selection: Binding(get: { construction.roof }, set: { kind in edit { $0.roof = kind } })
            ) {
                ForEach(
                    [
                        EnvelopeConstruction.Kind.reinforcedConcrete, .profiledSteelSheeting,
                        .crossLaminatedTimber,
                    ],
                    id: \.self
                ) {
                    Text($0.label).tag($0)
                }
            }
            .help("What the roof (and any floor slabs) are built of.")
            if construction.walls != .profiledSteelSheeting {
                number("Wall thickness", "m", Double(construction.wallThicknessM)) { value in
                    edit { $0.wallThicknessM = Float(max(value, 0.01)) }
                }
            }
            if construction.roof == .crossLaminatedTimber {
                number("Roof thickness", "m", Double(construction.roofThicknessM)) { value in
                    edit { $0.roofThicknessM = Float(max(value, 0.05)) }
                }
                .help("Cross-laminated timber, its lamellae about 35 mm each.")
            }
            if sheeted {
                if construction.walls == .profiledSteelSheeting {
                    sheetPicker("Wall sheets", construction.sheet(roof: false)) { name in
                        edit { $0.wallSheet = name }
                    }
                }
                if construction.roof == .profiledSteelSheeting {
                    sheetPicker("Roof sheets", construction.sheet(roof: true)) { name in
                        edit { $0.roofSheet = name }
                    }
                }
                number("Rails and purlins apart", "m", Double(construction.sheetSpanM ?? 1.8)) { value in
                    edit { $0.sheetSpanM = Float(max(value, 0.3)) }
                }
                .help(
                    "The span of the sheets between the rails (walls) or purlins (roof) they are screwed to.")
                Toggle(
                    "Continuous over them",
                    isOn: Binding(
                        get: { construction.sheetContinuous ?? true },
                        set: { on in edit { $0.sheetContinuous = on ? nil : false } })
                )
                .help("Sheets over several rails or purlins; off, each sheet a single span.")
                number("Screws at each rail", "per m", Double(construction.screwsPerM ?? 3)) { value in
                    edit { $0.screwsPerM = Float(max(value, 0.5)) }
                }
                number(
                    "Rails' and purlins' steel", "mm", Double((construction.railThicknessM ?? 0.002) * 1000)
                ) {
                    value in
                    edit { $0.railThicknessM = Float(max(value, 0.5)) / 1000 }
                }
                .help("The thickness of the cold-formed rails and purlins the screws hold in.")
            }
            if reinforced {
                number("Bars, each way", "%", Double(construction.reinforcementRatio) * 100) { value in
                    edit { $0.reinforcementRatio = Float(max(value, 0)) / 100 }
                }
                Toggle(
                    "Bars in both faces",
                    isOn: Binding(
                        get: { construction.barsInBothFaces == true },
                        set: { on in edit { $0.barsInBothFaces = on ? true : nil } })
                )
                .help("A mat in each face, the bars shared between them; off, one mat at mid-thickness.")
                if construction.barsInBothFaces == true {
                    number("Cover to the bars' centres", "m", Double(construction.barCoverM ?? 0.03)) {
                        value in
                        edit { $0.barCoverM = Float(max(value, 0)) }
                    }
                }
                number("Bars' yield", "MPa", Double(construction.barYieldMPa ?? 500)) { value in
                    edit { $0.barYieldMPa = Float(max(value, 1)) }
                }
            }
            if construction.walls == .reinforcedConcrete {
                number("Concrete strength", "MPa", Double(construction.concreteStrengthMPa ?? 30)) { value in
                    edit { $0.concreteStrengthMPa = Float(max(value, 1)) }
                }
            }
            if construction.walls == .reinforcedBlockwork {
                let grouted = construction.blockworkGrouted ?? true
                Toggle(
                    "Fully grouted",
                    isOn: Binding(
                        get: { grouted }, set: { on in edit { $0.blockworkGrouted = on ? nil : false } })
                )
                .help("Grout in every cell; off, the cells hold only the bars (hollow blockwork).")
                number(
                    "Masonry strength", "MPa", Double(construction.masonryStrengthMPa ?? (grouted ? 10 : 3))
                ) { value in
                    edit { $0.masonryStrengthMPa = Float(max(value, 0.5)) }
                }
            }
            if construction.walls == .unreinforcedMasonry {
                Toggle(
                    "Polyurea liner",
                    isOn: Binding(
                        get: { construction.wallLiner != nil },
                        set: { on in edit { $0.wallLiner = on ? .polyurea(mm: 3) : nil } })
                )
                .help(
                    "Polyurea sprayed on the walls' inside face and lapped onto their supports, holding the "
                        + "masonry once it cracks until the liner tears.")
                if let liner = construction.wallLiner {
                    number("Liner thickness", "mm", liner.thickness * 1000) { value in
                        edit { $0.wallLiner?.thickness = max(value, 0.5) / 1000 }
                    }
                }
                Toggle(
                    "Arching between returns",
                    isOn: Binding(
                        get: { construction.masonryArching == true },
                        set: { on in edit { $0.masonryArching = on ? true : nil } })
                )
                .help(
                    "Walls held at both upright edges (cross walls, party walls, corners) resist by arching "
                        + "across their width once cracked, the ends taken as not giving. Off: no arching (the default)."
                )
            }
            Picker(
                "Glass",
                selection: Binding(
                    get: { construction.glassCondition ?? .asDesigned },
                    set: { condition in edit { $0.setGlassCondition(condition) } })
            ) {
                ForEach(GlassCondition.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .help(
                "As designed: E1300's strength, for glass weathered in service (the default). New or tested: "
                    + "1.55 times it, the least of Osnes et al.'s tested panes; it holds only while the glass is new."
            )
            if construction.laminate == nil {
                Toggle(
                    "Toughened glass",
                    isOn: Binding(
                        get: { construction.glassToughened == true },
                        set: { on in edit { $0.glassToughened = on ? true : nil } })
                )
                .help("Thermally toughened panes, breaking at four times annealed glass's strength (E1300).")
                Picker(
                    "Security film",
                    selection: Binding(
                        get: { construction.film?.anchorage },
                        set: { anchorage in
                            edit { construction in
                                construction.film = anchorage.map { anchorage in
                                    var film = construction.film ?? .mils(8, anchorage: anchorage)
                                    film.anchorage = anchorage
                                    return film
                                }
                            }
                        })
                ) {
                    Text("None").tag(SecurityFilm.Anchorage?.none)
                    ForEach(SecurityFilm.Anchorage.allCases, id: \.self) {
                        Text($0.label.prefix(1).capitalized + $0.label.dropFirst()).tag(Optional($0))
                    }
                }
                .help(
                    "Polyester film on the panes' inner face, holding their fragments once the glass cracks; "
                        + "how it is held at the frame decides whether the pane stays.")
                if let film = construction.film {
                    number("Film thickness", "mil", film.thickness / 25.4e-6) { value in
                        edit { $0.film?.thickness = max(value, 1) * 25.4e-6 }
                    }
                }
            }
            if reinforced {
                number("Cap on a freestanding wall", "kg/m", Double(construction.capMassKgPerM ?? 0)) {
                    value in
                    edit { $0.capMassKgPerM = value > 0 ? Float(value) : nil }
                }
                .help(
                    "A cap or canopy carried on the top of a wall that stands free: mass moving with the top, "
                        + "not a support.")
            }
        }
        .font(.callout)
    }

    private func sheetPicker(
        _ title: String, _ current: SheetProfile, set: @escaping @MainActor (String) -> Void
    ) -> some View {
        Picker(title, selection: Binding(get: { current.name }, set: set)) {
            ForEach(
                SheetProfile.library.filter { $0.yieldStress >= 250e6 && $0.thickness < 0.0015 }, id: \.name
            ) {
                Text($0.name).tag($0.name)
            }
        }
        .help("The sheets' profile, from cited makers' tables (docs/profiled-sheeting.md).")
    }

    private func edit(_ change: (inout EnvelopeConstruction) -> Void) {
        model.editEnvelopeConstruction(id: id, change)
    }

    private func number(
        _ title: String, _ unit: String, _ value: Double, set: @escaping @MainActor (Double) -> Void
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField(
                    "", value: Binding(get: { value }, set: set),
                    format: .number.precision(.fractionLength(0...3))
                )
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
                Text(unit).foregroundStyle(.secondary)
            }
        }
    }
}
