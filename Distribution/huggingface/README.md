# Hugging Face presence kit — publishing runbook

Everything in this directory ships LokalBot's Hugging Face presence: a curated model Collection, a static benchmark Space, and the extracted benchmark data both of them present. **No weights are ever rehosted** — the collection links to model owners' repos, so licenses and bandwidth stay where they belong.

## Files

| File | Purpose |
| --- | --- |
| `benchmark-summary.md` | Every measured number in the repo, each with its source path, plus honest gaps. Single source of truth. |
| `COLLECTION.md` | Spec for the "LokalBot recommended local stack" collection: verified repo ids, curation notes, creation steps (UI + API). |
| `SPACE-benchmark.md` | Spec for the static Space hosting the benchmark summary, including frontmatter and cross-link plan. |
| `scripts/create_collection.py` | Idempotently verifies the model repos and creates the public Collection. |
| `scripts/render_space.py` | Renders the benchmark summary into the static Space HTML. |
| `scripts/create_space.py` | Creates or updates the public static Space through `huggingface_hub`. |
| `space/` | Space-card template, generated card/HTML, and stylesheet. Only `README.md`, `index.html`, and `style.css` are uploaded. |

## Prerequisites

- A Hugging Face account (`huggingface.co/join`). Using the existing `stevyhacker` account keeps collection/Space URLs consistent with the GitHub handle.
- For the API path only: install the current CLI with `uv tool install hf` (or run it ephemerally with `uvx hf`), then `hf auth login` with a write token.
- No other tooling required — the Space is static.

## Step 1 — Create the Collection

All referenced repo ids were verified against the HF API on 2026-08-21. With a write token, create and populate the Collection idempotently:

```sh
uv run --with huggingface_hub python Distribution/huggingface/scripts/create_collection.py
```

The script prints the Collection URL. Without a write token, follow the web-UI path in `COLLECTION.md` and save the resulting URL.

## Step 2 — Create the benchmark Space

Render `index.html` with the Collection URL, then create or update the Static SDK Space:

```sh
uv run --with markdown python Distribution/huggingface/scripts/render_space.py \
  --collection-url "https://huggingface.co/collections/<collection-slug>"
uv run --with huggingface_hub python Distribution/huggingface/scripts/create_space.py
```

Without a write token, create a public Static Space named `lokalbot-benchmarks` in the web UI and upload the three files from `space/`.

## Step 3 — Publish checklist

- [ ] Collection is public; all six items show curation notes; order matches `COLLECTION.md`.
- [ ] Space renders all four sections (stack leaderboard, cotyping matrix, two OCR tables) plus the gaps table.
- [ ] Space header/footer link to the GitHub repo; each table's source path resolves on GitHub.
- [ ] Collection description contains the repo link (`https://github.com/stevyhacker/lokalbot`).
- [ ] Nothing anywhere mirrors or re-uploads weights.

## Step 4 — Promotion checklist

- [ ] **lokalbot.com**: add the Space + collection links to the site footer or the "local transcription models compared" post. *(Site edit is not part of this kit — maintainer follow-up.)*
- [ ] **Repo README**: one line under the model-stack table linking the Space ("Interactive benchmark summary: …"). *(README edit is owned by the Registries agent / maintainer follow-up — do not edit it here.)*
- [ ] **r/LocalLLaMA**: mention the collection + Space in the next model-stack thread (see `Docs/reddit-localllama-followup-2026-07.md` for tone); lead with the numbers, not the app.
- [ ] **Release notes**: add the collection link to the next GitHub release body (v0.6.3+) under "Recommended models".
- [ ] **HF community post**: short article "the local stack behind a Mac meeting-notes app" tagging IBM Granite, NVIDIA (Parakeet), Qwen, LiquidAI, and FluidInference teams — per `Docs/distribution-channels-2026-07.md`, their devrel reshare downstream wins.
- [ ] Re-run the gap experiments from `benchmark-summary.md` when hardware access allows (M1/M2/M3 coverage, WER) and re-publish the Space.

## Maintenance rules

- `benchmark-summary.md` changes first; regenerate the Space HTML from it; never hand-edit the HTML.
- Any newly quoted number must carry a repo source path — same bar as the existing file.
- Model ids drift: before any public post, re-verify ids via `https://huggingface.co/api/models?search=<name>` exactly as `COLLECTION.md` documents.
