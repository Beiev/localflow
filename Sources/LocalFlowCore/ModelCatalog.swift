import Foundation
import CryptoKit

public struct ModelAsset: Codable, Sendable {
    public var path: String
    public var size: Int64
    public var hash: String
    public var sha256: Bool
}
public struct ModelPackage: Codable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var repo: String
    public var revision: String
    public var folder: String
    public var files: [ModelAsset]
    public var bytes: Int64 { files.reduce(0) { $0 + $1.size } }
    public var directory: URL { AppPaths.models.appendingPathComponent(folder) }
    public var installed: Bool {
        files.allSatisfy { f in (try? directory.appendingPathComponent(f.path).resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(f.size) } && FileManager.default.fileExists(atPath: directory.appendingPathComponent(".verified-\(id)-\(revision)").path)
    }
}
public enum ModelCatalog {
    public static let packages: [ModelPackage] = {
        guard let url = Bundle.module.url(forResource: "models", withExtension: "json"), let data = try? Data(contentsOf: url), let models = try? JSONDecoder().decode([ModelPackage].self, from: data) else { return [] }
        return models
    }()
    public static func package(_ id: String) -> ModelPackage { packages.first { $0.id == id }! }
}
public actor ModelInstaller {
    private static let gate = AsyncGate()
    public init() {}
    public func install(_ model: ModelPackage, progress: @escaping @Sendable (Double, String) -> Void) async throws {
        await Self.gate.acquire()
        do { try Task.checkCancellation(); try await performInstall(model, progress: progress); await Self.gate.release() }
        catch { await Self.gate.release(); throw error }
    }
    private func performInstall(_ model: ModelPackage, progress: @escaping @Sendable (Double, String) -> Void) async throws {
        let capacity = try AppPaths.models.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
        let missing = model.files.filter { (try? model.directory.appendingPathComponent($0.path).resourceValues(forKeys: [.fileSizeKey]).fileSize) != Int($0.size) }.reduce(Int64(0)) { $0 + $1.size }
        guard capacity > missing + 1_000_000_000 else { throw LocalFlowError.message("Для моделей недостаточно места. Нужно ещё \(ByteCountFormatter.string(fromByteCount: missing + 1_000_000_000, countStyle: .file)).") }
        var complete: Int64 = 0
        for asset in model.files {
            try Task.checkCancellation()
            let destination = model.directory.appendingPathComponent(asset.path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if Self.valid(destination, asset: asset) { complete += asset.size; progress(Double(complete)/Double(model.bytes), asset.path); continue }
            let base = complete
            let remote = URL(string: "https://huggingface.co/\(model.repo)/resolve/\(model.revision)/\(asset.path)")!
            let transfer = FileTransfer(destination: destination)
            try await transfer.download(remote) { count in progress(Double(base + count) / Double(model.bytes), asset.path) }
            guard Self.valid(destination, asset: asset) else {
                try? FileManager.default.removeItem(at: destination)
                throw LocalFlowError.message("Проверка модели не пройдена: \(asset.path). Повторите загрузку.")
            }
            complete += asset.size
        }
        try Data(model.revision.utf8).write(to: model.directory.appendingPathComponent(".verified-\(model.id)-\(model.revision)"), options: .atomic)
        progress(1, "Готово")
    }
    private static func valid(_ url: URL, asset: ModelAsset) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url), (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(asset.size) else { return false }
        defer { try? handle.close() }
        do {
            if asset.sha256 {
                var hash = SHA256()
                while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
                return hash.finalize().map { String(format: "%02x", $0) }.joined() == asset.hash
            } else {
                var hash = Insecure.SHA1(); hash.update(data: Data("blob \(asset.size)\0".utf8))
                while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
                return hash.finalize().map { String(format: "%02x", $0) }.joined() == asset.hash
            }
        } catch { return false }
    }
}
private final class FileTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    var resumeURL: URL { destination.appendingPathExtension("resume") }
    private var continuation: CheckedContinuation<Void, Error>?
    private var progress: (@Sendable (Int64) -> Void)?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var fileError: Error?
    private let taskLock = NSLock()
    private var cancelled = false
    init(destination: URL) { self.destination = destination }
    func download(_ url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        self.progress = progress
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 7200
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                self.session = session
                self.taskLock.lock()
                if let data = try? Data(contentsOf: resumeURL) { task = session.downloadTask(withResumeData: data) }
                else { task = session.downloadTask(with: url) }
                let wasCancelled = cancelled
                let created = task
                self.taskLock.unlock()
                if wasCancelled { created?.cancel() } else { created?.resume() }
            }
        } onCancel: {
            self.taskLock.lock(); self.cancelled = true; let task = self.task; self.taskLock.unlock()
            task?.cancel(byProducingResumeData: { data in if let data { try? data.write(to: self.resumeURL, options: .atomic) } })
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) { progress?(totalBytesWritten) }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 || response.statusCode == 206 else { throw LocalFlowError.message("Сервер загрузки вернул ошибку") }
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: location, to: destination)
            try? FileManager.default.removeItem(at: resumeURL)
        } catch { fileError = error }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error as NSError?, let data = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data { try? data.write(to: resumeURL, options: .atomic) }
        if let error = fileError ?? error { continuation?.resume(throwing: error) } else { continuation?.resume() }
        continuation = nil; session.finishTasksAndInvalidate(); self.session = nil
    }
}
