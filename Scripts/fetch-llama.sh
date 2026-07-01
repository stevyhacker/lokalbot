#!/bin/bash
# Fetches the pinned llama.cpp server build into Vendor/, which the Xcode build
# copies into the app bundle. GGUF models are intentionally user-selected and
# downloaded into Application Support, not bundled with the DMG.
# Idempotent: skips anything already present. Runs as an Xcode pre-build
# phase; safe to run manually.
set -euo pipefail
cd "$(dirname "$0")/.."

TAG=b9844   # pinned llama.cpp release (macOS arm64 tar.gz)
SERVER_DIR=Vendor/llama-cpp

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
HEADERS=(
  "include/llama.h"
  "ggml/include/ggml.h"
  "ggml/include/ggml-backend.h"
  "ggml/include/ggml-alloc.h"
  "ggml/include/ggml-cpu.h"
  "ggml/include/ggml-metal.h"
  "ggml/include/ggml-opt.h"
  "ggml/include/gguf.h"
)
mkdir -p "$INCLUDE_DIR"
for h in "${HEADERS[@]}"; do
  dest="$INCLUDE_DIR/$(basename "$h")"
  if [ ! -f "$dest" ]; then
    echo "fetch-llama: downloading header $(basename "$h")"
    curl -fsSL "$RAW_BASE/$h" -o "$dest"
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
