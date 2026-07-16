#!/usr/bin/env python3
"""Write deterministic delivery metadata for the 30-second showcase cut."""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from pathlib import Path


SCENES = [
    {"id": "hook", "start": 0.0, "end": 4.20, "purpose": "private on-device AI memory hook"},
    {"id": "quick-recall", "start": 4.20, "end": 8.12, "purpose": "search meetings and saved screen moments"},
    {"id": "context-rewind", "start": 8.12, "end": 12.92, "purpose": "scrub play and bookmark the workday timeline"},
    {"id": "dictation", "start": 12.92, "end": 16.14, "purpose": "local speech inserted into the active app"},
    {"id": "cotyping", "start": 16.14, "end": 20.50, "purpose": "on-device ghost text accepted with Tab"},
    {"id": "privacy-outro", "start": 20.50, "end": 30.0, "purpose": "privacy proof and brand payoff"},
]


def probe(path: Path) -> dict:
    result = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            "format=duration,size,bit_rate:stream=index,codec_type,codec_name,width,height,r_frame_rate,sample_rate,channels,bit_rate",
            "-of",
            "json",
            str(path),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: write_short_manifest.py <video.mp4> <manifest.json>")
    video = Path(sys.argv[1]).resolve()
    destination = Path(sys.argv[2]).resolve()
    manifest = {
        "version": 1,
        "output": video.name,
        "sha256": sha256(video),
        "production": {
            "engine": "HyperFrames",
            "engineVersion": "0.7.42",
            "source": "Video/hero-demo/short.html",
            "canvas": [1872, 1276],
            "fps": 30,
            "durationSeconds": 30.0,
        },
        "audio": {
            "narration": {
                "engine": "ElevenLabs Eleven v3",
                "modelId": "eleven_v3",
                "voice": "Will",
                "voiceId": "bIHbv24MWmeRgasZH58o",
                "speed": 1.0,
                "stabilityMode": "Natural",
                "timing": "natural performance with sentence-boundary pauses; no time stretching",
            },
            "music": "original deterministic score",
            "effects": "original scene-aligned UI sound-design stem",
            "deliveryLoudness": {"integratedTargetLufs": -16.0, "truePeakTargetDbtp": -1.5},
            "deliveryEncoding": {
                "video": "HyperFrames H.264 master stream; no second-generation encode",
                "audio": "AAC 192 kb/s",
            },
        },
        "captions": {
            "language": "en",
            "burnedIn": True,
            "source": "ElevenLabs character timings",
        },
        "scenes": SCENES,
        "delivery": probe(video),
    }
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
