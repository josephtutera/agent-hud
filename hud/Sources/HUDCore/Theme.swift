import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// The single source of truth for the instrument-cluster palette and type ramp.
// Never inline a hex or a font size at a call site; reach for a token here.
public enum Theme {

    // MARK: Colors
    //
    // Every semantic token is a *dynamic* color: it resolves to the light hex
    // in Aqua and the dark hex in Dark Aqua, so the HUD follows the system
    // appearance with no toggle. Dark values are the original approved
    // artboard palette; light values are their daylight counterparts (white
    // card, ink text, severity nudged darker so amber/green read on white).
    // The menu-bar glance is unaffected — it renders monochrome as a template.
    public static let notch    = dynamic(light: 0xE9EAEE, dark: 0x000000)
    public static let panel    = dynamic(light: 0xFFFFFF, dark: 0x101114)
    public static let panel2   = dynamic(light: 0xF4F5F7, dark: 0x17181C)
    public static let hairline = dynamic(light: 0xE4E6EB, dark: 0x2A2C33)
    public static let text     = dynamic(light: 0x17181C, dark: 0xF2F3F5)
    public static let muted    = dynamic(light: 0x6A6F78, dark: 0x8A8F98)
    // `faint` is the recessive tier — captions, the meter rows a pod is not
    // headlining — but it still carries readings, so it is held at 3:1 against
    // the card it sits on rather than allowed to fade to decoration.
    public static let faint    = dynamic(light: 0x8C9299, dark: 0x61666F)
    public static let amber    = dynamic(light: 0xB26B00, dark: 0xFFB340)
    public static let green    = dynamic(light: 0x1E9E4A, dark: 0x34C759)
    public static let red      = dynamic(light: 0xDA3A3F, dark: 0xFF5F57)

    // A problem row's own surface: amber washed into the card so a row that
    // needs attention reads as a block rather than as coloured text.
    public static let warnSurface = dynamic(light: 0xFDF5E6, dark: 0x1E1A12)
    public static let warnBorder  = dynamic(light: 0xEBD9B4, dark: 0x3A2F17)
    // A copyable command sits in a chip that reads as terminal: recessed on the
    // dark card, raised (white, hairlined) on the light one.
    public static let chip        = dynamic(light: 0xFFFFFF, dark: 0x0B0C0E)
    public static let chipBorder  = dynamic(light: 0xE4E6EB, dark: 0x0B0C0E)

    // Brand marks. Both deepen on white so they hold contrast against the light
    // card; the Codex mark draws in `text` on the card (see providerColor).
    public static let claudeCoral = dynamic(light: 0xC15F3C, dark: 0xD97757)
    public static let codexGreen  = dynamic(light: 0x109965, dark: 0x19C37D)

    /// A color that resolves per system appearance: `light` in Aqua, `dark` in
    /// Dark Aqua. On platforms without AppKit it collapses to the dark value.
    public static func dynamic(light: UInt32, dark: UInt32) -> Color {
        #if canImport(AppKit)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
        #else
        return Color(hex: dark)
        #endif
    }

    // MARK: Severity
    /// Ring / meter color driven by percent remaining.
    /// Fully spent (0) reads red, pressured (<25) amber, otherwise green.
    /// A null reading has no severity and renders as the track color.
    public static func severity(pctLeft: Int?) -> Color {
        guard let pct = pctLeft else { return hairline }
        if pct <= 0 { return red }
        if pct < 25 { return amber }
        return green
    }

    /// The brand mark tint for a subscription provider on the card. Claude is
    /// coral; Codex draws in `text` (ink on the light card, near-white on the
    /// dark one) since a fixed white mark would vanish on a white surface.
    public static func providerColor(_ provider: String) -> Color {
        provider == "codex" ? text : claudeCoral
    }

    /// The dot beside a pod's "2 agents" line. One colour, not a palette: the
    /// card counts agents per subscription rather than listing them, so there is
    /// nothing left to tell apart by hue. Deliberately clear of the severity
    /// green/amber/red the quota meters own, so it never reads as a warning.
    public static let agentDot = dynamic(light: 0x1F87A8, dark: 0x4EC9E0)

    // MARK: Type
    public static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    public static func label(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
}

extension Color {
    /// Construct an opaque color from a packed 0xRRGGBB integer.
    public init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }
}

#if canImport(AppKit)
extension NSColor {
    /// Construct an opaque color from a packed 0xRRGGBB integer, in sRGB so it
    /// matches the SwiftUI `Color(hex:)` above.
    convenience init(hex: UInt32) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >> 8) & 0xFF) / 255.0
        let b = CGFloat(hex & 0xFF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }
}
#endif
