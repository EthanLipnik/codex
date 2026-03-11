import Foundation

/// Controls how the embedded Rust runtime should identify the source of a session.
public enum CodexEmbeddedSessionSource: String, Sendable, Equatable {
    case cli
    case exec
    case appServer
}

/// Configures the embedded Rust runtime used by ``CodexClient/embedded(runtimeConfiguration:configuration:)``.
public struct CodexEmbeddedRuntimeConfiguration: Sendable, Equatable {
    public var codexHome: URL?
    public var workingDirectory: URL?
    public var sessionSource: CodexEmbeddedSessionSource
    public var enableCodexAPIKeyEnvironment: Bool
    public var channelCapacity: Int

    public init(
        codexHome: URL? = nil,
        workingDirectory: URL? = nil,
        sessionSource: CodexEmbeddedSessionSource = .appServer,
        enableCodexAPIKeyEnvironment: Bool = false,
        channelCapacity: Int = 256
    ) {
        self.codexHome = codexHome
        self.workingDirectory = workingDirectory
        self.sessionSource = sessionSource
        self.enableCodexAPIKeyEnvironment = enableCodexAPIKeyEnvironment
        self.channelCapacity = channelCapacity
    }

    func bridgeConfiguration(
        clientInfo: CodexClientInfo,
        experimentalAPI: Bool,
        fileManager: FileManager = .default
    ) -> CodexEmbeddedBridgeConfiguration {
        let resolvedCodexHome = codexHome ?? Self.defaultCodexHome(fileManager: fileManager)
        let resolvedWorkingDirectory = workingDirectory ?? resolvedCodexHome
        return CodexEmbeddedBridgeConfiguration(
            clientName: clientInfo.name,
            clientVersion: clientInfo.version,
            codexHome: resolvedCodexHome.path,
            cwd: resolvedWorkingDirectory.path,
            experimentalApi: experimentalAPI,
            enableCodexApiKeyEnv: enableCodexAPIKeyEnvironment,
            optOutNotificationMethods: [],
            sessionSource: sessionSource.rawValue,
            channelCapacity: channelCapacity
        )
    }

    static func defaultCodexHome(fileManager: FileManager = .default) -> URL {
        let baseDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return baseDirectory
            .appendingPathComponent("Codex", isDirectory: true)
    }
}

struct CodexEmbeddedBridgeConfiguration: Encodable {
    let clientName: String
    let clientVersion: String
    let codexHome: String
    let cwd: String
    let experimentalApi: Bool
    let enableCodexApiKeyEnv: Bool
    let optOutNotificationMethods: [String]
    let sessionSource: String
    let channelCapacity: Int
}
