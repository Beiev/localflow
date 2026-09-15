import Foundation
import Darwin

/// Local timing metadata only: no text, audio, target app or clipboard contents.
/// Durations use system uptime, so changing the wall clock cannot skew the result.
public struct DictationMetrics: Codable, Sendable {
    public var appVersion: String
    public var editorID: String?
    public var speechWasLoaded: Bool
    public var editorWasLoaded: Bool
    public var transcriptionSeconds: Double = 0
    public var editingSeconds: Double = 0
    public var stopToReadySeconds: Double = 0
    public var stopToPasteSeconds: Double?
    public var pasteSucceeded: Bool?
    public var usedFallback = false
    public var reviewIssues: [EditIssue] = []
    public init(appVersion: String, editorID: String?, speechWasLoaded: Bool, editorWasLoaded: Bool) {
        self.appVersion = appVersion; self.editorID = editorID
        self.speechWasLoaded = speechWasLoaded; self.editorWasLoaded = editorWasLoaded
    }
    public var warm: Bool { speechWasLoaded && (editorID == nil || editorWasLoaded) }
}

public struct LatencyDistribution: Codable, Sendable {
    public var count: Int
    public var p50: Double?
    public var p95: Double?
    /// Nearest-rank percentiles; empty cohorts stay absent instead of reporting zero latency.
    public init(_ values: [Double]) {
        let sorted = values.filter { $0.isFinite && $0 >= 0 }.sorted()
        count = sorted.count
        func percentile(_ fraction: Double) -> Double? {
            sorted.isEmpty ? nil : sorted[max(0, Int(ceil(Double(sorted.count) * fraction)) - 1)]
        }
        p50 = percentile(0.5); p95 = percentile(0.95)
    }
}

public struct DictationReport: Codable, Sendable {
    public var measured: Int
    public var insertionFailures: Int
    public var fallbacks: Int
    public var stopToReady: LatencyDistribution
    public var stopToPasteWarm: LatencyDistribution
    public var stopToPasteCold: LatencyDistribution
    public init(_ metrics: [DictationMetrics]) {
        measured = metrics.count
        insertionFailures = metrics.filter { $0.pasteSucceeded == false }.count
        fallbacks = metrics.filter(\.usedFallback).count
        stopToReady = LatencyDistribution(metrics.map(\.stopToReadySeconds))
        stopToPasteWarm = LatencyDistribution(metrics.filter { $0.warm && $0.pasteSucceeded == true }.compactMap(\.stopToPasteSeconds))
        stopToPasteCold = LatencyDistribution(metrics.filter { !$0.warm && $0.pasteSucceeded == true }.compactMap(\.stopToPasteSeconds))
    }
}

public enum ProcessMetrics {
    public static var footprintMB: Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return status == KERN_SUCCESS ? Double(info.phys_footprint) / 1048576 : 0
    }
}
