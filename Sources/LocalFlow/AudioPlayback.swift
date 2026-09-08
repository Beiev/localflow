import AVFoundation
import LocalFlowCore

/// Continues through the selected source's saved parts without loading a full recording.
@MainActor
final class AudioPlayback: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var queue: [(AudioPart, URL)] = []
    var onChange: ((Bool) -> Void)?
    var onError: ((String) -> Void)?
    var isPlaying: Bool { player?.isPlaying ?? false }
    func play(_ session: RecordingSession, at seconds: Double, source: String) throws {
        stop()
        let parts = try AudioFiles.parts(session.id).filter { $0.source == source }.sorted { $0.start < $1.start }
        guard let index = parts.firstIndex(where: { $0.start <= seconds && $0.start + $0.duration > seconds }) else {
            throw LocalFlowError.message("Аудио этого фрагмента уже удалено или недоступно")
        }
        queue = parts.dropFirst(index).map { ($0, AppPaths.audio(session.id).appendingPathComponent($0.file)) }
        try next(offset: max(0, seconds - parts[index].start))
    }
    private func next(offset: Double = 0) throws {
        guard !queue.isEmpty else { stop(); return }
        let (_, url) = queue.removeFirst()
        let value = try AVAudioPlayer(contentsOf: url)
        value.delegate = self; value.currentTime = offset
        player = value
        guard value.play() else { stop(); throw LocalFlowError.message("Не удалось начать воспроизведение") }
        onChange?(true)
    }
    func stop() { player?.stop(); player = nil; queue = []; onChange?(false) }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.player === player else { return }
            do { if flag { try self.next() } else { self.stop(); self.onError?("Воспроизведение прервано") } }
            catch { self.stop(); self.onError?(error.localizedDescription) }
        }
    }
}
