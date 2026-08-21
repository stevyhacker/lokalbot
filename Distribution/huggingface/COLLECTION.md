# COLLECTION.md — "LokalBot recommended local stack" Hugging Face Collection

A Hugging Face **Collection** that curates the exact third-party model repos LokalBot's Recommended stack downloads. **We never rehost or mirror weights**: every item links to the model owner's repo, so licenses (Apache-2.0, Gemma terms, LFM Open License, CC-BY-4.0) and download bandwidth stay with their owners. The collection is pure curation — a one-click "get everything LokalBot recommends" list with per-model notes.

## Curated items (all repo ids verified via the HF API on 2026-08-21)

| # | Role | HF repo id (verified) | Quant to note | Curation note |
| --- | --- | --- | --- | --- |
| 1 | Transcription (default) | `ibm-granite/granite-speech-4.1-2b-GGUF` | `Q4_K_M` + `mmproj-model-f16.gguf` (2.30 GB in-app) | Apache-2.0; LokalBot's default ASR; repo ships Q4_K_M→bf16 plus the F16 projector LokalBot loads. |
| 2 | Summaries and chat | `unsloth/Qwen3.5-4B-GGUF` | `Q4_K_M` | Most-downloaded Qwen3.5 4B GGUF repo (API: 1.17M downloads); measured ~100 tok/s on M4 Max in LokalBot's stack. |
| 3 | Autocomplete (default) | `LiquidAI/LFM2.5-1.2B-Instruct` (official; GGUF at `unsloth/LFM2.5-1.2B-Instruct-GGUF`) | `Q4_K_M` (730,895,584 bytes) | Fastest model to clear LokalBot's full cotyping gate (143 ms avg / 484 ms p95); **LFM Open License v1.0 — free commercial use limited to entities under USD 10M revenue**, so link, don't rehost. |
| 3b | Autocomplete (higher-capacity option) | `unsloth/gemma-4-E4B-it-GGUF` | `UD-Q5_K_XL` | The instruct tune measured strictly better than Cotypist's base file in LokalBot's pipeline (28/28 safety, 12/13 completions); Gemma license terms apply. |
| 4 | Embeddings / semantic search | `Qwen/Qwen3-Embedding-0.6B-GGUF` | `Q8_0` (0.64 GB) | Official Qwen repo; runs on a second llama-server with `--embeddings`, vectors in SQLite. |
| 5 | Speaker diarization | `FluidInference/speaker-diarization-coreml` | Core ML, FP16 on ANE (~0.10 GB) | FluidAudio's ANE-optimized conversion of `pyannote/speaker-diarization-community-1` (CC-BY-4.0); this is the exact artifact LokalBot downloads for Them 1/Them 2 labels. |

Verification method (reproduce before publishing): query `https://huggingface.co/api/models?search=<name>` (or `?author=<org>`) and record the exact `id` returned; confirm the quantization filename exists via `https://huggingface.co/api/models/<id>` `siblings`. All six ids above were confirmed this way, including the quant files `Qwen3.5-4B-Q4_K_M.gguf`, `gemma-4-E4B-it-UD-Q5_K_XL.gguf`, `LFM2.5-1.2B-Instruct-Q4_K_M.gguf`, and `Qwen3-Embedding-0.6B-Q8_0.gguf`.

## Collection description (paste as-is)

> The local model stack behind [LokalBot](https://github.com/stevyhacker/lokalbot) — a GPLv3 macOS app that records both sides of meetings without a bot, transcribes and summarizes everything on-device, and adds hold-to-talk dictation plus ghost-text autocomplete in any app. These are the exact repos its Recommended stack downloads: Granite Speech 4.1 2B for transcription, Qwen3.5 4B for summaries and chat (~100 tok/s on an M4 Max), LFM2.5 1.2B (or Gemma 4 E4B) for keystroke-latency autocomplete, Qwen3-Embedding 0.6B for semantic search, and FluidAudio's Core ML diarization. All inference stays on your machine; the only network traffic is these one-time downloads. Measured numbers: see the benchmark summary in the repo (`Distribution/huggingface/benchmark-summary.md`).

## Creating the collection

### Option A — web UI

1. Sign in at huggingface.co → your avatar → **New Collection** (or from any model page: ⋯ → **Add to collection** → *New collection*).
2. Title: **LokalBot recommended local stack**. Visibility: **Public**. Description: paste the paragraph above.
3. For each item in the table: open the repo page → **Add to collection** → pick the collection → set **Note** to the curation note (quant + one-line why).
4. Order items so the roles read top-to-bottom as in the table (Transcription → Summaries → Autocomplete → Embeddings → Diarization).
5. Copy the collection slug (e.g. `https://huggingface.co/collections/<username>/lokalbot-recommended-local-stack-<hash>`) — it is the link used in the runbook's promotion checklist.

### Option B — huggingface_hub Python API

```python
from huggingface_hub import create_collection, add_collection_item

NS = "stevyhacker"  # your HF username or org

col = create_collection(
    title="LokalBot recommended local stack",
    namespace=NS,
    description=(
        "The local model stack behind LokalBot (https://github.com/stevyhacker/lokalbot) — "
        "a GPLv3 macOS app for bot-free, fully on-device meeting notes. Curation only: "
        "weights stay with their owners."
    ),
    private=False,
)

items = [
    ("model", "ibm-granite/granite-speech-4.1-2b-GGUF",
     "Default ASR. Q4_K_M + F16 projector (2.30 GB). Apache-2.0."),
    ("model", "unsloth/Qwen3.5-4B-GGUF",
     "Summaries/chat. Q4_K_M, measured ~100 tok/s on M4 Max."),
    ("model", "LiquidAI/LFM2.5-1.2B-Instruct",
     "Default autocomplete. Official repo; GGUF Q4_K_M via unsloth. LFM Open License — check revenue eligibility."),
    ("model", "unsloth/gemma-4-E4B-it-GGUF",
     "Higher-capacity autocomplete. UD-Q5_K_XL; instruct tune outperformed the base file in LokalBot's gate."),
    ("model", "Qwen/Qwen3-Embedding-0.6B-GGUF",
     "Semantic search. Q8_0 (0.64 GB) on a second llama-server --embeddings."),
    ("model", "FluidInference/speaker-diarization-coreml",
     "Diarization via FluidAudio; Core ML conversion of pyannote-community-1 (CC-BY-4.0)."),
]

for item_type, repo_id, note in items:
    add_collection_item(collection=col.slug, item_id=repo_id,
                        item_type=item_type, note=note)

print(col.slug)  # save this — the promotion checklist needs it
```

If `add_collection_item` rejects an item type, re-check the id against the API first — ids drift; never substitute an unverified look-alike.

## Non-goals

- No mirrors, forks, or reuploads of any weights — including "convenience" quant packs. Link only.
- No fine-tunes/merges of the curated models under the LokalBot name.
- The collection holds models only; the benchmark Space is specified separately in `SPACE-benchmark.md`.
