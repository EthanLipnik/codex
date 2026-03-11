import Foundation

/// Errors surfaced by ``CodexClient`` when a turn or transport fails.
public enum CodexClientError: LocalizedError, Sendable, Equatable {
    case invalidResponse(String)
    case turnFailed(TurnError)
    case transportClosed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse(let message):
            return message
        case .turnFailed(let error):
            return error.message
        case .transportClosed(let message):
            return message
        }
    }
}

private struct InitializeResponse: Sendable, Codable, Equatable {
    let serverInfo: ServerInfo?
    let userAgent: String?
}

private struct ServerInfo: Sendable, Codable, Equatable {
    let name: String?
    let version: String?
}

private struct ThreadEnvelopeResponse: Sendable, Codable {
    let thread: ThreadSummary
}

private struct ThreadReadResponse: Sendable, Codable {
    let thread: ThreadSummary
}

private struct TurnEnvelopeResponse: Sendable, Codable {
    let turn: TurnSummary
}

private struct ThreadListEnvelopeResponse: Sendable, Codable {
    let data: [ThreadSummary]
    let nextCursor: String?
}

private struct ItemNotificationPayload: Sendable, Codable, Equatable {
    let threadID: String
    let turnID: String
    let item: CodexThreadItem

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case item
    }
}

private struct TurnCompletedNotificationPayload: Sendable, Codable, Equatable {
    let threadID: String
    let turn: TurnSummary

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turn
    }
}

private struct ErrorNotificationPayload: Sendable, Codable, Equatable {
    let threadID: String
    let turnID: String
    let error: TurnError
    let willRetry: Bool

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case error
        case willRetry
    }
}

/// High-level Swift wrapper around the Codex app-server JSON-RPC API.
public actor CodexClient {
    private let transport: any CodexTransporting
    private let configuration: CodexConfiguration

    private var nextRequestID = 1
    private var isStarted = false
    private var isClosed = false
    private var activeTurnConsumer: String?

    private var pendingResponses: [JSONRPCID: CheckedContinuation<JSONValue, Error>] = [:]
    private var queuedNotifications: [CodexNotification] = []
    private var notificationWaiters: [CheckedContinuation<CodexNotification, Error>] = []

    public init(
        transport: any CodexTransporting,
        configuration: CodexConfiguration = CodexConfiguration()
    ) {
        self.transport = transport
        self.configuration = configuration
    }

    public static func webSocket(
        url: URL,
        configuration: CodexConfiguration = CodexConfiguration()
    ) async throws -> CodexClient {
        let client = CodexClient(
            transport: WebSocketTransport(url: url),
            configuration: configuration
        )
        try await client.start()
        return client
    }

    #if os(macOS)
    public static func localProcess(
        executableURL: URL? = nil,
        arguments: [String] = ["app-server", "--listen", "stdio://"],
        workingDirectory: URL? = nil,
        environment: [String: String] = [:],
        configuration: CodexConfiguration = CodexConfiguration()
    ) async throws -> CodexClient {
        let transport = try ProcessTransport(
            executableURL: executableURL,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment
        )
        let client = CodexClient(transport: transport, configuration: configuration)
        try await client.start()
        return client
    }
    #endif

    public func start() async throws {
        guard !isStarted else {
            return
        }

        let client = self
        try await transport.connect(
            onEvent: { line in
                await client.handleInboundLine(line)
            },
            onClose: { error in
                await client.handleTransportClosed(error)
            }
        )

        _ = try await request(
            "initialize",
            params: [
                "clientInfo": .object([
                    "name": .string(configuration.clientInfo.name),
                    "title": .string(configuration.clientInfo.title),
                    "version": .string(configuration.clientInfo.version),
                ]),
                "capabilities": .object(capabilitiesPayload()),
            ],
            responseType: InitializeResponse.self
        )
        try await notify("initialized")
        isStarted = true
    }

    public func close() async {
        await transport.close()
        await handleTransportClosed(CodexClientError.transportClosed("Closed by client"))
    }

    public func startThread(options: ThreadStartOptions = ThreadStartOptions()) async throws -> CodexThread {
        try await ensureStarted()
        let summary = try await createThread(options: options)
        return CodexThread(id: summary.id, client: self)
    }

    public nonisolated func thread(id: String) -> CodexThread {
        CodexThread(id: id, client: self)
    }

    public func resumeThread(id: String, options: ThreadStartOptions = ThreadStartOptions()) async throws -> CodexThread {
        try await ensureStarted()
        let _: ThreadEnvelopeResponse = try await request(
            "thread/resume",
            params: ["threadId": .string(id)].mergingThreadOptions(options),
            responseType: ThreadEnvelopeResponse.self
        )
        return CodexThread(id: id, client: self)
    }

    public func listThreads(limit: Int? = nil, cursor: String? = nil) async throws -> ThreadListPage {
        try await ensureStarted()
        var params: JSONObject = [:]
        if let limit {
            params["limit"] = .int(Int64(limit))
        }
        if let cursor {
            params["cursor"] = .string(cursor)
        }
        let response: ThreadListEnvelopeResponse = try await request(
            "thread/list",
            params: params,
            responseType: ThreadListEnvelopeResponse.self
        )
        return ThreadListPage(data: response.data, nextCursor: response.nextCursor)
    }

    public func readThread(id: String, includeTurns: Bool = false) async throws -> ThreadSummary {
        try await ensureStarted()
        let response: ThreadReadResponse = try await request(
            "thread/read",
            params: [
                "threadId": .string(id),
                "includeTurns": .bool(includeTurns),
            ],
            responseType: ThreadReadResponse.self
        )
        return response.thread
    }

    func runTurn(
        threadID: String,
        input: [CodexUserInput],
        options: TurnOptions = TurnOptions()
    ) async throws -> TurnResult {
        let stream = try await runTurnStreamed(threadID: threadID, input: input, options: options)
        var items: [CodexThreadItem] = []
        var finalResponse = ""
        var finalTurn: TurnSummary?

        for try await event in stream {
            switch event {
            case .agentMessageDelta(let delta):
                finalResponse += delta.delta
            case .itemCompleted(_, _, let item):
                items.append(item)
                if let text = item.assistantText {
                    finalResponse = text
                }
            case .turnCompleted(_, let turn):
                finalTurn = turn
            case .turnStarted, .itemStarted, .error, .notification:
                break
            }
        }

        guard let finalTurn else {
            throw CodexClientError.invalidResponse("Missing terminal turn/completed notification.")
        }
        if finalTurn.status == .failed, let error = finalTurn.error {
            throw CodexClientError.turnFailed(error)
        }
        return TurnResult(
            threadID: threadID,
            turn: finalTurn,
            items: items,
            finalResponse: finalResponse
        )
    }

    func runTurnStreamed(
        threadID: String,
        input: [CodexUserInput],
        options: TurnOptions = TurnOptions()
    ) async throws -> AsyncThrowingStream<CodexTurnEvent, Error> {
        try await ensureStarted()

        let response: TurnEnvelopeResponse = try await request(
            "turn/start",
            params: turnParams(threadID: threadID, input: input, options: options),
            responseType: TurnEnvelopeResponse.self
        )

        let turn = response.turn
        try acquireTurnConsumer(turn.id)
        let client = self

        return AsyncThrowingStream { continuation in
            continuation.yield(.turnStarted(threadID: threadID, turn: turn))

            let task = Task {
                do {
                    defer {
                        Task {
                            await client.releaseTurnConsumer(turn.id)
                        }
                    }

                    while !Task.isCancelled {
                        let notification = try await client.nextNotification()
                        guard let event = try await client.mapTurnEvent(
                            notification: notification,
                            expectedThreadID: threadID,
                            expectedTurnID: turn.id
                        ) else {
                            continue
                        }

                        continuation.yield(event)
                        if case .turnCompleted = event {
                            continuation.finish()
                            return
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
                Task {
                    await client.releaseTurnConsumer(turn.id)
                }
            }
        }
    }

    private func createThread(options: ThreadStartOptions) async throws -> ThreadSummary {
        let response: ThreadEnvelopeResponse = try await request(
            "thread/start",
            params: try threadStartParams(options),
            responseType: ThreadEnvelopeResponse.self
        )
        return response.thread
    }

    private func ensureStarted() async throws {
        guard !isStarted else {
            return
        }
        try await start()
    }

    private func request<T: Decodable>(
        _ method: String,
        params: JSONObject,
        responseType: T.Type
    ) async throws -> T {
        let result = try await requestRaw(method, params: params)
        return try result.decoded(as: responseType)
    }

    private func requestRaw(_ method: String, params: JSONObject) async throws -> JSONValue {
        guard !isClosed else {
            throw CodexClientError.transportClosed("The client is already closed.")
        }

        let requestID = JSONRPCID.int(nextRequestID)
        nextRequestID += 1

        let payload = try JSONEncoder().encode(
            JSONRPCMessage(id: requestID, method: method, params: params)
        )
        let line = String(decoding: payload, as: UTF8.self)

        return try await withCheckedThrowingContinuation { continuation in
            pendingResponses[requestID] = continuation
            Task {
                do {
                    try await transport.send(line)
                } catch {
                    self.failPendingResponse(id: requestID, error: error)
                }
            }
        }
    }

    private func notify(_ method: String, params: JSONObject = [:]) async throws {
        let payload = try JSONEncoder().encode(
            JSONRPCMessage(method: method, params: params)
        )
        try await transport.send(String(decoding: payload, as: UTF8.self))
    }

    private func nextNotification() async throws -> CodexNotification {
        if !queuedNotifications.isEmpty {
            return queuedNotifications.removeFirst()
        }

        if isClosed {
            throw CodexClientError.transportClosed("The transport is closed.")
        }

        return try await withCheckedThrowingContinuation { continuation in
            notificationWaiters.append(continuation)
        }
    }

    private func handleInboundLine(_ line: String) async {
        do {
            let message = try JSONDecoder().decode(JSONRPCMessage.self, from: Data(line.utf8))

            switch (message.method, message.id, message.result, message.error) {
            case let (method?, id?, _, _) where message.result == nil && message.error == nil:
                let params = message.params ?? [:]
                let request = CodexServerRequest(id: id, method: method, params: params)
                let result = await configuration.approvalHandler(request)
                try await notifyResponse(id: id, result: result)

            case let (method?, nil, _, _):
                enqueueNotification(CodexNotification(method: method, params: message.params ?? [:]))

            case let (_, id?, result?, nil):
                resumePendingResponse(id: id, result: result)

            case let (_, id?, _, error?):
                resumePendingResponse(id: id, error: error)

            default:
                break
            }
        } catch {
            await handleTransportClosed(error)
        }
    }

    private func notifyResponse(id: JSONRPCID, result: JSONObject) async throws {
        let payload = try JSONEncoder().encode(
            JSONRPCMessage(id: id, result: .object(result))
        )
        try await transport.send(String(decoding: payload, as: UTF8.self))
    }

    private func handleTransportClosed(_ error: Error?) async {
        guard !isClosed else {
            return
        }
        isClosed = true

        let finalError = error ?? CodexClientError.transportClosed("The transport closed unexpectedly.")

        let pending = pendingResponses
        pendingResponses.removeAll()
        for continuation in pending.values {
            continuation.resume(throwing: finalError)
        }

        let waiters = notificationWaiters
        notificationWaiters.removeAll()
        for continuation in waiters {
            continuation.resume(throwing: finalError)
        }
    }

    private func enqueueNotification(_ notification: CodexNotification) {
        if let waiter = notificationWaiters.first {
            notificationWaiters.removeFirst()
            waiter.resume(returning: notification)
        } else {
            queuedNotifications.append(notification)
        }
    }

    private func resumePendingResponse(id: JSONRPCID, result: JSONValue) {
        guard let continuation = pendingResponses.removeValue(forKey: id) else {
            return
        }
        continuation.resume(returning: result)
    }

    private func resumePendingResponse(id: JSONRPCID, error: JSONRPCErrorPayload) {
        guard let continuation = pendingResponses.removeValue(forKey: id) else {
            return
        }
        continuation.resume(throwing: error)
    }

    private func failPendingResponse(id: JSONRPCID, error: Error) {
        guard let continuation = pendingResponses.removeValue(forKey: id) else {
            return
        }
        continuation.resume(throwing: error)
    }

    private func acquireTurnConsumer(_ turnID: String) throws {
        if let activeTurnConsumer {
            throw CodexClientError.invalidResponse(
                "Concurrent turn streams are not supported. Active turn: \(activeTurnConsumer)"
            )
        }
        activeTurnConsumer = turnID
    }

    private func releaseTurnConsumer(_ turnID: String) {
        if activeTurnConsumer == turnID {
            activeTurnConsumer = nil
        }
    }

    private func mapTurnEvent(
        notification: CodexNotification,
        expectedThreadID: String,
        expectedTurnID: String
    ) async throws -> CodexTurnEvent? {
        switch notification.method {
        case "item/agentMessage/delta":
            let payload = try JSONValue.object(notification.params).decoded(as: AgentMessageDelta.self)
            guard payload.threadID == expectedThreadID, payload.turnID == expectedTurnID else {
                return nil
            }
            return .agentMessageDelta(payload)

        case "item/started":
            let payload = try JSONValue.object(notification.params).decoded(as: ItemNotificationPayload.self)
            guard payload.threadID == expectedThreadID, payload.turnID == expectedTurnID else {
                return nil
            }
            return .itemStarted(threadID: payload.threadID, turnID: payload.turnID, item: payload.item)

        case "item/completed":
            let payload = try JSONValue.object(notification.params).decoded(as: ItemNotificationPayload.self)
            guard payload.threadID == expectedThreadID, payload.turnID == expectedTurnID else {
                return nil
            }
            return .itemCompleted(threadID: payload.threadID, turnID: payload.turnID, item: payload.item)

        case "error":
            let payload = try JSONValue.object(notification.params).decoded(as: ErrorNotificationPayload.self)
            guard payload.threadID == expectedThreadID, payload.turnID == expectedTurnID else {
                return nil
            }
            return .error(
                threadID: payload.threadID,
                turnID: payload.turnID,
                error: payload.error,
                willRetry: payload.willRetry
            )

        case "turn/completed":
            let payload = try JSONValue.object(notification.params).decoded(as: TurnCompletedNotificationPayload.self)
            guard payload.threadID == expectedThreadID, payload.turn.id == expectedTurnID else {
                return nil
            }
            return .turnCompleted(threadID: payload.threadID, turn: payload.turn)

        default:
            if notificationMatchesTurn(notification, expectedThreadID: expectedThreadID, expectedTurnID: expectedTurnID) {
                return .notification(notification)
            }
            return nil
        }
    }

    private func notificationMatchesTurn(
        _ notification: CodexNotification,
        expectedThreadID: String,
        expectedTurnID: String
    ) -> Bool {
        let threadID = notification.params["threadId"]?.stringValue
        let turnID = notification.params["turnId"]?.stringValue
        return threadID == expectedThreadID && turnID == expectedTurnID
    }

    private func capabilitiesPayload() -> JSONObject {
        var payload = configuration.additionalCapabilities
        payload["experimentalApi"] = .bool(configuration.experimentalAPI)
        return payload
    }

    private func threadStartParams(_ options: ThreadStartOptions) throws -> JSONObject {
        var params = options.additionalParams
        if let model = options.model {
            params["model"] = .string(model)
        }
        if let workingDirectory = options.workingDirectory {
            params["cwd"] = .string(workingDirectory)
        }
        if let approvalPolicy = options.approvalPolicy {
            params["approvalPolicy"] = .string(approvalPolicy.rawValue)
        }
        if let sandbox = options.sandbox {
            params["sandbox"] = try JSONValue.encoded(sandbox)
        }
        if let personality = options.personality {
            params["personality"] = .string(personality)
        }
        return params
    }

    private func turnParams(
        threadID: String,
        input: [CodexUserInput],
        options: TurnOptions
    ) throws -> JSONObject {
        var params = options.additionalParams
        params["threadId"] = .string(threadID)
        params["input"] = try JSONValue.encoded(input)
        return params
    }
}

private extension JSONObject {
    func mergingThreadOptions(_ options: ThreadStartOptions) -> JSONObject {
        var params = self
        if let model = options.model {
            params["model"] = .string(model)
        }
        if let workingDirectory = options.workingDirectory {
            params["cwd"] = .string(workingDirectory)
        }
        if let approvalPolicy = options.approvalPolicy {
            params["approvalPolicy"] = .string(approvalPolicy.rawValue)
        }
        if let personality = options.personality {
            params["personality"] = .string(personality)
        }
        params.mergeReplacing(options.additionalParams)
        return params
    }
}
