#!/bin/bash
# Fetches the pinned llama.cpp server build into Vendor/, which the Xcode build
# copies into the app bundle. GGUF models are intentionally user-selected and
# downloaded into Application Support, not bundled with the DMG.
# Idempotent: skips anything already present. Runs as an Xcode pre-build
# phase; safe to run manually.
set -euo pipefail
cd "$(dirname "$0")/.."

TAG=b9844   # pinned llama.cpp release (macOS arm64 tar.gz)
# SHA-256 of the release artifact + each header at that tag. A tag or release
# asset on GitHub can be replaced in place, so every fetched file is verified
# before it enters the app bundle. Recompute when bumping TAG:
#   shasum -a 256 <file>
ARCHIVE_SHA256=0ca1c57a3f9656f02bc05215e52d6343054060196b0744946a174af925efa61c
SERVER_DIR=Vendor/llama-cpp

# verify_sha256 <file> <expected> — hard-fails the build on mismatch.
verify_sha256() {
  local actual
  actual=$(shasum -a 256 "$1" | cut -d' ' -f1)
  if [ "$actual" != "$2" ]; then
    echo "fetch-llama: SHA-256 mismatch for $1" >&2
    echo "  expected: $2" >&2
    echo "  actual:   $actual" >&2
    exit 1
  fi
}

installed_tag=""
if [ -x "$SERVER_DIR/llama-server" ]; then
  installed_version=$("$SERVER_DIR/llama-server" --version 2>&1 | sed -n 's/^version: \([0-9][0-9]*\).*/\1/p' | head -n 1)
  if [ -n "$installed_version" ]; then
    installed_tag="b$installed_version"
  fi
fi

if [ "$installed_tag" != "$TAG" ]; then
  echo "fetch-llama: downloading llama.cpp ${TAG}..."
  tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/llama.tar.gz" \
    "https://github.com/ggml-org/llama.cpp/releases/download/$TAG/llama-$TAG-bin-macos-arm64.tar.gz"
  verify_sha256 "$tmp/llama.tar.gz" "$ARCHIVE_SHA256"
  tar -xzf "$tmp/llama.tar.gz" -C "$tmp"
  rm -rf "$SERVER_DIR"
  mkdir -p "$SERVER_DIR"
  # Only the server + its dylibs — the rest of the toolkit isn't needed.
  cp "$tmp/llama-$TAG/llama-server" "$SERVER_DIR/"
  cp "$tmp/llama-$TAG"/*.dylib "$SERVER_DIR/"
  chmod +x "$SERVER_DIR/llama-server"
  rm -rf "$tmp"
fi

# --- Public C headers for in-process libllama (LlamaCore module) ---
# Fetched from the pinned source tag so the Swift module compiles against the
# exact b9844 API the vendored dylib exports. Idempotent: skip if present.
INCLUDE_DIR="$SERVER_DIR/include"
RAW_BASE="https://raw.githubusercontent.com/ggml-org/llama.cpp/$TAG"
# "repo-path sha256" pairs (bash 3.2 has no associative arrays).
HEADERS=(
  "include/llama.h 74381910d947f3796395e4bf7fab181165b0a33bcbeea0310447b9f0969c43e2"
  "ggml/include/ggml.h 98c5fcf96279e16c09d42dcba482be1b03434839db723bba4b65518e424ba181"
  "ggml/include/ggml-backend.h a620e815b43a44cc72d5f216629a3a91980335b61bc37eb6b2d0813368c3704f"
  "ggml/include/ggml-alloc.h 94e4cd069b9313b2ceb35dacec901981e0bb478d8bb31035b7126be091998c23"
  "ggml/include/ggml-cpu.h 1aafe97e576ea38c0da57517fb2492955d0b69c1a799842481fc069d6d9d28ef"
  "ggml/include/ggml-metal.h 322f36cd30f3e9e7aad7b5b9bc63078012fd0b7706ac4e24f5721b604f3d8980"
  "ggml/include/ggml-opt.h 3586de1bc8a934b5c72339e2b6937b0641e8f149b512231e666f67de0736eea2"
  "ggml/include/gguf.h 2ddb276a5bece743433160ad863279473431c9d4c171d468bf860a3cda3fbf3f"
)
mkdir -p "$INCLUDE_DIR"
for entry in "${HEADERS[@]}"; do
  h=${entry% *}
  sha=${entry##* }
  dest="$INCLUDE_DIR/$(basename "$h")"
  if [ ! -f "$dest" ]; then
    echo "fetch-llama: downloading header $(basename "$h")"
    # Download beside the destination and only move once verified, so a
    # mismatch never leaves a file the next run's exists-check would skip.
    curl -fsSL "$RAW_BASE/$h" -o "$dest.download"
    verify_sha256 "$dest.download" "$sha"
    mv "$dest.download" "$dest"
  fi
done

# Declare the LlamaCore Clang module over the fetched headers. Generated here
# (not committed) so the whole Vendor/ tree stays reproducible and gitignored,
# matching the dylibs/model. Rewritten every run so it tracks any HEADERS edit.
cat > "$INCLUDE_DIR/module.modulemap" <<'EOF'
module LlamaCore {
    header "llama.h"
    header "ggml.h"
    header "ggml-backend.h"
    header "ggml-alloc.h"
    header "ggml-cpu.h"
    header "ggml-opt.h"
    header "gguf.h"
    export *
}
EOF

echo "fetch-llama: vendor ready"
