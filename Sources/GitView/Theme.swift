import SwiftUI
import AppKit
import GitViewCore

/// Design tokens. Dark is the concept's navy-charcoal; light is a matching cool neutral.
/// Status colours are a fixed palette and are always paired with an icon and a label.
enum Theme {
    // Surfaces
    static let page      = Color.adaptive(light: 0xF4F6FA, dark: 0x0B0F17)
    static let sidebar   = Color.adaptive(light: 0xEDF0F5, dark: 0x0E131B)
    static let surface   = Color.adaptive(light: 0xFFFFFF, dark: 0x121824)
    static let raised    = Color.adaptive(light: 0xFFFFFF, dark: 0x182030)
    static let hairline  = Color.adaptive(light: 0x0F172A, dark: 0xFFFFFF, alpha: 0.09)
    static let gridline  = Color.adaptive(light: 0xE2E8F0, dark: 0x1F2937)
    static let wash      = Color.adaptive(light: 0x0F172A, dark: 0xFFFFFF, alpha: 0.05)

    // Ink
    static let ink       = Color.adaptive(light: 0x0F172A, dark: 0xE8ECF3)
    static let inkSoft   = Color.adaptive(light: 0x475569, dark: 0x9AA4B5)
    static let inkMuted  = Color.adaptive(light: 0x94A3B8, dark: 0x6B7486)

    // Accent
    static let accent      = Color.adaptive(light: 0x2563EB, dark: 0x3B82F6)
    static let accentSoft  = Color.adaptive(light: 0x93C5FD, dark: 0x1E3A8A)
    static let accentWash  = Color.adaptive(light: 0x2563EB, dark: 0x3B82F6, alpha: 0.14)
    static let onAccent    = Color.white

    // Decorative tints for stat-card icons (identity, not data): validated categorical steps.
    enum Tint { case blue, aqua, violet, orange, yellow, magenta }
    static func tint(_ tint: Tint) -> Color {
        switch tint {
        case .blue: return Color.adaptive(light: 0x2A78D6, dark: 0x3987E5)
        case .aqua: return Color.adaptive(light: 0x1BAF7A, dark: 0x199E70)
        case .violet: return Color.adaptive(light: 0x4A3AA7, dark: 0x9085E9)
        case .orange: return Color.adaptive(light: 0xEB6834, dark: 0xD95926)
        case .yellow: return Color.adaptive(light: 0xEDA100, dark: 0xC98500)
        case .magenta: return Color.adaptive(light: 0xE87BA4, dark: 0xD55181)
        }
    }
    static let avatarTints: [Tint] = [.blue, .aqua, .violet, .orange, .yellow, .magenta]

    // Status palette — fixed, never themed.
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

    static func color(for status: RepositoryHealth.Status) -> Color {
        switch status {
        case .good: return good
        case .warning: return warning
        case .bad: return critical
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
        static let display  = Font.system(size: 24, weight: .semibold)
        static let title    = Font.system(size: 18, weight: .semibold)
        static let heading  = Font.system(size: 14, weight: .semibold)
        static let body     = Font.system(size: 13)
        static let bodyBold = Font.system(size: 13, weight: .semibold)
        static let caption  = Font.system(size: 11)
        static let hero     = Font.system(size: 24, weight: .semibold)
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
