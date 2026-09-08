# LocalFlow vs the market — September 2026

Checked 8 September 2026 against public pricing/feature pages. Vendor claims are
not independently verified. LocalFlow row describes v0.3.0 as shipped in this repo.

## The field

| | Wispr Flow | Superwhisper | Aqua Voice | VoiceInk | MacWhisper | Handy | **LocalFlow** |
|---|---|---|---|---|---|---|---|
| Engine | Cloud AI (own stack) | Local Whisper + optional BYO-key cloud LLMs | Cloud (Avalon, own model) | Local (optional paid cloud enhancement) | Local Whisper + optional cloud AI | Local (Whisper-family, CoreML) | **100% local**: Parakeet TDT v3 (ANE) + Gemma 4 E2B (MLX) |
| Price | Free (limited dictations) → Pro **$15/mo** → from $23/mo | Free → Pro **$8.49/mo** | 1,000 free words → **$8/mo** (annual) | **$25 once**, lifetime updates | Free → Pro one-time (Gumroad) | Free | **Free, MIT** |
| Platforms | macOS, Windows, iOS, Android | macOS, iOS | macOS, Windows, iOS (2026) | macOS (Apple Silicon) | macOS | macOS | macOS (Apple Silicon) |
| Live overlay while dictating | Yes | Yes | Yes | Yes | — | Yes | **Yes** (stable text + dimmed draft) |
| Speech cleanup by LLM | Yes (cloud) | Via cloud models (BYO keys) or local LLMs | Yes (filler strip, grammar, per-app format) | Yes — now local | Custom AI prompts | Optional post-processing | **Yes, fully local** (Gemma 4 E2B; measured bake-off) |
| Meeting capture + notes | Notetaker (Mac), speaker ID, Q&A over meetings | Meeting recording | — | — | Meeting recording, no bots | — | **System audio + mic, diarization, summary with [mm:ss] citations** |
| Memory / personalization | Learns names/jargon; calendar, Slack, MCP | Vocabulary + screen-aware "Super Mode" | "Deep Context" reads the screen | Custom words, smart replace | Custom prompts | Custom words | **Dictionary + voice profiles + archive Q&A with citations**; never reads the screen |
| Russian + English mix | Yes (cloud) | Yes | Yes (49 languages) | Yes | Yes | Yes | **Yes — the editing layer itself is tuned for it** (numbers, negations, self-corrections, tone guards) |
| Offline after install | No | Partially (local Whisper) | No | Yes | Yes | Yes | **Yes** (hash-pinned weights, no network use) |
| Open source | No | No | No | Yes (code public; binaries paid) | No | Yes | **Yes, MIT** |

## Where LocalFlow already stands with the leaders

- **The core Wispr Flow loop works locally**: shortcut → live overlay → stop → on-device
  edit → insert at cursor → overlay dismisses. No subscription, no cloud, clipboard restored.
- **Meetings with a searchable archive** is a combination most one-time-payment local tools
  don't ship; among cloud players it's a Pro feature.
- **Safety rails are a differentiator**: number/negation/self-correction guards, minimal-cleanup
  fallback, citation-gated archive answers. No competitor documents an equivalent; local
  editing without such guards is exactly where meaning gets silently changed.
- **Model choice is measured, not vibes**: pinned revisions, checksums, a reproducible
  bake-off that switched the default editor (Qwen3 → Gemma 4) and disqualified Qwen3.5
  for inverting meaning on self-corrections.

## Where the leaders are honestly ahead

- **Latency polish.** Aqua reports ~450 ms to finished text after you stop (cloud trade-off).
  LocalFlow's warm editing is ~1.3 s per sentence; cold model load adds seconds. Targets
  (≤2 s first words, ≤5 s finalize) are documented but not yet validated on real speech.
- **Distribution.** Wispr/Superwhisper/VoiceInk ship notarized installers with auto-updates;
  LocalFlow is build-it-yourself with local signing by design.
- **Context awareness.** Aqua's Deep Context and Superwhisper's Super Mode read the screen
  to fix jargon/casing. LocalFlow deliberately doesn't — an opt-in "context near cursor"
  is the honest compromise sketched in the strategy doc.
- **Diarization accuracy** on similar voices (known 4→3 failure), and the editing prompts
  are Russian-first; other languages inherit ASR support but not tuned editing.
- **Integrations** (calendar, Slack, MCP for external AI tools) and non-Mac platforms.

## Pet-project trajectory (proposed)

1. **Daily-driver hardening** — real-speech latency/accuracy log, notarized build + DMG for friends, CI running the test suite.
2. **Smarter, still private** — auto-learning dictionary from accepted corrections, per-app editing modes, keep-warm option.
3. **Open the archive** — MCP server so Claude/ChatGPT can query your own transcripts with citations.
4. **Community** — CONTRIBUTING, good-first-issues (localization is the obvious one: UI strings are currently Russian), roadmap board.

The niche that stays defensible for a personal project: *a Wispr-Flow-class loop that is
fully local, Russian-first, MIT, and honest about its guards and benchmarks.*

## Sources

- Wispr Flow pricing/features: https://wisprflow.ai/pricing
- Superwhisper: https://superwhisper.com/
- Aqua FAQ (speed, accuracy, pricing, languages): https://aquavoice.com/info/faq
- VoiceInk: https://tryvoiceink.com/ , code: https://github.com/beingpax/VoiceInk
- MacWhisper: https://macwhisper.com/
- Handy: https://github.com/cjpais/Handy
- Earlier positioning analysis: [product-strategy.md](product-strategy.md)
