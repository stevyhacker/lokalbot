#!/bin/bash
# Builds the pinned pi runtime bundle that LokalBot's Agent Mode downloads
# on first enable, and (with --install-local) installs Bun + the bundle into
# this Mac's Application Support for development and integration tests.
#
# Usage:
#   Scripts/build-pi-bundle.sh                 # build dist/lokalbot-pi-bundle-<ver>.tar.gz, print SHA256
#   Scripts/build-pi-bundle.sh --install-local # also install into Application Support
#
# Release flow (RELEASING.md): build ONCE, upload that exact tarball to the
# GitHub release tagged agent-runtime-<ver>, and commit the printed SHA256
# into AgentRuntimeManifest.current. The tarball is not byte-reproducible,
# so never rebuild without also updating the manifest.
set -euo pipefail

PI_VERSION="0.80.5"
BUN_VERSION="1.3.14"
# From SHASUMS256.txt on the bun-v$BUN_VERSION GitHub release (darwin-aarch64).
# Recompute when bumping BUN_VERSION.
BUN_ZIP_SHA256="d8b96221828ad6f97ac7ac0ab7e95872341af763001e8803e8267652c2652620"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$REPO_ROOT/dist"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

command -v bun >/dev/null || { echo "error: bun not on PATH (brew install oven-sh/bun/bun)"; exit 1; }

echo "==> staging pi $PI_VERSION with host bun $(bun --version)"
echo '{"name":"lokalbot-pi-bundle","private":true}' > "$STAGE/package.json"
# --ignore-scripts: never execute postinstall hooks from the dependency tree
(cd "$STAGE" && bun add "@earendil-works/pi-coding-agent@$PI_VERSION" --ignore-scripts)

CLI="$STAGE/node_modules/@earendil-works/pi-coding-agent/dist/cli.js"
test -f "$CLI" || { echo "error: cli.js missing after install"; exit 1; }

mkdir -p "$DIST"
TARBALL="$DIST/lokalbot-pi-bundle-$PI_VERSION.tar.gz"
tar -czf "$TARBALL" -C "$STAGE" package.json node_modules
SHA="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
echo "==> built  $TARBALL"
echo "==> sha256 $SHA"

if [[ "${1:-}" == "--install-local" ]]; then
    RUNTIME="$HOME/Library/Application Support/me.dotenv.LokalBot/agent-runtime"
    echo "==> installing runtime into $RUNTIME"
    rm -rf "$RUNTIME"
    mkdir -p "$RUNTIME/pi" "$RUNTIME/bun"
    tar -xzf "$TARBALL" -C "$RUNTIME/pi"
    BUNZIP="$STAGE/bun.zip"
    curl -fsSL -o "$BUNZIP" \
        "https://github.com/oven-sh/bun/releases/download/bun-v$BUN_VERSION/bun-darwin-aarch64.zip"
    ACTUAL="$(shasum -a 256 "$BUNZIP" | awk '{print $1}')"
    if [[ "$ACTUAL" != "$BUN_ZIP_SHA256" ]]; then
        echo "error: SHA-256 mismatch for bun-darwin-aarch64.zip" >&2
        echo "  expected: $BUN_ZIP_SHA256" >&2
        echo "  actual:   $ACTUAL" >&2
        exit 1
    fi
    (cd "$STAGE" && unzip -q "$BUNZIP")
    cp "$STAGE/bun-darwin-aarch64/bun" "$RUNTIME/bun/bun"
    chmod 755 "$RUNTIME/bun/bun"
    echo "==> installed bun $("$RUNTIME/bun/bun" --version)"
fi
