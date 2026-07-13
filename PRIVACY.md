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
- opt-in screenshots and locally extracted text;
- opt-in Agent Mode sessions and the agent runtime; and
- preferences, diagnostic logs, and encryption keys.

Screenshots are off by default, encrypted at rest, and deleted after 14 days by
default. Their extracted text follows the same retention unless you explicitly
choose to keep it. Dictation scratch audio is deleted after transcription by
default. You can delete an individual meeting in the app or remove the entire
LokalBot Application Support directory.

## Network access

Core recording and local inference do not require a LokalBot-operated server.
The app may make these outbound connections:

- **Models:** model metadata and model files from Hugging Face or a model
  publisher's download host. Selected first-use models can download
  automatically; other downloads start when you request them.
- **Updates:** the public GitHub Releases appcast and a signed update when you
  check for updates or enable automatic update checks.
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
  and approved agent interaction.
- Screen Recording for opt-in screen context capture.

Recording defaults to manual on a fresh install. You are responsible for
obtaining any consent required before recording other people.

## External-agent access

The bundled `lokalbot-cli` and MCP interface are read-only. They refuse library
access unless you explicitly enable Agent Access under Settings → Privacy. An
enabled external tool runs as your macOS user, so only connect tools you trust.

## Security and changes

No software can promise absolute security. Please report vulnerabilities using
the private channel in [SECURITY.md](SECURITY.md). Material changes to this
policy will be documented in the repository and release notes with a new
effective date.

## Contact

For privacy questions, open a support issue using the contact path in
[SUPPORT.md](SUPPORT.md). Do not include recordings, transcripts, secrets, or
other sensitive data in a public issue.
