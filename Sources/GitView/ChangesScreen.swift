import SwiftUI
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
    @Environment(WorkspaceSession.self) private var session
    @Environment(AppPreferences.self) private var preferences
    @Environment(WorkingCopyStore.self) private var workingCopy
    @Environment(\.staticRendering) private var staticRendering
    @State private var selectedEntryID: String?
    @State private var stashesExpanded = false

    private var state: WorkingState { session.analysis?.workingState ?? .clean }

    private var standardTrackedFiles: [WorkingState.FileStatus] {
        state.files.filter { !$0.isUntracked && !$0.isConflicted }
    }

    private var orderedEntries: [WorkingCopyChangeEntry] {
        WorkingCopyChangeEntry.ordered(in: state, advanced: preferences.advanced)
    }

    var body: some View {
        let entries = orderedEntries
        let activeEntry = entries.first(where: { $0.id == selectedEntryID }) ?? entries.first

        HStack(spacing: 0) {
            leftPane(entries: entries, activeID: activeEntry?.id)
                .frame(width: 364)
                .background(Theme.sidebar.opacity(0.45))

            Rectangle().fill(Theme.hairline).frame(width: 1)

            rightPane(activeEntry: activeEntry)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.page)
        }
        .onAppear {
            syncSelectionAndInlineDiff(entries: entries)
        }
        .onChange(of: state) {
            syncSelectionAndInlineDiff(entries: entries, reloadCurrent: true)
        }
        .onChange(of: preferences.advanced) {
            syncSelectionAndInlineDiff(entries: entries)
        }
        .onChange(of: selectedEntryID) {
            syncSelectionAndInlineDiff(entries: entries)
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.downArrow) {
            selectedEntryID = NavigationStore.stepSelection(
                in: entries.map(\.id), current: activeEntry?.id, delta: 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            selectedEntryID = NavigationStore.stepSelection(
                in: entries.map(\.id), current: activeEntry?.id, delta: -1)
            return .handled
        }
        .onKeyPress(.return) {
            guard let chosen = activeEntry else { return .ignored }
            selectedEntryID = chosen.id
            session.inspector.showDiff(.workingTree(staged: chosen.staged), path: chosen.file.path, title: chosen.title)
            return .handled
        }
    }

    private func syncSelectionAndInlineDiff(entries: [WorkingCopyChangeEntry], reloadCurrent: Bool = false) {
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

            ScrollColumn {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    if let error = workingCopy.writeError { errorBanner(error) }
                    if let operation = state.operation { operationBanner(operation) }

                    if !state.conflicted.isEmpty {
                        conflictsSection(state.conflicted, activeID: activeID)
                    }

                    if preferences.advanced {
                        if !state.staged.isEmpty {
                            fileSection("Staged", state.staged, tint: Theme.good, staged: true,
                                        sectionPrefix: "staged", activeID: activeID)
                        }
                        if !state.unstaged.isEmpty {
                            fileSection("Changed", state.unstaged, tint: Theme.warning, staged: false,
                                        sectionPrefix: "unstaged", activeID: activeID)
                        }
                        if !state.untracked.isEmpty {
                            fileSection("Untracked", state.untracked, tint: Theme.inkMuted, staged: false,
                                        sectionPrefix: "untracked", activeID: activeID)
                        }
                    } else {
                        if !standardTrackedFiles.isEmpty {
                            standardModifiedSection(standardTrackedFiles, activeID: activeID)
                        }
                        if !state.untracked.isEmpty {
                            fileSection("New files", state.untracked, tint: Theme.inkMuted, staged: false,
                                        sectionPrefix: "untracked", activeID: activeID)
                        }
                    }

                    if entries.isEmpty && workingCopy.writeError == nil && state.operation == nil {
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

                    if preferences.advanced {
                        stashSection
                    }
                }
                .padding(Theme.Space.m)
            }

            if showBottomDock(entries: entries) {
                HairlineDivider()
                bottomDock(hasFiles: !entries.isEmpty)
                    .padding(Theme.Space.m)
                    .background(Theme.surface.opacity(0.65))
            }
        }
    }

    private func showBottomDock(entries: [WorkingCopyChangeEntry]) -> Bool {
        if !entries.isEmpty || !workingCopy.commitSubject.isEmpty { return true }
        if let plan = workingCopy.pushPlan, !plan.isEmpty { return true }
        return !preferences.advanced && state.behind > 0
    }

    // MARK: - Right Pane (Live Diff or Clean Empty State)

    @ViewBuilder
    private func rightPane(activeEntry: WorkingCopyChangeEntry?) -> some View {
        if let activeEntry {
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
                        Button {
                            session.navigation.selectedCommitSHA = head.sha
                        } label: {
                            Card(padding: Theme.Space.l) {
                                HStack(spacing: Theme.Space.m) {
                                    Avatar(name: head.author, size: 30)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Latest commit").font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                                        Text(head.subject.isEmpty ? "(no message)" : head.subject)
                                            .font(Theme.Text.bodyBold).foregroundStyle(Theme.ink).lineLimit(1)
                                        Text("\(head.author) · \(RiskExplanation.relative(head.date, now: Date()))")
                                            .font(Theme.Text.caption).foregroundStyle(Theme.inkSoft)
                                    }
                                    Spacer()
                                    if preferences.advanced {
                                        ShaChip(sha: head.sha)
                                    }
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(Theme.inkMuted)
                                }
                            }
                            .frame(maxWidth: 520)
                        }
                        .buttonStyle(.plain)
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
                VStack(alignment: .leading, spacing: 2) {
                    Text("git refused that").font(Theme.Text.bodyBold).foregroundStyle(Theme.ink)
                    Text(error).font(Theme.Text.caption).foregroundStyle(Theme.inkSoft)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
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
        Card(padding: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                    Text(operation.label).font(Theme.Text.bodyBold).foregroundStyle(Theme.ink)
                    Spacer()
                    Button(abortButtonTitle(operation)) {
                        workingCopy.confirmAbortOperation(operation)
                    }
                    .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                    .disabled(workingCopy.writeInFlight)
                }
                Text("Resolve conflicts below, then stage to continue or safely abort.")
                    .font(Theme.Text.caption).foregroundStyle(Theme.inkSoft)
            }
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

    private func standardModifiedSection(_ files: [WorkingState.FileStatus], activeID: String?) -> some View {
        let allIncluded = files.allSatisfy { $0.staged != .unchanged && $0.unstaged == .unchanged }
        return Card(padding: Theme.Space.s) {
            VStack(spacing: 0) {
                HStack {
                    Text("MODIFIED FILES").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.inkMuted)
                    Text("\(files.count)").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.inkMuted)
                    Spacer()
                    Button(allIncluded ? "Unselect all" : "Include all") {
                        let paths = files.map(\.path)
                        allIncluded ? workingCopy.unstage(paths) : workingCopy.stage(paths)
                    }
                    .buttonStyle(SecondaryButtonStyle()).controlSize(.mini)
                }
                .padding(.horizontal, Theme.Space.s).padding(.vertical, 6)
                HairlineDivider()
                ForEach(files) { file in
                    standardRow(file, activeID: activeID)
                        .contextMenu { PathActions(path: file.path) }
                    if file.id != files.last?.id { HairlineDivider() }
                }
            }
        }
    }

    private func standardRow(_ file: WorkingState.FileStatus, activeID: String?) -> some View {
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
                selectedEntryID = entryID
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(fileName).font(Theme.Text.body.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(Theme.ink).lineLimit(1)
                    if partiallyIncluded {
                        Text("Newer edits not included").font(.system(size: 10)).foregroundStyle(Theme.warning)
                    } else if !folderPath.isEmpty {
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
        Card(padding: Theme.Space.s) {
            VStack(spacing: 0) {
                HStack {
                    Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.inkMuted)
                    Text("\(files.count)").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.inkMuted)
                    Spacer()
                    Button(staged ? "Unstage all" : (preferences.advanced ? "Stage all" : "Include all")) {
                        staged ? workingCopy.unstage(files.map(\.path)) : workingCopy.stage(files.map(\.path))
                    }
                    .buttonStyle(SecondaryButtonStyle()).controlSize(.mini)
                }
                .padding(.horizontal, Theme.Space.s).padding(.vertical, 6)
                HairlineDivider()
                ForEach(files) { file in
                    let entryID = "\(sectionPrefix):\(file.path)"
                    row(file, tint: tint, staged: staged, entryID: entryID, isSelected: activeID == entryID)
                        .contextMenu { PathActions(path: file.path) }
                    if file.id != files.last?.id { HairlineDivider() }
                }
            }
        }
    }

    private func row(_ file: WorkingState.FileStatus, tint: Color, staged: Bool,
                     entryID: String, isSelected: Bool) -> some View {
        let fileName = (file.path as NSString).lastPathComponent
        let folderPath = (file.path as NSString).deletingLastPathComponent
        return HStack(spacing: Theme.Space.s) {
            Text(marker(file, staged: staged))
                .font(Theme.Text.mono).foregroundStyle(tint).frame(width: 14)
            Button {
                selectedEntryID = entryID
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(fileName).font(Theme.Text.body.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(Theme.ink).lineLimit(1)
                    if let original = file.originalPath {
                        Text("from \(original)").font(.system(size: 10)).foregroundStyle(Theme.inkMuted)
                            .lineLimit(1).truncationMode(.head)
                    } else if !folderPath.isEmpty {
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

    // MARK: - Bottom Commit & Share Dock

    @ViewBuilder
    private func bottomDock(hasFiles: Bool) -> some View {
        @Bindable var workingCopy = workingCopy
        let canCommit = !state.staged.isEmpty
            && !workingCopy.commitSubject.trimmingCharacters(in: .whitespaces).isEmpty
            && !workingCopy.writeInFlight
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if hasFiles || !workingCopy.commitSubject.isEmpty {
                HStack {
                    Text(preferences.advanced ? "Commit" : "Save changes")
                        .font(Theme.Text.bodyBold).foregroundStyle(Theme.ink)
                    Spacer()
                    Text(preferences.advanced ? "\(state.staged.count) staged" : "\(state.staged.count) included")
                        .font(Theme.Text.caption.monospacedDigit())
                        .foregroundStyle(state.staged.isEmpty ? Theme.inkMuted : Theme.good)
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
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(Theme.page, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                            .strokeBorder(Theme.hairline))
                    TextEditor(text: $workingCopy.commitBody)
                        .font(Theme.Text.body).frame(height: 52).scrollContentBackground(.hidden)
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

                HStack(spacing: Theme.Space.s) {
                    if !preferences.advanced, workingCopy.pushPlan != nil || session.analysis?.info.remoteURL != nil {
                        Button("Commit") { workingCopy.commitStaged() }
                            .buttonStyle(SecondaryButtonStyle())
                            .frame(maxWidth: .infinity)
                            .disabled(!canCommit)
                        Button("Commit & Push") { workingCopy.commitAndPush() }
                            .buttonStyle(PrimaryButtonStyle())
                            .frame(maxWidth: .infinity)
                            .disabled(!canCommit)
                    } else {
                        Button("Commit \(state.staged.count) file\(state.staged.count == 1 ? "" : "s")") {
                            workingCopy.commitStaged()
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .frame(maxWidth: .infinity)
                        .disabled(!canCommit)
                    }
                }
            }

            if let plan = workingCopy.pushPlan, !plan.isEmpty {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.accent)
                    Text(preferences.advanced
                         ? "\(plan.commits.count) commit\(plan.commits.count == 1 ? "" : "s") -> \(plan.remote)/\(plan.branch)"
                         : "\(plan.commits.count) commit\(plan.commits.count == 1 ? "" : "s") ready to share")
                        .font(Theme.Text.caption).foregroundStyle(Theme.inkSoft).lineLimit(1)
                    Spacer()
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
                        HStack(spacing: Theme.Space.xs) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(stash.message).font(Theme.Text.caption).foregroundStyle(Theme.ink).lineLimit(1)
                                Text(RiskExplanation.relative(stash.date, now: Date()))
                                    .font(.system(size: 10)).foregroundStyle(Theme.inkMuted)
                            }
                            Spacer()
                            Button("Pop") { workingCopy.applyStash(stash.ref, removing: true) }
                                .buttonStyle(SecondaryButtonStyle()).controlSize(.mini)
                            Button { workingCopy.confirmDropStash(stash) } label: {
                                Image(systemName: "trash").font(.system(size: 10)).foregroundStyle(Theme.critical)
                            }
                            .buttonStyle(.plain)
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
    @State private var loading = false

    private var fileURL: URL? {
        guard let root else { return nil }
        let url = root.appendingPathComponent(file.path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
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
                if preferences.advanced {
                    Button(expanded ? "Hide Sides" : "Sides") {
                        expanded.toggle()
                    }
                    .buttonStyle(SecondaryButtonStyle()).controlSize(.mini)
                }
                if let url = fileURL {
                    Button("Open") {
                        openInEditor(url, line: versions?.firstConflictLine)
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

            if preferences.advanced && expanded {
                if loading && versions == nil {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Loading conflict stages…").font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
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
            guard expanded, versions == nil, let root else { return }
            loading = true
            let path = file.path
            let loaded = await Task.detached(priority: .userInitiated) {
                try? GitRepository(url: root).conflictVersions(path: path)
            }.value
            guard !Task.isCancelled else { return }
            versions = loaded
            loading = false
        }
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
