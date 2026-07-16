#!/usr/bin/env python3
"""Generate and editorially time the ElevenLabs hero-demo narration."""

from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import urllib.error
import urllib.request
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parent
ASSET_DIR = PROJECT_DIR / "assets"
SCRIPT_PATH = PROJECT_DIR / "script.txt"
MP3_PATH = ASSET_DIR / "narration-elevenlabs.mp3"
WAV_PATH = ASSET_DIR / "narration.wav"
TIMING_PATH = ASSET_DIR / "narration-elevenlabs-timing.json"

VOICE_ID = "hpp4J3VqNfWAUOO0d1Us"
MODEL_ID = "eleven_multilingual_v2"
OUTPUT_FORMAT = "mp3_44100_128"
COMPOSITION_DURATION = 55.0

# These lines should begin with the matching product scenes. Silence is inserted
# only between sentences; the ElevenLabs performance itself is never stretched.
SCENE_ANCHORS: list[tuple[str, float]] = []


def generate(text: str, api_key: str) -> dict:
    payload = json.dumps(
        {
            "text": text,
            "model_id": MODEL_ID,
            "seed": 24817,
            "voice_settings": {
                "stability": 0.48,
                "similarity_boost": 0.80,
                "style": 0.16,
                "use_speaker_boost": True,
                "speed": 1.00,
            },
        }
    ).encode("utf-8")
    url = (
        f"https://api.elevenlabs.io/v1/text-to-speech/{VOICE_ID}/with-timestamps"
        f"?output_format={OUTPUT_FORMAT}"
    )
    request = urllib.request.Request(
        url,
        data=payload,
        method="POST",
        headers={"Content-Type": "application/json", "xi-api-key": api_key},
    )
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")
        raise SystemExit(f"ElevenLabs request failed ({error.code}): {detail}") from None


def build_pauses(alignment: dict, anchors: list[tuple[str, float]]) -> list[dict]:
    characters = alignment["characters"]
    starts = alignment["character_start_times_seconds"]
    ends = alignment["character_end_times_seconds"]
    text = "".join(characters)
    pauses: list[dict] = []
    cumulative_delay = 0.0

    for phrase, target in anchors:
        phrase_index = text.index(phrase)
        previous_index = phrase_index - 1
        while previous_index >= 0 and characters[previous_index].isspace():
            previous_index -= 1
        if previous_index < 0:
            raise SystemExit(f"cannot place editorial pause before {phrase!r}")

        raw_start = starts[phrase_index]
        delay = target - (raw_start + cumulative_delay)
        if delay < -0.03:
            raise SystemExit(
                f"ElevenLabs read reaches {phrase!r} {-delay:.3f}s too late for its scene"
            )
        delay = max(0.0, delay)
        cut = (ends[previous_index] + raw_start) / 2.0
        pauses.append(
            {
                "before": phrase,
                "cutSeconds": round(cut, 4),
                "durationSeconds": round(delay, 4),
                "targetSeconds": target,
            }
        )
        cumulative_delay += delay

    return pauses


def shifted_time(value: float, pauses: list[dict]) -> float:
    return value + sum(
        pause["durationSeconds"] for pause in pauses if value >= pause["cutSeconds"]
    )


def render_timed_wav(pauses: list[dict], mp3_path: Path, wav_path: Path) -> None:
    if not pauses:
        subprocess.run(
            [
                "ffmpeg", "-y", "-v", "error", "-i", str(mp3_path),
                "-ar", "48000", "-ac", "1", "-c:a", "pcm_s16le",
                str(wav_path),
            ],
            check=True,
        )
        return

    segments: list[str] = []
    inputs: list[str] = []
    previous_cut = 0.0

    for index, pause in enumerate(pauses):
        cut = pause["cutSeconds"]
        duration = pause["durationSeconds"]
        segments.append(
            f"[0:a]atrim={previous_cut:.4f}:{cut:.4f},asetpts=PTS-STARTPTS[a{index}]"
        )
        inputs.append(f"[a{index}]")
        if duration > 0:
            segments.append(
                f"anullsrc=r=44100:cl=mono,atrim=duration={duration:.4f}[s{index}]"
            )
            inputs.append(f"[s{index}]")
        previous_cut = cut

    final_index = len(pauses)
    segments.append(
        f"[0:a]atrim=start={previous_cut:.4f},asetpts=PTS-STARTPTS[a{final_index}]"
    )
    inputs.append(f"[a{final_index}]")
    segments.append(f"{''.join(inputs)}concat=n={len(inputs)}:v=0:a=1[out]")

    subprocess.run(
        [
            "ffmpeg",
            "-y",
            "-v",
            "error",
            "-i",
            str(mp3_path),
            "-filter_complex",
            ";".join(segments),
            "-map",
            "[out]",
            "-ar",
            "48000",
            "-ac",
            "1",
            "-c:a",
            "pcm_s16le",
            str(wav_path),
        ],
        check=True,
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--script", type=Path, default=SCRIPT_PATH)
    parser.add_argument("--mp3", type=Path, default=MP3_PATH)
    parser.add_argument("--wav", type=Path, default=WAV_PATH)
    parser.add_argument("--timing", type=Path, default=TIMING_PATH)
    parser.add_argument("--max-duration", type=float, default=COMPOSITION_DURATION)
    parser.add_argument(
        "--reuse-audio",
        action="store_true",
        help="reuse the existing MP3 and raw alignment while rebuilding editorial timing",
    )
    parser.add_argument(
        "--anchor",
        action="append",
        default=[],
        metavar="PHRASE=SECONDS",
        help="insert silence so PHRASE begins at SECONDS; may be repeated",
    )
    args = parser.parse_args()

    anchors = list(SCENE_ANCHORS)
    for value in args.anchor:
        phrase, separator, target = value.rpartition("=")
        if not separator or not phrase:
            raise SystemExit(f"invalid --anchor {value!r}; expected PHRASE=SECONDS")
        anchors.append((phrase, float(target)))

    args.mp3.parent.mkdir(parents=True, exist_ok=True)
    args.wav.parent.mkdir(parents=True, exist_ok=True)
    args.timing.parent.mkdir(parents=True, exist_ok=True)
    if args.reuse_audio:
        if not args.mp3.exists() or not args.timing.exists():
            raise SystemExit("--reuse-audio requires the existing MP3 and timing JSON")
        result = json.loads(args.timing.read_text(encoding="utf-8"))
        alignment = result.get("alignment")
    else:
        api_key = os.environ.get("ELEVENLABS_API_KEY")
        if not api_key:
            raise SystemExit("ELEVENLABS_API_KEY is required to regenerate narration")
        text = args.script.read_text(encoding="utf-8")
        result = generate(text, api_key)
        alignment = result.get("alignment")
        audio_base64 = result.pop("audio_base64", None)
        if not alignment or not audio_base64:
            raise SystemExit("ElevenLabs response did not contain audio and alignment data")
        args.mp3.write_bytes(base64.b64decode(audio_base64, validate=True))

    if not alignment:
        raise SystemExit("ElevenLabs timing JSON did not contain raw alignment data")
    pauses = build_pauses(alignment, anchors)

    shifted_alignment = {
        "characters": alignment["characters"],
        "character_start_times_seconds": [
            shifted_time(value, pauses)
            for value in alignment["character_start_times_seconds"]
        ],
        "character_end_times_seconds": [
            shifted_time(value, pauses)
            for value in alignment["character_end_times_seconds"]
        ],
    }
    final_spoken_end = next(
        value
        for character, value in reversed(
            list(zip(shifted_alignment["characters"], shifted_alignment["character_end_times_seconds"]))
        )
        if not character.isspace()
    )
    if final_spoken_end > args.max_duration:
        raise SystemExit(
            f"ElevenLabs read ends at {final_spoken_end:.3f}s, after the "
            f"{args.max_duration:.1f}s composition"
        )

    result["editorial_pauses"] = pauses
    result["production_alignment"] = shifted_alignment
    args.timing.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    render_timed_wav(pauses, args.mp3, args.wav)
    print(f"Generated {args.wav} with Bella / {MODEL_ID}")


if __name__ == "__main__":
    main()
