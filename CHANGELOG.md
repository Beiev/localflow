# Changelog

## 0.4.1 — 2026-10-26

- Read a meeting as topics rather than as four lists. A fourth stage groups the assertions that survived into the stretches of conversation they came from — contiguous, by time and by shared wording — and the model is allowed one thing it is good at: naming a group it is shown, in two to four words. Each topic is rendered as a passage assembled in code, what was settled first and then what was measured, every sentence carrying the moment it came from. A group the model fails to name is headed by when it happened. One topic means the whole conversation, so the document stays as it was.
- Keep the tabs and the copy button in reach. They scrolled away with the text, so switching from the summary to the transcript on a long meeting meant scrolling back to the top first. Hold the text to a readable column while there: a meeting was running the full width of the window.
- Add the follow-up letter: the meeting as a message to the people who were in it — topics, the task table as lines, and what nobody answered — assembled from the document that already exists, without citations and without a model call. In the copy menu.
- Drop a question somebody answered. "Открытые вопросы" was listing everything the model labelled a question, including the ones answered two turns later.
- Spread a section's cap over the recording. Most decisions weigh the same, equal weights were broken by who spoke first, and a long call therefore kept twelve decisions from its opening stretch and none of the ones it ended on. Where the cap still has to choose, it now also counts how much of the room's time went to each point.

### Found by a second model's review of 0.4.0, and fixed

- Stop merging a correction into what it corrected. Word overlap cannot see a figure, and "не" is a stop word, so "лимит десять тысяч" and "лимит двадцать тысяч" — and "решили запускать" and "решили не запускать" — read as the same point, and merging kept the earlier one. Two assertions are now the same point only if they carry the same figures and the same polarity.
- Stop handing a task's owner and deadline to a different task. The index of a merged twin is an index into the kept list, and a line too short to carry a signature was kept without one, after which the two lists were out of step.
- Let nothing read off a screen become a decision or a task. A board reading "Утвердили перенос" is not a decision the meeting took. An observation citing a screen moment is still allowed, and screen text now reaches the model with the prompt's own markers neutralised, so a window containing `</экран>` cannot close the block it was placed in. At most three moments of screen per window: twenty-eight of them came to 36 898 characters, at which point the instructions are what falls out of the context.
- Match a task's owner whole instead of by prefix. A task for Александр went to Александра, "Яна" resolved to the microphone track's own "Я", and "Соб" resolved to "Собеседник" — the label the guard exists to refuse.
- Stop a price from becoming a task. "Тариф стоит двадцать долларов" has an intention marker in it and, because Russian numerals end the way infinitives do, an apparent action as well.
- Read a line the model wrapped in pipes. `| ФАКТ | … | u1 |` has an empty first field and cost the window every record it found.
- Give a slide left alone the time it was actually up. Only a changed frame is journalled, so a slide nobody touched produced a moment that ended where it began, invisible to every stretch of conversation that happened while it was on screen.
- Order recognised text by band rather than by distance. "Within 0.01 counts as the same line" is not a strict weak ordering, and a staggered table came out scrambled.
- Do not wait for recognition when pausing. Pause ran on the screen queue, where a frame is recognised, and the caller is the main thread.
- Keep a damaged screen journal. One byte lost to a power cut made the strict decoder return nothing, throwing away the whole journal rather than the one line it damaged.
- Say what the screen feature reads: the whole display minus LocalFlow's own windows, not only the call's window. Copying a whole meeting now carries the window titles and the times, never the text read off them.

## 0.4.0 — 2026-10-26

- Read the shared screen during a meeting, off by default. A second output on the ScreenCaptureKit stream that already carries system audio, with its own queue so recognition never sits in front of an audio buffer: one frame every three seconds, reduced to a 16×16 thumbnail, and only a frame that differs from the last one *read* is recognized. What is kept is the text and the window title — never video, never the frames. The app's own windows are excluded from the picture, the capture pauses with the recording, and the journal is removed with the session's audio.
- Attach what was shown to the analysis. Screen moments carry their own identifiers (`s3`) in the condensing material, so an assertion can cite a document that was on screen exactly as it cites a sentence that was said, and the clock comes from the moment. Screen text is passed to the model as data, with an explicit instruction not to act on it. A meeting with screen capture gains a "Что показывали" section and a screen tab listing the moments.

- Condense a meeting in three stages instead of one free-text pass. Turns get stable identifiers and the model is shown identifiers and speaker names but never a clock, so it cannot invent a timestamp or emit raw seconds; it returns typed assertions — fact, decision, task, question — from a few minutes of conversation at a time, each citing the turns it came from.
- Decide filing in code, not in the prompt. An assertion citing a turn outside the window it was shown is dropped as invented; one opening with "нужно" or "надо" becomes a task however the model labelled it; a task owner is accepted only when it matches a speaker the recording knows, so a diarizer label can no longer be handed work; paraphrases of one kind are merged by word overlap and keep the earlier citation, with the owner and deadline carried forward from the later mention.
- Assemble the opening paragraph in code from the assertions that survived, rather than asking the model for it. Asking was tried: the specificity check can tell a generic paragraph from a concrete one but not a coherent sentence from an incoherent one, and the accepted attempt on a real 45-minute call read "Срок, связанный с 4 позиции, показал…". All twelve openings in the archive failed the specificity check; the assembled one names the participants, the counts, the decisions, a figure and an unanswered question, and costs no model call.
- Give each kind of assertion its own quota per window. A single pooled ceiling starved the document: the ranking rewards a figure, decisions and questions rarely carry one, and a real 45-minute call came out with twelve figures, seven tasks and exactly one decision — the wrong one.
- Stop demoting a decision spoken as an obligation to a task: in Russian business speech the decision of a call is routinely said as "надо переносить запуск на следующую неделю". Facts phrased as intentions are still re-filed as tasks, and a task with nothing to do in it is now re-filed as a fact.
- Drop a task that only repeats a decision, unless it carries an owner or a deadline the decision does not.
- Catch repeats separated only by a Russian prefix. Word-overlap by Jaccard scored "нам нужно написать инструкцию для подрядчика" against "выглядит так, что нам надо переносить запуск на следующую неделю" at 0,45, because "ставить" and "поставить" stem differently; containment reads the same pair at 0,71.
- Order the figures section by a proper key. The first comparator asked only whether one entry had figures and the other did not, which is not a strict weak ordering, and Swift's sort scrambled the section.
- Omit sections the conversation did not fill, rather than padding them. Forced completeness is what made "Открытые вопросы" repeat the tasks.
- Render tasks as a table of owner, task and deadline, with "не назван" where nobody was named.
- Add `SummaryQuality`: deterministic proxies for the defects the owner pointed at — misfiled bullets, unusable citations (including `[134]`, a citation that came out as raw seconds), invented figures, paraphrased repeats, tasks with no real owner, and an opening that says nothing. Reported by `LocalFlowBench summary-quality` over the archive.
- Keep the previous single-pass path reachable as `EditPlan.SummaryStrategy.legacy` and add `LocalFlowBench summary-ab`, which runs both over the same prepared material so an architecture win can be told from a model win.
- Parse two summary shapes the archive already contains that the first parser missed: a section title with its first sentence on the same line (`**О чём** — …`), and a title followed by a bare dash. One 92-minute summary lost all five of its sections and all forty-one of its bullets to this.
- Never save an empty condensing result as a version: the summary tab showed a blank document where the mode had legitimately found nothing.

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
