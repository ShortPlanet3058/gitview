import SwiftUI
import GitViewCore

// MARK: - Card

struct Card<Content: View>: View {
    var padding: CGFloat = Theme.Space.l
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

struct CardHeader: View {
    let title: String
    var subtitle: String? = nil
    var info: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(title).font(Theme.Text.heading).foregroundStyle(Theme.ink)
            if let info { InfoButton(title: title, text: info) }
            Spacer()
            if let subtitle {
                Text(subtitle).font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
            }
        }
    }
}

// MARK: - Explanations

/// A small "i" that opens a plain-language explanation. Terms are explained where they
/// appear rather than assumed.
struct InfoButton: View {
    let title: String
    let text: String
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkMuted)
        }
        .buttonStyle(.plain)
        .help(text)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text(title).font(Theme.Text.heading)
                Text(text).font(Theme.Text.body).foregroundStyle(Theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Space.l)
            .frame(width: 300)
        }
    }
}

// MARK: - Risk badge

/// Level is always shown with icon and label together; colour alone never carries it.
struct RiskBadge: View {
    let level: RiskLevel
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: level.symbolName)
                .font(.system(size: compact ? 9 : 10, weight: .semibold))
                .foregroundStyle(Theme.color(for: level))
            Text(level.label)
                .font(.system(size: compact ? 10 : 11, weight: .semibold))
                .foregroundStyle(Theme.ink)
        }
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 2 : 3)
        .background(Theme.color(for: level).opacity(0.14),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
        .accessibilityLabel("\(level.label) risk")
    }
}

// MARK: - Stat tile

struct StatTile: View {
    let value: String
    let label: String
    var caption: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(Theme.Text.hero).foregroundStyle(Theme.ink)
            Text(label).font(Theme.Text.body).foregroundStyle(Theme.inkSoft)
            if let caption {
                Text(caption).font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Bars

/// Label left, thin rounded bar, value right. One hue for nominal categories.
struct BarRow: View {
    let label: String
    let detail: String
    let fraction: Double
    var tint: Color = Theme.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(Theme.Text.body).foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.head)
                Spacer()
                Text(detail).font(Theme.Text.caption.monospacedDigit()).foregroundStyle(Theme.inkSoft)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.wash)
                    Capsule().fill(tint)
                        .frame(width: max(4, geometry.size.width * CGFloat(min(max(fraction, 0), 1))))
                }
            }
            .frame(height: 6)
        }
    }
}

/// Stacked distribution with 2pt surface gaps; each segment is named in a legend row
/// beneath rather than inside the bar, so nothing is clipped or colour-only.
struct LevelDistributionBar: View {
    let counts: [RiskLevel: Int]

    private var total: Int { counts.values.reduce(0, +) }
    private var ordered: [(RiskLevel, Int)] {
        RiskLevel.allCases.reversed().map { ($0, counts[$0] ?? 0) }.filter { $0.1 > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(ordered, id: \.0) { level, count in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Theme.color(for: level))
                            .frame(width: max(3, (geometry.size.width - CGFloat(ordered.count - 1) * 2)
                                              * CGFloat(count) / CGFloat(max(total, 1))))
                    }
                }
            }
            .frame(height: 10)
            HStack(spacing: Theme.Space.l) {
                ForEach(ordered, id: \.0) { level, count in
                    HStack(spacing: 4) {
                        Image(systemName: level.symbolName)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.color(for: level))
                        Text("\(count) \(level.label.lowercased())")
                            .font(Theme.Text.caption).foregroundStyle(Theme.inkSoft)
                    }
                }
            }
        }
    }
}

// MARK: - Navigation

struct NavButton: View {
    let title: String
    let systemImage: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                Text(title).font(Theme.Text.body.weight(selected ? .semibold : .regular))
                Spacer()
            }
            .foregroundStyle(selected ? Theme.ink : Theme.inkSoft)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(selected ? Theme.accentWash : (hovering ? Theme.wash : .clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct Chip: View {
    let text: String
    var tint: Color = Theme.inkSoft
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Theme.wash, in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Text.bodyBold)
            .foregroundStyle(.white)
            .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.s)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.8 : 1),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Text.body)
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, Theme.Space.m).padding(.vertical, 6)
            .background(configuration.isPressed ? Theme.wash : Theme.surface,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(Theme.hairline))
    }
}

/// Segmented choice drawn in the app's own style.
struct SegmentPicker<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                Button { selection = value } label: {
                    Text(label)
                        .font(.system(size: 12, weight: selection == value ? .semibold : .regular))
                        .foregroundStyle(selection == value ? Theme.ink : Theme.inkSoft)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(selection == value ? Theme.raised : .clear,
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Theme.wash, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }
}

// MARK: - Misc

struct HairlineDivider: View {
    var body: some View { Rectangle().fill(Theme.hairline).frame(height: 1) }
}

extension View {
    func sectionSpacing() -> some View { padding(.bottom, Theme.Space.xl) }
}
