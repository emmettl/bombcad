import Foundation
import simd

/// Image sources for a room of any shape (Borish, 1984).
///
/// Each image is the source mirrored in a sequence of face planes, and can only be mirrored in a face
/// it lies in front of. It is valid for a receiver only if, traced back from the receiver, its path
/// meets each mirroring face within the face itself and no other face blocks any leg: that is what
/// hides reflections behind a balcony front or round the corner of a stage. Open faces do not reflect.
struct MeshImageSources {
    let geometry: MeshGeometry
    let source: SIMD3<Double>

    struct Image {
        var position: SIMD3<Double>
        /// Faces in the order the sound meets them, from the source.
        var faces: [Int]
        /// Index of the image this one mirrors, or -1 for the source.
        var parent: Int
    }

    /// Images up to `maximumOrder` reflections, or fewer if `PlanImageSources.imageBudget` runs out,
    /// within `reach` of the room. Returns the images (the source first) and the order reached.
    func images(maximumOrder: Int, reach: Double) -> (images: [Image], order: Int) {
        var images = [Image(position: source, faces: [], parent: -1)]
        var level = 0..<1
        var order = 0
        let (low, high) = geometry.mesh.bounds
        func farFromRoom(_ p: SIMD3<Double>) -> Bool {
            simd_distance(p, simd_clamp(p, low, high)) > reach
        }
        while order < maximumOrder {
            var next: [Image] = []
            for index in level {
                let image = images[index]
                for face in geometry.faces.indices
                where face != image.faces.last && !geometry.faces[face].open {
                    let f = geometry.faces[face]
                    let side = simd_dot(f.normal, image.position) - f.offset
                    // Only an image in front of a face can be mirrored in it.
                    guard side > 1e-9 else { continue }
                    let mirrored = image.position - 2 * side * f.normal
                    guard !farFromRoom(mirrored) else { continue }
                    next.append(Image(position: mirrored, faces: image.faces + [face], parent: index))
                }
            }
            guard !next.isEmpty, images.count + next.count <= PlanImageSources.imageBudget else { break }
            level = images.count..<(images.count + next.count)
            images += next
            order += 1
        }
        return (images, order)
    }

    /// Whether the path from `image` to `receiver` is real, as described above.
    func isValid(_ index: Int, in images: [Image], receiver: SIMD3<Double>) -> Bool {
        var target = receiver
        var current = index
        var arrivingFace = -1
        while images[current].parent >= 0 {
            let image = images[current]
            let face = image.faces.last!
            // Where the line from the target to this image crosses its last face, within the face.
            guard let t = geometry.intersect(face, origin: target, direction: image.position - target), t < 1
            else { return false }
            let point = target + (image.position - target) * t
            guard geometry.unobstructed(target, point, excluding: [face, arrivingFace]) else { return false }
            target = point
            arrivingFace = face
            current = image.parent
        }
        return geometry.unobstructed(target, source, excluding: [arrivingFace])
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
        var summary = Summary()
        var gains = [Double](repeating: 0, count: bands)
        for (index, image) in images.enumerated() {
            if index % 4096 == 0, stop() { break }
            let order = image.faces.count
            guard order <= maximumOrder, order > 0 || includeDirect else { continue }
            let offset = image.position - receiver
            let r = simd_length(offset)
            guard r <= reach, r > 0, generator.isValid(index, in: images, receiver: receiver) else {
                continue
            }
            var spreading = 1 / r
            if !microphone.isOmni { spreading *= microphone.gain(from: offset / r) }
            var audible = false
            for b in 0..<bands {
                var g = spreading * exp(-air[b] * r)
                for face in image.faces { g *= faceGains[face][b] }
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
            let deepest = images.filter { $0.faces.count == reached }.map {
                simd_distance($0.position, receiver)
            }
            if let nearest = deepest.min(), nearest < reach { summary.orderLimitedAfter = nearest / c }
        }
        return summary
    }
}
