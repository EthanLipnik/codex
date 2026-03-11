import Foundation

public enum JSONRPCID: Hashable, Sendable, Codable {
    case string(String)
    case int(Int)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .string(string)
            return
        }
        if let int = try? container.decode(Int.self) {
            self = .int(int)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "JSON-RPC ids must be strings or integers"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let string):
            try container.encode(string)
        case .int(let int):
            try container.encode(int)
        }
    }
}

public struct JSONRPCErrorPayload: Sendable, Equatable, Codable, Error {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

struct JSONRPCMessage: Sendable, Codable {
    let id: JSONRPCID?
    let method: String?
    let params: JSONObject?
    let result: JSONValue?
    let error: JSONRPCErrorPayload?

    init(
        id: JSONRPCID? = nil,
        method: String? = nil,
        params: JSONObject? = nil,
        result: JSONValue? = nil,
        error: JSONRPCErrorPayload? = nil
    ) {
        self.id = id
        self.method = method
        self.params = params
        self.result = result
        self.error = error
    }
}
