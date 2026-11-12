import Foundation

func parseVector(_ text: String) -> SIMD3<Float> {
    let v = text.split(separator: ",").compactMap { Float($0) }
    return SIMD3(v[0], v[1], v[2])
}
