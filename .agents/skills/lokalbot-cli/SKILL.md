---
name: lokalbot-cli
description: Read your LokalBot meeting library (recordings, transcripts, summaries) from a shell command. Use whenever the user asks about past meetings, decisions, action items, or anything that happened during a recorded meeting.
---

# LokalBot CLI Skill

LokalBot is a local-first macOS app that records, transcribes, and summarises meetings entirely on-device. Audio, transcripts, and summaries live in `~/Library/Application Support/com.dotenv.BotinaV2/meetings/`. The `lokalbot-cli` binary reads that library and prints meeting data so other tools (coding agents, shell scripts) can use it without launching the GUI.

## When to invoke

- The user mentions a meeting, call, sync, standup, or talk that probably happened recently.
- The user asks about a decision, an action item, a quote, or "who said X" — that knowledge likely lives in a meeting summary or transcript.
- The user wants to find past mentions of a topic across all meetings.

## Discovery

```bash
# Newest 10 meetings, JSON
lokalbot-cli list --limit 10

# Human-readable table
lokalbot-cli list --limit 10 --table

# Filter by date or title substring
lokalbot-cli list --since 2026-06-01 --query "design"
```

The `id` field in each list entry is an 8-character prefix that the other commands accept.

## Reading a single meeting

```bash
# The most recent meeting, full markdown
lokalbot-cli get latest

# Specific meeting by short id
lokalbot-cli get 4f7c2a91

# Just the summary, as JSON (parse-friendly for agents)
lokalbot-cli get 4f7c2a91 --include summary --format json

# Transcript only
lokalbot-cli get 4f7c2a91 --include transcript
```

`--include` accepts a comma-separated list of `metadata`, `summary`, `transcript`. Default is all three.

## Cross-meeting search

```bash
# Substring search across titles, summaries, and transcripts
lokalbot-cli search "auth refactor"

# Quick scan, table form
lokalbot-cli search "auth refactor" --table --limit 20
```

Transcript hits include a `timestamp` (HH:MM:SS) so the user can jump to that moment in the in-app player.

## Path lookup

```bash
# Library root (useful for grep/ripgrep)
lokalbot-cli path

# A specific meeting's folder — `mic.m4a`, `system.m4a`, `summary.md`, etc.
lokalbot-cli path latest
cd $(lokalbot-cli path latest)
```

## What you SHOULD do

- Lead with `list` to surface candidate meetings.
- Use `get` for the substance — quote actual snippets, never paraphrase past the meeting summary.
- Use `search` when the user remembers a phrase but not when the meeting happened.
- Cite the meeting by title and date in your answer; the `list` output has both.

## What you MUST NOT do

- Never invent meeting content. If `lokalbot-cli` returns no hits, say so.
- Never write into the meetings folder. The CLI is read-only by design.
- Never paste full transcripts into the chat unless explicitly asked — long meetings are long. Summarise, then offer to expand.
