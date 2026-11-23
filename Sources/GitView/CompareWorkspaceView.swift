import SwiftUI
import AppKit
import GitViewCore
import GitViewGit

/// Full two-pane diff & commit review workspace for comparing any two refs (`from..to`).
struct CompareWorkspaceView: View {
    enum SidebarTab: String, CaseIterable, Identifiable {
        case files = "Files"
        case commits = "Commits"
        var id: String { rawValue }
    }

    @Environment(WorkspaceSession.self) private var session
    @Environment(AppPreferences.self) private var preferences
    @AppStorage("gitview.comparePaneWidth") private var paneWidth: Double = 360
    @AppStorage("gitview.compareTreeView") private var showTreeView = false

    @State private var sidebarTab: SidebarTab = .files
    @State private var filterText = ""
    @State private var expandedFolders: Set<String> = []
    @State private var copiedNotes = false

    private var comparison: ComparisonResult? { session.navigation.comparison }

    private var filteredDeltas: [FileDelta] {
        let deltas = comparison?.deltas ?? []
        let q = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return deltas }
        return deltas.filter { $0.path.localizedCaseInsensitiveContains(q) }
    }

    private var filteredCommits: [Commit] {
        let commits = comparison?.commits ?? []
        let q = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return commits }
        return commits.filter {
            $0.subject.localizedCaseInsensitiveContains(q)
                || $0.author.localizedCaseInsensitiveContains(q)
                || $0.sha.localizedCaseInsensitiveContains(q)
        }
    }

    private var activeFilePath: String? {
        let deltas = filteredDeltas
        if let selected = session.navigation.compareSelectedFile,
           deltas.contains(where: { $0.path == selected }) {
            return selected
        }
        return deltas.first?.path ?? comparison?.deltas.first?.path
    }

    private var activeDiffRequest: DiffRequest? {
        guard let comparison, let path = activeFilePath else { return nil }
        return DiffRequest(
            source: .range(from: comparison.from, to: comparison.to),
            path: path,
            title: "\(comparison.from) → \(comparison.to)"
        )
    }

    var body: some View {
        let clampedWidth = min(max(paneWidth, 260), 520)

        VStack(spacing: 0) {
            workspaceHeader
            HairlineDivider()

            if session.navigation.comparisonInFlight && comparison == nil {
                VStack(spacing: Theme.Space.s) {
                    ProgressView()
                    Text("Comparing \(session.navigation.compareFrom) → \(session.navigation.compareTo)…")
                        .font(Theme.Text.body)
                        .foregroundStyle(Theme.inkSoft)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let comparison {
                if comparison.isEmpty {
                    VStack(spacing: Theme.Space.s) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 28))
                            .foregroundStyle(Theme.good)
                        Text("No differences between \(comparison.from) and \(comparison.to)")
                            .font(Theme.Text.heading)
                            .foregroundStyle(Theme.ink)
                        Text("Both references point to identical tree contents.")
                            .font(Theme.Text.body)
                            .foregroundStyle(Theme.inkMuted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HStack(spacing: 0) {
                        leftPane(comparison: comparison)
                            .frame(width: clampedWidth)
                            .background(Theme.sidebar.opacity(0.45))

                        VerticalPaneResizer(width: $paneWidth, range: 260...520, invertDrag: false)

                        rightPane
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .background(Theme.page)
        .onAppear {
            syncInlineDiff()
        }
        .onChange(of: activeDiffRequest) { _, next in
            syncInlineDiff(to: next)
        }
    }

    private func syncInlineDiff(to request: DiffRequest? = nil) {
        let target = request ?? activeDiffRequest
        if let target {
            session.inspector.showInlineDiff(target.source, path: target.path, title: target.title)
        } else {
            session.inspector.clearInlineDiff()
        }
    }

    private var workspaceHeader: some View {
        let fromRef = comparison?.from ?? session.navigation.compareFrom
        let toRef = comparison?.to ?? session.navigation.compareTo
        let stat = comparison?.stat ?? .zero

        return HStack(spacing: Theme.Space.m) {
            Button {
                session.navigation.isCompareWorkspacePresented = false
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(SecondaryButtonStyle())
            .controlSize(.small)

            HStack(spacing: 6) {
                Text(fromRef)
                    .font(Theme.Text.mono.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.inkMuted)
                Text(toRef)
                    .font(Theme.Text.mono.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let root = session.analysis?.root {
                Button {
                    session.navigation.openCompareWorkspace(from: toRef, to: fromRef, in: root)
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(GhostIconButtonStyle())
                .help("Swap comparison direction")
                .disabled(session.navigation.comparisonInFlight)
            }

            if session.navigation.comparisonInFlight {
                ProgressView().controlSize(.small)
            }

            Spacer()

            if let comparison, !comparison.isEmpty {
                HStack(spacing: Theme.Space.s) {
                    Chip(text: "\(comparison.commits.count) commit\(comparison.commits.count == 1 ? "" : "s")")
                    Chip(text: "\(comparison.deltas.count) file\(comparison.deltas.count == 1 ? "" : "s")")
                    Text("+\(stat.insertions)")
                        .font(Theme.Text.caption.monospacedDigit())
                        .foregroundStyle(Theme.good)
                    Text("−\(stat.deletions)")
                        .font(Theme.Text.caption.monospacedDigit())
                        .foregroundStyle(Theme.critical)
                }

                Button(copiedNotes ? "Copied" : "Copy Release Notes") {
                    let notes = ReleaseNotes.markdown(
                        title: "\(comparison.from) → \(comparison.to)",
                        commits: comparison.commits
                    )
                    copyToPasteboard(notes)
                    copiedNotes = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copiedNotes = false
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .controlSize(.small)
            }
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, Theme.Space.m)
        .background(Theme.raised)
    }

    private func leftPane(comparison: ComparisonResult) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.xs) {
                    SegmentPicker(
                        options: [
                            (.files, "Files (\(comparison.deltas.count))"),
                            (.commits, "Commits (\(comparison.commits.count))"),
                        ],
                        selection: $sidebarTab
                    )
                    Spacer(minLength: 0)
                    if sidebarTab == .files {
                        Button {
                            showTreeView.toggle()
                        } label: {
                            Image(systemName: showTreeView ? "list.bullet.indent" : "list.bullet")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(showTreeView ? Theme.accent : Theme.inkSoft)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .controlSize(.small)
                        .help(showTreeView ? "Show flat file list" : "Group changed files by folder")
                    }
                }

                SearchField(
                    text: $filterText,
                    prompt: sidebarTab == .files ? "Filter changed files…" : "Filter commits…",
                    focusTrigger: session.navigation.focusLocalFindRequest
                )
            }
            .padding(Theme.Space.m)

            HairlineDivider()

            ScrollColumn {
                LazyVStack(spacing: 0) {
                    switch sidebarTab {
                    case .files:
                        if filteredDeltas.isEmpty {
                            emptyListNotice("No matching files.")
                        } else if showTreeView {
                            treeFileList(filteredDeltas)
                        } else {
                            flatFileList(filteredDeltas)
                        }
                    case .commits:
                        if filteredCommits.isEmpty {
                            emptyListNotice("No matching commits.")
                        } else {
                            commitsList(filteredCommits)
                        }
                    }
                }
                .padding(.vertical, Theme.Space.xs)
            }
        }
    }

    @ViewBuilder
    private func flatFileList(_ deltas: [FileDelta]) -> some View {
        ForEach(deltas) { delta in
            deltaRow(delta: delta, displayName: (delta.path as NSString).lastPathComponent, indentLevel: 0)
            if delta.id != deltas.last?.id {
                HairlineDivider()
            }
        }
    }

    @ViewBuilder
    private func treeFileList(_ deltas: [FileDelta]) -> some View {
        let deltaByPath = Dictionary(uniqueKeysWithValues: deltas.map { ($0.path, $0) })
        let tree = FileTree(paths: deltas.map(\.path))
        let allFolders = Set(deltas.compactMap { delta -> [String] in
            var parts = delta.path.split(separator: "/").dropLast()
            var acc: [String] = []
            while !parts.isEmpty {
                acc.append(parts.joined(separator: "/"))
                parts = parts.dropLast()
            }
            return acc
        }.flatMap { $0 })
        let openFolders = expandedFolders.union(filterText.isEmpty ? allFolders : allFolders)
        let nodes = tree.visibleNodes(expanded: openFolders, filter: filterText)

        ForEach(nodes) { node in
            if node.isDirectory {
                let isOpen = openFolders.contains(node.path)
                Button {
                    if expandedFolders.contains(node.path) {
                        expandedFolders.remove(node.path)
                    } else {
                        expandedFolders.insert(node.path)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.inkMuted)
                            .frame(width: 10)
                        Image(systemName: "folder.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.accent.opacity(0.8))
                        Text(node.name)
                            .font(Theme.Text.caption.weight(.semibold))
                            .foregroundStyle(Theme.inkSoft)
                            .lineLimit(1)
                        Spacer()
                        Text("\(node.fileCount)")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(Theme.inkMuted)
                    }
                    .padding(.leading, Theme.Space.m + CGFloat(max(0, node.depth - 1)) * 12)
                    .padding(.trailing, Theme.Space.m)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else if let delta = deltaByPath[node.path] {
                deltaRow(delta: delta, displayName: node.name, indentLevel: max(0, node.depth - 1))
            }
        }
    }

    private func deltaRow(delta: FileDelta, displayName: String, indentLevel: Int) -> some View {
        let isSelected = activeFilePath == delta.path
        let folder = (delta.path as NSString).deletingLastPathComponent

        return Button {
            session.navigation.compareSelectedFile = delta.path
        } label: {
            HStack(spacing: Theme.Space.s) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(displayName)
                        .font(isSelected ? Theme.Text.bodyBold : Theme.Text.body)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if indentLevel == 0 && !folder.isEmpty && folder != "." {
                        Text(folder)
                            .font(Theme.Text.caption)
                            .foregroundStyle(Theme.inkMuted)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: Theme.Space.s)
                if delta.isBinary {
                    Chip(text: "bin")
                } else {
                    HStack(spacing: 4) {
                        if delta.insertions > 0 {
                            Text("+\(delta.insertions)").foregroundStyle(Theme.good)
                        }
                        if delta.deletions > 0 {
                            Text("−\(delta.deletions)").foregroundStyle(Theme.critical)
                        }
                    }
                    .font(Theme.Text.caption.monospacedDigit())
                }
            }
            .padding(.leading, Theme.Space.m + CGFloat(indentLevel) * 14)
            .padding(.trailing, Theme.Space.m)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Theme.accentWash : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { PathActions(path: delta.path) }
    }

    @ViewBuilder
    private func commitsList(_ commits: [Commit]) -> some View {
        ForEach(commits, id: \.sha) { commit in
            let isSelected = session.navigation.selectedCommitSHA == commit.sha
            Button {
                session.navigation.selectedCommitSHA = commit.sha
                session.inspector.ensureCommitDetail(sha: commit.sha)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(commit.subject.isEmpty ? "(no message)" : commit.subject)
                            .font(isSelected ? Theme.Text.bodyBold : Theme.Text.body)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        Spacer()
                        ShaChip(sha: commit.sha)
                    }
                    Text("\(commit.author) · \(RiskExplanation.relative(commit.date, now: Date()))")
                        .font(Theme.Text.caption)
                        .foregroundStyle(Theme.inkMuted)
                }
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isSelected ? Theme.accentWash : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if commit.sha != commits.last?.sha {
                HairlineDivider()
            }
        }
    }

    private func emptyListNotice(_ text: String) -> some View {
        Text(text)
            .font(Theme.Text.body)
            .foregroundStyle(Theme.inkMuted)
            .padding(Theme.Space.l)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var rightPane: some View {
        if let request = activeDiffRequest {
            DiffViewer(request: request, embedded: true)
        } else {
            VStack(spacing: Theme.Space.s) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.inkMuted)
                Text("Select a file to inspect its diff")
                    .font(Theme.Text.body)
                    .foregroundStyle(Theme.inkMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
