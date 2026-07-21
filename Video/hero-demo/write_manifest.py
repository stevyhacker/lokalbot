#!/usr/bin/env python3
"""Write deterministic delivery metadata for the rendered website demo."""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from pathlib import Path


SCENES = [
    {"id": "hook", "start": 0.0, "end": 8.62, "purpose": "problem hook and Remember Recall Write Act framing"},
    {"id": "remember", "start": 8.62, "end": 13.03, "purpose": "bot-free meeting capture and recap"},
    {"id": "evidence", "start": 13.03, "end": 17.12, "purpose": "speaker-labeled transcript evidence"},
    {"id": "quick-recall", "start": 17.12, "end": 24.48, "purpose": "search meetings and saved screen moments"},
    {"id": "context-rewind", "start": 24.48, "end": 31.30, "purpose": "scrub play and bookmark the permission-gated workday timeline"},
    {"id": "dictation", "start": 31.30, "end": 40.92, "purpose": "local push-to-talk transcription inserted at the cursor"},
    {"id": "cotyping", "start": 40.92, "end": 46.82, "purpose": "on-device ghost-text autocomplete with Tab acceptance"},
    {"id": "ask", "start": 46.82, "end": 49.28, "purpose": "answer work questions with citations"},
    {"id": "privacy", "start": 49.28, "end": 56.00, "purpose": "privacy proof and brand payoff"},
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
        raise SystemExit("usage: write_manifest.py <video.mp4> <manifest.json>")
    video = Path(sys.argv[1]).resolve()
    destination = Path(sys.argv[2]).resolve()
    metadata = probe(video)
    manifest = {
        "version": 3,
        "output": video.name,
        "sha256": sha256(video),
        "production": {
            "engine": "HyperFrames",
            "engineVersion": "0.7.42",
            "source": "Video/hero-demo/index.html",
            "canvas": [1872, 1276],
            "fps": 30,
            "durationSeconds": 56.0,
        },
        "audio": {
            "narration": {
                "engine": "ElevenLabs Multilingual v2",
                "voice": "Bella",
                "voiceId": "hpp4J3VqNfWAUOO0d1Us",
                "speed": 1.0,
            },
            "music": "original deterministic score",
            "effects": "original UI sound-design stem",
            "deliveryLoudness": {"integratedTargetLufs": -16.0, "truePeakTargetDbtp": -1.5},
        },
        "captions": {
            "language": "en",
            "burnedIn": True,
            "source": "ElevenLabs character timings",
        },
        "scenes": SCENES,
        "delivery": metadata,
    }
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
