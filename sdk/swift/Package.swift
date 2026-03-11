// swift-tools-version: 6.0
import Foundation
import PackageDescription

let embeddedBridgePath = "Artifacts/CodexEmbeddedBridge.xcframework"
let hasEmbeddedBridge = FileManager.default.fileExists(atPath: embeddedBridgePath)

var codexSwiftDependencies: [Target.Dependency] = []
var packageTargets: [Target] = []

if hasEmbeddedBridge {
    packageTargets.append(
        .binaryTarget(
            name: "CodexEmbeddedBridge",
            path: embeddedBridgePath
        )
    )
    codexSwiftDependencies.append(
        .target(
            name: "CodexEmbeddedBridge",
            condition: .when(platforms: [.iOS])
        )
    )
}

let package = Package(
    name: "CodexSwift",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CodexSwift",
            targets: ["CodexSwift"]
        ),
    ],
    targets: packageTargets + [
        .target(
            name: "CodexSwift",
            dependencies: codexSwiftDependencies,
            path: "Sources/CodexSwift"
        ),
        .testTarget(
            name: "CodexSwiftTests",
            dependencies: ["CodexSwift"],
            path: "Tests/CodexSwiftTests"
        ),
    ]
)
