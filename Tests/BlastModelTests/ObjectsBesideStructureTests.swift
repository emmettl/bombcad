import Foundation
import Testing
import simd

@testable import BlastModel

/// Freestanding objects and a deformable structure in the air together, stage 1: their masks and
/// wall velocities coexist (`installExperimentalBoxes` beside `setStructures`). A box held in place
/// but given a velocity stands beside a steel plate that a charge bends: the box's cells stay solid
/// at its velocity through the structure's remasks, the box's remaps leave the structure's cells as
/// they are, and the gas changes by what the structure and the box change it apart.
@Suite("Objects beside a moving structure")
struct ObjectsBesideStructureTests {
    @Test("A structure moved across the ground takes all it places with it")
    func movedStructure() {
        let wall = Box(min: SIMD3(2, 1, 0), max: SIMD3(2.2, 4, 3))
        var model = StructureModel(solids: [wall], elementSize: 0.1, fixedBase: true)
        model.openings = [Box(min: SIMD3(2, 2, 1), max: SIMD3(2.2, 3, 2))]
        model.supports = [Box(min: SIMD3(1.9, 0.9, 2.9), max: SIMD3(2.3, 4.1, 3.1))]
        model.reinforcement = [ReinforcementLayer(region: wall, ratio: SIMD3(0.01, 0, 0.01))]
        model.inclinedBars = [
            InclinedBars(
                start: SIMD3(2.1, 1, 1), direction: SIMD3(0, 1, 1), length: 1, span: 2...2.2,
                areaPerMetre: 1e-4)
        ]
        model.discreteBars = [
            DiscreteBar(start: SIMD3(2.1, 1, 0.5), end: SIMD3(2.1, 4, 0.5), diameter: 0.012)
        ]
        let offset = SIMD2<Float>(-1.8, -0.6)
        let shift = SIMD3(offset.x, offset.y, 0)
        let moved = model.moved(across: offset)
        #expect(moved.bounds.min == wall.min + shift && moved.bounds.max == wall.max + shift)
        #expect(moved.openings[0].min == model.openings[0].min + shift)
        #expect(moved.supports[0].max == model.supports[0].max + shift)
        #expect(moved.reinforcement[0].region.min == wall.min + shift)
        #expect(moved.inclinedBars[0].start == model.inclinedBars[0].start + shift)
        // These bars run in y and z, so they repeat along x.
        #expect(moved.inclinedBars[0].span == (2 + shift.x)...(2.2 + shift.x))
        #expect(moved.discreteBars[0].end == model.discreteBars[0].end + shift)
    }
}
