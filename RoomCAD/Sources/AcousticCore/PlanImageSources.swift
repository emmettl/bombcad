import Foundation
import simd

/// Image sources for a room with a floor plan.
///
/// The walls are vertical and the floor and ceiling flat and level, so a path's plan and its height
/// separate: images in plan come from reflecting across walls, and images in height from the floor and
/// ceiling exactly as in a box. An image in plan is valid for a receiver only if, traced back from the
/// receiver, its path meets each mirroring wall within the wall itself and no other wall blocks any leg;
/// that is what hides reflections round the corner of an L.
struct PlanImageSources {
    let room: ShoeboxRoom
    let plan: FloorPlan
    let source: SIMD3<Double>

    struct Image {
        var position: SIMD2<Double>
        /// Walls in the order the sound meets them, from the source.
        var walls: [Int]
        /// Index of the image this one mirrors, or -1 for the source.
        var parent: Int
    }

    /// Largest number of images generated; levels beyond it are left to the ray tracer.
    static let imageBudget = 100_000
    /// Floor and ceiling reflections allowed beyond the wall order, to bound the arrivals.
    static let verticalAllowance = 10

    /// Images up to `maximumOrder` wall reflections, or fewer if the budget runs out, within `reach` of
    /// the room. Returns the images (the source first) and the wall order reached.
    func images(maximumOrder: Int, reach: Double) -> (images: [Image], order: Int) {
        var images = [Image(position: [source.x, source.y], walls: [], parent: -1)]
        var level = 0..<1
        var order = 0
        let (low, high) = plan.bounds
        func farFromRoom(_ p: SIMD2<Double>) -> Bool {
            let nearest = simd_clamp(p, low, high)
            return simd_distance(p, nearest) > reach
        }
        while order < maximumOrder {
            var next: [Image] = []
            for index in level {
                let image = images[index]
                for wall in plan.corners.indices where wall != image.walls.last {
                    let a = plan.start(wall)
                    let normal = plan.inwardNormal(wall)
                    let side = simd_dot(image.position - a, normal)
                    // Only an image in front of a wall can be mirrored in it.
                    guard side > 1e-9 else { continue }
                    let mirrored = image.position - 2 * side * normal
                    guard !farFromRoom(mirrored) else { continue }
                    next.append(Image(position: mirrored, walls: image.walls + [wall], parent: index))
                }
            }
            guard !next.isEmpty, images.count + next.count <= Self.imageBudget else { break }
            level = images.count..<(images.count + next.count)
            images += next
            order += 1
        }
        return (images, order)
    }

    /// Whether the plan path from `image` to `receiver` is real, as described above.
    func isValid(_ index: Int, in images: [Image], receiver: SIMD2<Double>) -> Bool {
        pathPoints(index, in: images, receiver: receiver) != nil
    }

    /// The plan path from `receiver` back to the source through each reflection point, if it is real.
    func pathPoints(_ index: Int, in images: [Image], receiver: SIMD2<Double>) -> [SIMD2<Double>]? {
        var target = receiver
        var points = [receiver]
        var current = index
        var arrivingWall: Int? = nil
        while images[current].parent >= 0 {
            let image = images[current]
            let wall = image.walls.last!
            // Where the line from the target to this image crosses its last wall, within the wall.
            let a = plan.start(wall)
            let b = plan.end(wall)
            guard let t = raySegment(target, image.position - target, a, b), t < 1 else { return nil }
            let point = target + (image.position - target) * t
            guard unobstructed(target, point, except: [wall, arrivingWall]) else { return nil }
            target = point
            points.append(point)
            arrivingWall = wall
            current = image.parent
        }
        guard unobstructed(target, [source.x, source.y], except: [arrivingWall]) else { return nil }
        return points + [[source.x, source.y]]
    }

    /// Whether the segment p–q crosses no wall other than those listed.
    func unobstructed(_ p: SIMD2<Double>, _ q: SIMD2<Double>, except: [Int?]) -> Bool {
        for wall in plan.corners.indices where !except.contains(wall) {
            if let t = raySegment(p, q - p, plan.start(wall), plan.end(wall)), t < 1 - 1e-9 { return false }
        }
        return true
    }
}

extension ImageSourceModel {
    /// Arrivals in a room with a floor plan; see `PlanImageSources`. The summary's `orderLimitedAfter`
    /// is when images beyond the wall order reached may start to be missing.
    func forEachPlanArrival(
        at receiver: SIMD3<Double>, images: [PlanImageSources.Image], wallOrder: Int, microphone: Microphone,
        duration: Double, maximumOrder: Int, includeDirect: Bool, stop: () -> Bool,
        _ body: (_ delay: Double, _ order: Int, _ gains: [Double]) -> Void
    ) -> Summary {
        let plan = room.plan!
        let c = atmosphere.soundSpeed
        let reach = duration * c
        let bands = OctaveBands.count
        let generator = PlanImageSources(room: room, plan: plan, source: source)
        let zs = axisImages(
            length: room.size.z, source: source.z, receiver: receiver.z, reach: reach,
            low: room.floor.reflection,
            high: room.ceiling.reflection)
        let wallGains = plan.walls.map(\.reflection)
        let air =
            airAbsorption
            ? OctaveBands.centres.map { atmosphere.amplitudeAttenuationPerMetre(frequency: $0) }
            : Array(repeating: 0, count: bands)
        let flat = SIMD2(receiver.x, receiver.y)
        let zones = room.zones
        var summary = Summary()
        var gains = [Double](repeating: 0, count: bands)
        for (index, image) in images.enumerated() {
            if index % 4096 == 0, stop() { break }
            let horizontal = image.position - flat
            let h2 = simd_length_squared(horizontal)
            guard h2 <= reach * reach, let planPath = generator.pathPoints(index, in: images, receiver: flat)
            else { continue }
            var planGains = [Double](repeating: 1, count: bands)
            for wall in image.walls { for b in 0..<bands { planGains[b] *= wallGains[wall][b] } }
            for z in zs {
                let r2 = h2 + z.offset * z.offset
                if r2 > reach * reach { break }
                let order = image.walls.count + z.order
                guard order <= maximumOrder, order > 0 || includeDirect else { continue }
                let r = r2.squareRoot()
                var spreading = 1 / r
                if !microphone.isOmni {
                    spreading *= microphone.gain(from: SIMD3(horizontal.x, horizontal.y, z.offset) / r)
                }
                if !zones.isEmpty {
                    spreading *= exp(
                        -zones.depth(
                            along: Self.planPath(
                                planPath, from: receiver.z, to: receiver.z + z.offset, height: room.size.z))
                            / 2)
                }
                var audible = false
                for b in 0..<bands {
                    let g = planGains[b] * z.gains[b] * spreading * exp(-air[b] * r)
                    gains[b] = g
                    audible = audible || g != 0
                }
                guard audible else { continue }
                summary.arrivals += 1
                body(r / c, order, gains)
            }
        }
        if wallOrder < maximumOrder {
            // The nearest image one wall order further could be no closer than the nearest wall order
            // reached; report from there.
            let deepest = images.filter { $0.walls.count == wallOrder }.map {
                simd_distance($0.position, flat)
            }
            if let nearest = deepest.min(), nearest < reach { summary.orderLimitedAfter = nearest / c }
        }
        return summary
    }

    /// The path in 3D of a plan path whose height, unfolded, runs from `from` to `to`: it turns at
    /// each plan reflection and wherever it meets the floor or ceiling.
    static func planPath(_ plan: [SIMD2<Double>], from: Double, to: Double, height: Double) -> [SIMD3<Double>]
    {
        var lengths = [0.0]
        for (a, b) in zip(plan, plan.dropFirst()) { lengths.append(lengths.last! + simd_distance(a, b)) }
        let total = lengths.last!
        var breaks = total > 0 ? lengths.dropFirst().dropLast().map { $0 / total } : []
        foldBreaks(from: from, to: to, length: height, into: &breaks)
        breaks.sort()
        var segment = 0
        return ([0.0] + breaks + [1.0]).map { t in
            var flat = plan[0]
            if total > 0 {
                let along = t * total
                while segment < plan.count - 2, lengths[segment + 1] < along { segment += 1 }
                let span = lengths[segment + 1] - lengths[segment]
                let f = span > 0 ? (along - lengths[segment]) / span : 0
                flat = plan[segment] + (plan[segment + 1] - plan[segment]) * min(max(f, 0), 1)
            }
            return SIMD3(flat.x, flat.y, fold(from + t * (to - from), length: height))
        }
    }
}
