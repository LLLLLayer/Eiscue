import Foundation

/// JSON at the tool boundary, independent of the selected Agent runtime.
public indirect enum AgentJSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AgentJSONValue])
    case object([String: AgentJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([AgentJSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: AgentJSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public subscript(key: String) -> AgentJSONValue? { objectValue?[key] }
    public var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    public var doubleValue: Double? { if case .number(let value) = self { value } else { nil } }
    public var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var objectValue: [String: AgentJSONValue]? { if case .object(let value) = self { value } else { nil } }
    public var arrayValue: [AgentJSONValue]? { if case .array(let value) = self { value } else { nil } }

    public func decode<T: Decodable>(as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }
}

extension AgentJSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(arrayLiteral elements: AgentJSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, AgentJSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }
}
