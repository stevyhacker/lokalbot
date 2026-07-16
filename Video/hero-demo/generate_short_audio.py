#!/usr/bin/env python3
"""Generate the original score and UI effects for the 30-second cut."""

from __future__ import annotations

import math
from pathlib import Path

import numpy as np
import soundfile as sf

from generate_audio import SAMPLE_RATE, add_click, add_tone, add_whoosh, smooth_gate


DURATION = 30.0
OUTPUT_DIR = Path(__file__).resolve().parent / "assets"


def write_score() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    sample_count = int(round(DURATION * SAMPLE_RATE))
    t = np.arange(sample_count, dtype=np.float64) / SAMPLE_RATE
    bed = np.zeros((sample_count, 2), dtype=np.float64)

    chords = [
        (0.0, 4.6, (73.42, 110.00, 146.83, 164.81)),
        (3.7, 10.5, (58.27, 87.31, 116.54, 146.83, 220.00)),
        (9.6, 16.3, (87.31, 130.81, 174.61, 196.00)),
        (15.5, 22.4, (65.41, 98.00, 146.83, 196.00)),
        (21.6, 27.1, (73.42, 110.00, 164.81, 220.00)),
        (26.4, 30.0, (65.41, 98.00, 146.83, 196.00, 261.63)),
    ]
    for chord_index, (start, end, frequencies) in enumerate(chords):
        gate = smooth_gate(t, start, end, 0.72)
        left = np.zeros(sample_count, dtype=np.float64)
        right = np.zeros(sample_count, dtype=np.float64)
        for note_index, frequency in enumerate(frequencies):
            phase = (chord_index * 0.71 + note_index * 0.37) % (2.0 * math.pi)
            weight = 1.0 / (1.0 + note_index * 0.28)
            left += np.sin(2.0 * math.pi * frequency * 0.9985 * t + phase) * weight
            right += np.sin(2.0 * math.pi * frequency * 1.0015 * t + phase + 0.11) * weight
            left += np.sin(2.0 * math.pi * frequency * 2.0 * t + phase) * weight * 0.08
            right += np.sin(2.0 * math.pi * frequency * 2.0 * t + phase + 0.08) * weight * 0.08
        normalizer = sum(1.0 / (1.0 + i * 0.28) for i in range(len(frequencies)))
        breathing = 0.82 + 0.18 * np.sin(2.0 * math.pi * 0.09 * t + chord_index)
        bed[:, 0] += left / normalizer * gate * breathing * 0.105
        bed[:, 1] += right / normalizer * gate * breathing * 0.105

    for pulse_index, pulse_time in enumerate(np.arange(2.7, 26.5, 0.68)):
        progress = (pulse_time - 2.7) / (26.5 - 2.7)
        amplitude = 0.043 * math.sin(math.pi * progress) ** 0.7
        pan = -0.18 if pulse_index % 2 == 0 else 0.18
        add_tone(bed, float(pulse_time), 0.32, 82.4, amplitude, pan=pan, decay=12.0)

    bed *= smooth_gate(t, 0.0, DURATION, 0.9)[:, None]
    peak = float(np.max(np.abs(bed))) or 1.0
    bed *= min(1.0, 0.28 / peak)
    sf.write(OUTPUT_DIR / "score-short.wav", bed.astype(np.float32), SAMPLE_RATE, subtype="PCM_16")

    effects = np.zeros((sample_count, 2), dtype=np.float64)
    add_whoosh(effects, 3.62, 0.54, 0.31, pan=-0.22)
    for index, when in enumerate((4.26, 4.48, 4.70)):
        add_click(effects, when, 0.18, pan=-0.15 + index * 0.15)
    add_click(effects, 7.28, 0.39, pan=0.26)

    add_whoosh(effects, 9.62, 0.52, 0.29, pan=0.22)
    add_click(effects, 11.68, 0.34, pan=-0.18)
    for index, when in enumerate(np.arange(12.42, 13.72, 0.22)):
        add_click(effects, float(when), 0.13, pan=-0.14 + index * 0.05)
    add_tone(effects, 14.52, 0.46, 620, 0.22, pan=0.2, decay=7.0, chirp_to=980)

    add_whoosh(effects, 15.52, 0.52, 0.29, pan=-0.18)
    add_click(effects, 16.58, 0.34, pan=0.16)
    add_tone(effects, 18.78, 0.48, 520, 0.22, pan=0.16, decay=6.0, chirp_to=920)
    for index, when in enumerate(np.arange(18.96, 21.08, 0.23)):
        add_click(effects, float(when), 0.105, pan=-0.1 + (index % 5) * 0.05)

    add_whoosh(effects, 21.62, 0.5, 0.27, pan=0.22)
    for index, when in enumerate(np.arange(22.12, 24.52, 0.22)):
        add_click(effects, float(when), 0.105, pan=0.1 - (index % 5) * 0.04)
    add_click(effects, 25.02, 0.4, pan=0.18)
    add_tone(effects, 25.14, 0.52, 560, 0.24, pan=0.24, decay=6.0, chirp_to=1_020)
    add_whoosh(effects, 26.42, 0.58, 0.22, pan=0.0)

    for frequency, delay, pan in ((523.25, 0.0, -0.25), (659.25, 0.11, 0.0), (783.99, 0.23, 0.25)):
        add_tone(effects, 27.35 + delay, 1.55, frequency, 0.20, pan=pan, decay=2.5)

    peak = float(np.max(np.abs(effects))) or 1.0
    effects *= min(1.0, 0.72 / peak)
    sf.write(OUTPUT_DIR / "effects-short.wav", effects.astype(np.float32), SAMPLE_RATE, subtype="PCM_16")


if __name__ == "__main__":
    write_score()
