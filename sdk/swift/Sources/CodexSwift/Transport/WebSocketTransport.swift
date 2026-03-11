import Foundation

public actor WebSocketTransport: CodexTransporting {
    private let url: URL
    private let session: URLSession

    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?

    public init(url: URL, session: URLSession = .shared) {
        self.url = url
        self.session = session
    }

    public func connect(
        onEvent: @escaping @Sendable (String) async -> Void,
        onClose: @escaping @Sendable (Error?) async -> Void
    ) async throws {
        guard socket == nil else {
            return
        }

        let socket = session.webSocketTask(with: url)
        socket.resume()
        self.socket = socket

        receiveTask = Task {
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    switch message {
                    case .string(let text):
                        await onEvent(text)
                    case .data(let data):
                        guard let text = String(data: data, encoding: .utf8) else {
                            throw CodexTransportError.unsupportedPayload("Received a non-UTF8 websocket frame.")
                        }
                        await onEvent(text)
                    @unknown default:
                        throw CodexTransportError.unsupportedPayload("Received an unsupported websocket frame.")
                    }
                }
                await onClose(nil)
            } catch {
                await onClose(error)
            }
        }
    }

    public func send(_ payload: String) async throws {
        guard let socket else {
            throw CodexTransportError.notConnected
        }
        try await socket.send(.string(payload))
    }

    public func close() async {
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }
}
