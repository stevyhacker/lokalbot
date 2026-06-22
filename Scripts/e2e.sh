#!/bin/bash
# LokalBotV2 end-to-end test suite. Drives the REAL app binary headlessly:
# real audio (synthesized with `say`), real CoreML transcription, the real
# bundled llama.cpp server, real SQLite. Run on a Mac with the app built:
#   Scripts/install-app.sh && Scripts/e2e.sh
# Flows needing TCC permissions (screenshots) SKIP instead of failing when
# the permission is missing, so the suite is useful pre- and post-grant.
set -uo pipefail

BIN="${LOKALBOTV2_APP:-/Applications/LokalBotV2.app}/Contents/MacOS/LokalBotV2"
ROOT="$HOME/Library/Application Support/com.dotenv.LokalBotV2"
[ -x "$BIN" ] || { echo "no binary at $BIN — run Scripts/install-app.sh first"; exit 2; }

P=0; F=0; S=0
pass() { echo "  ✅ $1"; P=$((P+1)); }
fail() { echo "  ❌ $1"; F=$((F+1)); }
skip() { echo "  ⏭️  $1"; S=$((S+1)); }

echo "== T1: manual recording (mic → m4a + meta.json) =="
OUT=$("$BIN" --record 4 2>/dev/null | tail -1); RC=$?
DIR="${OUT#*→ }"
if [ "$RC" -eq 3 ]; then
  skip "microphone permission not granted yet"
elif [[ "$OUT" == *"--record: done"* && -s "$DIR/mic.m4a" && -s "$DIR/meta.json" ]]; then
  SIZE=$(stat -f%z "$DIR/mic.m4a")
  [ "$SIZE" -gt 5000 ] && pass "recorded mic.m4a (${SIZE}B) + meta.json" \
                       || fail "mic.m4a suspiciously small (${SIZE}B)"
  rm -rf "$DIR"   # don't pollute the library with 4-second clips
else
  fail "record flow: $OUT"
fi

echo "== T2: transcribe + summarize (dual-track, Me/Them, Markdown) =="
FIX="$ROOT/meetings/2026/06/e2e-fixture"
rm -rf "$FIX"; mkdir -p "$FIX"
say -v Samantha -o /tmp/e2e_mic.aiff "Let us decide on the caching layer. I propose Redis because of pub sub support. I will draft the eviction policy document by Thursday." 2>/dev/null
say -v Daniel -o /tmp/e2e_sys.aiff "Agreed on Redis. One open question, do we need cluster mode from day one? Please benchmark failover latency first." 2>/dev/null
afconvert -f m4af -d aac /tmp/e2e_mic.aiff "$FIX/mic.m4a"
afconvert -f m4af -d aac /tmp/e2e_sys.aiff "$FIX/system.m4a"
cat > "$FIX/meta.json" <<'EOF'
{"id":"7E57C0DE-0000-4000-8000-00000000E2E1","title":"E2E fixture","appName":"E2E",
 "startedAt":"2026-06-10T09:00:00Z","endedAt":"2026-06-10T09:02:00Z",
 "relativePath":"meetings/2026/06/e2e-fixture","hasSystemTrack":true}
EOF
"$BIN" --process "$FIX" >/dev/null 2>&1
grep -q '"speaker" : "me"' "$FIX/transcript.json" 2>/dev/null \
  && grep -q '"speaker" : "them"' "$FIX/transcript.json" \
  && pass "transcript.json has both speakers" || fail "speaker attribution"
grep -qi "redis" "$FIX/transcript.md" 2>/dev/null \
  && pass "transcription accurate ('Redis' survived)" || fail "transcript content"
grep -q "^## TL;DR" "$FIX/summary.md" 2>/dev/null \
  && grep -q "^## Action items" "$FIX/summary.md" \
  && pass "summary.md has TL;DR + Action items sections" || fail "summary sections"

echo "== T3: keyword search (FTS5) =="
"$BIN" --search "eviction policy" 2>/dev/null | grep -q "\[segment\]" \
  && pass "exact keyword hits a transcript segment" || fail "keyword search"

echo "== T4: prefix search (search-as-you-type) =="
"$BIN" --search "failov" 2>/dev/null | grep -q "«failover»" \
  && pass "prefix 'failov' matches 'failover'" || fail "prefix search"

echo "== T5: semantic search (embeddings, zero keyword overlap) =="
"$BIN" --search "which datastore did the team pick for caching" 2>/dev/null | grep -q "\[≈" \
  && pass "meaning-only query finds the Redis discussion" || fail "semantic search"

echo "== T6: screenshot + OCR + encryption =="
"$BIN" --shot-test >/dev/null 2>&1
case $? in
  0) LAST=$(sqlite3 "$ROOT/lokalbotv2.sqlite" "SELECT path FROM screenshots WHERE path!='' ORDER BY ts DESC LIMIT 1")
     if [ -n "$LAST" ] && ! xxd -l 12 "$LAST" | grep -q ftyp; then
       pass "capture ok, file encrypted (no HEIC magic)"
     else fail "capture row exists but file looks wrong"; fi ;;
  3) skip "screen recording permission not granted yet" ;;
  *) fail "shot-test errored — see $ROOT/debug.log" ;;
esac

echo "== T7: day digest (activity + meetings → journal/*.md) =="
OUT=$("$BIN" --digest today 2>/dev/null | tail -1)
JOURNAL="${OUT#*: }"; JOURNAL="${JOURNAL%% (*}"
if [[ "$OUT" == *"--digest: /"* && -s "$JOURNAL" ]] && grep -q "^## " "$JOURNAL"; then
  pass "digest written: $(basename "$JOURNAL")"
else fail "digest: $OUT"; fi

echo "== T8: digest folds in screenshot OCR, not just window titles =="
# Seed today's OCR with a proper noun that appears in NO window title or
# meeting, so if it lands in the digest it can only have come from the
# screenshot -> OCR path wired into generateDayDigest. A generic activity
# block gives the day material; its title carries no token.
NOW=$(date +%s)
sqlite3 -cmd ".timeout 5000" "$ROOT/lokalbotv2.sqlite" \
  "INSERT INTO ocr_fts (text, ts, app) VALUES ('Working through the Project Zephyrus migration runbook: rollback steps, feature flags, and the on-call rota for the cutover.', $NOW, 'Safari');" 2>/dev/null
sqlite3 -cmd ".timeout 5000" "$ROOT/lokalbotv2.sqlite" \
  "INSERT INTO activity_blocks (app, title, start, end) VALUES ('Safari', 'Internal wiki', $((NOW-600)), $NOW);" 2>/dev/null
OUT=$("$BIN" --digest today 2>/dev/null | tail -1)
JOURNAL="${OUT#*: }"; JOURNAL="${JOURNAL%% (*}"
if [[ "$OUT" == *"--digest: /"* && -s "$JOURNAL" ]]; then
  grep -qi "zephyrus" "$JOURNAL" \
    && pass "OCR'd screen text reached the digest ('Zephyrus' came only from screen text)" \
    || fail "digest written but OCR token absent — screenshots not feeding the summary"
else
  fail "digest: $OUT"
fi
# Undo the seed so the suite never pollutes the real library.
sqlite3 -cmd ".timeout 5000" "$ROOT/lokalbotv2.sqlite" \
  "DELETE FROM ocr_fts WHERE ts=$NOW; DELETE FROM activity_blocks WHERE start=$((NOW-600));" 2>/dev/null

echo
echo "passed: $P · failed: $F · skipped: $S"
[ "$F" -eq 0 ]
