import SwiftUI
import AppKit
import GitViewCore
import GitViewGit
import GitViewParse

/// A diff viewer supporting syntax highlighting, word-level inline emphasis, unified & side-by-side layouts, and find-in-diff.
struct DiffViewer: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(AppPreferences.self) private var preferences
    @Environment(InspectorStore.self) private var inspector
    @Environment(WorkingCopyStore.self) private var workingCopy
    @Environment(\.staticRendering) private var staticRendering
    let request: DiffRequest
    var embedded: Bool = false

    @State private var showingFindBar = false
    @State private var searchQuery = ""
    @State private var filterMatchesOnly = false
    @State private var currentMatchIndex = 0
    @State private var currentHunkIndex = 0
    @State private var hunkJumpTrigger = 0
    @State private var spansByLineID: [Int: [HighlightSpan]] = [:]
    @State private var fileSpansByLineNumber: [[HighlightSpan]] = []
    @State private var inlineRangesByLineID: [Int: [Range<Int>]] = [:]
    @State private var selectedLineIDs: Set<Int> = []
    @State private var expandedGaps: [Int: GapExpansion] = [:]
    @FocusState private var findFieldFocused: Bool

    private var activeDiff: FileDiff? {
        embedded ? inspector.inlineLoadedDiff : inspector.loadedDiff
    }

    private var activeFileLines: [String]? {
        embedded ? inspector.inlineLoadedDiffFileLines : inspector.loadedDiffFileLines
    }

    private var activeImageDiff: ImageDiffData? {
        embedded ? inspector.inlineLoadedImageDiff : inspector.loadedImageDiff
    }

    private var activeDiffInFlight: Bool {
        embedded ? inspector.inlineDiffInFlight : inspector.diffInFlight
    }

    private func reloadActiveDiff() {
        if embedded {
            inspector.reloadInlineDiff()
        } else {
            inspector.reloadDiff()
        }
    }

    private var isUntrackedFile: Bool {
        guard case .workingTree(staged: false) = request.source else { return false }
        return session.analysis?.workingState.untracked.contains(where: { $0.path == request.path }) ?? false
    }

    private var supportsLineSelection: Bool {
        guard preferences.advanced else { return false }
        if case .workingTree = request.source, !isUntrackedFile {
            return true
        }
        return false
    }

    private func toggleLineSelection(_ line: DiffLine) {
        guard supportsLineSelection, line.kind != .context else { return }
        if selectedLineIDs.contains(line.id) {
            selectedLineIDs.remove(line.id)
        } else {
            selectedLineIDs.insert(line.id)
        }
    }

    private func isLineSelected(_ line: DiffLine) -> Bool {
        supportsLineSelection && line.kind != .context && selectedLineIDs.contains(line.id)
    }

    private var trimmedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespaces)
    }

    private var matchingTargetIDs: [Int] {
        guard !trimmedQuery.isEmpty, let diff = activeDiff else { return [] }
        if preferences.diffLayoutMode == .unified {
            return diff.hunks.flatMap(\.lines)
                .filter { $0.text.localizedCaseInsensitiveContains(trimmedQuery) }
                .map(\.id)
        }
        return diff.hunks
            .flatMap { DiffPresentation.pairLines(in: $0.lines) }
            .filter { pair in
                (pair.left?.text.localizedCaseInsensitiveContains(trimmedQuery) ?? false)
                || (pair.right?.text.localizedCaseInsensitiveContains(trimmedQuery) ?? false)
            }
            .map(\.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if showingFindBar {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                findBar
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            content
        }
        .background(Theme.page)
        .onChange(of: request) {
            selectedLineIDs.removeAll()
            expandedGaps.removeAll()
            currentHunkIndex = 0
        }
        .onChange(of: activeDiff) {
            expandedGaps.removeAll()
        }
        .onChange(of: session.navigation.focusLocalFindRequest) { _, newValue in
            guard newValue > 0 else { return }
            showingFindBar = true
            findFieldFocused = true
        }
        .onChange(of: workingCopy.worktreeTick) {
            if !embedded, case .workingTree(staged: false) = request.source {
                reloadActiveDiff()
            }
        }
        .task(id: activeDiff) {
            await computeHighlightsAndInlineDiffs()
        }
    }

    private func computeHighlightsAndInlineDiffs() async {
        guard let diff = activeDiff, !diff.isBinary, !diff.isEmpty else {
            spansByLineID = [:]
            fileSpansByLineNumber = []
            inlineRangesByLineID = [:]
            return
        }
        let path = diff.path
        let hunks = diff.hunks
        let fileLines = activeFileLines
        let inputs = hunks.flatMap(\.lines).map { line in
            DiffHighlightLineInput(
                id: line.id,
                text: line.text,
                includesInOld: line.kind != .addition,
                includesInNew: line.kind != .deletion
            )
        }
        let (spans, fileSpans, inline) = await Task.detached(priority: .userInitiated) {
            let computedSpans = SyntaxHighlighter.highlightDiffLines(inputs, filePath: path)
            let computedFileSpans: [[HighlightSpan]] = if let fileLines, !fileLines.isEmpty {
                SyntaxHighlighter.highlightLines(source: fileLines.joined(separator: "\n"), filePath: path)
            } else {
                []
            }
            let computedInline = DiffPresentation.computeInlineDiffRanges(in: hunks)
            return (computedSpans, computedFileSpans, computedInline)
        }.value
        guard !Task.isCancelled, activeDiff == diff else { return }
        spansByLineID = spans
        fileSpansByLineNumber = fileSpans
        inlineRangesByLineID = inline
    }

    // MARK: - Header & Find bar

    private var header: some View {
        @Bindable var inspector = inspector
        @Bindable var preferences = preferences
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                if embedded {
                    Text(request.path).font(Theme.Text.heading).foregroundStyle(Theme.ink)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                } else {
                    Button { inspector.closeDiff() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                            // Closing a diff opened from a history returns to that history.
                            Text(inspector.fileHistoryPath == nil ? "Back" : "Back to history")
                        }
                        .font(Theme.Text.body).foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                if let diff = activeDiff, !diff.isBinary {
                    Text("+\(diff.additions)").font(Theme.Text.caption.monospacedDigit()).foregroundStyle(Theme.good)
                    Text("−\(diff.deletions)").font(Theme.Text.caption.monospacedDigit()).foregroundStyle(Theme.critical)
                }
                if let hunks = activeDiff?.hunks, hunks.count > 1 {
                    HStack(spacing: 2) {
                        Button {
                            currentHunkIndex = (currentHunkIndex - 1 + hunks.count) % hunks.count
                            hunkJumpTrigger += 1
                        } label: {
                            Image(systemName: "chevron.up").font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                        .help("Previous hunk (\(currentHunkIndex + 1)/\(hunks.count))")

                        Button {
                            currentHunkIndex = (currentHunkIndex + 1) % hunks.count
                            hunkJumpTrigger += 1
                        } label: {
                            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                        .help("Next hunk (\(currentHunkIndex + 1)/\(hunks.count))")
                    }
                }
                SegmentPicker(
                    options: DiffLayoutMode.allCases.map { ($0, $0.rawValue) },
                    selection: $preferences.diffLayoutMode
                )
                Button {
                    preferences.diffIgnoreWhitespace.toggle()
                } label: {
                    Text("−w")
                        .font(Theme.Text.mono)
                        .foregroundStyle(preferences.diffIgnoreWhitespace ? Theme.accent : Theme.inkSoft)
                }
                .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .strokeBorder(preferences.diffIgnoreWhitespace ? Theme.accent.opacity(0.6) : .clear, lineWidth: 1)
                )
                .help(preferences.diffIgnoreWhitespace ? "Showing diff ignoring whitespace (-w)" : "Ignore whitespace changes (-w)")
                if preferences.advanced {
                    if staticRendering {
                        HStack(spacing: 4) {
                            Text("\(inspector.diffContext) lines")
                                .font(Theme.Text.caption.weight(.medium))
                                .foregroundStyle(Theme.ink)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(Theme.inkMuted)
                        }
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .frame(width: 92)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.hairline))
                    } else {
                        Picker("", selection: $inspector.diffContext) {
                            Text("3 lines").tag(3)
                            Text("10 lines").tag(10)
                            Text("25 lines").tag(25)
                        }
                        .labelsHidden().frame(width: 96)
                        .help("Lines of unchanged context shown around each change")
                    }
                }
                Button {
                    showingFindBar.toggle()
                    if showingFindBar {
                        findFieldFocused = true
                    } else {
                        searchQuery = ""
                        filterMatchesOnly = false
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                .help("Find in diff")
                if preferences.advanced && !embedded {
                    Button("File history") { inspector.showFileHistory(request.path) }
                        .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                }
                if isUntrackedFile && !embedded {
                    Button(preferences.advanced ? "Stage file" : "Include file") {
                        workingCopy.stage([request.path])
                        inspector.closeDiff()
                    }
                    .buttonStyle(PrimaryButtonStyle()).controlSize(.small)
                    .disabled(workingCopy.writeInFlight)
                }
                if let url = fileURL {
                    Button(embedded ? "Edit" : "Open file") { openInEditor(url, line: initialEditorLine) }
                        .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                }
                if embedded {
                    Button {
                        inspector.expandInlineDiff()
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(GhostIconButtonStyle())
                    .help("Expand diff to full window")
                }
            }
            if embedded {
                HStack(spacing: Theme.Space.s) {
                    if let diff = activeDiff {
                        if diff.isNew { Chip(text: "new file", tint: Theme.good) }
                        if diff.isDeleted { Chip(text: "deleted", tint: Theme.critical) }
                        if diff.isRename, let old = diff.oldPath {
                            Chip(text: "renamed from \(old)")
                        }
                    }
                    Text(request.title).font(Theme.Text.caption).foregroundStyle(Theme.inkMuted).lineLimit(1)
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.path).font(Theme.Text.title).foregroundStyle(Theme.ink)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    HStack(spacing: Theme.Space.s) {
                        if let diff = activeDiff {
                            if diff.isNew { Chip(text: "new file", tint: Theme.good) }
                            if diff.isDeleted { Chip(text: "deleted", tint: Theme.critical) }
                            if diff.isRename, let old = diff.oldPath {
                                Chip(text: "renamed from \(old)")
                            }
                        }
                        Text(request.title).font(Theme.Text.caption).foregroundStyle(Theme.inkMuted).lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, embedded ? Theme.Space.l : Theme.Space.xl)
        .padding(.top, embedded ? Theme.Space.m : Theme.Space.xl)
        .padding(.bottom, Theme.Space.m)
    }

    private var findBar: some View {
        let matches = matchingTargetIDs
        return HStack(spacing: Theme.Space.s) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
                TextField("Find in this diff…", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(Theme.Text.body)
                    .focused($findFieldFocused)
                    .onSubmit {
                        if !matches.isEmpty {
                            currentMatchIndex = (currentMatchIndex + 1) % matches.count
                        }
                    }
                if !searchQuery.isEmpty {
                    Button { searchQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.hairline))
            .frame(maxWidth: 280)

            if !trimmedQuery.isEmpty {
                Text("\(matches.count) match\(matches.count == 1 ? "" : "es")")
                    .font(Theme.Text.caption.monospacedDigit())
                    .foregroundStyle(matches.isEmpty ? Theme.inkMuted : Theme.inkSoft)
            }
            Button {
                guard !matches.isEmpty else { return }
                currentMatchIndex = (currentMatchIndex - 1 + matches.count) % matches.count
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
            .disabled(matches.isEmpty)

            Button {
                guard !matches.isEmpty else { return }
                currentMatchIndex = (currentMatchIndex + 1) % matches.count
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
            .disabled(matches.isEmpty)

            Toggle("Matches only", isOn: $filterMatchesOnly)
                .toggleStyle(.checkbox)
                .font(Theme.Text.caption)
                .foregroundStyle(Theme.inkSoft)

            Spacer()
            Button {
                showingFindBar = false
                searchQuery = ""
                filterMatchesOnly = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.inkMuted)
        }
        .padding(.horizontal, Theme.Space.xl).padding(.vertical, Theme.Space.s)
        .background(Theme.wash)
        .onChange(of: searchQuery) { currentMatchIndex = 0 }
    }

    private var fileURL: URL? {
        guard let root = session.analysis?.root else { return nil }
        let url = root.appendingPathComponent(request.path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private var initialEditorLine: Int? {
        guard let hunk = activeDiff?.hunks.first else { return nil }
        return hunk.lines.first(where: { $0.newNumber != nil })?.newNumber ?? max(1, hunk.newStart)
    }

    @ViewBuilder
    private func lineContextMenu(_ line: DiffLine) -> some View {
        if supportsLineSelection, line.kind != .context {
            Button(selectedLineIDs.contains(line.id) ? "Deselect Line" : "Select Line") {
                toggleLineSelection(line)
            }
            Divider()
        }
        if let url = fileURL, let lineNumber = line.newNumber ?? line.oldNumber {
            Button("Open in Editor at Line \(lineNumber)") {
                openInEditor(url, line: lineNumber)
            }
        }
        Button("Copy Line") { copyToPasteboard(line.text) }
        if let web = session.analysis?.info.remoteWebURL,
           let lineNumber = line.newNumber ?? line.oldNumber,
           let targetSHA = permalinkSHA(for: request.source),
           let permalink = GitHubBridge.linePermalinkURL(
            remoteWebURL: web,
            sha: targetSHA,
            path: request.path,
            line: lineNumber
           ) {
            Button("Copy Remote Permalink") { copyToPasteboard(permalink.absoluteString) }
        }
    }

    private func permalinkSHA(for source: DiffSource) -> String? {
        switch source {
        case .commit(let sha): return sha
        case .range(_, let to): return to
        case .workingTree: return session.analysis?.workingState.headSHA ?? session.analysis?.commits.first?.sha
        case .stash: return nil
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if activeDiffInFlight && activeDiff == nil {
            VStack(spacing: Theme.Space.s) {
                ProgressView().controlSize(.small)
                Text("Reading the diff…").font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let diff = activeDiff {
            if diff.isBinary {
                if let imageDiff = activeImageDiff, ImageDiffView.canDisplay(imageDiff) {
                    ImageDiffView(imageDiff: imageDiff)
                } else {
                    message("Binary file", "Its contents changed, but there are no text lines to show.")
                }
            } else if diff.isEmpty {
                message("No changes here", "This file is listed but its contents are identical — usually a "
                                         + "mode change, or a rename with no edits.")
            } else {
                let fileLines = activeFileLines
                let gapsByIndex: [Int: DiffGap] = {
                    guard let fileLines else { return [:] }
                    let gaps = DiffGapCalculator.gaps(for: diff, totalNewLines: fileLines.count)
                    return Dictionary(uniqueKeysWithValues: gaps.map { ($0.index, $0) })
                }()
                let shouldHideGaps = filterMatchesOnly && !trimmedQuery.isEmpty
                ScrollViewReader { proxy in
                    ScrollColumn {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if !shouldHideGaps, let fileLines, let leadingGap = gapsByIndex[0] {
                                gapSection(leadingGap, fileLines: fileLines, isLeading: true, isTrailing: false)
                            }
                            ForEach(Array(diff.hunks.enumerated()), id: \.element.id) { index, hunk in
                                if index > 0, !shouldHideGaps, let fileLines, let middleGap = gapsByIndex[index] {
                                    gapSection(middleGap, fileLines: fileLines, isLeading: false, isTrailing: false)
                                }
                                hunkContent(hunk, in: diff)
                            }
                            if !shouldHideGaps, let fileLines, let trailingGap = gapsByIndex[diff.hunks.count] {
                                gapSection(trailingGap, fileLines: fileLines, isLeading: false, isTrailing: true)
                            }
                            if diff.truncated {
                                Text("Diff truncated — this file changed by more lines than are useful to read here.")
                                    .font(Theme.Text.caption).foregroundStyle(Theme.warning)
                                    .padding(Theme.Space.m)
                            }
                        }
                        .padding(.bottom, Theme.Space.xl)
                    }
                    .onChange(of: currentMatchIndex) {
                        let targetIDs = matchingTargetIDs
                        guard currentMatchIndex >= 0, currentMatchIndex < targetIDs.count else { return }
                        withAnimation(.easeInOut(duration: 0.15)) {
                            proxy.scrollTo(targetIDs[currentMatchIndex], anchor: .center)
                        }
                    }
                    .onChange(of: hunkJumpTrigger) {
                        guard currentHunkIndex >= 0, currentHunkIndex < diff.hunks.count else { return }
                        withAnimation(.easeInOut(duration: 0.15)) {
                            proxy.scrollTo("hunk:\(diff.hunks[currentHunkIndex].id)", anchor: .top)
                        }
                    }
                }
            }
        } else {
            message("Could not read this diff", "git returned nothing for this file.")
        }
    }

    @ViewBuilder
    private func hunkContent(_ hunk: DiffHunk, in diff: FileDiff) -> some View {
        let query = trimmedQuery
        let shouldFilter = filterMatchesOnly && !query.isEmpty
        if preferences.diffLayoutMode == .unified {
            let visibleLines = shouldFilter
                ? hunk.lines.filter { $0.text.localizedCaseInsensitiveContains(query) }
                : hunk.lines
            if !visibleLines.isEmpty {
                hunkHeader(hunk, in: diff)
                    .id("hunk:\(hunk.id)")
                ForEach(visibleLines) { line in
                    unifiedRow(line).id(line.id)
                }
            }
        } else {
            let paired = DiffPresentation.pairLines(in: hunk.lines)
            let visiblePairs = shouldFilter
                ? paired.filter {
                    ($0.left?.text.localizedCaseInsensitiveContains(query) ?? false)
                    || ($0.right?.text.localizedCaseInsensitiveContains(query) ?? false)
                }
                : paired
            if !visiblePairs.isEmpty {
                hunkHeader(hunk, in: diff)
                    .id("hunk:\(hunk.id)")
                ForEach(visiblePairs) { pair in
                    sideBySideRow(pair)
                        .id(pair.id)
                }
            }
        }
    }

    private func message(_ title: String, _ detail: String) -> some View {
        VStack(spacing: Theme.Space.s) {
            Text(title).font(Theme.Text.heading).foregroundStyle(Theme.ink)
            Text(detail).font(Theme.Text.body).foregroundStyle(Theme.inkSoft)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func gapSection(_ gap: DiffGap, fileLines: [String], isLeading: Bool, isTrailing: Bool) -> some View {
        let expansion = expandedGaps[gap.index] ?? GapExpansion()
        let split = DiffGapCalculator.split(gap: gap, expansion: expansion, fileLines: fileLines)

        contextLinesBlock(split.topLines)
        if split.remainingCount > 0 {
            gapControlBar(gap: gap, remainingCount: split.remainingCount, isLeading: isLeading, isTrailing: isTrailing)
        }
        contextLinesBlock(split.bottomLines)
    }

    @ViewBuilder
    private func contextLinesBlock(_ lines: [DiffLine]) -> some View {
        if !lines.isEmpty {
            if preferences.diffLayoutMode == .unified {
                ForEach(lines) { line in
                    unifiedRow(line).id(line.id)
                }
            } else {
                ForEach(lines) { line in
                    sideBySideRow(DiffPresentation.SideBySidePair(id: line.id, left: line, right: line))
                        .id(line.id)
                }
            }
        }
    }

    private func gapControlBar(gap: DiffGap, remainingCount: Int, isLeading: Bool, isTrailing: Bool) -> some View {
        HStack(spacing: Theme.Space.s) {
            if remainingCount <= 20 {
                Button {
                    var next = expandedGaps[gap.index] ?? GapExpansion()
                    next.showAll = true
                    expandedGaps[gap.index] = next
                } label: {
                    Label("Show \(remainingCount) hidden line\(remainingCount == 1 ? "" : "s")",
                          systemImage: "arrow.up.and.down.text.horizontal")
                }
                .buttonStyle(SecondaryButtonStyle()).controlSize(.mini)
            } else {
                if !isLeading {
                    Button {
                        var next = expandedGaps[gap.index] ?? GapExpansion()
                        next.top += 20
                        expandedGaps[gap.index] = next
                    } label: {
                        Label("20 below", systemImage: "arrow.down")
                    }
                    .buttonStyle(SecondaryButtonStyle()).controlSize(.mini)
                }
                if !isTrailing {
                    Button {
                        var next = expandedGaps[gap.index] ?? GapExpansion()
                        next.bottom += 20
                        expandedGaps[gap.index] = next
                    } label: {
                        Label("20 above", systemImage: "arrow.up")
                    }
                    .buttonStyle(SecondaryButtonStyle()).controlSize(.mini)
                }
                Button("Show all (\(remainingCount))") {
                    var next = expandedGaps[gap.index] ?? GapExpansion()
                    next.showAll = true
                    expandedGaps[gap.index] = next
                }
                .buttonStyle(SecondaryButtonStyle()).controlSize(.mini)
            }
            Text("\(remainingCount) hidden unchanged line\(remainingCount == 1 ? "" : "s")")
                .font(.system(size: 10))
                .foregroundStyle(Theme.inkMuted)
            Spacer()
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, 4)
        .background(Theme.wash.opacity(0.65))
        .overlay(alignment: .top) { HairlineDivider() }
        .overlay(alignment: .bottom) { HairlineDivider() }
    }

    private func hunkHeader(_ hunk: DiffHunk, in diff: FileDiff) -> some View {
        let selectedInHunk = Set(hunk.lines.filter { $0.kind != .context && selectedLineIDs.contains($0.id) }.map(\.id))
        let noun = "\(selectedInHunk.count) line\(selectedInHunk.count == 1 ? "" : "s")"
        let newCount = hunk.lines.count(where: { $0.kind != .deletion })
        let lineEnd = hunk.newStart + max(newCount - 1, 0)
        return HStack(spacing: Theme.Space.s) {
            if preferences.advanced {
                Text("@@ −\(hunk.oldStart) +\(hunk.newStart) @@")
                    .font(Theme.Text.mono).foregroundStyle(Theme.accent)
            } else {
                Text(newCount > 1 ? "Lines \(hunk.newStart)–\(lineEnd)" : "Line \(max(hunk.newStart, hunk.oldStart))")
                    .font(Theme.Text.caption.weight(.medium)).foregroundStyle(Theme.accent)
            }
            if !hunk.section.isEmpty {
                Text(hunk.section).font(Theme.Text.mono).foregroundStyle(Theme.inkMuted)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer()
            if preferences.advanced, case .workingTree(let staged) = request.source, !isUntrackedFile {
                if !selectedInHunk.isEmpty {
                    if staged {
                        Button("Unstage \(noun)") {
                            workingCopy.applySelectedLines(selectedInHunk, in: hunk, diff: diff, staged: true, discard: false) {
                                selectedLineIDs.subtract(selectedInHunk)
                                reloadActiveDiff()
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle()).controlSize(.small)
                        .disabled(workingCopy.writeInFlight)
                    } else {
                        Button("Stage \(noun)") {
                            workingCopy.applySelectedLines(selectedInHunk, in: hunk, diff: diff, staged: false, discard: false) {
                                selectedLineIDs.subtract(selectedInHunk)
                                reloadActiveDiff()
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle()).controlSize(.small)
                        .disabled(workingCopy.writeInFlight)
                        Button("Discard \(noun)") {
                            workingCopy.applySelectedLines(selectedInHunk, in: hunk, diff: diff, staged: false, discard: true) {
                                selectedLineIDs.subtract(selectedInHunk)
                                reloadActiveDiff()
                            }
                        }
                        .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                        .disabled(workingCopy.writeInFlight)
                    }
                    Button("Clear") {
                        selectedLineIDs.subtract(selectedInHunk)
                    }
                    .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                }

                if staged {
                    Button("Unstage hunk") {
                        workingCopy.applyHunk(hunk, diff: diff, staged: true, discard: false) {
                            selectedLineIDs.subtract(selectedInHunk)
                            reloadActiveDiff()
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                    .disabled(workingCopy.writeInFlight)
                } else {
                    Button("Stage hunk") {
                        workingCopy.applyHunk(hunk, diff: diff, staged: false, discard: false) {
                            selectedLineIDs.subtract(selectedInHunk)
                            reloadActiveDiff()
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                    .disabled(workingCopy.writeInFlight)
                    Button("Discard hunk") {
                        workingCopy.applyHunk(hunk, diff: diff, staged: false, discard: true) {
                            selectedLineIDs.subtract(selectedInHunk)
                            reloadActiveDiff()
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                    .disabled(workingCopy.writeInFlight)
                }
            }
        }
        .padding(.horizontal, Theme.Space.xl).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accentWash.opacity(0.5))
    }

    // MARK: - Line rendering

    private func renderedLineText(_ line: DiffLine) -> AttributedString {
        let spans: [HighlightSpan]
        if line.id < 0, let newNum = line.newNumber, newNum >= 1, newNum <= fileSpansByLineNumber.count {
            spans = fileSpansByLineNumber[newNum - 1]
        } else {
            spans = spansByLineID[line.id] ?? []
        }
        return Theme.Syntax.attributedLine(
            line.text,
            spans: spans,
            baseForeground: line.kind == .context ? Theme.inkSoft : Theme.ink,
            emphasisUTF16Ranges: inlineRangesByLineID[line.id] ?? [],
            emphasisBackground: emphasisBackground(for: line.kind),
            searchQuery: trimmedQuery
        )
    }

    @ViewBuilder
    private func lineSelectionCheckbox(for line: DiffLine) -> some View {
        if supportsLineSelection {
            Group {
                if line.kind != .context {
                    Image(systemName: isLineSelected(line) ? "checkmark.square.fill" : "square")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(isLineSelected(line) ? Theme.accent : Theme.inkMuted.opacity(0.6))
                } else {
                    Color.clear
                }
            }
            .frame(width: 16, alignment: .center)
        }
    }

    @ViewBuilder
    private func lineBackground(_ line: DiffLine) -> some View {
        ZStack(alignment: .leading) {
            background(line)
            if isLineSelected(line) {
                Theme.accent.opacity(0.14)
                Rectangle().fill(Theme.accent).frame(width: 3)
            }
        }
    }

    private func unifiedRow(_ line: DiffLine) -> some View {
        let numberWidth = max(46, CGFloat(preferences.codeFontSize) * 4.2)
        return HStack(alignment: .top, spacing: 0) {
            HStack(spacing: 0) {
                lineSelectionCheckbox(for: line)
                Text(line.oldNumber.map(String.init) ?? "")
                    .frame(width: numberWidth, alignment: .trailing)
                    .foregroundStyle(Theme.inkMuted)
                Text(line.newNumber.map(String.init) ?? "")
                    .frame(width: numberWidth, alignment: .trailing)
                    .foregroundStyle(Theme.inkMuted)
                Text(marker(line)).frame(width: 16, alignment: .center)
                    .foregroundStyle(markerColor(line))
            }
            .contentShape(Rectangle())
            .onTapGesture { toggleLineSelection(line) }
            Text(renderedLineText(line))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if line.missingTrailingNewline {
                Text(" ↵ no newline at end of file")
                    .foregroundStyle(Theme.warning)
            }
            Spacer(minLength: 0)
        }
        .font(Theme.Text.monoFont(size: preferences.codeFontSize))
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(lineBackground(line))
        .contextMenu { lineContextMenu(line) }
    }

    private func sideBySideRow(_ pair: DiffPresentation.SideBySidePair) -> some View {
        HStack(spacing: 0) {
            sideBySideCell(line: pair.left, sideNumber: pair.left?.oldNumber)
                .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            sideBySideCell(line: pair.right, sideNumber: pair.right?.newNumber)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(Theme.Text.monoFont(size: preferences.codeFontSize))
    }

    @ViewBuilder
    private func sideBySideCell(line: DiffLine?, sideNumber: Int?) -> some View {
        let numberWidth = max(40, CGFloat(preferences.codeFontSize) * 3.8)
        if let line {
            HStack(alignment: .top, spacing: 0) {
                HStack(spacing: 0) {
                    lineSelectionCheckbox(for: line)
                    Text(sideNumber.map(String.init) ?? "")
                        .frame(width: numberWidth, alignment: .trailing)
                        .foregroundStyle(Theme.inkMuted)
                    Text(marker(line))
                        .frame(width: 14, alignment: .center)
                        .foregroundStyle(markerColor(line))
                }
                .contentShape(Rectangle())
                .onTapGesture { toggleLineSelection(line) }
                Text(renderedLineText(line))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if line.missingTrailingNewline {
                    Text(" ↵")
                        .foregroundStyle(Theme.warning)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, 1)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .background(lineBackground(line))
            .contextMenu { lineContextMenu(line) }
        } else {
            Text(" ")
                .padding(.vertical, 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.wash.opacity(0.5))
        }
    }

    private func marker(_ line: DiffLine) -> String {
        switch line.kind {
        case .addition: return "+"
        case .deletion: return "−"
        case .context: return " "
        }
    }

    private func markerColor(_ line: DiffLine) -> Color {
        switch line.kind {
        case .addition: return Theme.good
        case .deletion: return Theme.critical
        case .context: return Theme.inkMuted
        }
    }

    private func background(_ line: DiffLine) -> Color {
        switch line.kind {
        case .addition: return Theme.good.opacity(0.12)
        case .deletion: return Theme.critical.opacity(0.12)
        case .context: return .clear
        }
    }

    private func emphasisBackground(for kind: DiffLine.Kind) -> Color? {
        switch kind {
        case .addition: return Theme.good.opacity(0.28)
        case .deletion: return Theme.critical.opacity(0.28)
        case .context: return nil
        }
    }
}

/// Pure helpers for pairing unified diff hunks into inline word-diff spans and side-by-side rows.
enum DiffPresentation {
    struct SideBySidePair: Identifiable {
        let id: Int
        let left: DiffLine?
        let right: DiffLine?
    }

    static func pairLines(in lines: [DiffLine]) -> [SideBySidePair] {
        var pairs: [SideBySidePair] = []
        pairs.reserveCapacity(lines.count)
        var i = 0
        var counter = 0

        while i < lines.count {
            let current = lines[i]
            if current.kind == .context {
                counter += 1
                pairs.append(SideBySidePair(id: counter, left: current, right: current))
                i += 1
                continue
            }

            var deletions: [DiffLine] = []
            var additions: [DiffLine] = []
            while i < lines.count && lines[i].kind != .context {
                if lines[i].kind == .deletion {
                    deletions.append(lines[i])
                } else if lines[i].kind == .addition {
                    additions.append(lines[i])
                }
                i += 1
            }

            let rows = max(deletions.count, additions.count)
            for k in 0..<rows {
                counter += 1
                let left = k < deletions.count ? deletions[k] : nil
                let right = k < additions.count ? additions[k] : nil
                pairs.append(SideBySidePair(id: counter, left: left, right: right))
            }
        }
        return pairs
    }

    static func computeInlineDiffRanges(in hunks: [DiffHunk]) -> [Int: [Range<Int>]] {
        var result: [Int: [Range<Int>]] = [:]
        for hunk in hunks {
            let lines = hunk.lines
            var i = 0
            while i < lines.count {
                guard lines[i].kind == .deletion else {
                    i += 1
                    continue
                }
                let delStart = i
                while i < lines.count && lines[i].kind == .deletion { i += 1 }
                let delEnd = i
                let addStart = i
                while i < lines.count && lines[i].kind == .addition { i += 1 }
                let addEnd = i

                let pairCount = min(delEnd - delStart, addEnd - addStart)
                guard pairCount > 0, pairCount <= 25 else { continue }
                for k in 0..<pairCount {
                    let oldLine = lines[delStart + k]
                    let newLine = lines[addStart + k]
                    let (oldRanges, newRanges) = InlineWordDiff.changedUTF16Ranges(
                        old: oldLine.text,
                        new: newLine.text
                    )
                    if !oldRanges.isEmpty { result[oldLine.id] = oldRanges }
                    if !newRanges.isEmpty { result[newLine.id] = newRanges }
                }
            }
        }
        return result
    }
}

private struct ImageDiffView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case sideBySide = "Side by side"
        case swipe = "Swipe"
        case onionSkin = "Onion skin"
        var id: String { rawValue }
    }

    let imageDiff: ImageDiffData
    @State private var mode: Mode = .sideBySide
    @State private var splitRatio: Double = 0.5
    @State private var onionOpacity: Double = 0.5

    static func canDisplay(_ data: ImageDiffData) -> Bool {
        let oldOK = data.oldData.flatMap(NSImage.init(data:)) != nil
        let newOK = data.newData.flatMap(NSImage.init(data:)) != nil
        return oldOK || newOK
    }

    private var oldImage: NSImage? { imageDiff.oldData.flatMap(NSImage.init(data:)) }
    private var newImage: NSImage? { imageDiff.newData.flatMap(NSImage.init(data:)) }

    var body: some View {
        ScrollColumn {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                HStack(spacing: Theme.Space.m) {
                    if oldImage != nil && newImage != nil {
                        SegmentPicker(
                            options: Mode.allCases.map { ($0, $0.rawValue) },
                            selection: $mode
                        )
                    }
                    Spacer()
                    if let oldBytes = imageDiff.oldData?.count, let newBytes = imageDiff.newData?.count {
                        let delta = newBytes - oldBytes
                        let prefix = delta >= 0 ? "+" : "−"
                        Text("\(Int64(oldBytes).byteString) → \(Int64(newBytes).byteString) (\(prefix)\(Int64(abs(delta)).byteString))")
                            .font(Theme.Text.caption.monospacedDigit())
                            .foregroundStyle(Theme.inkSoft)
                    } else if let onlyBytes = imageDiff.newData?.count ?? imageDiff.oldData?.count {
                        Text(Int64(onlyBytes).byteString)
                            .font(Theme.Text.caption.monospacedDigit())
                            .foregroundStyle(Theme.inkSoft)
                    }
                }

                if let oldImage, let newImage {
                    switch mode {
                    case .sideBySide:
                        HStack(alignment: .top, spacing: Theme.Space.l) {
                            imageCard(title: "Before", image: oldImage, data: imageDiff.oldData, tint: Theme.critical)
                            imageCard(title: "After", image: newImage, data: imageDiff.newData, tint: Theme.good)
                        }
                    case .swipe:
                        VStack(spacing: Theme.Space.m) {
                            GeometryReader { geo in
                                let revealWidth = geo.size.width * CGFloat(splitRatio)
                                ZStack(alignment: .leading) {
                                    CheckerboardBackdrop()
                                    Image(nsImage: oldImage)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: geo.size.width, height: geo.size.height)
                                    Image(nsImage: newImage)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: geo.size.width, height: geo.size.height)
                                        .mask(
                                            HStack(spacing: 0) {
                                                Rectangle().frame(width: max(0, revealWidth))
                                                Spacer(minLength: 0)
                                            }
                                        )
                                    Rectangle()
                                        .fill(Theme.accent)
                                        .frame(width: 2, height: geo.size.height)
                                        .offset(x: max(0, min(geo.size.width - 2, revealWidth - 1)))
                                }
                            }
                            .frame(height: 360)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.hairline))

                            HStack(spacing: Theme.Space.s) {
                                Text("After").font(Theme.Text.caption).foregroundStyle(Theme.good)
                                Slider(value: $splitRatio, in: 0...1)
                                Text("Before").font(Theme.Text.caption).foregroundStyle(Theme.critical)
                            }
                        }
                        .padding(Theme.Space.l)
                        .cardSurface()
                    case .onionSkin:
                        VStack(spacing: Theme.Space.m) {
                            ZStack {
                                CheckerboardBackdrop()
                                Image(nsImage: oldImage)
                                    .resizable()
                                    .scaledToFit()
                                Image(nsImage: newImage)
                                    .resizable()
                                    .scaledToFit()
                                    .opacity(onionOpacity)
                            }
                            .frame(height: 360)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.hairline))

                            HStack(spacing: Theme.Space.s) {
                                Text("Before").font(Theme.Text.caption).foregroundStyle(Theme.critical)
                                Slider(value: $onionOpacity, in: 0...1)
                                Text("After (\(Int((onionOpacity * 100).rounded()))%)")
                                    .font(Theme.Text.caption.monospacedDigit())
                                    .foregroundStyle(Theme.good)
                            }
                        }
                        .padding(Theme.Space.l)
                        .cardSurface()
                    }
                } else if let newImage {
                    imageCard(title: "Added image", image: newImage, data: imageDiff.newData, tint: Theme.good)
                } else if let oldImage {
                    imageCard(title: "Removed image", image: oldImage, data: imageDiff.oldData, tint: Theme.critical)
                }
            }
            .padding(Theme.Space.xl)
        }
    }

    private func imageCard(title: String, image: NSImage, data: Data?, tint: Color) -> some View {
        let dims = pixelDimensions(data: data, fallback: image)
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Text(title).font(Theme.Text.bodyBold).foregroundStyle(tint)
                Spacer()
                Text("\(dims.width) × \(dims.height) px")
                    .font(Theme.Text.caption.monospacedDigit())
                    .foregroundStyle(Theme.inkMuted)
                if let bytes = data?.count {
                    Text("· \(Int64(bytes).byteString)")
                        .font(Theme.Text.caption.monospacedDigit())
                        .foregroundStyle(Theme.inkMuted)
                }
            }
            ZStack {
                CheckerboardBackdrop()
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(Theme.Space.m)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 320)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.hairline))
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity)
        .cardSurface()
    }

    private func pixelDimensions(data: Data?, fallback: NSImage) -> (width: Int, height: Int) {
        if let data, let rep = NSBitmapImageRep(data: data), rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return (rep.pixelsWide, rep.pixelsHigh)
        }
        return (max(Int(fallback.size.width), 0), max(Int(fallback.size.height), 0))
    }
}

struct DiffGap: Equatable, Identifiable {
    var id: Int { index }
    let index: Int
    /// 1-based inclusive line numbers in the new file represented by this gap.
    let newLineRange: ClosedRange<Int>
    /// `oldLine = newLine + oldOffset`, nil when viewing a newly created file.
    let oldOffset: Int?

    var count: Int { newLineRange.count }
}

struct GapExpansion: Equatable {
    var top: Int = 0
    var bottom: Int = 0
    var showAll: Bool = false
}

enum DiffGapCalculator {
    static func gaps(for diff: FileDiff, totalNewLines: Int) -> [DiffGap] {
        guard !diff.hunks.isEmpty, totalNewLines > 0, !diff.isDeleted else { return [] }
        let sorted = diff.hunks.sorted { $0.newStart < $1.newStart }
        var result: [DiffGap] = []

        let first = sorted[0]
        if first.newStart > 1 {
            let upper = min(first.newStart - 1, totalNewLines)
            if upper >= 1 {
                result.append(DiffGap(
                    index: 0,
                    newLineRange: 1...upper,
                    oldOffset: diff.isNew ? nil : (first.oldStart - first.newStart)
                ))
            }
        }

        for idx in 1..<sorted.count {
            let prev = sorted[idx - 1]
            let next = sorted[idx]
            let prevNewCount = prev.lines.count(where: { $0.kind != .deletion })
            let gapStart = prev.newStart + prevNewCount
            let gapEnd = min(next.newStart - 1, totalNewLines)
            if gapStart <= gapEnd {
                result.append(DiffGap(
                    index: idx,
                    newLineRange: gapStart...gapEnd,
                    oldOffset: diff.isNew ? nil : (next.oldStart - next.newStart)
                ))
            }
        }

        if let last = sorted.last {
            let lastOldCount = last.lines.count(where: { $0.kind != .addition })
            let lastNewCount = last.lines.count(where: { $0.kind != .deletion })
            let trailingStart = max(1, last.newStart + lastNewCount)
            if trailingStart <= totalNewLines {
                let offset: Int? = diff.isNew ? nil : ((last.oldStart + lastOldCount) - (last.newStart + lastNewCount))
                result.append(DiffGap(
                    index: sorted.count,
                    newLineRange: trailingStart...totalNewLines,
                    oldOffset: offset
                ))
            }
        }

        return result
    }

    static func split(
        gap: DiffGap,
        expansion: GapExpansion,
        fileLines: [String]
    ) -> (topLines: [DiffLine], remainingCount: Int, remainingRange: ClosedRange<Int>?, bottomLines: [DiffLine]) {
        guard gap.newLineRange.lowerBound >= 1,
              gap.newLineRange.upperBound <= fileLines.count else {
            return ([], 0, nil, [])
        }

        if expansion.showAll || expansion.top + expansion.bottom >= gap.count {
            let allLines = gap.newLineRange.map {
                makeContextLine(gapIndex: gap.index, newLine: $0, oldOffset: gap.oldOffset, fileLines: fileLines)
            }
            return (allLines, 0, nil, [])
        }

        let topCount = max(0, min(expansion.top, gap.count))
        let bottomCount = max(0, min(expansion.bottom, gap.count - topCount))
        let remaining = gap.count - topCount - bottomCount

        var topLines: [DiffLine] = []
        if topCount > 0 {
            let upper = gap.newLineRange.lowerBound + topCount - 1
            topLines = (gap.newLineRange.lowerBound...upper).map {
                makeContextLine(gapIndex: gap.index, newLine: $0, oldOffset: gap.oldOffset, fileLines: fileLines)
            }
        }

        var bottomLines: [DiffLine] = []
        if bottomCount > 0 {
            let lower = gap.newLineRange.upperBound - bottomCount + 1
            bottomLines = (lower...gap.newLineRange.upperBound).map {
                makeContextLine(gapIndex: gap.index, newLine: $0, oldOffset: gap.oldOffset, fileLines: fileLines)
            }
        }

        let remStart = gap.newLineRange.lowerBound + topCount
        let remEnd = gap.newLineRange.upperBound - bottomCount
        let remRange = remaining > 0 ? remStart...remEnd : nil
        return (topLines, remaining, remRange, bottomLines)
    }

    private static func makeContextLine(
        gapIndex: Int,
        newLine: Int,
        oldOffset: Int?,
        fileLines: [String]
    ) -> DiffLine {
        DiffLine(
            id: -(gapIndex * 1_000_000 + newLine),
            kind: .context,
            oldNumber: oldOffset.map { $0 + newLine },
            newNumber: newLine,
            text: fileLines[newLine - 1],
            missingTrailingNewline: false
        )
    }
}

struct CheckerboardBackdrop: View {
    var body: some View {
        Canvas { context, size in
            let tile: CGFloat = 12
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.page))
            var y: CGFloat = 0
            var row = 0
            while y < size.height {
                var x: CGFloat = 0
                var col = 0
                while x < size.width {
                    if (row + col).isMultiple(of: 2) {
                        context.fill(
                            Path(CGRect(x: x, y: y, width: tile, height: tile)),
                            with: .color(Theme.wash)
                        )
                    }
                    x += tile
                    col += 1
                }
                y += tile
                row += 1
            }
        }
    }
}
