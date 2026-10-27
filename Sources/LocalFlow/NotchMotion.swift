import Foundation

/// A critically damped motion retains both position and velocity on reversal.
/// Core Animation receives samples of this curve; SwiftUI never relayouts per frame.
struct NotchMotion {
    struct Sample { var position: Double; var velocity: Double }
    static let duration: Double = 0.72
    private(set) var target: Double = 0
    private var initial = Sample(position: 0, velocity: 0)
    private var startedAt: Double = 0
    private var frequency: Double = 14
    private var duration = Self.duration

    func sample(at time: Double) -> Sample {
        let t = max(0, time - startedAt)
        guard t < duration else { return Sample(position: target, velocity: 0) }
        let displacement = initial.position - target
        let coefficient = initial.velocity + frequency * displacement
        let decay = exp(-frequency * t)
        let position = target + (displacement + coefficient * t) * decay
        let velocity = (coefficient - frequency * (displacement + coefficient * t)) * decay
        if position < 0 { return Sample(position: 0, velocity: max(0, velocity)) }
        if position > 1 { return Sample(position: 1, velocity: min(0, velocity)) }
        return Sample(position: position, velocity: velocity)
    }
    mutating func move(to target: Double, at time: Double, duration: Double = Self.duration) {
        initial = sample(at: time)
        self.target = target; startedAt = time
        self.duration = duration; frequency = 14 * Self.duration / duration
    }
}

/// Idempotent commands and revision-checked completion prevent a previous close
/// from ordering out a newly opened panel. Repeated close never restarts its timer.
struct OverlayVisibility {
    private(set) var isVisible = false
    private(set) var revision: UInt = 0
    mutating func request(_ visible: Bool) -> UInt? {
        guard visible != isVisible else { return nil }
        isVisible = visible; revision &+= 1
        return revision
    }
    func canFinishHiding(revision: UInt) -> Bool { !isVisible && self.revision == revision }
}
