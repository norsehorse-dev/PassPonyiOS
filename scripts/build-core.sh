#!/usr/bin/env bash
# Build pass-ffi from PassPonyCore into an XCFramework + Swift bindings.
# Run from the repo root: bash scripts/build-core.sh
# Prereqs: rustup with the toolchain pinned by PassPonyCore, Xcode CLT.

set -euo pipefail

CORE="${PASSPONY_CORE:-$HOME/Apps/PassPonyCore}"
OUT_VENDOR="$(pwd)/Vendor"
OUT_GEN="$(pwd)/Sources/Generated"

[[ -d "$CORE/crates/pass-ffi" ]] || {
  echo "PassPonyCore not found at $CORE (set PASSPONY_CORE)"; exit 1; }

# Rust's default iOS baseline is 10.0, far below what the SDK's C output
# (OpenSSL, libgit2) assumes — ___chkstk_darwin is missing at that baseline.
# Pin everything to the app's minimum.
export IPHONEOS_DEPLOYMENT_TARGET=17.0

pushd "$CORE" >/dev/null

# Run inside the core dir so rustup targets the toolchain pinned by its
# rust-toolchain.toml, not the default toolchain.
rustup target add aarch64-apple-ios aarch64-apple-ios-sim

cargo build --release -p pass-ffi
cargo build --release -p pass-ffi --target aarch64-apple-ios
cargo build --release -p pass-ffi --target aarch64-apple-ios-sim

# The core pins its target dir in .cargo/config.toml (a fixed absolute
# path, for reproducible builds), so the artifacts are not under
# $CORE/target. Ask cargo where they went rather than assuming.
TARGET_DIR="$(cargo metadata --format-version 1 --no-deps \
  | python3 -c 'import json, sys; print(json.load(sys.stdin)["target_directory"])')"
[[ -n "$TARGET_DIR" ]] || { echo "Could not resolve cargo's target directory"; exit 1; }

HOST_DYLIB="$TARGET_DIR/release/libpass_ffi.dylib"
[[ -f "$HOST_DYLIB" ]] || HOST_DYLIB="$TARGET_DIR/release/libpass_ffi.so"

rm -rf /tmp/passpony-bindings
cargo run -q --release -p pass-ffi --features cli --bin uniffi-bindgen -- \
  generate --library "$HOST_DYLIB" --language swift \
  --out-dir /tmp/passpony-bindings --no-format

popd >/dev/null

mkdir -p "$OUT_GEN"
cp /tmp/passpony-bindings/pass_ffi.swift "$OUT_GEN/PassFFI.swift"

HEADERS=/tmp/passpony-headers
rm -rf "$HEADERS"; mkdir -p "$HEADERS"
cp /tmp/passpony-bindings/pass_ffiFFI.h "$HEADERS/"
cp /tmp/passpony-bindings/pass_ffiFFI.modulemap "$HEADERS/module.modulemap"

rm -rf "$OUT_VENDOR/PassFFI.xcframework"
mkdir -p "$OUT_VENDOR"
xcodebuild -create-xcframework \
  -library "$TARGET_DIR/aarch64-apple-ios/release/libpass_ffi.a" -headers "$HEADERS" \
  -library "$TARGET_DIR/aarch64-apple-ios-sim/release/libpass_ffi.a" -headers "$HEADERS" \
  -output "$OUT_VENDOR/PassFFI.xcframework"

echo "Done. Now: xcodegen generate && open PassPony.xcodeproj"
