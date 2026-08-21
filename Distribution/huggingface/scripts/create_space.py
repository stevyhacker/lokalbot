#!/usr/bin/env python3
"""Create or update LokalBot's public static benchmark Space."""

from pathlib import Path

from huggingface_hub import HfApi

NAMESPACE = "stevyhacker"
REPO_ID = f"{NAMESPACE}/lokalbot-benchmarks"
SPACE_DIR = Path(__file__).resolve().parents[1] / "space"


def main() -> None:
    api = HfApi()
    username = api.whoami()["name"]
    if username != NAMESPACE:
        raise RuntimeError(f"Authenticated as {username!r}; expected {NAMESPACE!r}")

    required_files = [
        SPACE_DIR / "README.md",
        SPACE_DIR / "index.html",
        SPACE_DIR / "style.css",
    ]
    missing = [str(path) for path in required_files if not path.is_file()]
    if missing:
        raise RuntimeError(f"Render the Space before publishing; missing: {missing}")

    api.create_repo(
        repo_id=REPO_ID,
        repo_type="space",
        space_sdk="static",
        private=False,
        exist_ok=True,
    )
    api.upload_folder(
        repo_id=REPO_ID,
        repo_type="space",
        folder_path=SPACE_DIR,
        allow_patterns=["README.md", "index.html", "style.css"],
        commit_message="Publish LokalBot local-stack benchmarks",
    )
    print(f"https://huggingface.co/spaces/{REPO_ID}")


if __name__ == "__main__":
    main()
