import BlastCore
import BlastRender
import Foundation
import Metal
import SwiftUI
import simd

/// The scene's freestanding objects' last computed motion, and the time the view shows it at.
@MainActor
@Observable
final class FreestandingMotionState {
    var motion: FreestandingMotion?
    /// Seconds after detonation shown in the 3D view; nil shows the objects where they were placed.
    var time: Double?
    /// Simulated seconds reached while computing; nil when idle.
    var progress: Double?
    var errorMessage: String?
    var duration = 1.5
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var stop = StopFlag()

    final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        var isStopped: Bool { lock.withLock { stopped } }
        func set() { lock.withLock { stopped = true } }
    }

    func compute(_ scenario: Scenario) {
        cancel()
        let flag = StopFlag()
        stop = flag
        errorMessage = nil
        progress = 0
        let duration = duration
        task = Task {
            let result = await Task.detached(priority: .userInitiated) {
                [weak self] () -> Result<FreestandingMotion, Error> in
                guard let device = MTLCreateSystemDefaultDevice() else {
                    return .failure(BlastError.missingShader("no Metal device"))
                }
                return Result {
                    try FreestandingMotion.compute(
                        device: device, scenario: scenario, duration: duration,
                        progress: { time in Task { @MainActor in self?.progress = time } },
                        shouldContinue: { !flag.isStopped })
                }
            }.value
            guard !flag.isStopped else { return }
            progress = nil
            switch result {
            case .success(let motion):
                self.motion = motion
                time = motion.duration
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancel() {
        stop.set()
        task?.cancel()
        task = nil
        progress = nil
    }
}

extension SimulationModel {
    /// The freestanding objects as the 3D view draws them: at the computed motion's shown time
    /// while it matches the scene, and otherwise where they are placed.
    func freestandingBoxes() -> [SceneRenderer.OrientedBox] {
        let scenario = settings.scenario
        let objects = scenario.rigidObjects ?? []
        let cars = scenario.rigidCars ?? []
        if let motion = freestanding.motion, motion.scenario == scenario, let time = freestanding.time,
            let frame = motion.frame(at: time)
        {
            return zip(motion.objects, frame.poses).map { object, pose in
                SceneRenderer.OrientedBox(
                    centre: SIMD3<Float>(pose.centre),
                    orientation: simd_quatf(vector: SIMD4<Float>(pose.orientation)),
                    size: SIMD3<Float>(object.size), isCar: object.isCar)
            }
        }
        let boxes = objects.map { object -> SceneRenderer.OrientedBox in
            guard case .box(let size) = object.shape else { fatalError() }
            return SceneRenderer.OrientedBox(
                centre: SIMD3<Float>(object.position),
                orientation: simd_quatf(vector: SIMD4<Float>(object.orientation)),
                size: SIMD3<Float>(size), isCar: false)
        }
        return boxes
            + cars.map { car in
                let pose = simd_quatd(vector: car.orientation)
                let centre = car.position + pose.act(SIMD3(0, 0, car.groundClearance + car.shellSize.z / 2))
                return SceneRenderer.OrientedBox(
                    centre: SIMD3<Float>(centre),
                    orientation: simd_quatf(vector: SIMD4<Float>(car.orientation)),
                    size: SIMD3<Float>(car.shellSize), isCar: true)
            }
    }

    // MARK: Editing

    private var placementCentre: SIMD3<Double> {
        let charge = SIMD3<Double>(settings.scenario.charge.position)
        let domain = SIMD3<Double>(settings.scenario.domainSize)
        return simd_clamp(
            SIMD3(charge.x, charge.y + 3, 0), SIMD3(3, 3, 0), simd_max(domain - 3, SIMD3(3, 3, 0)))
    }

    func addFreestandingBox() {
        let size = SIMD3<Double>(1, 1, 1)
        // Beside where cars go, so the two do not overlap.
        let domain = SIMD3<Double>(settings.scenario.domainSize)
        let centre = simd_clamp(
            placementCentre - SIMD3(4, 0, 0), SIMD3(1, 1, 0), simd_max(domain - 1, SIMD3(1, 1, 0)))
        let count = (settings.scenario.rigidObjects ?? []).count
        do {
            let object = try RigidObjectDefinition(
                name: "Box \(count + 1)", shape: .box(size: size),
                position: SIMD3(centre.x, centre.y, size.z / 2),
                mass: 200)
            settings.scenario.rigidObjects = (settings.scenario.rigidObjects ?? []) + [object]
        } catch { freestanding.errorMessage = error.localizedDescription }
    }

    /// A saloon side-on to the charge, or `count` in 2.4 m bays.
    func addCars(_ count: Int = 1) {
        let centre = placementCentre
        let existing = (settings.scenario.rigidCars ?? []).count
        do {
            let cars = try (0..<count).map { n in
                try RigidCarDefinition.saloon(
                    name: "Car \(existing + n + 1)", position: SIMD3(centre.x, centre.y + 2.4 * Double(n), 0))
            }
            settings.scenario.rigidCars = (settings.scenario.rigidCars ?? []) + cars
        } catch { freestanding.errorMessage = error.localizedDescription }
    }

    func duplicateFreestanding(id: UUID) {
        do {
            if let object = settings.scenario.rigidObjects?.first(where: { $0.id == id }) {
                guard case .box(let size) = object.shape else { return }
                let copy = try object.edited(
                    id: UUID(), name: object.name + " copy",
                    position: object.position + SIMD3(size.x + 0.5, 0, 0))
                settings.scenario.rigidObjects?.append(copy)
            } else if let car = settings.scenario.rigidCars?.first(where: { $0.id == id }) {
                let pose = simd_quatd(vector: car.orientation)
                let copy = try car.edited(
                    id: UUID(), name: car.name + " copy", position: car.position + pose.act(SIMD3(0, 2.4, 0)))
                settings.scenario.rigidCars?.append(copy)
            }
        } catch { freestanding.errorMessage = error.localizedDescription }
    }

    func removeFreestanding(id: UUID) {
        settings.scenario.rigidObjects?.removeAll { $0.id == id }
        settings.scenario.rigidCars?.removeAll { $0.id == id }
        if settings.scenario.rigidObjects?.isEmpty == true { settings.scenario.rigidObjects = nil }
        if settings.scenario.rigidCars?.isEmpty == true { settings.scenario.rigidCars = nil }
    }
}

/// The layout editor's freestanding boxes and cars: placement, duplication and properties, and
/// their motion after the blast.
struct FreestandingObjectsSection: View {
    @Bindable var model: SimulationModel

    var body: some View {
        Section {
            ForEach(model.settings.scenario.rigidObjects ?? []) { object in
                FreestandingRow(model: model, id: object.id)
            }
            ForEach(model.settings.scenario.rigidCars ?? []) { car in
                FreestandingRow(model: model, id: car.id)
            }
            HStack {
                Button("Add Box", systemImage: "plus") { model.addFreestandingBox() }
                Button("Add Car", systemImage: "car") { model.addCars() }
                Button("Add Row of Cars", systemImage: "car.2") { model.addCars(4) }
            }
            if hasObjects { motion }
        } header: {
            Text("Freestanding objects (experimental)")
        } footer: {
            Text(
                "Rigid boxes and simplified cars (locked wheels, rigid suspension) that slide, tip and strike each other and the blocks. They do not take part in the ordinary run. Motion puts every object in the air, on 0.05 m cells around each, so they shield and reflect onto each other, and moves them through the air's load and contact."
            )
        }
    }

    private var hasObjects: Bool {
        !(model.settings.scenario.rigidObjects ?? []).isEmpty
            || !(model.settings.scenario.rigidCars ?? []).isEmpty
    }

    @ViewBuilder private var motion: some View {
        let state = model.freestanding
        HStack {
            if let progress = state.progress {
                ProgressView(value: min(progress / state.duration, 1)) {
                    Text(String(format: "Computing motion: %.2f of %.1f s", progress, state.duration))
                }
                Button("Stop") { state.cancel() }
            } else {
                Stepper(
                    String(format: "Duration %.1f s", state.duration),
                    value: Bindable(state).duration, in: 0.5...3, step: 0.5)
                Button("Compute Motion") { state.compute(model.settings.scenario) }
            }
        }
        if let error = state.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
        }
        if let result = state.motion {
            let current = result.scenario == model.settings.scenario
            if !current {
                Label(
                    "The layout has changed since this motion was computed.",
                    systemImage: "clock.arrow.circlepath"
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                GridRow {
                    Text("Object")
                    Text("Moved")
                    Text("Peak speed")
                    Text("Peak tilt")
                    Text("")
                }
                .font(.caption.bold())
                ForEach(Array(result.objects.enumerated()), id: \.offset) { n, object in
                    GridRow {
                        Text(object.name + (result.coupled.contains(n) ? "" : " (contact only)"))
                        Text(String(format: "%.2f m", simd_length(object.displacement)))
                        Text(String(format: "%.2f m/s", object.peakSpeed))
                        Text(String(format: "%.0f°", object.peakTilt))
                        Text(object.overturned ? "overturned" : object.finalTilt > 2 ? "tilted" : "upright")
                    }
                    .font(.caption.monospacedDigit())
                }
            }
            if current {
                Slider(
                    value: Binding(
                        get: { state.time ?? result.duration }, set: { state.time = $0 }),
                    in: 0...max(result.duration, 0.01)
                ) {
                    Text(String(format: "Pose at %.2f s", state.time ?? result.duration))
                }
                Button("Show Placed Poses") { state.time = nil }.disabled(state.time == nil)
            }
            if let failure = result.failure {
                Label(
                    "Stopped at \(String(format: "%.2f", result.duration)) s: \(failure)",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption).foregroundStyle(.orange)
            }
            Text(
                String(
                    format:
                        "%.2g m air, ×%d at the objects; %.0f s in the air, %.0f s coupling, %.1f s motion and contact.",
                    result.cellSize, result.refinement, result.timings.air, result.timings.coupling,
                    result.timings.mechanics)
            )
            .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// One object's name, placement and properties.
private struct FreestandingRow: View {
    @Bindable var model: SimulationModel
    let id: UUID
    @State private var expanded = false

    private var object: RigidObjectDefinition? { model.settings.scenario.rigidObjects?.first { $0.id == id } }
    private var car: RigidCarDefinition? { model.settings.scenario.rigidCars?.first { $0.id == id } }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            field("x (m)", position(0))
            field("y (m)", position(1))
            field("Heading (°)", yaw)
            field("Mass (kg)", property(\.mass))
            if object != nil {
                field("Length (m)", size(0))
                field("Width (m)", size(1))
                field("Height (m)", size(2))
            }
            field("Static friction", property(\.staticFriction))
            field("Sliding friction", property(\.slidingFriction))
        } label: {
            HStack {
                Label(object?.name ?? car?.name ?? "", systemImage: car != nil ? "car" : "cube")
                Spacer()
                Button("Duplicate", systemImage: "plus.square.on.square") {
                    model.duplicateFreestanding(id: id)
                }
                .labelStyle(.iconOnly)
                Button("Remove", systemImage: "trash") { model.removeFreestanding(id: id) }
                    .labelStyle(.iconOnly)
            }
        }
        .contextMenu {
            Button("Duplicate", systemImage: "plus.square.on.square") { model.duplicateFreestanding(id: id) }
        }
    }

    private func field(_ title: String, _ value: Binding<Double>) -> some View {
        LabeledContent(title) {
            TextField(title, value: value, format: .number.precision(.fractionLength(0...3)))
                .labelsHidden().frame(width: 90).multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }

    private struct Values {
        var position: SIMD3<Double>
        var yaw: Double
        var mass: Double
        var size: SIMD3<Double>
        var staticFriction: Double
        var slidingFriction: Double
    }

    private var values: Values? {
        if let object, case .box(let size) = object.shape {
            return Values(
                position: object.position, yaw: Self.yaw(object.orientation), mass: object.mass, size: size,
                staticFriction: object.staticFriction, slidingFriction: object.slidingFriction)
        }
        if let car {
            return Values(
                position: car.position, yaw: Self.yaw(car.orientation), mass: car.mass, size: car.shellSize,
                staticFriction: car.staticFriction, slidingFriction: car.slidingFriction)
        }
        return nil
    }

    private static func yaw(_ q: SIMD4<Double>) -> Double {
        let forward = simd_quatd(vector: q).act(SIMD3<Double>(1, 0, 0))
        return atan2(forward.y, forward.x) * 180 / .pi
    }

    /// Writes edited values back through the definitions' validation; invalid values are refused.
    private func apply(_ change: (inout Values) -> Void) {
        guard var edited = values else { return }
        change(&edited)
        let orientation = simd_quatd(angle: edited.yaw * .pi / 180, axis: SIMD3(0, 0, 1)).vector
        do {
            if let object,
                let index = model.settings.scenario.rigidObjects?.firstIndex(where: { $0.id == id })
            {
                model.settings.scenario.rigidObjects?[index] = try object.edited(
                    position: SIMD3(edited.position.x, edited.position.y, edited.size.z / 2),
                    orientation: orientation,
                    mass: edited.mass, size: edited.size, staticFriction: edited.staticFriction,
                    slidingFriction: edited.slidingFriction)
            } else if let car,
                let index = model.settings.scenario.rigidCars?.firstIndex(where: { $0.id == id })
            {
                model.settings.scenario.rigidCars?[index] = try car.edited(
                    position: SIMD3(edited.position.x, edited.position.y, 0), orientation: orientation,
                    mass: edited.mass,
                    staticFriction: edited.staticFriction, slidingFriction: edited.slidingFriction)
            }
        } catch {
            model.freestanding.errorMessage = error.localizedDescription
        }
    }

    private func position(_ axis: Int) -> Binding<Double> {
        Binding(get: { values?.position[axis] ?? 0 }, set: { value in apply { $0.position[axis] = value } })
    }
    private var yaw: Binding<Double> {
        Binding(get: { values?.yaw ?? 0 }, set: { value in apply { $0.yaw = value } })
    }
    private func size(_ axis: Int) -> Binding<Double> {
        Binding(get: { values?.size[axis] ?? 1 }, set: { value in apply { $0.size[axis] = value } })
    }
    private func property(_ keyPath: WritableKeyPath<Values, Double>) -> Binding<Double> {
        Binding(
            get: { values?[keyPath: keyPath] ?? 0 }, set: { value in apply { $0[keyPath: keyPath] = value } })
    }
}
