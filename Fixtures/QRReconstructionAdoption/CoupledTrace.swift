import Foundation
import simd

enum QRCoupledTrace {
    nonisolated(unsafe) static var events: [[String: Any]] = []
    static func scalar(_ value: Double) -> [String: String] {
        ["value": String(value), "bits": String(value.bitPattern, radix: 16)]
    }
    static func tree(_ value: Any) -> Any {
        if type(of: value) == Double.self { return scalar(value as! Double) }
        if type(of: value) == Float.self {
            let x = value as! Float
            return ["floatValue": String(x), "floatBits": String(x.bitPattern, radix: 16)]
        }
        if let value = value as? Bool { return value }
        if let value = value as? Int { return value }
        if let value = value as? String { return value }
        if let value = value as? SIMD3<Double> { return (0..<3).map { scalar(value[$0]) } }
        if let value = value as? SIMD4<Double> { return (0..<4).map { scalar(value[$0]) } }
        if let value = value as? SIMD8<Double> { return (0..<8).map { scalar(value[$0]) } }
        if let value = value as? simd_double3x3 {
            return (0..<3).map { c in (0..<3).map { r in scalar(value[c][r]) } }
        }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            return mirror.children.first.map { tree($0.value) } ?? NSNull()
        }
        if mirror.displayStyle == .collection { return mirror.children.map { tree($0.value) } }
        if mirror.displayStyle == .set {
            let values = mirror.children.map { tree($0.value) }
            return values.sorted { String(describing: $0) < String(describing: $1) }
        }
        if mirror.displayStyle == .dictionary {
            let values: [[String: Any]] = mirror.children.map {
                let pair = Array(Mirror(reflecting: $0.value).children)
                return ["key": tree(pair[0].value), "value": tree(pair[1].value)]
            }
            return values.sorted { String(describing: $0["key"]!) < String(describing: $1["key"]!) }
        }
        if mirror.children.isEmpty {
            return ["type": String(reflecting: type(of: value)), "value": String(describing: value)]
        }
        var result: [String: Any] = [:]
        for (index, child) in mirror.children.enumerated() {
            let label = child.label ?? String(index)
            precondition(result[label] == nil, "Duplicate reflection field")
            result[label] = tree(child.value)
        }
        return result
    }
    static func record(_ kind: String, _ values: [String: Any]) {
        var event: [String: Any] = ["kind": kind]
        for (name, value) in values { event[name] = tree(value) }
        events.append(event)
    }
    static func reset() { events = [] }
}
