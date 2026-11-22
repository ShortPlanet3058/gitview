import SwiftUI
import GitViewCore
import GitViewGit

/// The staging area: what has changed, what is ready to commit, and the few operations
/// that change the repository.
struct ChangesScreen: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(WorkingCopyStore.self) private var workingCopy

    private var state: WorkingState { session.analysis?.workingState ?? .clean }

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

            if state.isClean && !state.hasUnpushedCommits && state.stashes.isEmpty {
                cleanCard
            } else {
                if !state.staged.isEmpty {
                    fileSection("Staged", state.staged, tint: Theme.good, staged: true)
                }
                if !state.staged.isEmpty || !workingCopy.commitSubject.isEmpty { commitCard }
                if !state.unstaged.isEmpty {
                    fileSection("Changed", state.unstaged, tint: Theme.warning, staged: false)
                }
                if !state.untracked.isEmpty {
                    fileSection("Untracked", state.untracked, tint: Theme.inkMuted, staged: false)
                }
            }

            pushCard
            stashCard
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let branch = state.branch { parts.append("on \(branch)") }
        if state.ahead > 0 { parts.append("\(state.ahead) to push") }
        if state.behind > 0 { parts.append("\(state.behind) to pull") }
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

    private func operationCard(_ operation: WorkingState.Operation) -> some View {
        Card {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(operation.label).font(Theme.Text.bodyBold).foregroundStyle(Theme.ink)
                    Text("Finish or abort it in a terminal — GitView does not drive merges or rebases.")
                        .font(Theme.Text.caption).foregroundStyle(Theme.inkSoft)
                }
                Spacer()
            }
        }
    }

    private var cleanCard: some View {
        Card {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(Theme.good)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nothing to commit").font(Theme.Text.heading).foregroundStyle(Theme.ink)
                    Text("Your working copy matches the last commit, and everything is pushed.")
                        .font(Theme.Text.body).foregroundStyle(Theme.inkSoft)
                }
                Spacer()
            }
        }
    }

    private func fileSection(_ title: String, _ files: [WorkingState.FileStatus],
                             tint: Color, staged: Bool) -> some View {
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
                    row(file, tint: tint, staged: staged)
                        .contextMenu { PathActions(path: file.path) }
                    if file.id != files.last?.id { HairlineDivider() }
                }
            }
        }
    }

    private func row(_ file: WorkingState.FileStatus, tint: Color, staged: Bool) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text(marker(file, staged: staged))
                .font(Theme.Text.mono).foregroundStyle(tint).frame(width: 16)
            Button {
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
                Button("Stage") { workingCopy.stage([file.path]) }
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
        return Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                CardHeader(title: "Commit", subtitle: "\(state.staged.count) staged")
                TextField("Summary", text: $workingCopy.commitSubject).textFieldStyle(.roundedBorder)
                TextEditor(text: $workingCopy.commitBody)
                    .font(Theme.Text.body).frame(height: 70).scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Theme.page, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .strokeBorder(Theme.hairline))
                    .overlay(alignment: .topLeading) {
                        if workingCopy.commitBody.isEmpty {
                            Text("Description (optional)").font(Theme.Text.body).foregroundStyle(Theme.inkMuted)
                                .padding(.horizontal, 10).padding(.vertical, 12).allowsHitTesting(false)
                        }
                    }
                HStack {
                    Text("Commits as \(session.analysis?.info.configuredUserNames.first ?? "your git identity")")
                        .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                    Spacer()
                    Button("Commit \(state.staged.count) file\(state.staged.count == 1 ? "" : "s")") {
                        workingCopy.commitStaged()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(state.staged.isEmpty
                              || workingCopy.commitSubject.trimmingCharacters(in: .whitespaces).isEmpty
                              || workingCopy.writeInFlight)
                }
            }
        }
    }

    private var pushCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                CardHeader(title: "Push",
                           info: "Sends your commits to the remote, where other people will see them. "
                               + "GitView never force-pushes: if the remote has work you have not got, "
                               + "the answer is to pull, not to overwrite it.")
                if let plan = workingCopy.pushPlan, !plan.isEmpty {
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
