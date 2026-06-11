#!/bin/bash
# Fetches the pinned llama.cpp server build + the default small GGUF model
# into Vendor/, which the Xcode build copies into the app bundle.
# Idempotent: skips anything already present. Runs as an Xcode pre-build
# phase; safe to run manually.
set -euo pipefail
cd "$(dirname "$0")/.."

TAG=b9587   # pinned llama.cpp release (macOS arm64 tar.gz)
SERVER_DIR=Vendor/llama-cpp
MODEL_DIR=Vendor/llama-models
DEFAULT_MODEL=Qwen3.5-0.8B-Q4_K_M.gguf
DEFAULT_MODEL_URL="https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/$DEFAULT_MODEL"

if [ ! -x "$SERVER_DIR/llama-server" ]; then
  echo "fetch-llama: downloading llama.cpp $TAG…"
  tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/llama.tar.gz" \
    "https://github.com/ggml-org/llama.cpp/releases/download/$TAG/llama-$TAG-bin-macos-arm64.tar.gz"
  tar -xzf "$tmp/llama.tar.gz" -C "$tmp"
  mkdir -p "$SERVER_DIR"
  # Only the server + its dylibs — the rest of the toolkit isn't needed.
  cp "$tmp/llama-$TAG/llama-server" "$SERVER_DIR/"
  cp "$tmp/llama-$TAG"/*.dylib "$SERVER_DIR/"
  chmod +x "$SERVER_DIR/llama-server"
  rm -rf "$tmp"
fi

if [ ! -f "$MODEL_DIR/$DEFAULT_MODEL" ]; then
  echo "fetch-llama: downloading default model $DEFAULT_MODEL (~0.64 GB)…"
  mkdir -p "$MODEL_DIR"
  curl -fSL -o "$MODEL_DIR/$DEFAULT_MODEL.partial" "$DEFAULT_MODEL_URL"
  mv "$MODEL_DIR/$DEFAULT_MODEL.partial" "$MODEL_DIR/$DEFAULT_MODEL"
fi

echo "fetch-llama: vendor ready"
