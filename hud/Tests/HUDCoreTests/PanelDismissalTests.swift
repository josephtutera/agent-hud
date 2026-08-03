import XCTest
#if canImport(AppKit)
import AppKit
#endif
@testable import HUDCore

/// When a click should collapse the open card.
///
/// The naive version — "any mouse-down closes it" — breaks in three ways, and
/// each one is a case below. Two of them close the card when the user was trying
/// to use it; the third closes it and lets the status item reopen it in the same
/// gesture, so the click looks like it did nothing at all.
#if canImport(AppKit)
final class PanelDismissalTests: XCTestCase {

    private func makeWindow() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                 styleMask: [.borderless], backing: .buffered, defer: true)
    }

    func testAClickInAnotherAppDismisses() {
        // The case this exists for. A nil window means the click landed outside
        // this process entirely, or on the desktop.
        XCTAssertTrue(PanelDismissal.shouldDismiss(
            clickedWindow: nil, panel: makeWindow(), statusItemWindow: makeWindow()
        ))
    }

    func testAClickInSomeOtherWindowOfThisAppDismisses() {
        XCTAssertTrue(PanelDismissal.shouldDismiss(
            clickedWindow: makeWindow(), panel: makeWindow(), statusItemWindow: makeWindow()
        ))
    }

    func testAClickInsideTheCardKeepsItOpen() {
        // Otherwise the copy button would dismiss the card as you pressed it.
        let panel = makeWindow()
        XCTAssertFalse(PanelDismissal.shouldDismiss(
            clickedWindow: panel, panel: panel, statusItemWindow: makeWindow()
        ))
    }

    func testAClickInAWindowTheCardOwnsKeepsItOpen() {
        // A menu or popover opened from the card is its own window, parented to
        // the panel. Closing the card the moment you reach for one would make it
        // unusable, and this is the failure that only shows up later.
        let panel = makeWindow()
        let child = makeWindow()
        panel.addChildWindow(child, ordered: .above)
        XCTAssertFalse(PanelDismissal.shouldDismiss(
            clickedWindow: child, panel: panel, statusItemWindow: makeWindow()
        ))
    }

    func testAClickOnTheStatusItemIsLeftToTheToggle() {
        // The status item already closes an open card. Dismissing here as well
        // would hide it first, and the toggle would then see a hidden panel and
        // reopen it, so the click would appear to do nothing.
        let statusItemWindow = makeWindow()
        XCTAssertFalse(PanelDismissal.shouldDismiss(
            clickedWindow: statusItemWindow, panel: makeWindow(), statusItemWindow: statusItemWindow
        ))
    }

    func testAMissingStatusItemWindowDoesNotStopDismissal() {
        // The status item has no window until it is on screen. That must not turn
        // into "nothing ever dismisses the card".
        XCTAssertTrue(PanelDismissal.shouldDismiss(
            clickedWindow: makeWindow(), panel: makeWindow(), statusItemWindow: nil
        ))
    }
}
#endif
