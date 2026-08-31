#!/usr/bin/env bash
set -euo pipefail

# Muter launches the unsigned app-hosted XCTest bundle. On a developer Mac,
# that copied app identity can ask for access to LokalBot's Keychain items.
# Keep mutation execution on an isolated hosted runner so local verification
# remains non-interactive.
if [[ "${CI:-}" != "true" ]]; then
  printf '%s\n' \
    'error: LokalBot mutation tests are CI-only because the Xcode test host can prompt for Keychain access.' >&2
  exit 78
fi

exec /usr/bin/xcodebuild "$@"
