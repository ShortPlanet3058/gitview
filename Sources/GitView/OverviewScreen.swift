import SwiftUI
import GitViewCore
import GitViewGit
import GitViewParse

/// The dashboard: everything worth knowing at a glance, on one screen, without scrolling.
///
/// Two rules shape it, and they are what the previous version got wrong.
///
/// **The grid decides the sizes, never the content.** Cards that grew to fit whatever they
/// held meant every repository produced a different, lopsided layout — a project with a long
/// README pushed the numbers off the bottom, one with three branches left a hole. Here the
/// rows are measured from the window and each tile is handed its height; a tile with more to
/// say shows less of it rather than growing.
///
/// **Nothing scrolls.** A dashboard you have to scroll is a page, and a page cannot be read
/// at a glance. So the dashboard shows the shape of each thing and nothing more, and every
/// tile is a door: click it and the tab it belongs to has the whole story. That is the trade
/// it makes — less detail here, one click to all of it.
struct OverviewScreen: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(AppPreferences.self) private var preferences

    private let gap = Theme.Space.m

    var body: some View {
        if let analysis = session.analysis {
            GeometryReader { geometry in
                // Rows are proportional, so the dashboard fills a tall window, and each has
                // a height it would rather not go below. Those minimums can add up to more
                // than a short window has — at the smallest size the app allows they asked
                // for 428 points of a 384-point space, and the rows drew over each other.
                // So they are wishes, not floors: when they do not fit, everything shrinks
                // by the same factor and the layout stays in proportion. Nothing scrolls,
                // and nothing lands on top of anything else.
                let available = geometry.size.height - Self.headerHeight - gap * 4
                    - Theme.Space.l * 2
                let layout = Self.rows(in: available)
                let narrow = geometry.size.width < 820
                let hero = layout.hero
                let numbers = layout.numbers
                let languages = layout.languages
                let bottom = layout.bottom

                // `.clipped()` on every row, and it is not decoration. A `frame(height:)`
                // whose content wants more room does not shrink the content — it centres it,
                // so an overfull tile bleeds out of the top *and* bottom of its slot and
                // draws over its neighbours. Clipping each row keeps a tile inside the space
                // the grid gave it; the tile shows less rather than trespassing.
                VStack(spacing: gap) {
                    header(analysis)
                    heroRow(analysis, compact: layout.isCompact, narrow: narrow)
                        .frame(height: hero, alignment: .top).clipped()
                    numbersRow(analysis, narrow: narrow).frame(height: numbers, alignment: .top).clipped()
                    LanguageStrip(inventory: analysis.info.inventory)
                        .frame(height: languages, alignment: .top).clipped()
                    bottomRow(analysis, compact: layout.isCompact, narrow: narrow, bottomHeight: bottom)
                        .frame(height: bottom, alignment: .top).clipped()
                }
                .padding(.horizontal, Theme.Space.xl)
                .padding(.vertical, Theme.Space.l)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private static let headerHeight: CGFloat = 46

    struct RowHeights {
        let hero, numbers, languages, bottom: CGFloat
        /// True when the window is short enough that the tiles must show fewer rows. Cutting
        /// a list from four entries to two is a real answer to a short window; scaling type
        /// down until it cannot be read is not.
        let isCompact: Bool
    }

    /// Splits `available` between the four rows, shrinking all of them together rather than
    /// letting the preferred minimums overflow a short window.
    static func rows(in available: CGFloat) -> RowHeights {
        let hero = min(max(available * 0.36, 158), 248)
        let numbers: CGFloat = 82
        let languages: CGFloat = 52
        let bottom = max(available - hero - numbers - languages, 136)
        let wanted = hero + numbers + languages + bottom
        let scale = wanted > available && wanted > 0 ? available / wanted : 1
        return RowHeights(hero: hero * scale, numbers: numbers * scale,
                          languages: languages * scale, bottom: bottom * scale,
                          isCompact: scale < 1)
    }

    private func header(_ analysis: RepositoryAnalysis) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            Text("Overview").font(Theme.Text.display).foregroundStyle(Theme.ink)
            // The project's own description, where the Project card used to be. It is one
            // line of context, not a card's worth of screen.
            if let summary = analysis.info.readmeSummary, !summary.isEmpty {
                Text(summary)
                    .font(Theme.Text.body).foregroundStyle(Theme.inkMuted)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .frame(height: Self.headerHeight, alignment: .bottom)
    }

    // MARK: - Rows

    private func heroRow(_ analysis: RepositoryAnalysis, compact: Bool, narrow: Bool) -> some View {
        HStack(spacing: narrow ? Theme.Space.s : gap) {
            CatchUpTile(limit: compact ? 2 : 3).frame(maxWidth: .infinity)
            WorkingCopyTile(state: analysis.workingState, compact: compact)
                .frame(width: narrow ? 250 : 340)
        }
    }

    private func numbersRow(_ analysis: RepositoryAnalysis, narrow: Bool) -> some View {
        let metrics = session.overviewMetrics
        let advanced = preferences.advanced
        return HStack(spacing: narrow ? Theme.Space.s : gap) {
            NumberTile(icon: "clock.arrow.circlepath", tint: .blue, destination: .commits,
                       value: session.readiness.hasHistory ? analysis.commits.count.formatted() : "—",
                       label: advanced ? "Commits" : "History",
                       detail: narrow ? nil : commitsThisMonth(metrics))
            NumberTile(icon: "person.2", tint: .aqua, destination: .contributors,
                       value: session.readiness.hasHistory ? session.contributors.count.formatted() : "—",
                       label: advanced ? (session.contributors.count == 1 ? "Contributor" : "Contributors") : "People",
                       detail: narrow ? nil : activePeople(metrics))
            NumberTile(icon: "doc.text.fill", tint: .orange, destination: .files,
                       value: analysis.info.inventory.fileCount.formatted(),
                       label: "Files", detail: narrow ? nil : analysis.info.inventory.totalBytes.byteString)
            NumberTile(icon: "arrow.triangle.branch", tint: .violet, destination: .branches,
                       value: metrics.localBranchCount.formatted(),
                       label: metrics.localBranchCount == 1 ? "Branch" : "Branches",
                       detail: (narrow || !advanced) ? nil : (metrics.remoteBranchCount > 0
                           ? "\(metrics.remoteBranchCount) on the remote" : nil))
            if advanced {
                NumberTile(icon: "tag", tint: .yellow, destination: .releases,
                           value: analysis.tags.count.formatted(),
                           label: analysis.tags.count == 1 ? "Release" : "Releases",
                           detail: narrow ? nil : unreleasedDetail())
            }
        }
    }

    private func bottomRow(_ analysis: RepositoryAnalysis, compact: Bool, narrow: Bool, bottomHeight: CGFloat) -> some View {
        let showHealthDetails = bottomHeight >= 255
        return HStack(spacing: narrow ? Theme.Space.s : gap) {
            if preferences.advanced {
                HealthTile(checks: compact ? 1 : 3, showRowDetails: showHealthDetails).frame(maxWidth: .infinity)
                HotspotsTile(limit: compact ? 2 : 4).frame(maxWidth: .infinity)
                ActivityTile().frame(maxWidth: .infinity)
            } else {
                RecentHistoryTile(limit: compact ? 3 : 5).frame(maxWidth: .infinity)
                HealthTile(checks: compact ? 1 : 3, showRowDetails: showHealthDetails).frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Small derivations

    private func commitsThisMonth(_ metrics: WorkspaceSession.OverviewMetrics) -> String? {
        guard session.readiness.hasHistory else { return nil }
        return metrics.commitsLast30Days == 0 ? "none in 30 days" : "+\(metrics.commitsLast30Days) in 30 days"
    }

    private func activePeople(_ metrics: WorkspaceSession.OverviewMetrics) -> String? {
        guard session.readiness.hasHistory else { return nil }
        return metrics.activeAuthorsLast90Days == 0 ? "none in 90 days" : "\(metrics.activeAuthorsLast90Days) active"
    }

    private func unreleasedDetail() -> String? {
        guard let unreleased = session.unreleasedCount else { return nil }
        return unreleased == 0 ? "nothing unreleased" : "\(unreleased) unreleased"
    }
}

// MARK: - The tile

/// A fixed-size dashboard tile that opens the tab or sheet holding the full version of itself.
struct DashTile<Content: View>: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(AppPreferences.self) private var preferences
    let title: String
    var subtitle: String? = nil
    var info: String? = nil
    var destination: NavigationStore.Screen? = nil
    var action: (() -> Void)? = nil
    var helpText: String? = nil
    var needs: KeyPath<Readiness, Bool>? = nil
    var waitingFor: String = "the commit history"
    @ViewBuilder let content: Content

    @State private var hovering = false

    private var ready: Bool { needs.map { session.readiness[keyPath: $0] } ?? true }
    private var isInteractive: Bool { destination != nil || action != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: 5) {
                Text(title).font(Theme.Text.heading).foregroundStyle(Theme.ink)
                if let info { InfoButton(title: title, text: info) }
                Spacer(minLength: Theme.Space.s)
                if let subtitle {
                    Text(subtitle).font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                        .lineLimit(1)
                }
                if isInteractive {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(hovering ? Theme.accent : Theme.inkMuted.opacity(0.5))
                }
            }
            if ready {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                StillReading(what: waitingFor, compact: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .cardSurface(hovered: hovering && isInteractive)
        .contentShape(Rectangle())
        .onTapGesture {
            if let action {
                action()
            } else if let destination {
                session.show(destination)
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(helpText ?? destination.map { "Open \($0.displayTitle(advanced: preferences.advanced))" } ?? "")
    }
}

// MARK: - Tiles

struct CatchUpTile: View {
    @Environment(WorkspaceSession.self) private var session
    var limit = 3

    var body: some View {
        DashTile(title: "Since you were last here",
                 subtitle: session.catchUp.map { $0.isEmpty ? nil : "\($0.authorCount) \($0.authorCount == 1 ? "person" : "people")" } ?? nil,
                 destination: .commits,
                 needs: \.hasHistory) {
            if let catchUp = session.catchUp {
                VStack(alignment: .leading, spacing: 6) {
                    Text(catchUp.headline(now: Date()))
                        .font(Theme.Text.title).foregroundStyle(Theme.ink)
                        .lineLimit(1).minimumScaleFactor(0.85)
                    if catchUp.isEmpty {
                        Text("Up to date. The most recent work here:")
                            .font(Theme.Text.body).foregroundStyle(Theme.inkSoft)
                        ForEach(session.analysis?.commits.prefix(limit) ?? [], id: \.sha) { commit in
                            HStack(spacing: Theme.Space.s) {
                                Avatar(name: commit.author, size: 20)
                                Text(commit.subject.isEmpty ? "(no message)" : commit.subject)
                                    .font(Theme.Text.body).foregroundStyle(Theme.ink).lineLimit(1)
                                Spacer(minLength: 0)
                                Text(RiskExplanation.relative(commit.date, now: Date()))
                                    .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                            }
                            .frame(height: 22)
                        }
                    } else {
                        // Three, always: the row height is fixed, so the tile shows the same
                        // amount whether twelve commits arrived or two hundred.
                        ForEach(catchUp.commits.prefix(limit), id: \.sha) { commit in
                            HStack(spacing: Theme.Space.s) {
                                Avatar(name: commit.author, size: 20)
                                Text(commit.subject.isEmpty ? "(no message)" : commit.subject)
                                    .font(Theme.Text.body).foregroundStyle(Theme.ink).lineLimit(1)
                                Spacer(minLength: 0)
                                Text(RiskExplanation.relative(commit.date, now: Date()))
                                    .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                            }
                            .frame(height: 22)
                        }
                        if catchUp.commits.count > limit {
                            Text("and \((catchUp.commits.count - limit).formatted()) more")
                                .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

struct WorkingCopyTile: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(AppPreferences.self) private var preferences
    @Environment(WorkingCopyStore.self) private var workingCopy
    let state: WorkingState
    var compact = false

    private var changedCount: Int {
        Set(state.staged.map(\.path) + state.unstaged.map(\.path)).count
    }

    var body: some View {
        DashTile(title: preferences.advanced ? "Your working copy" : "Your work", destination: .changes) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 10, weight: .semibold))
                    Text(state.branch ?? "detached").font(Theme.Text.bodyBold).foregroundStyle(Theme.ink)
                    if preferences.advanced {
                        if state.ahead > 0 { Chip(text: "\(state.ahead) ahead") }
                        if state.behind > 0 { Chip(text: "\(state.behind) behind") }
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.inkSoft)

                if state.isClean && !state.hasUnpushedCommits && (preferences.advanced ? state.stashes.isEmpty : true) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.good)
                        Text(preferences.advanced ? "Nothing uncommitted, nothing unpushed." : "Everything is saved and synced.")
                            .font(Theme.Text.body).foregroundStyle(Theme.inkSoft).lineLimit(2)
                    }
                    // A clean tile would otherwise be three words and a lot of nothing.
                    if let head = session.analysis?.commits.first, !compact {
                        Divider().overlay(Theme.hairline).padding(.vertical, 2)
                        Text("Last commit").font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                        Text(head.subject.isEmpty ? "(no message)" : head.subject)
                            .font(Theme.Text.body).foregroundStyle(Theme.ink).lineLimit(2)
                        HStack(spacing: 6) {
                            Avatar(name: head.author, size: 18)
                            Text(head.author).font(Theme.Text.caption).foregroundStyle(Theme.inkSoft).lineLimit(1)
                            Text("· \(RiskExplanation.relative(head.date, now: Date()))")
                                .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                        }
                    }
                } else if !preferences.advanced {
                    if !state.conflicted.isEmpty {
                        countRow(state.conflicted.count, "file\(state.conflicted.count == 1 ? "" : "s") with conflicts",
                                 "exclamationmark.triangle.fill", Theme.critical)
                    }
                    countRow(changedCount, "modified file\(changedCount == 1 ? "" : "s")", "pencil", Theme.warning)
                    countRow(state.untracked.count, "new file\(state.untracked.count == 1 ? "" : "s")", "plus.circle", Theme.inkMuted)
                    if state.ahead > 0 {
                        countRow(state.ahead, "commit\(state.ahead == 1 ? "" : "s") ready to share", "arrow.up.circle", Theme.accent)
                    }
                    if state.behind > 0 {
                        countRow(state.behind, "update\(state.behind == 1 ? "" : "s") to pull", "arrow.down.circle", Theme.accent)
                    }
                    if !compact {
                        Spacer(minLength: 4)
                        HStack(spacing: Theme.Space.s) {
                            Button("Review changes") { session.show(.changes) }
                                .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                            if (state.ahead > 0 || state.behind > 0) && state.isClean {
                                Button("Sync") { workingCopy.sync() }
                                    .buttonStyle(PrimaryButtonStyle()).controlSize(.small)
                                    .disabled(workingCopy.writeInFlight)
                            }
                        }
                    }
                } else {
                    countRow(state.staged.count, "staged", "tray.and.arrow.down.fill", Theme.good)
                    countRow(state.unstaged.count, "not staged", "pencil", Theme.warning)
                    countRow(state.untracked.count, "not in git", "questionmark.circle", Theme.inkMuted)
                    countRow(state.stashes.count, "stashed", "archivebox", Theme.inkMuted)
                    if state.ahead > 0 {
                        countRow(state.ahead, "not pushed", "arrow.up.circle", Theme.accent)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func countRow(_ count: Int, _ label: String, _ icon: String, _ tint: Color) -> some View {
        if count > 0 {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 10)).foregroundStyle(tint).frame(width: 14)
                Text("\(count) \(label)").font(Theme.Text.body).foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
            }
            .frame(height: 20)
        }
    }
}

/// One number, its label, and one line of context.
struct NumberTile: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(AppPreferences.self) private var preferences
    let icon: String
    let tint: Theme.Tint
    let destination: NavigationStore.Screen
    let value: String
    let label: String
    var detail: String? = nil

    @State private var hovering = false

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.tint(tint))
                .frame(width: 32, height: 32)
                .background(Theme.tint(tint).opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(Theme.Text.hero.monospacedDigit()).foregroundStyle(Theme.ink)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(label).font(Theme.Text.caption).foregroundStyle(Theme.inkSoft).lineLimit(1)
                if let detail {
                    Text(detail).font(Theme.Text.caption).foregroundStyle(Theme.inkMuted).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .clipped()
        .cardSurface(hovered: hovering)
        .contentShape(Rectangle())
        .onTapGesture { session.show(destination) }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("Open \(destination.displayTitle(advanced: preferences.advanced))")
    }
}

/// The full-width language bar. Kept to one row: it answers "what is this written in", and
/// the breakdown with every percentage lives on the Files tab.
struct LanguageStrip: View {
    @Environment(WorkspaceSession.self) private var session
    let inventory: FileInventory
    @State private var hovering = false

    var body: some View {
        let shares = inventory.languages
        let total = max(shares.reduce(Int64(0)) { $0 + $1.bytes }, 1)
        let shown = Array(shares.prefix(6))

        HStack(spacing: Theme.Space.l) {
            if shares.isEmpty {
                Text("No recognised source files.")
                    .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
            } else {
                HStack(spacing: 2) {
                    ForEach(shown) { share in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(share.language.colorHex.map { Color(hex: $0) } ?? Theme.inkMuted)
                            .frame(width: max(3, 220 * CGFloat(share.bytes) / CGFloat(total)))
                    }
                }
                .frame(width: 220, height: 8)
                ForEach(shown.prefix(5)) { share in
                    HStack(spacing: 5) {
                        Circle().fill(share.language.colorHex.map { Color(hex: $0) } ?? Theme.inkMuted)
                            .frame(width: 7, height: 7)
                        Text(share.language.name).font(Theme.Text.caption).foregroundStyle(Theme.ink)
                        Text(percent(share.bytes, of: total))
                            .font(Theme.Text.caption.monospacedDigit()).foregroundStyle(Theme.inkMuted)
                    }
                }
            }
            Spacer(minLength: 0)
            Text("\(shares.count) languages").font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hovering ? Theme.accent : Theme.inkMuted.opacity(0.5))
        }
        .padding(.horizontal, Theme.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .clipped()
        .cardSurface(hovered: hovering)
        .contentShape(Rectangle())
        .onTapGesture { session.show(.files) }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("Open Files")
    }

    private func percent(_ bytes: Int64, of total: Int64) -> String {
        let value = Double(bytes) / Double(total) * 100
        return value < 1 ? String(format: "%.1f%%", value) : "\(Int(value.rounded()))%"
    }
}

struct HealthTile: View {
    @Environment(AppPreferences.self) private var preferences
    @Environment(NavigationStore.self) private var navigation
    @Environment(RiskStore.self) private var risk
    var checks = 3
    var showRowDetails = true

    var body: some View {
        DashTile(title: preferences.advanced ? "Repository health" : "Project health",
                 subtitle: risk.health != nil ? "Breakdown" : nil,
                 info: "Five checks totaling 100 points: recent activity (25), active contributors (20), branch "
                     + "hygiene (15), large files (15), and complex code under change (25). Click this tile "
                     + "to inspect all 5 checks and scoring rules.",
                 action: {
                     if risk.health != nil {
                         navigation.isHealthBreakdownSheetPresented = true
                     }
                 },
                 helpText: "Open full health score breakdown",
                 needs: preferences.advanced ? \.hasUnits : \.hasHistory,
                 waitingFor: preferences.advanced ? "the source files" : "the commit history") {
            if let health = risk.health {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    HStack(spacing: Theme.Space.m) {
                        // The ring is most of this tile's height. In a short window it is
                        // the first thing to go: the number is the information, the ring is
                        // the presentation of it.
                        if checks > 1 {
                            HealthRing(health: health, size: showRowDetails ? 74 : 64)
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: 2) {
                                Text("\(health.score)")
                                    .font(Theme.Text.display.monospacedDigit())
                                    .foregroundStyle(Theme.color(for: health.bandStatus))
                                Text("/\(health.maxScore)")
                                    .font(Theme.Text.caption.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(Theme.inkMuted)
                            }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(health.label)
                                    .font(Theme.Text.bodyBold)
                                    .foregroundStyle(Theme.color(for: health.bandStatus))
                                if checks > 1 {
                                    Text("\(health.score) / \(health.maxScore)")
                                        .font(Theme.Text.caption.weight(.semibold).monospacedDigit())
                                        .foregroundStyle(Theme.inkSoft)
                                }
                            }
                            Text(health.summary)
                                .font(Theme.Text.caption)
                                .foregroundStyle(Theme.inkSoft)
                                .lineLimit(checks > 1 ? 2 : 1)
                        }
                        Spacer(minLength: 0)
                    }
                    // Whatever needs attention most, first.
                    VStack(alignment: .leading, spacing: showRowDetails && checks > 1 ? 6 : 4) {
                        ForEach(Self.ranked(health).prefix(checks)) { item in
                            if showRowDetails && checks > 1 {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Circle().fill(Theme.color(for: item.status)).frame(width: 6, height: 6)
                                        Text(item.title)
                                            .font(Theme.Text.caption.weight(.medium))
                                            .foregroundStyle(Theme.ink)
                                            .lineLimit(1)
                                        Spacer(minLength: 4)
                                        HealthPointsBadge(points: item.points,
                                                          maxPoints: item.maxPoints,
                                                          status: item.status,
                                                          compact: true)
                                    }
                                    Text(item.detail)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(Theme.inkMuted)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .padding(.leading, 12)
                                }
                            } else {
                                HStack(spacing: 6) {
                                    Circle().fill(Theme.color(for: item.status)).frame(width: 6, height: 6)
                                    Text(item.title)
                                        .font(Theme.Text.caption.weight(.medium))
                                        .foregroundStyle(Theme.ink)
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    HealthPointsBadge(points: item.points,
                                                      maxPoints: item.maxPoints,
                                                      status: item.status,
                                                      compact: true)
                                }
                                .frame(height: 18)
                            }
                        }
                    }
                    Spacer(minLength: 2)
                    if checks > 1 {
                        HStack(spacing: 4) {
                            Text("All \(health.items.count) checks · \(health.score)/\(health.maxScore)")
                                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                                .foregroundStyle(Theme.inkMuted)
                            Spacer(minLength: 0)
                            Text("See breakdown")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }
            }
        }
    }

    static func ranked(_ health: RepositoryHealth) -> [RepositoryHealth.Item] {
        func rank(_ status: RepositoryHealth.Status) -> Int {
            switch status { case .bad: return 0; case .warning: return 1; case .good: return 2 }
        }
        return health.items.sorted { lhs, rhs in
            let lRank = rank(lhs.status)
            let rRank = rank(rhs.status)
            if lRank != rRank { return lRank < rRank }
            let lLost = lhs.maxPoints - lhs.points
            let rLost = rhs.maxPoints - rhs.points
            if lLost != rLost { return lLost > rLost }
            return lhs.maxPoints > rhs.maxPoints
        }
    }
}

struct HotspotsTile: View {
    @Environment(RiskStore.self) private var risk
    var limit = 4

    var body: some View {
        DashTile(title: "Risk hotspots",
                 subtitle: risk.rows.isEmpty ? nil : "\(risk.rows.count.formatted()) ranked",
                 info: "Functions with the highest combination of complexity and recent change — where a "
                     + "bug is most likely hiding and where a small refactor pays off most.",
                 destination: .hotspots,
                 needs: \.hasUnits, waitingFor: "the source files") {
            if risk.rows.isEmpty {
                Text("No functions with history to rank.")
                    .font(Theme.Text.body).foregroundStyle(Theme.inkMuted)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(risk.rows.prefix(limit)) { row in
                        HStack(spacing: Theme.Space.s) {
                            RiskBadge(level: row.level, compact: true)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(row.name).font(Theme.Text.body).foregroundStyle(Theme.ink).lineLimit(1)
                                Text(row.fileName).font(Theme.Text.caption)
                                    .foregroundStyle(Theme.inkMuted).lineLimit(1).truncationMode(.head)
                            }
                            Spacer(minLength: 0)
                            Text("\(row.commitCount)×").font(Theme.Text.caption.monospacedDigit())
                                .foregroundStyle(Theme.inkMuted)
                        }
                        .frame(height: 30)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

struct RecentHistoryTile: View {
    @Environment(WorkspaceSession.self) private var session
    var limit = 5

    var body: some View {
        DashTile(title: "Recent activity",
                 subtitle: "latest changes",
                 destination: .commits,
                 needs: \.hasHistory) {
            let commits = session.analysis?.commits.prefix(limit) ?? []
            if commits.isEmpty {
                Text("No saved history yet.")
                    .font(Theme.Text.body).foregroundStyle(Theme.inkMuted)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(commits), id: \.sha) { commit in
                        HStack(spacing: Theme.Space.s) {
                            Avatar(name: commit.author, size: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(commit.subject.isEmpty ? "(no message)" : commit.subject)
                                    .font(Theme.Text.body).foregroundStyle(Theme.ink).lineLimit(1)
                                Text("\(commit.author) · \(RiskExplanation.relative(commit.date, now: Date()))")
                                    .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(height: 30)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

struct ActivityTile: View {
    @Environment(WorkspaceSession.self) private var session

    var body: some View {
        DashTile(title: "Activity",
                 subtitle: "commits per week",
                 destination: .activity,
                 needs: \.hasHistory) {
            let buckets = session.recentActivityBuckets
            if buckets.isEmpty {
                Text("No commits in the last six months.")
                    .font(Theme.Text.body).foregroundStyle(Theme.inkMuted)
            } else {
                Sparkline(buckets: buckets)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// Bars with no chrome at all, scaled to the busiest week in the window.
struct Sparkline: View {
    let buckets: [ActivityBucket]

    var body: some View {
        let peak = max(buckets.map(\.commits).max() ?? 1, 1)
        GeometryReader { geometry in
            let spacing: CGFloat = 2
            let width = max((geometry.size.width - spacing * CGFloat(buckets.count - 1))
                            / CGFloat(max(buckets.count, 1)), 1)
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(buckets) { bucket in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Theme.accent.opacity(bucket.commits == 0 ? 0.18 : 0.85))
                        .frame(width: width,
                               height: max(2, geometry.size.height * CGFloat(bucket.commits) / CGFloat(peak)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }
}
