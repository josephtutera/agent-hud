import XCTest
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
@testable import HUDCore

/// Light mode is wiring, not palette design: every semantic token is already a
/// `dynamic(light:dark:)` pair. What breaks it is someone adding a token as a
/// plain hex, which looks right on whichever card they happened to be looking
/// at and wrong on the other. These resolve each token against both appearances
/// and insist the two differ, so that mistake fails the build rather than
/// shipping.
final class ThemeAppearanceTests: XCTestCase {

    /// Every token that carries meaning. Pure geometry (a hairline that happens
    /// to look similar) is still listed: nothing here is allowed to be fixed.
    private static let tokens: [(String, Color)] = [
        ("notch", Theme.notch),
        ("panel", Theme.panel),
        ("panel2", Theme.panel2),
        ("hairline", Theme.hairline),
        ("text", Theme.text),
        ("muted", Theme.muted),
        ("faint", Theme.faint),
        ("amber", Theme.amber),
        ("green", Theme.green),
        ("red", Theme.red),
        ("warnSurface", Theme.warnSurface),
        ("warnBorder", Theme.warnBorder),
        ("chip", Theme.chip),
        ("chipBorder", Theme.chipBorder),
        ("claudeCoral", Theme.claudeCoral),
        ("codexGreen", Theme.codexGreen),
        ("agentDot", Theme.agentDot),
    ]

    #if canImport(AppKit)
    private func resolve(_ color: Color, _ appearance: NSAppearance.Name) -> NSColor? {
        var resolved: NSColor?
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB)
        }
        return resolved
    }

    func testEverySemanticTokenAdaptsToTheAppearance() throws {
        for (name, color) in Self.tokens {
            let light = try XCTUnwrap(resolve(color, .aqua), "\(name) did not resolve in Aqua")
            let dark = try XCTUnwrap(resolve(color, .darkAqua), "\(name) did not resolve in Dark Aqua")
            XCTAssertNotEqual(
                light, dark,
                "\(name) is the same color in both appearances — it was probably "
                + "written as a fixed hex instead of Theme.dynamic(light:dark:)"
            )
        }
    }

    /// WCAG relative luminance. HSB `brightnessComponent` is not this: a
    /// saturated red scores 0.85 there while reading as dark, so measuring
    /// contrast with it would pass a palette nobody can read.
    private func luminance(_ color: NSColor) -> CGFloat {
        func channel(_ c: CGFloat) -> CGFloat {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.redComponent)
            + 0.7152 * channel(color.greenComponent)
            + 0.0722 * channel(color.blueComponent)
    }

    private func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    func testTheLightCardIsInkOnWhiteAndTheDarkOneTheOtherWayAround() throws {
        let lightPanel = try XCTUnwrap(resolve(Theme.panel, .aqua))
        let darkPanel = try XCTUnwrap(resolve(Theme.panel, .darkAqua))
        let lightText = try XCTUnwrap(resolve(Theme.text, .aqua))
        let darkText = try XCTUnwrap(resolve(Theme.text, .darkAqua))
        // Not just "different": the light card has to actually be the light one.
        XCTAssertGreaterThan(luminance(lightPanel), luminance(darkPanel))
        XCTAssertLessThan(luminance(lightText), luminance(darkText))
    }

    /// Every colour that carries a reading has to clear 3:1 against the card it
    /// sits on — WCAG's bar for graphical objects and large text. The dark
    /// palette came first, so this is really a check on the light values, which
    /// were derived from it rather than designed against white.
    func testEveryReadingColorClearsThreeToOneOnBothCards() throws {
        let readingTokens: [(String, Color)] = [
            ("text", Theme.text), ("muted", Theme.muted), ("faint", Theme.faint),
            ("amber", Theme.amber), ("green", Theme.green), ("red", Theme.red),
            ("claudeCoral", Theme.claudeCoral), ("codexGreen", Theme.codexGreen),
            ("agentDot", Theme.agentDot),
        ]
        for (appearanceName, appearance) in [("light", NSAppearance.Name.aqua),
                                             ("dark", NSAppearance.Name.darkAqua)] {
            let panel = try XCTUnwrap(resolve(Theme.panel, appearance))
            for (name, color) in readingTokens {
                let resolved = try XCTUnwrap(resolve(color, appearance))
                XCTAssertGreaterThanOrEqual(
                    contrast(resolved, panel), 3.0,
                    "\(name) is \(String(format: "%.2f", contrast(resolved, panel))):1 on the "
                    + "\(appearanceName) card — too low to read a value in"
                )
            }
        }
    }

    /// A problem row draws amber text on its own washed surface, not on the
    /// card, so that pairing is checked where it actually happens.
    func testAProblemRowIsReadableOnItsOwnSurface() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let surface = try XCTUnwrap(resolve(Theme.warnSurface, appearance))
            let amber = try XCTUnwrap(resolve(Theme.amber, appearance))
            let text = try XCTUnwrap(resolve(Theme.text, appearance))
            XCTAssertGreaterThanOrEqual(contrast(amber, surface), 3.0)
            XCTAssertGreaterThanOrEqual(contrast(text, surface), 4.5)
        }
    }

    /// And a copyable command draws on the chip, which is the inverse surface of
    /// the card it sits on in each appearance.
    func testACommandChipIsReadable() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let chip = try XCTUnwrap(resolve(Theme.chip, appearance))
            let text = try XCTUnwrap(resolve(Theme.text, appearance))
            XCTAssertGreaterThanOrEqual(contrast(text, chip), 4.5)
        }
    }
    #endif

    func testSeverityMapsToTheSameTokensInEitherAppearance() {
        // The mapping is appearance-independent; only the token's value moves.
        XCTAssertEqual(Theme.severity(pctLeft: 0), Theme.red)
        XCTAssertEqual(Theme.severity(pctLeft: 24), Theme.amber)
        XCTAssertEqual(Theme.severity(pctLeft: 25), Theme.green)
        XCTAssertEqual(Theme.severity(pctLeft: nil), Theme.hairline)
    }
}
