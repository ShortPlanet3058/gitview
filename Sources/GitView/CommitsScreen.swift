import SwiftUI
import GitViewCore
import GitViewGit

struct CommitRefBadge: Hashable {
    enum Kind: Hashable { case head, localBranch, remoteBranch, tag }
    let label: String
    let kind: Kind
}

struct CommitsScreen: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(AppPreferences.self) private var preferences
    @Environment(\.staticRendering) private var staticRendering
    @State private var query = ""
    @State private var range: TimeRange = .all
    @State private var author: String = ""
    @State private var scope: Scope = .currentBranch
    @State private var allBranchesCommits: [Commit] = []
    @State private var loadingAllBranches = false
    @State private var limit = 300
    @State private var cachedTimeline: CachedTimeline?

    enum Scope: String, CaseIterable, Identifiable, Hashable {
        case currentBranch = "Current branch"
        case allBranches = "All branches"
        var id: String { rawValue }
    }

    enum TimeRange: String, CaseIterable, Identifiable, Hashable {
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

    private struct TimelineCacheKey: Equatable {
        let headSHA: String?
        let commitCount: Int
        let workingHeadSHA: String?
        let branches: [BranchInfo]
        let tags: [TagInfo]
        let query: String
        let range: TimeRange
        let author: String
        let scope: Scope
        let allBranchesCount: Int
        let limit: Int
        let advanced: Bool
    }

    private struct CachedTimeline {
        let key: TimelineCacheKey
        let filteredCount: Int
        let visibleSHAs: [String]
        let firstFilteredSHA: String?
        let grouped: [DayGroup]
        let isUnfiltered: Bool
        let graphBySHA: [String: CommitGraphRow]
        let visibleMaxLanes: Int
        let refsBySHA: [String: [CommitRefBadge]]
    }

    private static func makeCacheKey(
        analysis: RepositoryAnalysis?,
        query: String,
        range: TimeRange,
        author: String,
        scope: Scope,
        allBranchesCount: Int,
        limit: Int,
        advanced: Bool
    ) -> TimelineCacheKey {
        TimelineCacheKey(
            headSHA: analysis?.commits.first?.sha,
            commitCount: analysis?.commits.count ?? 0,
            workingHeadSHA: analysis?.workingState.headSHA,
            branches: analysis?.branches ?? [],
            tags: analysis?.tags ?? [],
            query: query,
            range: range,
            author: author,
            scope: scope,
            allBranchesCount: allBranchesCount,
            limit: limit,
            advanced: advanced
        )
    }

    private static func buildTimeline(
        analysis: RepositoryAnalysis?,
        allBranchesCommits: [Commit],
        key: TimelineCacheKey
    ) -> CachedTimeline {
        let sourceCommits: [Commit]
        if key.advanced && key.scope == .allBranches && !allBranchesCommits.isEmpty {
            sourceCommits = allBranchesCommits
        } else {
            sourceCommits = analysis?.commits ?? []
        }
        let q = key.query.trimmingCharacters(in: .whitespaces)
        let since = key.range.since
        let filtered = sourceCommits.filter { commit in
            if let since, commit.date < since { return false }
            if !key.author.isEmpty && commit.author != key.author { return false }
            if q.isEmpty { return true }
            return commit.subject.localizedCaseInsensitiveContains(q)
                || commit.author.localizedCaseInsensitiveContains(q)
                || (key.advanced && commit.sha.hasPrefix(q.lowercased()))
        }
        let visible = Array(filtered.prefix(key.limit))
        let grouped = groupByDay(visible)
        let isUnfiltered = q.isEmpty && key.author.isEmpty && key.range == .all
        let graphBySHA = (key.advanced && isUnfiltered) ? CommitGraphLayout.build(commits: visible) : [:]
        let visibleMaxLanes = max(min(graphBySHA.values.map(\.laneCount).max() ?? 1, 8), 1)
        let refsBySHA = key.advanced ? refBadges(for: analysis) : [:]
        return CachedTimeline(
            key: key,
            filteredCount: filtered.count,
            visibleSHAs: visible.map(\.sha),
            firstFilteredSHA: filtered.first?.sha,
            grouped: grouped,
            isUnfiltered: isUnfiltered && key.advanced,
            graphBySHA: graphBySHA,
            visibleMaxLanes: visibleMaxLanes,
            refsBySHA: refsBySHA
        )
    }

    private static func refBadges(for analysis: RepositoryAnalysis?) -> [String: [CommitRefBadge]] {
        guard let analysis else { return [:] }
        var map: [String: [CommitRefBadge]] = [:]
        if let headSHA = analysis.workingState.headSHA,
           !analysis.branches.contains(where: { $0.isCurrent && !$0.isRemote }) {
            map[headSHA, default: []].append(CommitRefBadge(label: "HEAD", kind: .head))
        }
        for branch in analysis.branches {
            let kind: CommitRefBadge.Kind = branch.isCurrent && !branch.isRemote
                ? .head : (branch.isRemote ? .remoteBranch : .localBranch)
            let label = branch.isRemote ? branch.checkoutTarget : branch.name
            map[branch.sha, default: []].append(CommitRefBadge(label: label, kind: kind))
        }
        for tag in analysis.tags {
            map[tag.commitSHA, default: []].append(CommitRefBadge(label: tag.name, kind: .tag))
        }
        return map
    }

    private var scopeTaskKey: String {
        let branchSignature = (session.analysis?.branches ?? [])
            .map { "\($0.name):\($0.sha)" }
            .joined(separator: "|")
        return "\(preferences.advanced):\(scope.rawValue):\(session.analysis?.workingState.headSHA ?? ""):\(branchSignature)"
    }

    var body: some View {
        let advanced = preferences.advanced
        let key = Self.makeCacheKey(
            analysis: session.analysis,
            query: query,
            range: range,
            author: author,
            scope: scope,
            allBranchesCount: allBranchesCommits.count,
            limit: limit,
            advanced: advanced
        )
        let timeline = (cachedTimeline?.key == key ? cachedTimeline : nil)
            ?? Self.buildTimeline(analysis: session.analysis, allBranchesCommits: allBranchesCommits, key: key)

        Page {
            HStack(alignment: .top) {
                ScreenHeader(
                    title: advanced ? "Commits" : "History",
                    subtitle: advanced
                        ? "Browse the project history and branch topology."
                        : "A timeline of changes saved to this repository."
                )
                Spacer()
                if advanced {
                    HStack(spacing: Theme.Space.s) {
                        if loadingAllBranches {
                            ProgressView().controlSize(.small)
                        }
                        SegmentPicker(
                            options: Scope.allCases.map { ($0, $0.rawValue) },
                            selection: $scope
                        )
                    }
                }
            }
            HStack(spacing: Theme.Space.m) {
                SearchField(text: $query,
                            prompt: advanced ? "Search commits, authors, or shas" : "Search changes or people",
                            focusTrigger: session.navigation.focusLocalFindRequest).frame(maxWidth: 340)
                if staticRendering {
                    staticFilterPill(range.rawValue, width: 130)
                    staticFilterPill(author.isEmpty ? "All authors" : author, width: 150)
                } else {
                    Picker("", selection: $range) { ForEach(TimeRange.allCases) { Text($0.rawValue).tag($0) } }
                        .labelsHidden().frame(width: 140)
                    Picker("", selection: $author) {
                        Text("All authors").tag("")
                        ForEach(session.contributors.prefix(30)) { Text($0.name).tag($0.name) }
                    }
                    .labelsHidden().frame(width: 180)
                }
                Spacer()
                Text("\(timeline.filteredCount.formatted()) \(advanced ? "commits" : "saved changes")")
                    .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
            }
            Card(padding: Theme.Space.s) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(timeline.grouped, id: \.day) { group in
                        Text(group.day.formatted(.dateTime.year().month(.abbreviated).day()))
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.inkMuted)
                            .padding(.horizontal, Theme.Space.m).padding(.top, Theme.Space.m).padding(.bottom, 4)
                        ForEach(group.commits, id: \.sha) { commit in
                            Button {
                                session.navigation.selectedCommitSHA = commit.sha
                                session.inspector.ensureCommitDetail(sha: commit.sha)
                            } label: {
                                CommitRowView(
                                    commit: commit,
                                    selected: session.navigation.selectedCommitSHA == commit.sha,
                                    graphRow: timeline.isUnfiltered ? timeline.graphBySHA[commit.sha] : nil,
                                    laneSlots: timeline.visibleMaxLanes,
                                    refs: timeline.refsBySHA[commit.sha] ?? [],
                                    showSHA: advanced
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if timeline.filteredCount > limit {
                        HStack {
                            Spacer()
                            Button("Show \(min(300, timeline.filteredCount - limit)) more") { limit += 300 }
                                .buttonStyle(SecondaryButtonStyle())
                            Spacer()
                        }
                        .padding(Theme.Space.m)
                    }
                    if timeline.filteredCount == 0 {
                        Text("No commits match.").font(Theme.Text.body).foregroundStyle(Theme.inkMuted).padding(Theme.Space.l)
                    }
                }
            }
        }
        .onAppear { cachedTimeline = timeline }
        .onChange(of: key) { _, newKey in
            cachedTimeline = Self.buildTimeline(analysis: session.analysis, allBranchesCommits: allBranchesCommits, key: newKey)
        }
        .task(id: scopeTaskKey) {
            guard preferences.advanced, scope == .allBranches, let root = session.analysis?.root else {
                loadingAllBranches = false
                return
            }
            loadingAllBranches = true
            let loaded = await Task.detached(priority: .userInitiated) {
                (try? GitRepository(url: root).loadAllBranchesCommits(limit: 600)) ?? []
            }.value
            guard !Task.isCancelled else { return }
            allBranchesCommits = loaded
            loadingAllBranches = false
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.downArrow) {
            let next = NavigationStore.stepSelection(
                in: timeline.visibleSHAs, current: session.navigation.selectedCommitSHA, delta: 1)
            session.navigation.selectedCommitSHA = next
            if let next { session.inspector.ensureCommitDetail(sha: next) }
            return .handled
        }
        .onKeyPress(.upArrow) {
            let prev = NavigationStore.stepSelection(
                in: timeline.visibleSHAs, current: session.navigation.selectedCommitSHA, delta: -1)
            session.navigation.selectedCommitSHA = prev
            if let prev { session.inspector.ensureCommitDetail(sha: prev) }
            return .handled
        }
        .onKeyPress(.return) {
            if session.navigation.selectedCommitSHA == nil, let first = timeline.firstFilteredSHA {
                session.navigation.selectedCommitSHA = first
                session.inspector.ensureCommitDetail(sha: first)
                return .handled
            }
            return .ignored
        }
    }

    private func staticFilterPill(_ title: String, width: CGFloat) -> some View {
        HStack(spacing: 6) {
            Text(title).font(Theme.Text.body).foregroundStyle(Theme.ink).lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.inkMuted)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(width: width)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.hairline))
    }

    struct DayGroup { let day: Date; let commits: [Commit] }
    static func groupByDay(_ commits: [Commit]) -> [DayGroup] {
        let calendar = Calendar.current
        var groups: [DayGroup] = []
        var currentDay: Date?
        var bucket: [Commit] = []
        for commit in commits {
            let day = calendar.startOfDay(for: commit.date)
            if currentDay == day {
                bucket.append(commit)
            } else {
                if let prev = currentDay {
                    groups.append(DayGroup(day: prev, commits: bucket))
                }
                currentDay = day
                bucket = [commit]
            }
        }
        if let lastDay = currentDay {
            groups.append(DayGroup(day: lastDay, commits: bucket))
        }
        return groups
    }
}

struct CommitRowView: View {
    let commit: Commit
    var selected = false
    var graphRow: CommitGraphRow? = nil
    var laneSlots: Int = 1
    var refs: [CommitRefBadge] = []
    var showSHA = true
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            if let graphRow {
                CommitSwimlaneGutter(row: graphRow)
                    .frame(width: CGFloat(max(laneSlots, 1)) * 12 + 6)
                    .frame(maxHeight: .infinity)
            }
            HStack(alignment: .center, spacing: Theme.Space.m) {
                Avatar(name: commit.author, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(commit.subject.isEmpty ? "(no message)" : commit.subject)
                            .font(Theme.Text.body).foregroundStyle(Theme.ink).lineLimit(1)
                        if !refs.isEmpty {
                            ForEach(Array(refs.prefix(3)), id: \.self) { badge in
                                CommitRefPill(badge: badge)
                            }
                            if refs.count > 3 {
                                Chip(text: "+\(refs.count - 3)")
                            }
                        }
                    }
                    Text("\(commit.author) · \(RiskExplanation.relative(commit.date, now: Date()))"
                         + (commit.fileChanges.isEmpty ? "" : " · \(commit.fileChanges.count) file\(commit.fileChanges.count == 1 ? "" : "s")"))
                        .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                }
                Spacer()
                if showSHA {
                    ShaChip(sha: commit.sha)
                }
            }
            .padding(.vertical, 8)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, Theme.Space.m)
        .background(selected ? Theme.accentWash : (hovering ? Theme.wash : .clear),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contextMenu { CommitActions(commit: commit) }
    }
}

private struct CommitRefPill: View {
    let badge: CommitRefBadge

    private var icon: String {
        switch badge.kind {
        case .head, .localBranch, .remoteBranch: return "arrow.triangle.branch"
        case .tag: return "tag.fill"
        }
    }

    private var foreground: Color {
        switch badge.kind {
        case .head: return Theme.accent
        case .localBranch: return Theme.good
        case .remoteBranch: return Theme.inkSoft
        case .tag: return Theme.tint(.violet)
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8, weight: .semibold))
            Text(badge.label).font(.system(size: 10, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(foreground.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
    }
}

private struct CommitSwimlaneGutter: View {
    let row: CommitGraphRow

    private func laneX(_ lane: Int) -> CGFloat {
        8 + CGFloat(lane) * 12
    }

    private func laneColor(_ lane: Int) -> Color {
        let palette = Theme.avatarTints
        return Theme.tint(palette[abs(lane) % palette.count])
    }

    var body: some View {
        Canvas { context, size in
            let midY = size.height / 2

            for seg in row.upperSegments {
                let start = CGPoint(x: laneX(seg.fromLane), y: 0)
                let end = CGPoint(x: laneX(seg.toLane), y: midY)
                var path = Path()
                path.move(to: start)
                if seg.fromLane == seg.toLane {
                    path.addLine(to: end)
                } else {
                    path.addCurve(
                        to: end,
                        control1: CGPoint(x: start.x, y: midY * 0.55),
                        control2: CGPoint(x: end.x, y: midY * 0.45)
                    )
                }
                context.stroke(path, with: .color(laneColor(seg.colorIndex).opacity(0.85)),
                               style: StrokeStyle(lineWidth: 1.75, lineCap: .round))
            }

            for seg in row.lowerSegments {
                let start = CGPoint(x: laneX(seg.fromLane), y: midY)
                let end = CGPoint(x: laneX(seg.toLane), y: size.height)
                var path = Path()
                path.move(to: start)
                if seg.fromLane == seg.toLane {
                    path.addLine(to: end)
                } else {
                    path.addCurve(
                        to: end,
                        control1: CGPoint(x: start.x, y: midY + (size.height - midY) * 0.45),
                        control2: CGPoint(x: end.x, y: midY + (size.height - midY) * 0.55)
                    )
                }
                context.stroke(path, with: .color(laneColor(seg.colorIndex).opacity(0.85)),
                               style: StrokeStyle(lineWidth: 1.75, lineCap: .round))
            }

            let center = CGPoint(x: laneX(row.nodeLane), y: midY)
            let radius: CGFloat = row.isMerge ? 4.5 : 3.5
            let circleRect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            let nodeColor = laneColor(row.nodeLane)
            context.fill(Path(ellipseIn: circleRect.insetBy(dx: -1.5, dy: -1.5)), with: .color(Theme.surface))
            if row.isMerge {
                context.stroke(Path(ellipseIn: circleRect), with: .color(nodeColor), lineWidth: 2)
            } else {
                context.fill(Path(ellipseIn: circleRect), with: .color(nodeColor))
            }
        }
    }
}
