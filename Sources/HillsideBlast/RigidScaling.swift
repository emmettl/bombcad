import BlastModel
import Foundation
import simd

/// The project's rigid-body reference (`RigidBodyWorld`, CPU, sequential impulses) on terrain, for
/// the scaling question only: a stack of 1 m boxes dropped a little onto a slope.
enum RigidScaling {
    static func run(counts: [Int], stepsEach: Int = 60, budget: Double = 120) {
        print("RigidBodyWorld on a sloped terrain (CPU, one thread), dt 1/240 s")
        print("bodies  median step (ms)  p90 step (ms)  steps timed  contacts (last step)")
        for count in counts {
            let side = Int(ceil(pow(Double(count), 1.0 / 3))) + 1
            let columns = 64
            let heights = (0..<columns * columns).map { n -> Float in
                let j = n / columns
                return Float(j) * 0.5 * 0.3
            }
            let terrain = Terrain(
                origin: SIMD2(-8, -8), spacing: 0.5, columns: columns, rows: columns, heights: heights)
            var members: [RigidBodyWorld.Member] = []
            outer: for k in 0..<side * 4 {
                for j in 0..<side {
                    for i in 0..<side {
                        if members.count == count { break outer }
                        let centre = SIMD3<Double>(
                            Double(i) * 1.001 - Double(side) * 0.5, Double(j) * 1.001 - Double(side) * 0.5,
                            Double(
                                terrain.height(
                                    at: SIMD2<Float>(Float(i), Float(j)) * 1.001 - Float(side) * 0.5))
                                + 0.52 + Double(k) * 1.001)
                        guard
                            let body = try? RigidBoxBody(
                                mass: 2600, size: SIMD3(repeating: 1), position: centre)
                        else { continue }
                        members.append(.init(body: body, supports: [], friction: .init()))
                    }
                }
            }
            var world = RigidBodyWorld(members: members, terrain: terrain)
            var times: [Double] = []
            var contacts = 0
            let start = Date()
            for _ in 0..<stepsEach {
                let t0 = Date()
                contacts = world.advance(by: 1.0 / 240).count
                times.append(Date().timeIntervalSince(t0) * 1000)
                if Date().timeIntervalSince(start) > budget { break }
            }
            times.sort()
            print(
                "\(members.count)  \(String(format: "%.1f", times[times.count / 2]))  \(String(format: "%.1f", times[times.count * 9 / 10]))  \(times.count)  \(contacts)"
            )
            fflush(stdout)
        }
    }
}
