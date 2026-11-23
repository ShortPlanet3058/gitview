import SwiftUI
import AppKit
import GitViewCore
import GitViewGit

/// Tabbed management sheet for editing git remotes and linked worktrees.
struct RepositoryManagementSheet: View {
    enum Tab: String, CaseIterable, Identifiable {
        case remotes = "Remotes"
        case worktrees = "Worktrees"
        var id: String { rawValue }
    }

    private enum PendingConfirmation: Identifiable {
        case removeRemote(String)
        case removeWorktree(WorktreeInfo, force: Bool)

        var id: String {
            switch self {
            case .removeRemote(let name): return "remote:\(name)"
            case .removeWorktree(let wt, let force): return "wt:\(wt.path):\(force)"
            }
        }
    }

    @Environment(WorkspaceSession.self) private var session
    @Environment(WorkingCopyStore.self) private var workingCopy
    @Environment(\.dismiss) private var dismiss

    @State private var tab: Tab = .remotes

    // Add remote form
    @State private var newRemoteName = ""
    @State private var newRemoteURL = ""

    // Edit remote inline
    @State private var editingRemoteName: String?
    @State private var editedRemoteName = ""
    @State private var editedRemoteURL = ""

    // Add worktree form
    @State private var worktreeBranch = ""
    @State private var createNewWorktreeBranch = true
    @State private var worktreeFolder: URL?

    @State private var pendingConfirmation: PendingConfirmation?

    private var analysis: RepositoryAnalysis? { session.analysis }

    private var sortedRemotes: [(name: String, url: String)] {
        guard let remotes = analysis?.info.remotes else { return [] }
        return remotes
            .map { (name: $0.key, url: $0.value) }
            .sorted { lhs, rhs in
                if lhs.name == "origin" && rhs.name != "origin" { return true }
                if rhs.name == "origin" && lhs.name != "origin" { return false }
                return lhs.name < rhs.name
            }
    }

    private var resolvedWorktreeDestination: URL? {
        if let worktreeFolder { return worktreeFolder }
        guard let root = analysis?.root else { return nil }
        let safeBranch = worktreeBranch
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        let folderName = safeBranch.isEmpty ? "\(root.lastPathComponent)-worktree" : "\(root.lastPathComponent)-\(safeBranch)"
        return root.deletingLastPathComponent().appendingPathComponent(folderName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: "externaldrive.connected.to.line.below")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Remotes & Worktrees")
                        .font(Theme.Text.title)
                        .foregroundStyle(Theme.ink)
                    if let root = analysis?.root {
                        Text(root.path)
                            .font(Theme.Text.caption)
                            .foregroundStyle(Theme.inkMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
                SegmentPicker(
                    options: Tab.allCases.map { ($0, $0.rawValue) },
                    selection: $tab
                )
                Button("Done") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .padding(Theme.Space.l)
            .background(Theme.raised)

            HairlineDivider()

            if let error = workingCopy.writeError {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.critical)
                    Text(error).font(Theme.Text.caption).foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
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

            ScrollColumn {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    switch tab {
                    case .remotes:
                        remotesBody
                    case .worktrees:
                        worktreesBody
                    }
                }
                .padding(Theme.Space.l)
            }
        }
        .frame(width: 720, height: 520)
        .background(Theme.page)
        .alert(item: $pendingConfirmation) { confirmation in
            switch confirmation {
            case .removeRemote(let name):
                return Alert(
                    title: Text("Remove remote “\(name)”?" ),
                    message: Text("Deletes remote configuration and cached remote-tracking refs for \(name)."),
                    primaryButton: .destructive(Text("Remove Remote")) {
                        workingCopy.removeRemote(name: name)
                    },
                    secondaryButton: .cancel()
                )
            case .removeWorktree(let wt, let force):
                return Alert(
                    title: Text("\(force ? "Force remove" : "Remove") worktree “\(URL(fileURLWithPath: wt.path).lastPathComponent)”?" ),
                    message: Text(force
                                  ? "Deletes the linked worktree directory at \(wt.path), including any uncommitted edits."
                                  : "Removes the linked worktree at \(wt.path). Git refuses removal if uncommitted changes remain."),
                    primaryButton: .destructive(Text(force ? "Force Remove" : "Remove")) {
                        workingCopy.removeWorktree(path: wt.path, force: force)
                    },
                    secondaryButton: .cancel()
                )
            }
        }
    }

    // MARK: - Remotes

    @ViewBuilder
    private var remotesBody: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                CardHeader(title: "Add remote")
                HStack(spacing: Theme.Space.s) {
                    TextField("Name (e.g. origin)", text: $newRemoteName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                    TextField("https://github.com/owner/repo.git", text: $newRemoteURL)
                        .textFieldStyle(.roundedBorder)
                    Button("Add Remote") {
                        let name = newRemoteName.trimmingCharacters(in: .whitespacesAndNewlines)
                        let url = newRemoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
                        workingCopy.addRemote(name: name, url: url) {
                            newRemoteName = ""
                            newRemoteURL = ""
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .controlSize(.small)
                    .disabled(
                        newRemoteName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || newRemoteURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || workingCopy.writeInFlight
                    )
                }
            }
        }

        Card(padding: Theme.Space.s) {
            VStack(spacing: 0) {
                HStack {
                    Text("CONFIGURED REMOTES (\(sortedRemotes.count))")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.inkMuted)
                    Spacer()
                }
                .padding(.horizontal, Theme.Space.s)
                .padding(.vertical, 6)
                HairlineDivider()

                if sortedRemotes.isEmpty {
                    Text("No remotes configured for this repository.")
                        .font(Theme.Text.body)
                        .foregroundStyle(Theme.inkMuted)
                        .padding(Theme.Space.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(sortedRemotes, id: \.name) { remote in
                        remoteRow(name: remote.name, url: remote.url)
                        if remote.name != sortedRemotes.last?.name {
                            HairlineDivider()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func remoteRow(name: String, url: String) -> some View {
        let isEditing = editingRemoteName == name
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "network")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accent)
                Text(name)
                    .font(Theme.Text.bodyBold)
                    .foregroundStyle(Theme.ink)
                if name == "origin" {
                    Chip(text: "Default", tint: Theme.accent)
                }
                Spacer()
                if let web = GitRepository.webURL(fromRemote: url) {
                    Button("Open Web") { NSWorkspace.shared.open(web) }
                        .buttonStyle(SecondaryButtonStyle()).controlSize(.mini)
                }
                Button("Copy URL") { copyToPasteboard(url) }
                    .buttonStyle(SecondaryButtonStyle()).controlSize(.mini)
                Button(isEditing ? "Cancel" : "Edit") {
                    if isEditing {
                        editingRemoteName = nil
                    } else {
                        editingRemoteName = name
                        editedRemoteName = name
                        editedRemoteURL = url
                    }
                }
                .buttonStyle(SecondaryButtonStyle()).controlSize(.mini)
                Button {
                    pendingConfirmation = .removeRemote(name)
                } label: {
                    Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(Theme.critical)
                }
                .buttonStyle(.plain)
                .disabled(workingCopy.writeInFlight)
                .help("Remove remote \(name)")
            }

            if isEditing {
                HStack(spacing: Theme.Space.s) {
                    TextField("Name", text: $editedRemoteName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                    TextField("Remote URL", text: $editedRemoteURL)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        let targetName = editedRemoteName.trimmingCharacters(in: .whitespacesAndNewlines)
                        let targetURL = editedRemoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
                        if targetName != name {
                            workingCopy.renameRemote(from: name, to: targetName) {
                                if targetURL != url {
                                    workingCopy.setRemoteURL(name: targetName, url: targetURL)
                                }
                                editingRemoteName = nil
                            }
                        } else if targetURL != url {
                            workingCopy.setRemoteURL(name: name, url: targetURL) {
                                editingRemoteName = nil
                            }
                        } else {
                            editingRemoteName = nil
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .controlSize(.small)
                    .disabled(
                        editedRemoteName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || editedRemoteURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || workingCopy.writeInFlight
                    )
                }
            } else {
                Text(url)
                    .font(Theme.Text.caption)
                    .foregroundStyle(Theme.inkSoft)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, 8)
    }

    // MARK: - Worktrees

    @ViewBuilder
    private var worktreesBody: some View {
        let worktrees = analysis?.info.worktrees ?? []

        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                CardHeader(title: "Create linked worktree")
                HStack(spacing: Theme.Space.s) {
                    TextField(createNewWorktreeBranch ? "New branch name" : "Existing branch name", text: $worktreeBranch)
                        .textFieldStyle(.roundedBorder)
                    Toggle("Create branch", isOn: $createNewWorktreeBranch)
                        .toggleStyle(.checkbox)
                        .font(Theme.Text.caption)
                }
                HStack(spacing: Theme.Space.s) {
                    Text(resolvedWorktreeDestination?.path ?? "Choose destination folder…")
                        .font(Theme.Text.caption)
                        .foregroundStyle(Theme.inkMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Folder…") { pickWorktreeFolder() }
                        .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                    Button("Create Worktree") {
                        guard let dest = resolvedWorktreeDestination else { return }
                        let branch = worktreeBranch.trimmingCharacters(in: .whitespacesAndNewlines)
                        let base = createNewWorktreeBranch ? analysis?.info.currentBranch : nil
                        workingCopy.addWorktree(
                            path: dest,
                            branch: branch,
                            createBranch: createNewWorktreeBranch,
                            startPoint: base
                        ) {
                            worktreeBranch = ""
                            worktreeFolder = nil
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle()).controlSize(.small)
                    .disabled(
                        resolvedWorktreeDestination == nil
                        || worktreeBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || workingCopy.writeInFlight
                    )
                }
            }
        }

        Card(padding: Theme.Space.s) {
            VStack(spacing: 0) {
                HStack {
                    Text("LINKED WORKTREES (\(worktrees.count))")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.inkMuted)
                    Spacer()
                    Button("Prune Stale") {
                        workingCopy.pruneWorktrees()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .controlSize(.mini)
                    .disabled(workingCopy.writeInFlight)
                }
                .padding(.horizontal, Theme.Space.s)
                .padding(.vertical, 6)
                HairlineDivider()

                ForEach(worktrees) { wt in
                    worktreeRow(wt)
                    if wt.id != worktrees.last?.id {
                        HairlineDivider()
                    }
                }
            }
        }
    }

    private func worktreeRow(_ wt: WorktreeInfo) -> some View {
        let url = URL(fileURLWithPath: wt.path)
        return HStack(spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(url.lastPathComponent)
                        .font(Theme.Text.bodyBold)
                        .foregroundStyle(Theme.ink)
                    if wt.isCurrent {
                        Chip(text: "Current", tint: Theme.good)
                    }
                    Chip(text: wt.branch ?? "detached \(String(wt.headSHA.prefix(7)))", tint: Theme.accent)
                }
                Text(wt.path)
                    .font(Theme.Text.caption)
                    .foregroundStyle(Theme.inkMuted)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            if !wt.isCurrent {
                Button("Open") {
                    dismiss()
                    session.open(url: url)
                }
                .buttonStyle(SecondaryButtonStyle()).controlSize(.mini)
            }
            Button("Finder") { revealInFinder(url) }
                .buttonStyle(SecondaryButtonStyle()).controlSize(.mini)
            if !wt.isCurrent {
                Button {
                    pendingConfirmation = .removeWorktree(wt, force: false)
                } label: {
                    Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(Theme.critical)
                }
                .buttonStyle(.plain)
                .disabled(workingCopy.writeInFlight)
                .help("Remove worktree")
                .contextMenu {
                    Button("Remove Worktree") {
                        pendingConfirmation = .removeWorktree(wt, force: false)
                    }
                    Button("Force Remove Worktree", role: .destructive) {
                        pendingConfirmation = .removeWorktree(wt, force: true)
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, 8)
    }

    private func pickWorktreeFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        if panel.runModal() == .OK, let url = panel.url {
            worktreeFolder = url
        }
    }
}
