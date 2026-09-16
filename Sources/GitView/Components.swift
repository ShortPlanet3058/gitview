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
        // Hover is quick enough to feel instant but not so instant that the highlight
        // flickers when the pointer crosses the sidebar on its way somewhere else.
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.15), value: selected)
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

// MARK: - Concept-dashboard pieces

/// Icon square + big number + label, as on the concept's overview.
struct StatCard: View {
    let icon: String
    let tint: Theme.Tint
    let value: String
    let label: String
    var delta: String? = nil

    var body: some View {
        Card(padding: Theme.Space.l) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.tint(tint))
                    .frame(width: 36, height: 36)
                    .background(Theme.tint(tint).opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(value).font(Theme.Text.hero).foregroundStyle(Theme.ink).lineLimit(1).minimumScaleFactor(0.7)
                    Text(label).font(Theme.Text.caption).foregroundStyle(Theme.inkSoft)
                    if let delta {
                        Text(delta).font(Theme.Text.caption).foregroundStyle(Theme.good)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// Initials in a tinted circle — no network, so no photos.
struct Avatar: View {
    let name: String
    var size: CGFloat = 28

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }
    private var tint: Color {
        var hash: UInt64 = 1469598103934665603
        for byte in name.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return Theme.tint(Theme.avatarTints[Int(hash % UInt64(Theme.avatarTints.count))])
    }

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.16), in: Circle())
    }
}

/// Score ring with the label inside; colour follows the status palette and is always
/// accompanied by the number and word.
struct HealthRing: View {
    let health: RepositoryHealth
    var size: CGFloat = 96

    private var color: Color {
        health.score >= 80 ? Theme.good : health.score >= 60 ? Theme.warning : Theme.critical
    }

    var body: some View {
        ZStack {
            Circle().stroke(Theme.wash, lineWidth: 8)
            Circle()
                .trim(from: 0, to: CGFloat(health.score) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(health.score)").font(.system(size: size * 0.3, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(health.label).font(.system(size: size * 0.11)).foregroundStyle(color)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Health \(health.score), \(health.label)")
    }
}

struct HealthItemRow: View {
    let item: RepositoryHealth.Item
    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: item.status == .good ? "checkmark.circle.fill"
                  : item.status == .warning ? "exclamationmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Theme.color(for: item.status))
            Text(item.title).font(Theme.Text.body).foregroundStyle(Theme.ink)
            Spacer()
            Text(item.detail).font(Theme.Text.caption).foregroundStyle(Theme.inkSoft)
                .lineLimit(2).multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 5)
    }
}

/// Sha as a small mono chip.
struct ShaChip: View {
    let sha: String
    var body: some View {
        Text(sha.prefix(7))
            .font(Theme.Text.mono)
            .foregroundStyle(Theme.inkSoft)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Theme.wash, in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
    }
}

/// Tiny link-styled button ("See all →").
struct LinkButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(Theme.Text.body).foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plain)
    }
}

/// Column headings for hand-built tables.
struct TableHeading: View {
    let columns: [(String, CGFloat?, Alignment)]
    var body: some View {
        HStack(spacing: Theme.Space.m) {
            ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                Text(column.0.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.inkMuted)
                    .frame(width: column.1, alignment: column.2)
                    .frame(maxWidth: column.1 == nil ? .infinity : nil, alignment: column.2)
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, 6)
    }
}

/// Inline proportion bar used in tables (contributors, size).
struct InlineBar: View {
    let fraction: Double
    var tint: Color = Theme.accent
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.wash)
                Capsule().fill(tint).frame(width: max(3, geometry.size.width * CGFloat(min(max(fraction, 0), 1))))
            }
        }
        .frame(height: 6)
    }
}

// MARK: - Static rendering (offscreen screenshots)

private struct StaticRenderingKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// True while `--screenshot` renders the view offscreen: ScrollViews become plain stacks
    /// there because ImageRenderer leaves scroll content blank.
    var staticRendering: Bool {
        get { self[StaticRenderingKey.self] }
        set { self[StaticRenderingKey.self] = newValue }
    }
}

/// Vertical ScrollView that degrades to a fixed stack under static rendering.
struct ScrollColumn<Content: View>: View {
    @Environment(\.staticRendering) private var staticRendering
    var showsIndicators = true
    @ViewBuilder let content: Content
    var body: some View {
        if staticRendering {
            // Content taller than the frame would be centred and spill off the top; pin it
            // to the top edge and clip so an offscreen render shows what a user sees first.
            // An explicit minHeight matters: without it the frame grows to the child's height
            // and nothing is clipped.
            VStack(spacing: 0) { content }
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
        } else {
            ScrollView(showsIndicators: showsIndicators) {
                content.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

extension Int64 {
    /// "892 MB", "1.2 GB", "48 KB".
    var byteString: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.allowsNonnumericFormatting = false   // "0 bytes", not "Zero KB"
        return formatter.string(fromByteCount: self)
    }
}


extension Double {
    /// "19%" normally, "0.3%" below one percent so small shares do not read as nothing.
    var sharePercent: String {
        let percent = self * 100
        if percent > 0 && percent < 1 { return String(format: "%.1f%%", percent) }
        return "\(Int(percent.rounded()))%"
    }
}

/// Stands in for content whose part of the analysis has not been read yet.
///
/// The alternative is worse than a spinner: a commits page drawn before history arrives
/// shows "0 commits", which is not a loading state, it is a wrong answer.
///
/// It also has to tell the truth once the read has stopped. After "Stop", nothing is
/// arriving any more, and a page that goes on claiming to be reading would be waiting for
/// something that is never coming — so it says what happened and offers to finish.
struct StillReading: View {
    @EnvironmentObject private var model: AnalysisModel
    let what: String
    var compact = false

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            if model.loadProgress != nil {
                ProgressView().controlSize(.small)
                Text("Still reading \(what)…")
                    .font(compact ? Theme.Text.caption : Theme.Text.body)
                    .foregroundStyle(Theme.inkMuted)
            } else {
                Text("Stopped before \(what) was read.")
                    .font(compact ? Theme.Text.caption : Theme.Text.body)
                    .foregroundStyle(Theme.inkMuted)
                Button("Finish reading") { model.refresh() }
                    .buttonStyle(SecondaryButtonStyle())
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, compact ? Theme.Space.l : Theme.Space.xxl)
    }
}
