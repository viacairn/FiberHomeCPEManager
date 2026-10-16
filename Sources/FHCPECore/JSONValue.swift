import Foundation
public enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .object(let v): try c.encode(v); case .array(let v): try c.encode(v); case .string(let v): try c.encode(v); case .number(let v): try c.encode(v); case .bool(let v): try c.encode(v); case .null: try c.encodeNil() }
    }
    public subscript(_ key: String) -> JSONValue { if case .object(let o) = self { o[key] ?? .null } else { .null } }
    public var text: String? { switch self { case .string(let s): s.isEmpty ? nil : s; case .number(let n): n.rounded() == n ? String(format: "%.0f", n) : String(n); default: nil } }
    public var double: Double? { text.flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil } }
    public var array: [JSONValue] { if case .array(let a) = self { a } else { [] } }
    public static func strings(_ dictionary: [String: String]) -> JSONValue { .object(dictionary.mapValues(JSONValue.string)) }
}
