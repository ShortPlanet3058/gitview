import SwiftUI
import GitViewCore
import GitViewGit
import GitViewParse

/// A diff viewer supporting syntax highlighting, word-level inline emphasis, unified & side-by-side layouts, and find-in-diff.
struct DiffViewer: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(InspectorStore.self) private var inspector
    @Environment(WorkingCopyStore.self) private var workingCopy
    let request: DiffRequest

    enum LayoutMode: String, CaseIterable {
        case unified = "Unified"
        case sideBySide = "Side by side"
    }

    @State private var layoutMode: LayoutMode = .unified
    @State private var showingFindBar = false
    @State private var searchQuery = ""
    @State private var filterMatchesOnly = false
    @State private var currentMatchIndex = 0
    @State private var spansByLineID: [Int: [HighlightSpan]] = [:]
    @State private var inlineRangesByLineID: [Int: [Range<Int>]] = [:]
    @FocusState private var findFieldFocused: Bool

    private var isUntrackedFile: Bool {
        guard case .workingTree(staged: false) = request.source else { return false }
        return session.analysis?.workingState.untracked.contains(where: { $0.path == request.path }) ?? false
    }

    private var trimmedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespaces)
    }

    private var matchingTargetIDs: [Int] {
        guard !trimmedQuery.isEmpty, let diff = inspector.loadedDiff else { return [] }
        if layoutMode == .unified {
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
        .task(id: inspector.loadedDiff) {
            await computeHighlightsAndInlineDiffs()
        }
    }

    private func computeHighlightsAndInlineDiffs() async {
        guard let diff = inspector.loadedDiff, !diff.isBinary, !diff.isEmpty else {
            spansByLineID = [:]
            inlineRangesByLineID = [:]
            return
        }
        let path = diff.path
        let hunks = diff.hunks
        let inputs = hunks.flatMap(\.lines).map { line in
            DiffHighlightLineInput(
                id: line.id,
                text: line.text,
                includesInOld: line.kind != .addition,
                includesInNew: line.kind != .deletion
            )
        }
        let (spans, inline) = await Task.detached(priority: .userInitiated) {
            let computedSpans = SyntaxHighlighter.highlightDiffLines(inputs, filePath: path)
            let computedInline = DiffPresentation.computeInlineDiffRanges(in: hunks)
            return (computedSpans, computedInline)
        }.value
        guard !Task.isCancelled, inspector.loadedDiff == diff else { return }
        spansByLineID = spans
        inlineRangesByLineID = inline
    }

    // MARK: - Header & Find bar

    private var header: some View {
        @Bindable var inspector = inspector
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Button { inspector.closeDiff() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                        // Closing a diff opened from a history returns to that history.
                        Text(inspector.fileHistoryPath == nil ? "Back" : "Back to history")
                    }
                    .font(Theme.Text.body).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                Spacer()
                if let diff = inspector.loadedDiff, !diff.isBinary {
                    Text("+\(diff.additions)").font(Theme.Text.caption.monospacedDigit()).foregroundStyle(Theme.good)
                    Text("−\(diff.deletions)").font(Theme.Text.caption.monospacedDigit()).foregroundStyle(Theme.critical)
                }
                SegmentPicker(
                    options: LayoutMode.allCases.map { ($0, $0.rawValue) },
                    selection: $layoutMode
                )
                Picker("", selection: $inspector.diffContext) {
                    Text("3 lines").tag(3)
                    Text("10 lines").tag(10)
                    Text("25 lines").tag(25)
                }
                .labelsHidden().frame(width: 96)
                .help("Lines of unchanged context shown around each change")
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
                Button("File history") { inspector.showFileHistory(request.path) }
                    .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                if isUntrackedFile {
                    Button("Stage file") {
                        workingCopy.stage([request.path])
                        inspector.closeDiff()
                    }
                    .buttonStyle(PrimaryButtonStyle()).controlSize(.small)
                    .disabled(workingCopy.writeInFlight)
                }
                if let url = fileURL {
                    Button("Open file") { openInEditor(url, line: initialEditorLine) }
                        .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(request.path).font(Theme.Text.title).foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                HStack(spacing: Theme.Space.s) {
                    if let diff = inspector.loadedDiff {
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
        .padding(.horizontal, Theme.Space.xl).padding(.top, Theme.Space.xl).padding(.bottom, Theme.Space.m)
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
        guard let hunk = inspector.loadedDiff?.hunks.first else { return nil }
        return hunk.lines.first(where: { $0.newNumber != nil })?.newNumber ?? max(1, hunk.newStart)
    }

    @ViewBuilder
    private func lineContextMenu(_ line: DiffLine) -> some View {
        if let url = fileURL, let lineNumber = line.newNumber ?? line.oldNumber {
            Button("Open in Editor at Line \(lineNumber)") {
                openInEditor(url, line: lineNumber)
            }
        }
        Button("Copy Line") { copyToPasteboard(line.text) }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if inspector.diffInFlight && inspector.loadedDiff == nil {
            VStack(spacing: Theme.Space.s) {
                ProgressView().controlSize(.small)
                Text("Reading the diff…").font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let diff = inspector.loadedDiff {
            if diff.isBinary {
                message("Binary file", "Its contents changed, but there are no text lines to show.")
            } else if diff.isEmpty {
                message("No changes here", "This file is listed but its contents are identical — usually a "
                                         + "mode change, or a rename with no edits.")
            } else {
                ScrollViewReader { proxy in
                    ScrollColumn {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(diff.hunks) { hunk in
                                hunkContent(hunk, in: diff)
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
        if layoutMode == .unified {
            let visibleLines = shouldFilter
                ? hunk.lines.filter { $0.text.localizedCaseInsensitiveContains(query) }
                : hunk.lines
            if !visibleLines.isEmpty {
                hunkHeader(hunk, in: diff)
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

    private func hunkHeader(_ hunk: DiffHunk, in diff: FileDiff) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text("@@ −\(hunk.oldStart) +\(hunk.newStart) @@")
                .font(Theme.Text.mono).foregroundStyle(Theme.accent)
            if !hunk.section.isEmpty {
                Text(hunk.section).font(Theme.Text.mono).foregroundStyle(Theme.inkMuted)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer()
            if case .workingTree(let staged) = request.source, !isUntrackedFile {
                if staged {
                    Button("Unstage hunk") {
                        workingCopy.applyHunk(hunk, diff: diff, staged: true, discard: false) {
                            inspector.reloadDiff()
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                    .disabled(workingCopy.writeInFlight)
                } else {
                    Button("Stage hunk") {
                        workingCopy.applyHunk(hunk, diff: diff, staged: false, discard: false) {
                            inspector.reloadDiff()
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                    .disabled(workingCopy.writeInFlight)
                    Button("Discard hunk") {
                        workingCopy.applyHunk(hunk, diff: diff, staged: false, discard: true) {
                            inspector.reloadDiff()
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
        Theme.Syntax.attributedLine(
            line.text,
            spans: spansByLineID[line.id] ?? [],
            baseForeground: line.kind == .context ? Theme.inkSoft : Theme.ink,
            emphasisUTF16Ranges: inlineRangesByLineID[line.id] ?? [],
            emphasisBackground: emphasisBackground(for: line.kind),
            searchQuery: trimmedQuery
        )
    }

    private func unifiedRow(_ line: DiffLine) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(line.oldNumber.map(String.init) ?? "")
                .frame(width: 46, alignment: .trailing)
                .foregroundStyle(Theme.inkMuted)
            Text(line.newNumber.map(String.init) ?? "")
                .frame(width: 46, alignment: .trailing)
                .foregroundStyle(Theme.inkMuted)
            Text(marker(line)).frame(width: 16, alignment: .center)
                .foregroundStyle(markerColor(line))
            Text(renderedLineText(line))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if line.missingTrailingNewline {
                Text(" ↵ no newline at end of file")
                    .foregroundStyle(Theme.warning)
            }
            Spacer(minLength: 0)
        }
        .font(Theme.Text.mono)
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background(line))
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
        .font(Theme.Text.mono)
    }

    @ViewBuilder
    private func sideBySideCell(line: DiffLine?, sideNumber: Int?) -> some View {
        if let line {
            HStack(alignment: .top, spacing: 0) {
                Text(sideNumber.map(String.init) ?? "")
                    .frame(width: 40, alignment: .trailing)
                    .foregroundStyle(Theme.inkMuted)
                Text(marker(line))
                    .frame(width: 14, alignment: .center)
                    .foregroundStyle(markerColor(line))
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
            .background(background(line))
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
