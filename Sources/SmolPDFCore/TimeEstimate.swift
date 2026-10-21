import Foundation

/// Estimates how long a run has left from how fast its progress grew so far, and decides when that is
/// worth showing: only for runs projected to take longer than `threshold`.
public struct TimeEstimate: Sendable {
    public let start: Date
    public let threshold: TimeInterval
    /// Seconds left, once the whole run is projected to take longer than `threshold`. From then on it
    /// stays available, so that a display of it doesn't come and go.
    public private(set) var remaining: TimeInterval?

    private var smoothed: TimeInterval?
    private var updated: Date?

    public init(start: Date = .now, threshold: TimeInterval = 10) {
        self.start = start
        self.threshold = threshold
    }

    /// Takes the fraction done (0...1) at `now`.
    public mutating func update(fraction: Double, at now: Date = .now) {
        let elapsed = now.timeIntervalSince(start)
        // Progress is lumpy at first; wait until there is something to go by.
        guard fraction > 0.01, elapsed >= 1 else { return }
        let fraction = min(fraction, 1)
        let left = elapsed * (1 - fraction) / fraction
        // Smooth over a couple of seconds, so that the estimate doesn't jump with every image: the last
        // estimate, counted down since, moves towards the new one.
        var estimate = left
        if fraction < 1, let smoothed, let updated {
            let interval = max(0, now.timeIntervalSince(updated))
            let counted = smoothed - interval
            estimate = counted + (left - counted) * (1 - exp(-interval / 2))
        }
        smoothed = estimate
        updated = now
        if remaining != nil || elapsed + left > threshold {
            remaining = max(0, estimate)
        }
    }
}
