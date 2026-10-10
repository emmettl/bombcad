import BlastCore
import SwiftUI
import simd

/// Exact preset matching keeps a custom law visible without replacing it with a nearby preset.
struct AnchorageEditor: View {
    let title: String
    @Binding var law: Anchorage?
    /// Whether the joint may face another way than down (a support region's, not the ground's).
    var turns = false

    private var choice: String {
        if law == nil { return BaseConnection.clamped.rawValue }
        return BaseConnection.allCases.first { $0.anchorage == law }?.rawValue ?? "custom"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Picker(
                title,
                selection: Binding(
                    get: { choice },
                    set: { value in
                        if let preset = BaseConnection(rawValue: value) { law = preset.anchorage }
                    })
            ) {
                ForEach(BaseConnection.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                if choice == "custom" { Text("Custom connection").tag("custom") }
            }
            .labelsHidden().accessibilityLabel(title)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if law != nil && turns {
            Picker(
                "Joint faces",
                selection: Binding(
                    get: { law?.jointNormal != nil ? "angle" : (law?.side ?? .below).rawValue },
                    set: { value in
                        guard var candidate = law else { return }
                        if let side = JointSide(rawValue: value) {
                            candidate.side = side == .below ? nil : side
                            candidate.jointNormal = nil
                        } else {
                            candidate.jointNormal = candidate.across
                            candidate.side = nil
                        }
                        law = candidate
                    })
            ) {
                ForEach(JointSide.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                Text("At an angle").tag("angle")
            }
            .accessibilityLabel("Joint faces")
            if law?.jointNormal != nil {
                angle("Support from below", \.tilt, range: 0...180)
                angle("Support towards", \.azimuth, range: -180...360)
                Text(
                    "The support lies at this angle from straight below the body (90° beside it, 180° over it), towards this bearing in plan from +x. Its joint ties the faces of the staircase that stands for it, each over its share projected on the joint."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Toggle(
                "Ties two parts across a gap",
                isOn: Binding(
                    get: { law?.betweenParts == true },
                    set: { on in
                        guard var candidate = law else { return }
                        candidate.betweenParts = on ? true : nil
                        if on { candidate.footing = nil }
                        law = candidate
                    }))
            if law?.betweenParts == true {
                Text(
                    "The joint ties the body to another of its parts, both moving, instead of to fixed ground: each node on faces facing the joint to the node straight across the gap, as a beam seated on a corbel or a panel against its frame. Leave a gap of at least one element between the parts, and span it with the region; the seat ends where the other part's faces in the region end, and a node that slides past it is off its seat for good. Solid elements only."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        if law != nil {
            DisclosureGroup("Connection properties") {
                number("Tensile strength", "MPa", \.tensileStrength, scale: 1e6)
                number("Strength plateau opening", "mm", \.tensionPlateau, scale: 0.001)
                number("Final opening", "mm", \.tensionOpening, scale: 0.001)
                number("Shear cohesion", "MPa", \.cohesion, scale: 1e6)
                number("Cohesion loss slip", "mm", \.cohesionSlip, scale: 0.001)
                number("Friction coefficient", "", \.friction, scale: 1)
                bearing()
                stiffness("Normal stiffness", \.normalStiffness)
                stiffness("Shear stiffness", \.shearStiffness)
                Text(
                    "Automatic stiffness uses the structure’s default material and element size. Strength and friction apply per unit bearing area; these presets are modelling assumptions."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            if law?.betweenParts != true { footing() }
        }
    }

    /// A rigid footing between the base and the soil, and the soil under it. Its rows read and
    /// write through `law?.footing`, so that a row still drawn as the footing is removed (or
    /// undone) reads a default instead of a footing that has gone.
    @ViewBuilder private func footing() -> some View {
        Toggle(
            "On a footing",
            isOn: Binding(
                get: { law?.footing != nil },
                set: { on in
                    guard var candidate = law else { return }
                    candidate.footing = on ? Footing() : nil
                    law = candidate
                }))
        if law?.footing != nil {
            DisclosureGroup("Footing and soil") {
                footingNumber("Overhang across x", "m", \.overhang.x, scale: 1)
                footingNumber("Overhang across y", "m", \.overhang.y, scale: 1)
                footingNumber("Footing thickness", "m", \.thickness, scale: 1)
                footingNumber("Footing density", "kg/m³", \.density, scale: 1)
                footingNumber("Soil shear modulus", "MPa", \.soil.material.shearModulus, scale: 1e6)
                footingNumber("Soil Poisson’s ratio", "", \.soil.material.poissonRatio, scale: 1)
                footingNumber("Soil density", "kg/m³", \.soil.material.density, scale: 1)
                footingNumber("Soil friction", "", \.soil.friction, scale: 1)
                footingOptional(
                    "Unlimited soil bearing", "Soil bearing capacity", "kPa", \.soil.bearingCapacity,
                    initial: 600e3,
                    scale: 1e3)
                Toggle(
                    "Soil mass and radiation damping",
                    isOn: Binding(
                        get: { law?.footing?.soil.radiationDamping ?? false },
                        set: { value in
                            guard var candidate = law, candidate.footing != nil else { return }
                            candidate.footing?.soil.radiationDamping = value
                            law = candidate
                        }))
                footingOptional(
                    "Soil all the way down", "Layer depth", "m", \.soil.layerDepth, initial: 3, scale: 1)
                if law?.footing?.soil.layerDepth != nil {
                    Picker(
                        "Beneath the layer",
                        selection: Binding(
                            get: { law?.footing?.soil.beneath == nil },
                            set: { rock in
                                guard var candidate = law, candidate.footing != nil else { return }
                                candidate.footing?.soil.beneath = rock ? nil : .softRock
                                law = candidate
                            })
                    ) {
                        Text("Rock").tag(true)
                        Text("Other ground").tag(false)
                    }
                    if law?.footing?.soil.beneath != nil {
                        beneathNumber("Shear modulus beneath", "MPa", \.shearModulus, scale: 1e6)
                        beneathNumber("Poisson’s ratio beneath", "", \.poissonRatio, scale: 1)
                        beneathNumber("Density beneath", "kg/m³", \.density, scale: 1)
                    }
                }
                Text(
                    "The footing is rigid and spans the base it carries, widened by the overhang on each side. The soil defaults to a medium dense sand; with its mass it radiates energy as Wolf’s cones do, and a layer sends echoes back from its base."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func field(
        _ title: String, _ unit: String, get: @escaping () -> Float?, set: @escaping (Float) -> Void,
        scale: Float, positive: Bool = false
    ) -> some View {
        LabeledContent(title) {
            HStack {
                TextField(
                    title,
                    value: Binding(
                        get: { Double((get() ?? 0) / scale) },
                        set: { value in
                            guard value.isFinite, positive ? value > 0 : value >= 0,
                                Float(value * Double(scale)).isFinite
                            else { return }
                            set(Float(value * Double(scale)))
                        }), format: .number.precision(.fractionLength(0...4))
                )
                .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 85)
                Text(unit).foregroundStyle(.secondary)
            }
        }
    }

    private func footingNumber(
        _ title: String, _ unit: String, _ key: WritableKeyPath<Footing, Float>, scale: Float
    ) -> some View {
        field(
            title, unit, get: { law?.footing?[keyPath: key] },
            set: { value in
                guard var candidate = law, candidate.footing != nil else { return }
                candidate.footing?[keyPath: key] = value
                law = candidate
            }, scale: scale)
    }

    private func beneathNumber(
        _ title: String, _ unit: String, _ key: WritableKeyPath<SoilMaterial, Float>, scale: Float
    ) -> some View {
        field(
            title, unit, get: { law?.footing?.soil.beneath?[keyPath: key] },
            set: { value in
                guard var candidate = law, candidate.footing?.soil.beneath != nil else { return }
                candidate.footing?.soil.beneath?[keyPath: key] = value
                law = candidate
            }, scale: scale)
    }

    /// A value that may be absent: a toggle for its absence, and a field for it when present.
    private func footingOptional(
        _ absent: String, _ title: String, _ unit: String, _ key: WritableKeyPath<Footing, Float?>,
        initial: Float, scale: Float
    ) -> some View {
        VStack(alignment: .leading) {
            Toggle(
                absent,
                isOn: Binding(
                    get: { law?.footing?[keyPath: key] == nil },
                    set: { none in
                        guard var candidate = law, candidate.footing != nil else { return }
                        candidate.footing?[keyPath: key] = none ? nil : initial
                        law = candidate
                    }))
            if law?.footing?[keyPath: key] != nil {
                field(
                    title, unit, get: { law?.footing?[keyPath: key] ?? initial },
                    set: { value in
                        guard var candidate = law, candidate.footing != nil else { return }
                        candidate.footing?[keyPath: key] = value
                        law = candidate
                    }, scale: scale, positive: true)
            }
        }
    }

    /// One of the angles of a joint at an angle, in degrees: from straight below to the support,
    /// or its bearing in plan.
    private func angle(
        _ title: String, _ key: WritableKeyPath<JointAngles, Float>, range: ClosedRange<Double>
    )
        -> some View
    {
        LabeledContent(title) {
            HStack {
                TextField(
                    title,
                    value: Binding(
                        get: { Double(JointAngles(law?.across ?? SIMD3(0, 0, 1))[keyPath: key]) },
                        set: { value in
                            guard value.isFinite, range.contains(value), var candidate = law else { return }
                            var angles = JointAngles(candidate.across)
                            angles[keyPath: key] = Float(value)
                            candidate.jointNormal = angles.normal
                            law = candidate
                        }), format: .number.precision(.fractionLength(0...2))
                )
                .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 85)
                Text("°").foregroundStyle(.secondary)
            }
        }
    }

    private func number(
        _ title: String, _ unit: String, _ key: WritableKeyPath<Anchorage, Float>, scale: Float
    ) -> some View {
        LabeledContent(title) {
            HStack {
                TextField(
                    title,
                    value: Binding(
                        get: { Double((law?[keyPath: key] ?? 0) / scale) },
                        set: { value in
                            guard value.isFinite, value >= 0, Float(value * Double(scale)).isFinite,
                                var candidate = law
                            else { return }
                            candidate[keyPath: key] = Float(value * Double(scale))
                            // Keep the envelope ordered as either opening is edited.
                            if key == \.tensionPlateau {
                                candidate.tensionOpening = max(
                                    candidate.tensionOpening, candidate.tensionPlateau)
                            }
                            if key == \.tensionOpening {
                                candidate.tensionPlateau = min(
                                    candidate.tensionPlateau, candidate.tensionOpening)
                            }
                            law = candidate
                        }), format: .number.precision(.fractionLength(0...5))
                )
                .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 85)
                Text(unit).foregroundStyle(.secondary)
            }
        }
    }

    /// The ground's bearing capacity: unlimited, or a pressure past which it yields and the base
    /// settles for good.
    private func bearing() -> some View {
        VStack(alignment: .leading) {
            Toggle(
                "Unlimited bearing",
                isOn: Binding(
                    get: { law?.bearingCapacity == nil },
                    set: { unlimited in
                        guard var candidate = law else { return }
                        candidate.bearingCapacity = unlimited ? nil : 600e3
                        law = candidate
                    }))
            if law?.bearingCapacity != nil {
                LabeledContent("Bearing capacity (kPa)") {
                    TextField(
                        "Bearing capacity",
                        value: Binding(
                            get: { Double(law?.bearingCapacity ?? 600e3) / 1e3 },
                            set: { value in
                                guard value.isFinite, value > 0, Float(value * 1e3).isFinite,
                                    var candidate = law
                                else { return }
                                candidate.bearingCapacity = Float(value * 1e3)
                                law = candidate
                            }), format: .number.precision(.fractionLength(0...3))
                    )
                    .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 85)
                }
            }
        }
    }

    private func stiffness(_ title: String, _ key: WritableKeyPath<Anchorage, Float?>) -> some View {
        VStack(alignment: .leading) {
            Toggle(
                "Automatic \(title.lowercased())",
                isOn: Binding(
                    get: { law?[keyPath: key] == nil },
                    set: { automatic in
                        guard var candidate = law else { return }
                        candidate[keyPath: key] = automatic ? nil : 1e9
                        law = candidate
                    }))
            if law?[keyPath: key] != nil {
                LabeledContent(title + " (GPa/m)") {
                    TextField(
                        title,
                        value: Binding(
                            get: { Double(law?[keyPath: key] ?? 1e9) / 1e9 },
                            set: { value in
                                guard value.isFinite, value > 0, Float(value * 1e9).isFinite,
                                    var candidate = law
                                else { return }
                                candidate[keyPath: key] = Float(value * 1e9)
                                law = candidate
                            }), format: .number.precision(.fractionLength(0...5))
                    )
                    .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 85)
                }
            }
        }
    }
}

/// A joint's normal as the angles the editor shows, in degrees: the support's angle from straight
/// below the body, and its bearing in plan from +x.
struct JointAngles: Equatable {
    var tilt: Float
    var azimuth: Float

    init(_ normal: SIMD3<Float>) {
        let unit = normal / max(simd_length(normal), 1e-12)
        tilt = acos(max(-1, min(1, unit.z))) * 180 / .pi
        let plan = SIMD2(-unit.x, -unit.y)
        azimuth = simd_length(plan) < 1e-6 ? 0 : atan2(plan.y, plan.x) * 180 / .pi
    }

    var normal: SIMD3<Float> { Anchorage.normal(tilt: tilt * .pi / 180, azimuth: azimuth * .pi / 180) }
}
