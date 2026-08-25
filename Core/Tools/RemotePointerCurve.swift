import Foundation

struct RemotePointerCurve: Sendable, Equatable {
    /// Vamp-aligned: ≥1× when slow (precise), up to ~2.5× when fast.
    var minimumGain: Double = 1.0
    var maximumGain: Double = 2.5
    /// Matches Vamp `1.0 + min(speed / 50, 1.5)` knee.
    var velocityScale: Double = 50
    var smoothing: Double = 0.35

    private(set) var filteredVelocity: Double = 0

    mutating func apply(dx: Double, dy: Double, elapsed: TimeInterval) -> (dx: Double, dy: Double) {
        guard dx.isFinite, dy.isFinite else { return (0, 0) }
        let distance = hypot(dx, dy)
        guard distance > 0 else { return (0, 0) }
        let safeElapsed = elapsed.isFinite && elapsed > 0.0001 ? min(elapsed, 0.25) : 1.0 / 60.0
        let velocity = distance / safeElapsed
        let alpha = min(max(smoothing, 0), 1)
        filteredVelocity += (velocity - filteredVelocity) * alpha
        let scale = max(velocityScale, 0.001)
        let low = min(minimumGain, maximumGain)
        let high = max(minimumGain, maximumGain)
        let gain = low + (high - low) * (1 - exp(-filteredVelocity / scale))
        return (dx * gain, dy * gain)
    }

    mutating func reset() {
        filteredVelocity = 0
    }
}
