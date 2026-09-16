import SwiftUI
import AppKit
import GitViewCore

/// Design tokens. Values come from a validated palette (warm-neutral surfaces, a blue
/// accent, a fixed status palette); dark mode uses its own steps, not an inverted light.
enum Theme {
    // Surfaces
    static let page      = Color.adaptive(light: 0xF9F9F7, dark: 0x0D0D0D)
    static let surface   = Color.adaptive(light: 0xFCFCFB, dark: 0x1A1A19)
    static let raised    = Color.adaptive(light: 0xFFFFFF, dark: 0x222221)
    static let sidebar   = Color.adaptive(light: 0xF2F2EF, dark: 0x121211)
    static let hairline  = Color.adaptive(light: 0x0B0B0B, dark: 0xFFFFFF, alpha: 0.10)
    static let gridline  = Color.adaptive(light: 0xE1E0D9, dark: 0x2C2C2A)
    static let wash      = Color.adaptive(light: 0x0B0B0B, dark: 0xFFFFFF, alpha: 0.05)

    // Ink
    static let ink       = Color.adaptive(light: 0x0B0B0B, dark: 0xFFFFFF)
    static let inkSoft   = Color.adaptive(light: 0x52514E, dark: 0xC3C2B7)
    static let inkMuted  = Color.adaptive(light: 0x898781, dark: 0x898781)

    // Accent (categorical slot 1 / sequential hue)
    static let accent      = Color.adaptive(light: 0x2A78D6, dark: 0x3987E5)
    static let accentSoft  = Color.adaptive(light: 0x86B6EF, dark: 0x184F95)
    static let accentWash  = Color.adaptive(light: 0x2A78D6, dark: 0x3987E5, alpha: 0.12)

    // Status palette — fixed, never themed, always paired with icon + label.
    static let critical = Color(hex: 0xD03B3B)
    static let serious  = Color(hex: 0xEC835A)
    static let warning  = Color(hex: 0xFAB219)
    static let good     = Color(hex: 0x0CA30C)

    static func color(for level: RiskLevel) -> Color {
        switch level {
        case .critical: return critical
        case .high: return serious
        case .elevated: return warning
        case .low: return good
        }
    }

    enum Radius {
        static let card: CGFloat = 12
        static let control: CGFloat = 8
        static let chip: CGFloat = 6
    }

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Text {
        static let display  = Font.system(size: 26, weight: .semibold)
        static let title    = Font.system(size: 19, weight: .semibold)
        static let heading  = Font.system(size: 14, weight: .semibold)
        static let body     = Font.system(size: 13)
        static let bodyBold = Font.system(size: 13, weight: .semibold)
        static let caption  = Font.system(size: 11)
        static let hero     = Font.system(size: 30, weight: .semibold)   // proportional figures on purpose
        static let mono     = Font.system(size: 11, design: .monospaced)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }

    /// Resolves per appearance so light and dark each get a chosen step.
    static func adaptive(light: UInt32, dark: UInt32, alpha: Double = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255,
                           alpha: CGFloat(alpha))
        })
    }
}
