#!/usr/bin/env python3
"""Generate the original score bed and UI sound-design stem.

The synthesis is deterministic and uses only NumPy + SoundFile, which are
already installed for the local Kokoro narration workflow. Keeping music and
effects generated in-project avoids stock-audio licensing ambiguity.
"""

from __future__ import annotations

import math
from pathlib import Path

import numpy as np
import soundfile as sf


SAMPLE_RATE = 48_000
DURATION = 56.0
OUTPUT_DIR = Path(__file__).resolve().parent / "assets"


def smooth_gate(t: np.ndarray, start: float, end: float, fade: float) -> np.ndarray:
    gate = np.zeros_like(t)
    body = (t >= start) & (t <= end)
    gate[body] = 1.0
    fade_in = (t >= start) & (t < start + fade)
    gate[fade_in] = 0.5 - 0.5 * np.cos(math.pi * (t[fade_in] - start) / fade)
    fade_out = (t > end - fade) & (t <= end)
    gate[fade_out] = 0.5 + 0.5 * np.cos(math.pi * (t[fade_out] - (end - fade)) / fade)
    return gate


def add_tone(track: np.ndarray, when: float, duration: float, frequency: float,
             amplitude: float, pan: float = 0.0, decay: float = 8.0,
             chirp_to: float | None = None) -> None:
    start = max(0, int(round(when * SAMPLE_RATE)))
    count = min(len(track) - start, int(round(duration * SAMPLE_RATE)))
    if count <= 0:
        return
    local_t = np.arange(count, dtype=np.float64) / SAMPLE_RATE
    envelope = (1.0 - np.exp(-local_t * 70.0)) * np.exp(-local_t * decay)
    if chirp_to is None:
        phase = 2.0 * math.pi * frequency * local_t
    else:
        slope = (chirp_to - frequency) / max(duration, 1e-6)
        phase = 2.0 * math.pi * (frequency * local_t + 0.5 * slope * local_t * local_t)
    signal = np.sin(phase) * envelope * amplitude
    left = math.sqrt((1.0 - pan) * 0.5)
    right = math.sqrt((1.0 + pan) * 0.5)
    track[start:start + count, 0] += signal * left
    track[start:start + count, 1] += signal * right


def add_click(track: np.ndarray, when: float, amplitude: float = 0.5,
              pan: float = 0.0) -> None:
    add_tone(track, when, 0.12, 1_420, amplitude, pan=pan, decay=45.0,
             chirp_to=860)
    add_tone(track, when + 0.006, 0.08, 2_300, amplitude * 0.32,
             pan=pan, decay=60.0, chirp_to=1_200)


def add_whoosh(track: np.ndarray, when: float, duration: float = 0.52,
               amplitude: float = 0.25, pan: float = 0.0) -> None:
    add_tone(track, when, duration, 120, amplitude, pan=pan, decay=2.6,
             chirp_to=1_250)
    add_tone(track, when + 0.04, duration * 0.86, 260, amplitude * 0.58,
             pan=-pan, decay=3.5, chirp_to=2_100)


def write_score() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    sample_count = int(round(DURATION * SAMPLE_RATE))
    t = np.arange(sample_count, dtype=np.float64) / SAMPLE_RATE
    bed = np.zeros((sample_count, 2), dtype=np.float64)

    # Four related, slowly crossfading voicings. Detuned stereo oscillators
    # keep the bed wide without chorus plugins or non-deterministic effects.
    chords = [
        (0.0, 9.6, (73.42, 110.00, 146.83, 164.81)),
        (8.7, 17.9, (58.27, 87.31, 116.54, 146.83, 220.00)),
        (17.0, 25.5, (87.31, 130.81, 174.61, 196.00)),
        (24.5, 32.2, (65.41, 98.00, 146.83, 196.00)),
        (31.3, 41.8, (73.42, 110.00, 164.81, 220.00)),
        (40.9, 49.8, (58.27, 87.31, 130.81, 174.61)),
        (49.0, 56.0, (65.41, 98.00, 146.83, 196.00, 261.63)),
    ]
    for chord_index, (start, end, frequencies) in enumerate(chords):
        gate = smooth_gate(t, start, end, 0.9)
        chord_left = np.zeros(sample_count, dtype=np.float64)
        chord_right = np.zeros(sample_count, dtype=np.float64)
        for note_index, frequency in enumerate(frequencies):
            phase = (chord_index * 0.71 + note_index * 0.37) % (2.0 * math.pi)
            weight = 1.0 / (1.0 + note_index * 0.28)
            chord_left += np.sin(2.0 * math.pi * frequency * 0.9985 * t + phase) * weight
            chord_right += np.sin(2.0 * math.pi * frequency * 1.0015 * t + phase + 0.11) * weight
            chord_left += np.sin(2.0 * math.pi * frequency * 2.0 * t + phase) * weight * 0.08
            chord_right += np.sin(2.0 * math.pi * frequency * 2.0 * t + phase + 0.08) * weight * 0.08
        normalizer = sum(1.0 / (1.0 + index * 0.28) for index in range(len(frequencies)))
        breathing = 0.82 + 0.18 * np.sin(2.0 * math.pi * 0.075 * t + chord_index)
        bed[:, 0] += chord_left / normalizer * gate * breathing * 0.105
        bed[:, 1] += chord_right / normalizer * gate * breathing * 0.105

    # A restrained, heartbeat-like product pulse enters only after the hook.
    for pulse_index, pulse_time in enumerate(np.arange(3.2, 50.0, 0.72)):
        progress = (pulse_time - 3.2) / (50.0 - 3.2)
        amplitude = 0.045 * math.sin(math.pi * progress) ** 0.7
        pan = -0.18 if pulse_index % 2 == 0 else 0.18
        add_tone(bed, float(pulse_time), 0.34, 82.4, amplitude, pan=pan, decay=12.0)

    master_fade = smooth_gate(t, 0.0, DURATION, 1.15)
    bed *= master_fade[:, None]
    bed_peak = float(np.max(np.abs(bed))) or 1.0
    bed *= min(1.0, 0.28 / bed_peak)
    sf.write(OUTPUT_DIR / "score.wav", bed.astype(np.float32), SAMPLE_RATE, subtype="PCM_16")

    effects = np.zeros((sample_count, 2), dtype=np.float64)
    add_whoosh(effects, 8.46, 0.62, 0.34, pan=0.25)
    add_click(effects, 9.82, 0.42, pan=-0.24)
    add_click(effects, 14.0, 0.38, pan=0.18)
    add_whoosh(effects, 17.12, 0.5, 0.28, pan=-0.25)
    for index, key_time in enumerate((17.72, 17.90, 18.08)):
        add_click(effects, key_time, 0.19, pan=-0.16 + index * 0.16)
    add_click(effects, 21.24, 0.38, pan=0.28)
    add_whoosh(effects, 24.48, 0.5, 0.28, pan=0.2)
    add_click(effects, 27.34, 0.38, pan=-0.18)
    for index, tick_time in enumerate((27.76, 27.98, 28.20, 28.42, 28.64, 28.86)):
        add_click(effects, tick_time, 0.14, pan=-0.14 + index * 0.055)
    add_tone(effects, 29.1, 0.46, 620, 0.23, pan=0.2, decay=7.0, chirp_to=980)
    add_whoosh(effects, 31.3, 0.52, 0.28, pan=-0.18)
    add_click(effects, 32.38, 0.34, pan=0.16)
    add_tone(effects, 36.56, 0.48, 520, 0.22, pan=0.16, decay=6.0, chirp_to=920)
    for index, tick_time in enumerate(np.arange(36.9, 39.55, 0.24)):
        add_click(effects, float(tick_time), 0.11, pan=-0.1 + (index % 5) * 0.05)
    add_whoosh(effects, 40.92, 0.5, 0.26, pan=0.22)
    for index, tick_time in enumerate(np.arange(41.48, 44.18, 0.23)):
        add_click(effects, float(tick_time), 0.11, pan=0.1 - (index % 5) * 0.04)
    add_click(effects, 45.32, 0.4, pan=0.18)
    add_tone(effects, 45.48, 0.52, 560, 0.24, pan=0.24, decay=6.0, chirp_to=1_020)
    add_whoosh(effects, 46.82, 0.48, 0.24, pan=-0.2)
    add_click(effects, 48.66, 0.34, pan=0.28)
    add_whoosh(effects, 49.06, 0.58, 0.22, pan=0.0)

    # A three-note, non-triumphal resolve under the final brand line.
    for frequency, delay, pan in ((523.25, 0.0, -0.25), (659.25, 0.11, 0.0), (783.99, 0.23, 0.25)):
        add_tone(effects, 52.2 + delay, 1.65, frequency, 0.20,
                 pan=pan, decay=2.5)

    effects_peak = float(np.max(np.abs(effects))) or 1.0
    effects *= min(1.0, 0.72 / effects_peak)
    sf.write(OUTPUT_DIR / "effects.wav", effects.astype(np.float32), SAMPLE_RATE, subtype="PCM_16")


if __name__ == "__main__":
    write_score()
