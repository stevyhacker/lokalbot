#!/bin/sh
# Render the natural-speed, 30-second LokalBot showcase cut.
set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PROJECT_DIR="$REPO_ROOT/Video/hero-demo"
VENV_DIR="$PROJECT_DIR/.venv"
HYPERFRAMES_VERSION="0.7.42"
MASTER="$PROJECT_DIR/renders/lokalbot-showcase-short-master.mp4"
FINAL_TMP="$REPO_ROOT/web/assets/hero-demo-short.production.mp4"
FINAL="$REPO_ROOT/web/assets/hero-demo-short.mp4"
POSTER="$REPO_ROOT/web/assets/hero-poster-short.jpg"
MANIFEST="$REPO_ROOT/web/assets/hero-demo-short.manifest.json"
DEFAULT_FINAL_TMP="$REPO_ROOT/web/assets/hero-demo.production.mp4"
DEFAULT_FINAL="$REPO_ROOT/web/assets/hero-demo.mp4"
DEFAULT_POSTER_TMP="$REPO_ROOT/web/assets/hero-poster.production.jpg"
DEFAULT_POSTER="$REPO_ROOT/web/assets/hero-poster.jpg"
DEFAULT_MANIFEST="$REPO_ROOT/web/assets/hero-demo.manifest.json"
SCRIPT="$PROJECT_DIR/short-script.txt"
MP3="$PROJECT_DIR/assets/narration-short.mp3"
WAV="$PROJECT_DIR/assets/narration-short.wav"
TIMING="$PROJECT_DIR/assets/narration-short-timing.json"
VOICE_ID="bIHbv24MWmeRgasZH58o"
VOICE_NAME="Will"
MODEL_ID="eleven_v3"
OUTPUT_FORMAT="mp3_44100_128"

if ! command -v uv >/dev/null 2>&1; then
  echo "error: uv is required to prepare the local narration environment" >&2
  exit 1
fi
if [ ! -x "$VENV_DIR/bin/python" ]; then
  uv venv --python 3.12 "$VENV_DIR"
fi
uv pip install --python "$VENV_DIR/bin/python" numpy soundfile
PYTHON="$VENV_DIR/bin/python"

mkdir -p "$PROJECT_DIR/assets" "$PROJECT_DIR/renders" "$REPO_ROOT/web/assets"
for name in quick-recall timeline dictation cotyping; do
  cp "$REPO_ROOT/Assets/screenshots/$name.png" "$PROJECT_DIR/assets/$name.png"
done
cp "$REPO_ROOT/Assets/lokalbot-icon.svg" "$PROJECT_DIR/assets/lokalbot-icon.svg"

if [ ! -f "$WAV" ] || [ "$SCRIPT" -nt "$WAV" ]; then
  set -- \
    --script "$SCRIPT" \
    --mp3 "$MP3" \
    --wav "$WAV" \
    --timing "$TIMING" \
    --max-duration 30 \
    --voice-id "$VOICE_ID" \
    --voice-name "$VOICE_NAME" \
    --model-id "$MODEL_ID" \
    --output-format "$OUTPUT_FORMAT" \
    --anchor "Dictate=13.20" \
    --anchor "LokalBot:=23.72"
  if [ -f "$MP3" ] && [ -f "$TIMING" ] && [ ! "$SCRIPT" -nt "$MP3" ]; then
    "$PYTHON" "$PROJECT_DIR/generate_elevenlabs_narration.py" "$@" --reuse-audio
  else
    if [ -z "${ELEVENLABS_API_KEY:-}" ]; then
      echo "error: ELEVENLABS_API_KEY is required to regenerate the Will narration" >&2
      exit 1
    fi
    "$PYTHON" "$PROJECT_DIR/generate_elevenlabs_narration.py" "$@"
  fi
fi

"$PYTHON" "$PROJECT_DIR/write_short_captions.py"
"$PYTHON" "$PROJECT_DIR/generate_short_audio.py"

CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/lokalbot-showcase-short.XXXXXX")
trap 'rm -rf "$CHECK_DIR"' EXIT HUP INT TERM
ln -s "$PROJECT_DIR/short.html" "$CHECK_DIR/index.html"
ln -s "$PROJECT_DIR/assets" "$CHECK_DIR/assets"
ln -s "$PROJECT_DIR/captions-short.generated.js" "$CHECK_DIR/captions-short.generated.js"

npx --yes "hyperframes@$HYPERFRAMES_VERSION" lint "$CHECK_DIR"
npx --yes "hyperframes@$HYPERFRAMES_VERSION" validate "$CHECK_DIR"
npx --yes "hyperframes@$HYPERFRAMES_VERSION" inspect "$CHECK_DIR" \
  --at "0.8,3.2,5.8,7.4,8.8,10.5,12.2,13.6,14.8,16.8,18.6,19.4,21.3,24.6,27.6" \
  --strict
npx --yes "hyperframes@$HYPERFRAMES_VERSION" render "$CHECK_DIR" \
  --output "$MASTER" --fps 30 --quality high --strict --skill creative-production

ffmpeg -y -v error -i "$MASTER" -t 30 \
  -map 0:v:0 -map 0:a:0 \
  -filter:a 'loudnorm=I=-16:TP=-1.5:LRA=7' \
  -c:v copy \
  -c:a aac -b:a 192k -ar 48000 -movflags +faststart "$FINAL_TMP"
mv "$FINAL_TMP" "$FINAL"

ffmpeg -y -v error -ss 5.8 -i "$FINAL" -frames:v 1 -q:v 2 -pix_fmt yuvj444p "$POSTER"
"$PYTHON" "$PROJECT_DIR/write_short_manifest.py" "$FINAL" "$MANIFEST"

# The short cut is the canonical website and README showcase. Keep promotion
# atomic so readers never see a partially copied media file.
cp "$FINAL" "$DEFAULT_FINAL_TMP"
mv "$DEFAULT_FINAL_TMP" "$DEFAULT_FINAL"
cp "$POSTER" "$DEFAULT_POSTER_TMP"
mv "$DEFAULT_POSTER_TMP" "$DEFAULT_POSTER"
"$PYTHON" "$PROJECT_DIR/write_short_manifest.py" "$DEFAULT_FINAL" "$DEFAULT_MANIFEST"

echo "Rendered $FINAL"
echo "Poster   $POSTER"
echo "Manifest $MANIFEST"
echo "Default  $DEFAULT_FINAL"
