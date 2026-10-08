import Foundation
import simd

/// Image sources for a room of any shape (Borish, 1984).
///
/// Each image is the source mirrored in a sequence of planes, and can only be mirrored in a plane it
/// lies in front of. It is valid for a receiver only if, traced back from the receiver, its path meets
/// each mirroring plane within one of the faces on it and no other face blocks any leg: that is what
/// hides reflections behind a balcony front or round the corner of a stage. Open faces do not reflect.
/// Images are mirrored in planes, not faces, so a wall cut into several faces adds no images.
struct MeshImageSources {
    let geometry: MeshGeometry
    let source: SIMD3<Double>

    struct Image {
        var position: SIMD3<Double>
        /// Planes (groups of coplanar faces) in the order the sound meets them, from the source.
        var planes: [Int]
        /// Index of the image this one mirrors, or -1 for the source.
        var parent: Int
    }

    /// Images up to `maximumOrder` reflections, or fewer if `PlanImageSources.imageBudget` runs out,
    /// within `reach` of the room. Returns the images (the source first) and the order reached.
    func images(maximumOrder: Int, reach: Double) -> (images: [Image], order: Int) {
        var images = [Image(position: source, planes: [], parent: -1)]
        var level = 0..<1
        var order = 0
        let (low, high) = geometry.mesh.bounds
        func farFromRoom(_ p: SIMD3<Double>) -> Bool {
            simd_distance(p, simd_clamp(p, low, high)) > reach
        }
        // Planes that can reflect: those with a face that is not open.
        let reflecting = geometry.planes.indices.filter { plane in
            geometry.planes[plane].faces.contains { !geometry.faces[$0].open }
        }
        while order < maximumOrder {
            var next: [Image] = []
            for index in level {
                let image = images[index]
                for plane in reflecting where plane != image.planes.last {
                    let p = geometry.planes[plane]
                    let side = simd_dot(p.normal, image.position) - p.offset
                    // Only an image in front of a plane can be mirrored in it.
                    guard side > 1e-9 else { continue }
                    let mirrored = image.position - 2 * side * p.normal
                    guard !farFromRoom(mirrored) else { continue }
                    next.append(Image(position: mirrored, planes: image.planes + [plane], parent: index))
                }
            }
            guard !next.isEmpty, images.count + next.count <= PlanImageSources.imageBudget else { break }
            level = images.count..<(images.count + next.count)
            images += next
            order += 1
        }
        return (images, order)
    }

    /// The faces the path from `image` to `receiver` reflects from, from the source, and the path's
    /// points from the receiver back to the source, if the path is real: traced back from the receiver
    /// it must meet each mirroring plane within one of its faces that is not open, and no other face
    /// may block any leg.
    func path(_ index: Int, in images: [Image], receiver: SIMD3<Double>) -> (
        faces: [Int], points: [SIMD3<Double>]
    )? {
        var target = receiver
        var current = index
        var arriving: [Int] = []
        var faces: [Int] = []
        var points = [receiver]
        while images[current].parent >= 0 {
            let image = images[current]
            let plane = geometry.planes[image.planes.last!]
            // Where the line from the target to this image crosses its last plane.
            let direction = image.position - target
            let denominator = simd_dot(plane.normal, direction)
            guard abs(denominator) > 1e-12 else { return nil }
            let t = (plane.offset - simd_dot(plane.normal, target)) / denominator
            guard t > 1e-9, t < 1 else { return nil }
            let point = target + direction * t
            guard let face = plane.faces.first(where: { geometry.faceContains($0, point) }),
                !geometry.faces[face].open,
                geometry.unobstructed(target, point, excluding: plane.faces + arriving)
            else { return nil }
            faces.append(face)
            points.append(point)
            target = point
            arriving = plane.faces
            current = image.parent
        }
        guard geometry.unobstructed(target, source, excluding: arriving) else { return nil }
        return (faces.reversed(), points + [source])
    }
}

extension ImageSourceModel {
    /// Arrivals in a room of any shape; see `MeshImageSources`. The summary's `orderLimitedAfter` is when
    /// images beyond the order reached may start to be missing.
    func forEachMeshArrival(
        at receiver: SIMD3<Double>, images: [MeshImageSources.Image], order reached: Int,
        microphone: Microphone,
        duration: Double, maximumOrder: Int, includeDirect: Bool, stop: () -> Bool,
        _ body: (_ delay: Double, _ order: Int, _ gains: [Double]) -> Void
    ) -> Summary {
        let mesh = room.mesh!
        let geometry = MeshGeometry.of(mesh)
        let generator = MeshImageSources(geometry: geometry, source: source)
        let c = atmosphere.soundSpeed
        let reach = duration * c
        let bands = OctaveBands.count
        let faceGains = mesh.faces.indices.map { mesh.material(of: $0).reflection }
        let air =
            airAbsorption
            ? OctaveBands.centres.map { atmosphere.amplitudeAttenuationPerMetre(frequency: $0) }
            : Array(repeating: 0, count: bands)
        let zones = room.zones
        var summary = Summary()
        var gains = [Double](repeating: 0, count: bands)
        for (index, image) in images.enumerated() {
            if index % 4096 == 0, stop() { break }
            let order = image.planes.count
            guard order <= maximumOrder, order > 0 || includeDirect else { continue }
            let offset = image.position - receiver
            let r = simd_length(offset)
            guard r <= reach, r > 0,
                let (faces, points) = generator.path(index, in: images, receiver: receiver)
            else { continue }
            var spreading = 1 / r
            if !zones.isEmpty { spreading *= exp(-zones.depth(along: points) / 2) }
            if !microphone.isOmni { spreading *= microphone.gain(from: offset / r) }
            var audible = false
            for b in 0..<bands {
                var g = spreading * exp(-air[b] * r)
                for face in faces { g *= faceGains[face][b] }
                gains[b] = g
                audible = audible || g != 0
            }
            guard audible else { continue }
            summary.arrivals += 1
            body(r / c, order, gains)
        }
        if reached < maximumOrder {
            // The nearest image one order further could be no closer than the nearest image of the order
            // reached; report from there.
            let deepest = images.filter { $0.planes.count == reached }.map {
                simd_distance($0.position, receiver)
            }
            if let nearest = deepest.min(), nearest < reach { summary.orderLimitedAfter = nearest / c }
        }
        return summary
    }
}
