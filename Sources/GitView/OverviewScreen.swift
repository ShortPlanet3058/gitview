// Cards that used to crowd the Overview. The dashboard now shows the shape of each of
// these and links to the tab that owns it, so they live here and are used by those tabs.
import SwiftUI
import Charts
import GitViewCore
import GitViewGit
import GitViewParse


enum ActivityRange: String, CaseIterable, Identifiable {
    case sixMonths = "Last 6 months", year = "Last year", twoYears = "Last 2 years", all = "All time"
    var id: String { rawValue }
}

// MARK: - Cards



struct HealthCard: View {
    let health: RepositoryHealth
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                CardHeader(title: "Repository health",
                           info: "Five checks, 100 points: recent activity (25), active contributors (20), branch "
                               + "hygiene (15), large files (15), and complex code under change (25) — the share of "
                               + "recent commits that landed in a function with 10 or more branch points. Branch "
                               + "hygiene counts local branches only; branches that exist just on the remote are "
                               + "other people's pull requests. Each line shows what was measured; the score is a "
                               + "heuristic to start a conversation, not a verdict.")
                HStack(spacing: Theme.Space.l) {
                    HealthRing(health: health)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(health.label).font(Theme.Text.title)
                            .foregroundStyle(health.score >= 80 ? Theme.good : health.score >= 60 ? Theme.warning : Theme.critical)
                        Text(health.summary).font(Theme.Text.body).foregroundStyle(Theme.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                VStack(spacing: 0) {
                    ForEach(health.items) { item in
                        HealthItemRow(item: item)
                        if item.id != health.items.last?.id { HairlineDivider() }
                    }
                }
            }
        }
    }
}



struct RepositoryInfoCard: View {
    let analysis: RepositoryAnalysis
    let contributors: Int
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                CardHeader(title: "Repository info")
                VStack(spacing: 0) {
                    row("folder", "Path", analysis.root.path)
                    row("arrow.triangle.branch", "Default branch", analysis.info.defaultBranch)
                    if let range = analysis.dateRange {
                        row("calendar", "Created", range.lowerBound.formatted(.dateTime.year().month(.abbreviated).day()))
                        row("clock", "Last commit", RiskExplanation.relative(range.upperBound, now: Date()))
                    }
                    row("person.2", "Total contributors", contributors.formatted())
                    if let remote = analysis.info.remoteURL { row("link", "Remote", remote) }
                }
            }
        }
    }
    private func row(_ symbol: String, _ label: String, _ value: String) -> some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(Theme.inkMuted).frame(width: 16)
            Text(label).font(Theme.Text.body).foregroundStyle(Theme.inkSoft)
            Spacer()
            Text(value).font(Theme.Text.body).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(.vertical, 6)
    }
}



/// Single-hue bars, recessive grid, no value on every bar.
struct ActivityBars: View {
    let buckets: [ActivityBucket]
    var granularity: ActivitySeries.Granularity = .week
    var body: some View {
        Chart(buckets) { bucket in
            BarMark(x: .value("Period", bucket.start, unit: granularity == .week ? .weekOfYear : .month),
                    y: .value("Commits", bucket.commits), width: .ratio(0.65))
                .foregroundStyle(Theme.accent)
                .cornerRadius(2)
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).year(.twoDigits)).foregroundStyle(Theme.inkMuted)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Theme.gridline)
                AxisValueLabel().foregroundStyle(Theme.inkMuted)
            }
        }
    }
}

struct BranchesCard: View {
    @EnvironmentObject private var model: AnalysisModel
    let branches: [BranchInfo]
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                CardHeader(title: "Branches", subtitle: "\(branches.count)")
                VStack(spacing: 0) {
                    ForEach(branches.prefix(5)) { branch in
                        HStack(spacing: Theme.Space.s) {
                            Image(systemName: "arrow.triangle.branch").font(.system(size: 10)).foregroundStyle(Theme.inkMuted)
                            Text(branch.name).font(Theme.Text.body).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                            if branch.isDefault { Chip(text: "Default", tint: Theme.accent) }
                            Spacer()
                            Text(RiskExplanation.relative(branch.date, now: Date())).font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                        }
                        .padding(.vertical, 6)
                    }
                }
                LinkButton(title: "See all →") { model.show(.branches) }
            }
        }
    }
}

struct RepositorySizeCard: View {
    let info: RepositoryInfo
    private var tints: [Theme.Tint] { [.blue, .violet, .yellow, .magenta] }
    var body: some View {
        let categories = FileInventory.categories
        let bytes = categories.map { info.inventory.bytesByCategory[$0] ?? 0 }
        let history = info.packedBytes ?? 0
        let total = max(bytes.reduce(0, +) + history, 1)
        return Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                CardHeader(title: "Repository size", subtitle: (bytes.reduce(0, +) + history).byteString,
                           info: "Tracked files by type, plus the git object store (\"Git history\"). Build products "
                               + "and dependencies are not counted.")
                GeometryReader { geometry in
                    HStack(spacing: 2) {
                        ForEach(Array(zip(categories, bytes).enumerated()), id: \.offset) { index, entry in
                            if entry.1 > 0 {
                                RoundedRectangle(cornerRadius: 2).fill(Theme.tint(tints[index % tints.count]))
                                    .frame(width: max(3, geometry.size.width * CGFloat(entry.1) / CGFloat(total)))
                            }
                        }
                        if history > 0 {
                            RoundedRectangle(cornerRadius: 2).fill(Theme.inkMuted)
                                .frame(width: max(3, geometry.size.width * CGFloat(history) / CGFloat(total)))
                        }
                    }
                }
                .frame(height: 10)
                VStack(spacing: 4) {
                    ForEach(Array(zip(categories, bytes).enumerated()), id: \.offset) { index, entry in
                        legendRow(entry.0, Int64(entry.1), Theme.tint(tints[index % tints.count]))
                    }
                    legendRow("Git history", history, Theme.inkMuted)
                }
            }
        }
    }
    private func legendRow(_ label: String, _ bytes: Int64, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(Theme.Text.caption).foregroundStyle(Theme.inkSoft)
            Spacer()
            Text(bytes.byteString).font(Theme.Text.caption.monospacedDigit()).foregroundStyle(Theme.ink)
        }
    }
}

struct TopChangedFilesCard: View {
    let commits: [Commit]
    var body: some View {
        let top = ChangeFrequency.topFiles(commits: commits, since: Date().addingTimeInterval(-90 * 86_400), limit: 6)
        return Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                CardHeader(title: "Top changed files", subtitle: "last 3 months")
                if top.isEmpty {
                    Text("No changes in the last 3 months.").font(Theme.Text.body).foregroundStyle(Theme.inkMuted)
                } else {
                    VStack(spacing: 0) {
                        ForEach(top) { entry in
                            HStack(spacing: Theme.Space.s) {
                                Image(systemName: "doc.text").font(.system(size: 10)).foregroundStyle(Theme.inkMuted)
                                Text(entry.path).font(Theme.Text.body).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.head)
                                Spacer()
                                Text("\(entry.changes)").font(Theme.Text.caption.monospacedDigit()).foregroundStyle(Theme.inkSoft)
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }
            }
        }
    }
}




/// GitHub-style language bar. Colours come from Linguist and identify a language rather
/// than encoding a value, so every segment is also named with its share in the legend.
struct LanguagesCard: View {
    let inventory: FileInventory

    /// Languages GitView can parse for function-level risk, matched by display name.
    private static let analysable: Set<String> = Set(LanguageSupport.all.map(\.displayName))

    var body: some View {
        let shares = inventory.languages
        let total = max(shares.reduce(Int64(0)) { $0 + $1.bytes }, 1)
        let shown = Array(shares.prefix(8))
        let otherBytes = shares.dropFirst(8).reduce(Int64(0)) { $0 + $1.bytes }
        let analysedCount = shares.filter { Self.analysable.contains($0.language.name) }.count

        return Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                CardHeader(title: "Languages",
                           subtitle: "\(shares.count) in this repository",
                           info: "Share of tracked bytes per language, identified the same way GitHub does — "
                               + "by filename and extension — but computed locally, so it works offline and on "
                               + "repositories that are not on GitHub. Risk analysis needs a parser as well, and "
                               + "only applies to languages that have functions.")
                if shares.isEmpty {
                    Text("No recognised source files.").font(Theme.Text.body).foregroundStyle(Theme.inkMuted)
                } else {
                    GeometryReader { geometry in
                        HStack(spacing: 2) {
                            ForEach(shown) { share in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(color(share.language))
                                    .frame(width: max(3, geometry.size.width * CGFloat(share.bytes) / CGFloat(total)))
                            }
                            if otherBytes > 0 {
                                RoundedRectangle(cornerRadius: 2).fill(Theme.inkMuted)
                                    .frame(width: max(3, geometry.size.width * CGFloat(otherBytes) / CGFloat(total)))
                            }
                        }
                    }
                    .frame(height: 10)
                    FlowRow(spacing: Theme.Space.l) {
                        ForEach(shown) { share in
                            HStack(spacing: 5) {
                                Circle().fill(color(share.language)).frame(width: 8, height: 8)
                                Text(share.language.name).font(Theme.Text.caption).foregroundStyle(Theme.ink)
                                Text(percent(share.bytes, of: total))
                                    .font(Theme.Text.caption.monospacedDigit()).foregroundStyle(Theme.inkMuted)
                                if Self.analysable.contains(share.language.name) {
                                    Image(systemName: "flame.fill").font(.system(size: 8)).foregroundStyle(Theme.serious)
                                }
                            }
                        }
                        if otherBytes > 0 {
                            HStack(spacing: 5) {
                                Circle().fill(Theme.inkMuted).frame(width: 8, height: 8)
                                Text("Other").font(Theme.Text.caption).foregroundStyle(Theme.inkSoft)
                                Text(percent(otherBytes, of: total))
                                    .font(Theme.Text.caption.monospacedDigit()).foregroundStyle(Theme.inkMuted)
                            }
                        }
                    }
                    Text(analysedCount == 0
                         ? "None of these can be ranked for function-level risk yet."
                         : "\u{1F525} marks the \(analysedCount) language\(analysedCount == 1 ? "" : "s") GitView also ranks by risk.")
                        .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                }
            }
        }
    }

    private func color(_ language: KnownLanguage) -> Color {
        language.colorHex.map { Color(hex: $0) } ?? Theme.inkMuted
    }

    private func percent(_ bytes: Int64, of total: Int64) -> String {
        let value = Double(bytes) / Double(total) * 100
        return value < 1 ? String(format: "%.1f%%", value) : "\(Int(value.rounded()))%"
    }
}

/// Wraps its children onto as many lines as needed — the legend has a variable number of
/// entries and a fixed grid would either clip or leave holes.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += lineHeight + 6; lineHeight = 0 }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += lineHeight + 6; lineHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
