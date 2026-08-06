import XCTest
#if canImport(AppKit)
import AppKit
#endif
@testable import HUDCore

/// When an appearance change means the glance has to be drawn again.
///
/// The case that matters is the second one. Handing the status item a new image
/// makes AppKit re-resolve the button's `effectiveAppearance`, which fires the
/// observer that asked for the image in the first place. Redraw on that and the
/// app rasterizes the glance about a thousand times a second, forever, on an
/// idle menu bar — a whole CPU spent drawing a picture that never changes. So
/// the rule is not "the appearance was notified", it is "the appearance differs
/// from what is on screen", and the test below is the thing standing between
/// this app and that loop coming back.
#if canImport(AppKit)
final class GlanceRedrawTests: XCTestCase {

    func testTheFirstDrawAlwaysHappens() {
        // Nothing on screen yet, so whatever the bar's appearance is, it needs
        // drawing for.
        XCTAssertTrue(GlanceRedraw.isNeeded(observedIsDark: true, renderedIsDark: nil))
        XCTAssertFalse(GlanceRedraw.isNeeded(observedIsDark: false, renderedIsDark: false))
    }

    func testTheSameAppearanceDoesNotRedraw() {
        // The loop-breaker. This is the notification AppKit sends back to us
        // because we just set an image, and answering it with another image is
        // what runs the CPU flat out.
        XCTAssertFalse(GlanceRedraw.isNeeded(observedIsDark: true, renderedIsDark: true))
        XCTAssertFalse(GlanceRedraw.isNeeded(observedIsDark: false, renderedIsDark: false))
    }

    func testFlippingLightOrDarkRedraws() {
        // The reason the observer exists: the glance draws its own ink, so it
        // would stay near-white on a bar that has just turned light.
        XCTAssertTrue(GlanceRedraw.isNeeded(observedIsDark: false, renderedIsDark: true))
        XCTAssertTrue(GlanceRedraw.isNeeded(observedIsDark: true, renderedIsDark: false))
    }

    func testAFlipSettlesAfterOneRedraw() {
        // A real flip draws once and then has to stop, because that draw sets an
        // image and provokes one more notification. Walking the two steps here
        // is what proves the guard terminates rather than merely being quieter.
        var renderedIsDark: Bool?
        let observedIsDark = true

        XCTAssertTrue(GlanceRedraw.isNeeded(observedIsDark: observedIsDark, renderedIsDark: renderedIsDark))
        renderedIsDark = observedIsDark  // the redraw happened

        XCTAssertFalse(
            GlanceRedraw.isNeeded(observedIsDark: observedIsDark, renderedIsDark: renderedIsDark),
            "the notification caused by setting the image must not cause another render"
        )
    }

    func testTheMenuBarAppearancesResolve() {
        // The glance's whole appearance question is this one bit, so a change to
        // how it is resolved should fail here rather than in the menu bar.
        XCTAssertTrue(GlanceRedraw.isDark(NSAppearance(named: .darkAqua)!))
        XCTAssertFalse(GlanceRedraw.isDark(NSAppearance(named: .aqua)!))
        XCTAssertTrue(GlanceRedraw.isDark(NSAppearance(named: .vibrantDark)!))
        XCTAssertFalse(GlanceRedraw.isDark(NSAppearance(named: .vibrantLight)!))
    }
}
#endif
