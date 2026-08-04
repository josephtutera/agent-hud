import SwiftUI

#if canImport(AppKit)
import AppKit
import UniformTypeIdentifiers

/// Renders the popover card with a fixed snapshot to a PNG at a given scale,
/// using SwiftUI's ImageRenderer. This is the evidence artifact reviewers look
/// at, and it doubles as a headless smoke test that the whole view tree lays
/// out without crashing.
@MainActor
public enum PreviewRenderer {

    public struct RenderError: Error, CustomStringConvertible {
        public let description: String
    }

    @discardableResult
    public static func renderCardPNG(
        snapshot: HUDSnapshot = .sample,
        now: Date = HUDSnapshot.previewNow,
        to url: URL,
        scale: CGFloat = 2,
        colorScheme: ColorScheme = .dark
    ) throws -> URL {
        // Resolve the dynamic Theme colors against the requested appearance, both
        // via the AppKit appearance (which backs the dynamic NSColors) and the
        // SwiftUI environment, so the render matches what the live app shows.
        #if canImport(AppKit)
        let previousAppearance = NSApplication.shared.appearance
        NSApplication.shared.appearance =
            NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        defer { NSApplication.shared.appearance = previousAppearance }
        #endif

        // A little breathing room around the card so the border isn't flush to
        // the image edge, over the appearance-appropriate desktop backdrop.
        let content = PopoverCard(snapshot: snapshot, now: now)
            .environment(\.colorScheme, colorScheme)
            .padding(20)
            .background(Theme.notch)
            .environment(\.colorScheme, colorScheme)

        return try write(content, to: url, scale: scale, opaque: true)
    }

    /// Renders the card on a day when nothing is wrong. Worth its own artifact
    /// because the all-clear is the state the panel is in almost always, and it
    /// is a different layout rather than the same one with fewer rows.
    @discardableResult
    public static func renderAllClearPNG(
        to url: URL,
        scale: CGFloat = 2,
        colorScheme: ColorScheme = .dark
    ) throws -> URL {
        try renderCardPNG(
            snapshot: .sampleAllClear,
            to: url,
            scale: scale,
            colorScheme: colorScheme
        )
    }

    /// Renders the menu-bar glance (status-item content) beside its dropdown
    /// card over a desktop-gray backdrop, so reviewers see both the collapsed
    /// glance and the click-through card in one image.
    @discardableResult
    public static func renderMenubarPNG(
        snapshot: HUDSnapshot = .sample,
        now: Date = HUDSnapshot.previewNow,
        to url: URL,
        scale: CGFloat = 2,
        colorScheme: ColorScheme = .dark
    ) throws -> URL {
        // Pin the appearance rather than inheriting the host machine's, so the
        // artifact is the same wherever it is generated.
        let isDark = colorScheme == .dark
        #if canImport(AppKit)
        let previousAppearance = NSApplication.shared.appearance
        NSApplication.shared.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        defer { NSApplication.shared.appearance = previousAppearance }
        #endif

        let content = VStack(alignment: .trailing, spacing: 24) {
            // The glance on a menu-bar strip, right-aligned like the real status
            // area. `ink` is what the app resolves from the bar's appearance:
            // near-white on a dark bar, near-black on a light one. The severity
            // colours do not move, which is the point of not being a template.
            HStack {
                Spacer()
                MenuBarContentView(snapshot: snapshot, now: now, ink: isDark ? .white : .black)
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Color(hex: isDark ? 0x26272C : 0xF2F2F4))

            PopoverCard(snapshot: snapshot, now: now)
        }
        .environment(\.colorScheme, colorScheme)
        .padding(40)
        .background(Color(hex: isDark ? 0x1C1D21 : 0xE9EAEE))

        return try write(content, to: url, scale: scale, opaque: true)
    }

    private static func write(
        _ content: some View,
        to url: URL,
        scale: CGFloat,
        opaque: Bool
    ) throws -> URL {
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        renderer.isOpaque = opaque

        guard let cgImage = renderer.cgImage else {
            throw RenderError(description: "ImageRenderer produced no image")
        }

        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw RenderError(description: "could not create PNG destination at \(url.path)")
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw RenderError(description: "could not finalize PNG at \(url.path)")
        }
        return url
    }
}
#endif
