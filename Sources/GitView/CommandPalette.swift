import SwiftUI
import GitViewCore
import GitViewGit

/// Pure scored ranking for Command Palette items: exact > prefix > word boundary > substring > fuzzy subsequence.
enum CommandPaletteMatcher {
    static func rank<T>(
        query: String,
        items: [T],
        title: (T) -> String,
        subtitle: (T) -> String = { _ in "" },
        keywords: (T) -> String = { _ in "" }
    ) -> [T] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return items }

        var scored: [(index: Int, score: Int, item: T)] = []
        scored.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            if let s = score(
                query: trimmed,
                title: title(item).lowercased(),
                subtitle: subtitle(item).lowercased(),
                keywords: keywords(item).lowercased()
            ) {
                scored.append((index, s, item))
            }
        }
        scored.sort { lhs, rhs in
            lhs.score != rhs.score ? lhs.score > rhs.score : lhs.index < rhs.index
        }
        return scored.map(\.item)
    }

    static func score(query q: String, title t: String, subtitle s: String, keywords k: String) -> Int? {
        if t == q { return 1000 }
        if t.hasPrefix(q) { return 850 }

        let words = t.split { $0 == " " || $0 == "/" || $0 == "." || $0 == "_" || $0 == "-" }
        if words.contains(where: { $0.hasPrefix(q) }) {
            return 700
        }
        if t.contains(q) { return 550 }
        if s.contains(q) || k.contains(q) { return 350 }
        if let fuzzy = fuzzySubsequenceScore(query: q, in: t) {
            return fuzzy
        }
        return nil
    }

    private static func fuzzySubsequenceScore(query: String, in target: String) -> Int? {
        var targetIndex = target.startIndex
        var gaps = 0
        var lastMatched: String.Index?

        for ch in query {
            guard let found = target[targetIndex...].firstIndex(of: ch) else {
                return nil
            }
            if let prev = lastMatched {
                gaps += target.distance(from: prev, to: found) - 1
            } else {
                gaps += target.distance(from: target.startIndex, to: found)
            }
            lastMatched = found
            targetIndex = target.index(after: found)
        }
        return max(150 - gaps * 2, 10)
    }
}

struct CommandPaletteEntry: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let category: String
    let symbol: String
    let keywords: String
    let perform: @MainActor () -> Void
}

/// Modal floating Command Palette invoked via ⌘K for jumping across screens, files, branches, commits, and actions.
struct CommandPaletteOverlay: View {
    @Environment(WorkspaceSession.self) private var session
    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var queryFocused: Bool

    private var entries: [CommandPaletteEntry] {
        var items: [CommandPaletteEntry] = []

        let advanced = session.preferences.advanced
        if session.hasRepository {
            for screen in session.visibleScreens {
                let title = screen.displayTitle(advanced: advanced)
                items.append(CommandPaletteEntry(
                    id: "screen:\(screen.rawValue)",
                    title: title,
                    subtitle: "Switch to \(title) screen",
                    category: "Screen",
                    symbol: screen.symbol,
                    keywords: "\(screen.rawValue) \(screen.title) \(title)",
                    perform: { session.show(screen) }
                ))
            }
        }

        items.append(CommandPaletteEntry(
            id: "action:open",
            title: "Open Repository…",
            subtitle: "Choose a git repository folder",
            category: "Action",
            symbol: "folder.badge.plus",
            keywords: "open repo choose",
            perform: { chooseRepository(into: session) }
        ))

        if let analysis = session.analysis {
            items.append(CommandPaletteEntry(
                id: "action:refresh",
                title: "Refresh Repository",
                subtitle: "Re-read repository state",
                category: "Action",
                symbol: "arrow.clockwise",
                keywords: "reload sync",
                perform: { session.refresh() }
            ))
            items.append(CommandPaletteEntry(
                id: "action:mode",
                title: advanced ? "Switch to Standard Mode" : "Switch to Advanced Mode",
                subtitle: "Toggle between everyday Git and full analysis views",
                category: "Action",
                symbol: "slider.horizontal.3",
                keywords: "advanced standard mode",
                perform: { session.preferences.advanced.toggle() }
            ))
            if analysis.info.remoteURL != nil || session.workingCopy.pushPlan != nil {
                if advanced {
                    items.append(CommandPaletteEntry(
                        id: "action:fetch",
                        title: "Fetch All Remotes",
                        subtitle: "git fetch --all --prune",
                        category: "Action",
                        symbol: "arrow.down.circle",
                        keywords: "remote fetch prune",
                        perform: { session.workingCopy.fetch() }
                    ))
                } else {
                    items.append(CommandPaletteEntry(
                        id: "action:sync",
                        title: "Sync with Remote",
                        subtitle: "Fetch updates, pull, and share commits",
                        category: "Action",
                        symbol: "arrow.triangle.2.circlepath",
                        keywords: "sync pull push remote",
                        perform: { session.workingCopy.sync() }
                    ))
                }
            }
            if advanced && analysis.workingState.behind > 0 {
                items.append(CommandPaletteEntry(
                    id: "action:pull",
                    title: "Pull Fast-Forward (\(analysis.workingState.behind) behind)",
                    subtitle: "git pull --ff-only",
                    category: "Action",
                    symbol: "arrow.down",
                    keywords: "pull sync",
                    perform: { session.workingCopy.pull() }
                ))
            }

            let branchPool = advanced ? analysis.branches : analysis.branches.filter { !$0.isRemote }
            for branch in branchPool.prefix(80) {
                let target = branch.checkoutTarget
                items.append(CommandPaletteEntry(
                    id: "branch:\(branch.id)",
                    title: "Switch to \(branch.name)",
                    subtitle: "\(branch.isRemote ? "Remote branch" : "Local branch") · \(branch.subject)",
                    category: "Branch",
                    symbol: "arrow.triangle.branch",
                    keywords: "\(branch.name) \(target)",
                    perform: { session.workingCopy.switchBranch(target, isRemote: branch.isRemote) }
                ))
            }

            for file in analysis.info.inventory.files {
                let name = (file.path as NSString).lastPathComponent
                items.append(CommandPaletteEntry(
                    id: "file:\(file.path)",
                    title: name,
                    subtitle: file.path,
                    category: "File",
                    symbol: "doc.text",
                    keywords: file.path,
                    perform: {
                        session.show(.files)
                        session.navigation.pendingFileSelection = file.path
                    }
                ))
            }

            for commit in analysis.commits.prefix(150) {
                let subtitle = advanced
                    ? "\(String(commit.sha.prefix(7))) · \(commit.author)"
                    : commit.author
                items.append(CommandPaletteEntry(
                    id: "commit:\(commit.sha)",
                    title: commit.subject.isEmpty ? String(commit.sha.prefix(7)) : commit.subject,
                    subtitle: subtitle,
                    category: advanced ? "Commit" : "History",
                    symbol: "clock.arrow.circlepath",
                    keywords: advanced ? "\(commit.sha) \(commit.author)" : commit.author,
                    perform: {
                        session.navigation.selectedCommitSHA = commit.sha
                        session.inspector.ensureCommitDetail(sha: commit.sha)
                    }
                ))
            }

            if advanced {
                for row in session.risk.allRankedRows.prefix(150) {
                    items.append(CommandPaletteEntry(
                        id: "unit:\(row.id.uuidString)",
                        title: row.name,
                        subtitle: row.location,
                        category: "Hotspot",
                        symbol: "flame",
                        keywords: "\(row.name) \(row.filePath)",
                        perform: {
                            session.show(.hotspots)
                            session.navigation.selectedUnitID = row.id
                        }
                    ))
                }
            }
        }

        return items
    }

    private var matchedEntries: [CommandPaletteEntry] {
        let ranked = CommandPaletteMatcher.rank(
            query: query,
            items: entries,
            title: \.title,
            subtitle: \.subtitle,
            keywords: \.keywords
        )
        return Array(ranked.prefix(40))
    }

    var body: some View {
        let matches = matchedEntries
        ZStack(alignment: .top) {
            Color.black.opacity(0.32)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(spacing: 0) {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.accent)
                    TextField("Jump to screen, file, branch, commit, hotspot, or action…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .focused($queryFocused)
                        .onSubmit {
                            executeSelection(in: matches)
                        }
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.inkMuted)
                        }
                        .buttonStyle(.plain)
                    }
                    Text("ESC")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.inkMuted)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Theme.wash, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .padding(.horizontal, Theme.Space.l)
                .padding(.vertical, 12)

                HairlineDivider()

                if matches.isEmpty {
                    VStack(spacing: Theme.Space.s) {
                        Text("No matching commands or items")
                            .font(Theme.Text.body)
                            .foregroundStyle(Theme.inkMuted)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Space.xxl)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(Array(matches.enumerated()), id: \.element.id) { index, entry in
                                    Button {
                                        dismiss()
                                        entry.perform()
                                    } label: {
                                        HStack(spacing: Theme.Space.m) {
                                            Image(systemName: entry.symbol)
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundStyle(index == selectedIndex ? Theme.accent : Theme.inkMuted)
                                                .frame(width: 18)
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(entry.title)
                                                    .font(Theme.Text.bodyBold)
                                                    .foregroundStyle(Theme.ink)
                                                    .lineLimit(1)
                                                Text(entry.subtitle)
                                                    .font(Theme.Text.caption)
                                                    .foregroundStyle(Theme.inkMuted)
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                            }
                                            Spacer()
                                            Chip(text: entry.category, tint: index == selectedIndex ? Theme.accent : Theme.inkSoft)
                                        }
                                        .padding(.horizontal, Theme.Space.m)
                                        .padding(.vertical, 7)
                                        .background(
                                            index == selectedIndex ? Theme.accentWash : .clear,
                                            in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                                        )
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .id(entry.id)
                                }
                            }
                            .padding(Theme.Space.s)
                        }
                        .frame(maxHeight: 340)
                        .onChange(of: selectedIndex) { _, newIndex in
                            if newIndex >= 0 && newIndex < matches.count {
                                proxy.scrollTo(matches[newIndex].id, anchor: .center)
                            }
                        }
                    }
                }
            }
            .frame(width: 580)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.hairline))
            .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
            .padding(.top, 72)
        }
        .onAppear {
            selectedIndex = 0
            queryFocused = true
        }
        .onChange(of: query) { _, _ in
            selectedIndex = 0
        }
        .onKeyPress(.downArrow) {
            guard !matches.isEmpty else { return .ignored }
            selectedIndex = min(selectedIndex + 1, matches.count - 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            guard !matches.isEmpty else { return .ignored }
            selectedIndex = max(selectedIndex - 1, 0)
            return .handled
        }
        .onKeyPress(.return) {
            executeSelection(in: matches)
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    private func executeSelection(in matches: [CommandPaletteEntry]) {
        guard selectedIndex >= 0 && selectedIndex < matches.count else { return }
        let chosen = matches[selectedIndex]
        dismiss()
        chosen.perform()
    }

    private func dismiss() {
        session.navigation.isCommandPalettePresented = false
    }
}
