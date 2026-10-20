import Foundation
import simd

// Envelopes: the standing's entries, fields and results for building envelopes' part of a scene.
// Split from EvidentialStanding.swift (emmettl/bombcad-work#50); see that file for the types.

extension StandingTable {
    /// The entries of building envelopes' options; `entry(for:)` sends them here.
    static func envelopeEntry(for option: ModelOption) -> Entry {
        let air: [ResultKind] = [.peakOverpressure, .impulse]
        switch option {
        case .importedEnvelopes:
            return Entry(
                title: "Envelopes from imports", affects: air + [.envelopeExposure], limit: .approximation,
                note:
                    "An import's sampled boxes kept as a stationary envelope, which on the IFC fixtures is the "
                    + "rigid import to the bit; windows and doors are cut as their bounding boxes (under 0.6% on "
                    + "the maps and 0.8% on the surface loading of the duplex); element identities and materials "
                    + "are lost, and nothing deforms or fails.",
                document: "building-envelopes.md#envelopes-from-imports-and-map-data")
        case .mapBuildings:
            return Entry(
                title: "Buildings from map data", affects: air + [.envelopeExposure], limit: .illustrative,
                note:
                    "Footprints from map data extruded as solid blocks to a tagged height, or levels at 3 m, or an "
                    + "assumed two levels: no openings, interiors or roof shapes, and positions and heights as "
                    + "accurate as the map.",
                document: "building-envelopes.md#buildings-from-map-data")
        case .newGlass:
            return Entry(
                title: "New or tested glass", affects: [.envelopeDamage], limit: .approximation,
                note:
                    "Glass judged 1.55 times E1300's strength, as new or tested glass rather than glass weathered "
                    + "in service: the least of Osnes et al.'s fifteen laminated panes' glass, 1.55 to 1.85 times "
                    + "E1300's median, at which their panes crack or hold as measured in 14 of 15, the miss "
                    + "cracking a pane that held. From 1.58 one that cracked (C-02) holds, the unsafe side. At 1.55 "
                    + "E1300's own load resistance is exceeded (1.0 to 1.3 of it), and Beirut's sides with broken "
                    + "glass fall below GEER's beyond 2 to 2.5 km: glass weathers towards E1300's in service, so a plan "
                    + "that relies on new glass holds only while it is new.",
                document: "glass-strength.md")
        case .ventedGlazing:
            return Entry(
                title: "Glazing vented in the air", affects: [.envelopeExposure, .envelopeDamage],
                limit: nil,
                note:
                    "Envelopes' panes break in the air when their one-way glass does (within 0.3 ms on its own "
                    + "loads) and open their windows whole, so the blast fills the rooms and loads the walls from "
                    + "inside; walls, roofs and slabs judged failed open too; the default where it can run. The "
                    + "inside stays illustrative: the detailed "
                    + "references let broken glass go element by element and cannot judge it; against UFC "
                    + "3-340-02's loads through open windows the walls inside come at 0.31 to 1.22 of the UFC's "
                    + "(the back walls within 25%), where the one-way fill gives 0.15 to 0.42. Fragments' "
                    + "perforations open holes through walls, each the fragment's presented area, for want of a "
                    + "cited hole size (UFC 3-340-02 §4-60.1 describes craters wider than the fragment but gives "
                    + "no size): the open area is a lower bound, a cell opening when its holes fill half its "
                    + "face. Concrete past UFC 3-340-02's threshold breach curve (Figure 4-65a, equation 4-179) "
                    + "opens where it is breached, at the blast's arrival there: illustrative; on Hupfauf's "
                    + "contact slabs it breaches all four that did and two of four that held, as the upper "
                    + "bound it is.",
                document: "building-envelopes.md#venting-glazing-that-breaks-in-the-air")
        default:
            preconditionFailure("\(option) is not one of building envelopes' options")
        }
    }

    /// The fields of building envelopes' inputs; part of `fields`.
    static let envelopeFields: [String: Field] = [
        "EnvelopeSource.objectID": .input,
        "EnvelopeSource.kind": .option([.importedEnvelopes, .mapBuildings]),
        "EnvelopeSource.detail": .input,
        "EnvelopeConstruction.objectID": .input,
        "EnvelopeConstruction.walls": .input,
        "EnvelopeConstruction.wallThicknessM": .input,
        "EnvelopeConstruction.roof": .input,
        "EnvelopeConstruction.roofThicknessM": .input,
        "EnvelopeConstruction.reinforcementRatio": .input,
        "EnvelopeConstruction.glassThicknessM": .input,
        "EnvelopeConstruction.laminate": .input,
        "EnvelopeConstruction.film": .input,
        "EnvelopeConstruction.wallLiner": .input,
        "EnvelopeConstruction.glassToughened": .input,
        "EnvelopeConstruction.glassCondition": .option([.newGlass]),
        "EnvelopeConstruction.facadePaneM": .input,
        "EnvelopeConstruction.glazing": .input,
        "EnvelopeConstruction.sideGlazing": .input,
        "EnvelopeConstruction.source": .input,
        "EnvelopeConstruction.detail": .input,
        "EnvelopeConstruction.barsInBothFaces": .input,
        "EnvelopeConstruction.barCoverM": .input,
        "EnvelopeConstruction.concreteStrengthMPa": .input,
        "EnvelopeConstruction.barYieldMPa": .input,
        "EnvelopeConstruction.blockworkGrouted": .input,
        "EnvelopeConstruction.masonryStrengthMPa": .input,
        "EnvelopeConstruction.capMassKgPerM": .input,
        "EnvelopeConstruction.wallSheet": .input,
        "EnvelopeConstruction.roofSheet": .input,
        "EnvelopeConstruction.sheetSpanM": .input,
        "EnvelopeConstruction.sheetContinuous": .input,
        "EnvelopeConstruction.screwsPerM": .input,
        "EnvelopeConstruction.railThicknessM": .input,
    ]
}

extension StandingScene {
    /// Said of the envelopes in a scene with structures, which may move beside them.
    static let envelopesBesideStructures =
        "Beside moving structures, one way: a structure never takes the air at an envelope's faces, and its "
        + "debris passes the envelopes by, neither loading nor damaging them."

    func envelopeDamage() -> ResultStanding {
        let envelopes = inputs.scenario.envelopeObjects.map(\.id)
        let assumed = envelopes.filter { inputs.scenario.envelopeConstruction(for: $0).source == .assumed }
            .count
        let blocks = inputs.scenario.envelopeObjects.filter { object in
            (object.envelope?.solids ?? []).contains { BuildingEnvelope.role($0) == .block }
                && inputs.scenario.envelopeConstruction(for: object.id).facadePaneM.map {
                    $0.x > 0 && $0.y > 0
                } != false
        }.count
        let vented = inputs.ventsGlazing && inputs.scenario.hasEnvelopePanes
        let laminated = envelopes.contains { inputs.scenario.envelopeConstruction(for: $0).laminate != nil }
        let laminatedEvidence =
            laminated
            ? [
                StandingEvidence(
                    "Laminated panes: Osnes et al.'s 15 shock-tube panes, Zhang et al.'s 5 and Hooper's 8 "
                        + "framed windows in the open",
                    "Cracking: every Osnes pane at E1300's median strength, 8 of which held (their new glass "
                        + "1.6 times as strong); cracked panes held, 0.67–0.89 of Osnes's deflection, 1.2–1.7 "
                        + "of Zhang's; all of Hooper's silicone-bonded panes pulled out, as measured, at 0.9–1.5 "
                        + "of his speeds but at 73 mm where his held to 140–209 mm",
                    "building-envelopes.md#laminated-glass")
            ] : []
        let filmed = envelopes.contains { inputs.scenario.envelopeConstruction(for: $0).film != nil }
        let filmEvidence =
            filmed
            ? [
                StandingEvidence(
                    "Security film: 67 shock-tube and arena tests of filmed 1/4\" panes in the open GSA reports "
                        + "of 3M, Solar Gard and ARA",
                    "Wet-glazed: held, condition 2, as 18 of 24 were graded, the rest worse; daylight: held "
                        + "while pushed, gone on the rebound, condition 3a, one class better than 16 of 17 tests; "
                        + "mechanical: pulled out at a vendor's capacity, condition 5, never better than its 26 "
                        + "tests (no open capacity)",
                    "building-envelopes.md#security-film")
            ] : []
        let linerEvidence =
            envelopes.contains { inputs.scenario.envelopeConstruction(for: $0).wallLiner != nil }
            ? [
                StandingEvidence(
                    "Polyurea-lined masonry: Ciornei's lined and bare blockwork walls in the University of Ottawa's "
                        + "shock tube (2012)",
                    "Past the masonry's thickness, 1.3–1.9 times the measured deflection; held through the shot "
                        + "that tore the test's wall (246 mm against its 254 mm, after nine shots); the masonry "
                        + "does not arch, so small shots go several times as far as measured",
                    "building-envelopes.md#polyurea-liners-on-masonry")
            ] : []
        return result(
            .envelopeDamage, .approximation,
            "One way, from each component's load, "
                + (vented
                    ? "with the air seeing each building whole but for its glazing, which opens in the air as "
                        + "it breaks: "
                    : "with the air seeing the building whole and the inside a one-way fill: ")
                + "each on its equivalent uniform load: glass breakage and its time, concrete panels' rotation "
                + "between fixed and simply supported edges, freestanding walls as cantilevers from their foot, "
                + "and profiled steel sheeting between its rails, as approximations; brick panels, "
                + "cross-laminated timber and the inside pressure through broken panes illustrative.",
            evidence: [
                StandingEvidence(
                    "UFC 3-340-02 §2-15.4's loads on the walls inside, through an open front window (16 cases, "
                        + "2–16 psi)",
                    vented
                        ? "Glazing vented: 0.31–1.22 of the UFC's (the back walls 0.74–1.22)"
                        : "The one-way fill, as venting cannot run here: 0.15–0.42 of the UFC's",
                    "validation.md#inside-buildings-against-ufc-3-340-02s-loads-through-openings"),
                StandingEvidence(
                    "UFC 3-340-02's worked examples 3A-5, 3A-6(a) and 4A-1", "Within 1%",
                    "building-envelopes.md#one-way-damage-single-degree-of-freedom"),
                StandingEvidence(
                    "The same buildings free to respond (19 runs, 2–500 kg)",
                    "Glass: all 45 panes the detailed buildings break, a median 0.3 ms later, and 6 more; "
                        + "the walls facing the charge between the fixed and simply supported bounds, roofs "
                        + "and walls beside a failing one beyond both",
                    "building-envelopes.md#one-way-damage-single-degree-of-freedom"),
                StandingEvidence(
                    "Freestanding walls against measurement: Alsubaei's perimeter walls and Keys's brick walls",
                    "On the equivalent load 5 of 7 outcomes as measured, built as tested (6 on the mean); the "
                        + "blockwork's top 28 mm against 28; the half-scale concrete wall 4.3° where light cracking "
                        + "was seen, the safe side (the detailed model 2.1°); the blockwork at 125 kg 9.5° against "
                        + "the 10° that fails it, where it collapsed: the unsafe side",
                    "building-envelopes.md#freestanding-walls"),
                StandingEvidence(
                    "One-way reinforced masonry walls under measured loads (Hayman, 2014)",
                    "1.16–1.91 times the measured mid-height displacement, a level worse on four of five, the "
                        + "one that blew out failed: the safe side",
                    "building-envelopes.md#one-way-walls"),
                StandingEvidence(
                    "Slabs held on their edges against measurement (the contest slab, Reynolds, Wu, Wang, Mendonça)",
                    "Under measured loads the measured peak between the fixed and simply supported bounds on all "
                        + "eight; under the model's own close-in loads, on the equivalent load, Wu's one-face slabs "
                        + "0.91–1.56 of measured (0.52–0.71 on the mean), Wang's clamped panels 0.35–0.47, and "
                        + "Mendonça's two collapses missed",
                    "building-envelopes.md#slabs-held-on-their-edges"),
                StandingEvidence(
                    "ADBLAST's screwed TR84 cladding shot in air (10 tests, 0.5–1.5 kg)",
                    "Profiled sheeting: within 1.0–1.35 of the shell model's deflection under the same load; in "
                        + "the air's load on the strip of ribs it is judged on 0.65–1.09 of measured (the shells "
                        + "0.90–1.35; the whole panel's mean 0.49–1.36); graded heavy to failed where the sheets "
                        + "set but stayed on; the screws held, as measured",
                    "profiled-sheeting.md#against-adblasts-cladding-as-an-envelope"),
                StandingEvidence(
                    "Monk and Clubley's annealed windows in the Shoeburyness tunnel (12 timed panes)",
                    "Every pane broken, as in the tests, at 0.82–1.07 of the measured time and 0.69–1.15 of the "
                        + "deflection", "validation.md#window-glass"),
                StandingEvidence(
                    "ASTM E1300's load resistance of eight annealed panes",
                    "Its stresses within 8%; panes break at 0.57–0.72 of its load resistance (the safe side)",
                    "validation.md#the-threshold-against-astm-e1300"),
                StandingEvidence(
                    "A district against its surveys: Beirut, 2020, 14,169 map buildings at 0.2–1.1 kt",
                    "Glass (converged by 4 m cells) breaks inside 1.25 km where GEER found 0.39–0.84 of "
                        + "street façades damaged, its edge set by the panes assumed; the structure low and "
                        + "not converged: 0.5 m stone cracks where partial collapses were found, concrete "
                        + "hardly damaged where GEER's was D1–D3",
                    "validation.md#a-district-beirut-2020"),
            ] + laminatedEvidence + filmEvidence + linerEvidence,
            assumptions: [
                "Compared with measurement as freestanding and one-way walls, as slabs held on their edges "
                    + "(mostly on two; one panel clamped all round), and glass only under a load far past what "
                    + "breaks it (its threshold against E1300's design resistance); references on one mesh and "
                    + "one air grid.",
                "Reinforced blockwork is judged as a concrete of the masonry's strength, graded by the "
                    + "concrete's limits; a freestanding wall's cap adds only the mass its construction gives.",
                "Profiled steel sheeting spans one way between its rails or purlins by UFC 3-340-02's method for "
                    + "cold-formed panels on its effective section (the maker's, or by its compressed flat's "
                    + "class, a slender one at Winter's width), graded by PDC-TR 06-08's limits for deck whose membrane action its "
                    + "fixings limit, and blown off when the reaction pulling it off its screws, as it comes back "
                    + "out or is sucked, passes what they hold by EN 1993-1-3; on the load on the middle third of "
                    + "its ribs across the span, as they span on their own.",
                "Cross-laminated timber spans one way, elastic–perfectly plastic, its resistance from the mean "
                    + "bending strength with the Ottawa shock tube's dynamic increase, graded by WoodWorks' ductility "
                    + "limits from the Tyndall tests; no envelope-level test of its damage compared.",
                "Each panel alone: frame action, junctions and neighbouring walls are not seen; a panel past "
                    + "2° is flagged as beyond the one-way model.",
                "A component's load is Biggs's equivalent uniform load, its faces weighted by its plastic "
                    + "mechanism's shape from the edges it is held on (held nowhere, taken as held all round).",
                "Concrete is judged whichever way it went furthest, pushed out as pushed in (UFC 3-340-02 "
                    + "§4-26.2), with ASCE/SEI 59-11's limits.",
                "Glass is annealed, on Moore's large-deflection plate, simply supported, breaking at E1300's "
                    + "median strength with the whole pane at its largest stress"
                    + (laminated
                        ? "; laminated glass as one pane of its effective thicknesses (E1300's), which cracks "
                            + "so and is then a membrane at the cracked laminate's plateau tension (Hooper's) "
                            + "until its interlayer's failure strain or its frame's hold is passed: GSA 2 while "
                            + "held, thrown whole when not, never vented in the air."
                        : "."),
                "The glass's hazard is graded by GSA's conditions and ASTM F1642's ratings from where it "
                    + "would land, thrown whole from the pane's middle at its speed on breaking, the load pushing "
                    + "it on, over a 0.9 m sill; no test's fragments compared. A cased charge's fragments hole a "
                    + "pane past Kim et al.'s breaking momentum, breaking it then if first. With glazing vented "
                    + "it opens in the air then, at a time from the fragments flown in still air before the run, "
                    + "independent of the blast's effect on their flight: fine near the charge, where fragments "
                    + "lead the shock. Roof glazing that goes falls to the building's foot without drag, "
                    + "graded at 79 J and 14.9 J, whole if laminated, else by the shard that would reach them; no "
                    + "falling test compared.",
                "Concrete by ASCE/SEI 59-11's limits for single-reinforced slabs; brick cracked or fallen, with "
                    + "no arching, a wall rocking against the weight of its own masonry above it.",
            ]
                + (assumed > 0
                    ? [
                        "\(assumed) of \(envelopes.count) envelopes' construction assumed (0.2 m concrete, 0.3%)."
                    ]
                    : [])
                + (blocks > 0
                    ? [
                        "\(blocks) buildings of solid blocks (as map buildings are) taken to hold a window "
                            + "in each storey of each façade, 1.2 × 1.5 m unless set, judged on the storey's "
                            + "mean load; map buildings' façades also as a mix of panes by their kind and "
                            + "height, assumed (no survey of glazing found), each breaking with E1300's "
                            + "probability, the whole pane at its largest stress."
                    ]
                    : [])
                + (inputs.scenario.structuralObjects.isEmpty ? [] : [Self.envelopesBesideStructures]),
            documents: ["building-envelopes.md#one-way-damage-single-degree-of-freedom"])
    }

    func envelopeExposure() -> ResultStanding {
        result(
            .envelopeExposure, .approximation,
            "Stationary surfaces whose loads come from the air beside them; a wall facing a charge has Kingery–"
                + "Bulmash's reflected impulse; across a district the shock arrives when it was seen, its peak "
                + "on 4 m cells about three quarters of Kingery–Bulmash's.",
            evidence: [
                StandingEvidence(
                    "Surface integration against per-step pressure on the CPU",
                    "Agrees, with suction; uniform "
                        + "pressure cancels", "building-envelopes.md#scope-and-verification"),
                StandingEvidence(
                    "Kingery–Bulmash, a rigid wall facing the charge, on the shipped air",
                    "Reflected impulse 93–113% from 1 m/kg^(1/3) on 0.25 m cells",
                    ValidationTables.burningDocument),
                StandingEvidence(
                    "Beirut, 2020: the shock's arrival at 30 observers 250 m to 2.35 km (Rigby et al.)",
                    "At 0.5 kt a median 0.98 of the times seen, 25 of 27 from 400 m out within 10%; peaks "
                        + "0.68–0.78 of Kingery–Bulmash on 4 m cells",
                    "validation.md#a-district-beirut-2020"),
            ],
            assumptions: [
                "Fixed geometry: no broken windows, deformation, collapse or changing shielding.",
                "Openings and walls thinner than a cell can vanish.",
            ] + (inputs.scenario.structuralObjects.isEmpty ? [] : [Self.envelopesBesideStructures])
                + ((inputs.scenario.importNotes ?? []).contains(MapBuildingReport.clearedChargeNote)
                    ? [
                        MapBuildingReport.clearedChargeNote
                            + " Its walls neither confine the blast nor vent it, and it takes no damage."
                    ] : []),
            documents: ["building-envelopes.md#scope-and-verification"])
    }
}
