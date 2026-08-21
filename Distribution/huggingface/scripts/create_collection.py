#!/usr/bin/env python3
"""Create LokalBot's public Hugging Face model collection idempotently."""

from huggingface_hub import HfApi, add_collection_item, create_collection

NAMESPACE = "stevyhacker"
TITLE = "LokalBot recommended local stack"
DESCRIPTION = (
    "LokalBot on-device stack: transcription, summaries, autocomplete, search, "
    "and diarization. Links only. https://github.com/stevyhacker/lokalbot"
)

ITEMS = [
    (
        "ibm-granite/granite-speech-4.1-2b-GGUF",
        "Default ASR. Q4_K_M plus F16 projector (2.30 GB). Apache-2.0.",
    ),
    (
        "unsloth/Qwen3.5-4B-GGUF",
        "Summaries and chat. Q4_K_M; measured around 100 tok/s on M4 Max.",
    ),
    (
        "unsloth/LFM2.5-1.2B-Instruct-GGUF",
        "Default autocomplete. Q4_K_M of LiquidAI's model; check LFM Open License revenue eligibility.",
    ),
    (
        "unsloth/gemma-4-E4B-it-GGUF",
        "Higher-capacity autocomplete. UD-Q5_K_XL; the instruct tune passed LokalBot's full cotyping gate.",
    ),
    (
        "Qwen/Qwen3-Embedding-0.6B-GGUF",
        "Semantic search. Q8_0 (0.64 GB) on a dedicated llama-server with embeddings enabled.",
    ),
    (
        "FluidInference/speaker-diarization-coreml",
        "Core ML speaker diarization via FluidAudio; based on pyannote community-1 (CC-BY-4.0).",
    ),
]

VERIFICATION = {
    "ibm-granite/granite-speech-4.1-2b-GGUF": ("Q4_K_M", "mmproj"),
    "unsloth/Qwen3.5-4B-GGUF": ("Q4_K_M",),
    "LiquidAI/LFM2.5-1.2B-Instruct": (),
    "unsloth/LFM2.5-1.2B-Instruct-GGUF": ("Q4_K_M",),
    "unsloth/gemma-4-E4B-it-GGUF": ("UD-Q5_K_XL",),
    "Qwen/Qwen3-Embedding-0.6B-GGUF": ("Q8_0",),
    "FluidInference/speaker-diarization-coreml": (),
}


def main() -> None:
    if len(DESCRIPTION) >= 150:
        raise RuntimeError(
            "Hugging Face Collection descriptions must be under 150 characters"
        )

    api = HfApi()
    username = api.whoami()["name"]
    if username != NAMESPACE:
        raise RuntimeError(f"Authenticated as {username!r}; expected {NAMESPACE!r}")

    for repo_id, expected_fragments in VERIFICATION.items():
        info = api.model_info(repo_id, files_metadata=False)
        filenames = [sibling.rfilename for sibling in info.siblings]
        missing = [
            fragment
            for fragment in expected_fragments
            if not any(fragment in filename for filename in filenames)
        ]
        if missing:
            raise RuntimeError(f"{repo_id} is missing expected files: {missing}")

    collection = create_collection(
        title=TITLE,
        namespace=NAMESPACE,
        description=DESCRIPTION,
        private=False,
        exists_ok=True,
    )

    for repo_id, note in ITEMS:
        add_collection_item(
            collection_slug=collection.slug,
            item_id=repo_id,
            item_type="model",
            note=note,
            exists_ok=True,
        )

    print(f"https://huggingface.co/collections/{collection.slug}")


if __name__ == "__main__":
    main()
