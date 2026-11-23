import SwiftUI
import GitViewCore
import GitViewGit

/// Interactive `git reflog` recovery drawer ("Time Machine") for inspecting and recovering lost commits or branches.
struct ReflogSheet: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(WorkingCopyStore.self) private var workingCopy
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [ReflogEntry] = []
    @State private var loading = false
    @State private var loadError: String?
    @State private var query = ""
    @State private var branchTargetEntry: ReflogEntry?
    @State private var newBranchName = ""
    @State private var pendingResetEntry: ReflogEntry?

    private var filtered: [ReflogEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return entries }
        return entries.filter {
            $0.message.localizedCaseInsensitiveContains(q)
                || $0.action.localizedCaseInsensitiveContains(q)
                || $0.selector.localizedCaseInsensitiveContains(q)
                || $0.sha.localizedCaseInsensitiveHasPrefix(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: "clock.arrow.2.circlepath")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reflog Recovery")
                        .font(Theme.Text.title)
                        .foregroundStyle(Theme.ink)
                    Text("Recent HEAD movements recorded locally by git — recover dropped commits, resets, or rebases.")
                        .font(Theme.Text.caption)
                        .foregroundStyle(Theme.inkSoft)
                }
                Spacer()
                Button { loadReflog() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(GhostIconButtonStyle())
                .help("Reload reflog")
                Button("Done") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .padding(Theme.Space.l)
            .background(Theme.raised)

            HairlineDivider()

            HStack(spacing: Theme.Space.s) {
                SearchField(text: $query, prompt: "Filter reflog entries, actions, or SHAs…")
                    .frame(maxWidth: 340)
                Spacer()
                Text("\(filtered.count) of \(entries.count)")
                    .font(Theme.Text.caption.monospacedDigit())
                    .foregroundStyle(Theme.inkMuted)
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.s)
            .background(Theme.wash)

            HairlineDivider()

            if let error = workingCopy.writeError {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.critical)
                    Text(error).font(Theme.Text.caption).foregroundStyle(Theme.ink)
                    Spacer()
                    Button { workingCopy.writeError = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.inkMuted)
                }
                .padding(.horizontal, Theme.Space.l)
                .padding(.vertical, Theme.Space.s)
                .background(Theme.critical.opacity(0.08))
                HairlineDivider()
            }

            if loading && entries.isEmpty {
                VStack(spacing: Theme.Space.s) {
                    ProgressView().controlSize(.small)
                    Text("Reading local reflog…").font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                VStack(spacing: Theme.Space.s) {
                    Text("Could not read reflog").font(Theme.Text.heading).foregroundStyle(Theme.ink)
                    Text(loadError).font(Theme.Text.caption).foregroundStyle(Theme.inkSoft)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                VStack(spacing: Theme.Space.s) {
                    Text(entries.isEmpty ? "No reflog entries yet" : "No entries matching “\(query)”")
                        .font(Theme.Text.heading)
                        .foregroundStyle(Theme.ink)
                    Text("Git records HEAD changes locally as you commit, checkout, rebase, and reset.")
                        .font(Theme.Text.caption)
                        .foregroundStyle(Theme.inkMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollColumn {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { entry in
                            reflogRow(entry)
                            if entry.id != filtered.last?.id {
                                HairlineDivider()
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.vertical, Theme.Space.s)
                }
            }
        }
        .frame(width: 780, height: 540)
        .background(Theme.surface)
        .task(id: session.analysis?.root) {
            loadReflog()
        }
        .popover(item: $branchTargetEntry) { entry in
            newBranchPopover(for: entry)
        }
        .alert(item: $pendingResetEntry) { entry in
            Alert(
                title: Text("Soft reset HEAD to \(entry.shortSHA)?"),
                message: Text("Moves your current branch pointer to \(entry.selector) (\(entry.message.isEmpty ? entry.action : entry.message)) while keeping all working copy and staged edits untouched."),
                primaryButton: .destructive(Text("Soft Reset")) {
                    workingCopy.resetSoft(to: entry.sha) {
                        dismiss()
                    }
                },
                secondaryButton: .cancel()
            )
        }
    }

    private func reflogRow(_ entry: ReflogEntry) -> some View {
        HStack(spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Theme.Space.s) {
                    Text(entry.selector)
                        .font(Theme.Text.mono)
                        .foregroundStyle(Theme.inkSoft)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.wash, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    Chip(text: entry.action, tint: actionTint(entry.action))
                    ShaChip(sha: entry.sha)
                    Spacer(minLength: 0)
                    Text(RiskExplanation.relative(entry.date, now: Date()))
                        .font(Theme.Text.caption)
                        .foregroundStyle(Theme.inkMuted)
                }
                Text(entry.message.isEmpty ? "(no description)" : entry.message)
                    .font(Theme.Text.body)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: Theme.Space.xs) {
                Button("Inspect") {
                    session.navigation.selectedCommitSHA = entry.sha
                    session.inspector.ensureCommitDetail(sha: entry.sha)
                    dismiss()
                }
                .buttonStyle(SecondaryButtonStyle())
                .controlSize(.small)

                Button("Branch…") {
                    newBranchName = "recover-\(entry.shortSHA)"
                    branchTargetEntry = entry
                }
                .buttonStyle(SecondaryButtonStyle())
                .controlSize(.small)
                .disabled(workingCopy.writeInFlight)

                Button("Pick") {
                    workingCopy.cherryPick(sha: entry.sha)
                    dismiss()
                }
                .buttonStyle(SecondaryButtonStyle())
                .controlSize(.small)
                .disabled(workingCopy.writeInFlight)
                .help("Cherry-pick this commit onto current branch")

                Button("Reset…") {
                    pendingResetEntry = entry
                }
                .buttonStyle(SecondaryButtonStyle())
                .controlSize(.small)
                .disabled(workingCopy.writeInFlight)
                .help("Soft reset current branch here (git reset --soft)")
            }
        }
        .padding(.vertical, 9)
    }

    private func newBranchPopover(for entry: ReflogEntry) -> some View {
        let trimmed = newBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Create Recovery Branch at \(entry.shortSHA)")
                .font(Theme.Text.heading)
                .foregroundStyle(Theme.ink)
            TextField("Branch name", text: $newBranchName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { branchTargetEntry = nil }
                    .buttonStyle(SecondaryButtonStyle())
                    .controlSize(.small)
                Button("Create & Switch") {
                    workingCopy.createBranch(name: trimmed, startPoint: entry.sha)
                    branchTargetEntry = nil
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .controlSize(.small)
                .disabled(trimmed.isEmpty || workingCopy.writeInFlight)
            }
        }
        .padding(Theme.Space.m)
        .frame(width: 300)
    }

    private func actionTint(_ action: String) -> Color {
        let lower = action.lowercased()
        if lower.hasPrefix("commit") { return Theme.good }
        if lower.hasPrefix("reset") { return Theme.warning }
        if lower.hasPrefix("rebase") || lower.hasPrefix("cherry-pick") { return Theme.tint(.violet) }
        if lower.hasPrefix("checkout") || lower.hasPrefix("switch") { return Theme.accent }
        return Theme.inkSoft
    }

    private func loadReflog() {
        guard let root = session.analysis?.root else { return }
        loading = true
        loadError = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<[ReflogEntry], Error> in
                Result { try GitRepository(url: root).reflog(limit: 120) }
            }.value
            guard session.analysis?.root == root else { return }
            switch result {
            case .success(let loaded):
                entries = loaded
            case .failure(let error):
                loadError = "\(error)"
            }
            loading = false
        }
    }
}

private extension String {
    func localizedCaseInsensitiveHasPrefix(_ prefix: String) -> Bool {
        lowercased().hasPrefix(prefix.lowercased())
    }
}
