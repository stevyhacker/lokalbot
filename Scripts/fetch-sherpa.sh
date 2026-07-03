#!/bin/bash
# Fetches the pinned sherpa-onnx offline-ASR CLI (+ its onnxruntime dylibs)
# into Vendor/sherpa-onnx/, which the Xcode build copies into the app bundle.
# This is the ONNX-runtime path for SenseVoice (CJK) and GigaAM (Russian) —
# models WhisperKit/FluidAudio don't cover well. Run as an Xcode pre-build
# phase, mirroring fetch-llama.sh; idempotent and safe to run manually.
#
# Integration model (same as the bundled llama-server): we bundle the
# `sherpa-onnx-offline` binary + its dylibs, copy them out of the bundle on
# first run, and invoke the binary as a subprocess per audio track — no
# C++/ONNX linking into the Swift app, no notarization-of-linked-lib dance.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=v1.13.3   # pinned sherpa-onnx release (macOS arm64 shared)
ARTIFACT="sherpa-onnx-$VERSION-osx-arm64-shared.tar.bz2"
URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/$VERSION/$ARTIFACT"
# SHA-256 of the release artifact — a GitHub release asset can be replaced in
# place, so verify before bundling. Recompute when bumping VERSION:
#   shasum -a 256 <file>
ARCHIVE_SHA256=d67b1a77ca252a4dbe0480255c61eeadc951708d15ac840c12308864496b134d
DEST=Vendor/sherpa-onnx

if [ -x "$DEST/sherpa-onnx-offline" ]; then
  echo "fetch-sherpa: vendor already present"
  exit 0
fi

echo "fetch-sherpa: downloading sherpa-onnx ${VERSION}..."
tmp=$(mktemp -d)
curl -fsSL -o "$tmp/sherpa.tar.bz2" "$URL"
actual=$(shasum -a 256 "$tmp/sherpa.tar.bz2" | cut -d' ' -f1)
if [ "$actual" != "$ARCHIVE_SHA256" ]; then
  echo "fetch-sherpa: SHA-256 mismatch for $ARTIFACT" >&2
  echo "  expected: $ARCHIVE_SHA256" >&2
  echo "  actual:   $actual" >&2
  exit 1
fi
tar -xjf "$tmp/sherpa.tar.bz2" -C "$tmp"
src="$tmp/sherpa-onnx-$VERSION-osx-arm64-shared"

mkdir -p "$DEST"
# Only the offline (file-based) recogniser + its dylibs — the microphone,
# TTS, websocket, and other tools aren't needed. Flat layout; the app spawns
# the binary with DYLD_LIBRARY_PATH pointed at this directory.
cp "$src/bin/sherpa-onnx-offline" "$DEST/"
cp "$src"/lib/*.dylib "$DEST/"
chmod +x "$DEST/sherpa-onnx-offline"
rm -rf "$tmp"

echo "fetch-sherpa: vendor ready ($(du -sh "$DEST" | cut -f1))"
