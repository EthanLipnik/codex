#if os(macOS)
import Foundation

public actor ProcessTransport: CodexTransporting {
    private let executableURL: URL
    private let arguments: [String]
    private let workingDirectory: URL?
    private let environment: [String: String]

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var stderrTail: [String] = []

    public init(
        executableURL: URL? = nil,
        arguments: [String] = ["app-server", "--listen", "stdio://"],
        workingDirectory: URL? = nil,
        environment: [String: String] = [:]
    ) throws {
        self.executableURL = try executableURL ?? Self.resolveDefaultCodexExecutable()
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
    }

    public func connect(
        onEvent: @escaping @Sendable (String) async -> Void,
        onClose: @escaping @Sendable (Error?) async -> Void
    ) async throws {
        guard process == nil else {
            return
        }

        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        process.currentDirectoryURL = workingDirectory
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

        try process.run()

        self.process = process
        self.stdinHandle = stdin.fileHandleForWriting

        stdoutTask = Task {
            do {
                for try await line in stdout.fileHandleForReading.bytes.lines {
                    await onEvent(line)
                }
                await onClose(nil)
            } catch {
                await onClose(
                    CodexTransportError.closed(
                        "codex app-server closed stdout. stderr_tail=\(self.stderrSummary())"
                    )
                )
            }
        }

        stderrTask = Task {
            do {
                for try await line in stderr.fileHandleForReading.bytes.lines {
                    self.appendStderrLine(String(line))
                }
            } catch {
                self.appendStderrLine("stderr read failed: \(error.localizedDescription)")
            }
        }
    }

    public func send(_ payload: String) async throws {
        guard let stdinHandle else {
            throw CodexTransportError.notConnected
        }
        let data = Data((payload + "\n").utf8)
        try stdinHandle.write(contentsOf: data)
    }

    public func close() async {
        stdoutTask?.cancel()
        stderrTask?.cancel()
        stdoutTask = nil
        stderrTask = nil

        stdinHandle?.closeFile()
        stdinHandle = nil

        guard let process else {
            return
        }

        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }

        self.process = nil
    }

    public static func resolveDefaultCodexExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> URL {
        if let override = environment["CODEX_EXECUTABLE"] {
            let url = URL(fileURLWithPath: override)
            if fileManager.isExecutableFile(atPath: url.path) {
                return url
            }
        }

        if let pathValue = environment["PATH"] {
            for directory in pathValue.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("codex")
                if fileManager.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }

        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let candidates = [
            cwd.appendingPathComponent("codex-rs/target/debug/codex"),
            cwd.appendingPathComponent("../codex-rs/target/debug/codex"),
            cwd.appendingPathComponent("../../codex-rs/target/debug/codex"),
        ]

        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate.path) {
            return candidate.standardizedFileURL
        }

        throw CodexTransportError.closed(
            "Unable to locate a `codex` executable. Set CODEX_EXECUTABLE or put `codex` on PATH."
        )
    }

    private func appendStderrLine(_ line: String) {
        stderrTail.append(line)
        if stderrTail.count > 40 {
            stderrTail.removeFirst(stderrTail.count - 40)
        }
    }

    private func stderrSummary() -> String {
        stderrTail.joined(separator: "\n")
    }
}
#endif
