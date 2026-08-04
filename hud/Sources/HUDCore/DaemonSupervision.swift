import Foundation

/// When to try starting the snapshot daemon again.
///
/// The app starts the daemon once, at launch. If it then dies — crashed, killed,
/// wedged, or never came up because the machine was still waking — nothing
/// noticed, and the HUD showed its offline face until you quit and relaunched.
/// A supervisor fixes that, but a naive one has the opposite failure: if the port
/// is held by something else, or the daemon dies instantly every time, it spawns
/// a process every tick forever.
///
/// So retries back off: a short first gap, doubling to a cap, reset the moment a
/// daemon answers. Pure and clock-injectable so the schedule can be tested
/// without waiting real seconds for it.
public struct DaemonSupervision {
    /// How long to wait before the first retry after a failure.
    public static let firstDelay: TimeInterval = 15
    /// The longest gap between retries. Beyond this, a machine that is never
    /// going to run the daemon is only paying one process every few minutes.
    public static let maxDelay: TimeInterval = 300

    private var consecutiveFailures = 0
    private var lastAttempt: Date?

    public init() {}

    /// The gap required before the next attempt, given how many have failed.
    public var currentDelay: TimeInterval {
        guard consecutiveFailures > 0 else { return 0 }
        let doubled = Self.firstDelay * pow(2, Double(consecutiveFailures - 1))
        return min(doubled, Self.maxDelay)
    }

    /// Should the supervisor try to start a daemon right now?
    ///
    /// - Parameters:
    ///   - daemonUnreachable: whether the daemon failed to answer its last poll.
    ///     Deliberately not "the app has no data": a dead daemon still leaves a
    ///     readable cache file, so the card keeps showing numbers and would never
    ///     look offline while the process it came from was gone.
    ///   - daemonIsRunning: whether a daemon this app spawned is still alive. A
    ///     live-but-unreachable process is starting up or wedged; spawning a
    ///     second one would only make them fight over the port.
    ///   - now: injected so the schedule is testable.
    public func shouldAttempt(daemonUnreachable: Bool, daemonIsRunning: Bool, now: Date) -> Bool {
        guard daemonUnreachable, !daemonIsRunning else { return false }
        guard let lastAttempt else { return true }
        return now.timeIntervalSince(lastAttempt) >= currentDelay
    }

    /// Record an attempt. `succeeded` means a daemon is answering afterwards.
    public mutating func recordAttempt(succeeded: Bool, now: Date) {
        lastAttempt = now
        consecutiveFailures = succeeded ? 0 : consecutiveFailures + 1
    }

    /// Reset once a daemon is answering again, however it got there — the user
    /// may have started one by hand, and the next outage should get a fast retry
    /// rather than inheriting the old backoff.
    public mutating func noteHealthy() {
        consecutiveFailures = 0
        lastAttempt = nil
    }
}
