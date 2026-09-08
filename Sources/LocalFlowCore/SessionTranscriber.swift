import Foundation

public protocol SpeechRecognizing: Sendable {
    func recognize(_ samples: [Float]) async throws -> SpeechRecognition
}

/// Disk-backed transcription with checkpointed ownership of overlapping windows.
/// The audio source is immutable after capture has stopped.
public struct SessionTranscriber: Sendable {
    let recognizer: any SpeechRecognizing
    let store: Store
    public init(recognizer: any SpeechRecognizing, store: Store) {
        self.recognizer = recognizer; self.store = store
    }
    public func transcribe(_ session: RecordingSession, progress: @escaping @Sendable (Double, Double) -> Void = { _,_ in }) async throws -> RecordingSession {
        var result = session; result.state = "processing"; result.error = nil
        let parts = try AudioFiles.parts(session.id)
        if result.transcribedThrough == nil { result.segments = []; result.transcribedThrough = [:] }
        for source in Set(parts.map(\.source)).sorted() {
            try Task.checkCancellation()
            let id = session.id
            let url = try await Task.detached { try AudioFiles.joinedTrack(id, source: source) }.value
            defer { try? FileManager.default.removeItem(at: url) }
            let duration = parts.filter { $0.source == source }.map { $0.start + $0.duration }.max() ?? 0
            var center = result.transcribedThrough?[source] ?? 0
            while center < duration {
                try Task.checkCancellation()
                let windowStart = max(0, center - 1)
                let windowEnd = min(duration, center + 11)
                let samples = try AudioFiles.read(url, from: windowStart, duration: windowEnd - windowStart)
                guard !samples.isEmpty else {
                    throw LocalFlowError.message("Не удалось дочитать аудио. Исходник сохранён для восстановления.")
                }
                let recognition = try await recognizer.recognize(samples)
                try Task.checkCancellation()
                let boundaryEnd = min(duration, center + 10)
                if recognition.words.isEmpty && !recognition.text.isEmpty {
                    throw LocalFlowError.message("Модель не вернула временные отметки. Аудио сохранено для повторной обработки.")
                }
                let owned = TranscriptAssembly.windowWords(recognition.words, offset: windowStart, from: center, to: boundaryEnd == duration ? .infinity : boundaryEnd, source: source)
                result.segments.append(contentsOf: owned.map { value in
                    var word = value; word.speaker = source == "microphone" ? "Я" : nil; return word
                })
                center = boundaryEnd
                result.transcribedThrough?[source] = center
                result.duration = max(result.duration, duration)
                try store.save(result)
                progress(center, duration)
            }
        }
        return result
    }
}
