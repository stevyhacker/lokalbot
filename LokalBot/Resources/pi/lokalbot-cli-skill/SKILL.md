---
name: lokalbot-library
description: Query the user's LokalBot meeting library (transcripts, summaries, full-text search) via the lokalbot-cli tool. Use when asked about the user's meetings, recordings, or what was said or decided in them.
---

# LokalBot meeting library

`lokalbot-cli` is preinstalled on PATH and gives read-only access to the
meeting library. Output is JSON by default; add `--table` for human-readable.

- `lokalbot-cli list [--limit N]` — recent meetings (id, title, date, duration)
- `lokalbot-cli get <id>` — one meeting's metadata and summary
- `lokalbot-cli search "<query>"` — full-text search across transcripts
- `lokalbot-cli path <id>` — filesystem folder of a meeting (transcript.md, summary.md, audio)

Prefer `search` over reading transcript files directly — transcripts can be
very long. Never modify files inside the library; treat it as read-only.
