import SwiftUI
import GitViewCore
import GitViewGit

struct BranchesScreen: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(AppPreferences.self) private var preferences
    @Environment(WorkingCopyStore.self) private var workingCopy
    @State private var showMerged = false
    @State private var query = ""
    @State private var newBranchName = ""

    var body: some View {
        if let analysis = session.analysis {
            let all = analysis.branches
            let merged = all.filter { $0.isMerged }
            let shown = all.filter { (showMerged || !$0.isMerged) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
            Page {
                ScreenHeader(title: "Branches", subtitle: "Branches in this repository, newest activity first.")
                HStack(spacing: Theme.Space.m) {
                    SearchField(text: $query, prompt: "Filter branches").frame(maxWidth: 280)
                    Spacer()
                    TextField("New branch name…", text: $newBranchName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 190)
                        .onSubmit(createBranch)
                    Button("New branch", action: createBranch)
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(newBranchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || workingCopy.writeInFlight)
                    Text("\(shown.count) of \(all.count)").font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                }
                Card(padding: Theme.Space.s) {
                    VStack(spacing: 0) {
                        TableHeading(columns: [("Name", nil, .leading), ("Last commit", 240, .leading), ("Behind / Ahead", 110, .trailing), ("Actions", 130, .trailing)])
                        HairlineDivider()
                        ForEach(shown) { branch in
                            BranchRow(branch: branch)
                            if branch.id != shown.last?.id { HairlineDivider() }
                        }
                        if !merged.isEmpty {
                            HairlineDivider()
                            Button {
                                showMerged.toggle()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: showMerged ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold))
                                    Text(showMerged ? "Hide merged branches (\(merged.count))" : "Show merged branches (\(merged.count))")
                                }
                                .font(Theme.Text.body).foregroundStyle(Theme.inkSoft)
                                .padding(Theme.Space.m)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if preferences.advanced {
                    Text("Behind / ahead are counted against the default branch (\(analysis.info.defaultBranch)). "
                         + "Remote-tracking branches without a local copy are marked “remote”.")
                        .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                }
            }
        }
    }

    private func createBranch() {
        let trimmed = newBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        newBranchName = ""
        workingCopy.createBranch(name: trimmed)
    }
}

struct BranchRow: View {
    @Environment(WorkingCopyStore.self) private var workingCopy
    let branch: BranchInfo

    private var canDelete: Bool {
        !branch.isRemote && !branch.isCurrent && !branch.isDefault && branch.isMerged
    }

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
                Text(branch.name).font(branch.isDefault ? Theme.Text.bodyBold : Theme.Text.body).foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.middle)
                if branch.isDefault { Chip(text: "Default", tint: Theme.accent) }
                if branch.isCurrent && !branch.isDefault { Chip(text: "Current") }
                if branch.isRemote { Chip(text: "remote") }
                if branch.isMerged { Chip(text: "merged") }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(branch.subject).font(Theme.Text.body).foregroundStyle(Theme.inkSoft).lineLimit(1)
                Text("\(branch.author) · \(RiskExplanation.relative(branch.date, now: Date()))")
                    .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
            }
            .frame(width: 240, alignment: .leading)
            Group {
                if branch.isDefault {
                    Text("—").foregroundStyle(Theme.inkMuted)
                } else if let ahead = branch.ahead, let behind = branch.behind {
                    HStack(spacing: 3) {
                        Text("\(behind)").foregroundStyle(behind > 0 ? Theme.serious : Theme.inkMuted)
                        Text("/").foregroundStyle(Theme.inkMuted)
                        Text("\(ahead)").foregroundStyle(ahead > 0 ? Theme.good : Theme.inkMuted)
                    }
                } else {
                    Text("·").foregroundStyle(Theme.inkMuted)
                }
            }
            .font(Theme.Text.body.monospacedDigit())
            .frame(width: 110, alignment: .trailing)
            HStack(spacing: Theme.Space.xs) {
                if !branch.isCurrent {
                    Button(branch.isRemote ? "Track" : "Switch") {
                        workingCopy.switchBranch(branch.name, isRemote: branch.isRemote)
                    }
                    .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                    .disabled(workingCopy.writeInFlight)
                }
                if canDelete {
                    Button { workingCopy.confirmDeleteBranch(branch) } label: {
                        Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(Theme.critical)
                    }
                    .buttonStyle(.plain)
                    .disabled(workingCopy.writeInFlight)
                    .help("Delete merged branch")
                }
            }
            .frame(width: 130, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Space.m).padding(.vertical, 9)
        .contextMenu {
            if !branch.isCurrent {
                Button(branch.isRemote ? "Track & Switch" : "Switch to Branch") {
                    workingCopy.switchBranch(branch.name, isRemote: branch.isRemote)
                }
            }
            if canDelete {
                Button("Delete Merged Branch", role: .destructive) {
                    workingCopy.confirmDeleteBranch(branch)
                }
            }
        }
    }
}
