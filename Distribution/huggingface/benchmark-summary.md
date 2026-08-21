# LokalBot local-stack benchmarks — extracted numbers

Every number below is copied verbatim from a file in this repository; the **Source** column is the path to check. Nothing here is estimated or invented. All measurements to date were taken on a single machine: an **Apple M4 Max MacBook Pro, 48 GB**, running LokalBot's bundled llama.cpp runtime with full Metal offload (per `README.md`, "Example model stack and performance").

## Recommended-stack leaderboard (generation throughput)

| Role | Model | Quant / format | Model files size | Measured | Hardware | Source |
| --- | --- | --- | ---: | --- | --- | --- |
| Summaries and chat | Qwen3.5 4B | `Q4_K_M` | 2.74 GB | ~100 tokens/s generation | 48 GB M4 Max, bundled llama.cpp, full Metal offload | `README.md` (model stack table) |
| Autocomplete (higher-capacity option) | Gemma 4 E4B | `UD-Q5_K_XL` | 6.66 GB | ~78 tokens/s generation | 48 GB M4 Max, bundled llama.cpp, full Metal offload | `README.md` (model stack table) |
| Transcription (default) | IBM Granite Speech 4.1 2B | `Q4_K_M` + F16 projector | 2.30 GB | ASR — no generation-speed figure published | 48 GB M4 Max | `README.md` (model stack table) |
| Semantic search | Qwen3-Embedding 0.6B | `Q8_0` | 0.64 GB | Embeddings; not generative | 48 GB M4 Max | `README.md` (model stack table) |
| Speaker diarization | pyannote-community-1 via FluidAudio | Core ML | ~0.10 GB | Diarization; not generative | 48 GB M4 Max | `README.md` (model stack table) |

The full measured example stack occupies about **12.4 GB** after download (`README.md`). The current *Recommended* preset uses the smaller LFM2.5 1.2B for Autocomplete instead of Gemma (see next table).

Transcription speed headline: **Parakeet runs up to ~190× realtime in local benchmarks** (`README.md`, features section; repeated in `Docs/show-hn-kit.md`, `Docs/reddit-launch-posts.md`). No realtime factor has been published for Granite Speech 4.1, Whisper large-v3 turbo, or Qwen3-ASR.

## Cotyping (inline autocomplete) latency matrix

Harness: production `LokalBot --cotyping-bench`, all 28 default scenarios through the real in-process llama.cpp engine. Gate = 28/28 safety, ≥12/13 word completions, p95 ≤ 2000 ms. Source: `Benchmarks/Cotyping/results/2026-07-21-model-debounce-benchmark.md`.

| Model | Exact file | Bytes | Safety | Word completions | Avg latency | p95 latency | Gate |
| --- | --- | ---: | --- | --- | --- | --- | --- |
| LFM2.5 1.2B Instruct | `LFM2.5-1.2B-Instruct-Q4_K_M.gguf` | 730,895,584 | 28/28 | 12/13 | 143 / 143 / 151 ms (3 warmed runs) | 484 / 487 / 494 ms | Pass ×3 |
| Gemma 4 E4B Instruct | `gemma-4-E4B-it-UD-Q5_K_XL.gguf` | 6,656,152,736 | 28/28 | 12/13 | 399 ms | 1,830 ms | Pass |
| Qwen3.5 2B | `Qwen3.5-2B-Q4_K_M.gguf` | 1,280,835,840 | 27/28 | 11/13 | 437 ms | 1,629 ms | Fail quality |
| Qwen3.5 4B | `Qwen3.5-4B-Q4_K_M.gguf` | 2,740,937,888 | 27/28 | 11/13 | 434 ms | 1,652 ms | Fail quality |
| Gemma 4 E2B (base) | `gemma-4-E2B.i1-Q6_K.gguf` | 3,845,328,608 | 26/28 | 10/13 | 883 ms | 2,560 ms | Fail quality + latency |
| Gemma 4 E4B (base) | `gemma-4-E4B-UD-Q5_K_XL.gguf` | 6,700,259,616 | 26/28 | 10/13 | 697 ms | 3,022 ms | Fail quality + latency |

Supporting figures from the same sources:

- LFM2.5 keyword relevance: **15/64 hits vs 13/64** for the Gemma instruct baseline — "a weak relevance signal, not a separate gate" (`Benchmarks/Cotyping/results/2026-07-21-model-debounce-benchmark.md`).
- Cold Metal-kernel compilation, first scenario only: LFM2.5 **19,349 ms**, Gemma E4B instruct **127,466 ms** (same file).
- Debounce replay on LFM warmed runs: in-process debounce **35 / 55 ms** avg/p95; inferred end-to-end **178–186 / 509–519 ms** avg/p95 (same file; arithmetic replay, not a typing trace).
- Earlier engine bench (2026-07-06): Gemma E4B instruct avg **459 ms**, p95 **1798 ms**, steady-state **~200 ms**; the base variant measured avg **564 ms**, p95 **2393 ms** (`Benchmarks/Cotyping/results/2026-07-06-cotypist-parity.md`; raw JSON siblings `2026-07-06-engine-bench.json`, `2026-07-06-engine-bench-base-model.json`). A later side-by-side run logged avg **471 ms** / p95 **1798 ms** (`Benchmarks/Cotyping/results/20260706-165057-cotypist-vs-lokalbot.md`; its GUI capture leg recorded no insertions and is not usable as data).

## Screenshot OCR — real stored screenshots

Input: 15 real LokalBot screenshots exported from the encrypted local store; Apple Vision baseline min 140.8 ms / max 404.8 ms. Hardware: M4 Max. Source: `Benchmarks/OCR/RESULTS-2026-06-24.md`. "Overlap" = token overlap vs Apple Vision output.

| Engine | Images | Mean latency | Token overlap vs Vision | Verdict in source |
| --- | ---: | ---: | ---: | --- |
| Apple Vision `VNRecognizeTextRequest` | 15 | 243.2 ms | — | Current LokalBot baseline |
| PP-OCRv5 mobile det+rec | 5 | 18.46 s | 0.187 | Too slow |
| PP-OCRv5 server det+rec | 5 | 15.32 s | 0.147 | Too slow |
| PP-OCRv6 medium det+rec | 5 | 22.43 s | 0.208 | Too slow |
| TrOCR small printed | 3 | 2.47 s | 0.001 | Line-level; not a screenshot replacement |
| GOT-OCR 2.0 (HF, MPS, 256-token cap) | 3 | 3.70 s | 0.000 | Poor screenshot output |
| GLM-OCR (MPS, 256-token cap) | 3 | 5.74 s | 0.127 | Too slow/partial |
| PaddleOCR-VL 1.6 GGUF (256-token cap) | 3 | 1.30 s | 0.027 | Fast but heavily truncated |
| PaddleOCR-VL 1.6 GGUF (1024-token cap) | 3 | 2.74 s | 0.104 | Best non-Vision runtime, still slower and partial |
| DeepSeek-OCR GGUF (512-token cap) | 3 | 1.64 s | 0.000 | Hallucinated unrelated content |

## Screenshot OCR — synthetic set with ground truth

Input: 5 generated screenshots with ground-truth text (`Benchmarks/OCR/synthetic/manifest.tsv`). Metric: normalized multiset token scores; char similarity is reading-order sensitive. Hardware: M4 Max. Source: `Benchmarks/OCR/SYNTHETIC-RESULTS-2026-06-24.md`.

| Engine | Mean latency | Token precision | Token recall | Token F1 | Char similarity |
| --- | ---: | ---: | ---: | ---: | ---: |
| Apple Vision | 119.6 ms | 0.971 | 0.971 | 0.971 | 0.812 |
| PP-OCRv6 medium | 6.78 s | 0.960 | 0.990 | 0.974 | 0.867 |
| PaddleOCR-VL GGUF | 1.70 s | 0.871 | 0.813 | 0.777 | 0.731 |
| DeepSeek-OCR GGUF | 1.44 s | 0.844 | 0.732 | 0.741 | 0.680 |

Notes from the same file: PP-OCRv6 was the only open-source option slightly above Apple Vision on quality but **~57× slower** with a **~15 s model load**; a DeepSeek-OCR rerun with the upstream-style `Free OCR.` prompt fell to mean token F1 **0.529**. Decision in both OCR files: keep Apple Vision as the default screenshot OCR pipeline.

## Honest gaps — what is NOT yet measured

| Gap | One-line plan |
| --- | --- |
| Single-chip coverage: every number above is one M4 Max (48 GB) | Re-run `--cotyping-bench` and the OCR harness on M1, M2, and M3 machines before claiming per-chip guidance. |
| No ASR accuracy (WER/CER) for any transcription engine | Run Granite Speech 4.1, Parakeet v3, Whisper large-v3 turbo, and Qwen3-ASR against a standard eval set (e.g. Common Voice / ESB subsets) and publish WER alongside the realtime factors. |
| No realtime factor for Granite Speech 4.1, Whisper, or Qwen3-ASR | Time each engine over a fixed reference audio file and record ×realtime like the existing Parakeet figure. |
| No diarization error rate (DER) for pyannote-community-1 via FluidAudio | Score against a labeled multi-speaker fixture using pyannote.metrics or dscore. |
| No embedding-retrieval quality metric for Qwen3-Embedding 0.6B | Build a small recall@k fixture from real meeting queries and measure hit rate against hand-labeled relevant meetings. |
| No summarization-quality evaluation for Qwen3.5 4B | Human-rate recaps on a fixed meeting corpus (faithfulness, action-item completeness); publish rubric + raw ratings. |
| OCR sets are small (15 real + 5 synthetic screenshots) | Grow the synthetic manifest to ≥50 fixtures across app categories and re-run `score_text_outputs.py`. |
| Cotyping keyword-hit count is self-declared a weak signal | Replace with a curated expected-completion suite reviewed by humans before quoting relevance numbers. |
