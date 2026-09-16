import SwiftUI
import Charts
import GitViewCore
import GitViewParse

struct UnitDetailView: View {
    @EnvironmentObject private var model: AnalysisModel
    let unit: CodeUnit

    @State private var excerpt: SourceExcerpt?
    @State private var excerptError: String?

    private var row: RiskRow? { model.rowsByID[unit.id] }
    private var history: [UnitComplexityPoint]? { model.histories[unit.id] }
    private var isLoadingHistory: Bool { model.loadingHistories.contains(unit.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let row { metrics(row) }
                complexitySection
                // Commits before source: the commit list is the evidence behind the score,
                // while the source is reference material that also has an Open File button.
                commitsSection
                sourceSection
            }
            .padding(16)
        }
        .task(id: unit.id) {
            model.ensureHistory(for: unit)
            loadExcerpt()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(unit.name)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Text(unit.kind.rawValue)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                Text("\(unit.filePath):\(unit.lineRange.lowerBound)–\(unit.lineRange.upperBound)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
                Spacer()
                if let fileURL {
                    Button("Open File") { NSWorkspace.shared.open(fileURL) }
                        .controlSize(.small)
                        .help("Open in the default editor for .swift files")
                }
            }
        }
    }

    private var fileURL: URL? {
        model.analysis?.root.appendingPathComponent(unit.filePath)
    }

    // MARK: - Metrics

    private func metrics(_ row: RiskRow) -> some View {
        let columns = [GridItem(.adaptive(minimum: 92), spacing: 8)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            Metric("Score", row.score.formatted(.number.precision(.fractionLength(2))))
            Metric("Complexity", "\(row.complexity)")
            Metric("Nesting", "\(row.nestingDepth)")
            Metric("Lines", "\(row.lineCount)")
            Metric("Commits", "\(row.commitCount)")
            Metric("Authors", "\(row.authorCount)")
            Metric("Recency", row.recency.formatted(.number.precision(.fractionLength(2))))
            Metric("Last touched",
                   row.lastTouched.map { $0.formatted(.dateTime.year().month(.abbreviated).day()) } ?? "–")
        }
    }

    private struct Metric: View {
        let label: String
        let value: String
        init(_ label: String, _ value: String) { self.label = label; self.value = value }
        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.body.monospacedDigit()).fontWeight(.medium)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - Complexity over time

    @ViewBuilder
    private var complexitySection: some View {
        Section("Complexity over time") {
            if let history {
                let known = history.filter { $0.complexity != nil }.sorted { $0.date < $1.date }
                let missing = history.count - known.count
                if known.count >= 2 {
                    Chart(known) { point in
                        LineMark(
                            x: .value("Date", point.date),
                            y: .value("Complexity", point.complexity ?? 0)
                        )
                        // Complexity is piecewise constant: it changes at a commit and holds
                        // until the next one, which is what a stepped line says.
                        .interpolationMethod(.stepEnd)
                        PointMark(
                            x: .value("Date", point.date),
                            y: .value("Complexity", point.complexity ?? 0)
                        )
                        .symbolSize(point.isHead ? 60 : 30)
                        .foregroundStyle(point.isHead ? Color.accentColor : Color.secondary)
                    }
                    .chartYScale(domain: 0...Double((known.compactMap(\.complexity).max() ?? 1) + 2))
                    .chartYAxisLabel("complexity")
                    .frame(height: 150)
                } else {
                    Text("Not enough revisions to chart.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text(historyCaption(revisions: history.count - 1, missing: missing))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if isLoadingHistory {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Re-parsing the file at each revision…")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(height: 150)
            }
        }
    }

    private func historyCaption(revisions: Int, missing: Int) -> String {
        guard missing > 0 else { return "\(revisions) revisions touched this unit." }
        return "\(revisions) revisions attributed; in \(missing) the unit did not exist yet or "
             + "was not found. Those are commits whose changed lines have since drifted onto "
             + "this unit — they still count toward churn."
    }

    // MARK: - Source

    @ViewBuilder
    private var sourceSection: some View {
        Section("Source") {
            if let excerpt {
                SourceExcerptView(excerpt: excerpt, highlight: unit.lineRange)
            } else if let excerptError {
                Text(excerptError).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func loadExcerpt() {
        guard let fileURL else { return }
        do {
            excerpt = try SourceExcerpt.load(from: fileURL, around: unit.lineRange, context: 4)
        } catch {
            excerptError = "Could not read \(unit.filePath): \(error.localizedDescription)"
        }
    }

    // MARK: - Commits

    @ViewBuilder
    private var commitsSection: some View {
        if let churn = model.churn {
            let commits = churn.commits(for: unit)
            let bySHA = Dictionary(uniqueKeysWithValues: (history ?? []).map { ($0.sha, $0) })
            Section("Commits (\(commits.count))") {
                VStack(spacing: 0) {
                    ForEach(commits, id: \.sha) { commit in
                        CommitRow(commit: commit, point: bySHA[commit.sha], historyLoaded: history != nil)
                        if commit.sha != commits.last?.sha { Divider() }
                    }
                }
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private struct CommitRow: View {
        let commit: Commit
        let point: UnitComplexityPoint?
        let historyLoaded: Bool

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(commit.sha.prefix(7))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                VStack(alignment: .leading, spacing: 2) {
                    Text(commit.subject.isEmpty ? "(no subject)" : commit.subject)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("\(commit.author) · \(commit.date.formatted(.dateTime.year().month(.abbreviated).day()))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if historyLoaded {
                    if let complexity = point?.complexity {
                        Text("cx \(complexity)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(.orange)
                            .help("The unit was not found in the file at this revision — the "
                                  + "changed lines have since drifted onto it.")
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }
}

// MARK: - Section helper

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content
        }
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

    /// Loads `range` plus `context` lines either side. Tabs are widened for display only.
    static func load(from url: URL, around range: ClosedRange<Int>, context: Int) throws -> SourceExcerpt {
        let source = try String(contentsOf: url, encoding: .utf8)
        let all = source.split(separator: "\n", omittingEmptySubsequences: false)
        guard !all.isEmpty else { return SourceExcerpt(lines: []) }
        let lower = max(1, range.lowerBound - context)
        let upper = min(all.count, range.upperBound + context)
        guard lower <= upper else { return SourceExcerpt(lines: []) }
        let lines = (lower...upper).map { number in
            Line(number: number, text: all[number - 1].replacingOccurrences(of: "\t", with: "    "))
        }
        return SourceExcerpt(lines: lines)
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
                        Text("\(line.number)")
                            .frame(width: 44, alignment: .trailing)
                            .foregroundStyle(highlight.contains(line.number) ? .secondary : .tertiary)
                        Text(line.text.isEmpty ? " " : line.text)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.vertical, 1)
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(highlight.contains(line.number)
                                ? Color.accentColor.opacity(0.13) : Color.clear)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(height: min(CGFloat(excerpt.lines.count) * 17 + 12, 380))
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }
}
