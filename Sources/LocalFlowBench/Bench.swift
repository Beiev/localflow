import Foundation
import LocalFlowCore
import FluidAudio

@main
struct Bench {
    static func main() async {
        setbuf(stdout, nil)
        do {
            try AppPaths.create()
            let args = Array(CommandLine.arguments.dropFirst())
            switch args.first {
            case "install":
                for id in args.dropFirst() {
                    guard let model = ModelCatalog.packages.first(where: { $0.id == id }) else { throw LocalFlowError.message("Unknown model: \(id)") }
                    print("Installing \(model.title), \(model.bytes) bytes")
                    try await ModelInstaller().install(model) { fraction, _ in if fraction >= 1 { print("Verified") } }
                }
            case "transcribe":
                guard args.count >= 2 else { return }
                let engine = SpeechEngine(); let url = URL(fileURLWithPath: args[1])
                let session = RecordingSession(kind: .note)
                try AudioFiles.importFile(url, id: session.id)
                defer { try? FileManager.default.removeItem(at: AppPaths.audio(session.id)) }
                let started = Date()
                for part in try AudioFiles.parts(session.id) {
                    let samples = try AudioFiles.read(AppPaths.audio(session.id).appendingPathComponent(part.file), duration: part.duration)
                    let result = try await engine.recognize(samples)
                    print(result.text)
                    print("timed_words=\(result.words.count)")
                }
                print("elapsed_s=\(Date().timeIntervalSince(started)) cold_s=\(await engine.coldStartSeconds) footprint_mb=\(ProcessMetrics.footprintMB)")
                await engine.unload()
                print("after_unload_mb=\(ProcessMetrics.footprintMB)")
            case "pipeline":
                guard args.count >= 3 else { throw LocalFlowError.message("pipeline AUDIO OUTPUT.json") }
                let session = RecordingSession(kind: .dictation)
                let directory = AppPaths.audio(session.id)
                try AudioFiles.importFile(URL(fileURLWithPath: args[1]), id: session.id)
                defer { try? FileManager.default.removeItem(at: directory) }
                let store = try Store(url: directory.appendingPathComponent("benchmark.sqlite"))
                let speech = SpeechEngine(); let editor = TextEngine(); let start = Date()
                let transcript = try await SessionTranscriber(recognizer: speech, store: store).transcribe(session)
                let transcribed = Date()
                let edited = try await editor.edit(transcript.rawText, mode: .clean, dictionary: [])
                let delivered = TextSafety.deliveryText(original: transcript.rawText, edited: edited.text, requiresReview: edited.guarded, dictionary: [])
                let row: [String: Any] = ["duration": transcript.duration, "asr_s": transcribed.timeIntervalSince(start), "edit_s": Date().timeIntervalSince(transcribed), "raw": transcript.rawText, "edited": edited.text, "delivered": delivered, "guarded": edited.guarded, "footprint_mb": ProcessMetrics.footprintMB]
                try JSONSerialization.data(withJSONObject: row, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: args[2]), options: .atomic)
                print("duration=\(transcript.duration) delivered_characters=\(delivered.count) guarded=\(edited.guarded)")
                await speech.unload(); await editor.unload()
            case "edit-modes":
                let engine = TextEngine()
                let samples = [
                    "Эээ, нам нужно, нам нужно проверить Локэлфлоу. Бюджет 250000 рублей. Данные не отправляем в облако.",
                    "Сегодня как-то устал. А ещё придумал: хочу вести дневник. С утра был созвон, потом прогулка. Вернусь к дневнику: хочется короткие заметки, от первого лица. На прогулке стало легче."
                ]
                var rows: [[String: Any]] = []
                for mode: ProcessingMode in [.clean, .compose] {
                    for input in samples {
                        let start = Date()
                        let result = try await engine.edit(input, mode: mode, dictionary: [.init(heard: "Локэлфлоу", preferred: "LocalFlow")], style: "Сохраняй личный тон, без канцелярита.")
                        rows.append(["mode": mode.rawValue, "input": input, "output": result.text, "requires_review": result.guarded, "elapsed_s": Date().timeIntervalSince(start)])
                    }
                }
                let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
                if args.count > 1 { try data.write(to: URL(fileURLWithPath: args[1]), options: .atomic) }
                print(String(decoding: data, as: UTF8.self))
                await engine.unload()
            case "edit":
                let engine = TextEngine(); let start = Date()
                let text = args.dropFirst().joined(separator: " ")
                let result = try await engine.edit(text, mode: .clean, dictionary: [])
                print(result.text); if result.guarded { print("proposals=\(result.proposals)") }; print("guarded=\(result.guarded) elapsed_s=\(Date().timeIntervalSince(start)) footprint_mb=\(ProcessMetrics.footprintMB)")
                await engine.unload(); print("after_unload_mb=\(ProcessMetrics.footprintMB)")
            case "summarize":
                // Re-summarizes an archive entry with the current code and reports the numbers,
                // without writing anything back: the "after" for a run that was already recorded.
                guard args.count >= 2 else { throw LocalFlowError.message("summarize SESSION_PREFIX [OUTPUT.json]") }
                let wanted = args[1].lowercased()
                let store = try Store(url: AppPaths.root.appendingPathComponent("archive.sqlite"))
                guard let session = try store.sessions().first(where: { $0.id.uuidString.lowercased().hasPrefix(wanted) }) else {
                    throw LocalFlowError.message("No session starts with \(args[1])")
                }
                var regrouped = session
                regrouped.segments = TranscriptAssembly.group(session.segments)
                let source = regrouped.referencedText
                let speechCharacters = session.segments.reduce(0) { $0 + $1.text.count }
                let previous = session.versions.last(where: { $0.mode == .summary })?.text.count ?? 0
                let engine = TextEngine()
                let start = Date()
                let result = try await engine.edit(source, mode: .summary, dictionary: try store.dictionary())
                let elapsed = Date().timeIntervalSince(start)
                var row: [String: Any] = [:]
                row["session"] = session.id.uuidString
                row["duration_s"] = session.duration
                row["segments_before"] = session.segments.count
                row["turns_after"] = regrouped.segments.count
                row["speech_characters"] = speechCharacters
                row["referenced_characters"] = source.count
                // Report the split the condensing path actually uses, not the editing default.
                row["chunks"] = TextSafety.chunks(source, maxCharacters: EditPlan.condensingChunkCharacters).count
                row["model_calls"] = result.proposals.count
                row["previous_summary_characters"] = previous
                row["summary_characters"] = result.text.count
                row["summary_share_of_speech"] = Double(result.text.count) / Double(max(1, speechCharacters))
                row["cited_times"] = result.text.ranges(of: try Regex("\\[\\d{2,}:\\d{2}\\]")).count
                row["cited_times_all_exist"] = TextSafety.citedTimesExist(in: result.text, source: source)
                row["elapsed_s"] = elapsed
                row["footprint_mb"] = ProcessMetrics.footprintMB
                // Numbers only. The transcript and the summary are the owner's private material;
                // benchmark files live in a public repository, so the text goes to stdout instead.
                let summaryData = try JSONSerialization.data(withJSONObject: row, options: [.prettyPrinted, .sortedKeys])
                if args.count > 2 { try summaryData.write(to: URL(fileURLWithPath: args[2]), options: .atomic) }
                print("segments_before=\(session.segments.count) turns_after=\(regrouped.segments.count)")
                print("speech_characters=\(speechCharacters) referenced=\(source.count) chunks=\(TextSafety.chunks(source, maxCharacters: EditPlan.condensingChunkCharacters).count) model_calls=\(result.proposals.count)")
                print("previous_summary=\(previous) summary=\(result.text.count) share=\(Double(result.text.count) / Double(max(1, speechCharacters)))")
                print("cited_times_all_exist=\(TextSafety.citedTimesExist(in: result.text, source: source)) elapsed_s=\(elapsed) footprint_mb=\(ProcessMetrics.footprintMB)")
                print("--- summary ---"); print(result.text)
                await engine.unload()
            case "diarize":
                // Re-runs speaker separation over an archive entry's system track and reports the
                // identity map, without writing anything back.
                guard args.count >= 2 else { throw LocalFlowError.message("diarize SESSION_PREFIX [OUTPUT.json]") }
                let target = args[1].lowercased()
                let archive = try Store(url: AppPaths.root.appendingPathComponent("archive.sqlite"))
                guard let stored = try archive.sessions().first(where: { $0.id.uuidString.lowercased().hasPrefix(target) }) else {
                    throw LocalFlowError.message("No session starts with \(args[1])")
                }
                let recording = stored.id
                let track = try await Task.detached { try AudioFiles.joinedTrack(recording, source: "system") }.value
                defer { try? FileManager.default.removeItem(at: track) }
                var input = stored
                input.segments = TranscriptAssembly.group(stored.segments)
                let began = Date()
                let annotated = try await SpeakerEngine().annotate(input, audio: track, profiles: try archive.voices())
                func census(_ session: RecordingSession) -> [String: Int] {
                    var counts: [String: Int] = [:]
                    for segment in session.segments where segment.source == "system" { counts[segment.speaker ?? "—"] = (counts[segment.speaker ?? "—"] ?? 0) + 1 }
                    return counts
                }
                var report: [String: Any] = [:]
                report["session"] = stored.id.uuidString
                report["identities_before"] = stored.embeddings.keys.sorted()
                report["identities_after"] = annotated.embeddings.keys.sorted()
                report["system_segments_before"] = census(stored)
                report["system_turns_after"] = census(annotated)
                report["elapsed_s"] = Date().timeIntervalSince(began)
                report["footprint_mb"] = ProcessMetrics.footprintMB
                let reportData = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                if args.count > 2 { try reportData.write(to: URL(fileURLWithPath: args[2]), options: .atomic) }
                print(String(decoding: reportData, as: UTF8.self))
            case "batch":
                guard args.count > 2 else { throw LocalFlowError.message("batch MANIFEST OUTPUT") }
                let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
                let cases = try JSONDecoder().decode([EvaluationCase].self, from: data)
                let engine = SpeechEngine(); var results: [EvaluationResult] = []
                for item in cases {
                    let temp = RecordingSession(kind: .note)
                    try AudioFiles.importFile(URL(fileURLWithPath: item.audio), id: temp.id)
                    let started = Date(); var texts: [String] = []; var updates: [Double] = []
                    for part in try AudioFiles.parts(temp.id) {
                        let samples = try AudioFiles.read(AppPaths.audio(temp.id).appendingPathComponent(part.file), duration: part.duration)
                        texts.append(try await engine.transcribe(samples))
                        // Replay prefixes from one to eight seconds to measure actual partial inference cost.
                        if item.id == "ru-01" {
                            for seconds in 1...min(8, Int(part.duration)) {
                                let before = Date()
                                _ = try await engine.transcribe(Array(samples.prefix(seconds * 16000)))
                                updates.append(Date().timeIntervalSince(before))
                            }
                        }
                    }
                    let output = texts.joined(separator: " ")
                    results.append(EvaluationResult(id: item.id, reference: item.text, actual: output, seconds: Date().timeIntervalSince(started), footprintMB: ProcessMetrics.footprintMB, partialSeconds: updates))
                    print("\(item.id): \(output)")
                    try? FileManager.default.removeItem(at: AppPaths.audio(temp.id))
                }
                try JSONEncoder().encode(results).write(to: URL(fileURLWithPath: args[2]), options: .atomic)
                print("cold_s=\(await engine.coldStartSeconds) footprint_mb=\(ProcessMetrics.footprintMB)")
                await engine.scheduleUnload(after: 1)
                try await Task.sleep(for: .seconds(2))
                print("auto_unloaded=\(!(await engine.isLoaded)) after_unload_mb=\(ProcessMetrics.footprintMB)")
            case "storage":
                // Accelerated two-hour PCM stress test. This does not simulate a real call.
                let id = UUID(); let root = AppPaths.audio(id)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                var parts: [AudioPart] = []; var peak = ProcessMetrics.footprintMB
                let baseline = peak; let start = Date()
                for index in 0..<240 {
                    let filename = "part-\(index).caf"
                    try AudioFiles.write(Array(repeating: Float(index % 10) / 10, count: 30 * 16000), url: root.appendingPathComponent(filename))
                    parts.append(AudioPart(file: filename, source: "microphone", start: Double(index * 30), duration: 30))
                    peak = max(peak, ProcessMetrics.footprintMB)
                }
                try JSONEncoder().encode(parts).write(to: root.appendingPathComponent("parts.json"))
                let joined = try AudioFiles.joinedTrack(id, source: "microphone")
                let tail = try AudioFiles.read(joined, from: 7199, duration: 1)
                guard tail.count == 16000, abs((tail.first ?? 0) - 0.9) < 0.001 else { throw LocalFlowError.message("Storage tail mismatch") }
                peak = max(peak, ProcessMetrics.footprintMB)
                print("duration_s=7200 parts=240 tail_verified=true elapsed_s=\(Date().timeIntervalSince(start)) baseline_mb=\(baseline) peak_mb=\(peak)")
            case "voices":
                guard args.count > 2 else { throw LocalFlowError.message("voices FIRST SECOND") }
                let engine = SpeakerEngine()
                let first = try await engine.annotate(RecordingSession(kind: .meeting), audio: URL(fileURLWithPath: args[1]), profiles: [])
                let names = ["Milena", "Daniel", "Thomas", "Anna"]
                guard first.embeddings.count == names.count else { throw LocalFlowError.message("First fixture speaker count mismatch") }
                let profiles = zip(first.embeddings.keys.sorted(), names).map { VoiceProfile(name: $0.1, embedding: first.embeddings[$0.0]!) }
                let second = try await engine.annotate(RecordingSession(kind: .meeting), audio: URL(fileURLWithPath: args[2]), profiles: profiles)
                let matched = second.embeddings.keys.sorted().map { second.speakers[$0] ?? "unknown" }
                print("matched=\(matched)")
                guard matched == ["Anna", "Milena", "Daniel", "Thomas"] else { throw LocalFlowError.message("Voice profile reorder mismatch") }
                var manual = RecordingSession(kind: .meeting); manual.speakers["S1"] = "Ручное имя"
                let preserved = try await engine.annotate(manual, audio: URL(fileURLWithPath: args[2]), profiles: profiles)
                guard preserved.speakers["S1"] == "Ручное имя" else { throw LocalFlowError.message("Manual speaker name overwritten") }
                print("reorder_verified=true manual_name_preserved=true")
            case "diarize":
                guard args.count > 1 else { return }
                ModelHub.offlineMode = true
                let start = Date()
                var config = OfflineDiarizerConfig.default
                if args.count > 2, let count = Int(args[2]), count > 0 { config = config.withSpeakers(exactly: count) }
                if args.count > 3, let threshold = Double(args[3]) { config.clustering.threshold = threshold }
                let manager = OfflineDiarizerManager(config: config)
                manager.initialize(models: try await OfflineDiarizerModels.load(from: AppPaths.models))
                let result = try await manager.process(URL(fileURLWithPath: args[1]))
                let spans = result.segments.map { ["speaker": $0.speakerId, "start": $0.startTimeSeconds, "end": $0.endTimeSeconds] as [String: Any] }
                let json = try JSONSerialization.data(withJSONObject: spans, options: [.sortedKeys])
                print("spans=" + String(decoding: json, as: UTF8.self))
                print("speakers=\(result.speakerDatabase?.count ?? 0) elapsed_s=\(Date().timeIntervalSince(start)) footprint_mb=\(ProcessMetrics.footprintMB)")
            default: print("LocalFlowBench install [asr8 editor editor-qwen speakers] | transcribe FILE | edit TEXT | diarize FILE")
            }
        } catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
    }
}

struct EvaluationCase: Decodable { let id: String; let text: String; let audio: String }
struct EvaluationResult: Codable { let id: String; let reference: String; let actual: String; let seconds: Double; let footprintMB: Double; let partialSeconds: [Double] }
