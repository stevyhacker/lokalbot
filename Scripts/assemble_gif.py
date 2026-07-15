#!/usr/bin/env python3
"""Assemble an animated GIF or MP4 from screenshot frames with slide transitions.

Each frame is centered (no scaling, so text stays crisp) on an even-sized
brand-dark canvas, cross-slid with xfade, then quantized to a GIF via a
two-pass palette — or, when <out> ends in .mp4, encoded as web-grade H.264
(the landing page's hero-demo). Used by Scripts/capture-screenshots.sh.

Usage:
    assemble_gif.py <out.gif|out.mp4> <width> <frame1.png> [frame2.png ...]
"""
import os, subprocess, sys

BG = "0x0e141c"
HOLD, TRANS, FPS = 1.9, 0.5, 12


def dims(p):
    o = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", p],
                       capture_output=True, text=True).stdout
    w = int([l for l in o.splitlines() if "pixelWidth" in l][0].split(":")[1])
    h = int([l for l in o.splitlines() if "pixelHeight" in l][0].split(":")[1])
    return w, h


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        sys.exit(1)
    out, width, frames = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
    mw = max(dims(f)[0] for f in frames)
    mh = max(dims(f)[1] for f in frames)
    cw, ch = mw + 80, mh + 80
    cw += cw % 2
    ch += ch % 2
    tmp = subprocess.run(["mktemp", "-d"], capture_output=True, text=True).stdout.strip()

    norm = []
    for i, f in enumerate(frames):
        d = os.path.join(tmp, f"f{i}.png")
        subprocess.run(["ffmpeg", "-y", "-i", f, "-vf",
                        f"pad={cw}:{ch}:(ow-iw)/2:(oh-ih)/2:color={BG}", d],
                       check=True, capture_output=True)
        norm.append(d)

    inputs = []
    for f in norm:
        inputs += ["-loop", "1", "-t", str(HOLD + TRANS), "-i", f]
    if len(norm) > 1:
        steps, prev = [], "[0]"
        for i in range(1, len(norm)):
            lbl = f"[v{i}]"
            steps.append(f"{prev}[{i}]xfade=transition=slideleft:"
                         f"duration={TRANS}:offset={i * HOLD}{lbl}")
            prev = lbl
        filt = ";".join(steps) + f";{prev}fps={FPS},format=yuv420p[out]"
    else:
        filt = f"[0]fps={FPS},format=yuv420p[out]"

    mp4 = os.path.join(tmp, "v.mp4")
    subprocess.run(["ffmpeg", "-y"] + inputs + ["-filter_complex", filt, "-map", "[out]", mp4],
                   check=True, capture_output=True)
    # Never upscale: cap at the source width so 1x captures stay unscaled and
    # 2x (Retina) captures land at the requested width for crisp README render.
    if out.endswith(".mp4"):
        # Web-grade H.264 for the landing page: even dimensions, faststart.
        subprocess.run(["ffmpeg", "-y", "-i", mp4, "-vf",
                        f"scale=min({width}\\,iw):-2:flags=lanczos",
                        "-c:v", "libx264", "-crf", "22", "-preset", "slow",
                        "-movflags", "+faststart", "-an", out],
                       check=True, capture_output=True)
        print(f"  {out} ({os.path.getsize(out) // 1024} KB)")
        return

    scale = f"scale=min({width}\\,iw):-1:flags=lanczos"
    pal = os.path.join(tmp, "pal.png")
    subprocess.run(["ffmpeg", "-y", "-i", mp4, "-vf",
                    f"fps={FPS},{scale},palettegen=stats_mode=diff", pal],
                   check=True, capture_output=True)
    subprocess.run(["ffmpeg", "-y", "-i", mp4, "-i", pal, "-lavfi",
                    f"fps={FPS},{scale}[x];"
                    f"[x][1:v]paletteuse=dither=bayer:bayer_scale=3", out],
                   check=True, capture_output=True)
    print(f"  {out} ({os.path.getsize(out) // 1024} KB)")


if __name__ == "__main__":
    main()
