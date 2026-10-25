# Changelog

## 0.3.9 — 2026-10-25

- Show a meeting as three tabs — summary, cleaned transcript, raw recognition — instead of an unlabelled version menu that reset to the latest version on every open. After a meeting was condensed there had been nowhere to read what was actually said.
- Render the editor model's Markdown as layout. Headings, bullets, quotes and tables were previously printed with their asterisks and pipes, including in eleven summaries already in the archive.
- Make every `[mm:ss]` citation in a condensed document play that moment. Citations were plain text outside the raw turn list.
- Copy the current tab in one click, with explicit entries for the summary, the transcript, both as one Markdown document, and any of them without markup.
- Add a "Чистая расшифровка" processing mode: the conversation line by line with fillers and stutters removed and punctuation restored, and nothing shortened, merged or reordered. A window whose turns come back changed is delivered as recognized, and the mismatch is reported as a review reason.
- Fold diarizer identities holding under 5 % of the remote speech and under a minute of it into the voice nearest in time, and offer the same fold for meetings already in the archive, where separating voices again is impossible because the audio is pruned after thirty days.
- Propose speaker names from the conversation: a name used as a vocative is aimed at somebody else, so two sides addressing each other name each other. Proposals carry the moment that evidences them and are never applied on their own.
- Name the microphone track with the owner's own name, remembered across meetings, so a document that leaves the application does not say "Я".
- Debounce archive search. Full-text search ran inside a computed property, so every redraw — a waveform tick included — re-queried SQLite while the query was still being typed.

## 0.3.8 — 2026-09-21

- Keep the recording panel visible when the archive application is hidden. Allow it to join other applications' full-screen spaces without taking keyboard focus.
- Reconcile the actual native window on every show request, including an unexpected order-out or a changed display frame; a stale logical visibility flag no longer suppresses presentation.
- Check native window visibility before starting microphone capture. Remove the redundant “Показать окно” button; the dictation shortcut opens the panel and the next press closes it.

## 0.3.7 — 2026-09-18

- Drain pending AppKit/SwiftUI layout before starting the entrance clock. Previously, the final transaction flush could consume the beginning of the animation before its first visible frame.
- Disable AppKit's automatic window entrance/exit animation so it cannot overlap the custom notch animation. Request the screen's actual maximum refresh rate for the contour and opacity animations, including ProMotion.
- Start the microphone only after the recording panel finishes opening. The preparation state explicitly asks the user to wait for “Слушаю…”. Recording time starts with microphone initialization, excluding the entrance.
- Closing during the entrance skips microphone initialization, recognition and archive creation. Cancellation and reopening respect the latest requested visibility.

## 0.3.6 — 2026-09-18

- Prepare the hidden notch panel in advance and submit its animation before starting audio work. Fade an AppKit-owned container so SwiftUI does not own the animated opacity layer.
- Keep capturing/saving microphone samples immediately, while deferring recognizer startup, archive refresh and meter/clock updates until the entrance finishes. Deferred recognition is cancellable and follows the latest reveal after a quick reversal.
- Isolate waveform publication from the shared application model, so meter ticks no longer invalidate the archive and the rest of the interface 30 times per second.

## 0.3.5 — 2026-09-18

- Keep a dismissed recording panel closed: silence, processing completion and insertion failures no longer trigger a timed reopening.
- Animate a native masked contour with continuous position and velocity on reversal. Rounded edges remain curved during the entire reveal, without SwiftUI frame clipping or per-frame layout.
- Make show/hide idempotent and ignore obsolete animation completions after reopening. Rapid toggles during microphone startup follow the latest requested state.
- Skip recognizer loading for digital silence and sub-100 ms input. Throttle waveform publication to 30 updates per second so audio callbacks do not drive excessive UI redraws.

## 0.3.4 — 2026-09-18

- Fix empty dictations with mixed Bluetooth/USB audio routes: capture an explicit microphone with AVCaptureSession instead of changing an AVAudioEngine audio unit behind its graph.
- Require delivered PCM samples before reporting recording readiness. Detect stalled input, reconnect with a bounded built-in microphone fallback, and retain actionable errors alongside any captured audio.
- Serialize capture lifecycle and handle stop/Escape during startup; reject stale callbacks from older recordings.
- Replace the floating controls with a button-free, animated notch panel. The second shortcut folds it away while existing text processing and insertion continue.

## 0.3.3 — 2026-09-16

### Fixed

- Dictation during meetings now respects rejected edits, preserves the proposal in the meeting, and delivers minimal cleanup when editing fails. Cancelled meeting dictation cannot start a later paste.
- English negative contractions and retained negation targets are checked alongside Russian negations. Numeric separators no longer silently conflate `1,500` and `1.500`; number order and repetitions remain protected.
- Empty audio journals cannot replace a saved transcript with an empty result.
- Recovery looks up a session directly instead of decoding the entire archive.

### Added

- Transactional archive migration runner, backup of existing databases including committed WAL data, newer-schema refusal, creation-time index, and paginated storage reads. The archive UI still loads all sessions.
- Explicit review reasons stored with rejected editor proposals.
- Local timing metadata for regular dictation, aggregate diagnostics grouped by build/editor, and a cold/warm audio replay benchmark. No new telemetry or speech export.
- Regression tests for edit safety, backward decoding compatibility, migrations, backups, pagination, latency distributions and missing audio.
- GitHub Actions test/build workflow and contribution/diagnostics documentation. Hosted execution is pending the first repository run.

Recognition models are unchanged. This release does not establish accuracy or latency parity with commercial products.
