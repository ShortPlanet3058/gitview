import SwiftUI
import GitViewCore
import GitViewGit

struct BranchesScreen: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(AppPreferences.self) private var preferences
    @Environment(WorkingCopyStore.self) private var workingCopy
    @Environment(\.staticRendering) private var staticRendering
    @State private var showMerged = false
    @State private var query = ""
    @State private var newBranchName = ""
    @State private var renamingBranch: BranchInfo?
    @State private var renameName = ""

    var body: some View {
        if let analysis = session.analysis {
            let advanced = preferences.advanced
            let pool = advanced ? analysis.branches : analysis.branches.filter { !$0.isRemote }
            let merged = advanced ? pool.filter { $0.isMerged } : []
            let shown = pool.filter {
                (advanced ? (showMerged || !$0.isMerged) : true)
                && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))
            }
            Page {
                ScreenHeader(
                    title: "Branches",
                    subtitle: advanced
                        ? "Local and remote branches in this repository, newest activity first."
                        : "Switch between branches or start a new branch."
                )
                HStack(spacing: Theme.Space.m) {
                    SearchField(text: $query, prompt: "Filter branches",
                                focusTrigger: session.navigation.focusLocalFindRequest).frame(maxWidth: 280)
                    Spacer()
                    if staticRendering {
                        Text(newBranchName.isEmpty ? "New branch name…" : newBranchName)
                            .font(Theme.Text.body)
                            .foregroundStyle(newBranchName.isEmpty ? Theme.inkMuted : Theme.ink)
                            .frame(width: 170, alignment: .leading)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.hairline))
                    } else {
                        TextField("New branch name…", text: $newBranchName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 190)
                            .onSubmit(createBranch)
                    }
                    Button("New branch", action: createBranch)
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(newBranchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || workingCopy.writeInFlight)
                    Text("\(shown.count) of \(pool.count)").font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                }
                Card(padding: Theme.Space.s) {
                    VStack(spacing: 0) {
                        TableHeading(columns: [
                            ("Name", nil, .leading),
                            (advanced ? "Last commit" : "Latest update", 240, .leading),
                            (advanced ? "Behind / Ahead" : "Status", 120, .trailing),
                            ("Actions", 160, .trailing)
                        ])
                        HairlineDivider()
                        ForEach(shown) { branch in
                            BranchRow(
                                branch: branch,
                                advanced: advanced,
                                currentBranch: analysis.info.currentBranch,
                                root: analysis.root,
                                onRename: { target in
                                    renamingBranch = target
                                    renameName = target.name
                                }
                            )
                            if branch.id != shown.last?.id { HairlineDivider() }
                        }
                        if advanced && !merged.isEmpty {
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
                if advanced {
                    Text("Behind / ahead are counted against the default branch (\(analysis.info.defaultBranch)). "
                         + "Remote-tracking branches without a local copy are marked “remote”.")
                        .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                }
            }
            .sheet(item: $renamingBranch) { branch in
                renameBranchSheet(branch)
            }
        }
    }

    private func renameBranchSheet(_ branch: BranchInfo) -> some View {
        let trimmed = renameName.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text("Rename Branch").font(Theme.Text.title).foregroundStyle(Theme.ink)
            VStack(alignment: .leading, spacing: 4) {
                Text("New name for “\(branch.name)”").font(Theme.Text.caption).foregroundStyle(Theme.inkSoft)
                TextField(branch.name, text: $renameName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        guard !trimmed.isEmpty, trimmed != branch.name else { return }
                        workingCopy.renameBranch(from: branch.name, to: trimmed)
                        renamingBranch = nil
                    }
            }
            HStack {
                Spacer()
                Button("Cancel") { renamingBranch = nil }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Rename") {
                    workingCopy.renameBranch(from: branch.name, to: trimmed)
                    renamingBranch = nil
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(trimmed.isEmpty || trimmed == branch.name || workingCopy.writeInFlight)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 360)
        .background(Theme.surface)
    }

    private func createBranch() {
        let trimmed = newBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        newBranchName = ""
        workingCopy.createBranch(name: trimmed)
    }
}

struct BranchRow: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(WorkingCopyStore.self) private var workingCopy
    @Environment(\.staticRendering) private var staticRendering
    let branch: BranchInfo
    var advanced: Bool = true
    var currentBranch: String? = nil
    var root: URL? = nil
    var onRename: ((BranchInfo) -> Void)? = nil

    private var canDeleteMerged: Bool {
        advanced && !branch.isRemote && !branch.isCurrent && !branch.isDefault && branch.isMerged
    }

    private var canForceDelete: Bool {
        advanced && !branch.isRemote && !branch.isCurrent && !branch.isDefault && !branch.isMerged
    }

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
                Text(branch.name).font(branch.isDefault ? Theme.Text.bodyBold : Theme.Text.body).foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.middle)
                if branch.isDefault { Chip(text: "Default", tint: Theme.accent) }
                if branch.isCurrent && !branch.isDefault { Chip(text: "Current", tint: Theme.good) }
                if advanced && branch.isRemote { Chip(text: "remote") }
                if advanced && branch.isMerged { Chip(text: "merged") }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(branch.subject).font(Theme.Text.body).foregroundStyle(Theme.inkSoft).lineLimit(1)
                Text("\(branch.author) · \(RiskExplanation.relative(branch.date, now: Date()))")
                    .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
            }
            .frame(width: 240, alignment: .leading)
            statusCell
                .frame(width: 120, alignment: .trailing)
            HStack(spacing: Theme.Space.xs) {
                if !branch.isCurrent {
                    Button(branch.isRemote ? "Track" : "Switch") {
                        workingCopy.switchBranch(branch.checkoutTarget, isRemote: branch.isRemote)
                    }
                    .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                    .disabled(workingCopy.writeInFlight)
                }
                if canDeleteMerged {
                    Button { workingCopy.confirmDeleteBranch(branch) } label: {
                        Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(Theme.critical)
                    }
                    .buttonStyle(.plain)
                    .disabled(workingCopy.writeInFlight)
                    .help("Delete merged branch")
                }
                if staticRendering {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.inkSoft)
                        .frame(width: 24)
                } else {
                    Menu {
                        rowActionsMenuContent
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.inkSoft)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 24)
                }
            }
            .frame(width: 160, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Space.m).padding(.vertical, 9)
        .contextMenu {
            rowActionsMenuContent
        }
    }

    @ViewBuilder
    private var rowActionsMenuContent: some View {
        if !branch.isCurrent {
            Button(branch.isRemote ? "Track & Switch" : "Switch to Branch") {
                workingCopy.switchBranch(branch.checkoutTarget, isRemote: branch.isRemote)
            }
            Button("Merge into \(currentBranch ?? "Current Branch")…") {
                workingCopy.confirmMergeBranch(branch, into: currentBranch)
            }
            .disabled(workingCopy.writeInFlight)
            if advanced {
                Button("Rebase \(currentBranch ?? "Current Branch") onto \(branch.name)…") {
                    workingCopy.confirmRebaseOnto(branch, currentBranch: currentBranch)
                }
                .disabled(workingCopy.writeInFlight)
            }
            if let root {
                Button("Compare with Current Branch") {
                    session.navigation.compareFrom = branch.name
                    session.navigation.compareTo = "HEAD"
                    session.navigation.runComparison(in: root)
                    session.show(.releases)
                }
            }
        }
        if !branch.isRemote {
            if !branch.isCurrent { Divider() }
            Button("Rename Branch…") {
                onRename?(branch)
            }
            .disabled(workingCopy.writeInFlight)
        }
        if canDeleteMerged {
            Divider()
            Button("Delete Merged Branch", role: .destructive) {
                workingCopy.confirmDeleteBranch(branch)
            }
        } else if canForceDelete {
            Divider()
            Button("Force Delete Branch…", role: .destructive) {
                workingCopy.confirmForceDeleteBranch(branch)
            }
        }
    }

    @ViewBuilder
    private var statusCell: some View {
        if advanced {
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
        } else {
            Text(plainStatus)
                .font(Theme.Text.caption)
                .foregroundStyle(plainStatusTint)
        }
    }

    private var plainStatus: String {
        if branch.isCurrent { return "Active" }
        if branch.isDefault { return "Main branch" }
        if let ahead = branch.ahead, let behind = branch.behind {
            if ahead == 0 && behind == 0 { return "Up to date" }
            if ahead > 0 && behind == 0 { return "\(ahead) ahead" }
            if behind > 0 && ahead == 0 { return "\(behind) behind" }
            return "\(ahead) ahead · \(behind) behind"
        }
        return "Local branch"
    }

    private var plainStatusTint: Color {
        if branch.isCurrent { return Theme.good }
        if let ahead = branch.ahead, let behind = branch.behind {
            if behind > 0 { return Theme.serious }
            if ahead > 0 { return Theme.accent }
        }
        return Theme.inkMuted
    }
}
