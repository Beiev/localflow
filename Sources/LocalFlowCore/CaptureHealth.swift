import Foundation

/// Measures sample delivery, not loudness: digital silence is a healthy input.
/// Recovery is bounded so an unavailable device cannot leave a pretend recording running.
public struct CaptureHealth: Sendable {
    public static let maximumRecoveries = 2
    public private(set) var receivedAudio = false
    public private(set) var recoveries = 0
    private var lastAudio: Double
    public init(now: Double = 0) { lastAudio = now }
    public mutating func didReceiveAudio(at now: Double) {
        receivedAudio = true; lastAudio = now
    }
    public func isStalled(at now: Double) -> Bool { now - lastAudio >= 2.5 }
    public mutating func beginRecovery(at now: Double) -> Bool {
        guard recoveries < Self.maximumRecoveries else { return false }
        recoveries += 1; receivedAudio = false; lastAudio = now
        return true
    }
}
