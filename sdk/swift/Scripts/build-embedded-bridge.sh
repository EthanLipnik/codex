#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWIFT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${SWIFT_ROOT}/../.." && pwd)"
RUST_ROOT="${REPO_ROOT}/codex-rs"
HEADER_ROOT="${SWIFT_ROOT}/Bridge/include"
BUILD_ROOT="${SWIFT_ROOT}/.build/embedded-bridge"
OUTPUT_ROOT="${SWIFT_ROOT}/Artifacts/CodexEmbeddedBridge.xcframework"
LIB_NAME="libcodex_swift_bridge.a"
DEVICE_LIB="${RUST_ROOT}/target/aarch64-apple-ios/release/${LIB_NAME}"
SIM_ARM64_LIB="${RUST_ROOT}/target/aarch64-apple-ios-sim/release/${LIB_NAME}"
SIM_X86_64_LIB="${RUST_ROOT}/target/x86_64-apple-ios/release/${LIB_NAME}"
SIM_UNIVERSAL_LIB="${BUILD_ROOT}/iphonesimulator/${LIB_NAME}"

export PATH="${HOME}/.cargo/bin:/opt/homebrew/opt/rustup/bin:${PATH}"

pushd "${RUST_ROOT}" >/dev/null
cargo build -p codex-swift-bridge --release --target aarch64-apple-ios
cargo build -p codex-swift-bridge --release --target aarch64-apple-ios-sim
cargo build -p codex-swift-bridge --release --target x86_64-apple-ios
popd >/dev/null

rm -rf "${BUILD_ROOT}" "${OUTPUT_ROOT}"
mkdir -p "$(dirname "${SIM_UNIVERSAL_LIB}")"

lipo -create \
  "${SIM_ARM64_LIB}" \
  "${SIM_X86_64_LIB}" \
  -output "${SIM_UNIVERSAL_LIB}"

xcodebuild -create-xcframework \
  -library "${DEVICE_LIB}" \
  -headers "${HEADER_ROOT}" \
  -library "${SIM_UNIVERSAL_LIB}" \
  -headers "${HEADER_ROOT}" \
  -output "${OUTPUT_ROOT}"
