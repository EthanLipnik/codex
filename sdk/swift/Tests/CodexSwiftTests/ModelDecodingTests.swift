import Foundation
import Testing
@testable import CodexSwift

struct ModelDecodingTests {
    @Test
    func decodesKnownThreadItems() throws {
        let payload = """
        {
          "id": "msg-1",
          "type": "agentMessage",
          "text": "Hello from Rust",
          "phase": "final"
        }
        """.data(using: .utf8)!

        let item = try JSONDecoder().decode(CodexThreadItem.self, from: payload)

        #expect(item == .agentMessage(id: "msg-1", text: "Hello from Rust", phase: "final"))
    }

    @Test
    func decodesUnknownItemsWithoutDroppingPayload() throws {
        let payload = """
        {
          "id": "img-1",
          "type": "imageGeneration",
          "status": "completed"
        }
        """.data(using: .utf8)!

        let item = try JSONDecoder().decode(CodexThreadItem.self, from: payload)

        guard case .unknown(let type, let id, let raw) = item else {
            Issue.record("Expected an unknown item.")
            return
        }

        #expect(type == "imageGeneration")
        #expect(id == "img-1")
        #expect(raw["status"] == .string("completed"))
    }

    @Test
    func runsTurnAgainstMockTransport() async throws {
        let transport = MockTransport()
        let client = CodexClient(transport: transport)
        let thread = try await client.startThread(options: ThreadStartOptions(model: "gpt-5"))
        let result = try await thread.run("Hello")

        #expect(result.turn.status == .completed)
        #expect(result.finalResponse == "Hello from mock server")
    }
}

private actor MockTransport: CodexTransporting {
    private var onEvent: (@Sendable (String) async -> Void)?
    private var onClose: (@Sendable (Error?) async -> Void)?

    func connect(
        onEvent: @escaping @Sendable (String) async -> Void,
        onClose: @escaping @Sendable (Error?) async -> Void
    ) async throws {
        self.onEvent = onEvent
        self.onClose = onClose
    }

    func send(_ payload: String) async throws {
        let message = try JSONDecoder().decode(JSONRPCMessage.self, from: Data(payload.utf8))

        if let method = message.method, let id = message.id {
            switch method {
            case "initialize":
                try await emit(
                    JSONRPCMessage(
                        id: id,
                        result: .object([
                            "serverInfo": .object([
                                "name": .string("codex-app-server"),
                                "version": .string("0.0.0"),
                            ]),
                            "userAgent": .string("mock-agent"),
                        ])
                    )
                )
            case "thread/start":
                try await emit(
                    JSONRPCMessage(
                        id: id,
                        result: .object([
                            "thread": .object([
                                "id": .string("thread-1"),
                                "name": .null,
                                "preview": .string(""),
                                "cwd": .string("/tmp/repo"),
                                "createdAt": .int(1),
                                "updatedAt": .int(1),
                                "status": .string("loaded"),
                                "modelProvider": .string("openai"),
                                "turns": .array([]),
                            ]),
                        ])
                    )
                )
            case "turn/start":
                try await emit(
                    JSONRPCMessage(
                        id: id,
                        result: .object([
                            "turn": .object([
                                "id": .string("turn-1"),
                                "status": .string("inProgress"),
                                "items": .array([]),
                                "error": .null,
                            ]),
                        ])
                    )
                )
                try await emit(
                    JSONRPCMessage(
                        method: "item/agentMessage/delta",
                        params: [
                            "threadId": .string("thread-1"),
                            "turnId": .string("turn-1"),
                            "itemId": .string("item-1"),
                            "delta": .string("Hello from mock server"),
                        ]
                    )
                )
                try await emit(
                    JSONRPCMessage(
                        method: "item/completed",
                        params: [
                            "threadId": .string("thread-1"),
                            "turnId": .string("turn-1"),
                            "item": .object([
                                "id": .string("item-1"),
                                "type": .string("agentMessage"),
                                "text": .string("Hello from mock server"),
                                "phase": .string("final"),
                            ]),
                        ]
                    )
                )
                try await emit(
                    JSONRPCMessage(
                        method: "turn/completed",
                        params: [
                            "threadId": .string("thread-1"),
                            "turn": .object([
                                "id": .string("turn-1"),
                                "status": .string("completed"),
                                "items": .array([]),
                                "error": .null,
                            ]),
                        ]
                    )
                )
            default:
                break
            }
        }
    }

    func close() async {
        if let onClose {
            await onClose(nil)
        }
    }

    private func emit(_ message: JSONRPCMessage) async throws {
        let data = try JSONEncoder().encode(message)
        if let onEvent {
            await onEvent(String(decoding: data, as: UTF8.self))
        }
    }
}
