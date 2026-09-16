import SwiftUI
import Charts
import GitViewCore
import GitViewParse

struct UnitDetailPanel: View {
    @EnvironmentObject private var model: AnalysisModel
    let unit: CodeUnit
    let row: RiskRow

    @State private var excerpt: SourceExcerpt?
    @State private var excerptError: String?

    private var history: [UnitComplexityPoint]? { model.histories[unit.id] }
    private var isLoadingHistory: Bool { model.loadingHistories.contains(unit.id) }
    private var fileURL: URL? { model.analysis?.root.appendingPathComponent(unit.filePath) }

    var body: some View {
        VStack(spacing: 0) {
            panelHeader
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    why
                    complexityCard
                    if model.advanced { rawMetrics }
                    commitsCard
                    sourceCard
                }
                .padding(Theme.Space.l)
            }
        }
        .background(Theme.surface)
        .task(id: unit.id) {
            model.ensureHistory(for: unit)
            loadExcerpt()
        }
    }

    // MARK: Header

    private var panelHeader: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .top) {
                RiskBadge(level: row.level)
                Spacer()
                Button { model.selectedUnitID = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.inkMuted)
                        .padding(6).background(Theme.wash, in: Circle())
                }
                .buttonStyle(.plain).help("Close")
            }
            Text(unit.name).font(Theme.Text.title).foregroundStyle(Theme.ink)
                .lineLimit(3).textSelection(.enabled)
            HStack(spacing: Theme.Space.s) {
                Chip(text: unit.kind.rawValue)
                Text("\(unit.filePath):\(unit.lineRange.lowerBound)–\(unit.lineRange.upperBound)")
                    .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                    .lineLimit(1).truncationMode(.head).textSelection(.enabled)
                Spacer()
                if let fileURL {
                    Button("Open file") { NSWorkspace.shared.open(fileURL) }
                        .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                }
            }
        }
        .padding(Theme.Space.l)
        .padding(.top, Theme.Space.xl)
        .background(Theme.raised)
        .overlay(alignment: .bottom) { HairlineDivider() }
    }

    // MARK: Why

    private var why: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(row.explanation.headline).font(Theme.Text.heading).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(row.explanation.reasons, id: \.self) { reason in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle().fill(Theme.inkMuted).frame(width: 4, height: 4).padding(.top, 5)
                        Text(reason).font(Theme.Text.body).foregroundStyle(Theme.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: Complexity over time

    private var complexityCard: some View {
        Card(padding: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                CardHeader(title: "How it grew",
                           info: "Complexity of this function at each commit that touched it. A rising line "
                               + "means it has been accumulating branches and special cases over time.")
                if let history {
                    let known = history.filter { $0.complexity != nil }.sorted { $0.date < $1.date }
                    let missing = history.count - known.count
                    if known.count >= 2 {
                        Chart(known) { point in
                            LineMark(x: .value("Date", point.date), y: .value("Complexity", point.complexity ?? 0))
                                .interpolationMethod(.stepEnd)
                                .lineStyle(StrokeStyle(lineWidth: 2))
                                .foregroundStyle(Theme.accent)
                            PointMark(x: .value("Date", point.date), y: .value("Complexity", point.complexity ?? 0))
                                .symbolSize(point.isHead ? 56 : 26)
                                .foregroundStyle(point.isHead ? Theme.accent : Theme.accentSoft)
                        }
                        .chartYScale(domain: 0...Double((known.compactMap(\.complexity).max() ?? 1) + 2))
                        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                            AxisGridLine().foregroundStyle(Theme.gridline); AxisValueLabel().foregroundStyle(Theme.inkMuted) } }
                        .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                            AxisGridLine().foregroundStyle(Theme.gridline); AxisValueLabel().foregroundStyle(Theme.inkMuted) } }
                        .frame(height: 130)
                    } else {
                        Text("Not enough history to draw a line.").font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                    }
                    Text(caption(revisions: history.count - 1, missing: missing))
                        .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                } else if isLoadingHistory {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading this function at each past commit…").font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                    }
                    .frame(height: 130)
                }
            }
        }
    }

    private func caption(revisions: Int, missing: Int) -> String {
        guard missing > 0 else { return "\(revisions) commits touched this function." }
        return "\(revisions) commits are counted; in \(missing) of them the function did not exist yet "
             + "(the file changed around where it now lives)."
    }

    // MARK: Raw metrics (advanced)

    private var rawMetrics: some View {
        Card(padding: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                CardHeader(title: "Metrics")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], alignment: .leading, spacing: 8) {
                    metric("Score", row.score.formatted(.number.precision(.fractionLength(2))))
                    metric("Complexity", "\(row.complexity)")
                    metric("Nesting", "\(row.nestingDepth)")
                    metric("Lines", "\(row.lineCount)")
                    metric("Commits", "\(row.commitCount)")
                    metric("Last year", "\(row.recentCommits)")
                    metric("Authors", "\(row.authorCount)")
                    metric("Recency", row.recency.formatted(.number.precision(.fractionLength(2))))
                }
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 10)).foregroundStyle(Theme.inkMuted)
            Text(value).font(Theme.Text.bodyBold.monospacedDigit()).foregroundStyle(Theme.ink)
        }
    }

    // MARK: Commits

    private var commitsCard: some View {
        Card(padding: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if let churn = model.churn {
                    let commits = churn.commits(for: unit)
                    let bySHA = Dictionary(uniqueKeysWithValues: (history ?? []).map { ($0.sha, $0) })
                    CardHeader(title: "Changes", subtitle: "\(commits.count) commits")
                    VStack(spacing: 0) {
                        ForEach(commits.prefix(40), id: \.sha) { commit in
                            CommitLine(commit: commit, point: bySHA[commit.sha], historyLoaded: history != nil)
                            if commit.sha != commits.prefix(40).last?.sha { HairlineDivider() }
                        }
                    }
                    if commits.count > 40 {
                        Text("and \(commits.count - 40) older…").font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                    }
                }
            }
        }
    }

    // MARK: Source

    private var sourceCard: some View {
        Card(padding: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                CardHeader(title: "Source", subtitle: "\(unit.lineCount) lines")
                if let excerpt {
                    SourceExcerptView(excerpt: excerpt, highlight: unit.lineRange)
                } else if let excerptError {
                    Text(excerptError).font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                }
            }
        }
    }

    private func loadExcerpt() {
        guard let fileURL else { return }
        do { excerpt = try SourceExcerpt.load(from: fileURL, around: unit.lineRange, context: 3) }
        catch { excerptError = "Could not read \(unit.filePath): \(error.localizedDescription)" }
    }
}

struct CommitLine: View {
    let commit: Commit
    let point: UnitComplexityPoint?
    let historyLoaded: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(commit.sha.prefix(7)).font(Theme.Text.mono).foregroundStyle(Theme.inkMuted)
            VStack(alignment: .leading, spacing: 1) {
                Text(commit.subject.isEmpty ? "(no message)" : commit.subject)
                    .font(Theme.Text.body).foregroundStyle(Theme.ink).lineLimit(1)
                Text("\(commit.author) · \(RiskExplanation.relative(commit.date, now: Date()))")
                    .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
            }
            Spacer(minLength: 4)
            if historyLoaded {
                if let complexity = point?.complexity {
                    Text("cx \(complexity)").font(Theme.Text.caption.monospacedDigit()).foregroundStyle(Theme.inkMuted)
                } else {
                    Image(systemName: "questionmark.circle").font(.system(size: 11)).foregroundStyle(Theme.warning)
                        .help("The function did not exist in the file at this commit; the change was nearby.")
                }
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Source excerpt

struct SourceExcerpt {
    struct Line: Identifiable {
        var id: Int { number }
        let number: Int
        let text: String
    }
    let lines: [Line]

    static func load(from url: URL, around range: ClosedRange<Int>, context: Int) throws -> SourceExcerpt {
        let source = try String(contentsOf: url, encoding: .utf8)
        let all = source.split(separator: "\n", omittingEmptySubsequences: false)
        guard !all.isEmpty else { return SourceExcerpt(lines: []) }
        let lower = max(1, range.lowerBound - context)
        let upper = min(all.count, range.upperBound + context)
        guard lower <= upper else { return SourceExcerpt(lines: []) }
        return SourceExcerpt(lines: (lower...upper).map {
            Line(number: $0, text: all[$0 - 1].replacingOccurrences(of: "\t", with: "    "))
        })
    }
}

struct SourceExcerptView: View {
    let excerpt: SourceExcerpt
    let highlight: ClosedRange<Int>

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(excerpt.lines) { line in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(line.number)").frame(width: 40, alignment: .trailing)
                            .foregroundStyle(highlight.contains(line.number) ? Theme.inkSoft : Theme.inkMuted.opacity(0.6))
                        Text(line.text.isEmpty ? " " : line.text).fixedSize(horizontal: true, vertical: false)
                            .foregroundStyle(highlight.contains(line.number) ? Theme.ink : Theme.inkSoft)
                    }
                    .font(Theme.Text.mono)
                    .padding(.vertical, 1).padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(highlight.contains(line.number) ? Theme.accentWash : Color.clear)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(height: min(CGFloat(excerpt.lines.count) * 17 + 12, 320))
        .background(Theme.page, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }
}
