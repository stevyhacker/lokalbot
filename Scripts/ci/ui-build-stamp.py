#!/usr/bin/env python3
"""Bind within-job UI build reuse to the checkout, toolchain and signing mode."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys


def output(*args):
    return subprocess.check_output(args, text=True).strip()


def identity():
    root = Path(output("git", "rev-parse", "--show-toplevel"))
    paths = ["LokalBot", "LokalBotUITests", "CLI", "project.yml", "Scripts",
             "LokalBot.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"]
    changes = output("git", "status", "--porcelain", "--untracked-files=all", "--", *paths)
    if changes:
        raise ValueError("UI build reuse requires a clean checkout of build inputs")
    return {
        "commit": output("git", "rev-parse", "HEAD"),
        "root": str(root),
        "xcode": output("xcodebuild", "-version"),
        "architecture": output("uname", "-m"),
        "signing": os.environ.get("CODE_SIGNING_ALLOWED", ""),
        "lock": hashlib.sha256((root / paths[-1]).read_bytes()).hexdigest(),
        "run": os.environ.get("GITHUB_RUN_ID", ""),
        "attempt": os.environ.get("GITHUB_RUN_ATTEMPT", ""),
        "job": os.environ.get("GITHUB_JOB", ""),
    }


def main():
    mode, raw_path = sys.argv[1:]
    path = Path(raw_path)
    current = identity()
    if mode == "write":
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(current, indent=2) + "\n")
    elif mode == "verify":
        if json.loads(path.read_text()) != current:
            raise ValueError("UI build does not match this checkout, job or toolchain; rebuild it")
        if not list(path.parent.glob("Build/Products/*.xctestrun")):
            raise ValueError("UI test products are missing; rebuild them")
    else:
        raise ValueError("expected write or verify")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
