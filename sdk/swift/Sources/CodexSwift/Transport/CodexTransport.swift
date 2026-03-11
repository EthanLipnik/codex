import Foundation

public protocol CodexTransporting: Sendable {
    func connect(
        onEvent: @escaping @Sendable (String) async -> Void,
        onClose: @escaping @Sendable (Error?) async -> Void
    ) async throws

    func send(_ payload: String) async throws
    func close() async
}

public enum CodexTransportError: LocalizedError, Sendable, Equatable {
    case notConnected
    case unsupportedPayload(String)
    case closed(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "The transport is not connected."
        case .unsupportedPayload(let message):
            return message
        case .closed(let message):
            return message
        }
    }
}
