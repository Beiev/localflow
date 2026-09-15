# Changelog

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
