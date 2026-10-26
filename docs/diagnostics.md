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

## Meeting quality: what is measured, and what the measurement is worth

```sh
build.noindex/Build/Products/Release/LocalFlowBench identities        # voice identities per meeting, before and after folding
build.noindex/Build/Products/Release/LocalFlowBench names             # names the recordings themselves offer
build.noindex/Build/Products/Release/LocalFlowBench summary-quality   # every stored summary, scored against its own transcript
build.noindex/Build/Products/Release/LocalFlowBench transcript <ID>   # line-by-line cleanup with the real editor
build.noindex/Build/Products/Release/LocalFlowBench summary-ab <ID>   # both condensing strategies over the same material
```

All five open SQLite read-only and write nothing back. `summary-quality` and `identities` print only counts and ratios. `names`, `transcript` and `summary-ab` print speech to stdout, because that is the only way to judge the result — the JSON reports they write contain numbers only, and stdout is not committed.

The scores are proxies, not quality. Read them with these limits in mind:

- **Section purity is circular for the structured strategy.** Filing is deterministic in code: a record whose text opens with an intention marker is routed to tasks regardless of the model's own label, and the purity metric checks that same marker list. The structured path therefore reads 1.00 by construction and the number carries no information about it. It still measures the legacy strategy and the documents already in the archive, where the model chose the section.
- **Citation validity is likewise near-circular now.** The structured strategy never lets the model write a clock reading; timestamps are attached in code from the cited turn, so an unresolvable citation is impossible unless the code is wrong. On the legacy strategy and on archived documents the metric is real, and it is what caught `[134]` — a citation emitted as raw seconds.
- **Number fidelity needed its own correction.** Figures were first counted over the whole transcript, including the `[мм:сс]` clock and labels such as `Участник 1`, so a summary that said "Участник 1" was credited with a figure the conversation contained. Figures are now counted over the speech only. This moved the archive baseline from 0.94 to 0.84, which means the earlier number was wrong, not that anything regressed.
- **Fidelity and coverage are different errors.** A document with no figures at all has perfect fidelity and no coverage; a capped extraction that drops the figures that mattered shows up only in coverage.
- **Redundancy, owner clarity and opening specificity are not circular** and are where the comparison carries weight. Owner clarity moves for two independent reasons — naming the voices, and refusing an owner the recording does not know — so attribute it carefully.

## Where screen reading keeps things, and how to be rid of it

Off unless switched on in Settings. While it is on, each recording gets `screen.jsonl` inside its
own folder under `Recordings/<session>/`, one JSON line per frame that was read: the time, the
application name, the window title and the recognized lines. No frames and no video are written at
any point — the thumbnail used to decide whether a frame changed lives in memory for the length of
one comparison. Deleting the recording deletes the folder and the journal with it; audio pruning
after thirty days removes it on the same schedule. The assembled moments are stored inside the
session row, so deleting the session removes those too.

To see what a recording captured without opening the application:

```sh
python3 -c 'import json,sys;[print(json.loads(l)["time"], json.loads(l).get("window"), sep="\t") for l in open(sys.argv[1]) if l.strip()]' \
  ~/Library/Application\ Support/LocalFlow/Recordings/<session>/screen.jsonl
```

Two limits worth knowing before relying on it. The capture takes the whole display, so a window
the owner did not mean to share is read if it is in front — pausing the recording pauses the
reading, and the application's own windows are the only ones excluded by construction. And text
recognition runs only in the languages this Mac reports as supported; if Russian is not among them
the journal simply stays empty rather than filling with nonsense.

## Сравнение весов редактора

`LOCALFLOW_EDITOR` подменяет вес для одного запуска и не трогает настройку приложения:

```bash
build.noindex/Build/Products/Release/LocalFlowBench install editor-qwen9
LOCALFLOW_EDITOR=editor-qwen9 build.noindex/Build/Products/Release/LocalFlowBench summary-ab SESSION_PREFIX out.json
```

Идентификаторы весов — `editor` (Gemma 4 E2B, по умолчанию) и `editor-qwen` (Qwen 4B). Кандидат должен быть в каталоге: строка для Qwen 3.5 9B лежит закомментированной в `Scripts/pin-models.py`, вместе с причиной, по которой он отклонён. Сравнивать нужно на одном и том же подготовленном материале: `summary-ab` сам сводит мелкие голоса и применяет предложенные имена, поэтому два запуска по одной записи сопоставимы.

Числа идут в файл, текст конспектов — в stdout. В stdout попадает настоящая речь: не коммитить.

## Прогон по всему архиву

```bash
build.noindex/Build/Products/Release/LocalFlowBench summary-sweep /tmp/localflow-sweep.json
```

Прогоняет через текущий конвейер каждый созвон архива, у которого есть реплики, и печатает по строке на созвон: сколько тем получилось, сработали ли защиты, сколько было вызовов модели, прокси-метрики и время. Это способ увидеть, как часто защиты срабатывают на настоящем материале, а не на двух созвонах, которые смотрят чаще всего.

`topics=0` означает, что тем не вышло и документ собран плоскими разделами: либо утверждений меньше четырёх, либо модель не выполнила инструкцию по группировке. Это штатное поведение, а не ошибка.

В stdout попадают названия тем — это содержание настоящих разговоров. Не выкладывать.

## Проверка MCP-сервера

```bash
printf '%s\n' \
 '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
 '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
 '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_recordings","arguments":{"limit":3}}}' \
 | ~/Applications/LocalFlow.app/Contents/MacOS/localflow-mcp
```

Сервер открывает архив только на чтение и работает одновременно с приложением. Ответы `list_recordings` и `search_recordings` содержат названия записей, `read_recording` и `find_moments` — их содержимое: это настоящие разговоры, и вывод этих команд никуда не выкладывается.

