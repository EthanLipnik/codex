# Integrating Codex on iOS

@Metadata {
  @TitleHeading("Articles")
}

Embed Codex directly into an iPhone or iPad app by linking the Swift package and starting the
Rust runtime in-process.

## Add the package

Add `sdk/swift` as a local Swift package in Xcode, or point Xcode at a git tag that contains this
package. Link the `CodexSwift` library product to your iOS target.

If you are working from a source checkout, run the embedded bridge build once before trying to use
the iOS runtime:

```bash
sdk/swift/Scripts/build-embedded-bridge.sh
```

That generates `sdk/swift/Artifacts/CodexEmbeddedBridge.xcframework`. After that, the package can
embed Codex directly and you do not need to build or launch an external `codex app-server` from
your app.

## Start the embedded runtime

Create a ``CodexClient`` using ``CodexClient/embedded(runtimeConfiguration:configuration:)``.

```swift
import CodexSwift
import Foundation

func makeClient() async throws -> CodexClient {
    let applicationSupport = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    ).first!

    let runtime = CodexEmbeddedRuntimeConfiguration(
        codexHome: applicationSupport.appendingPathComponent("Codex", isDirectory: true),
        workingDirectory: applicationSupport,
        sessionSource: .appServer,
        enableCodexAPIKeyEnvironment: false
    )

    let configuration = CodexConfiguration(
        clientInfo: CodexClientInfo(
            name: "com.example.myapp",
            title: "My App",
            version: "1.0"
        ),
        experimentalAPI: true
    )

    return try await CodexClient.embedded(
        runtimeConfiguration: runtime,
        configuration: configuration
    )
}
```

## Build a SwiftUI chat surface

``CodexConversationStore`` is the fastest way to stand up a chat UI around a single thread.

```swift
import CodexSwift
import Observation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    var conversation: CodexConversationStore?

    func start() async {
        guard conversation == nil else { return }

        do {
            let client = try await makeClient()
            conversation = CodexConversationStore(
                client: client,
                threadStartOptions: ThreadStartOptions(
                    model: "gpt-5-codex",
                    approvalPolicy: .never,
                    sandbox: .workspaceWrite(networkAccess: true)
                )
            )
        } catch {
            print("Failed to start Codex: \\(error)")
        }
    }
}

struct ConversationView: View {
    @Bindable var store: CodexConversationStore

    var body: some View {
        VStack {
            List(store.messages) { message in
                VStack(alignment: .leading, spacing: 4) {
                    Text(message.role.rawValue.capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(message.text)
                }
            }

            HStack {
                TextField("Ask Codex", text: $store.draft)
                    .textFieldStyle(.roundedBorder)
                Button("Send") {
                    store.sendDraft()
                }
                .disabled(store.isSending)
            }
        }
        .padding()
    }
}

struct ContentView: View {
    @State private var model = AppModel()

    var body: some View {
        Group {
            if let conversation = model.conversation {
                ConversationView(store: conversation)
            } else {
                ProgressView()
                    .task {
                        await model.start()
                    }
            }
        }
    }
}
```

## Work directly with threads when you need more control

If you want a custom UI or command model, start a thread yourself and call ``CodexThread/run(_:options:)``
or ``CodexThread/runStreamed(_:options:)``.

```swift
let client = try await makeClient()
let thread = try await client.startThread()
let result = try await thread.run("Summarize the files in my workspace.")
print(result.finalResponse)
```

## Runtime behavior on iOS

- The Codex runtime is local to the app process.
- The package stores Codex state under your app's Application Support directory by default.
- Core orchestration logic stays in Rust, which keeps rebases against upstream practical.
- Whether responses are fully offline depends on the configured model provider. The embedded
  runtime is local; model execution may still require network access unless you configure a
  provider that runs locally.

## Recommended integration pattern

For most apps:

1. Create one long-lived ``CodexClient`` when the app launches.
2. Wrap it in one or more ``CodexConversationStore`` instances for SwiftUI screens.
3. Keep `codexHome` stable so threads, state, and approvals persist across launches.
4. Use streamed turns for the chat surface, and direct thread APIs for workflows or tools UIs.
