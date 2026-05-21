import Foundation

/// Wall-clock scheduling for gas-leak phase sampling.
/// Config `duration_seconds` is the span from the first sample (t=0) to the last scheduled sample (t=duration).
/// Config `interval_seconds` is the logical spacing between sample timestamps.
enum GasLeakPhaseTiming {
    static let preferredBleSettle: TimeInterval = 0.6
    static let minBleSettle: TimeInterval = 0.05
    static let retryExtra: TimeInterval = 0.2

    static func clampedInterval(_ intervalSeconds: Double) -> TimeInterval {
        TimeInterval(max(0.1, min(3.0, intervalSeconds)))
    }

    /// Logical sample times from 0 through `durationSeconds` inclusive, stepped by `intervalSeconds`.
    static func sampleTimes(durationSeconds: Int, intervalSeconds: Double) -> [TimeInterval] {
        let duration = TimeInterval(max(0, durationSeconds))
        let step = clampedInterval(intervalSeconds)
        guard duration > 0 else { return [0] }
        var times: [TimeInterval] = []
        var t: TimeInterval = 0
        while t <= duration + 1e-9 {
            times.append(t)
            t += step
        }
        return times.isEmpty ? [0] : times
    }

    /// Sleep until wall-clock reaches `phaseStart + targetT` (no-op for t=0).
    static func waitUntil(phaseStart: Date, targetT: TimeInterval) async {
        guard targetT > 0 else { return }
        let delay = phaseStart.addingTimeInterval(targetT).timeIntervalSinceNow
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    /// BLE settle time that must not push past `deadline` (next sample or phase end).
    static func bleSettleSeconds(until deadline: Date) -> TimeInterval {
        let remaining = deadline.timeIntervalSinceNow
        if remaining <= 0 { return minBleSettle }
        return min(preferredBleSettle, max(minBleSettle, remaining))
    }

    static func canRetry(until deadline: Date) -> Bool {
        deadline.timeIntervalSinceNow > retryExtra
    }

    /// Deadline for BLE work after sampling at `sampleT` within a phase of length `durationSeconds`.
    static func bleDeadline(
        phaseStart: Date,
        sampleT: TimeInterval,
        nextSampleT: TimeInterval?,
        durationSeconds: Int
    ) -> Date {
        if let next = nextSampleT {
            return phaseStart.addingTimeInterval(next)
        }
        return phaseStart.addingTimeInterval(TimeInterval(max(0, durationSeconds)))
    }
}
