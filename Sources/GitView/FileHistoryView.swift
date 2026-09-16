import SwiftUI
import Charts
import GitViewCore
import GitViewGit

/// One file's life: every commit that touched it, following renames, each opening its diff.
struct FileHistoryView: View {
    @EnvironmentObject private var model: AnalysisModel
    let path: String

    private var entries: [FileHistoryEntry] { model.fileHistory }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.hairline).frame(height: 1)
            if model.fileHistoryInFlight && entries.isEmpty {
                VStack(spacing: Theme.Space.s) {
                    ProgressView().controlSize(.small)
                    Text("Reading this file's history…").font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                VStack(spacing: Theme.Space.s) {
                    Text("No history").font(Theme.Text.heading).foregroundStyle(Theme.ink)
                    Text("Nothing in this repository's history has touched this path.")
                        .font(Theme.Text.body).foregroundStyle(Theme.inkSoft)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollColumn {
                    VStack(alignment: .leading, spacing: Theme.Space.l) {
                        churnCard
                        timeline
                    }
                    .padding(.horizontal, Theme.Space.xl)
                    .padding(.top, Theme.Space.l)
                    .padding(.bottom, Theme.Space.xxl)
                    .frame(maxWidth: 1080, alignment: .leading)
                }
            }
        }
        .background(Theme.page)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Button { model.closeFileHistory() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                        Text("Back")
                    }
                    .font(Theme.Text.body).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                Spacer()
                if !entries.isEmpty {
                    Text("+\(entries.reduce(0) { $0 + $1.insertions })")
                        .font(Theme.Text.caption.monospacedDigit()).foregroundStyle(Theme.good)
                    Text("−\(entries.reduce(0) { $0 + $1.deletions })")
                        .font(Theme.Text.caption.monospacedDigit()).foregroundStyle(Theme.critical)
                }
            }
            Text(path).font(Theme.Text.title).foregroundStyle(Theme.ink)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Text(subtitle).font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
        }
        .padding(.horizontal, Theme.Space.xl).padding(.top, Theme.Space.xl).padding(.bottom, Theme.Space.m)
    }

    private var subtitle: String {
        guard !entries.isEmpty else { return "" }
        let people = Set(entries.map(\.commit.author)).count
        // When the history is capped, the count and the earliest date are both about what
        // was read, not about the file — so say that rather than implying a total.
        var text = model.fileHistoryTruncated
            ? "most recent \(entries.count) commits, by \(people) \(people == 1 ? "person" : "people")"
            : "\(entries.count) commit\(entries.count == 1 ? "" : "s") by "
              + "\(people) \(people == 1 ? "person" : "people")"
        if !model.fileHistoryTruncated, let oldest = entries.last?.commit.date {
            text += ", since \(oldest.formatted(.dateTime.year().month(.abbreviated)))"
        }
        if entries.contains(where: \.isRename) { text += " · renamed along the way" }
        return text
    }

    /// Lines changed per commit, oldest first — where a file was rewritten shows up as a spike.
    private var churnCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                CardHeader(title: "Lines changed over time",
                           info: "Insertions plus deletions per commit. A tall bar is a rewrite; a long flat "
                               + "stretch means the file was left alone.")
                Chart(entries.reversed()) { entry in
                    BarMark(x: .value("When", entry.commit.date, unit: .day),
                            y: .value("Lines", entry.churn))
                        .foregroundStyle(entry.isRename ? Theme.tint(.violet) : Theme.accent)
                }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                    AxisValueLabel(format: .dateTime.year().month(.abbreviated)).foregroundStyle(Theme.inkMuted) } }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(Theme.gridline)
                    AxisValueLabel().foregroundStyle(Theme.inkMuted) } }
                .frame(height: 120)
            }
        }
    }

    private var timeline: some View {
        Card(padding: Theme.Space.s) {
            VStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    Button {
                        // The path as of that commit, so an old revision resolves correctly.
                        model.showDiff(.commit(sha: entry.commit.sha), path: entry.path,
                                       title: entry.commit.subject)
                    } label: {
                        HStack(alignment: .top, spacing: Theme.Space.m) {
                            VStack(spacing: 0) {
                                Avatar(name: entry.commit.author, size: 26)
                                if index < entries.count - 1 {
                                    Rectangle().fill(Theme.hairline).frame(width: 1).frame(maxHeight: .infinity)
                                }
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.commit.subject.isEmpty ? "(no message)" : entry.commit.subject)
                                    .font(Theme.Text.body).foregroundStyle(Theme.ink).lineLimit(1)
                                HStack(spacing: 6) {
                                    Text("\(entry.commit.author) · \(RiskExplanation.relative(entry.commit.date, now: Date()))")
                                        .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                                    if entry.isRename, let previous = entry.previousPath {
                                        Chip(text: "renamed from \((previous as NSString).lastPathComponent)",
                                             tint: Theme.tint(.violet))
                                    }
                                }
                            }
                            .padding(.bottom, index < entries.count - 1 ? Theme.Space.m : 0)
                            Spacer(minLength: Theme.Space.m)
                            if entry.isBinary {
                                Text("binary").font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                            } else {
                                Text("+\(entry.insertions)").font(Theme.Text.caption.monospacedDigit())
                                    .foregroundStyle(Theme.good)
                                Text("−\(entry.deletions)").font(Theme.Text.caption.monospacedDigit())
                                    .foregroundStyle(Theme.critical)
                            }
                            ShaChip(sha: entry.commit.sha)
                        }
                        .padding(.horizontal, Theme.Space.m).padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
