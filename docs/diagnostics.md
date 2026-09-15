# Local diagnostics and reproducible latency measurements

The commands below process data on the Mac. The new `diagnostics` and `latency` JSON reports contain counts, durations and model/build identifiers, without speech, session titles, recording paths or session identifiers. Older benchmark commands have different output formats; do not assume their reports are safe to publish.

Build the harness:

```sh
xcodegen generate
xcodebuild -project LocalFlow.xcodeproj -scheme LocalFlowBench -configuration Release -derivedDataPath build.noindex -clonedSourcePackagesDirPath .build -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation -skipMacroValidation build
```

## Archive audit

```sh
build.noindex/Build/Products/Release/LocalFlowBench diagnostics /tmp/localflow-diagnostics.json
```

This opens SQLite read-only, without migrating or rewriting sessions. It checks the last editing proposal for each dictation using the **current** dictionary. Historical dictionary and prompt settings may differ. `proposals_flagged_now` is a deterministic audit, not a count of human-confirmed errors. It cannot determine whether the speaker intended an ASR word or a model paraphrase.

Issue codes: `empty`, `numbers`, `correction`, `negation`, `negationScope`, `truncated`, `expanded`. Counts can overlap. An ambiguous single separator (`1,500` or `1.500`) is preserved verbatim; explicit decimal/grouping formats such as `1,500.25` and `1.500,25` can be normalized. This may conservatively reject legitimate formatting when the spoken language is unknown.

The regular dictation flow records local metadata from the stop command to the ready text and to the insertion routine returning success. This includes pending capture/live recognition work, final ASR, editing, archive writes and insertion. The successful-insertion metric is the application's acknowledgment, not independent verification that every target app accepted every character. A failed insertion is counted separately, never treated as a successful fast result.

Reports group timings by app version and editor. Warm means the recognizer and selected editor were loaded at the start of final processing; it does not describe their state when recording began. Dictation inside a meeting and manual archive reprocessing are not included. Old sessions have no timings and are omitted. Empty cohorts have count zero and absent percentiles, not fabricated zero-second latency. Percentiles use nearest rank; small samples do not establish a service-level guarantee.

## Audio replay

```sh
build.noindex/Build/Products/Release/LocalFlowBench latency /path/to/fixture.wav 5 /tmp/localflow-latency.json
```

Install the recognizer and selected editor first. One run starts with unloaded models; subsequent runs reuse the same instances. Audio is imported once into a temporary session and removed on completion; the real archive is not opened. Timed work is final ASR with checkpoint writes and editing, using clean mode and an empty personal dictionary. Capture, live transcription, final application save, UI, paste and clipboard restoration are excluded. The report explicitly identifies this as `audio_replay_without_capture_or_paste`.

Use the same audio and model on both builds. Measure speech error rate against a manually corrected reference separately; faster processing alone says nothing about accuracy.

## Archive migration and recovery

Schema 2 adds an index on creation time and identity. Fresh archives run steps 1 and 2; schema 1 archives run step 2. Before upgrading an existing database, LocalFlow creates `Backups/archive-v1-<random>.sqlite` next to the archive using [SQLite VACUUM INTO](https://www.sqlite.org/lang_vacuum.html#vacuuminto), which captures a consistent snapshot including committed WAL data. Backups contain private archive content and are never uploaded automatically. Audio and model weights are separate and are not included.

An unsupported newer schema fails with an actionable error instead of rewriting the version. Failed migration rolls back; the backup stays available. To restore manually, quit every LocalFlow process, preserve the current database **and its `-wal`/`-shm` companions**, and restore a chosen backup as `archive.sqlite` with no stale companions left at that destination. Never replace an open database. Old pre-migration binaries do not have the newer-schema protection; downgrading those against a migrated archive is unsupported.

The UI still loads all sessions. Pagination and direct session lookup now exist in the storage API; moving the UI to lightweight pages remains separate work.
