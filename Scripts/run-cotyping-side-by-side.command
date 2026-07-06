#!/usr/bin/env bash
# Orchestrates the Cotypist vs LokalBot side-by-side capture:
# installs the freshly built LokalBot, runs both capture legs with the shared
# 25-prompt manifest, merges the report, and restores the desktop state.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"
cd "$REPO"

STAMP=$(date +%Y%m%d-%H%M%S)
COTYPIST_DIR=/tmp/cotyping-cotypist-$STAMP
LOKALBOT_DIR=/tmp/cotyping-lokalbot-$STAMP

echo "== install freshly built LokalBot =="
Scripts/install-app.sh || exit 1
sleep 8

export COTYPING_COMPARE_ACCEPT=1
export COTYPING_COMPARE_FIRST_WAIT_SECONDS=30
export COTYPING_COMPARE_WAIT_SECONDS=6
export COTYPING_COMPARE_ACCEPT_WAIT_SECONDS=0.9

echo "== leg A: Cotypist =="
Scripts/compare-cotyping.sh cotypist "$COTYPIST_DIR" || echo "cotypist leg exited $?"

echo "== leg B: LokalBot =="
open -b me.dotenv.LokalBot; sleep 10
Scripts/compare-cotyping.sh lokalbot "$LOKALBOT_DIR" || echo "lokalbot leg exited $?"

echo "== close TextEdit windows =="
osascript -e 'tell application "TextEdit" to quit saving no' 2>/dev/null || true

echo "== restore both apps running =="
open -b app.cotypist.Cotypist 2>/dev/null || true
open -b me.dotenv.LokalBot 2>/dev/null || true

echo "== merge report =="
python3 Benchmarks/Cotyping/side_by_side.py \
  --cotypist-dir "$COTYPIST_DIR" \
  --lokalbot-dir "$LOKALBOT_DIR" \
  --engine-json /tmp/lokalbot-cotyping-bench.json \
  --output "Benchmarks/Cotyping/results/$STAMP-cotypist-vs-lokalbot.md"
echo "COTYPIST_DIR=$COTYPIST_DIR"
echo "LOKALBOT_DIR=$LOKALBOT_DIR"
date > /tmp/side-by-side-done
