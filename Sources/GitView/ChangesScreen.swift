import SwiftUI
import AppKit
import GitViewCore
import GitViewGit

/// Unified selectable item across the left Changes list and live right-pane diff preview.
struct WorkingCopyChangeEntry: Identifiable, Hashable {
    let id: String
    let file: WorkingState.FileStatus
    let staged: Bool
    let title: String

    var diffRequest: DiffRequest {
        DiffRequest(source: .workingTree(staged: staged), path: file.path, title: title)
    }

    static func ordered(in state: WorkingState, advanced: Bool) -> [WorkingCopyChangeEntry] {
        var entries: [WorkingCopyChangeEntry] = []
        entries.append(contentsOf: state.conflicted.map {
            WorkingCopyChangeEntry(id: "conflicted:\($0.path)", file: $0, staged: false, title: "Conflicted file")
        })
        if advanced {
            entries.append(contentsOf: state.staged.map {
                WorkingCopyChangeEntry(id: "staged:\($0.path)", file: $0, staged: true, title: "Staged changes")
            })
            entries.append(contentsOf: state.unstaged.map {
                WorkingCopyChangeEntry(id: "unstaged:\($0.path)", file: $0, staged: false, title: "Uncommitted changes")
            })
        } else {
            let tracked = state.files.filter { !$0.isUntracked && !$0.isConflicted }
            entries.append(contentsOf: tracked.map { file in
                let stagedOnly = file.staged != .unchanged && file.unstaged == .unchanged
                return WorkingCopyChangeEntry(id: "tracked:\(file.path)", file: file, staged: stagedOnly, title: "Modified file")
            })
        }
        entries.append(contentsOf: state.untracked.map {
            WorkingCopyChangeEntry(
                id: "untracked:\($0.path)",
                file: $0,
                staged: false,
                title: advanced ? "Untracked file" : "New file"
            )
        })
        return entries
    }
}

/// Split Changes workspace: left list + commit dock paired with a live embedded diff pane on the right.
struct ChangesScreen: View {
    private struct StashFileSelection: Hashable {
        let ref: String
        let message: String
        let path: String
    }

    @Environment(WorkspaceSession.self) private var session
    @Environment(AppPreferences.self) private var preferences
    @Environment(WorkingCopyStore.self) private var workingCopy
    @Environment(\.staticRendering) private var staticRendering
    @AppStorage("gitview.changesPaneWidth") private var changesPaneWidth: Double = 364
    @AppStorage("gitview.changesTreeView") private var showTreeView = false
    @State private var selectedEntryID: String?
    @State private var stashesExpanded = false
    @State private var expandedStashRef: String?
    @State private var selectedStashFile: StashFileSelection?
    @State private var fileFilter = ""
    @State private var filterFieldFocused = false
    @FocusState private var commitInputFocused: Bool

    private var state: WorkingState { session.analysis?.workingState ?? .clean }

    private var trimmedFilter: String {
        fileFilter.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func matching(_ files: [WorkingState.FileStatus]) -> [WorkingState.FileStatus] {
        guard !trimmedFilter.isEmpty else { return files }
        return files.filter { $0.path.localizedCaseInsensitiveContains(trimmedFilter) }
    }

    private var standardTrackedFiles: [WorkingState.FileStatus] {
        matching(state.files.filter { !$0.isUntracked && !$0.isConflicted })
    }

    private var orderedEntries: [WorkingCopyChangeEntry] {
        let all = WorkingCopyChangeEntry.ordered(in: state, advanced: preferences.advanced)
        guard !trimmedFilter.isEmpty else { return all }
        return all.filter { $0.file.path.localizedCaseInsensitiveContains(trimmedFilter) }
    }

    var body: some View {
        let entries = orderedEntries
        let activeEntry = selectedStashFile == nil
            ? (entries.first(where: { $0.id == selectedEntryID }) ?? entries.first)
            : nil
        let clampedLeft = min(max(changesPaneWidth, 280), 520)

        HStack(spacing: 0) {
            leftPane(entries: entries, activeID: activeEntry?.id)
                .frame(width: clampedLeft)
                .background(Theme.sidebar.opacity(0.45))

            VerticalPaneResizer(width: $changesPaneWidth, range: 280...520, invertDrag: false)

            rightPane(activeEntry: activeEntry, stashSelection: selectedStashFile)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.page)
        }
        .onAppear {
            syncSelectionAndInlineDiff(entries: entries)
        }
        .onChange(of: state) {
            if let stashSelection = selectedStashFile,
               !state.stashes.contains(where: { $0.ref == stashSelection.ref }) {
                selectedStashFile = nil
            }
            syncSelectionAndInlineDiff(entries: entries, reloadCurrent: true)
        }
        .onChange(of: state.stashes) {
            session.inspector.invalidateStashes()
            if let expandedStashRef, state.stashes.contains(where: { $0.ref == expandedStashRef }) {
                session.inspector.ensureStashFiles(ref: expandedStashRef, force: true)
            } else {
                expandedStashRef = nil
            }
        }
        .onChange(of: workingCopy.worktreeTick) {
            if selectedStashFile == nil,
               let activeEntry,
               case .workingTree(staged: false) = activeEntry.diffRequest.source {
                session.inspector.reloadInlineDiff()
            }
        }
        .onChange(of: preferences.advanced) {
            if !preferences.advanced {
                selectedStashFile = nil
            }
            syncSelectionAndInlineDiff(entries: entries)
        }
        .onChange(of: fileFilter) {
            selectedStashFile = nil
            syncSelectionAndInlineDiff(entries: entries)
        }
        .onChange(of: selectedEntryID) {
            selectedStashFile = nil
            syncSelectionAndInlineDiff(entries: entries)
        }
        .onChange(of: selectedStashFile) {
            syncSelectionAndInlineDiff(entries: entries)
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.downArrow) {
            guard !commitInputFocused, !filterFieldFocused else { return .ignored }
            selectedStashFile = nil
            selectedEntryID = NavigationStore.stepSelection(
                in: entries.map(\.id), current: activeEntry?.id, delta: 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            guard !commitInputFocused, !filterFieldFocused else { return .ignored }
            selectedStashFile = nil
            selectedEntryID = NavigationStore.stepSelection(
                in: entries.map(\.id), current: activeEntry?.id, delta: -1)
            return .handled
        }
        .onKeyPress(.space) {
            guard !commitInputFocused, !filterFieldFocused,
                  let activeEntry,
                  !activeEntry.file.isConflicted,
                  !workingCopy.writeInFlight else { return .ignored }
            if activeEntry.staged {
                workingCopy.unstage([activeEntry.file.path])
            } else {
                workingCopy.stage([activeEntry.file.path])
            }
            return .handled
        }
        .onKeyPress(.return) {
            guard !commitInputFocused, !filterFieldFocused,
                  let chosen = activeEntry else { return .ignored }
            selectedStashFile = nil
            selectedEntryID = chosen.id
            session.inspector.showDiff(.workingTree(staged: chosen.staged), path: chosen.file.path, title: chosen.title)
            return .handled
        }
    }

    private func syncSelectionAndInlineDiff(entries: [WorkingCopyChangeEntry], reloadCurrent: Bool = false) {
        if let stashSelection = selectedStashFile,
           state.stashes.contains(where: { $0.ref == stashSelection.ref }) {
            let req = DiffRequest(
                source: .stash(ref: stashSelection.ref),
                path: stashSelection.path,
                title: "Stash · \(stashSelection.message)"
            )
            if session.inspector.inlineDiffRequest != req {
                session.inspector.showInlineDiff(req.source, path: req.path, title: req.title)
            } else if reloadCurrent {
                session.inspector.reloadInlineDiff()
            }
            return
        }
        let current = entries.first(where: { $0.id == selectedEntryID }) ?? entries.first
        if let current {
            if selectedEntryID != current.id {
                selectedEntryID = current.id
            }
            let req = current.diffRequest
            if session.inspector.inlineDiffRequest != req {
                session.inspector.showInlineDiff(req.source, path: req.path, title: req.title)
            } else if reloadCurrent {
                session.inspector.reloadInlineDiff()
            }
        } else {
            selectedEntryID = nil
            session.inspector.clearInlineDiff()
        }
    }

    // MARK: - Left Pane

    private func leftPane(entries: [WorkingCopyChangeEntry], activeID: String?) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: Theme.Space.s) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Changes").font(Theme.Text.title).foregroundStyle(Theme.ink)
                    Text(subtitle)
                        .font(Theme.Text.caption)
                        .foregroundStyle(Theme.inkMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button {
                    workingCopy.refreshWorkingState()
                    workingCopy.refreshPushPlan()
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(GhostIconButtonStyle())
                .help("Refresh working copy status")
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.m)

            HairlineDivider()

            if !state.isClean {
                HStack(spacing: Theme.Space.xs) {
                    SearchField(
                        text: $fileFilter,
                        prompt: "Filter changed files…",
                        focusTrigger: session.navigation.focusLocalFindRequest,
                        onFocusChange: { filterFieldFocused = $0 }
                    )
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
                .padding(.horizontal, Theme.Space.m)
                .padding(.top, Theme.Space.s)
            }

            let visibleConflicted = matching(state.conflicted)
            let visibleStaged = matching(state.staged)
            let visibleUnstaged = matching(state.unstaged)
            let visibleUntracked = matching(state.untracked)
            let visibleStandardTracked = standardTrackedFiles

            ScrollColumn {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    if let error = workingCopy.writeError { errorBanner(error) }
                    if let operation = state.operation { operationBanner(operation) }

                    if !visibleConflicted.isEmpty {
                        conflictsSection(visibleConflicted, activeID: activeID)
                    }

                    if preferences.advanced {
                        if !visibleStaged.isEmpty {
                            fileSection("Staged", visibleStaged, tint: Theme.good, staged: true,
                                        sectionPrefix: "staged", activeID: activeID)
                        }
                        if !visibleUnstaged.isEmpty {
                            fileSection("Changed", visibleUnstaged, tint: Theme.warning, staged: false,
                                        sectionPrefix: "unstaged", activeID: activeID)
                        }
                        if !visibleUntracked.isEmpty {
                            fileSection("Untracked", visibleUntracked, tint: Theme.inkMuted, staged: false,
                                        sectionPrefix: "untracked", activeID: activeID)
                        }
                    } else {
                        if !visibleStandardTracked.isEmpty {
                            standardModifiedSection(visibleStandardTracked, activeID: activeID)
                        }
                        if !visibleUntracked.isEmpty {
                            fileSection("New files", visibleUntracked, tint: Theme.inkMuted, staged: false,
                                        sectionPrefix: "untracked", activeID: activeID)
                        }
                    }

                    if entries.isEmpty && workingCopy.writeError == nil && state.operation == nil {
                        if !trimmedFilter.isEmpty && !state.isClean {
                            HStack(spacing: Theme.Space.s) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.inkMuted)
                                Text("No files matching “\(trimmedFilter)”")
                                    .font(Theme.Text.body)
                                    .foregroundStyle(Theme.inkMuted)
                            }
                            .padding(.horizontal, Theme.Space.s)
                            .padding(.vertical, Theme.Space.m)
                        } else {
                            HStack(spacing: Theme.Space.s) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Theme.good)
                                Text("No local file changes")
                                    .font(Theme.Text.body)
                                    .foregroundStyle(Theme.inkSoft)
                            }
                            .padding(.horizontal, Theme.Space.s)
                            .padding(.vertical, Theme.Space.m)
                        }
                    }

                    if preferences.advanced {
                        stashSection
                    }
                }
                .padding(Theme.Space.m)
            }

            if showBottomDock(hasFiles: !state.isClean) {
                HairlineDivider()
                bottomDock(hasFiles: !state.isClean)
                    .padding(Theme.Space.m)
                    .background(Theme.surface.opacity(0.65))
            }
        }
    }

    private var activeBranchPR: PullRequestSummary? {
        guard let branch = state.branch else { return nil }
        return session.pullRequestsByBranch[branch]
    }

    private var createPullRequestURL: URL? {
        guard let branch = state.branch,
              let info = session.analysis?.info,
              let web = info.remoteWebURL else { return nil }
        return GitHubBridge.createPRURL(remoteWebURL: web, branch: branch, defaultBranch: info.defaultBranch)
    }

    private func showBottomDock(hasFiles: Bool) -> Bool {
        if hasFiles || !workingCopy.commitSubject.isEmpty || workingCopy.amendLastCommit { return true }
        if workingCopy.headCommitInfo?.hasParent == true && workingCopy.headCommitInfo?.isPushedToUpstream == false {
            return true
        }
        if let plan = workingCopy.pushPlan, !plan.isEmpty { return true }
        if activeBranchPR != nil || createPullRequestURL != nil { return true }
        return !preferences.advanced && state.behind > 0
    }

    // MARK: - Right Pane (Live Diff or Clean Empty State)

    @ViewBuilder
    private func rightPane(activeEntry: WorkingCopyChangeEntry?, stashSelection: StashFileSelection?) -> some View {
        if let stashSelection {
            let req = DiffRequest(
                source: .stash(ref: stashSelection.ref),
                path: stashSelection.path,
                title: "Stash · \(stashSelection.message)"
            )
            DiffViewer(request: req, embedded: true)
                .id(req)
        } else if let activeEntry {
            DiffViewer(request: activeEntry.diffRequest, embedded: true)
                .id(activeEntry.diffRequest)
        } else {
            ScrollColumn {
                VStack(spacing: Theme.Space.xl) {
                    Spacer(minLength: Theme.Space.xl)
                    let planCount = workingCopy.pushPlan?.commits.count ?? 0
                    if planCount > 0 || state.behind > 0 {
                        EmptyStateView(
                            icon: "arrow.triangle.2.circlepath",
                            tint: Theme.accent,
                            title: planCount > 0
                                ? "\(planCount) commit\(planCount == 1 ? "" : "s") ready to share"
                                : "\(state.behind) update\(state.behind == 1 ? "" : "s") on remote",
                            message: "Your working tree has no uncommitted edits.",
                            actionTitle: preferences.advanced ? (planCount > 0 ? "Push" : "Pull") : "Sync",
                            action: {
                                if preferences.advanced {
                                    planCount > 0 ? workingCopy.push() : workingCopy.pull()
                                } else {
                                    workingCopy.sync()
                                }
                            }
                        )
                    } else {
                        EmptyStateView(
                            icon: "checkmark.circle.fill",
                            tint: Theme.good,
                            title: "Working copy is clean",
                            message: "Everything matches the latest commit on \(state.branch ?? "this branch")."
                        )
                    }

                    if let head = session.analysis?.commits.first {
                        Card(padding: Theme.Space.l) {
                            HStack(spacing: Theme.Space.m) {
                                Button {
                                    session.navigation.selectedCommitSHA = head.sha
                                } label: {
                                    HStack(spacing: Theme.Space.m) {
                                        Avatar(name: head.author, size: 30)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Latest commit").font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                                            Text(head.subject.isEmpty ? "(no message)" : head.subject)
                                                .font(Theme.Text.bodyBold).foregroundStyle(Theme.ink).lineLimit(1)
                                            Text("\(head.author) · \(RiskExplanation.relative(head.date, now: Date()))")
                                                .font(Theme.Text.caption).foregroundStyle(Theme.inkSoft)
                                        }
                                        Spacer(minLength: Theme.Space.s)
                                        if preferences.advanced {
                                            ShaChip(sha: head.sha)
                                        }
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(Theme.inkMuted)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                if let info = workingCopy.headCommitInfo, info.hasParent, !info.isPushedToUpstream {
                                    Rectangle().fill(Theme.hairline).frame(width: 1, height: 28)
                                    Button("Undo") {
                                        workingCopy.confirmUndoLastCommit()
                                    }
                                    .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                                    .disabled(workingCopy.writeInFlight)
                                    .help("Undo last commit and keep changes staged (git reset --soft HEAD~1)")
                                }
                            }
                        }
                        .frame(maxWidth: 560)
                    }
                    Spacer(minLength: Theme.Space.xl)
                }
                .padding(Theme.Space.xl)
                .frame(maxWidth: .infinity, minHeight: 460)
            }
        }
    }

    // MARK: - Sections & Rows

    private var subtitle: String {
        var parts: [String] = []
        if let branch = state.branch { parts.append("on \(branch)") }
        if preferences.advanced {
            if state.ahead > 0 { parts.append("\(state.ahead) to push") }
            if state.behind > 0 { parts.append("\(state.behind) to pull") }
        } else {
            if state.ahead > 0 { parts.append("\(state.ahead) to share") }
            if state.behind > 0 { parts.append("\(state.behind) behind") }
        }
        return parts.isEmpty ? "Working copy" : parts.joined(separator: " · ")
    }

    private func errorBanner(_ error: String) -> some View {
        Card(padding: Theme.Space.m) {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.critical)
                VStack(alignment: .leading, spacing: 4) {
                    Text("git refused that").font(Theme.Text.bodyBold).foregroundStyle(Theme.ink)
                    Text(error).font(Theme.Text.caption).foregroundStyle(Theme.inkSoft)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    Button("View Log") {
                        session.navigation.isCommandLogSheetPresented = true
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .controlSize(.mini)
                }
                Spacer()
                Button { workingCopy.writeError = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 11))
                }
                .buttonStyle(GhostIconButtonStyle())
            }
        }
    }

    private func operationBanner(_ operation: WorkingState.Operation) -> some View {
        let readyToContinue = state.conflicted.isEmpty && operation != .bisect
        return Card(padding: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: operation == .bisect ? "magnifyingglass.circle.fill" : (readyToContinue ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"))
                        .foregroundStyle(operation == .bisect ? Theme.accent : (readyToContinue ? Theme.good : Theme.warning))
                    Text(operation.label).font(Theme.Text.bodyBold).foregroundStyle(Theme.ink)
                    Spacer()
                    Button(abortButtonTitle(operation)) {
                        workingCopy.confirmAbortOperation(operation)
                    }
                    .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                    .disabled(workingCopy.writeInFlight)
                    if readyToContinue {
                        Button(continueButtonTitle(operation)) {
                            workingCopy.continueOperation(operation)
                        }
                        .buttonStyle(PrimaryButtonStyle()).controlSize(.small)
                        .disabled(workingCopy.writeInFlight)
                    }
                }
                if operation == .bisect {
                    if let bisect = workingCopy.bisectStatus {
                        Text("Testing \(String(bisect.currentSHA.prefix(7))) · \(bisect.currentSubject)")
                            .font(Theme.Text.mono)
                            .foregroundStyle(Theme.inkSoft)
                            .lineLimit(2)
                    } else {
                        Text("Test the checked-out commit and mark whether the bug is present.")
                            .font(Theme.Text.caption).foregroundStyle(Theme.inkSoft)
                    }
                    HStack(spacing: Theme.Space.xs) {
                        Button("Mark Good") { workingCopy.bisectMark(.good) }
                            .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                            .disabled(workingCopy.writeInFlight)
                        Button("Mark Bad") { workingCopy.bisectMark(.bad) }
                            .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                            .disabled(workingCopy.writeInFlight)
                        Button("Skip") { workingCopy.bisectMark(.skip) }
                            .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                            .disabled(workingCopy.writeInFlight)
                    }
                } else {
                    Text(readyToContinue
                         ? "All conflicts are resolved — continue to finish."
                         : "Resolve conflicts below, then continue or safely abort.")
                        .font(Theme.Text.caption).foregroundStyle(Theme.inkSoft)
                }
            }
        }
    }

    private func continueButtonTitle(_ operation: WorkingState.Operation) -> String {
        switch operation {
        case .merge: return "Continue Merge"
        case .rebase: return "Continue Rebase"
        case .cherryPick: return "Continue Cherry-pick"
        case .revert: return "Continue Revert"
        case .bisect: return "Continue"
        }
    }

    private func abortButtonTitle(_ operation: WorkingState.Operation) -> String {
        switch operation {
        case .merge: return "Abort Merge"
        case .rebase: return "Abort Rebase"
        case .cherryPick: return "Abort Cherry-pick"
        case .revert: return "Abort Revert"
        case .bisect: return "Reset Bisect"
        }
    }

    private func conflictsSection(_ files: [WorkingState.FileStatus], activeID: String?) -> some View {
        Card(padding: Theme.Space.s) {
            VStack(spacing: 0) {
                HStack {
                    Text("CONFLICTS").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.critical)
                    Text("\(files.count)").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.critical)
                    Spacer()
                }
                .padding(.horizontal, Theme.Space.s).padding(.vertical, 6)
                HairlineDivider()
                ForEach(files) { file in
                    let entryID = "conflicted:\(file.path)"
                    ConflictFileRow(
                        file: file,
                        selected: activeID == entryID,
                        root: session.analysis?.root,
                        onSelect: { selectedEntryID = entryID }
                    )
                    if file.id != files.last?.id { HairlineDivider() }
                }
            }
        }
    }

    private func groupedFiles(_ files: [WorkingState.FileStatus]) -> [(folder: String, files: [WorkingState.FileStatus])] {
        var byFolder: [String: [WorkingState.FileStatus]] = [:]
        for file in files {
            let folder = (file.path as NSString).deletingLastPathComponent
            byFolder[folder, default: []].append(file)
        }
        return byFolder
            .map { (folder: $0.key, files: $0.value) }
            .sorted { lhs, rhs in
                if lhs.folder.isEmpty != rhs.folder.isEmpty { return lhs.folder.isEmpty }
                return lhs.folder < rhs.folder
            }
    }

    private func folderHeading(_ folder: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "folder.fill")
                .font(.system(size: 10))
                .foregroundStyle(Theme.accent.opacity(0.85))
            Text(folder)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.inkSoft)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private func changesContextMenu(for file: WorkingState.FileStatus, staged: Bool) -> some View {
        PathActions(path: file.path)
        if !staged && !file.isUntracked && !file.isConflicted {
            Divider()
            Button("Stash This File") {
                workingCopy.stashSelected(paths: [file.path])
            }
            .disabled(workingCopy.writeInFlight)
        }
        if file.isUntracked {
            let ext = URL(fileURLWithPath: file.path).pathExtension
            let folder = (file.path as NSString).deletingLastPathComponent
            Divider()
            Button("Add to .gitignore") {
                workingCopy.addToGitignore([file.path])
            }
            .disabled(workingCopy.writeInFlight)
            if !ext.isEmpty {
                Button("Ignore all *.\(ext) files") {
                    workingCopy.addToGitignore(["*.\(ext)"])
                }
                .disabled(workingCopy.writeInFlight)
            }
            if !folder.isEmpty {
                Button("Ignore folder \(folder)/") {
                    workingCopy.addToGitignore(["\(folder)/"])
                }
                .disabled(workingCopy.writeInFlight)
            }
        }
    }

    private func standardModifiedSection(_ files: [WorkingState.FileStatus], activeID: String?) -> some View {
        let allIncluded = files.allSatisfy { $0.staged != .unchanged && $0.unstaged == .unchanged }
        let unstagedCount = files.count(where: { $0.unstaged != .unchanged })
        return Card(padding: Theme.Space.s) {
            VStack(spacing: 0) {
                HStack {
                    Text("MODIFIED FILES").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.inkMuted)
                    Text("\(files.count)").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.inkMuted)
                    Spacer()
                    if unstagedCount > 1 {
                        Button("Discard all") {
                            workingCopy.confirmDiscardAllUnstaged(count: unstagedCount)
                        }
                        .buttonStyle(SecondaryButtonStyle()).controlSize(.mini)
                        .disabled(workingCopy.writeInFlight)
                        .help("Discard all unstaged modifications")
                    }
                    Button(allIncluded ? "Unselect all" : "Include all") {
                        let paths = files.map(\.path)
                        allIncluded ? workingCopy.unstage(paths) : workingCopy.stage(paths)
                    }
                    .buttonStyle(SecondaryButtonStyle()).controlSize(.mini)
                }
                .padding(.horizontal, Theme.Space.s).padding(.vertical, 6)
                HairlineDivider()
                if showTreeView {
                    let groups = groupedFiles(files)
                    ForEach(Array(groups.enumerated()), id: \.element.folder) { gIdx, group in
                        if !group.folder.isEmpty {
                            if gIdx > 0 { HairlineDivider() }
                            folderHeading(group.folder)
                        }
                        ForEach(group.files) { file in
                            standardRow(file, activeID: activeID, compactFolder: !group.folder.isEmpty)
                                .padding(.leading, group.folder.isEmpty ? 0 : 12)
                                .contextMenu { changesContextMenu(for: file, staged: false) }
                        }
                    }
                } else {
                    ForEach(files) { file in
                        standardRow(file, activeID: activeID)
                            .contextMenu { changesContextMenu(for: file, staged: false) }
                        if file.id != files.last?.id { HairlineDivider() }
                    }
                }
            }
        }
    }

    private func standardRow(_ file: WorkingState.FileStatus, activeID: String?, compactFolder: Bool = false) -> some View {
        let entryID = "tracked:\(file.path)"
        let isSelected = activeID == entryID
        let fullyIncluded = file.staged != .unchanged && file.unstaged == .unchanged
        let partiallyIncluded = file.staged != .unchanged && file.unstaged != .unchanged
        let fileName = (file.path as NSString).lastPathComponent
        let folderPath = (file.path as NSString).deletingLastPathComponent

        return HStack(spacing: Theme.Space.s) {
            Button {
                fullyIncluded ? workingCopy.unstage([file.path]) : workingCopy.stage([file.path])
            } label: {
                Image(systemName: fullyIncluded ? "checkmark.square.fill" : (partiallyIncluded ? "minus.square.fill" : "square"))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle((fullyIncluded || partiallyIncluded) ? Theme.accent : Theme.inkMuted)
            }
            .buttonStyle(.plain)
            .help(fullyIncluded ? "Exclude from commit" : "Include all edits in commit")

            Button {
                selectedStashFile = nil
                selectedEntryID = entryID
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(fileName).font(Theme.Text.body.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(Theme.ink).lineLimit(1)
                    if partiallyIncluded {
                        Text("Newer edits not included").font(.system(size: 10)).foregroundStyle(Theme.warning)
                    } else if !compactFolder && !folderPath.isEmpty {
                        Text(folderPath).font(.system(size: 10)).foregroundStyle(Theme.inkMuted)
                            .lineLimit(1).truncationMode(.head)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                workingCopy.confirmDiscard(file)
            } label: {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 11)).foregroundStyle(Theme.critical)
            }
            .buttonStyle(.plain)
            .help("Revert edits in this file")
        }
        .padding(.horizontal, Theme.Space.s).padding(.vertical, 6)
        .background(isSelected ? Theme.accentWash : .clear,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .opacity(workingCopy.writeInFlight ? 0.5 : 1)
    }

    private func fileSection(_ title: String, _ files: [WorkingState.FileStatus],
                             tint: Color, staged: Bool, sectionPrefix: String, activeID: String?) -> some View {
        let isTrackedUnstaged = !staged && sectionPrefix == "unstaged"
        return Card(padding: Theme.Space.s) {
            VStack(spacing: 0) {
                HStack {
                    Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.inkMuted)
                    Text("\(files.count)").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.inkMuted)
                    Spacer()
                    if isTrackedUnstaged && files.count > 1 {
                        Button("Discard all") {
                            workingCopy.confirmDiscardAllUnstaged(count: files.count)
                        }
                        .buttonStyle(SecondaryButtonStyle()).controlSize(.mini)
                        .disabled(workingCopy.writeInFlight)
                        .help("Discard all unstaged modifications")
                    }
                    Button(staged ? "Unstage all" : (preferences.advanced ? "Stage all" : "Include all")) {
                        staged ? workingCopy.unstage(files.map(\.path)) : workingCopy.stage(files.map(\.path))
                    }
                    .buttonStyle(SecondaryButtonStyle()).controlSize(.mini)
                }
                .padding(.horizontal, Theme.Space.s).padding(.vertical, 6)
                HairlineDivider()
                if showTreeView {
                    let groups = groupedFiles(files)
                    ForEach(Array(groups.enumerated()), id: \.element.folder) { gIdx, group in
                        if !group.folder.isEmpty {
                            if gIdx > 0 { HairlineDivider() }
                            folderHeading(group.folder)
                        }
                        ForEach(group.files) { file in
                            let entryID = "\(sectionPrefix):\(file.path)"
                            row(file, tint: tint, staged: staged, entryID: entryID,
                                isSelected: activeID == entryID, compactFolder: !group.folder.isEmpty)
                                .padding(.leading, group.folder.isEmpty ? 0 : 12)
                                .contextMenu { changesContextMenu(for: file, staged: staged) }
                        }
                    }
                } else {
                    ForEach(files) { file in
                        let entryID = "\(sectionPrefix):\(file.path)"
                        row(file, tint: tint, staged: staged, entryID: entryID, isSelected: activeID == entryID)
                            .contextMenu { changesContextMenu(for: file, staged: staged) }
                        if file.id != files.last?.id { HairlineDivider() }
                    }
                }
            }
        }
    }

    private func row(_ file: WorkingState.FileStatus, tint: Color, staged: Bool,
                     entryID: String, isSelected: Bool, compactFolder: Bool = false) -> some View {
        let fileName = (file.path as NSString).lastPathComponent
        let folderPath = (file.path as NSString).deletingLastPathComponent
        return HStack(spacing: Theme.Space.s) {
            Text(marker(file, staged: staged))
                .font(Theme.Text.mono).foregroundStyle(tint).frame(width: 14)
            Button {
                selectedStashFile = nil
                selectedEntryID = entryID
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(fileName).font(Theme.Text.body.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(Theme.ink).lineLimit(1)
                    if let original = file.originalPath {
                        Text("from \(original)").font(.system(size: 10)).foregroundStyle(Theme.inkMuted)
                            .lineLimit(1).truncationMode(.head)
                    } else if !compactFolder && !folderPath.isEmpty {
                        Text(folderPath).font(.system(size: 10)).foregroundStyle(Theme.inkMuted)
                            .lineLimit(1).truncationMode(.head)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if staged {
                Button { workingCopy.unstage([file.path]) } label: {
                    Image(systemName: "minus.circle").font(.system(size: 12)).foregroundStyle(Theme.inkSoft)
                }
                .buttonStyle(.plain)
                .help("Unstage file")
            } else {
                Button { workingCopy.stage([file.path]) } label: {
                    Image(systemName: "plus.circle").font(.system(size: 12)).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .help(preferences.advanced ? "Stage file" : "Include file")

                Button {
                    file.isUntracked ? workingCopy.confirmDelete(file) : workingCopy.confirmDiscard(file)
                } label: {
                    Image(systemName: file.isUntracked ? "trash" : "arrow.uturn.backward")
                        .font(.system(size: 11)).foregroundStyle(Theme.critical)
                }
                .buttonStyle(.plain)
                .help(file.isUntracked ? "Delete untracked file" : "Discard changes")
            }
        }
        .padding(.horizontal, Theme.Space.s).padding(.vertical, 6)
        .background(isSelected ? Theme.accentWash : .clear,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .opacity(workingCopy.writeInFlight ? 0.5 : 1)
    }

    private func marker(_ file: WorkingState.FileStatus, staged: Bool) -> String {
        if file.isConflicted { return "!" }
        if file.isUntracked { return "?" }
        switch staged ? file.staged : file.unstaged {
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        default: return "M"
        }
    }

    private var contributorIdentities: [(name: String, email: String)] {
        guard let commits = session.analysis?.commits else { return [] }
        var seenEmails: Set<String> = []
        var result: [(name: String, email: String)] = []
        for commit in commits {
            let email = commit.email.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = commit.author.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !email.isEmpty else { continue }
            let key = email.lowercased()
            if seenEmails.insert(key).inserted {
                result.append((name: name, email: email))
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @ViewBuilder
    private var composerUtilityBar: some View {
        @Bindable var workingCopy = workingCopy
        let coAuthors = contributorIdentities
        let hasHistoryMenu = workingCopy.commitTemplateText != nil || !workingCopy.recentMessages.isEmpty
        if !staticRendering && (hasHistoryMenu || !coAuthors.isEmpty || preferences.advanced) {
            HStack(spacing: Theme.Space.xs) {
                if hasHistoryMenu {
                    Menu {
                        if let template = workingCopy.commitTemplateText {
                            Button("Apply Commit Template") {
                                let lines = template.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                                workingCopy.commitSubject = lines.first.map(String.init) ?? ""
                                workingCopy.commitBody = lines.count > 1
                                    ? String(lines[1]).trimmingCharacters(in: .newlines)
                                    : ""
                            }
                            if !workingCopy.recentMessages.isEmpty {
                                Divider()
                            }
                        }
                        ForEach(workingCopy.recentMessages.prefix(10)) { item in
                            Button(item.subject) {
                                workingCopy.commitSubject = item.subject
                                workingCopy.commitBody = item.body
                            }
                        }
                    } label: {
                        Label("Messages", systemImage: "clock.arrow.circlepath")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Insert a commit template or reuse a recent commit message")
                }

                if !coAuthors.isEmpty {
                    Menu {
                        ForEach(coAuthors.prefix(25), id: \.email) { person in
                            Button("\(person.name) <\(person.email)>") {
                                workingCopy.appendCoAuthor(name: person.name, email: person.email)
                            }
                        }
                    } label: {
                        Label("Co-author", systemImage: "person.badge.plus")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Append a Co-authored-by trailer from repository contributors")
                }

                Spacer(minLength: 0)

                if preferences.advanced {
                    composerTogglePill(
                        title: "Sign",
                        systemImage: workingCopy.signCommit ? "checkmark.seal.fill" : "signature",
                        isOn: $workingCopy.signCommit,
                        tint: Theme.accent,
                        helpText: "Sign this commit with GPG/SSH (git commit -S)"
                    )
                    composerTogglePill(
                        title: "No-verify",
                        systemImage: workingCopy.skipHooks ? "checkmark.circle.fill" : "bolt.slash",
                        isOn: $workingCopy.skipHooks,
                        tint: Theme.warning,
                        helpText: "Skip pre-commit and commit-msg hooks (--no-verify)"
                    )
                }
            }
        }
    }

    private func composerTogglePill(
        title: String,
        systemImage: String,
        isOn: Binding<Bool>,
        tint: Color,
        helpText: String
    ) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(isOn.wrappedValue ? tint : Theme.inkSoft)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                isOn.wrappedValue ? tint.opacity(0.14) : Theme.wash,
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(isOn.wrappedValue ? tint.opacity(0.5) : Theme.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    // MARK: - Bottom Commit & Share Dock

    @ViewBuilder
    private func bottomDock(hasFiles: Bool) -> some View {
        @Bindable var workingCopy = workingCopy
        let amending = workingCopy.amendLastCommit
        let canCommit = (!state.staged.isEmpty || amending)
            && !workingCopy.commitSubject.trimmingCharacters(in: .whitespaces).isEmpty
            && !workingCopy.writeInFlight
        let subjectLength = workingCopy.commitSubject.count
        let showEditor = hasFiles || !workingCopy.commitSubject.isEmpty || amending
        let headInfo = workingCopy.headCommitInfo
        let canAmend = headInfo != nil && (!(headInfo?.isPushedToUpstream ?? true) || preferences.advanced)
        let canUndo = headInfo?.hasParent == true && headInfo?.isPushedToUpstream == false

        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if showEditor {
                HStack(spacing: Theme.Space.s) {
                    Text(amending ? "Amend last commit" : (preferences.advanced ? "Commit" : "Save changes"))
                        .font(Theme.Text.bodyBold).foregroundStyle(Theme.ink)
                    Spacer()
                    if subjectLength > 0 {
                        Text("\(subjectLength)/72")
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(subjectLength > 72 ? Theme.critical : (subjectLength > 50 ? Theme.warning : Theme.inkMuted))
                    }
                    Text(preferences.advanced ? "\(state.staged.count) staged" : "\(state.staged.count) included")
                        .font(Theme.Text.caption.monospacedDigit())
                        .foregroundStyle(state.staged.isEmpty ? Theme.inkMuted : Theme.good)
                }

                if canAmend || canUndo {
                    HStack(spacing: Theme.Space.s) {
                        if canAmend {
                            Button {
                                workingCopy.toggleAmend()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: amending ? "checkmark.square.fill" : "square")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(amending ? Theme.accent : Theme.inkMuted)
                                    Text("Amend previous")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(Theme.inkSoft)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                        if canUndo && !amending {
                            Button("Undo last commit") {
                                workingCopy.confirmUndoLastCommit()
                            }
                            .buttonStyle(SecondaryButtonStyle()).controlSize(.mini)
                            .disabled(workingCopy.writeInFlight)
                        }
                    }
                }

                if amending && headInfo?.isPushedToUpstream == true && preferences.advanced {
                    Text("Latest commit is already pushed — amending rewrites history.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.warning)
                }

                if staticRendering {
                    staticTextBox(
                        workingCopy.commitSubject.isEmpty
                            ? (preferences.advanced ? "Summary" : "What did you change?")
                            : workingCopy.commitSubject,
                        isEmpty: workingCopy.commitSubject.isEmpty,
                        height: 28
                    )
                    staticTextBox(
                        workingCopy.commitBody.isEmpty
                            ? (preferences.advanced ? "Description (optional)" : "Notes (optional)")
                            : workingCopy.commitBody,
                        isEmpty: workingCopy.commitBody.isEmpty,
                        height: 46
                    )
                } else {
                    TextField(preferences.advanced ? "Summary" : "What did you change?", text: $workingCopy.commitSubject)
                        .textFieldStyle(.plain)
                        .font(Theme.Text.body)
                        .focused($commitInputFocused)
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(Theme.page, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                            .strokeBorder(Theme.hairline))
                    TextEditor(text: $workingCopy.commitBody)
                        .font(Theme.Text.body).frame(height: 52).scrollContentBackground(.hidden)
                        .focused($commitInputFocused)
                        .padding(6)
                        .background(Theme.page, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                            .strokeBorder(Theme.hairline))
                        .overlay(alignment: .topLeading) {
                            if workingCopy.commitBody.isEmpty {
                                Text(preferences.advanced ? "Description (optional)" : "Notes (optional)")
                                    .font(Theme.Text.body).foregroundStyle(Theme.inkMuted)
                                    .padding(.horizontal, 10).padding(.vertical, 10).allowsHitTesting(false)
                            }
                        }
                }

                composerUtilityBar

                HStack(spacing: Theme.Space.s) {
                    if !preferences.advanced, workingCopy.pushPlan != nil || session.analysis?.info.remoteURL != nil {
                        Button(amending ? "Amend" : "Commit") {
                            workingCopy.commitStaged(allowPublishedAmend: preferences.advanced)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .frame(maxWidth: .infinity)
                        .disabled(!canCommit)
                        Button(amending ? "Amend & Push" : "Commit & Push") {
                            workingCopy.commitAndPush(allowPublishedAmend: preferences.advanced)
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .frame(maxWidth: .infinity)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!canCommit)
                    } else {
                        Button(amending
                               ? "Amend Commit"
                               : "Commit \(state.staged.count) file\(state.staged.count == 1 ? "" : "s")") {
                            workingCopy.commitStaged(allowPublishedAmend: preferences.advanced)
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .frame(maxWidth: .infinity)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!canCommit)
                    }
                }
            } else if canAmend || canUndo {
                HStack(spacing: Theme.Space.s) {
                    if canAmend {
                        Button("Amend last commit") { workingCopy.toggleAmend() }
                            .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                            .disabled(workingCopy.writeInFlight)
                    }
                    Spacer()
                    if canUndo {
                        Button("Undo last commit") { workingCopy.confirmUndoLastCommit() }
                            .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                            .disabled(workingCopy.writeInFlight)
                    }
                }
            }

            if let plan = workingCopy.pushPlan,
               (!plan.isEmpty || (preferences.advanced && workingCopy.lastPushRejectedNonFastForward)) {
                let defaultBranch = session.analysis?.info.defaultBranch
                let isProtected = GitRepository.isProtectedBranch(plan.branch, defaultBranch: defaultBranch)
                let offerForceLease = preferences.advanced
                    && !isProtected
                    && ((state.ahead > 0 && state.behind > 0) || workingCopy.lastPushRejectedNonFastForward)
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.accent)
                    Text(preferences.advanced
                         ? "\(plan.commits.count) commit\(plan.commits.count == 1 ? "" : "s") -> \(plan.remote)/\(plan.branch)"
                         : "\(plan.commits.count) commit\(plan.commits.count == 1 ? "" : "s") ready to share")
                        .font(Theme.Text.caption).foregroundStyle(Theme.inkSoft).lineLimit(1)
                    Spacer()
                    if offerForceLease {
                        Button("Force Push (lease)…") {
                            workingCopy.confirmForcePushWithLease(
                                defaultBranch: defaultBranch,
                                allowProtected: true
                            )
                        }
                        .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                        .disabled(workingCopy.writeInFlight)
                        .help("Safely force-push rewritten commits using --force-with-lease")
                    }
                    Button(preferences.advanced ? "Push" : "Sync") {
                        preferences.advanced ? workingCopy.push() : workingCopy.sync()
                    }
                    .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                    .disabled(workingCopy.writeInFlight)
                }
                .padding(.top, 2)
            } else if !preferences.advanced && state.behind > 0 {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.accent)
                    Text("\(state.behind) update\(state.behind == 1 ? "" : "s") available")
                        .font(Theme.Text.caption).foregroundStyle(Theme.inkSoft)
                    Spacer()
                    Button("Sync") { workingCopy.sync() }
                        .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                        .disabled(workingCopy.writeInFlight)
                }
                .padding(.top, 2)
            }

            if let pr = activeBranchPR {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: pr.checkStatus == .failing ? "exclamationmark.circle.fill" : "arrow.triangle.pull")
                        .font(.system(size: 11))
                        .foregroundStyle(pr.checkStatus == .passing ? Theme.good : (pr.checkStatus == .failing ? Theme.critical : Theme.accent))
                    Text("PR #\(pr.number) · \(pr.title)")
                        .font(Theme.Text.caption)
                        .foregroundStyle(Theme.inkSoft)
                        .lineLimit(1)
                    Spacer()
                    Button("Open PR") { NSWorkspace.shared.open(pr.url) }
                        .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                }
                .padding(.top, 2)
            } else if let createURL = createPullRequestURL, (workingCopy.pushPlan?.commits.isEmpty ?? true) {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "arrow.triangle.pull")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.inkMuted)
                    Text("Ready to open a pull request from \(state.branch ?? "branch")")
                        .font(Theme.Text.caption)
                        .foregroundStyle(Theme.inkSoft)
                        .lineLimit(1)
                    Spacer()
                    Button("Create PR") { NSWorkspace.shared.open(createURL) }
                        .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                }
                .padding(.top, 2)
            }
        }
    }

    private func staticTextBox(_ text: String, isEmpty: Bool, height: CGFloat) -> some View {
        Text(text)
            .font(Theme.Text.body)
            .foregroundStyle(isEmpty ? Theme.inkMuted : Theme.ink)
            .frame(maxWidth: .infinity, minHeight: height, alignment: .topLeading)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(Theme.page, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.hairline))
    }

    private var stashSection: some View {
        @Bindable var workingCopy = workingCopy
        return Card(padding: Theme.Space.s) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Button {
                    stashesExpanded.toggle()
                } label: {
                    HStack {
                        Image(systemName: stashesExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.inkMuted)
                        Text("STASHES").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.inkMuted)
                        if !state.stashes.isEmpty {
                            Chip(text: "\(state.stashes.count)")
                        }
                        Spacer()
                    }
                    .padding(.horizontal, Theme.Space.s).padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if stashesExpanded {
                    HairlineDivider()
                    if !state.isClean {
                        HStack(spacing: Theme.Space.xs) {
                            if staticRendering {
                                staticTextBox(workingCopy.stashMessage.isEmpty ? "Stash note…" : workingCopy.stashMessage,
                                              isEmpty: workingCopy.stashMessage.isEmpty, height: 24)
                            } else {
                                TextField("Stash note…", text: $workingCopy.stashMessage)
                                    .textFieldStyle(.roundedBorder)
                            }
                            Button("Stash") { workingCopy.stashEverything(includeUntracked: true) }
                                .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                                .disabled(workingCopy.writeInFlight)
                        }
                        .padding(.horizontal, Theme.Space.s)
                    }
                    ForEach(state.stashes) { stash in
                        let isExpanded = expandedStashRef == stash.ref
                        let stashFiles = session.inspector.stashFilesByRef[stash.ref]
                        let isLoadingFiles = session.inspector.loadingStashRefs.contains(stash.ref)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: Theme.Space.xs) {
                                Button {
                                    if isExpanded {
                                        expandedStashRef = nil
                                    } else {
                                        expandedStashRef = stash.ref
                                        session.inspector.ensureStashFiles(ref: stash.ref)
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(Theme.inkMuted)
                                            .frame(width: 10)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(stash.message).font(Theme.Text.caption).foregroundStyle(Theme.ink).lineLimit(1)
                                            Text(RiskExplanation.relative(stash.date, now: Date()))
                                                .font(.system(size: 10)).foregroundStyle(Theme.inkMuted)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Button("Apply") { workingCopy.applyStash(stash.ref, removing: false) }
                                    .buttonStyle(SecondaryButtonStyle()).controlSize(.mini)
                                    .disabled(workingCopy.writeInFlight)
                                    .help("Apply stash without removing it")
                                Button("Pop") { workingCopy.applyStash(stash.ref, removing: true) }
                                    .buttonStyle(SecondaryButtonStyle()).controlSize(.mini)
                                    .disabled(workingCopy.writeInFlight)
                                    .help("Apply stash and remove it from list")
                                Button { workingCopy.confirmDropStash(stash) } label: {
                                    Image(systemName: "trash").font(.system(size: 10)).foregroundStyle(Theme.critical)
                                }
                                .buttonStyle(.plain)
                                .disabled(workingCopy.writeInFlight)
                                .help("Drop stash")
                            }
                            .contextMenu {
                                Button("Inspect Stash Contents") {
                                    expandedStashRef = stash.ref
                                    session.inspector.ensureStashFiles(ref: stash.ref)
                                }
                                Button("Apply Stash (Keep)") { workingCopy.applyStash(stash.ref, removing: false) }
                                    .disabled(workingCopy.writeInFlight)
                                Button("Pop Stash") { workingCopy.applyStash(stash.ref, removing: true) }
                                    .disabled(workingCopy.writeInFlight)
                                Divider()
                                Button("Drop Stash…", role: .destructive) { workingCopy.confirmDropStash(stash) }
                            }

                            if isExpanded {
                                VStack(alignment: .leading, spacing: 2) {
                                    if isLoadingFiles && stashFiles == nil {
                                        HStack(spacing: 6) {
                                            ProgressView().controlSize(.small).scaleEffect(0.7)
                                            Text("Reading stashed files…")
                                                .font(.system(size: 10))
                                                .foregroundStyle(Theme.inkMuted)
                                        }
                                        .padding(.vertical, 3)
                                    } else if let stashFiles, !stashFiles.isEmpty {
                                        ForEach(stashFiles) { delta in
                                            let isStashFileSelected = selectedStashFile?.ref == stash.ref && selectedStashFile?.path == delta.path
                                            Button {
                                                selectedStashFile = StashFileSelection(
                                                    ref: stash.ref,
                                                    message: stash.message,
                                                    path: delta.path
                                                )
                                            } label: {
                                                HStack(spacing: Theme.Space.xs) {
                                                    Image(systemName: "doc.text")
                                                        .font(.system(size: 10))
                                                        .foregroundStyle(Theme.inkMuted)
                                                    Text((delta.path as NSString).lastPathComponent)
                                                        .font(.system(size: 11, weight: isStashFileSelected ? .semibold : .regular))
                                                        .foregroundStyle(Theme.ink)
                                                        .lineLimit(1)
                                                    Spacer(minLength: 4)
                                                    if delta.isBinary {
                                                        Text("bin").font(.system(size: 10)).foregroundStyle(Theme.inkMuted)
                                                    } else {
                                                        if delta.insertions > 0 {
                                                            Text("+\(delta.insertions)")
                                                                .font(.system(size: 10).monospacedDigit())
                                                                .foregroundStyle(Theme.good)
                                                        }
                                                        if delta.deletions > 0 {
                                                            Text("−\(delta.deletions)")
                                                                .font(.system(size: 10).monospacedDigit())
                                                                .foregroundStyle(Theme.critical)
                                                        }
                                                    }
                                                }
                                                .padding(.horizontal, 6).padding(.vertical, 4)
                                                .background(
                                                    isStashFileSelected ? Theme.accentWash : .clear,
                                                    in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                                                )
                                                .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    } else {
                                        Text("No file differences reported.")
                                            .font(.system(size: 10))
                                            .foregroundStyle(Theme.inkMuted)
                                            .padding(.vertical, 2)
                                    }
                                }
                                .padding(.leading, 16)
                            }
                        }
                        .padding(.horizontal, Theme.Space.s).padding(.vertical, 2)
                    }
                    if state.stashes.isEmpty && state.isClean {
                        Text("No stashes.").font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                            .padding(.horizontal, Theme.Space.s).padding(.bottom, 4)
                    }
                }
            }
        }
    }
}

private struct ConflictFileRow: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(AppPreferences.self) private var preferences
    @Environment(WorkingCopyStore.self) private var workingCopy
    let file: WorkingState.FileStatus
    let selected: Bool
    let root: URL?
    let onSelect: () -> Void

    @State private var expanded = false
    @State private var versions: GitRepository.ConflictFileVersions?
    @State private var blocks: [ConflictBlock] = []
    @State private var loading = false

    private var fileURL: URL? {
        guard let root else { return nil }
        let url = root.appendingPathComponent(file.path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func loadConflictData() {
        guard let root else { return }
        loading = true
        let path = file.path
        Task.detached(priority: .userInitiated) {
            let repo = GitRepository(url: root)
            let loadedVersions = try? repo.conflictVersions(path: path)
            let loadedBlocks = (try? repo.conflictBlocks(path: path)) ?? []
            await MainActor.run {
                self.versions = loadedVersions
                self.blocks = loadedBlocks
                self.loading = false
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Text("!").font(Theme.Text.mono).foregroundStyle(Theme.critical).frame(width: 14)
                Button(action: onSelect) {
                    Text(file.path).font(Theme.Text.bodyBold).foregroundStyle(Theme.ink)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: Theme.Space.xs) {
                Button(expanded ? "Hide Blocks" : (preferences.advanced ? "Blocks" : "Resolve")) {
                    expanded.toggle()
                }
                .buttonStyle(SecondaryButtonStyle()).controlSize(.mini)
                if let url = fileURL {
                    Button("Open") {
                        openInEditor(url, line: blocks.first?.startLine ?? versions?.firstConflictLine)
                    }
                    .buttonStyle(SecondaryButtonStyle()).controlSize(.mini)
                }
                Button(preferences.advanced ? "Ours" : "Keep mine") {
                    workingCopy.confirmResolveConflict(path: file.path, acceptOurs: true)
                }
                .buttonStyle(SecondaryButtonStyle()).controlSize(.mini)
                .disabled(workingCopy.writeInFlight)
                Button(preferences.advanced ? "Theirs" : "Incoming") {
                    workingCopy.confirmResolveConflict(path: file.path, acceptOurs: false)
                }
                .buttonStyle(SecondaryButtonStyle()).controlSize(.mini)
                .disabled(workingCopy.writeInFlight)
                Spacer()
                Button("Resolved") {
                    workingCopy.stage([file.path])
                }
                .buttonStyle(PrimaryButtonStyle()).controlSize(.mini)
                .disabled(workingCopy.writeInFlight)
            }

            if expanded {
                if loading && versions == nil && blocks.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Loading conflict sections…").font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                    }
                } else if !blocks.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        ForEach(blocks) { block in
                            conflictBlockCard(block)
                        }
                    }
                } else if let versions {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        conflictSidePreview(title: "Ours (Current Branch)", content: versions.ours, tint: Theme.accent)
                        conflictSidePreview(title: "Theirs (Incoming Changes)", content: versions.theirs, tint: Theme.tint(.violet))
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Space.s).padding(.vertical, 8)
        .background(selected ? Theme.accentWash : .clear,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .contextMenu { PathActions(path: file.path) }
        .task(id: expanded) {
            guard expanded else { return }
            loadConflictData()
        }
    }

    private func conflictBlockCard(_ block: ConflictBlock) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.xs) {
                Text("Conflict \(block.id + 1) · Line \(block.startLine)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.inkSoft)
                Spacer()
                Button(preferences.advanced ? "Ours" : "Mine") {
                    workingCopy.resolveConflictBlock(path: file.path, blockIndex: block.id, choice: .ours) {
                        loadConflictData()
                        session.inspector.reloadInlineDiff()
                    }
                }
                .buttonStyle(SecondaryButtonStyle()).controlSize(.mini)
                .disabled(workingCopy.writeInFlight)

                Button(preferences.advanced ? "Theirs" : "Incoming") {
                    workingCopy.resolveConflictBlock(path: file.path, blockIndex: block.id, choice: .theirs) {
                        loadConflictData()
                        session.inspector.reloadInlineDiff()
                    }
                }
                .buttonStyle(SecondaryButtonStyle()).controlSize(.mini)
                .disabled(workingCopy.writeInFlight)

                Button("Both") {
                    workingCopy.resolveConflictBlock(path: file.path, blockIndex: block.id, choice: .both) {
                        loadConflictData()
                        session.inspector.reloadInlineDiff()
                    }
                }
                .buttonStyle(SecondaryButtonStyle()).controlSize(.mini)
                .disabled(workingCopy.writeInFlight)
            }
            conflictSidePreview(
                title: block.oursLabel.isEmpty ? "Current changes" : block.oursLabel,
                content: block.oursText,
                tint: Theme.accent
            )
            conflictSidePreview(
                title: block.theirsLabel.isEmpty ? "Incoming changes" : block.theirsLabel,
                content: block.theirsText,
                tint: Theme.tint(.violet)
            )
        }
        .padding(Theme.Space.s)
        .background(Theme.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.hairline))
    }

    private func conflictSidePreview(title: String, content: String?, tint: Color) -> some View {
        let previewText: String = {
            guard let content else { return "(Deleted on this side)" }
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false).prefix(20)
            return lines.joined(separator: "\n")
        }()
        return VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(tint)
            ScrollView {
                Text(previewText.isEmpty ? " " : previewText)
                    .font(Theme.Text.mono)
                    .foregroundStyle(content == nil ? Theme.inkMuted : Theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 110)
            .padding(Theme.Space.s)
            .background(Theme.page, in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).strokeBorder(tint.opacity(0.35)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
