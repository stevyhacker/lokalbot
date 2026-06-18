---
name: Bug report
about: Report a reproducible LokalBot (BotinaV2) bug
title: "[Bug] "
labels: bug
assignees: ""
---

## Category

Check all that apply:

- [ ] Recording / Audio capture (mic or system audio not captured, wrong source)
- [ ] Transcription (missing, garbled, or wrong-language text)
- [ ] Summarization / LLM (bad or empty summary, model or server errors)
- [ ] Permissions (Microphone, Screen Recording, or Accessibility)
- [ ] Performance / Crash (slow processing, hang, or crash)

## Summary

Describe the bug in one or two sentences.

## Environment

- macOS version:
- Audio source: microphone / system audio / both
- Transcription model (WhisperKit):
- Summarization engine: local llama.cpp / Ollama / OpenAI-compatible / Apple Intelligence
- Model name (if local / Ollama):
- Microphone permission granted: yes / no
- Screen Recording permission granted: yes / no
- Accessibility permission granted: yes / no

## Steps to reproduce

1.
2.
3.

## Expected behavior

Describe what you expected BotinaV2 to do.

## Actual behavior

Describe what happened instead.

## Notes

Add screenshots, recordings, or relevant lines from the debug log
(`~/Library/Application Support/com.dotenv.BotinaV2/debug.log`) here if useful.
