#if canImport(AppKit)
import AppKit

/// When a mouse-down should collapse the open card.
///
/// Kept out of the app delegate so the rule is testable, because it is easier to
/// get subtly wrong than it looks: two of the three cases below close the card
/// when they should not, and one of them closes it and immediately reopens it,
/// which reads as the click having done nothing at all.
public enum PanelDismissal {

    /// - Parameters:
    ///   - clickedWindow: the window the click landed in. `nil` means it landed
    ///     in another application, or on the desktop.
    ///   - panel: the open card.
    ///   - statusItemWindow: the window hosting the menu-bar item, if any.
    public static func shouldDismiss(
        clickedWindow: NSWindow?,
        panel: NSWindow,
        statusItemWindow: NSWindow?
    ) -> Bool {
        // Another app, or the desktop. This is the case the whole thing is for.
        guard let clickedWindow else { return true }

        // Inside the card, or inside something the card put on screen — a menu or
        // a popover is its own window whose parent is the panel, and closing the
        // card the moment you reach for one would make it unusable.
        if isDescendant(clickedWindow, of: panel) { return false }

        // The status item toggles the card itself. Closing it here as well would
        // leave the toggle looking at a hidden panel and reopening it, so the
        // click would appear to do nothing.
        if let statusItemWindow, clickedWindow === statusItemWindow { return false }

        return true
    }

    private static func isDescendant(_ window: NSWindow, of ancestor: NSWindow) -> Bool {
        var current: NSWindow? = window
        while let candidate = current {
            if candidate === ancestor { return true }
            current = candidate.parent
        }
        return false
    }
}
#endif
