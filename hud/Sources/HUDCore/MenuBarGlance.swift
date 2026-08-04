import SwiftUI

/// The menu-bar status-item content: one concentric ring cluster per
/// subscription, and a single dot when the agent setup has problems.
///
/// There is deliberately no countdown. The only one that fits here is the
/// soonest reset across every plan, which is a single number that does not say
/// which plan it belongs to — and the card, a click away, gives each plan its
/// own reset and its own 5-hour clock.
///
/// Each ring is a fuel gauge for one window — the arc is how much is left — and
/// is coloured by severity, so a plan running dry shrinks and turns amber and
/// then red without you having to read a number. That colour is the reason this is **not** rendered as a
/// template image: a template throws its pixels away and takes AppKit's tint,
/// which is what keeps a monochrome icon legible over any wallpaper but would
/// also flatten green, amber and red into one shade. So the glance draws in real
/// colour, and everything that is *not* severity resolves against the menu bar's
/// own appearance instead, which is what `ink` carries — see AppDelegate, which
/// re-renders whenever that appearance changes.
public struct MenuBarContentView: View {
    public let snapshot: HUDSnapshot?
    public var now: Date
    /// The menu bar's own foreground colour, resolved from its current
    /// appearance: near-white on a dark bar, near-black on a light one. Used for
    /// the ring tracks and the offline dashes, never for a reading.
    public var ink: Color

    public init(snapshot: HUDSnapshot?, now: Date = Date(), ink: Color = .primary) {
        self.snapshot = snapshot
        self.now = now
        self.ink = ink
    }

    private var orderedSubs: [Subscription] {
        snapshot?.orderedSubscriptions ?? []
    }

    public var body: some View {
        HStack(spacing: 7) {
            if !orderedSubs.isEmpty {
                ForEach(orderedSubs) { sub in
                    RingCluster(
                        rings: sub.glanceRings,
                        diameter: 20,
                        strokeWidth: 1.6,
                        track: ink.opacity(0.28)
                    )
                }
            } else {
                ForEach(0..<3, id: \.self) { _ in
                    Text("–")
                        .font(Theme.mono(13, weight: .semibold))
                        .foregroundStyle(ink.opacity(0.35))
                }
            }
            if showsSetupDot {
                // One dot, and nothing at all when the setup is clean. The menu
                // bar is where you are not looking, so it may say "come look" and
                // nothing more; the count and the detail are one click away. A
                // setup the daemon could not check shows nothing either: an
                // unanswered question is not worth a permanent mark.
                Circle()
                    .fill(Theme.amber)
                    .frame(width: 5, height: 5)
                    .accessibilityLabel("agent setup has problems")
            }
        }
        .padding(.horizontal, 5)
        .frame(height: 22)
    }

    /// True only for real problems. A setup the daemon could not check shows
    /// nothing: an unanswered question is not worth a permanent mark, and a dot
    /// that is always there trains the eye to stop seeing it.
    public var showsSetupDot: Bool {
        guard let setup = snapshot?.setup else { return false }
        return !setup.isClean
    }
}
