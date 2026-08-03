import SwiftUI

/// One concentric ring cluster, outermost ring first.
///
/// Each ring reads as a fuel gauge: the arc is how much of that window is
/// *left*, so a healthy plan is a full ring and a burnt one is nearly bare. That
/// matches the fuel bars in the pods and on the meter rows, which fill the same
/// way — the alternative, filling by what you have spent, means the same
/// quantity runs in opposite directions in two places on one screen.
///
/// The catch with a fuel gauge is that empty renders as nothing, which is
/// exactly the state that most needs to be visible. So the track carries the
/// severity color too, at low opacity: a spent limit is a complete red circle
/// with no arc on it, rather than an absence.
///
/// Used by the menu-bar glance (one cluster per subscription) and by the
/// popover's offline state (three dim, empty clusters).
public struct RingCluster: View {
    public let rings: [Window?]
    public var diameter: CGFloat = 18
    public var strokeWidth: CGFloat = 2
    /// The unfilled part of each ring. Defaults to the card's hairline; the menu
    /// bar passes a wash of its own ink instead, because a hairline picked for
    /// the card is invisible against the menu-bar strip.
    public var track: Color?

    public init(rings: [Window?], diameter: CGFloat = 18, strokeWidth: CGFloat = 2, track: Color? = nil) {
        self.rings = rings
        self.diameter = diameter
        self.strokeWidth = strokeWidth
        self.track = track
    }

    /// The two-ring form used by the offline state.
    public init(session: Window?, weekly: Window?, diameter: CGFloat = 18, strokeWidth: CGFloat = 2, track: Color? = nil) {
        self.init(rings: [session, weekly], diameter: diameter, strokeWidth: strokeWidth, track: track)
    }

    public var body: some View {
        ZStack {
            ForEach(Array(rings.enumerated()), id: \.offset) { index, window in
                ring(for: window, inset: inset(at: index))
            }
        }
        .frame(width: diameter, height: diameter)
    }

    /// Ring spacing from the approved artboards: one stroke off the frame edge,
    /// then a stroke-and-a-point per level inward. At the menu bar's 20pt/1.6pt
    /// that puts three rings at radii 8.4 / 5.8 / 3.2, which is the artboard's
    /// proportions at the size a status item actually has.
    private func inset(at index: Int) -> CGFloat {
        strokeWidth + CGFloat(index) * (strokeWidth + 1)
    }

    /// The unfilled part of a ring.
    ///
    /// Normally a wash of the ring's own severity, so a half-spent limit reads
    /// as one coloured ring rather than an arc floating on a grey circle. When
    /// the limit is fully spent there is no arc at all, so the track takes the
    /// severity at full strength instead: that is the state most worth seeing,
    /// and a 32% red is a solid dark ring on a dark bar but pale pink on a light
    /// one, which is the appearance that needs it most.
    ///
    /// A window with no reading has no severity to show, so it falls back to the
    /// neutral track the caller passed.
    func trackColor(pctLeft: Int?, fraction: Double, severity: Color) -> Color {
        guard pctLeft != nil else { return track ?? Theme.hairline }
        return fraction > 0 ? severity.opacity(0.32) : severity
    }

    @ViewBuilder
    private func ring(for window: Window?, inset: CGFloat) -> some View {
        let pctLeft = window?.pctLeft
        let fraction = Fmt.remaining(pctLeft: pctLeft)
        let severity = Theme.severity(pctLeft: pctLeft)
        let trackColor = trackColor(pctLeft: pctLeft, fraction: fraction, severity: severity)
        ZStack {
            Circle()
                .stroke(trackColor, lineWidth: strokeWidth)
            Circle()
                .trim(from: 0, to: max(0, min(1, fraction)))
                .stroke(
                    severity,
                    style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .padding(inset)
    }
}
