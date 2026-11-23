import SwiftUI
import GitViewCore
import GitViewGit

/// The staging area: what has changed, what is ready to commit, and the few operations
/// that change the repository.
struct ChangesScreen: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(AppPreferences.self) private var preferences
    @Environment(WorkingCopyStore.self) private var workingCopy
    @State private var selectedEntryID: String?

    private struct SelectableEntry: Identifiable {
        let id: String
        let file: WorkingState.FileStatus
        let staged: Bool
        let title: String
    }

    private var state: WorkingState { session.analysis?.workingState ?? .clean }

    private var standardTrackedFiles: [WorkingState.FileStatus] {
        state.files.filter { !$0.isUntracked && !$0.isConflicted }
    }

    private var orderedEntries: [SelectableEntry] {
        var entries: [SelectableEntry] = []
        entries.append(contentsOf: state.conflicted.map {
            SelectableEntry(id: "conflicted:\($0.path)", file: $0, staged: false, title: "Conflicted file")
        })
        if preferences.advanced {
            entries.append(contentsOf: state.staged.map {
                SelectableEntry(id: "staged:\($0.path)", file: $0, staged: true, title: "Staged changes")
            })
            entries.append(contentsOf: state.unstaged.map {
                SelectableEntry(id: "unstaged:\($0.path)", file: $0, staged: false, title: "Uncommitted changes")
            })
        } else {
            entries.append(contentsOf: standardTrackedFiles.map { file in
                let stagedOnly = file.staged != .unchanged && file.unstaged == .unchanged
                return SelectableEntry(id: "tracked:\(file.path)", file: file, staged: stagedOnly, title: "Modified file")
            })
        }
        entries.append(contentsOf: state.untracked.map {
            SelectableEntry(id: "untracked:\($0.path)", file: $0, staged: false, title: preferences.advanced ? "Untracked file" : "New file")
        })
        return entries
    }

    var body: some View {
        Page {
            HStack(alignment: .top) {
                ScreenHeader(title: "Changes", subtitle: subtitle)
                Spacer()
                Button { workingCopy.refreshWorkingState(); workingCopy.refreshPushPlan() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(SecondaryButtonStyle())
            }

            if let error = workingCopy.writeError { errorCard(error) }
            if let operation = state.operation { operationCard(operation) }

            let isCleanForMode = preferences.advanced
                ? (state.isClean && !state.hasUnpushedCommits && state.stashes.isEmpty)
                : (state.isClean && !state.hasUnpushedCommits && state.behind == 0)

            if isCleanForMode {
                cleanCard
            } else {
                if !preferences.advanced && state.isClean {
                    cleanCard
                }
                if !state.conflicted.isEmpty {
                    conflictsSection(state.conflicted)
                }
                if preferences.advanced {
                    if !state.staged.isEmpty {
                        fileSection("Staged", state.staged, tint: Theme.good, staged: true, sectionPrefix: "staged")
                    }
                    if !state.staged.isEmpty || !workingCopy.commitSubject.isEmpty { commitCard }
                    if !state.unstaged.isEmpty {
                        fileSection("Changed", state.unstaged, tint: Theme.warning, staged: false, sectionPrefix: "unstaged")
                    }
                    if !state.untracked.isEmpty {
                        fileSection("Untracked", state.untracked, tint: Theme.inkMuted, staged: false, sectionPrefix: "untracked")
                    }
                } else {
                    if !standardTrackedFiles.isEmpty {
                        standardModifiedSection(standardTrackedFiles)
                    }
                    if !state.untracked.isEmpty {
                        fileSection("New files", state.untracked, tint: Theme.inkMuted, staged: false, sectionPrefix: "untracked")
                    }
                    if !standardTrackedFiles.isEmpty || !state.staged.isEmpty || !workingCopy.commitSubject.isEmpty {
                        commitCard
                    }
                }
            }

            if preferences.advanced || (workingCopy.pushPlan.map { !$0.isEmpty } ?? false) || state.behind > 0 {
                pushCard
            }
            if preferences.advanced {
                stashCard
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.downArrow) {
            selectedEntryID = NavigationStore.stepSelection(
                in: orderedEntries.map(\.id), current: selectedEntryID, delta: 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            selectedEntryID = NavigationStore.stepSelection(
                in: orderedEntries.map(\.id), current: selectedEntryID, delta: -1)
            return .handled
        }
        .onKeyPress(.return) {
            let entries = orderedEntries
            let chosen = entries.first(where: { $0.id == selectedEntryID }) ?? entries.first
            guard let chosen else { return .ignored }
            selectedEntryID = chosen.id
            session.inspector.showDiff(.workingTree(staged: chosen.staged), path: chosen.file.path, title: chosen.title)
            return .handled
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let branch = state.branch { parts.append("on \(branch)") }
        if preferences.advanced {
            if state.ahead > 0 { parts.append("\(state.ahead) to push") }
            if state.behind > 0 { parts.append("\(state.behind) to pull") }
        } else {
            if state.ahead > 0 { parts.append("\(state.ahead) ready to share") }
            if state.behind > 0 { parts.append("\(state.behind) update\(state.behind == 1 ? "" : "s") available") }
        }
        return parts.isEmpty ? "Your working copy" : parts.joined(separator: " · ")
    }

    private func errorCard(_ error: String) -> some View {
        Card {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.critical)
                VStack(alignment: .leading, spacing: 2) {
                    Text("git refused that").font(Theme.Text.bodyBold).foregroundStyle(Theme.ink)
                    Text(error).font(Theme.Text.caption).foregroundStyle(Theme.inkSoft)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                Spacer()
                Button("Dismiss") { workingCopy.writeError = nil }.buttonStyle(SecondaryButtonStyle())
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

    private func operationCard(_ operation: WorkingState.Operation) -> some View {
        Card {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(operation.label).font(Theme.Text.bodyBold).foregroundStyle(Theme.ink)
                    Text("Resolve any conflicts below and stage to continue, or safely abort to restore the pre-operation state.")
                        .font(Theme.Text.caption).foregroundStyle(Theme.inkSoft)
                }
                Spacer()
                Button(abortButtonTitle(operation)) {
                    workingCopy.confirmAbortOperation(operation)
                }
                .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                .disabled(workingCopy.writeInFlight)
            }
        }
    }

    private func conflictsSection(_ files: [WorkingState.FileStatus]) -> some View {
        Card(padding: Theme.Space.s) {
            VStack(spacing: 0) {
                HStack {
                    Text("CONFLICTS").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.critical)
                    Text("\(files.count)").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.critical)
                    Spacer()
                    Text("Resolve by accepting a side or editing in your editor")
                        .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                }
                .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
                HairlineDivider()
                ForEach(files) { file in
                    let entryID = "conflicted:\(file.path)"
                    ConflictFileRow(
                        file: file,
                        selected: selectedEntryID == entryID,
                        root: session.analysis?.root,
                        onSelect: { selectedEntryID = entryID }
                    )
                    if file.id != files.last?.id { HairlineDivider() }
                }
            }
        }
    }

    private var cleanCard: some View {
        Card {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(Theme.good)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preferences.advanced ? "Nothing to commit" : "Everything is up to date")
                        .font(Theme.Text.heading).foregroundStyle(Theme.ink)
                    Text("Your working copy matches the last commit, and everything is pushed.")
                        .font(Theme.Text.body).foregroundStyle(Theme.inkSoft)
                }
                Spacer()
            }
        }
    }

    private func standardModifiedSection(_ files: [WorkingState.FileStatus]) -> some View {
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
                    .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                }
                .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
                HairlineDivider()
                ForEach(files) { file in
                    standardRow(file)
                        .contextMenu { PathActions(path: file.path) }
                    if file.id != files.last?.id { HairlineDivider() }
                }
            }
        }
    }

    private func standardRow(_ file: WorkingState.FileStatus) -> some View {
        let entryID = "tracked:\(file.path)"
        let isSelected = selectedEntryID == entryID
        let fullyIncluded = file.staged != .unchanged && file.unstaged == .unchanged
        let partiallyIncluded = file.staged != .unchanged && file.unstaged != .unchanged
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
                session.inspector.showDiff(.workingTree(staged: fullyIncluded), path: file.path, title: "Modified file")
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.path).font(Theme.Text.body).foregroundStyle(Theme.ink)
                        .lineLimit(1).truncationMode(.middle)
                    if partiallyIncluded {
                        Text("Has newer edits not yet included")
                            .font(Theme.Text.caption).foregroundStyle(Theme.warning)
                    } else if let original = file.originalPath {
                        Text("renamed from \(original)").font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
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
        .padding(.horizontal, Theme.Space.m).padding(.vertical, 7)
        .background(isSelected ? Theme.accentWash : .clear,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .opacity(workingCopy.writeInFlight ? 0.5 : 1)
    }

    private func fileSection(_ title: String, _ files: [WorkingState.FileStatus],
                             tint: Color, staged: Bool, sectionPrefix: String) -> some View {
        Card(padding: Theme.Space.s) {
            VStack(spacing: 0) {
                HStack {
                    Text(title.uppercased()).font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.inkMuted)
                    Text("\(files.count)").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.inkMuted)
                    Spacer()
                    Button(staged ? "Unstage all" : "Stage all") {
                        staged ? workingCopy.unstage(files.map(\.path)) : workingCopy.stage(files.map(\.path))
                    }
                    .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                }
                .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
                HairlineDivider()
                ForEach(files) { file in
                    let entryID = "\(sectionPrefix):\(file.path)"
                    row(file, tint: tint, staged: staged, entryID: entryID)
                        .contextMenu { PathActions(path: file.path) }
                    if file.id != files.last?.id { HairlineDivider() }
                }
            }
        }
    }

    private func row(_ file: WorkingState.FileStatus, tint: Color, staged: Bool, entryID: String) -> some View {
        let isSelected = selectedEntryID == entryID
        return HStack(spacing: Theme.Space.s) {
            Text(marker(file, staged: staged))
                .font(Theme.Text.mono).foregroundStyle(tint).frame(width: 16)
            Button {
                selectedEntryID = entryID
                let title = staged ? "Staged changes" : (file.isUntracked ? "Untracked file" : "Uncommitted changes")
                session.inspector.showDiff(.workingTree(staged: staged), path: file.path, title: title)
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.path).font(Theme.Text.body).foregroundStyle(Theme.ink)
                        .lineLimit(1).truncationMode(.middle)
                    if let original = file.originalPath {
                        Text("renamed from \(original)").font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                            .lineLimit(1).truncationMode(.head)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if staged {
                Button("Unstage") { workingCopy.unstage([file.path]) }
                    .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
            } else {
                Button(preferences.advanced ? "Stage" : "Include") { workingCopy.stage([file.path]) }
                    .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                Button {
                    file.isUntracked ? workingCopy.confirmDelete(file) : workingCopy.confirmDiscard(file)
                } label: {
                    Image(systemName: file.isUntracked ? "trash" : "arrow.uturn.backward")
                        .font(.system(size: 11)).foregroundStyle(Theme.critical)
                }
                .buttonStyle(.plain)
                .help(file.isUntracked ? "Delete this untracked file" : "Discard these changes")
            }
        }
        .padding(.horizontal, Theme.Space.m).padding(.vertical, 7)
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

    private var commitCard: some View {
        @Bindable var workingCopy = workingCopy
        let canCommit = !state.staged.isEmpty
            && !workingCopy.commitSubject.trimmingCharacters(in: .whitespaces).isEmpty
            && !workingCopy.writeInFlight
        return Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                CardHeader(
                    title: preferences.advanced ? "Commit" : "Save changes",
                    subtitle: preferences.advanced ? "\(state.staged.count) staged" : "\(state.staged.count) included"
                )
                TextField(preferences.advanced ? "Summary" : "What did you change?", text: $workingCopy.commitSubject)
                    .textFieldStyle(.roundedBorder)
                TextEditor(text: $workingCopy.commitBody)
                    .font(Theme.Text.body).frame(height: 70).scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Theme.page, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .strokeBorder(Theme.hairline))
                    .overlay(alignment: .topLeading) {
                        if workingCopy.commitBody.isEmpty {
                            Text(preferences.advanced ? "Description (optional)" : "Notes (optional)")
                                .font(Theme.Text.body).foregroundStyle(Theme.inkMuted)
                                .padding(.horizontal, 10).padding(.vertical, 12).allowsHitTesting(false)
                        }
                    }
                HStack(spacing: Theme.Space.s) {
                    Text("Commits as \(session.analysis?.info.configuredUserNames.first ?? "your git identity")")
                        .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                    Spacer()
                    if !preferences.advanced, workingCopy.pushPlan != nil || session.analysis?.info.remoteURL != nil {
                        Button("Commit") { workingCopy.commitStaged() }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(!canCommit)
                        Button("Commit & Push") { workingCopy.commitAndPush() }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(!canCommit)
                    } else {
                        Button("Commit \(state.staged.count) file\(state.staged.count == 1 ? "" : "s")") {
                            workingCopy.commitStaged()
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!canCommit)
                    }
                }
            }
        }
    }

    private var pushCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                CardHeader(title: preferences.advanced ? "Push" : "Share changes",
                           info: "Sends your commits to the remote, where other people will see them. "
                               + "GitView never force-pushes: if the remote has work you have not got, "
                               + "the answer is to pull, not to overwrite it.")
                if !preferences.advanced {
                    HStack {
                        if let plan = workingCopy.pushPlan, !plan.isEmpty {
                            Text("\(plan.commits.count) commit\(plan.commits.count == 1 ? "" : "s") ready to share.")
                                .font(Theme.Text.body).foregroundStyle(Theme.ink)
                        } else if state.behind > 0 {
                            Text("\(state.behind) update\(state.behind == 1 ? "" : "s") waiting on the remote.")
                                .font(Theme.Text.body).foregroundStyle(Theme.ink)
                        } else {
                            Text("All commits are shared.").font(Theme.Text.body).foregroundStyle(Theme.inkMuted)
                        }
                        Spacer()
                        Button("Sync") { workingCopy.sync() }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(workingCopy.writeInFlight)
                    }
                } else if let plan = workingCopy.pushPlan, !plan.isEmpty {
                    Text("\(plan.commits.count) commit\(plan.commits.count == 1 ? "" : "s") "
                         + "to \(plan.remote)/\(plan.branch)"
                         + (plan.hasUpstream ? "" : " — this will set the upstream"))
                        .font(Theme.Text.body).foregroundStyle(Theme.ink)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(plan.commits.prefix(5), id: \.sha) { commit in
                            Text("• \(commit.subject)").font(Theme.Text.caption).foregroundStyle(Theme.inkSoft)
                                .lineLimit(1)
                        }
                        if plan.commits.count > 5 {
                            Text("  and \(plan.commits.count - 5) more")
                                .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                        }
                    }
                    HStack {
                        if state.behind > 0 {
                            Label("\(state.behind) commit\(state.behind == 1 ? "" : "s") behind — pull first",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(Theme.Text.caption).foregroundStyle(Theme.warning)
                        }
                        Spacer()
                        Button("Push to \(plan.remote)/\(plan.branch)") { workingCopy.push() }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(workingCopy.writeInFlight)
                    }
                } else {
                    Text(workingCopy.pushPlan == nil ? "No remote configured for this branch."
                                               : "Everything is pushed.")
                        .font(Theme.Text.body).foregroundStyle(Theme.inkMuted)
                }
            }
        }
    }

    private var stashCard: some View {
        @Bindable var workingCopy = workingCopy
        return Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                CardHeader(title: "Stashes", subtitle: state.stashes.isEmpty ? nil : "\(state.stashes.count)",
                           info: "A stash sets changes aside without committing them, and is the safe "
                               + "alternative to discarding work you are not sure about.")
                if !state.isClean {
                    HStack(spacing: Theme.Space.s) {
                        TextField("What is this work?", text: $workingCopy.stashMessage)
                            .textFieldStyle(.roundedBorder)
                        Button("Stash all") { workingCopy.stashEverything(includeUntracked: true) }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(workingCopy.writeInFlight)
                    }
                }
                ForEach(state.stashes) { stash in
                    HStack(spacing: Theme.Space.s) {
                        Image(systemName: "tray.full").font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(stash.message).font(Theme.Text.body).foregroundStyle(Theme.ink).lineLimit(1)
                            Text("\(stash.ref) · \(RiskExplanation.relative(stash.date, now: Date()))")
                                .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                        }
                        Spacer()
                        Button("Apply") { workingCopy.applyStash(stash.ref, removing: false) }
                            .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                        Button("Pop") { workingCopy.applyStash(stash.ref, removing: true) }
                            .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                        Button { workingCopy.confirmDropStash(stash) } label: {
                            Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(Theme.critical)
                        }
                        .buttonStyle(.plain).help("Drop this stash")
                    }
                    .padding(.vertical, 3)
                }
                if state.stashes.isEmpty && state.isClean {
                    Text("No stashes.").font(Theme.Text.body).foregroundStyle(Theme.inkMuted)
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
                Text("!").font(Theme.Text.mono).foregroundStyle(Theme.critical).frame(width: 16)
                Button {
                    onSelect()
                    session.inspector.showDiff(.workingTree(staged: false), path: file.path, title: "Conflicted file")
                } label: {
                    Text(file.path).font(Theme.Text.bodyBold).foregroundStyle(Theme.ink)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if preferences.advanced {
                    Button(expanded ? "Hide Sides" : "Inspect Sides") {
                        expanded.toggle()
                    }
                    .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                }

                if let url = fileURL {
                    Button(versions?.firstConflictLine.map { "Open (L\($0))" } ?? "Open in Editor") {
                        openInEditor(url, line: versions?.firstConflictLine)
                    }
                    .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                }

                Button(preferences.advanced ? "Accept Ours" : "Keep mine") {
                    workingCopy.confirmResolveConflict(path: file.path, acceptOurs: true)
                }
                .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                .disabled(workingCopy.writeInFlight)

                Button(preferences.advanced ? "Accept Theirs" : "Use incoming") {
                    workingCopy.confirmResolveConflict(path: file.path, acceptOurs: false)
                }
                .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                .disabled(workingCopy.writeInFlight)

                Button("Mark Resolved") {
                    workingCopy.stage([file.path])
                }
                .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                .disabled(workingCopy.writeInFlight)
            }

            if preferences.advanced && expanded {
                if loading && versions == nil {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Loading conflict stages…").font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                    }
                    .padding(.leading, 24)
                } else if let versions {
                    HStack(alignment: .top, spacing: Theme.Space.m) {
                        conflictSidePreview(title: "Ours (Current Branch)", content: versions.ours, tint: Theme.accent)
                        conflictSidePreview(title: "Theirs (Incoming Changes)", content: versions.theirs, tint: Theme.tint(.violet))
                    }
                    .padding(.leading, 24)
                }
            }
        }
        .padding(.horizontal, Theme.Space.m).padding(.vertical, 8)
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
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false).prefix(40)
            return lines.joined(separator: "\n")
        }()
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(tint)
            ScrollView {
                Text(previewText.isEmpty ? " " : previewText)
                    .font(Theme.Text.mono)
                    .foregroundStyle(content == nil ? Theme.inkMuted : Theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 160)
            .padding(Theme.Space.s)
            .background(Theme.page, in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).strokeBorder(tint.opacity(0.35)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
