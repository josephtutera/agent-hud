#if canImport(AppKit)
import AppKit

/// Whether an observed menu-bar appearance actually needs the glance redrawn.
///
/// Kept out of the app delegate, and tested, because getting it wrong is not a
/// cosmetic bug: it burns a core forever. Handing the status item a new image
/// makes AppKit re-resolve the button's `effectiveAppearance`, which fires the
/// very observer that asked for the redraw, which draws and hands over another
/// image. Nothing in that circle is slow enough to notice on its own, so it
/// simply runs flat out — measured at roughly a thousand rasterizations a
/// second, one whole CPU, from an idle menu bar with nothing on screen changing.
///
/// The break is to compare against what is already drawn rather than trusting
/// the notification. The glance takes exactly one thing from the bar's
/// appearance — whether its ink is near-white or near-black — so an observation
/// that resolves to the appearance already on screen has nothing to do, and the
/// redraw AppKit provoked stops there instead of provoking the next one.
///
/// This also quiets the appearance observer's ordinary chatter: it fires once or
/// twice a second on its own, without any image being set, and every one of
/// those used to cost a full render.
public enum GlanceRedraw {

    /// The only thing the glance takes from the menu bar's appearance.
    public static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// - Parameters:
    ///   - observedIsDark: the appearance the observer just saw.
    ///   - renderedIsDark: the appearance the glance currently on screen was
    ///     drawn for, or `nil` before anything has been drawn.
    public static func isNeeded(observedIsDark: Bool, renderedIsDark: Bool?) -> Bool {
        observedIsDark != renderedIsDark
    }
}
#endif
