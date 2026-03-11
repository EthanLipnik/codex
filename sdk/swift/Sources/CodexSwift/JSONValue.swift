import Foundation

public typealias JSONObject = [String: JSONValue]

public enum JSONValue: Sendable, Equatable, Codable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case object(JSONObject)
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int64.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode(JSONObject.self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let string):
            try container.encode(string)
        case .int(let int):
            try container.encode(int)
        case .double(let double):
            try container.encode(double)
        case .bool(let bool):
            try container.encode(bool)
        case .object(let object):
            try container.encode(object)
        case .array(let array):
            try container.encode(array)
        case .null:
            try container.encodeNil()
        }
    }

    public var stringValue: String? {
        guard case .string(let string) = self else {
            return nil
        }
        return string
    }

    public var intValue: Int64? {
        switch self {
        case .int(let int):
            return int
        case .double(let double) where double.rounded() == double:
            return Int64(double)
        default:
            return nil
        }
    }

    public var boolValue: Bool? {
        guard case .bool(let bool) = self else {
            return nil
        }
        return bool
    }

    public var objectValue: JSONObject? {
        guard case .object(let object) = self else {
            return nil
        }
        return object
    }

    public var arrayValue: [JSONValue]? {
        guard case .array(let array) = self else {
            return nil
        }
        return array
    }

    public static func encoded<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public func decoded<T: Decodable>(as type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(type, from: data)
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    mutating func mergeReplacing(_ other: JSONObject) {
        merge(other) { _, new in new }
    }
}
