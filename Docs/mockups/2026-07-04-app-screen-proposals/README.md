# LokalBot App Screen Mockup Proposals

Generated: 2026-07-04

These are visual proposal mockups for the current LokalBot app surface, generated with the built-in `image_gen` workflow. They are proposal artifacts, not implementation screenshots. Small labels, model names, and sample meeting content are representative and should be reconciled against the SwiftUI source before implementation.

## Screen Set

| File | Proposal surface | Current source anchor |
| --- | --- | --- |
| [01-onboarding-welcome.png](./01-onboarding-welcome.png) | First-run onboarding welcome | `LokalBot/Views/OnboardingView.swift` |
| [02-capture-timeline-day.png](./02-capture-timeline-day.png) | Capture day timeline + day overview | `LokalBot/Views/CaptureView.swift`, `LokalBot/Views/CaptureDetailView.swift` |
| [03-capture-library-meeting-detail.png](./03-capture-library-meeting-detail.png) | Meeting library + selected meeting detail | `LokalBot/Views/MeetingListView.swift`, `LokalBot/Views/MainWindowView.swift` |
| [04-ask-search-results.png](./04-ask-search-results.png) | Ask unified search/results state | `LokalBot/Views/AskView.swift` |
| [05-ask-conversation.png](./05-ask-conversation.png) | Ask assistant answer + citations state | `LokalBot/Views/AskView.swift`, `LokalBot/Views/ChatView.swift` |
| [06-type-dictation.png](./06-type-dictation.png) | Type / Dictation tab | `LokalBot/Views/TypeView.swift`, `LokalBot/Views/DictationView.swift` |
| [07-type-cotyping.png](./07-type-cotyping.png) | Type / Cotyping tab | `LokalBot/Views/TypeView.swift`, `LokalBot/Views/CotypingView.swift` |
| [08-settings-general.png](./08-settings-general.png) | Settings / General tab | `LokalBot/Views/SettingsView.swift` |
| [09-settings-models.png](./09-settings-models.png) | Settings / Models tab | `LokalBot/Views/SettingsView.swift`, `LokalBot/Views/ModelsView.swift` |
| [10-menu-bar-popover.png](./10-menu-bar-popover.png) | Menu bar recording popover | `LokalBot/Views/MenuBarView.swift` |
| [11-command-palette.png](./11-command-palette.png) | Command palette overlay | `LokalBot/Views/CommandPaletteView.swift` |
| [12-floating-overlays.png](./12-floating-overlays.png) | Dictation HUD, cotyping ghost, audio banner | `LokalBot/Dictation/DictationOverlayView.swift`, `LokalBot/Cotyping/CotypingGhostView.swift`, `LokalBot/Views/AudioSourceBanner.swift` |

## Direction

- Keep the current local-first product promise visible: no account, no plan, no cloud workspace, no billing surface.
- Keep the primary navigation compact: Capture, Ask, Type, Settings.
- Use slate hero/HUD surfaces sparingly for live or high-value states, while keeping standard panes native macOS.
- Treat teal as the primary action/accent, amber as live/attention state, and red as destructive stop/cancel.
- Keep dense settings/model surfaces scan-friendly instead of turning them into marketing cards.

## Prompt Set

Each image used the same base prompt direction:

- `Use case: ui-mockup`
- Native SwiftUI/macOS dark-mode app screenshot or system-surface mockup
- Slate + teal LokalBot visual language, amber live cues, no decorative blobs
- Local-first/account-free constraints: no user profile, no Pro plan, no billing, no cloud account
- Screen-specific content grounded in the current app views listed above

Several images were regenerated or edited after review to remove account/pricing drift and old sidebar destinations.
