import SwiftUI
import GitViewCore
import GitViewGit
import GitViewParse

/// Tracked-file tree with interactive code viewer, line-by-line blame gutter, and file overview.
struct FilesScreen: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(AppPreferences.self) private var preferences
    @AppStorage("gitview.filesTreeWidth") private var filesTreeWidth: Double = 280
    @State private var expanded: Set<String> = [""]
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
            let chosen = pending ?? session.navigation.selectedFilePath
            let selectedNode = chosen.flatMap { tree.node(at: $0) }
            let openFolders = expanded.union(chosen.map(Self.ancestors) ?? [])
            let visible = tree.visibleNodes(expanded: openFolders, filter: query)
            let isViewingFile = selectedNode.map { !$0.isDirectory } ?? false
            let clampedTreeWidth = min(max(filesTreeWidth, 220), 460)

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    ScreenHeader(
                        title: "Files",
                        subtitle: preferences.advanced
                            ? "Explore the repository structure, syntax-highlighted code, and line blame."
                            : "Browse folders and source files in this repository."
                    )
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

                HStack(alignment: .top, spacing: isViewingFile ? Theme.Space.xs : Theme.Space.l) {
                    Card(padding: Theme.Space.s) {
                        ScrollColumn {
                            LazyVStack(spacing: 0) {
                                ForEach(visible) { node in
                                    FileTreeRow(
                                        node: node,
                                        expanded: openFolders.contains(node.path),
                                        selected: chosen == node.path,
                                        showHotspots: preferences.advanced
                                    ) {
                                        if node.isDirectory {
                                            if expanded.contains(node.path) { expanded.remove(node.path) } else { expanded.insert(node.path) }
                                        }
                                        session.navigation.pendingFileSelection = nil
                                        session.navigation.selectedFilePath = node.path
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
                    .frame(width: isViewingFile ? clampedTreeWidth : nil)
                    .frame(maxWidth: isViewingFile ? clampedTreeWidth : .infinity)

                    if isViewingFile {
                        VerticalPaneResizer(width: $filesTreeWidth, range: 220...460, invertDrag: false)
                    }

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
            .onAppear {
                if let pending {
                    session.navigation.selectedFilePath = pending
                    expanded.formUnion(Self.ancestors(of: pending))
                    session.navigation.pendingFileSelection = nil
                } else if let existing = session.navigation.selectedFilePath {
                    expanded.formUnion(Self.ancestors(of: existing))
                }
            }
            .onChange(of: session.navigation.pendingFileSelection) { _, newValue in
                guard let newValue,
                      let resolved = tree.node(at: newValue)?.path ?? tree.firstNode(matching: newValue)?.path else { return }
                session.navigation.selectedFilePath = resolved
                expanded.formUnion(Self.ancestors(of: resolved))
                session.navigation.pendingFileSelection = nil
            }
        }
    }
}

private struct FileContentWorkspace: View {
    enum Mode: String, CaseIterable {
        case preview = "Preview"
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
    @Environment(AppPreferences.self) private var preferences
    @Environment(InspectorStore.self) private var inspector
    @Environment(\.staticRendering) private var staticRendering
    let node: FileTree.Node
    let root: URL
    let inventory: FileInventory
    let info: RepositoryInfo

    @State private var mode: Mode = .code
    @State private var codeSearchQuery = ""
    @State private var filterMatchesOnly = false
    @State private var codeLines: [String] = []
    @State private var codeSpans: [[HighlightSpan]] = []
    @State private var imageData: Data?
    @State private var isBinaryFile = false
    @State private var isTruncatedFile = false
    @State private var fileLoading = false
    @State private var fileReadError: String?

    @State private var blameStack: [(path: String, revision: String)] = []
    @State private var blameSpans: [[HighlightSpan]] = []

    @State private var highlightedLine: Int?
    @State private var scrollTargetLine: Int?
    @State private var scrollTrigger = 0
    @State private var showingGoToLine = false
    @State private var goToLineText = ""

    private var fileExtension: String {
        URL(fileURLWithPath: node.path).pathExtension.lowercased()
    }

    private var isMarkdownFile: Bool {
        fileExtension == "md" || fileExtension == "markdown"
    }

    private var isImageFile: Bool {
        GitRepository.supportedImageExtensions.contains(fileExtension) || fileExtension == "svg"
    }

    private var hasRenderableImage: Bool {
        imageData.flatMap(NSImage.init(data:)) != nil
    }

    private var fileUnits: [CodeUnit] {
        (session.analysis?.allUnits ?? [])
            .filter { $0.filePath == node.path }
            .sorted { $0.lineRange.lowerBound < $1.lineRange.lowerBound }
    }

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
                if (mode == .code || mode == .blame) && !hasRenderableImage {
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
            guard preferences.advanced && mode == .blame else { return }
            inspector.loadBlame(for: activeBlamePath, revision: activeBlameRevision)
        }
        .task(id: activeBlame) {
            await highlightActiveBlame()
        }
        .onChange(of: preferences.advanced) { _, isAdvanced in
            if !isAdvanced && mode == .blame { mode = .code }
        }
        .onChange(of: session.navigation.pendingFileLine) { _, newValue in
            guard let newValue, !fileLoading, !codeLines.isEmpty else { return }
            jumpToLine(newValue)
            session.navigation.pendingFileLine = nil
        }
        .onChange(of: session.navigation.focusGoToLineRequest) { _, newValue in
            guard newValue > 0, !hasRenderableImage, !isBinaryFile else { return }
            goToLineText = highlightedLine.map(String.init) ?? ""
            showingGoToLine = true
        }
    }

    private var blameTaskKey: String {
        "\(mode == .blame ? "B" : "C"):\(activeBlameRevision ?? "WORKTREE"):\(activeBlamePath)"
    }

    private func jumpToLine(_ line: Int) {
        let clamped = max(1, min(line, max(codeLines.count, activeBlame?.lines.count ?? line)))
        if mode == .overview || mode == .preview {
            mode = .code
        }
        highlightedLine = clamped
        scrollTargetLine = clamped
        scrollTrigger += 1
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
            let availableModes: [Mode] = {
                var items: [Mode] = []
                if isMarkdownFile && !isBinaryFile { items.append(.preview) }
                items.append(.code)
                if preferences.advanced && !hasRenderableImage { items.append(.blame) }
                items.append(.overview)
                return items
            }()
            SegmentPicker(
                options: availableModes.map { ($0, $0.rawValue) },
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
        let units = fileUnits
        return HStack(spacing: Theme.Space.s) {
            SearchField(text: $codeSearchQuery, prompt: "Find in file…",
                        focusTrigger: session.navigation.focusLocalFindRequest)
                .frame(maxWidth: 240)
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
            if !units.isEmpty {
                if staticRendering {
                    HStack(spacing: 4) {
                        Image(systemName: "curlybraces")
                            .font(.system(size: 10))
                        Text("Symbols (\(units.count))")
                            .font(Theme.Text.caption)
                    }
                    .foregroundStyle(Theme.inkSoft)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.hairline))
                } else {
                    Menu {
                        ForEach(units) { unit in
                            Button("\(unit.name)  :\(unit.lineRange.lowerBound)") {
                                jumpToLine(unit.lineRange.lowerBound)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "curlybraces")
                                .font(.system(size: 10))
                            Text("Symbols (\(units.count))")
                                .font(Theme.Text.caption)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.hairline))
                    .help("Jump to a function or symbol in this file")
                }
            }
            Button {
                preferences.wrapCodeLines.toggle()
            } label: {
                Image(systemName: "arrow.turn.down.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(preferences.wrapCodeLines ? Theme.accent : Theme.inkSoft)
            }
            .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(preferences.wrapCodeLines ? Theme.accent.opacity(0.6) : .clear, lineWidth: 1)
            )
            .help(preferences.wrapCodeLines ? "Wrap long lines (enabled)" : "Wrap long lines (disabled)")
            Button {
                goToLineText = highlightedLine.map(String.init) ?? ""
                showingGoToLine = true
            } label: {
                Label("Line", systemImage: "arrow.down.to.line")
            }
            .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
            .help("Go to line (⌘L)")
            .popover(isPresented: $showingGoToLine, arrowEdge: .bottom) {
                goToLinePopover
            }
            if mode == .blame, let blame = activeBlame {
                Text("\(blame.totalLines.formatted()) lines · \(blame.authors.count) author\(blame.authors.count == 1 ? "" : "s")")
                    .font(Theme.Text.caption.monospacedDigit())
                    .foregroundStyle(Theme.inkMuted)
            }
        }
        .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.s)
        .background(Theme.wash)
    }

    private var goToLinePopover: some View {
        let maxLine = max(codeLines.count, activeBlame?.lines.count ?? 1)
        let parsed = Int(goToLineText.trimmingCharacters(in: .whitespacesAndNewlines))
        let isValid = parsed.map { $0 >= 1 && $0 <= maxLine } ?? false
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Go to Line (1–\(maxLine))")
                .font(Theme.Text.heading).foregroundStyle(Theme.ink)
            TextField("Line number", text: $goToLineText)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    if let parsed, isValid {
                        showingGoToLine = false
                        jumpToLine(parsed)
                    }
                }
            HStack {
                Spacer()
                Button("Cancel") { showingGoToLine = false }
                    .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                Button("Go") {
                    if let parsed, isValid {
                        showingGoToLine = false
                        jumpToLine(parsed)
                    }
                }
                .buttonStyle(PrimaryButtonStyle()).controlSize(.small)
                .disabled(!isValid)
            }
        }
        .padding(Theme.Space.m)
        .frame(width: 240)
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
        case .preview:
            MarkdownDocumentView(source: codeLines.joined(separator: "\n"))
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
        if fileLoading && codeLines.isEmpty && imageData == nil {
            centeredProgress("Reading \(node.name)…")
        } else if let imageData, let nsImage = NSImage(data: imageData) {
            imagePreviewView(nsImage: nsImage, data: imageData)
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
            let lineNumWidth = max(48, CGFloat(preferences.codeFontSize) * 4.3)
            let codeFont = Theme.Text.monoFont(size: preferences.codeFontSize)
            let codeAxes: Axis.Set = preferences.wrapCodeLines ? .vertical : [.vertical, .horizontal]
            ScrollViewReader { proxy in
                ScrollColumn(axes: codeAxes) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows, id: \.lineNumber) { row in
                            let isHighlighted = highlightedLine == row.lineNumber
                            HStack(alignment: .top, spacing: 0) {
                                Text("\(row.lineNumber)")
                                    .font(codeFont)
                                    .foregroundStyle(isHighlighted ? Theme.accent : Theme.inkMuted)
                                    .frame(width: lineNumWidth, alignment: .trailing)
                                    .padding(.trailing, Theme.Space.m)
                                if preferences.wrapCodeLines {
                                    Text(Theme.Syntax.attributedLine(
                                        row.text,
                                        spans: row.spans,
                                        baseForeground: Theme.ink,
                                        searchQuery: query
                                    ))
                                    .font(codeFont)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                                } else {
                                    Text(Theme.Syntax.attributedLine(
                                        row.text,
                                        spans: row.spans,
                                        baseForeground: Theme.ink,
                                        searchQuery: query
                                    ))
                                    .font(codeFont)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .textSelection(.enabled)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, Theme.Space.m)
                            .padding(.vertical, 1)
                            .background(isHighlighted ? Theme.accentWash : .clear)
                            .overlay(alignment: .leading) {
                                if isHighlighted {
                                    Rectangle().fill(Theme.accent).frame(width: 3)
                                }
                            }
                            .id("code:\(row.lineNumber)")
                            .contextMenu {
                                Button("Open in Editor at Line \(row.lineNumber)") {
                                    openInEditor(root.appendingPathComponent(node.path), line: row.lineNumber)
                                }
                                Button("Copy Line") { copyToPasteboard(row.text) }
                                if let web = info.remoteWebURL,
                                   let sha = session.analysis?.workingState.headSHA ?? session.analysis?.commits.first?.sha,
                                   let permalink = GitHubBridge.linePermalinkURL(remoteWebURL: web, sha: sha, path: node.path, line: row.lineNumber) {
                                    Button("Copy Remote Permalink") { copyToPasteboard(permalink.absoluteString) }
                                }
                            }
                        }
                    }
                    .padding(.vertical, Theme.Space.s)
                }
                .onAppear {
                    if let target = scrollTargetLine {
                        proxy.scrollTo("code:\(target)", anchor: .center)
                    }
                }
                .onChange(of: scrollTrigger) {
                    if let target = scrollTargetLine {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            proxy.scrollTo("code:\(target)", anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private func imagePreviewView(nsImage: NSImage, data: Data) -> some View {
        let dims: (width: Int, height: Int) = {
            if let rep = NSBitmapImageRep(data: data), rep.pixelsWide > 0, rep.pixelsHigh > 0 {
                return (rep.pixelsWide, rep.pixelsHigh)
            }
            return (max(Int(nsImage.size.width), 0), max(Int(nsImage.size.height), 0))
        }()
        return ScrollColumn {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack {
                    Text("\(dims.width) × \(dims.height) px · \(Int64(data.count).byteString)")
                        .font(Theme.Text.caption.monospacedDigit())
                        .foregroundStyle(Theme.inkMuted)
                    Spacer()
                }
                ZStack {
                    CheckerboardBackdrop()
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .padding(Theme.Space.l)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 340, maxHeight: 520)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.hairline))
            }
            .padding(Theme.Space.l)
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
                ScrollViewReader { proxy in
                    ScrollColumn {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(rows) { entry in
                                blameLineRow(entry, blame: blame, query: query)
                                    .id("blame:\(entry.line.lineNumber)")
                            }
                        }
                        .padding(.vertical, Theme.Space.xs)
                    }
                    .onChange(of: scrollTrigger) {
                        if let target = scrollTargetLine {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                proxy.scrollTo("blame:\(target)", anchor: .center)
                            }
                        }
                    }
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

                let blameFont = Theme.Text.monoFont(size: preferences.codeFontSize)
                let blameLineNumWidth = max(44, CGFloat(preferences.codeFontSize) * 4.0)
                Text("\(line.lineNumber)")
                    .font(blameFont)
                    .foregroundStyle(Theme.inkMuted)
                    .frame(width: blameLineNumWidth, alignment: .trailing)
                    .padding(.trailing, Theme.Space.s)
                    .padding(.vertical, 1)

                Text(Theme.Syntax.attributedLine(
                    line.text,
                    spans: spans,
                    baseForeground: Theme.ink,
                    searchQuery: query
                ))
                .font(blameFont)
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
            if !line.isUncommitted,
               let web = info.remoteWebURL,
               let permalink = GitHubBridge.linePermalinkURL(
                remoteWebURL: web,
                sha: line.sha,
                path: activeBlamePath,
                line: line.lineNumber
               ) {
                Button("Copy Remote Permalink") { copyToPasteboard(permalink.absoluteString) }
            }
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
        imageData = nil
        let targetPath = node.path
        let repoRoot = root
        let shouldTryImage = isImageFile
        let result = await Task.detached(priority: .userInitiated) { () -> Result<(lines: [String], spans: [[HighlightSpan]], imageData: Data?, isBinary: Bool, truncated: Bool), Error> in
            if shouldTryImage {
                let url = repoRoot.appendingPathComponent(targetPath)
                if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                   let size = (attrs[.size] as? NSNumber)?.intValue,
                   size > 0, size <= 25_000_000,
                   let data = try? Data(contentsOf: url),
                   NSImage(data: data) != nil {
                    return .success(([], [], data, false, false))
                }
            }
            do {
                let loaded = try GitRepository(url: repoRoot).fileContent(path: targetPath)
                guard !loaded.isBinary else {
                    return .success(([], [], nil, true, false))
                }
                let lines = loaded.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                let spans = SyntaxHighlighter.highlightLines(source: loaded.text, filePath: targetPath)
                return .success((lines, spans, nil, false, loaded.truncated))
            } catch {
                return .failure(error)
            }
        }.value
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let value):
            imageData = value.imageData
            codeLines = value.lines
            codeSpans = value.spans
            isBinaryFile = value.isBinary
            isTruncatedFile = value.truncated
            if let pendingLine = session.navigation.pendingFileLine, !value.lines.isEmpty {
                jumpToLine(pendingLine)
                session.navigation.pendingFileLine = nil
            }
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
    var showHotspots: Bool = true
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
                if showHotspots && node.hotspots > 0 {
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
    @Environment(AppPreferences.self) private var preferences
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

                if preferences.advanced {
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

private struct MarkdownDocumentView: View {
    enum Block: Identifiable {
        case heading(id: Int, level: Int, text: String)
        case paragraph(id: Int, text: String)
        case codeBlock(id: Int, language: String, code: String)
        case listItem(id: Int, bullet: String, text: String)
        case blockquote(id: Int, text: String)
        case divider(id: Int)

        var id: Int {
            switch self {
            case .heading(let id, _, _),
                 .paragraph(let id, _),
                 .codeBlock(let id, _, _),
                 .listItem(let id, _, _),
                 .blockquote(let id, _),
                 .divider(let id):
                return id
            }
        }
    }

    @Environment(AppPreferences.self) private var preferences
    let source: String

    private var blocks: [Block] { Self.parse(source) }

    var body: some View {
        ScrollColumn {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                ForEach(blocks) { block in
                    blockView(block)
                }
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .heading(_, let level, let text):
            VStack(alignment: .leading, spacing: 6) {
                Text(inlineMarkdown(text))
                    .font(headingFont(level: level))
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                if level <= 2 {
                    HairlineDivider()
                }
            }
            .padding(.top, level == 1 ? 4 : 8)

        case .paragraph(_, let text):
            Text(inlineMarkdown(text))
                .font(Theme.Text.body)
                .foregroundStyle(Theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

        case .codeBlock(_, let language, let code):
            VStack(alignment: .leading, spacing: 4) {
                if !language.isEmpty {
                    Text(language)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.inkMuted)
                }
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(code.isEmpty ? " " : code)
                        .font(Theme.Text.monoFont(size: preferences.codeFontSize))
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                }
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.hairline))

        case .listItem(_, let bullet, let text):
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Text(bullet)
                    .font(Theme.Text.bodyBold)
                    .foregroundStyle(Theme.accent)
                    .frame(minWidth: 16, alignment: .trailing)
                Text(inlineMarkdown(text))
                    .font(Theme.Text.body)
                    .foregroundStyle(Theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(.leading, 4)

        case .blockquote(_, let text):
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Rectangle().fill(Theme.accent.opacity(0.6)).frame(width: 3)
                Text(inlineMarkdown(text))
                    .font(Theme.Text.body)
                    .foregroundStyle(Theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, Theme.Space.s)
            .background(Theme.wash.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))

        case .divider:
            HairlineDivider()
                .padding(.vertical, Theme.Space.xs)
        }
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1: return .system(size: 22, weight: .bold)
        case 2: return .system(size: 18, weight: .semibold)
        case 3: return .system(size: 15, weight: .semibold)
        default: return .system(size: 13, weight: .semibold)
        }
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    private static func parse(_ source: String) -> [Block] {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [Block] = []
        var nextID = 0
        func makeID() -> Int { defer { nextID += 1 }; return nextID }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                i += 1
                continue
            }

            if trimmed.hasPrefix("```") {
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count {
                    let current = lines[i]
                    if current.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        i += 1
                        break
                    }
                    codeLines.append(current)
                    i += 1
                }
                blocks.append(.codeBlock(id: makeID(), language: language, code: codeLines.joined(separator: "\n")))
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                blocks.append(.divider(id: makeID()))
                i += 1
                continue
            }

            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix(while: { $0 == "#" }).count
                if hashes >= 1, hashes <= 6, trimmed.dropFirst(hashes).first == " " {
                    let text = String(trimmed.dropFirst(hashes + 1)).trimmingCharacters(in: .whitespaces)
                    blocks.append(.heading(id: makeID(), level: hashes, text: text))
                    i += 1
                    continue
                }
            }

            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while i < lines.count {
                    let qt = lines[i].trimmingCharacters(in: .whitespaces)
                    guard qt.hasPrefix(">") else { break }
                    let content = qt.dropFirst().trimmingCharacters(in: .whitespaces)
                    quoteLines.append(content)
                    i += 1
                }
                blocks.append(.blockquote(id: makeID(), text: quoteLines.joined(separator: " ")))
                continue
            }

            if let listMatch = parseListItem(trimmed) {
                blocks.append(.listItem(id: makeID(), bullet: listMatch.bullet, text: listMatch.body))
                i += 1
                continue
            }

            var paragraphLines: [String] = []
            while i < lines.count {
                let pTrim = lines[i].trimmingCharacters(in: .whitespaces)
                if pTrim.isEmpty || pTrim.hasPrefix("```") || pTrim.hasPrefix("#") || pTrim.hasPrefix(">")
                    || pTrim == "---" || pTrim == "***" || pTrim == "___" || parseListItem(pTrim) != nil {
                    break
                }
                paragraphLines.append(pTrim)
                i += 1
            }
            if !paragraphLines.isEmpty {
                blocks.append(.paragraph(id: makeID(), text: paragraphLines.joined(separator: " ")))
            } else {
                i += 1
            }
        }
        return blocks
    }

    private static func parseListItem(_ trimmed: String) -> (bullet: String, body: String)? {
        for prefix in ["- ", "* ", "+ "] where trimmed.hasPrefix(prefix) {
            return ("•", String(trimmed.dropFirst(2)))
        }
        if let dot = trimmed.firstIndex(of: ".") {
            let numPart = trimmed[..<dot]
            let restStart = trimmed.index(after: dot)
            if !numPart.isEmpty, numPart.allSatisfy(\.isNumber),
               restStart < trimmed.endIndex, trimmed[restStart] == " " {
                let bodyStart = trimmed.index(after: restStart)
                return ("\(numPart).", String(trimmed[bodyStart...]))
            }
        }
        return nil
    }
}
