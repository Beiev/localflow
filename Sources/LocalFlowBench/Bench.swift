import Foundation
import LocalFlowCore

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
                    let result = try await engine.recognize(samples, compact: args.contains("--compact"))
                    print(result.text)
                    print("timed_words=\(result.words.count)")
                }
                print("elapsed_s=\(Date().timeIntervalSince(started)) cold_s=\(await engine.coldStartSeconds) footprint_mb=\(ProcessMetrics.footprintMB)")
                await engine.unload()
                print("after_unload_mb=\(ProcessMetrics.footprintMB)")
            case "edit":
                let engine = TextEngine(); let start = Date()
                let text = args.dropFirst().joined(separator: " ")
                let result = try await engine.edit(text, mode: .clean, dictionary: [])
                print(result.text); if result.guarded { print("proposals=\(result.proposals)") }; print("guarded=\(result.guarded) elapsed_s=\(Date().timeIntervalSince(start)) footprint_mb=\(ProcessMetrics.footprintMB)")
                await engine.unload(); print("after_unload_mb=\(ProcessMetrics.footprintMB)")
            case "batch":
                guard args.count > 2 else { throw LocalFlowError.message("batch MANIFEST OUTPUT [--compact]") }
                let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
                let cases = try JSONDecoder().decode([EvaluationCase].self, from: data)
                let engine = SpeechEngine(); var results: [EvaluationResult] = []
                for item in cases {
                    let temp = RecordingSession(kind: .note)
                    try AudioFiles.importFile(URL(fileURLWithPath: item.audio), id: temp.id)
                    let started = Date(); var texts: [String] = []; var updates: [Double] = []
                    for part in try AudioFiles.parts(temp.id) {
                        let samples = try AudioFiles.read(AppPaths.audio(temp.id).appendingPathComponent(part.file), duration: part.duration)
                        texts.append(try await engine.transcribe(samples, compact: args.contains("--compact")))
                        // Replay prefixes from one to eight seconds to measure actual partial inference cost.
                        if item.id == "ru-01" {
                            for seconds in 1...min(8, Int(part.duration)) {
                                let before = Date()
                                _ = try await engine.transcribe(Array(samples.prefix(seconds * 16000)), compact: args.contains("--compact"))
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
            case "diarize":
                guard args.count > 1 else { return }
                let start = Date(); var session = RecordingSession(kind: .meeting)
                if args.count > 2 { session.expectedRemoteSpeakers = Int(args[2]) }
                let result = try await SpeakerEngine().annotate(session, audio: URL(fileURLWithPath: args[1]), profiles: [])
                print("speakers=\(result.embeddings.count) elapsed_s=\(Date().timeIntervalSince(start)) footprint_mb=\(ProcessMetrics.footprintMB)")
            default: print("LocalFlowBench install asr8 asr4 editor speakers | transcribe FILE [--compact] | edit TEXT | diarize FILE")
            }
        } catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
    }
}

struct EvaluationCase: Decodable { let id: String; let text: String; let audio: String }
struct EvaluationResult: Codable { let id: String; let reference: String; let actual: String; let seconds: Double; let footprintMB: Double; let partialSeconds: [Double] }
