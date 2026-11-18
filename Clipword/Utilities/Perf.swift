import Foundation
import OSLog

/// Performance instrumentation. Signpost intervals show up as lanes in
/// Instruments ("os_signpost" template) and inline in Time Profiler traces —
/// that's the flame-graph view for this app. Durations also go to the unified
/// log (`log stream --predicate 'subsystem == "com.clipword.app"'`) and to
/// stdout when launched via run.sh.
enum Perf {
    static let log = Logger(subsystem: "com.clipword.app", category: "perf")
    private static let intervals = OSSignposter(
        subsystem: "com.clipword.app",
        category: "intervals"
    )
    private static let pointsOfInterest = OSSignposter(
        subsystem: "com.clipword.app",
        category: .pointsOfInterest
    )

    /// Interval around a synchronous block. Cheap enough for the hot path
    /// (~100ns when tracing is off) — keep names static.
    @discardableResult
    static func measure<T>(_ name: StaticString, _ work: () throws -> T) rethrows -> T {
        let state = intervals.beginInterval(name)
        defer { intervals.endInterval(name, state) }
        return try work()
    }

    static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        intervals.beginInterval(name)
    }

    static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        intervals.endInterval(name, state)
    }

    /// Single point in Instruments' Points of Interest lane (shows even in
    /// lightweight Time Profiler recordings).
    static func event(_ name: StaticString) {
        pointsOfInterest.emitEvent(name)
    }

    /// Point event with context — e.g. `Perf.event("palette.move", "delta=1")`.
    static func event(_ name: StaticString, _ message: String) {
        pointsOfInterest.emitEvent(name, "\(message, privacy: .public)")
    }

    /// Measure and also record the duration to the unified log at debug level.
    @discardableResult
    static func timed<T>(_ name: StaticString, _ work: () throws -> T) rethrows -> T {
        let state = intervals.beginInterval(name)
        let started = ContinuousClock.now
        defer {
            intervals.endInterval(name, state)
            let ms = (ContinuousClock.now - started).milliseconds
            log.debug("\(name, privacy: .public): \(ms, format: .fixed(precision: 2))ms")
        }
        return try work()
    }
}

/// Lap-style stopwatch for the self-test report: `mark()` accumulates named
/// segments, `report()` renders a table of milliseconds.
struct PerfTimer {
    private var last = ContinuousClock.now
    private(set) var laps: [(name: String, milliseconds: Double)] = []

    mutating func mark(_ name: String) {
        let now = ContinuousClock.now
        laps.append((name, (last.duration(to: now)).milliseconds))
        last = now
    }

    func report() -> String {
        laps.map { name, ms in
            "  \(name.padding(toLength: 40, withPad: ".", startingAt: 0)) \(String(format: "%8.2f", ms)) ms"
        }.joined(separator: "\n")
    }
}

private extension Duration {
    var milliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}
