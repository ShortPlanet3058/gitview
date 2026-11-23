import SwiftUI
import GitViewCore
import GitViewGit

/// Reorder, reword, squash, fixup, or drop unpushed commits via an interactive rebase plan.
struct InteractiveRebaseSheet: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(WorkingCopyStore.self) private var workingCopy
    @Environment(\.dismiss) private var dismiss

    @State private var baseRef = ""
    @State private var items: [RebaseTodoItem] = []
    @State private var loadingCommits = false
    @State private var loadError: String?

    private var baseOptions: [String] {
        var options: [String] = []
        if let upstream = session.analysis?.workingState.upstream, !upstream.isEmpty {
            options.append(upstream)
        }
        if let defaultBranch = session.analysis?.info.defaultBranch,
           !defaultBranch.isEmpty,
           !options.contains(defaultBranch) {
            options.append(defaultBranch)
        }
        for branch in (session.analysis?.branches ?? []).prefix(20) {
            let ref = branch.isRemote ? "origin/\(branch.name)" : branch.name
            if ref != session.analysis?.info.currentBranch, !options.contains(ref) {
                options.append(ref)
            }
        }
        for n in [3, 5, 10] {
            let rel = "HEAD~\(n)"
            if !options.contains(rel) { options.append(rel) }
        }
        return options
    }

    private var validationError: String? {
        InteractiveRebaseBuilder.validate(items: items)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: "arrow.triangle.swap")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Interactive Rebase")
                        .font(Theme.Text.title)
                        .foregroundStyle(Theme.ink)
                    if let branch = session.analysis?.info.currentBranch {
                        Text("On branch \(branch)")
                            .font(Theme.Text.caption)
                            .foregroundStyle(Theme.inkMuted)
                    }
                }
                Spacer()
                Text("Onto").font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                Picker("Onto", selection: $baseRef) {
                    ForEach(baseOptions, id: \.self) { ref in
                        Text(ref).tag(ref)
                    }
                }
                .labelsHidden()
                .frame(width: 210)
                Button {
                    loadCommits()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(GhostIconButtonStyle())
                .disabled(loadingCommits || workingCopy.writeInFlight)
                .help("Reload commits since base ref")
                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .padding(Theme.Space.l)
            .background(Theme.raised)

            HairlineDivider()

            if let error = workingCopy.writeError ?? loadError {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.critical)
                    Text(error)
                        .font(Theme.Text.caption)
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(.horizontal, Theme.Space.l)
                .padding(.vertical, Theme.Space.s)
                .background(Theme.critical.opacity(0.08))
                HairlineDivider()
            }

            if loadingCommits {
                VStack(spacing: Theme.Space.s) {
                    ProgressView()
                    Text("Loading commits in \(baseRef)..HEAD…")
                        .font(Theme.Text.body)
                        .foregroundStyle(Theme.inkSoft)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                VStack(spacing: Theme.Space.s) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 28))
                        .foregroundStyle(Theme.good)
                    Text("No commits ahead of \(baseRef)")
                        .font(Theme.Text.heading)
                        .foregroundStyle(Theme.ink)
                    Text("Choose an earlier base reference (such as \(baseOptions.last ?? "HEAD~5")) to rebase older commits.")
                        .font(Theme.Text.body)
                        .foregroundStyle(Theme.inkMuted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollColumn {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Text("Oldest commit runs first (top) -> newest commit runs last (bottom).")
                            .font(Theme.Text.caption)
                            .foregroundStyle(Theme.inkMuted)

                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            rebaseRow(index: index, item: item)
                        }
                    }
                    .padding(Theme.Space.l)
                }
            }

            HairlineDivider()

            HStack(spacing: Theme.Space.m) {
                if let validationError, !items.isEmpty {
                    Label(validationError, systemImage: "exclamationmark.circle")
                        .font(Theme.Text.caption)
                        .foregroundStyle(Theme.critical)
                } else if !items.isEmpty {
                    Text(planSummary)
                        .font(Theme.Text.caption)
                        .foregroundStyle(Theme.inkMuted)
                }
                Spacer()
                Button("Run Rebase") {
                    let currentBase = baseRef
                    let plan = items
                    workingCopy.runInteractiveRebase(
                        onto: currentBase,
                        items: plan,
                        onSuccess: {
                            dismiss()
                        },
                        onConflict: {
                            dismiss()
                            session.show(.changes)
                        }
                    )
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(items.isEmpty || validationError != nil || workingCopy.writeInFlight || loadingCommits)
            }
            .padding(Theme.Space.l)
            .background(Theme.raised)
        }
        .frame(width: 780, height: 540)
        .background(Theme.page)
        .onAppear {
            if baseRef.isEmpty {
                baseRef = baseOptions.first ?? "HEAD~5"
            }
            loadCommits()
        }
        .onChange(of: baseRef) {
            loadCommits()
        }
    }

    private var planSummary: String {
        let kept = items.count { $0.action == .pick || $0.action == .reword }
        let combined = items.count { $0.action == .squash || $0.action == .fixup }
        let dropped = items.count { $0.action == .drop }
        var parts = ["\(kept) kept"]
        if combined > 0 { parts.append("\(combined) combined") }
        if dropped > 0 { parts.append("\(dropped) dropped") }
        return parts.joined(separator: " · ")
    }

    private func rebaseRow(index: Int, item: RebaseTodoItem) -> some View {
        Card(padding: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.s) {
                    HStack(spacing: 2) {
                        Button {
                            guard index > 0 else { return }
                            items.swapAt(index, index - 1)
                        } label: {
                            Image(systemName: "chevron.up").font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(SecondaryButtonStyle()).controlSize(.mini)
                        .disabled(index == 0)

                        Button {
                            guard index + 1 < items.count else { return }
                            items.swapAt(index, index + 1)
                        } label: {
                            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(SecondaryButtonStyle()).controlSize(.mini)
                        .disabled(index + 1 >= items.count)
                    }

                    Picker("Action", selection: Binding(
                        get: { items[index].action },
                        set: { newAction in
                            items[index].action = newAction
                            if newAction == .reword && items[index].newMessage == nil {
                                items[index].newMessage = items[index].subject
                            }
                        }
                    )) {
                        ForEach(RebaseAction.allCases) { action in
                            Text(action.label).tag(action)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 96)

                    ShaChip(sha: item.shortSHA)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.subject.isEmpty ? "(no message)" : item.subject)
                            .font(Theme.Text.body)
                            .foregroundStyle(item.action == .drop ? Theme.inkMuted : Theme.ink)
                            .strikethrough(item.action == .drop)
                            .lineLimit(1)
                        Text(item.author)
                            .font(Theme.Text.caption)
                            .foregroundStyle(Theme.inkMuted)
                    }
                    Spacer()
                }

                if item.action == .reword {
                    TextField("New commit message", text: Binding(
                        get: { items[index].newMessage ?? items[index].subject },
                        set: { items[index].newMessage = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private func loadCommits() {
        guard let root = session.analysis?.root, !baseRef.isEmpty else { return }
        let selectedBase = baseRef
        loadingCommits = true
        loadError = nil
        Task.detached(priority: .userInitiated) {
            let result = Result {
                try GitRepository(url: root).commitsForInteractiveRebase(onto: selectedBase, limit: 50)
            }
            await MainActor.run {
                guard self.baseRef == selectedBase else { return }
                self.loadingCommits = false
                switch result {
                case .success(let loaded):
                    self.items = loaded
                case .failure(let error):
                    self.items = []
                    self.loadError = "\(error)"
                }
            }
        }
    }
}
