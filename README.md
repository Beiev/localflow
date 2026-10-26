# LocalFlow

**Local-first dictation, voice notes and meeting memory for macOS. Everything runs on your Mac — no cloud APIs, no subscriptions.**

LocalFlow is an open, privacy-first alternative to Wispr Flow built for Apple Silicon. Press **⌘B**, speak anywhere, and get clean, edited text pasted into the field you were typing in. Record calls with one shortcut, keep a voice diary, and ask questions across your own searchable archive — with every model running locally.

## What it does

- **Dictate anywhere (⌘B).** A button-free panel unfolds from the MacBook notch (top center on displays without a notch), showing a voice-level waveform and live transcript. Speak when the status reads “Слушаю…”: microphone initialization starts after the entrance finishes. Press ⌘B again to fold it away and finish recognition, editing and insertion in the background. Closing during the entrance skips recording and archive creation. Escape cancels, including during microphone startup; the clipboard is restored after pasting. Capture waits for real audio before reporting readiness and reconnects a stalled microphone, with a bounded fallback to the built-in input. Recording UI only opens on request; silence, errors and completion never reopen it. Errors and insertion results stay available in the main window, menu bar and archive.
- **Shortcuts you actually like.** Both global shortcuts (dictation and meeting capture) are re-recordable in Settings with live validation: conflicts with each other and system-critical combinations (⌘C/⌘V/⌘X/⌘Q/⌘W/⌘Space/⌘Tab) are rejected, function keys work without modifiers, and ⌘-shortcuts trigger on the left ⌘ only — the right ⌘ keeps reaching applications, so ⌘B still means Bold.
- **Two editing strengths.** *Tidy* removes speech noise while preserving facts, numbers, negations and your tone. *Flowing text* reorganizes a stream of thoughts into coherent paragraphs without inventing anything. A free-form *your style* field tunes both.
- **Voice notes as a quiet diary page.** Create a note, write a title and a line of context, then dictate into it whenever you're ready. Notes can be extended by voice later.
- **One-press meeting capture (⇧⌘M).** Records system audio and your microphone as separate tracks, transcribes both into speaker turns, splits speakers post-hoc, and condenses the transcript into a document of decisions, tasks, figures and open questions with `[mm:ss]` timestamps that play the matching audio. Measured on a real 29-minute two-person call: 21 892 characters of speech to a 6 095-character summary carrying 44 verified timestamps ([docs/validation.md](docs/validation.md)). Two honest limits remain: the system track captures *every* app's audio, so a video played during a call still enters the recording — identity folding now gives its speech to the nearest voice instead of inventing a participant for it, which is a better name above the words rather than a fix — and diarization can merge two similar voices into one identity.
- **A summary built in code, with one paragraph written by the model.** Condensing runs in six stages. Turns get stable identifiers and the model is shown identifiers and speaker names but never a clock, so it cannot invent a timestamp or hand back raw seconds; it reads a few minutes of conversation at a time and returns typed assertions — fact, decision, task, question — each citing the turns it came from. Everything after that is deterministic: an assertion citing a turn it was never shown is dropped as invented, so is one carrying a figure that occurs nowhere in the speech or on the screen — unless the turns it cites say a figure in words and write none in digits, where «30 %» over *«тридцать процентов»* is a transcription and not an invention — one opening with *нужно* or *надо* becomes a task however the model labelled it, an owner is accepted only when it matches a speaker the recording knows, paraphrases of one kind are merged by word overlap, each section keeps only its strongest entries, and the document is assembled from what survives with the clock attached from the cited turns. The opening paragraph is assembled in code from the assertions that survived — it names the participants, the counts, the decisions, a figure and an unanswered question. Asking the model for it was tried and dropped: a specificity check can tell a generic paragraph from a concrete one but not a coherent sentence from an incoherent one, and the paragraph it accepted on a real 45-minute call read *«Срок, связанный с 4 позиции, показал…»*. The assertions that survive are rewritten from speech into writing in one pass, line by line, and each rewritten line is taken only when it carries the same figures, the same polarity and no more length than the original allows — otherwise the original stands. They are then grouped into topics — by the model, which is allowed to group and name and nothing else, and whose answer is read back against the records: every number has to exist and is used once. What was settled is one list directly under the opening, because the outcome of a meeting is what a reader comes back for; each topic is then a passage assembled in code carrying the state of things, in the order of the conversation, every sentence with the moment it came from. A topic the model named «Разное» is the bin it put what it could not classify into, so its contents go under the flat heading instead. Tasks are a table when any of them has an owner or a deadline and a plain list when none does — seven rows reading «не назван» say less than seven lines — and a cell drops the word «нужно» in front of an infinitive, because the column is already called «Что». Finally one call reads the **whole** transcript at once and writes the opening paragraph — the one thing reading in windows cannot give, the through-line of the conversation. It is guarded: no lists, no clock it could not know, and every figure in it has to have been said, or it is dropped and the opening is assembled in code instead. Quality is tracked by deterministic proxies (`LocalFlowBench summary-quality`): misfiled bullets, unusable citations, invented figures, paraphrased repeats, tasks with no real owner. These are proxies, not proof: a document can pass all of them and still read badly.
- **The letter you send afterwards.** The meeting as a message to the people who were in it — the topics, the task table as lines, and what nobody answered — assembled from the document that already exists, without citations, without a model call, and with nothing in it that is not in the summary.
- **The record itself, next to the summary.** A meeting opens on three tabs — the condensed summary, a cleaned line-by-line transcript, and the raw recognition — and each copies to the clipboard in one click, as Markdown or without markup. Condensed documents render as formatting rather than asterisks, and every `[mm:ss]` in them is a control that plays that moment. The cleaned transcript is produced a few turns at a time behind a guard that compares the turns before and after: a window the model shortened, merged or renumbered is delivered as recognized instead of accepted, so polish can be lost on a stretch but the record cannot.
- **Voices get the names people used.** The microphone track is you; the remote voices are proposed from the conversation itself, because a name spoken right after a comma is aimed at somebody else in the room — two sides addressing each other therefore name each other, while a client discussed by one side only is named by nobody and stays out. Each proposal comes with the moment that says so, and accepting it is one click. Diarizer identities holding under 5 % of the remote speech *and* under a minute of it are folded into the voice beside them in time: measured over eleven real meetings, that turned three identities into one on a two-person call and left a genuinely quiet participant of a nine-person call alone ([docs/validation.md](docs/validation.md)).
- **What was on screen, folded into the notes (off by default).** During a meeting LocalFlow can read the display — the whole display minus its own windows, not only the call's window: one frame every three seconds on a second output of the stream that already carries the system audio, reduced to a 16×16 thumbnail, and only a frame that differs from the last one *read* is recognized at all. What is kept is the text on it and the window title — never video, never the frames themselves — as moments with a start and an end, because a slide that was up for four minutes is a span and not an instant. Those moments carry their own citation identifiers, so a line in the summary can point at a document that was shown exactly as it points at a sentence that was said, and the recording gains a screen tab and a "Что показывали" section. The app's own windows are excluded from the picture, the capture pauses with the recording, and everything read is deleted with the session's audio. Screen text reaches the model as data, with the prompt's own markers neutralised in it, and nothing read off a screen can become a decision or a task — only an observation, which has to cite the moment it was on screen. Copying the whole meeting copies the window titles and not what they said.
- **Your archive, answerable by your own assistant.** An MCP server ships inside the bundle: four read-only tools over stdio that let Claude, or anything else speaking MCP, search your recordings, read a summary or a transcript, and pull the exact moments that match a question — each with `[mm:ss]`, the speaker, and the recording it came from. Nothing leaves the machine, and nothing in the server can change or delete a recording. [docs/mcp.md](docs/mcp.md).
- **A copy where you already keep notes.** Point LocalFlow at a folder and every condensed meeting lands there as Markdown — dated, deterministically named, rewritten only when it changed. No service in between.
- **A memory that is actually yours.** A personal dictionary (heard → preferred spelling) is applied before every edit; familiar voices can be saved and recognized across meetings. Ask the archive a question and every claim comes with a citation and a playable timestamp.
- **Engineered for low load.** Models load on demand and unload automatically after idle (ASR after 2 min, editor after 1 min by default). A dictated sentence edits in ~1–2 s on an M3 Pro; nothing runs in the background while you're silent.

## The models (and why)

All weights are pinned to exact revisions with per-file checksums and downloaded once from their publishers; after that LocalFlow works fully offline.

| Role | Model | Disk |
|---|---|---:|
| Speech recognition (25 languages incl. Russian) | NVIDIA Parakeet TDT 0.6B v3, CoreML on the Neural Engine | 483 MB |
| Text editor & archive answers (default) | Google **Gemma 4 E2B** (4-bit MLX) | 3.6 GB |
| Alternative editor | Qwen3-4B-Instruct-2507 (4-bit MLX) | 2.3 GB |
| Speaker separation | Pyannote Community-1 / WeSpeaker (CoreML) | 22 MB |

The editor was chosen by a measured bake-off on a 10-case Russian dictation corpus ([docs/benchmarks](docs/benchmarks)): Gemma 4 E2B is ~2× faster than Qwen3-4B (0.32 s first token, ~76 tok/s) at equal or better fact preservation, and correctly handles self-corrections like *"send 12 files, not 15"*. Qwen3.5-4B was disqualified for silently changing meaning. Both remaining editors are selectable in Settings.

**Safety rails.** Every edited draft passes deterministic guards (ordered numbers with conservative separator handling, Russian/English negations and retained negation targets, corrected-number patterns, length ratios). A suspicious edit is never silently trusted: the minimal deterministic cleanup is delivered instead, and the model's proposal is kept as a separate version. The original transcript is always preserved. Rejected proposals carry specific review reasons, and dictation during meetings uses the same guarded delivery. These checks do not prove semantic equivalence. Archive answers without valid citations are rejected.

## Build & install

Requirements: Apple Silicon Mac, Xcode 26.6 with the Metal toolchain, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodebuild -downloadComponent MetalToolchain
Scripts/build.sh     # xcodegen + xcodebuild Release + local signing
Scripts/test.sh      # 307 unit/interface tests; no model weights needed
Scripts/install.sh   # installs to ~/Applications/LocalFlow.app
```

First run: open **Settings → Models**, download the recognizer and editor, grant Microphone and Accessibility (for ⌘B), and — for meeting audio — Screen & System Audio Recording. The app UI is currently in Russian; the codebase and docs are English-friendly and localization is on the roadmap.

The build is signed with a persistent local certificate (stored outside the repo), so permissions survive re-installs on your own Mac. This is not a notarized distribution — see [docs](docs/validation.md) for the honest limitations list.

## Data & privacy

Everything lives in `~/Library/Application Support/LocalFlow/`: a SQLite archive with full-text search (`archive.sqlite`), chunked 30-second audio parts with a crash-safe journal, and checksum-verified model weights. Audio is pruned after 30 days (pinned items are kept), texts stay until you delete them, and there is no telemetry of any kind. Recording survives crashes: transcription is checkpointed per window and resumes where it stopped.

Archive upgrades are transactional and create a local SQLite backup before changing an existing schema. Newer unsupported schemas are rejected. See [migration and recovery](docs/diagnostics.md#archive-migration-and-recovery).

## Quality and contributing

[Contributing](CONTRIBUTING.md) explains the development workflow and privacy rules for fixtures. GitHub Actions is configured to test and compile the app and benchmark harness on Apple Silicon. Hardware behavior and recognition accuracy still need separate real-world validation.

[Local diagnostics](docs/diagnostics.md) report review reasons and processing latency without exporting speech. New regular dictations record stop-to-ready and insertion acknowledgment timings, grouped by build/editor and warm/cold model state. Old recordings have no latency metadata. Audio replay measurements explicitly exclude capture and insertion.

## Repository layout

```
Sources/LocalFlowCore/   engine: audio capture, ASR/LLM/diarization, safety guards, SQLite store
Sources/LocalFlow/       SwiftUI app: overlay panel, archive, diary, settings
Sources/LocalFlowBench/  CLI benchmarking harness (ASR/editor/diarization pipelines)
Sources/LocalFlowMCP/    read-only MCP server over the archive (ships inside the app bundle)
Scripts/                 build, test, install, signing, model pinning, editor bake-off
docs/                    architecture, plan, validation log, benchmarks, product strategy
```

## Status & roadmap

v0.6.0 — daily-driver quality for the author's setup (M3 Pro / 18 GB, macOS 26): dictation, notes, meetings condensed into topics with a read-whole opening, optional screen reading, the archive open to your own assistant over MCP, model choice. Known limits: how readable a summary is cannot be measured by the proxies this repository ships, so it is judged by reading; topic grouping depends on a 2B model following an instruction, and falls back to flat sections when it does not; diarization can merge similar voices; screen reading has never been run on a live meeting, so there are no load or OCR-quality numbers for it; latency targets on real speech are still being measured; Slack and mobile are future work. Full details: [docs/plan.md](docs/plan.md), [docs/validation.md](docs/validation.md), [where it stands against the meeting-notes market](docs/competition-2026-10.md), [docs/product-strategy.md](docs/product-strategy.md).

## License

Code: [MIT](LICENSE). Model weights keep their publishers' licenses — see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
