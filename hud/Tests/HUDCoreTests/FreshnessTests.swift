import XCTest
@testable import HUDCore

/// Staying honest about how old the numbers are, and getting the daemon back
/// when it dies.
///
/// Both exist because the same failure is possible in two places: showing a
/// reading as if it were current when it is not. The daemon dying used to leave
/// the HUD offline until the app was relaunched; a Codex percentage from three
/// days ago used to be drawn exactly like one from three minutes ago.
final class FreshnessTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_785_000_000)

    private func sub(readAt: Date?) -> Subscription {
        Subscription(id: "codex", provider: "codex", label: "Codex Pro",
                     readAt: readAt, windows: [], tightest: nil, stale: nil, activeAgents: 0)
    }

    // MARK: - How old a reading is

    func testAFreshReadingSaysNothing() {
        // Claude is re-read every three minutes; saying so every time would be
        // noise, and noise is what stops the real case being noticed.
        XCTAssertNil(sub(readAt: now.addingTimeInterval(-60)).agedReading(now: now))
        XCTAssertNil(sub(readAt: now.addingTimeInterval(-9 * 60)).agedReading(now: now))
    }

    func testAnOldReadingIsSurfaced() {
        // Codex has no API to ask: its numbers come out of a rollout file written
        // as a side effect of a turn, so after a quiet day they are a day old. A
        // weekly window that has since reset makes them wrong, not merely late.
        let threeDaysAgo = now.addingTimeInterval(-3 * 86_400)
        XCTAssertEqual(sub(readAt: threeDaysAgo).agedReading(now: now), threeDaysAgo)
    }

    func testAReadingWithNoTimestampIsNotAccusedOfBeingOld() {
        // A snapshot from a daemon that predates the field. Unknown age is not
        // the same as fresh, but it is not evidence of staleness either.
        XCTAssertNil(sub(readAt: nil).agedReading(now: now))
    }

    func testTheAgeIsRenderedInPlainWords() {
        XCTAssertEqual(Fmt.ago(now.addingTimeInterval(-90 * 60), now: now), "1h ago")
        XCTAssertEqual(Fmt.ago(now.addingTimeInterval(-3 * 86_400), now: now), "3d ago")
    }

    func testAClockAheadOfUsReadsAsJustNowRatherThanNegative() {
        // The daemon stamps readings with its own clock. A little skew must not
        // produce "-4s ago".
        XCTAssertEqual(Fmt.ago(now.addingTimeInterval(30), now: now), "just now")
    }

    // MARK: - Getting the daemon back

    func testAHealthyDaemonIsNeverRestarted() {
        let s = DaemonSupervision()
        XCTAssertFalse(s.shouldAttempt(daemonUnreachable: false, daemonIsRunning: false, now: now))
    }

    func testAnOfflineHUDWithNoDaemonRetriesImmediatelyTheFirstTime() {
        let s = DaemonSupervision()
        XCTAssertTrue(s.shouldAttempt(daemonUnreachable: true, daemonIsRunning: false, now: now))
    }

    func testALiveButUnreachableDaemonIsLeftAlone() {
        // It is starting up, or wedged. A second one would only fight it for the
        // port, and then neither would answer.
        let s = DaemonSupervision()
        XCTAssertFalse(s.shouldAttempt(daemonUnreachable: true, daemonIsRunning: true, now: now))
    }

    func testRepeatedFailuresBackOffRatherThanSpawningEveryTick() {
        // The pathological case is a port held by something else: without this,
        // the supervisor starts a process every few seconds forever.
        var s = DaemonSupervision()
        s.recordAttempt(succeeded: false, now: now)
        XCTAssertEqual(s.currentDelay, DaemonSupervision.firstDelay)
        XCTAssertFalse(s.shouldAttempt(daemonUnreachable: true, daemonIsRunning: false,
                                       now: now.addingTimeInterval(5)))
        XCTAssertTrue(s.shouldAttempt(daemonUnreachable: true, daemonIsRunning: false,
                                      now: now.addingTimeInterval(DaemonSupervision.firstDelay)))

        s.recordAttempt(succeeded: false, now: now)
        XCTAssertEqual(s.currentDelay, DaemonSupervision.firstDelay * 2)
    }

    func testBackoffIsCapped() {
        var s = DaemonSupervision()
        for _ in 0..<20 { s.recordAttempt(succeeded: false, now: now) }
        XCTAssertEqual(s.currentDelay, DaemonSupervision.maxDelay)
    }

    func testASuccessClearsTheBackoff() {
        var s = DaemonSupervision()
        for _ in 0..<5 { s.recordAttempt(succeeded: false, now: now) }
        s.recordAttempt(succeeded: true, now: now)
        XCTAssertEqual(s.currentDelay, 0)
    }

    func testADaemonComingBackOnItsOwnAlsoClearsTheBackoff() {
        // The user may have started one by hand. The next outage should get a
        // fast retry rather than inheriting a five-minute wait.
        var s = DaemonSupervision()
        for _ in 0..<5 { s.recordAttempt(succeeded: false, now: now) }
        s.noteHealthy()
        XCTAssertTrue(s.shouldAttempt(daemonUnreachable: true, daemonIsRunning: false, now: now))
    }
}
