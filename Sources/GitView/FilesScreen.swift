import SwiftUI
import GitViewCore
import GitViewGit
import GitViewParse

/// Tracked-file tree with interactive code viewer, line-by-line blame gutter, and file overview.
struct FilesScreen: View {
    @Environment(WorkspaceSession.self) private var session
    @State private var expanded: Set<String> = [""]
    @State private var selectedPath: String? = nil
    @State private var query = ""

    /// Every folder on the way to a path, so a preselected file is visible.
    private static func ancestors(of path: String) -> Set<String> {
        var result = Set<String>()
        var parts = path.split(separator: "/").dropLast()
        while !parts.isEmpty {
            result.insert(parts.joined(separator: "/"))
            parts = parts.dropLast()
        }
        return result
    }

    var body: some View {
        if let analysis = session.analysis {
            let tree = session.risk.fileTree ?? FileTree(files: analysis.info.inventory.files, rows: session.risk.allRankedRows)
            // Resolved during evaluation rather than by a side effect: an offscreen render
            // completes before any async work could land.
            let pending = session.navigation.pendingFileSelection.flatMap { wanted in
                tree.node(at: wanted)?.path ?? tree.firstNode(matching: wanted)?.path
            }
            let chosen = selectedPath ?? pending
            let selectedNode = chosen.flatMap { tree.node(at: $0) }
            let openFolders = expanded.union(pending.map(Self.ancestors) ?? [])
            let visible = tree.visibleNodes(expanded: openFolders, filter: query)
            let isViewingFile = selectedNode.map { !$0.isDirectory } ?? false

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    ScreenHeader(title: "Files", subtitle: "Explore the repository structure, syntax-highlighted code, and line blame.")
                    HStack {
                        SearchField(text: $query, prompt: "Filter files",
                                    focusTrigger: isViewingFile ? 0 : session.navigation.focusLocalFindRequest)
                            .frame(maxWidth: 300)
                        Spacer()
                        Text("\(analysis.info.inventory.fileCount.formatted()) files · \(analysis.info.inventory.totalBytes.byteString)")
                            .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                    }
                }
                .padding(.horizontal, Theme.Space.xl).padding(.top, Theme.Space.xl).padding(.bottom, Theme.Space.l)

                HStack(alignment: .top, spacing: Theme.Space.l) {
                    Card(padding: Theme.Space.s) {
                        ScrollColumn {
                            LazyVStack(spacing: 0) {
                                ForEach(visible) { node in
                                    FileTreeRow(node: node, expanded: openFolders.contains(node.path), selected: chosen == node.path) {
                                        if node.isDirectory {
                                            if expanded.contains(node.path) { expanded.remove(node.path) } else { expanded.insert(node.path) }
                                        }
                                        selectedPath = node.path
                                    }
                                    .contextMenu {
                                        if node.isDirectory {
                                            Button("Reveal in Finder") {
                                                revealInFinder(analysis.root.appendingPathComponent(node.path))
                                            }
                                            Button("Copy Path") { copyToPasteboard(node.path) }
                                        } else {
                                            PathActions(path: node.path)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .frame(width: isViewingFile ? 280 : nil)
                    .frame(maxWidth: isViewingFile ? 280 : .infinity)

                    if let fileNode = selectedNode, !fileNode.isDirectory {
                        FileContentWorkspace(
                            node: fileNode,
                            root: analysis.root,
                            inventory: analysis.info.inventory,
                            info: analysis.info
                        )
                        .id(fileNode.path)
                        .frame(maxWidth: .infinity)
                    } else {
                        ScrollColumn {
                            VStack(alignment: .leading, spacing: Theme.Space.l) {
                                if let dirNode = selectedNode {
                                    FileInfoCard(node: dirNode, root: analysis.root)
                                    LanguagesCard(inventory: analysis.info.inventory)
                                    RepositorySizeCard(info: analysis.info)
                                } else {
                                    LanguagesCard(inventory: analysis.info.inventory)
                                    RepositorySizeCard(info: analysis.info)
                                    FileInfoCard(node: tree.root, root: analysis.root)
                                }
                            }
                        }
                        .frame(width: 320)
                    }
                }
                .padding(.horizontal, Theme.Space.xl).padding(.bottom, Theme.Space.xl)
            }
        }
    }
}

private struct FileContentWorkspace: View {
    enum Mode: String, CaseIterable {
        case code = "Code"
        case blame = "Blame"
        case overview = "Overview"
    }

    struct BlameRow: Identifiable {
        var id: Int { line.lineNumber }
        let line: BlameOwnership.Line
        let isRunStart: Bool
    }

    @Environment(WorkspaceSession.self) private var session
    @Environment(InspectorStore.self) private var inspector
    let node: FileTree.Node
    let root: URL
    let inventory: FileInventory
    let info: RepositoryInfo

    @State private var mode: Mode = .code
    @State private var codeSearchQuery = ""
    @State private var filterMatchesOnly = false
    @State private var codeLines: [String] = []
    @State private var codeSpans: [[HighlightSpan]] = []
    @State private var isBinaryFile = false
    @State private var isTruncatedFile = false
    @State private var fileLoading = false
    @State private var fileReadError: String?

    @State private var blameStack: [(path: String, revision: String)] = []
    @State private var blameSpans: [[HighlightSpan]] = []

    private var activeBlamePath: String { blameStack.last?.path ?? node.path }
    private var activeBlameRevision: String? { blameStack.last?.revision }
    private var trimmedCodeQuery: String { codeSearchQuery.trimmingCharacters(in: .whitespaces) }

    private var activeBlame: BlameOwnership? {
        inspector.blame(for: activeBlamePath, revision: activeBlameRevision)
    }

    private var isActiveBlameLoading: Bool {
        inspector.isBlameInFlight(for: activeBlamePath, revision: activeBlameRevision)
    }

    var body: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                header
                if mode == .code || mode == .blame {
                    HairlineDivider()
                    searchStrip
                }
                if mode == .blame && !blameStack.isEmpty {
                    HairlineDivider()
                    blameBreadcrumb
                }
                HairlineDivider()
                workspaceBody
            }
        }
        .task(id: node.path) {
            await loadCodeContent()
        }
        .task(id: blameTaskKey) {
            guard mode == .blame else { return }
            inspector.loadBlame(for: activeBlamePath, revision: activeBlameRevision)
        }
        .task(id: activeBlame) {
            await highlightActiveBlame()
        }
    }

    private var blameTaskKey: String {
        "\(mode == .blame ? "B" : "C"):\(activeBlameRevision ?? "WORKTREE"):\(activeBlamePath)"
    }

    private var header: some View {
        HStack(spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Space.s) {
                    Text(node.name).font(Theme.Text.heading).foregroundStyle(Theme.ink).lineLimit(1)
                    if isTruncatedFile && mode == .code {
                        Chip(text: "truncated at 512 KB", tint: Theme.warning)
                    }
                }
                Text(node.path).font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            SegmentPicker(
                options: Mode.allCases.map { ($0, $0.rawValue) },
                selection: $mode
            )
            Button("History") { inspector.showFileHistory(node.path) }
                .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
            Button("Open") { openInEditor(root.appendingPathComponent(node.path)) }
                .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
        }
        .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m)
    }

    private var searchStrip: some View {
        let query = trimmedCodeQuery
        let matchesCount: Int = {
            guard !query.isEmpty else { return 0 }
            if mode == .code {
                return codeLines.count(where: { $0.localizedCaseInsensitiveContains(query) })
            }
            return activeBlame?.lines.count(where: { $0.text.localizedCaseInsensitiveContains(query) }) ?? 0
        }()
        return HStack(spacing: Theme.Space.s) {
            SearchField(text: $codeSearchQuery, prompt: "Find in file…",
                        focusTrigger: session.navigation.focusLocalFindRequest)
                .frame(maxWidth: 260)
            if !query.isEmpty {
                Text("\(matchesCount) line\(matchesCount == 1 ? "" : "s")")
                    .font(Theme.Text.caption.monospacedDigit())
                    .foregroundStyle(Theme.inkMuted)
                Toggle("Matches only", isOn: $filterMatchesOnly)
                    .toggleStyle(.checkbox)
                    .font(Theme.Text.caption)
                    .foregroundStyle(Theme.inkSoft)
            }
            Spacer()
            if mode == .blame, let blame = activeBlame {
                Text("\(blame.totalLines.formatted()) lines · \(blame.authors.count) author\(blame.authors.count == 1 ? "" : "s")")
                    .font(Theme.Text.caption.monospacedDigit())
                    .foregroundStyle(Theme.inkMuted)
            }
        }
        .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.s)
        .background(Theme.wash)
    }

    private var blameBreadcrumb: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 11)).foregroundStyle(Theme.accent)
            if let rev = activeBlameRevision {
                Text("Blame at \(String(rev.prefix(7))) (\(activeBlamePath))")
                    .font(Theme.Text.caption).foregroundStyle(Theme.inkSoft)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("Back") {
                if !blameStack.isEmpty { blameStack.removeLast() }
            }
            .buttonStyle(SecondaryButtonStyle()).controlSize(.mini)
            Button("Current") {
                blameStack.removeAll()
            }
            .buttonStyle(SecondaryButtonStyle()).controlSize(.mini)
        }
        .padding(.horizontal, Theme.Space.l).padding(.vertical, 6)
        .background(Theme.accentWash.opacity(0.6))
    }

    @ViewBuilder
    private var workspaceBody: some View {
        switch mode {
        case .code:
            codeView
        case .blame:
            blameView
        case .overview:
            ScrollColumn {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    FileInfoCard(node: node, root: root)
                    LanguagesCard(inventory: inventory)
                    RepositorySizeCard(info: info)
                }
                .padding(Theme.Space.l)
            }
        }
    }

    @ViewBuilder
    private var codeView: some View {
        if fileLoading && codeLines.isEmpty {
            centeredProgress("Reading \(node.name)…")
        } else if isBinaryFile {
            centeredMessage("Binary file", "No text preview available.")
        } else if let fileReadError {
            centeredMessage("Could not read file", fileReadError)
        } else {
            let query = trimmedCodeQuery
            let indexed = codeLines.enumerated().map { (lineNumber: $0.offset + 1, text: $0.element, spans: $0.offset < codeSpans.count ? codeSpans[$0.offset] : []) }
            let rows = (filterMatchesOnly && !query.isEmpty)
                ? indexed.filter { $0.text.localizedCaseInsensitiveContains(query) }
                : indexed
            ScrollColumn {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows, id: \.lineNumber) { row in
                        HStack(alignment: .top, spacing: 0) {
                            Text("\(row.lineNumber)")
                                .font(Theme.Text.mono)
                                .foregroundStyle(Theme.inkMuted)
                                .frame(width: 48, alignment: .trailing)
                                .padding(.trailing, Theme.Space.m)
                            Text(Theme.Syntax.attributedLine(
                                row.text,
                                spans: row.spans,
                                baseForeground: Theme.ink,
                                searchQuery: query
                            ))
                            .font(Theme.Text.mono)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, Theme.Space.m)
                        .padding(.vertical, 1)
                        .contextMenu {
                            Button("Open in Editor at Line \(row.lineNumber)") {
                                openInEditor(root.appendingPathComponent(node.path), line: row.lineNumber)
                            }
                            Button("Copy Line") { copyToPasteboard(row.text) }
                        }
                    }
                }
                .padding(.vertical, Theme.Space.s)
            }
        }
    }

    @ViewBuilder
    private var blameView: some View {
        if isActiveBlameLoading && activeBlame == nil {
            centeredProgress("Reading line blame…")
        } else if let blame = activeBlame {
            if blame.lines.isEmpty {
                centeredMessage("No blame lines", "This file has no text lines to attribute.")
            } else {
                let query = trimmedCodeQuery
                let builtRows: [BlameRow] = blame.lines.enumerated().map { index, line in
                    let isStart = index == 0 || blame.lines[index - 1].sha != line.sha
                    return BlameRow(line: line, isRunStart: isStart)
                }
                let rows = (filterMatchesOnly && !query.isEmpty)
                    ? builtRows.filter { $0.line.text.localizedCaseInsensitiveContains(query) }
                    : builtRows
                ScrollColumn {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { entry in
                            blameLineRow(entry, blame: blame, query: query)
                        }
                    }
                    .padding(.vertical, Theme.Space.xs)
                }
            }
        } else {
            centeredMessage("Blame unavailable", "Git could not attribute this file at the selected revision.")
        }
    }

    private func blameLineRow(_ entry: BlameRow, blame: BlameOwnership, query: String) -> some View {
        let line = entry.line
        let lineIdx = line.lineNumber - 1
        let spans = (lineIdx >= 0 && lineIdx < blameSpans.count) ? blameSpans[lineIdx] : []
        let heat = ageHeatColor(for: line.date, oldest: blame.oldestLine, newest: blame.newestLine)
        let isSelectedCommit = session.navigation.selectedCommitSHA == line.sha

        return VStack(spacing: 0) {
            if entry.isRunStart && line.lineNumber > 1 {
                HairlineDivider()
            }
            HStack(alignment: .top, spacing: 0) {
                Button {
                    guard !line.isUncommitted else { return }
                    session.navigation.selectedCommitSHA = line.sha
                    inspector.ensureCommitDetail(sha: line.sha)
                } label: {
                    HStack(spacing: 6) {
                        Rectangle().fill(heat).frame(width: 3)
                        if entry.isRunStart {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 4) {
                                    Text(line.isUncommitted ? "Draft" : String(line.sha.prefix(7)))
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(line.isUncommitted ? Theme.warning : Theme.accent)
                                    Text(line.author.isEmpty ? (line.isUncommitted ? "Uncommitted" : "Unknown") : line.author)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(Theme.ink)
                                        .lineLimit(1)
                                    Spacer(minLength: 2)
                                    if let date = line.date {
                                        Text(RiskExplanation.relative(date, now: Date()))
                                            .font(.system(size: 9))
                                            .foregroundStyle(Theme.inkMuted)
                                            .lineLimit(1)
                                    }
                                }
                                if !line.summary.isEmpty {
                                    Text(line.summary)
                                        .font(.system(size: 10))
                                        .foregroundStyle(Theme.inkSoft)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                            }
                        } else {
                            Spacer(minLength: 0)
                        }
                    }
                    .frame(width: 248, alignment: .leading)
                    .padding(.vertical, 1)
                    .background(isSelectedCommit ? Theme.accentWash : Theme.wash.opacity(0.6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Rectangle().fill(Theme.hairline).frame(width: 1)

                Text("\(line.lineNumber)")
                    .font(Theme.Text.mono)
                    .foregroundStyle(Theme.inkMuted)
                    .frame(width: 44, alignment: .trailing)
                    .padding(.trailing, Theme.Space.s)
                    .padding(.vertical, 1)

                Text(Theme.Syntax.attributedLine(
                    line.text,
                    spans: spans,
                    baseForeground: Theme.ink,
                    searchQuery: query
                ))
                .font(Theme.Text.mono)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.vertical, 1)

                Spacer(minLength: 0)
            }
        }
        .contextMenu {
            if !line.isUncommitted {
                Button("Show Commit") {
                    session.navigation.selectedCommitSHA = line.sha
                    inspector.ensureCommitDetail(sha: line.sha)
                }
            }
            if let prevSHA = line.previousSHA {
                Button("Blame Before This Commit") {
                    blameStack.append((path: line.previousPath ?? activeBlamePath, revision: prevSHA))
                }
            }
            if blameStack.isEmpty {
                Button("Open in Editor at Line \(line.lineNumber)") {
                    openInEditor(root.appendingPathComponent(node.path), line: line.lineNumber)
                }
            }
            Button("Copy Line") { copyToPasteboard(line.text) }
        }
    }

    private func centeredProgress(_ label: String) -> some View {
        VStack(spacing: Theme.Space.s) {
            ProgressView().controlSize(.small)
            Text(label).font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func centeredMessage(_ title: String, _ detail: String) -> some View {
        VStack(spacing: Theme.Space.s) {
            Text(title).font(Theme.Text.heading).foregroundStyle(Theme.ink)
            Text(detail).font(Theme.Text.body).foregroundStyle(Theme.inkSoft)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func ageHeatColor(for date: Date?, oldest: Date?, newest: Date?) -> Color {
        guard let date else { return Theme.inkMuted.opacity(0.35) }
        guard let oldest, let newest, newest > oldest else { return Theme.accent.opacity(0.75) }
        let span = newest.timeIntervalSince(oldest)
        let fraction = min(max(date.timeIntervalSince(oldest) / span, 0), 1)
        return Theme.accent.opacity(0.22 + 0.78 * fraction)
    }

    private func loadCodeContent() async {
        fileLoading = true
        fileReadError = nil
        let targetPath = node.path
        let repoRoot = root
        let result = await Task.detached(priority: .userInitiated) { () -> Result<(lines: [String], spans: [[HighlightSpan]], isBinary: Bool, truncated: Bool), Error> in
            do {
                let loaded = try GitRepository(url: repoRoot).fileContent(path: targetPath)
                guard !loaded.isBinary else {
                    return .success(([], [], true, false))
                }
                let lines = loaded.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                let spans = SyntaxHighlighter.highlightLines(source: loaded.text, filePath: targetPath)
                return .success((lines, spans, false, loaded.truncated))
            } catch {
                return .failure(error)
            }
        }.value
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let value):
            codeLines = value.lines
            codeSpans = value.spans
            isBinaryFile = value.isBinary
            isTruncatedFile = value.truncated
        case .failure(let error):
            fileReadError = "\(error)"
        }
        fileLoading = false
    }

    private func highlightActiveBlame() async {
        guard let blame = activeBlame, !blame.lines.isEmpty else {
            blameSpans = []
            return
        }
        let path = activeBlamePath
        let source = blame.lines.map(\.text).joined(separator: "\n")
        let computed = await Task.detached(priority: .userInitiated) {
            SyntaxHighlighter.highlightLines(source: source, filePath: path)
        }.value
        guard !Task.isCancelled else { return }
        blameSpans = computed
    }
}

struct FileTreeRow: View {
    let node: FileTree.Node
    let expanded: Bool
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Spacer().frame(width: CGFloat(max(node.depth - 1, 0)) * 16)
                Image(systemName: node.isDirectory ? (expanded ? "chevron.down" : "chevron.right") : "")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.inkMuted).frame(width: 12)
                Image(systemName: node.isDirectory ? "folder.fill" : "doc.text")
                    .font(.system(size: 12)).foregroundStyle(node.isDirectory ? Theme.accent : Theme.inkMuted)
                Text(node.name).font(Theme.Text.body).foregroundStyle(Theme.ink).lineLimit(1)
                if node.hotspots > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "flame.fill").font(.system(size: 9))
                        Text("\(node.hotspots)").font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(Theme.serious)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Theme.serious.opacity(0.14), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .help("\(node.hotspots) critical or high-risk function\(node.hotspots == 1 ? "" : "s") inside")
                }
                Spacer()
                Text(node.isDirectory ? "\(node.fileCount) file\(node.fileCount == 1 ? "" : "s")" : node.bytes.byteString)
                    .font(Theme.Text.caption.monospacedDigit()).foregroundStyle(Theme.inkMuted)
            }
            .padding(.horizontal, Theme.Space.s).padding(.vertical, 5)
            .background(selected ? Theme.accentWash : (hovering ? Theme.wash : .clear),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct FileInfoCard: View {
    @Environment(WorkspaceSession.self) private var session
    let node: FileTree.Node
    let root: URL

    private var url: URL { node.path.isEmpty ? root : root.appendingPathComponent(node.path) }
    /// A file lists all its ranked functions; a directory lists only what needs attention,
    /// otherwise the root would list every function in the repository.
    private var hotspotRows: [RiskRow] {
        if node.isDirectory {
            let prefix = node.path.isEmpty ? "" : node.path + "/"
            return session.risk.rows.filter { $0.filePath.hasPrefix(prefix) && ($0.level == .critical || $0.level == .high) }
        }
        return session.risk.rows.filter { $0.filePath == node.path }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(spacing: Theme.Space.m) {
                    Image(systemName: node.isDirectory ? "folder.fill" : "doc.text.fill")
                        .font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.accent)
                        .frame(width: 40, height: 40)
                        .background(Theme.accentWash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.path.isEmpty ? root.lastPathComponent : node.name).font(Theme.Text.heading).foregroundStyle(Theme.ink).lineLimit(2)
                        Text(node.isDirectory ? "Directory" : (url.pathExtension.isEmpty ? "File" : url.pathExtension.uppercased() + " file"))
                            .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                    }
                }
                VStack(spacing: 0) {
                    if node.isDirectory { infoRow("doc.on.doc", "\(node.fileCount.formatted()) file\(node.fileCount == 1 ? "" : "s")") }
                    infoRow("internaldrive", node.bytes.byteString)
                    if let modified = node.modified {
                        infoRow("clock", "Modified \(RiskExplanation.relative(modified, now: Date()))")
                    }
                }
                HStack(spacing: Theme.Space.s) {
                    if !node.isDirectory {
                        Button { session.inspector.showFileHistory(node.path) } label: {
                            Label("History", systemImage: "clock.arrow.circlepath")
                        }
                        .buttonStyle(PrimaryButtonStyle()).controlSize(.small)
                    }
                    Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Label("Finder", systemImage: "folder") }
                        .buttonStyle(SecondaryButtonStyle())
                    if !node.isDirectory {
                        Button { openInEditor(url) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
                if let ownership = session.ownership {
                    HairlineDivider()
                    OwnershipSection(
                        filePath: node.isDirectory ? nil : node.path,
                        ownership: node.isDirectory ? nil : ownership.ownership(of: node.path),
                        directory: node.isDirectory ? ownership.ownership(ofDirectory: node.path) : nil)
                }

                let rows = hotspotRows
                if !rows.isEmpty {
                    HairlineDivider()
                    HStack {
                        Text(node.isDirectory ? "Needs attention inside" : "Functions").font(Theme.Text.heading).foregroundStyle(Theme.ink)
                        Spacer()
                        Text("\(rows.count)").font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                    }
                    VStack(spacing: 4) {
                        ForEach(rows.prefix(6)) { row in
                            Button { session.navigation.selectedUnitID = row.id } label: {
                                HStack(spacing: Theme.Space.s) {
                                    RiskBadge(level: row.level, compact: true)
                                    Text(row.name.split(separator: ".").suffix(2).joined(separator: "."))
                                        .font(Theme.Text.body).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text("cx \(row.complexity)").font(Theme.Text.caption.monospacedDigit()).foregroundStyle(Theme.inkMuted)
                                }
                                .padding(.vertical, 3)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        if rows.count > 6 {
                            Text("and \(rows.count - 6) more…").font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                        }
                    }
                }
            }
        }
    }

    private func infoRow(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(Theme.inkMuted).frame(width: 16)
            Text(text).font(Theme.Text.body).foregroundStyle(Theme.inkSoft)
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
