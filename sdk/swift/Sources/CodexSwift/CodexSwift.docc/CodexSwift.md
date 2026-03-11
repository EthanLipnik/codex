# ``CodexSwift``

Build SwiftUI apps on top of Codex while keeping the underlying runtime in Rust.

## Overview

`CodexSwift` exposes the Codex app-server protocol as a Swift package.

On iOS, the preferred entry point is ``CodexClient/embedded(runtimeConfiguration:configuration:)``.
That boots the Rust `codex-app-server` runtime in-process through the embedded bridge, so your app
does not need to manage a websocket service or a separate helper process.

When working from a source checkout, run `sdk/swift/Scripts/build-embedded-bridge.sh` once before
trying to use the embedded iOS runtime. The package can still resolve without the generated
XCFramework, but the embedded entry point is only available after that build step.

The package also includes higher-level types that make SwiftUI integration straightforward:

- ``CodexClient`` for lifecycle and thread management
- ``CodexThread`` for running turns
- ``CodexConversationStore`` for a simple observable chat-style store
- ``CodexEmbeddedRuntimeConfiguration`` for on-device runtime setup

## Topics

### Essentials

- <doc:IntegratingCodexOnIOS>

### Primary Symbols

- ``CodexClient``
- ``CodexClient/embedded(runtimeConfiguration:configuration:)``
- ``CodexConfiguration``
- ``CodexEmbeddedRuntimeConfiguration``
- ``CodexConversationStore``
