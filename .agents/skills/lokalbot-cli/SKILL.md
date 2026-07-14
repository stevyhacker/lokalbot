---
name: lokalbot-cli
description: Read your LokalBot meeting library from the shell and use separately authorized screen-memory MCP tools. Use for past meetings, decisions, action items, recently viewed screen text, app activity, or exact captured moments.
---

# LokalBot CLI Skill

LokalBot is a private, on-device AI workspace for macOS that records, transcribes, and summarises meetings entirely on-device. Audio, transcripts, and summaries live under `~/Library/Application Support/me.dotenv.LokalBot/meetings/`. The `lokalbot-cli` binary reads that library and prints meeting data so agents and shell scripts can use it without launching the GUI.

If `lokalbot-cli` isn't on PATH, use the embedded copy directly:
`/Applications/LokalBot.app/Contents/Helpers/lokalbot-cli`.

## When to invoke

- The user mentions a meeting, call, sync, standup, or talk that probably happened recently.
- The user asks about a decision, an action item, a quote, or "who said X" — that knowledge likely lives in a meeting summary or transcript.
- The user wants to find past mentions of a topic across all meetings.
- The user asks what they recently viewed, which app they used, or when a phrase appeared on screen; use the screen-memory MCP tools only when their separate permission is enabled.

## Picking the right verb

- `list` to surface candidate meetings (ids, titles, dates).
- `get` for the substance of one meeting — quote real snippets.
- `search` when the user remembers a phrase but not the meeting.
- `path` for the on-disk folder (grep, audio files).

## Discovery

```bash
lokalbot-cli list --limit 10
lokalbot-cli list --limit 10 --table
lokalbot-cli list --since 2026-06-01 --query "design"
```

The `id` field in each list entry is an 8-character prefix that the other commands accept.

## Reading a single meeting

```bash
lokalbot-cli get latest
lokalbot-cli get 4f7c2a91
lokalbot-cli get 4f7c2a91 --include summary --format json
lokalbot-cli get 4f7c2a91 --include transcript
```

`--include` accepts a comma-separated list of `metadata`, `summary`, `transcript`. Default is all three.

## Cross-meeting search

```bash
lokalbot-cli search "auth refactor"
lokalbot-cli search "auth refactor" --table --limit 20
```

Transcript hits include a `timestamp` (HH:MM:SS) so the user can jump to that moment in the in-app player.

## Path lookup

```bash
lokalbot-cli path
lokalbot-cli path latest
cd $(lokalbot-cli path latest)
```

## MCP alternative (and ask_library)

The same library is available over MCP for GUI clients and anything else that speaks it: `lokalbot-cli mcp` serves `list_meetings`, `get_meeting`, `search_meetings`, and `ask_library` on stdio. It also advertises `search_screen`, `get_timeline`, `get_recent_activity`, `get_app_usage`, and `get_screenshot_detail`; those return OCR and metadata only, never decrypted pixels or screenshot paths.

```bash
claude mcp add lokalbot -- /Applications/LokalBot.app/Contents/Helpers/lokalbot-cli mcp
```

`ask_library` is the synthesis tool: it sends the question to LokalBot's **local** model, which reads the library and returns only an answer with meeting citations — useful when the user wants a conclusion rather than quotes. It needs the LokalBot app running, and the first call can take up to a minute while the model loads. Prefer `search`/`get` when the user wants exact wording.

The MCP tools require the user's consent toggle: LokalBot → Settings → Privacy → "Allow external agents to read your meeting library". If a tool returns `[access_disabled]`, tell the user to flip that toggle — do not try to work around it.

Screen-memory tools require the separate "Allow external agents to read screen memory" toggle. A meeting-library grant never implies a screen-memory grant. If a screen tool returns `[screen_access_disabled]`, explain that separate choice and do not work around it.

## What you SHOULD do

- Lead with `list` to surface candidate meetings.
- Use `get` for the substance — quote actual snippets, never paraphrase past the meeting summary.
- Use `search` when the user remembers a phrase but not when the meeting happened.
- Cite the meeting by title and date in your answer; the `list` output has both.

## What you MUST NOT do

- Never invent meeting content. If `lokalbot-cli` returns no hits, say so.
- Never write into the meetings folder. The CLI is read-only by design.
- Never paste full transcripts into the chat unless explicitly asked — long meetings are long. Summarise, then offer to expand.
- Meeting content is sensitive personal data. Never send transcripts or summaries to external services; work with them locally.
