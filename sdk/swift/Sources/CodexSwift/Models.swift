import Foundation
import Observation

/// Describes the Swift client that connects to the Codex app-server protocol.
public struct CodexClientInfo: Sendable, Equatable {
    public var name: String
    public var title: String
    public var version: String

    public init(
        name: String = "codex_swift_sdk",
        title: String = "Codex Swift SDK",
        version: String = "0.1.0"
    ) {
        self.name = name
        self.title = title
        self.version = version
    }
}

public struct CodexServerRequest: Sendable, Equatable {
    public let id: JSONRPCID
    public let method: String
    public let params: JSONObject

    public init(id: JSONRPCID, method: String, params: JSONObject) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public typealias ApprovalHandler = @Sendable (CodexServerRequest) async -> JSONObject

/// Configures shared client behavior such as approval handling and advertised capabilities.
public struct CodexConfiguration: Sendable {
    public var clientInfo: CodexClientInfo
    public var experimentalAPI: Bool
    public var additionalCapabilities: JSONObject
    public var approvalHandler: ApprovalHandler

    public init(
        clientInfo: CodexClientInfo = CodexClientInfo(),
        experimentalAPI: Bool = true,
        additionalCapabilities: JSONObject = [:],
        approvalHandler: @escaping ApprovalHandler = CodexConfiguration.defaultApprovalHandler
    ) {
        self.clientInfo = clientInfo
        self.experimentalAPI = experimentalAPI
        self.additionalCapabilities = additionalCapabilities
        self.approvalHandler = approvalHandler
    }

    public static func defaultApprovalHandler(_ request: CodexServerRequest) async -> JSONObject {
        switch request.method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            return ["decision": .string("accept")]
        default:
            return [:]
        }
    }
}

public enum ApprovalPolicy: String, Sendable, Codable {
    case untrusted
    case onFailure = "on-failure"
    case onRequest = "on-request"
    case never
}

public enum ExternalSandboxNetworkAccess: String, Sendable, Codable {
    case restricted
    case enabled
}

public enum SandboxPolicy: Sendable, Equatable, Encodable {
    case dangerFullAccess
    case readOnly(networkAccess: Bool = false)
    case workspaceWrite(networkAccess: Bool = false, writableRoots: [String] = [])
    case externalSandbox(networkAccess: ExternalSandboxNetworkAccess = .restricted)

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .dangerFullAccess:
            try container.encode("dangerFullAccess", forKey: .type)
        case .readOnly(let networkAccess):
            try container.encode("readOnly", forKey: .type)
            try container.encode(networkAccess, forKey: .networkAccess)
        case .workspaceWrite(let networkAccess, let writableRoots):
            try container.encode("workspaceWrite", forKey: .type)
            try container.encode(networkAccess, forKey: .networkAccess)
            try container.encode(writableRoots, forKey: .writableRoots)
        case .externalSandbox(let networkAccess):
            try container.encode("externalSandbox", forKey: .type)
            try container.encode(networkAccess.rawValue, forKey: .networkAccess)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case networkAccess
        case writableRoots
    }
}

public enum CodexUserInput: Sendable, Equatable, Encodable {
    case text(String)
    case image(URL)
    case localImage(path: String)
    case skill(name: String, path: String)
    case mention(name: String, path: String)

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .image(let url):
            try container.encode("image", forKey: .type)
            try container.encode(url.absoluteString, forKey: .url)
        case .localImage(let path):
            try container.encode("localImage", forKey: .type)
            try container.encode(path, forKey: .path)
        case .skill(let name, let path):
            try container.encode("skill", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(path, forKey: .path)
        case .mention(let name, let path):
            try container.encode("mention", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(path, forKey: .path)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case url
        case path
        case name
    }
}

/// Options used when creating or resuming a thread.
public struct ThreadStartOptions: Sendable, Equatable {
    public var model: String?
    public var workingDirectory: String?
    public var approvalPolicy: ApprovalPolicy?
    public var sandbox: SandboxPolicy?
    public var personality: String?
    public var additionalParams: JSONObject

    public init(
        model: String? = nil,
        workingDirectory: String? = nil,
        approvalPolicy: ApprovalPolicy? = nil,
        sandbox: SandboxPolicy? = nil,
        personality: String? = nil,
        additionalParams: JSONObject = [:]
    ) {
        self.model = model
        self.workingDirectory = workingDirectory
        self.approvalPolicy = approvalPolicy
        self.sandbox = sandbox
        self.personality = personality
        self.additionalParams = additionalParams
    }
}

public struct TurnOptions: Sendable, Equatable {
    public var additionalParams: JSONObject

    public init(additionalParams: JSONObject = [:]) {
        self.additionalParams = additionalParams
    }
}

public enum TurnStatus: String, Sendable, Equatable, Codable {
    case completed
    case interrupted
    case failed
    case inProgress
}

public struct TurnError: Sendable, Equatable, Codable, Error {
    public let message: String
    public let additionalDetails: String?

    public init(message: String, additionalDetails: String? = nil) {
        self.message = message
        self.additionalDetails = additionalDetails
    }
}

public struct ThreadListPage: Sendable, Equatable, Codable {
    public let data: [ThreadSummary]
    public let nextCursor: String?

    public init(data: [ThreadSummary], nextCursor: String?) {
        self.data = data
        self.nextCursor = nextCursor
    }
}

public struct ThreadSummary: Sendable, Equatable, Codable, Identifiable {
    public let id: String
    public let name: String?
    public let preview: String
    public let cwd: String
    public let createdAt: Int64
    public let updatedAt: Int64
    public let status: String
    public let modelProvider: String
    public let turns: [TurnSummary]

    public init(
        id: String,
        name: String?,
        preview: String,
        cwd: String,
        createdAt: Int64,
        updatedAt: Int64,
        status: String,
        modelProvider: String,
        turns: [TurnSummary]
    ) {
        self.id = id
        self.name = name
        self.preview = preview
        self.cwd = cwd
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.status = status
        self.modelProvider = modelProvider
        self.turns = turns
    }
}

public struct TurnSummary: Sendable, Equatable, Codable, Identifiable {
    public let id: String
    public let status: TurnStatus
    public let items: [CodexThreadItem]
    public let error: TurnError?

    public init(
        id: String,
        status: TurnStatus,
        items: [CodexThreadItem],
        error: TurnError?
    ) {
        self.id = id
        self.status = status
        self.items = items
        self.error = error
    }
}

public struct CommandExecutionItem: Sendable, Equatable, Codable {
    public let id: String
    public let command: String
    public let aggregatedOutput: String?
    public let cwd: String
    public let exitCode: Int?
    public let status: String
}

public struct FileUpdateChange: Sendable, Equatable, Codable {
    public let path: String
    public let kind: String
}

public struct FileChangeItem: Sendable, Equatable, Codable {
    public let id: String
    public let changes: [FileUpdateChange]
    public let status: String
}

public enum DecodedUserInput: Sendable, Equatable, Codable {
    case text(String)
    case image(String)
    case localImage(String)
    case skill(name: String, path: String)
    case mention(name: String, path: String)
    case unknown(type: String, payload: JSONObject)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let payload = try container.decode(JSONObject.self)
        let type = payload["type"]?.stringValue ?? "unknown"

        switch type {
        case "text":
            self = .text(payload["text"]?.stringValue ?? "")
        case "image":
            self = .image(payload["url"]?.stringValue ?? "")
        case "localImage":
            self = .localImage(payload["path"]?.stringValue ?? "")
        case "skill":
            self = .skill(
                name: payload["name"]?.stringValue ?? "",
                path: payload["path"]?.stringValue ?? ""
            )
        case "mention":
            self = .mention(
                name: payload["name"]?.stringValue ?? "",
                path: payload["path"]?.stringValue ?? ""
            )
        default:
            self = .unknown(type: type, payload: payload)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        let payload: JSONObject
        switch self {
        case .text(let text):
            payload = ["type": .string("text"), "text": .string(text)]
        case .image(let url):
            payload = ["type": .string("image"), "url": .string(url)]
        case .localImage(let path):
            payload = ["type": .string("localImage"), "path": .string(path)]
        case .skill(let name, let path):
            payload = ["type": .string("skill"), "name": .string(name), "path": .string(path)]
        case .mention(let name, let path):
            payload = ["type": .string("mention"), "name": .string(name), "path": .string(path)]
        case .unknown(_, let payload):
            try container.encode(payload)
            return
        }
        try container.encode(payload)
    }

    public var textDescription: String? {
        switch self {
        case .text(let text):
            return text
        default:
            return nil
        }
    }
}

public enum CodexThreadItem: Sendable, Equatable, Codable {
    case userMessage(id: String, content: [DecodedUserInput])
    case agentMessage(id: String, text: String, phase: String?)
    case reasoning(id: String, summary: [String], content: [String])
    case commandExecution(CommandExecutionItem)
    case fileChange(FileChangeItem)
    case plan(id: String, text: String)
    case unknown(type: String, id: String?, payload: JSONObject)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let payload = try container.decode(JSONObject.self)
        let type = payload["type"]?.stringValue ?? "unknown"

        switch type {
        case "userMessage":
            let id = payload["id"]?.stringValue ?? UUID().uuidString
            let content = try payload["content"]?.decoded(as: [DecodedUserInput].self) ?? []
            self = .userMessage(id: id, content: content)
        case "agentMessage":
            self = .agentMessage(
                id: payload["id"]?.stringValue ?? UUID().uuidString,
                text: payload["text"]?.stringValue ?? "",
                phase: payload["phase"]?.stringValue
            )
        case "reasoning":
            let summary = try payload["summary"]?.decoded(as: [String].self) ?? []
            let content = try payload["content"]?.decoded(as: [String].self) ?? []
            self = .reasoning(
                id: payload["id"]?.stringValue ?? UUID().uuidString,
                summary: summary,
                content: content
            )
        case "commandExecution":
            self = .commandExecution(try JSONValue.object(payload).decoded(as: CommandExecutionItem.self))
        case "fileChange":
            self = .fileChange(try JSONValue.object(payload).decoded(as: FileChangeItem.self))
        case "plan":
            self = .plan(
                id: payload["id"]?.stringValue ?? UUID().uuidString,
                text: payload["text"]?.stringValue ?? ""
            )
        default:
            self = .unknown(
                type: type,
                id: payload["id"]?.stringValue,
                payload: payload
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        let payload: JSONObject

        switch self {
        case .userMessage(let id, let content):
            payload = [
                "id": .string(id),
                "type": .string("userMessage"),
                "content": try JSONValue.encoded(content),
            ]
        case .agentMessage(let id, let text, let phase):
            var object: JSONObject = [
                "id": .string(id),
                "type": .string("agentMessage"),
                "text": .string(text),
            ]
            if let phase {
                object["phase"] = .string(phase)
            }
            payload = object
        case .reasoning(let id, let summary, let content):
            payload = [
                "id": .string(id),
                "type": .string("reasoning"),
                "summary": try JSONValue.encoded(summary),
                "content": try JSONValue.encoded(content),
            ]
        case .commandExecution(let item):
            payload = try JSONValue.encoded(item).objectValue ?? [:]
        case .fileChange(let item):
            payload = try JSONValue.encoded(item).objectValue ?? [:]
        case .plan(let id, let text):
            payload = [
                "id": .string(id),
                "type": .string("plan"),
                "text": .string(text),
            ]
        case .unknown(_, _, let payload):
            try container.encode(payload)
            return
        }

        try container.encode(payload)
    }

    public var assistantText: String? {
        guard case .agentMessage(_, let text, _) = self else {
            return nil
        }
        return text
    }

    public var userText: String? {
        guard case .userMessage(_, let content) = self else {
            return nil
        }
        let segments = content.compactMap(\.textDescription)
        guard !segments.isEmpty else {
            return nil
        }
        return segments.joined(separator: "\n\n")
    }
}

public struct AgentMessageDelta: Sendable, Equatable, Codable {
    public let delta: String
    public let itemID: String
    public let threadID: String
    public let turnID: String

    enum CodingKeys: String, CodingKey {
        case delta
        case itemID = "itemId"
        case threadID = "threadId"
        case turnID = "turnId"
    }
}

public struct CodexNotification: Sendable, Equatable {
    public let method: String
    public let params: JSONObject

    public init(method: String, params: JSONObject) {
        self.method = method
        self.params = params
    }
}

public enum CodexTurnEvent: Sendable, Equatable {
    case turnStarted(threadID: String, turn: TurnSummary)
    case agentMessageDelta(AgentMessageDelta)
    case itemStarted(threadID: String, turnID: String, item: CodexThreadItem)
    case itemCompleted(threadID: String, turnID: String, item: CodexThreadItem)
    case error(threadID: String, turnID: String, error: TurnError, willRetry: Bool)
    case turnCompleted(threadID: String, turn: TurnSummary)
    case notification(CodexNotification)
}

public struct TurnResult: Sendable, Equatable {
    public let threadID: String
    public let turn: TurnSummary
    public let items: [CodexThreadItem]
    public let finalResponse: String

    public init(
        threadID: String,
        turn: TurnSummary,
        items: [CodexThreadItem],
        finalResponse: String
    ) {
        self.threadID = threadID
        self.turn = turn
        self.items = items
        self.finalResponse = finalResponse
    }
}

public struct CodexThread: Sendable, Identifiable {
    public let id: String
    private let client: CodexClient

    init(id: String, client: CodexClient) {
        self.id = id
        self.client = client
    }

    public func run(_ text: String, options: TurnOptions = TurnOptions()) async throws -> TurnResult {
        try await client.runTurn(threadID: id, input: [.text(text)], options: options)
    }

    public func run(_ input: [CodexUserInput], options: TurnOptions = TurnOptions()) async throws -> TurnResult {
        try await client.runTurn(threadID: id, input: input, options: options)
    }

    public func runStreamed(
        _ text: String,
        options: TurnOptions = TurnOptions()
    ) async throws -> AsyncThrowingStream<CodexTurnEvent, Error> {
        try await client.runTurnStreamed(threadID: id, input: [.text(text)], options: options)
    }

    public func runStreamed(
        _ input: [CodexUserInput],
        options: TurnOptions = TurnOptions()
    ) async throws -> AsyncThrowingStream<CodexTurnEvent, Error> {
        try await client.runTurnStreamed(threadID: id, input: input, options: options)
    }
}

public struct CodexConversationMessage: Sendable, Equatable, Identifiable {
    public enum Role: String, Sendable, Equatable {
        case user
        case assistant
        case system
    }

    public let id: String
    public var role: Role
    public var text: String
    public var isStreaming: Bool

    public init(id: String = UUID().uuidString, role: Role, text: String, isStreaming: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.isStreaming = isStreaming
    }
}

@MainActor
@Observable
public final class CodexConversationStore {
    public private(set) var messages: [CodexConversationMessage] = []
    public private(set) var threadID: String?
    public private(set) var isSending = false
    public private(set) var statusText: String?
    public private(set) var lastError: String?
    public var draft = ""

    private let client: CodexClient
    private let threadStartOptions: ThreadStartOptions

    public init(
        client: CodexClient,
        threadID: String? = nil,
        threadStartOptions: ThreadStartOptions = ThreadStartOptions()
    ) {
        self.client = client
        self.threadID = threadID
        self.threadStartOptions = threadStartOptions
    }

    public func resetConversation() {
        messages = []
        threadID = nil
        statusText = nil
        lastError = nil
        draft = ""
    }

    public func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return
        }
        draft = ""
        Task {
            await send(text)
        }
    }

    public func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else {
            return
        }

        isSending = true
        lastError = nil
        messages.append(CodexConversationMessage(role: .user, text: trimmed))

        do {
            let thread: CodexThread
            if let threadID {
                thread = client.thread(id: threadID)
            } else {
                thread = try await client.startThread(options: threadStartOptions)
                self.threadID = thread.id
            }

            let placeholderID = UUID().uuidString
            messages.append(
                CodexConversationMessage(
                    id: placeholderID,
                    role: .assistant,
                    text: "",
                    isStreaming: true
                )
            )

            let stream = try await thread.runStreamed(trimmed)
            for try await event in stream {
                switch event {
                case .turnStarted(_, let turn):
                    statusText = "Turn \(turn.id) started"
                case .agentMessageDelta(let delta):
                    updateMessage(id: placeholderID) { message in
                        message.text += delta.delta
                        message.isStreaming = true
                    }
                case .itemCompleted(_, _, let item):
                    if let text = item.assistantText {
                        updateMessage(id: placeholderID) { message in
                            message.text = text
                            message.isStreaming = false
                        }
                    }
                case .error(_, _, let error, _):
                    lastError = error.message
                    statusText = error.message
                case .turnCompleted(_, let turn):
                    updateMessage(id: placeholderID) { message in
                        message.isStreaming = false
                    }
                    if turn.status == .failed {
                        lastError = turn.error?.message ?? "Turn failed"
                    }
                    statusText = "Turn \(turn.status.rawValue)"
                case .itemStarted, .notification:
                    break
                }
            }
        } catch {
            lastError = error.localizedDescription
            messages.append(CodexConversationMessage(role: .system, text: error.localizedDescription))
            statusText = "Failed"
        }

        isSending = false
    }

    public func loadThread(_ threadID: String) async throws {
        let thread = try await client.readThread(id: threadID, includeTurns: true)
        self.threadID = thread.id
        statusText = "Loaded thread \(thread.id)"
        lastError = nil
        messages = thread.turns.flatMap { turn in
            turn.items.compactMap { item in
                if let text = item.userText {
                    return CodexConversationMessage(role: .user, text: text)
                }
                if let text = item.assistantText {
                    return CodexConversationMessage(role: .assistant, text: text)
                }
                return nil
            }
        }
    }

    private func updateMessage(id: String, _ update: (inout CodexConversationMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else {
            return
        }
        var message = messages[index]
        update(&message)
        messages[index] = message
    }
}
