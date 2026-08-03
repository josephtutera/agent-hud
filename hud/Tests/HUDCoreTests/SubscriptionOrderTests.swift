import XCTest
@testable import HUDCore

/// Presentation order and the `trees` field.
///
/// The card and the menu-bar glance used to pick subscriptions out of the
/// snapshot by a hardcoded list of ids (`claude-team`, `claude-personal`,
/// `codex`). Ids now come from whichever organizations the machine is signed
/// into, so anything not on that list rendered nowhere at all. These pin the
/// replacement: order by provider, take whatever the daemon sent.
final class SubscriptionOrderTests: XCTestCase {

    private func sub(_ id: String, provider: String, trees: [String] = []) -> Subscription {
        Subscription(id: id, provider: provider, label: id, trees: trees,
                     windows: [], tightest: nil, stale: nil, activeAgents: 0)
    }

    private func snapshot(_ subs: [Subscription]) -> HUDSnapshot {
        HUDSnapshot(version: 1, generatedAt: nil, subscriptions: subs,
                    agents: [], value: nil, soonestReset: nil)
    }

    func testClaudePlansComeFirstThenCodex() {
        let snap = snapshot([sub("codex", provider: "codex"),
                             sub("claude-max", provider: "claude"),
                             sub("claude-team", provider: "claude")])
        XCTAssertEqual(snap.orderedSubscriptions.map(\.id), ["claude-max", "claude-team", "codex"])
    }

    func testAnUnfamiliarIdIsStillRendered() {
        // The regression: an id no hardcoded list knew about used to vanish.
        let snap = snapshot([sub("claude-enterprise-acme", provider: "claude"),
                             sub("codex", provider: "codex")])
        XCTAssertEqual(snap.orderedSubscriptions.count, 2)
        XCTAssertEqual(snap.orderedSubscriptions.first?.id, "claude-enterprise-acme")
    }

    func testDaemonOrderIsPreservedWithinAProvider() {
        let snap = snapshot([sub("claude-team", provider: "claude"),
                             sub("claude-max", provider: "claude")])
        XCTAssertEqual(snap.orderedSubscriptions.map(\.id), ["claude-team", "claude-max"])
    }

    // MARK: - trees

    func testTreesDecodeAndSurviveCollapse() throws {
        let json = """
        {"version": 1, "generated_at": null, "subscriptions": [
          {"id": "claude-team", "provider": "claude", "label": "Claude Team",
           "trees": ["~/.claude", "~/.claude-work"], "windows": [],
           "tightest": null, "stale": null, "active_agents": 0}],
         "agents": [], "value": null, "soonest_reset": null}
        """
        let snap = try HUDSnapshot.decode(from: Data(json.utf8))
        XCTAssertEqual(snap.subscriptions.first?.trees, ["~/.claude", "~/.claude-work"])
    }

    func testASnapshotWithoutTreesStillDecodes() throws {
        // A daemon predating the organization work writes no `trees` key. The
        // app must read that snapshot rather than showing nothing at all.
        let json = """
        {"version": 1, "generated_at": null, "subscriptions": [
          {"id": "claude-team", "provider": "claude", "label": "Claude Team",
           "windows": [], "tightest": null, "stale": null, "active_agents": 0}],
         "agents": [], "value": null, "soonest_reset": null}
        """
        let snap = try HUDSnapshot.decode(from: Data(json.utf8))
        XCTAssertEqual(snap.subscriptions.first?.trees, [])
    }
}
