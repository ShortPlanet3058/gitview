import SwiftUI
import GitViewCore

struct CommitsScreen: View {
    @EnvironmentObject private var model: AnalysisModel
    @State private var query = ""
    @State private var range: TimeRange = .all
    @State private var author: String = ""
    @State private var limit = 300

    enum TimeRange: String, CaseIterable, Identifiable {
        case all = "All time", year = "Last year", sixMonths = "Last 6 months", month = "Last 30 days"
        var id: String { rawValue }
        var since: Date? {
            switch self {
            case .all: return nil
            case .year: return Date().addingTimeInterval(-365 * 86_400)
            case .sixMonths: return Date().addingTimeInterval(-182 * 86_400)
            case .month: return Date().addingTimeInterval(-30 * 86_400)
            }
        }
    }

    private var filtered: [Commit] {
        guard let commits = model.analysis?.commits else { return [] }
        let q = query.trimmingCharacters(in: .whitespaces)
        return commits.filter { commit in
            if let since = range.since, commit.date < since { return false }
            if !author.isEmpty && commit.author != author { return false }
            if q.isEmpty { return true }
            return commit.subject.localizedCaseInsensitiveContains(q)
                || commit.author.localizedCaseInsensitiveContains(q)
                || commit.sha.hasPrefix(q.lowercased())
        }
    }

    var body: some View {
        let commits = filtered
        let grouped = Self.groupByDay(Array(commits.prefix(limit)))
        Page {
            ScreenHeader(title: "Commits", subtitle: "Browse the project history.")
            HStack(spacing: Theme.Space.m) {
                SearchField(text: $query, prompt: "Search commits, authors, or shas").frame(maxWidth: 340)
                Picker("", selection: $range) { ForEach(TimeRange.allCases) { Text($0.rawValue).tag($0) } }
                    .labelsHidden().frame(width: 140)
                Picker("", selection: $author) {
                    Text("All authors").tag("")
                    ForEach(model.contributors.prefix(30)) { Text($0.name).tag($0.name) }
                }
                .labelsHidden().frame(width: 180)
                Spacer()
                Text("\(commits.count.formatted()) commits").font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
            }
            Card(padding: Theme.Space.s) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(grouped, id: \.day) { group in
                        Text(group.day.formatted(.dateTime.year().month(.abbreviated).day()))
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.inkMuted)
                            .padding(.horizontal, Theme.Space.m).padding(.top, Theme.Space.m).padding(.bottom, 4)
                        ForEach(group.commits, id: \.sha) { commit in
                            Button { model.selectedCommitSHA = commit.sha } label: {
                                CommitRowView(commit: commit, selected: model.selectedCommitSHA == commit.sha)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if commits.count > limit {
                        HStack {
                            Spacer()
                            Button("Show \(min(300, commits.count - limit)) more") { limit += 300 }
                                .buttonStyle(SecondaryButtonStyle())
                            Spacer()
                        }
                        .padding(Theme.Space.m)
                    }
                    if commits.isEmpty {
                        Text("No commits match.").font(Theme.Text.body).foregroundStyle(Theme.inkMuted).padding(Theme.Space.l)
                    }
                }
            }
        }
    }

    struct DayGroup { let day: Date; let commits: [Commit] }
    static func groupByDay(_ commits: [Commit]) -> [DayGroup] {
        let calendar = Calendar.current
        var groups: [DayGroup] = []
        for commit in commits {
            let day = calendar.startOfDay(for: commit.date)
            if let last = groups.last, last.day == day {
                groups[groups.count - 1] = DayGroup(day: day, commits: last.commits + [commit])
            } else {
                groups.append(DayGroup(day: day, commits: [commit]))
            }
        }
        return groups
    }
}

struct CommitRowView: View {
    let commit: Commit
    var selected = false
    @State private var hovering = false
    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            Avatar(name: commit.author, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(commit.subject.isEmpty ? "(no message)" : commit.subject)
                    .font(Theme.Text.body).foregroundStyle(Theme.ink).lineLimit(1)
                Text("\(commit.author) · \(RiskExplanation.relative(commit.date, now: Date()))"
                     + (commit.fileChanges.isEmpty ? "" : " · \(commit.fileChanges.count) file\(commit.fileChanges.count == 1 ? "" : "s")"))
                    .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
            }
            Spacer()
            ShaChip(sha: commit.sha)
        }
        .padding(.horizontal, Theme.Space.m).padding(.vertical, 8)
        .background(selected ? Theme.accentWash : (hovering ? Theme.wash : .clear),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy SHA") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(commit.sha, forType: .string) }
        }
    }
}
