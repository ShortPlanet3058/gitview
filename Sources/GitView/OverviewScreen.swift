import SwiftUI
import Charts
import GitViewCore
import GitViewGit
import GitViewParse

struct OverviewScreen: View {
    @EnvironmentObject private var model: AnalysisModel
    @State private var activityRange: ActivityRange = .sixMonths

    var body: some View {
        if let analysis = model.analysis {
            Page {
                HStack(alignment: .top) {
                    ScreenHeader(title: "Overview",
                                 subtitle: model.advanced ? "Detailed insights into your repository."
                                                          : "What has changed, and where things stand.")
                    Spacer()
                }

                // What to do now comes before what the repository is.
                HStack(alignment: .top, spacing: Theme.Space.l) {
                    if let catchUp = model.catchUp {
                        CatchUpCard(catchUp: catchUp).frame(maxWidth: .infinity)
                    }
                    WorkingStateCard(state: analysis.workingState).frame(width: 360)
                }

                ProjectCard(analysis: analysis)

                statTiles(analysis)

                LanguagesCard(inventory: analysis.info.inventory)

                // The catch-up card at the top already lists the newest commits. Showing
                // them again here was the same five rows twice on one screen, each with
                // its own "see all commits" link. Recent activity is kept for the case the
                // catch-up cannot cover — nothing new since the last visit — where it is
                // the only place the latest work appears.
                HStack(alignment: .top, spacing: Theme.Space.l) {
                    if model.catchUp?.isEmpty ?? true {
                        RecentActivityCard(commits: Array(analysis.commits.prefix(5)))
                            .frame(maxWidth: .infinity)
                    }
                    if let health = model.health {
                        HealthCard(health: health).frame(maxWidth: .infinity)
                    }
                }

                HStack(alignment: .top, spacing: Theme.Space.l) {
                    TopHotspotsCard().frame(maxWidth: .infinity)
                    if model.advanced {
                        ContributorsCard(contributors: model.contributors, total: analysis.commits.count)
                            .frame(maxWidth: .infinity)
                    } else {
                        QuickActionsCard(analysis: analysis).frame(maxWidth: .infinity)
                    }
                }

                if model.advanced {
                    ActivityChartCard(commits: analysis.commits, range: $activityRange)
                    HStack(alignment: .top, spacing: Theme.Space.l) {
                        BranchesCard(branches: analysis.branches).frame(maxWidth: .infinity)
                        RepositorySizeCard(info: analysis.info).frame(maxWidth: .infinity)
                        TopChangedFilesCard(commits: analysis.commits).frame(maxWidth: .infinity)
                    }
                    HStack(alignment: .top, spacing: Theme.Space.l) {
                        QuickActionsCard(analysis: analysis).frame(maxWidth: .infinity)
                        RepositoryInfoCard(analysis: analysis, contributors: model.contributors.count).frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private func statTiles(_ analysis: RepositoryAnalysis) -> some View {
        let now = Date()
        let calendar = Calendar.current
        let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? now
        let thisMonth = analysis.commits.filter { $0.date >= monthStart }.count
        let newPeople = model.contributors.filter { $0.firstCommit >= monthStart }.count
        let active = analysis.branches.filter { now.timeIntervalSince($0.date) < 90 * 86_400 }.count
        return HStack(spacing: Theme.Space.m) {
            StatCard(icon: "clock.arrow.circlepath", tint: .blue, value: analysis.commits.count.formatted(), label: "Commits",
                     delta: thisMonth > 0 ? "+\(thisMonth) this month" : nil)
            StatCard(icon: "person.2.fill", tint: .aqua, value: model.contributors.count.formatted(), label: "Contributors",
                     delta: newPeople > 0 ? "\(newPeople) new this month" : nil)
            if model.advanced {
                StatCard(icon: "arrow.triangle.branch", tint: .violet, value: analysis.branches.count.formatted(), label: "Branches",
                         delta: "\(active) active")
            }
            StatCard(icon: "doc.text.fill", tint: .orange, value: analysis.info.inventory.fileCount.formatted(), label: "Files",
                     delta: analysis.info.inventory.totalBytes.byteString)
            StatCard(icon: "calendar", tint: .yellow, value: Self.historySpan(analysis.dateRange), label: "History",
                     delta: analysis.dateRange.map { "since \($0.lowerBound.formatted(.dateTime.year().month(.abbreviated)))" })
        }
    }

    static func historySpan(_ range: ClosedRange<Date>?) -> String {
        guard let range else { return "—" }
        let days = range.upperBound.timeIntervalSince(range.lowerBound) / 86_400
        // A project started this morning has a history spanning zero days, which is true
        // and reads like a bug. Say what it means instead.
        if days < 1 { return "Today" }
        if days < 2 { return "1 day" }
        if days < 60 { return "\(Int(days)) days" }
        if days < 365 * 1.5 { return "\(Int((days / 30).rounded())) months" }
        return "\(Int((days / 365).rounded())) years"
    }
}

enum ActivityRange: String, CaseIterable, Identifiable {
    case sixMonths = "Last 6 months", year = "Last year", twoYears = "Last 2 years", all = "All time"
    var id: String { rawValue }
}

// MARK: - Cards

struct ProjectCard: View {
    let analysis: RepositoryAnalysis
    var body: some View {
        Card {
            HStack(spacing: Theme.Space.l) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 56, height: 56)
                    .background(Theme.accentWash, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(analysis.root.lastPathComponent).font(Theme.Text.title).foregroundStyle(Theme.ink)
                    Text(analysis.info.readmeSummary ?? "No README description found.")
                        .font(Theme.Text.body).foregroundStyle(Theme.inkSoft)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

struct RecentActivityCard: View {
    @EnvironmentObject private var model: AnalysisModel
    let commits: [Commit]
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                CardHeader(title: "Recent activity")
                // The connector between avatars is `maxHeight: .infinity`, so if this stack
                // is ever handed more height than it needs — a taller card beside it, a
                // stretching container — the extra goes into the gaps between commits and
                // five rows spread over half a screen. Pinning it to its ideal height keeps
                // the connector doing its job without letting it become the layout.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(commits.enumerated()), id: \.element.sha) { index, commit in
                        Button { model.selectedCommitSHA = commit.sha } label: {
                        HStack(alignment: .top, spacing: Theme.Space.m) {
                            VStack(spacing: 0) {
                                Avatar(name: commit.author, size: 26)
                                if index < commits.count - 1 {
                                    Rectangle().fill(Theme.hairline).frame(width: 1).frame(maxHeight: .infinity)
                                }
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(commit.subject.isEmpty ? "(no message)" : commit.subject)
                                    .font(Theme.Text.body).foregroundStyle(Theme.ink).lineLimit(1)
                                HStack(spacing: 6) {
                                    Text(commit.sha.prefix(7)).font(Theme.Text.mono).foregroundStyle(Theme.inkMuted)
                                    Text("· \(RiskExplanation.relative(commit.date, now: Date()))")
                                        .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                                }
                            }
                            .padding(.bottom, index < commits.count - 1 ? Theme.Space.m : 0)
                        }
                        .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu { CommitActions(commit: commit) }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                LinkButton(title: "See all commits →") { model.screen = .commits }
            }
        }
    }
}

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

struct TopHotspotsCard: View {
    @EnvironmentObject private var model: AnalysisModel
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                CardHeader(title: "Risk hotspots", subtitle: "\(model.rows.count.formatted()) functions ranked",
                           info: "Functions with the highest combination of complexity and recent change — where a "
                               + "bug is most likely hiding and where a small refactor pays off most.")
                if model.rows.isEmpty {
                    Text("No functions with history to rank.").font(Theme.Text.body).foregroundStyle(Theme.inkMuted)
                } else {
                    VStack(spacing: Theme.Space.s) {
                        ForEach(model.rows.prefix(4)) { row in
                            HotspotCard(row: row, compact: true, selected: model.selectedUnitID == row.id) {
                                model.selectedUnitID = row.id
                            }
                        }
                    }
                    LinkButton(title: "See all hotspots →") { model.screen = .hotspots }
                }
            }
        }
    }
}

struct QuickActionsCard: View {
    let analysis: RepositoryAnalysis
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                CardHeader(title: "Quick actions")
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Theme.Space.s) {
                    action("Open in Finder", "folder") { NSWorkspace.shared.activateFileViewerSelecting([analysis.root]) }
                    action("Open in Terminal", "terminal") {
                        NSWorkspace.shared.open([analysis.root], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                                configuration: NSWorkspace.OpenConfiguration())
                    }
                    if let web = analysis.info.remoteWebURL {
                        action("View on \(web.host ?? "web")", "globe") { NSWorkspace.shared.open(web) }
                    }
                    action("Copy path", "doc.on.clipboard") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(analysis.root.path, forType: .string)
                    }
                }
            }
        }
    }

    private func action(_ title: String, _ symbol: String, _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
                Text(title).font(Theme.Text.body).foregroundStyle(Theme.ink).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.m).padding(.vertical, 10)
            .background(Theme.wash, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

struct ContributorsCard: View {
    @EnvironmentObject private var model: AnalysisModel
    let contributors: [Contributor]
    let total: Int
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                CardHeader(title: "Contributors", subtitle: "\(contributors.count) people")
                VStack(spacing: Theme.Space.s) {
                    ForEach(contributors.prefix(4)) { person in
                        HStack(spacing: Theme.Space.s) {
                            Avatar(name: person.name, size: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(person.name).font(Theme.Text.body).foregroundStyle(Theme.ink).lineLimit(1)
                                Text("\(person.commits.formatted()) commits").font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                            }
                            Spacer()
                            InlineBar(fraction: person.share).frame(width: 70)
                            Text(person.share.sharePercent)
                                .font(Theme.Text.caption.monospacedDigit()).foregroundStyle(Theme.inkSoft).frame(width: 34, alignment: .trailing)
                        }
                    }
                    if contributors.count > 4 {
                        let rest = contributors.dropFirst(4)
                        HStack(spacing: Theme.Space.s) {
                            Text("+ \(rest.count) others").font(Theme.Text.body).foregroundStyle(Theme.inkSoft)
                            Spacer()
                            InlineBar(fraction: rest.map(\.share).reduce(0, +), tint: Theme.inkMuted).frame(width: 70)
                            Text(rest.map(\.share).reduce(0, +).sharePercent)
                                .font(Theme.Text.caption.monospacedDigit()).foregroundStyle(Theme.inkSoft).frame(width: 34, alignment: .trailing)
                        }
                    }
                }
                LinkButton(title: "See all →") { model.screen = .contributors }
            }
        }
    }
}

struct ActivityChartCard: View {
    let commits: [Commit]
    @Binding var range: ActivityRange

    private var buckets: [ActivityBucket] {
        let now = Date()
        let from: Date
        let granularity: ActivitySeries.Granularity
        switch range {
        case .sixMonths: from = now.addingTimeInterval(-182 * 86_400); granularity = .week
        case .year: from = now.addingTimeInterval(-365 * 86_400); granularity = .week
        case .twoYears: from = now.addingTimeInterval(-730 * 86_400); granularity = .month
        case .all: from = commits.map(\.date).min() ?? now; granularity = .month
        }
        return ActivitySeries.buckets(commits: commits, granularity: granularity, from: from, to: now)
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Activity over time").font(Theme.Text.heading).foregroundStyle(Theme.ink)
                        Text(range == .twoYears || range == .all ? "Commits per month" : "Commits per week")
                            .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                    }
                    Spacer()
                    Picker("", selection: $range) {
                        ForEach(ActivityRange.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().frame(width: 150)
                }
                ActivityBars(buckets: buckets, granularity: range == .twoYears || range == .all ? .month : .week).frame(height: 150)
            }
        }
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
                LinkButton(title: "See all →") { model.screen = .branches }
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
