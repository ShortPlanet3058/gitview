import SwiftUI
import GitViewCore
import GitViewGit

struct GlobalSearchField: View {
    @Environment(AppPreferences.self) private var preferences
    @Environment(SearchStore.self) private var search
    @Environment(NavigationStore.self) private var navigation
    @Environment(\.staticRendering) private var staticRendering
    @FocusState private var focused: Bool

    private var prompt: String {
        preferences.advanced
            ? "Search commits, files, functions…"
            : "Search history, files, branches…"
    }

    var body: some View {
        @Bindable var search = search
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.inkMuted)
            if staticRendering {
                Text(search.globalSearch.isEmpty ? prompt : search.globalSearch)
                    .font(Theme.Text.body)
                    .foregroundStyle(search.globalSearch.isEmpty ? Theme.inkMuted : Theme.ink)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(prompt, text: $search.globalSearch)
                    .textFieldStyle(.plain)
                    .font(Theme.Text.body)
                    .focused($focused)
                    .frame(maxWidth: .infinity)
            }
            if search.isSearching {
                Button { search.clear() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.inkMuted)
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    navigation.isCommandPalettePresented.toggle()
                } label: {
                    Text("⌘K")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.inkMuted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.wash, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Open Command Palette (⌘K)")
            }
        }
        .frame(minWidth: 220, maxWidth: 360)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.surface.opacity(0.9), in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            .strokeBorder(focused ? Theme.accent.opacity(0.6) : Theme.hairline))
        .onChange(of: navigation.focusSearchRequest) { focused = true }
    }
}

/// Everything that matches, grouped by what it is.
struct SearchScreen: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(SearchStore.self) private var search
    @Environment(RiskStore.self) private var risk

    var body: some View {
        Page {
            header
            if let results = search.searchResults {
                if results.isEmpty && search.codeMatches.isEmpty && search.historyMatches.isEmpty
                    && !search.deepSearchInFlight {
                    emptyState
                } else {
                    if !results.commits.isEmpty { commitsSection(results.commits) }
                    if !results.units.isEmpty { unitsSection(results.units) }
                    if !results.files.isEmpty { filesSection(results.files) }
                    if !search.codeMatches.isEmpty || search.deepSearchInFlight { codeSection }
                    if !search.historyMatches.isEmpty { historySection }
                    if !results.people.isEmpty || !results.branches.isEmpty || !results.tags.isEmpty {
                        othersSection(results)
                    }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScreenHeader(title: "Search", subtitle: summary)
            Text("Try `author:weiss`, or `in:commits`, `in:files`, `in:functions` to narrow it.")
                .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
        }
    }

    private var summary: String {
        guard let results = search.searchResults else { return "" }
        var parts: [String] = []
        if results.total > 0 { parts.append("\(results.total) match\(results.total == 1 ? "" : "es")") }
        if !search.codeMatches.isEmpty { parts.append("\(search.codeMatches.count) in file contents") }
        if !search.historyMatches.isEmpty { parts.append("\(search.historyMatches.count) commits changed it") }
        return parts.isEmpty ? "No matches for “\(results.query)”" : parts.joined(separator: " · ")
    }

    private var emptyState: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Nothing matches “\(search.globalSearch)”").font(Theme.Text.heading).foregroundStyle(Theme.ink)
                Text("Searched commit messages, authors, commit ids, file paths, function names, "
                     + "branches, tags, and the contents of tracked files.")
                    .font(Theme.Text.body).foregroundStyle(Theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func section<Content: View>(_ title: String, _ count: Int, info: String? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                CardHeader(title: title, subtitle: "\(count)", info: info)
                content()
            }
        }
    }

    private func commitsSection(_ commits: [Commit]) -> some View {
        section("Commits", commits.count) {
            VStack(spacing: 0) {
                ForEach(commits, id: \.sha) { commit in
                    Button { session.navigation.selectedCommitSHA = commit.sha } label: {
                        HStack(spacing: Theme.Space.s) {
                            Avatar(name: commit.author, size: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(commit.subject.isEmpty ? "(no message)" : commit.subject)
                                    .font(Theme.Text.body).foregroundStyle(Theme.ink).lineLimit(1)
                                Text("\(commit.author) · \(RiskExplanation.relative(commit.date, now: Date()))")
                                    .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                            }
                            Spacer()
                            ShaChip(sha: commit.sha)
                        }
                        .padding(.vertical, 4).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu { CommitActions(commit: commit) }
                }
            }
        }
    }

    private func unitsSection(_ units: [CodeUnit]) -> some View {
        section("Functions", units.count) {
            VStack(spacing: 0) {
                ForEach(units) { unit in
                    Button {
                        session.show(.hotspots)
                        session.navigation.selectedUnitID = unit.id
                    } label: {
                        HStack(spacing: Theme.Space.s) {
                            if let row = risk.rowsByID[unit.id] { RiskBadge(level: row.level, compact: true) }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(unit.name).font(Theme.Text.body).foregroundStyle(Theme.ink)
                                    .lineLimit(1).truncationMode(.middle)
                                Text("\(unit.filePath):\(unit.lineRange.lowerBound)")
                                    .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Text("cx \(unit.complexity)").font(Theme.Text.caption.monospacedDigit())
                                .foregroundStyle(Theme.inkMuted)
                        }
                        .padding(.vertical, 4).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if let url = session.analysis?.root.appendingPathComponent(unit.filePath),
                           FileManager.default.fileExists(atPath: url.path) {
                            Button("Open in Editor at Line \(unit.lineRange.lowerBound)") {
                                openInEditor(url, line: unit.lineRange.lowerBound)
                            }
                        }
                        PathActions(path: unit.filePath)
                    }
                }
            }
        }
    }

    private func filesSection(_ files: [String]) -> some View {
        section("Files", files.count) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(files, id: \.self) { path in
                    Button {
                        session.show(.files)
                        session.navigation.pendingFileSelection = path
                    } label: {
                        HStack(spacing: Theme.Space.s) {
                            Image(systemName: "doc.text").font(.system(size: 10)).foregroundStyle(Theme.inkMuted)
                            Text(path).font(Theme.Text.body).foregroundStyle(Theme.ink)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                        }
                        .padding(.vertical, 4).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu { PathActions(path: path) }
                }
            }
        }
    }

    private var codeSection: some View {
        section("In file contents", search.codeMatches.count,
                info: "Matching lines in tracked files as they stand now, from `git grep`. "
                    + "Binary files are skipped.") {
            if search.deepSearchInFlight && search.codeMatches.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Searching file contents…").font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(search.codeMatches.prefix(30)) { match in
                        Button {
                            session.show(.files)
                            session.navigation.pendingFileSelection = match.path
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(match.path):\(match.line)")
                                    .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                                    .lineLimit(1).truncationMode(.middle)
                                Text(match.text).font(Theme.Text.mono).foregroundStyle(Theme.ink)
                                    .lineLimit(1)
                            }
                            .padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if let url = session.analysis?.root.appendingPathComponent(match.path),
                               FileManager.default.fileExists(atPath: url.path) {
                                Button("Open in Editor at Line \(match.line)") {
                                    openInEditor(url, line: match.line)
                                }
                            }
                            PathActions(path: match.path)
                        }
                    }
                }
            }
        }
    }

    private var historySection: some View {
        section("Commits that added or removed it", search.historyMatches.count,
                info: "Commits where the number of occurrences of this text changed — git's "
                    + "\"pickaxe\". This is how to find when something was introduced or deleted.") {
            VStack(spacing: 0) {
                ForEach(search.historyMatches, id: \.sha) { commit in
                    Button { session.navigation.selectedCommitSHA = commit.sha } label: {
                        HStack(spacing: Theme.Space.s) {
                            Avatar(name: commit.author, size: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(commit.subject).font(Theme.Text.body).foregroundStyle(Theme.ink).lineLimit(1)
                                Text("\(commit.author) · \(RiskExplanation.relative(commit.date, now: Date()))")
                                    .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                            }
                            Spacer()
                            ShaChip(sha: commit.sha)
                        }
                        .padding(.vertical, 4).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu { CommitActions(commit: commit) }
                }
            }
        }
    }

    private func othersSection(_ results: SearchResults) -> some View {
        section("People, branches and tags",
                results.people.count + results.branches.count + results.tags.count) {
            FlowRow(spacing: Theme.Space.s) {
                ForEach(results.people) { person in
                    Button {
                        session.show(.contributors)
                        session.navigation.selectedAuthor = person.name
                    } label: {
                        HStack(spacing: 5) {
                            Avatar(name: person.name, size: 18)
                            Text(person.name).font(Theme.Text.caption).foregroundStyle(Theme.ink)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Theme.wash, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                ForEach(results.branches, id: \.self) { name in
                    Button { session.show(.branches) } label: {
                        Label(name, systemImage: "arrow.triangle.branch")
                            .font(Theme.Text.caption).foregroundStyle(Theme.ink)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Theme.wash, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                ForEach(results.tags, id: \.self) { name in
                    Button {
                        session.navigation.compareTo = name
                        session.show(.releases)
                    } label: {
                        Label(name, systemImage: "tag")
                            .font(Theme.Text.caption).foregroundStyle(Theme.ink)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Theme.wash, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
