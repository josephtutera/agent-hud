import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// The click-through card. Top to bottom: a slim header, one pod per subscription
// showing every window it reports, the setup panel, the API-value strip, and a
// footer. Colors are the dynamic Theme tokens, so the whole card follows the
// system light/dark appearance. Width 520, radius 16, hairline border.

public struct PopoverCard: View {
    public let snapshot: HUDSnapshot?
    public var now: Date
    /// Called when the footer's refresh is pressed. Nil in previews and tests,
    /// which is why the control is a seam rather than a direct call into the store.
    public var onRefresh: (() -> Void)?

    public init(snapshot: HUDSnapshot?, now: Date = Date(), onRefresh: (() -> Void)? = nil) {
        self.snapshot = snapshot
        self.now = now
        self.onRefresh = onRefresh
    }

    private var orderedSubs: [Subscription] {
        snapshot?.orderedSubscriptions ?? []
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let snap = snapshot {
                CardHeaderView(now: now)
                GaugeClusterView(subs: orderedSubs, now: now)
                SetupSection(setup: snap.setup)
                if let value = snap.value {
                    ValueStripView(value: value, subs: orderedSubs, now: now)
                }
                FooterView(setup: snap.setup, generatedAt: snap.generatedAt,
                           now: now, onRefresh: onRefresh)
            } else {
                OfflineView()
            }
        }
        .padding(22)
        .frame(width: 520, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
    }
}

// MARK: - Header

/// A slim card head: the wordmark, a hairline that fills the row, and the
/// current date and time, so the card reads as a dated snapshot.
struct CardHeaderView: View {
    let now: Date

    var body: some View {
        HStack(spacing: 14) {
            Text("AGENT HUD")
                .font(Theme.label(11, weight: .semibold))
                .tracking(2.0)
                .foregroundStyle(Theme.text)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            Text(Self.dateText(now))
                .font(Theme.mono(10))
                .foregroundStyle(Theme.muted)
                .fixedSize()
        }
    }

    static func dateText(_ now: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE MMM d"
        return "\(f.string(from: now)) · \(Fmt.clock(now))"
    }
}

// MARK: - Section header rule

/// A section rule: a caps letterspaced label, a hairline that fills the row,
/// and an optional right-aligned accessory.
struct SectionRule<Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(Theme.label(10, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(Theme.muted)
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
            accessory()
        }
    }
}

extension SectionRule where Accessory == EmptyView {
    init(title: String) {
        self.init(title: title, accessory: { EmptyView() })
    }
}

// MARK: - Gauge cluster

/// The instrument cluster: one gauge pod per subscription, equal width.
struct GaugeClusterView: View {
    let subs: [Subscription]
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            ForEach(subs) { sub in
                PodView(sub: sub, now: now)
            }
        }
    }
}

/// One plan's pod: mark + short name, the big number for the window with the
/// least headroom, when that window resets, then a meter row for every window
/// the subscription reports. Every window is shown because a Claude plan has
/// three and a Codex plan has one, and a card that only draws the 5-hour window
/// silently hides whichever limit you are actually about to hit. The tightest
/// row is the one drawn at full contrast, since it is the number the big figure
/// is quoting.
///
/// When that window is pressured (< 25% left) the whole pod lights in its
/// severity color, the way a dashboard warning lamp does.
struct PodView: View {
    let sub: Subscription
    let now: Date

    /// The window the pod headlines. `tightest` is the daemon's own answer; the
    /// fallbacks only matter for a subscription reporting no percentages at all.
    private var leadWindow: Window? { sub.tightest ?? sub.sessionWindow ?? sub.windows.first }
    private var leadPct: Int? { leadWindow?.pctLeft }
    private var severity: Color { Theme.severity(pctLeft: leadPct) }

    /// Lit when the lead window is amber/red (pressured), i.e. < 25% left.
    private var isLit: Bool {
        guard let p = leadPct else { return false }
        return p < 25
    }

    private var shortName: String {
        if sub.label.hasPrefix("Claude ") {
            return String(sub.label.dropFirst("Claude ".count))
        }
        return sub.label
    }

    private var dotColor: Color {
        sub.provider == "codex" ? Theme.codexGreen : Theme.claudeCoral
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(dotColor).frame(width: 7, height: 7)
                Text(sub.label.uppercased())
                    .font(Theme.label(9, weight: .semibold))
                    .tracking(1.0)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(Fmt.glancePercent(pctLeft: leadPct))
                    .font(Theme.mono(34, weight: .bold))
                    .foregroundStyle(isLit ? severity : Theme.text)
                    .monospacedDigit()
                Text("%")
                    .font(Theme.mono(12))
                    .foregroundStyle(isLit ? severity.opacity(0.7) : Theme.muted)
            }

            Text(resetCaption)
                .font(Theme.label(9))
                .foregroundStyle(Theme.faint)
                .lineLimit(1)

            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(sub.windows.enumerated()), id: \.offset) { _, window in
                    PodMeterRow(window: window, isLead: window.kind == leadWindow?.kind)
                }
                if sub.sessionWindow == nil {
                    // Codex reports only a weekly limit. Saying so beats leaving
                    // a reader to wonder where the session row went.
                    Text("no session limit")
                        .font(Theme.label(9))
                        .foregroundStyle(Theme.faint)
                        .padding(.top, 1)
                }
                if sub.activeAgents > 0 {
                    HStack(spacing: 5) {
                        Circle().fill(Theme.agentColor(1)).frame(width: 5, height: 5)
                        Text(sub.activeAgents == 1 ? "1 agent" : "\(sub.activeAgents) agents")
                            .font(Theme.label(10))
                            .foregroundStyle(Theme.muted)
                    }
                    .padding(.top, 3)
                }
                if let stale = sub.stale {
                    Text(stale)
                        .font(Theme.label(9))
                        .foregroundStyle(Theme.amber)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 3)
                }
            }
            .padding(.top, 3)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isLit ? severity.opacity(0.10) : Theme.panel2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isLit ? severity.opacity(0.40) : Theme.hairline, lineWidth: 1)
        )
    }

    /// When the headline window rolls over, as a day and clock time rather than
    /// a countdown: the countdown belongs in the menu bar, where you glance at
    /// it; here you are deciding whether to wait, which is a question about when.
    private var resetCaption: String {
        guard let reset = leadWindow?.resetsAt else { return "no reset reported" }
        return "resets \(Fmt.dayClock(reset, now: now))"
    }
}

/// One window inside a pod: a fixed-width label, a bar filled by how much is
/// left, and the number. The lead row draws at full contrast; the rest recede,
/// so the pod reads as one number with its supporting detail.
struct PodMeterRow: View {
    let window: Window
    let isLead: Bool

    var body: some View {
        HStack(spacing: 5) {
            Text(Fmt.windowName(kind: window.kind))
                .font(Theme.label(10))
                .foregroundStyle(isLead ? Theme.text : Theme.faint)
                .frame(width: 40, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.hairline)
                    Capsule()
                        .fill(Theme.severity(pctLeft: window.pctLeft))
                        .frame(width: Fmt.remaining(pctLeft: window.pctLeft) * geo.size.width)
                }
            }
            .frame(height: 3)
            Text(Fmt.glancePercent(pctLeft: window.pctLeft))
                .font(Theme.label(10))
                .foregroundStyle(isLead ? Theme.text : Theme.muted)
                .monospacedDigit()
                .frame(width: 20, alignment: .trailing)
        }
    }
}

// MARK: - Value strip

/// The API-value readout: three tiles for today, the month, and the multiple
/// over what the subscriptions cost, then a line per subscription. The
/// per-subscription split is the part that answers "which plan is doing the
/// work", which the totals alone cannot.
struct ValueStripView: View {
    let value: ValueBlock
    let subs: [Subscription]
    let now: Date

    private var monthName: String {
        let f = DateFormatter()
        f.dateFormat = "MMMM"
        return f.string(from: now).uppercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionRule(title: "VALUE AT API RATES")
            HStack(spacing: 9) {
                tile(caption: "TODAY", value: Fmt.usd(value.todayUSD))
                tile(caption: monthName, value: Fmt.usd(value.monthUSD))
                multipleTile
            }
            if !bySub.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(bySub, id: \.label) { row in
                        HStack(spacing: 8) {
                            Circle().fill(row.color).frame(width: 7, height: 7)
                            Text(row.label)
                                .font(Theme.label(12))
                                .foregroundStyle(row.isSpent ? Theme.text : Theme.faint)
                            Spacer(minLength: 8)
                            Text(Fmt.usdExact(row.monthUSD))
                                .font(Theme.label(12))
                                .foregroundStyle(row.isSpent ? Theme.text : Theme.faint)
                                .monospacedDigit()
                        }
                    }
                }
                .padding(.horizontal, 3)
            }
        }
    }

    private struct SubRow {
        let label: String
        let color: Color
        let monthUSD: Double
        /// A plan that spent nothing this month recedes rather than disappearing:
        /// "this one is idle" is itself worth seeing.
        var isSpent: Bool { monthUSD > 0 }
    }

    /// Biggest spender first, so the line that explains the total leads.
    private var bySub: [SubRow] {
        subs.compactMap { sub in
            guard let v = value.bySub[sub.id] else { return nil }
            let color = sub.provider == "codex" ? Theme.codexGreen : Theme.claudeCoral
            return SubRow(label: sub.label,
                          color: v.monthUSD > 0 ? color : Theme.faint,
                          monthUSD: v.monthUSD)
        }
        .sorted { $0.monthUSD > $1.monthUSD }
    }

    private func tile(caption: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(caption)
                .font(Theme.label(9, weight: .semibold))
                .tracking(1.0)
                .foregroundStyle(Theme.muted)
            Text(value)
                .font(Theme.mono(22, weight: .bold))
                .foregroundStyle(Theme.text)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.panel2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
    }

    /// The multiple needs to know what the subscriptions cost, which lives in a
    /// config file nobody has to fill in. Unset, the tile says what to do about
    /// it rather than showing a dash that reads like a bug.
    @ViewBuilder
    private var multipleTile: some View {
        if let multiple = value.multiple {
            tile(caption: "MULTIPLE", value: Fmt.multiple(multiple))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("MULTIPLE")
                    .font(Theme.label(9, weight: .semibold))
                    .tracking(1.0)
                    .foregroundStyle(Theme.muted)
                Text("set what the subs cost")
                    .font(Theme.label(12))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(Theme.hairline)
            )
        }
    }
}

// MARK: - Footer

/// When the setup was last checked, a refresh, the copy-for-an-agent button, and
/// quit. Both new controls are read-only: one re-reads, one writes to the
/// clipboard. Nothing on this card mutates the machine.
struct FooterView: View {
    let setup: SetupBlock?
    let generatedAt: Date?
    let now: Date
    var onRefresh: (() -> Void)?

    @State private var didCopy = false

    var body: some View {
        HStack(spacing: 12) {
            Text(checkedLabel)
                .font(Theme.label(11))
                .foregroundStyle(Theme.faint)
                .fixedSize()
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.muted)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
                .onTapGesture { onRefresh?() }
                .help("Re-read the daemon now")
            Spacer(minLength: 0)
            if let setup, !setup.isClean {
                copyButton(setup: setup)
            }
            Text("quit")
                .font(Theme.label(11))
                .foregroundStyle(Theme.muted)
                .contentShape(Rectangle())
                .onTapGesture { AppActions.quit() }
        }
        .padding(.top, 6)
    }

    private func copyButton(setup: SetupBlock) -> some View {
        HStack(spacing: 7) {
            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10, weight: .semibold))
            Text(didCopy ? "copied" : copyLabel(setup.problems))
                .font(Theme.label(11))
        }
        .foregroundStyle(Theme.amber)
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.warnSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Theme.warnBorder, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            AppActions.copyToClipboard(SetupClipboard.payload(for: setup, now: now))
            didCopy = true
        }
    }

    private func copyLabel(_ n: Int) -> String {
        n == 1 ? "copy 1 problem for an agent" : "copy \(n) problems for an agent"
    }

    /// The setup block carries its own timestamp, which is what "checked" means
    /// here; the snapshot's own `generated_at` stands in when there is no block.
    private var checkedLabel: String {
        guard let stamped = setup?.generatedAt ?? generatedAt else { return "setup not checked" }
        return "setup checked \(Fmt.ago(stamped, now: now))"
    }
}

// MARK: - Offline

struct OfflineView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { _ in
                    RingCluster(session: nil, weekly: nil).opacity(0.35)
                }
            }
            Text("daemon offline, run: agenthud serve")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }
}

/// Side effects the card triggers. Kept behind a seam so the views stay pure
/// and the tests never shell out. Every one of these is read-only or writes to
/// the clipboard: nothing on this card changes the machine.
public enum AppActions {
    /// Put the setup problems, and the rules for fixing them properly, on the
    /// clipboard so they can be pasted into any agent.
    public static func copyToClipboard(_ text: String) {
        #if canImport(AppKit)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        #endif
    }

    /// Quit the HUD. There's no dock icon or app menu (it's an accessory app),
    /// so this is the only way out short of `kill`; the footer button and the
    /// status item's right-click menu both call it.
    public static func quit() {
        #if canImport(AppKit)
        NSApplication.shared.terminate(nil)
        #endif
    }
}
