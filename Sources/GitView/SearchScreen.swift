import SwiftUI
import GitViewCore
import GitViewGit

struct GlobalSearchField: View {
    @EnvironmentObject private var model: AnalysisModel
    @Environment(\.staticRendering) private var staticRendering
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.inkMuted)
            if staticRendering {
                // A real TextField is AppKit-backed and draws as a blank placeholder in the
                // offscreen renderer, which is no use for a screenshot. Same metrics, plain
                // text, only ever used when rendering to an image.
                Text(model.globalSearch.isEmpty ? "Search commits, files, functions…" : model.globalSearch)
                    .font(Theme.Text.body)
                    .foregroundStyle(model.globalSearch.isEmpty ? Theme.inkMuted : Theme.ink)
                    .frame(width: 260, alignment: .leading)
            } else {
            TextField("Search commits, files, functions…", text: $model.globalSearch)
                .textFieldStyle(.plain).font(Theme.Text.body).focused($focused)
                .frame(width: 260)
            }
            if model.isSearching {
                Button { model.clearSearch() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.inkMuted)
                }
                .buttonStyle(.plain)
            } else {
                Text("⌘F").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.inkMuted)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            .strokeBorder(focused ? Theme.accent.opacity(0.6) : Theme.hairline))
        .onChange(of: model.focusSearchRequest) { _ in focused = true }
    }
}

/// Everything that matches, grouped by what it is.
struct SearchScreen: View {
    @EnvironmentObject private var model: AnalysisModel

    var body: some View {
        Page {
            header
            if let results = model.searchResults {
                if results.isEmpty && model.codeMatches.isEmpty && model.historyMatches.isEmpty
                    && !model.deepSearchInFlight {
                    emptyState
                } else {
                    if !results.commits.isEmpty { commitsSection(results.commits) }
                    if !results.units.isEmpty { unitsSection(results.units) }
                    if !results.files.isEmpty { filesSection(results.files) }
                    if !model.codeMatches.isEmpty || model.deepSearchInFlight { codeSection }
                    if !model.historyMatches.isEmpty { historySection }
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
        guard let results = model.searchResults else { return "" }
        var parts: [String] = []
        if results.total > 0 { parts.append("\(results.total) match\(results.total == 1 ? "" : "es")") }
        if !model.codeMatches.isEmpty { parts.append("\(model.codeMatches.count) in file contents") }
        if !model.historyMatches.isEmpty { parts.append("\(model.historyMatches.count) commits changed it") }
        return parts.isEmpty ? "No matches for “\(results.query)”" : parts.joined(separator: " · ")
    }

    private var emptyState: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Nothing matches “\(model.globalSearch)”").font(Theme.Text.heading).foregroundStyle(Theme.ink)
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
                    Button { model.selectedCommitSHA = commit.sha } label: {
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
                }
            }
        }
    }

    private func unitsSection(_ units: [CodeUnit]) -> some View {
        section("Functions", units.count) {
            VStack(spacing: 0) {
                ForEach(units) { unit in
                    Button {
                        model.show(.hotspots)
                        model.selectedUnitID = unit.id
                        model.clearSearch()
                    } label: {
                        HStack(spacing: Theme.Space.s) {
                            if let row = model.rowsByID[unit.id] { RiskBadge(level: row.level, compact: true) }
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
                }
            }
        }
    }

    private func filesSection(_ files: [String]) -> some View {
        section("Files", files.count) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(files, id: \.self) { path in
                    Button {
                        model.pendingFileSelection = path
                        model.show(.files)
                        model.clearSearch()
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
                }
            }
        }
    }

    private var codeSection: some View {
        section("In file contents", model.codeMatches.count,
                info: "Matching lines in tracked files as they stand now, from `git grep`. "
                    + "Binary files are skipped.") {
            if model.deepSearchInFlight && model.codeMatches.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Searching file contents…").font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.codeMatches.prefix(30)) { match in
                        Button {
                            model.pendingFileSelection = match.path
                            model.show(.files)
                            model.clearSearch()
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
                    }
                }
            }
        }
    }

    private var historySection: some View {
        section("Commits that added or removed it", model.historyMatches.count,
                info: "Commits where the number of occurrences of this text changed — git's "
                    + "\"pickaxe\". This is how to find when something was introduced or deleted.") {
            VStack(spacing: 0) {
                ForEach(model.historyMatches, id: \.sha) { commit in
                    Button { model.selectedCommitSHA = commit.sha } label: {
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
                        model.show(.contributors)
                        model.selectedAuthor = person.name
                        model.clearSearch()
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
                    Button { model.show(.branches); model.clearSearch() } label: {
                        Label(name, systemImage: "arrow.triangle.branch")
                            .font(Theme.Text.caption).foregroundStyle(Theme.ink)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Theme.wash, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                ForEach(results.tags, id: \.self) { name in
                    Button {
                        model.compareTo = name
                        model.show(.releases)
                        model.clearSearch()
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
