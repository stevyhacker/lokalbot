#!/bin/sh
# Validate the preserved long film and legacy short film as independent
# HyperFrames entry points. Both roots live together for production, but
# checking them together makes the runtime merge their audio tracks.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HYPERFRAMES_VERSION=0.7.42
CHECK_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/lokalbot-hero-check.XXXXXX")
trap 'rm -rf "$CHECK_ROOT"' EXIT HUP INT TERM

check_composition() {
  label=$1
  source=$2
  captions=$3
  target="$CHECK_ROOT/$label"
  mkdir -p "$target"
  ln -s "$ROOT/$source" "$target/index.html"
  ln -s "$ROOT/assets" "$target/assets"
  ln -s "$ROOT/$captions" "$target/$captions"

  echo "Checking $label composition"
  npx --yes "hyperframes@$HYPERFRAMES_VERSION" lint "$target"
  npx --yes "hyperframes@$HYPERFRAMES_VERSION" validate "$target"
  npx --yes "hyperframes@$HYPERFRAMES_VERSION" inspect "$target"
}

check_composition long index.html captions.generated.js
check_composition short short.html captions-short.generated.js
