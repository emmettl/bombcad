import Foundation

/// The standing table's identity, derived from its content rather than numbered by hand: a hash
/// of every model option's entry, the input fields' roles, the validation tables and figures the
/// bands are read from, and the standing of every sample scene on the shipped air. Any change to
/// what the table says gives a new identity, and two changes made apart merge with nothing to
/// renumber. Kept runs record it (`SceneStanding.table`); those recorded before it carry their
/// "standing-table-N" and read as different from every identity since.
public enum StandingFingerprint {
    /// "standing-" and the hash's first eight hexadecimal digits.
    public static let current: String = {
        let hash = fnv1a(canonicalText)
        return "standing-" + String(format: "%08llx", hash >> 32)
    }()

    /// What the identity is a hash of, written canonically: dictionaries and sets sorted, the
    /// fields of each value in label order, and every floating-point number to six significant
    /// figures, so that the same content gives the same text on any Mac.
    static var canonicalText: String {
        var parts: [String] = []
        for option in ModelOption.allCases.sorted(by: { $0.rawValue < $1.rawValue }) {
            parts.append("option \(option.rawValue) " + canonical(StandingTable.entry(for: option)))
        }
        parts.append("fields " + canonical(StandingTable.fields))
        parts.append("figures " + canonical(ValidationTables.figures))
        parts.append("scatters " + canonical(ValidationTables.scatters))
        parts.append("spreads " + canonical(ValidationTables.spreads))
        parts.append("roundings " + canonical(ValidationTables.roundings))
        for preset in ScenarioPreset.allCases.sorted(by: { $0.rawValue < $1.rawValue }) {
            let inputs = StandingInputs(
                scenario: preset.scenario, cellSize: 0.25, configuration: .recommended,
                thermal: ThermalSpec(),
                cloud: CloudSpec(), fragments: FragmentSpec(), groundShock: GroundShockSpec())
            // Built without the table's identity, which is what is being worked out here.
            parts.append("scene \(preset.rawValue) " + canonical(SceneStanding(inputs, table: "")))
        }
        return parts.joined(separator: "\n")
    }

    /// `value` written canonically (see `canonicalText`).
    static func canonical(_ value: Any) -> String {
        switch value {
        case let number as Double: return number.isFinite ? String(format: "%.6g", number) : "\(number)"
        case let number as Float: return canonical(Double(number))
        case let text as String: return "\"" + text.replacingOccurrences(of: "\"", with: "\\\"") + "\""
        case let flag as Bool: return flag ? "true" : "false"
        case let integer as Int: return String(integer)
        default: break
        }
        let mirror = Mirror(reflecting: value)
        switch mirror.displayStyle {
        case .optional:
            return mirror.children.first.map { canonical($0.value) } ?? "nil"
        case .dictionary:
            let pairs = mirror.children.map { child -> (String, String) in
                let pair = Mirror(reflecting: child.value).children.map(\.value)
                return (canonical(pair[0]), canonical(pair[1]))
            }
            return "{" + pairs.sorted { $0.0 < $1.0 }.map { "\($0.0):\($0.1)" }.joined(separator: ",") + "}"
        case .set:
            return "<" + mirror.children.map { canonical($0.value) }.sorted().joined(separator: ",") + ">"
        case .collection, .tuple:
            return "[" + mirror.children.map { canonical($0.value) }.joined(separator: ",") + "]"
        case .struct, .class:
            let fields = mirror.children.map { ($0.label ?? "", canonical($0.value)) }
            return "(" + fields.sorted { $0.0 < $1.0 }.map { "\($0.0)=\($0.1)" }.joined(separator: ",") + ")"
        case .enum:
            let name = String(describing: value).prefix { $0 != "(" }
            let payload = mirror.children.map { canonical($0.value) }.joined(separator: ",")
            return payload.isEmpty ? String(name) : "\(name)(\(payload))"
        default:
            return String(describing: value)
        }
    }

    /// 64-bit FNV-1a over `text`'s UTF-8.
    static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}
