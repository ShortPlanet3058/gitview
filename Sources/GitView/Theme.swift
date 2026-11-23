import SwiftUI
import AppKit
import GitViewCore
import GitViewParse

/// Design tokens. Dark is the concept's navy-charcoal; light is a matching cool neutral.
/// Status colours are a fixed palette and are always paired with an icon and a label.
enum Theme {
    // Surfaces
    static let page           = Color.adaptive(light: 0xF6F8FB, dark: 0x0A0D14)
    static let sidebar        = Color.adaptive(light: 0xEEF1F6, dark: 0x0D1119)
    static let surface        = Color.adaptive(light: 0xFFFFFF, dark: 0x131823)
    static let raised         = Color.adaptive(light: 0xFFFFFF, dark: 0x1A2130)
    static let hairline       = Color.adaptive(light: 0x0F172A, dark: 0xFFFFFF, alpha: 0.068)
    static let innerHighlight = Color.adaptive(light: 0xFFFFFF, dark: 0xFFFFFF, alpha: 0.045)
    static let cardShadow     = Color.adaptive(light: 0x0F172A, dark: 0x000000, alpha: 0.06)
    static let gridline       = Color.adaptive(light: 0xE2E8F0, dark: 0x1F2937)
    static let wash           = Color.adaptive(light: 0x0F172A, dark: 0xFFFFFF, alpha: 0.05)

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
        static let card: CGFloat = 14
        static let control: CGFloat = 9
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
        static let hero     = Font.system(size: 26, weight: .semibold)
        static let mono     = Font.system(size: 11, design: .monospaced)
    }

    enum Syntax {
        static let keyword  = Color.adaptive(light: 0x7C3AED, dark: 0xC084FC)
        static let type     = Color.adaptive(light: 0x0F766E, dark: 0x5EEAD4)
        static let function = Color.adaptive(light: 0x1D4ED8, dark: 0x60A5FA)
        static let string   = Color.adaptive(light: 0xB45309, dark: 0xFBBF24)
        static let comment  = Color.adaptive(light: 0x64748B, dark: 0x7C8598)
        static let number   = Color.adaptive(light: 0xC2410C, dark: 0xFB923C)
        static let property = Color.adaptive(light: 0x0369A1, dark: 0x7DD3FC)

        static func color(for kind: SyntaxTokenKind) -> Color {
            switch kind {
            case .keyword: return keyword
            case .type: return type
            case .function: return function
            case .string: return string
            case .comment: return comment
            case .number: return number
            case .property: return property
            }
        }

        /// Builds a syntax-highlighted `AttributedString`, safely mapping UTF-16 spans and optional background highlights.
        static func attributedLine(
            _ text: String,
            spans: [HighlightSpan],
            baseForeground: Color,
            foregroundOpacity: Double = 1.0,
            emphasisUTF16Ranges: [Range<Int>] = [],
            emphasisBackground: Color? = nil,
            searchQuery: String = ""
        ) -> AttributedString {
            let display = text.isEmpty ? " " : text
            var attributed = AttributedString(display)
            attributed.foregroundColor = foregroundOpacity < 1.0 ? baseForeground.opacity(foregroundOpacity) : baseForeground

            guard !text.isEmpty else { return attributed }

            for span in spans {
                if let attrRange = attributedRange(forUTF16: span.range, in: text, attributed: attributed) {
                    let tokenColor = color(for: span.kind)
                    attributed[attrRange].foregroundColor = foregroundOpacity < 1.0
                        ? tokenColor.opacity(foregroundOpacity)
                        : tokenColor
                }
            }

            if let emphasisBackground {
                for emphasisUTF16Range in emphasisUTF16Ranges {
                    if let attrRange = attributedRange(forUTF16: emphasisUTF16Range, in: text, attributed: attributed) {
                        attributed[attrRange].backgroundColor = emphasisBackground
                    }
                }
            }

            let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespaces)
            if !trimmedQuery.isEmpty {
                var searchStart = text.startIndex
                while searchStart < text.endIndex,
                      let found = text.range(of: trimmedQuery, options: .caseInsensitive, range: searchStart..<text.endIndex) {
                    if let attrStart = AttributedString.Index(found.lowerBound, within: attributed),
                       let attrEnd = AttributedString.Index(found.upperBound, within: attributed),
                       attrStart < attrEnd {
                        attributed[attrStart..<attrEnd].backgroundColor = Theme.warning.opacity(0.35)
                    }
                    searchStart = found.upperBound
                }
            }

            return attributed
        }

        private static func attributedRange(forUTF16 range: Range<Int>, in text: String,
                                            attributed: AttributedString) -> Range<AttributedString.Index>? {
            let utf16 = text.utf16
            let lower = min(max(0, range.lowerBound), utf16.count)
            let upper = min(max(lower, range.upperBound), utf16.count)
            guard lower < upper else { return nil }
            let uStart = utf16.index(utf16.startIndex, offsetBy: lower)
            let uEnd = utf16.index(utf16.startIndex, offsetBy: upper)
            guard let sStart = String.Index(uStart, within: text),
                  let sEnd = String.Index(uEnd, within: text),
                  sStart < sEnd,
                  let aStart = AttributedString.Index(sStart, within: attributed),
                  let aEnd = AttributedString.Index(sEnd, within: attributed),
                  aStart < aEnd else {
                return nil
            }
            return aStart..<aEnd
        }
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
