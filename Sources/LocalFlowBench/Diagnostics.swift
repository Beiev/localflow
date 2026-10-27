import Foundation
import LocalFlowCore

extension Bench {
    static func writeReport(_ object: Any, output: String?) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        if let output { try data.write(to: URL(fileURLWithPath: output), options: .atomic) }
        print(String(decoding: data, as: UTF8.self))
    }
    /// No speech, titles, file paths or session identifiers in this report.
    static func diagnostics(output: String?) throws {
        let archive = try Store(readOnly: true)
        let dictionary = try archive.dictionary()
        var sessions = 0, evaluated = 0, guarded = 0, historicalFallbacks = 0
        var reasons: [String: Int] = [:]
        var cohorts: [String: [DictationMetrics]] = [:]
        var offset = 0
        while true {
            let page = try archive.sessions(limit: 100, offset: offset)
            if page.isEmpty { break }
            offset += page.count
            for session in page where session.kind == .dictation {
                sessions += 1
                if let timing = session.dictationMetrics {
                    let key = timing.appVersion + "/" + (timing.editorID ?? "no-editor")
                    cohorts[key, default: []].append(timing)
                }
                if session.versions.contains(where: { $0.label == "Минимальная очистка" }) { historicalFallbacks += 1 }
                guard let proposal = session.versions.last(where: { ($0.mode == .clean || $0.mode == .compose) && $0.label != "Минимальная очистка" }) else { continue }
                evaluated += 1
                let issues = TextSafety.editIssues(original: TextSafety.applyDictionary(session.rawText, entries: dictionary), edited: proposal.text)
                if !issues.isEmpty { guarded += 1 }
                for reason in issues { reasons[reason.rawValue, default: 0] += 1 }
            }
        }
        let encoder = JSONEncoder()
        var reports: [String: Any] = [:]
        for (key, values) in cohorts { reports[key] = try JSONSerialization.jsonObject(with: encoder.encode(DictationReport(values))) }
        try writeReport(["dictations": sessions, "historical_minimal_cleanup": historicalFallbacks,
            "proposals_checked_with_current_dictionary": evaluated, "proposals_flagged_now": guarded,
            "issue_counts": reasons, "latency_by_app_version_and_editor": reports], output: output)
    }
    /// Audio replay includes final ASR, editor and checkpoint writes, but never capture or paste.
    static func latency(audio: String, runs: Int, output: String?) async throws {
        guard (1...50).contains(runs) else { throw LocalFlowError.message("Runs must be between 1 and 50") }
        let session = RecordingSession(kind: .dictation)
        let directory = AppPaths.audio(session.id)
        defer { try? FileManager.default.removeItem(at: directory) }
        try AudioFiles.importFile(URL(fileURLWithPath: audio), id: session.id)
        let store = try Store(url: directory.appendingPathComponent("benchmark.sqlite"))
        let speech = SpeechEngine(), editor = TextEngine()
        var rows: [[String: Any]] = [], warm: [Double] = [], cold: [Double] = []
        for _ in 0..<runs {
            let speechLoaded = await speech.isLoaded
            let editorLoaded = await editor.isLoaded
            let loaded = speechLoaded && editorLoaded
            let start = ProcessInfo.processInfo.systemUptime
            let transcript = try await SessionTranscriber(recognizer: speech, store: store).transcribe(session)
            let transcribed = ProcessInfo.processInfo.systemUptime
            let edit = try await editor.edit(transcript.rawText, mode: .clean, dictionary: [])
            let ended = ProcessInfo.processInfo.systemUptime
            let elapsed = ended - start
            if loaded { warm.append(elapsed) } else { cold.append(elapsed) }
            rows.append(["warm": loaded, "audio_seconds": transcript.duration, "asr_seconds": transcribed - start,
                "edit_seconds": ended - transcribed, "processing_seconds": elapsed,
                "guarded": edit.guarded, "issues": edit.issues.map(\.rawValue),
                "delivered_characters": edit.delivery(original: transcript.rawText, dictionary: []).count])
        }
        await speech.unload(); await editor.unload()
        let encoder = JSONEncoder()
        try writeReport(["scope": "audio_replay_without_capture_or_paste", "editor": ModelCatalog.editorPackageID(),
            "warm_processing_seconds": try JSONSerialization.jsonObject(with: encoder.encode(LatencyDistribution(warm))),
            "cold_processing_seconds": try JSONSerialization.jsonObject(with: encoder.encode(LatencyDistribution(cold))),
            "runs": rows], output: output)
    }
}
