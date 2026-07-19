# LokalBot Privacy Policy

Effective: July 12, 2026

LokalBot is a local-first macOS application. It has no LokalBot account,
analytics service, advertising SDK, or telemetry backend. The project does not
receive your recordings, transcripts, summaries, screenshots, prompts, files,
calendar events, or usage history.

## Data stored on your Mac

LokalBot can store the following under its Application Support directory:

- meeting microphone and system-audio tracks;
- transcripts, summaries, notes, search indexes, and meeting metadata;
- downloaded transcription, embedding, speech, and language models;
- opt-in app/window activity history;
- opt-in visible screen text and optional encrypted screenshots;
- saved screen moments, optional unencrypted daily-memory exports, and optional
  routine drafts at folders you choose;
- opt-in Agent Mode sessions and the agent runtime; and
- preferences, diagnostic logs, and encryption keys.

Screen context is off by default. You can enable accessible text without pixels
or pair it with encrypted screenshots. Pixels are deleted after 14 days by
default, and captured text follows the same retention unless you explicitly
choose to keep it. Saved moments remain until you unsave or delete them.
Dictation scratch audio is deleted after transcription by default. You can
delete an individual meeting in the app or remove the entire LokalBot
Application Support directory.

## Network access

Core recording and local inference do not require a LokalBot-operated server.
The app may make these outbound connections:

- **Models:** model metadata and model files from Hugging Face or a model
  publisher's download host. Selected first-use models can download
  automatically; other downloads start when you request them.
- **Updates:** the public GitHub Releases appcast and a signed update. Automatic
  checks are enabled for new installs and can be disabled in Settings; you can
  also run a manual check.
- **Optional remote inference:** an Ollama or OpenAI-compatible URL that you
  configure. Loopback URLs stay on your Mac. Before a non-loopback server can
  receive meeting, workday, or agent context, LokalBot requires approval for
  that exact origin. The operator of that server controls its privacy terms.
- **Optional Agent Mode:** enabling Agent Mode downloads its pinned runtime.
  Commands you approve can read files or access the network with your macOS
  user permissions; their destinations and data handling are outside
  LokalBot's control.

Those services receive normal connection metadata such as your IP address and
request headers. LokalBot does not add an advertising identifier and does not
use those requests to track you.

## Permissions

LokalBot asks only for permissions needed by features you choose:

- Microphone and system audio for recording meetings.
- Calendar access for meeting detection and titles.
- Accessibility for browser-meeting detection, Cotyping, dictation insertion,
  visible-text context, and approved agent interaction.
- Screen Recording only when you opt into visual screen context.

Recording defaults to manual on a fresh install. You are responsible for
obtaining any consent required before recording other people.

## External-agent access

The bundled `lokalbot-cli` and MCP interface are read-only. They refuse library
access unless you explicitly enable Agent Access under Settings → Privacy. An
enabled external tool runs as your macOS user, so only connect tools you trust.
Screen-memory MCP tools require a second, independent toggle and a history
profile: today, the rolling last seven days, or all retained history. They
expose captured text, window/app activity, timestamps, and capture metadata,
but never decrypted screenshot pixels or screenshot file paths. Queries are
clamped to the granted period and out-of-scope ids appear missing. Enabling
meeting access does not enable screen-memory access, or vice versa. A connected
MCP client may transmit tool inputs and results under that client's own privacy
terms.

Screen pixels and captured text follow the configured retention window by
default. A screen moment you explicitly save retains its encrypted pixels,
captured text, and semantic search vector until you unsave or delete that
moment. Private/incognito windows, excluded apps and domains, and focused
secure fields are skipped by default. Detected credential text is redacted and
causes the associated pixel payload to be dropped; no detector is perfect, so
exclude any source whose content should never be retained. Daily-memory exports
and routine outputs are ordinary unencrypted Markdown files written only to
folders you choose and remain there until you remove them. Routines have fixed
local read scopes and cannot run scripts, contact services, send messages, or
modify source meetings.

## Security and changes

No software can promise absolute security. Please report vulnerabilities using
the private channel in [SECURITY.md](SECURITY.md). Material changes to this
policy will be documented in the repository and release notes with a new
effective date.

## Contact

For privacy questions, open a support issue using the contact path in
[SUPPORT.md](SUPPORT.md). Do not include recordings, transcripts, secrets, or
other sensitive data in a public issue.
