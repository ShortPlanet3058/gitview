import SwiftUI
import AppKit
import GitViewCore
import GitViewGit

/// Tabbed sheet for browsing/checking out open GitHub PRs or creating a new PR from the current branch.
struct PullRequestsSheet: View {
    enum Tab: String, CaseIterable, Identifiable {
        case open = "Open PRs"
        case create = "Create PR"
        var id: String { rawValue }
    }

    @Environment(WorkspaceSession.self) private var session
    @Environment(WorkingCopyStore.self) private var workingCopy
    @Environment(\.dismiss) private var dismiss

    @State private var tab: Tab = .open
    @State private var query = ""

    // Create PR fields
    @State private var prTitle = ""
    @State private var prBody = ""
    @State private var baseBranch = ""
    @State private var isDraft = false
    @State private var didPrefillCreate = false

    private var ghAvailable: Bool {
        GitHubBridge.ghExecutablePath() != nil
    }

    private var isGitHubRemote: Bool {
        session.analysis?.info.remoteWebURL?.host?.lowercased() == "github.com"
    }

    private var filteredPRs: [PullRequestSummary] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return session.openPullRequests }
        return session.openPullRequests.filter { pr in
            pr.title.localizedCaseInsensitiveContains(q)
                || pr.headRefName.localizedCaseInsensitiveContains(q)
                || "#\(pr.number)".contains(q)
                || (pr.authorLogin?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: "arrow.triangle.pull")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pull Requests")
                        .font(Theme.Text.title)
                        .foregroundStyle(Theme.ink)
                    if let name = session.analysis?.root.lastPathComponent {
                        Text(name)
                            .font(Theme.Text.caption)
                            .foregroundStyle(Theme.inkMuted)
                    }
                }
                Spacer()
                SegmentPicker(
                    options: [
                        (.open, "Open (\(session.openPullRequests.count))"),
                        (.create, "Create PR"),
                    ],
                    selection: $tab
                )
                Button {
                    session.refreshPullRequests()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(GhostIconButtonStyle())
                .help("Refresh open pull requests via gh")
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

            switch tab {
            case .open:
                openPRsBody
            case .create:
                createPRBody
            }
        }
        .frame(width: 760, height: 540)
        .background(Theme.page)
        .onAppear {
            prefillCreateFormIfNeeded()
            session.refreshPullRequests()
        }
    }

    @ViewBuilder
    private var openPRsBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                SearchField(text: $query, prompt: "Filter open pull requests…", focusTrigger: 0)
                Spacer()
                Text("\(filteredPRs.count) open")
                    .font(Theme.Text.caption)
                    .foregroundStyle(Theme.inkMuted)
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.m)

            HairlineDivider()

            if !isGitHubRemote {
                emptyState(
                    icon: "link",
                    title: "Not a GitHub remote",
                    detail: "Open pull requests are fetched when the origin remote points to github.com."
                )
            } else if !ghAvailable {
                emptyState(
                    icon: "terminal",
                    title: "GitHub CLI (gh) not found",
                    detail: "Install GitHub CLI (brew install gh) and run gh auth login to list and check out pull requests inside GitView."
                )
            } else if filteredPRs.isEmpty {
                emptyState(
                    icon: "tray",
                    title: query.isEmpty ? "No open pull requests" : "No pull requests match",
                    detail: query.isEmpty ? "All caught up for this repository." : "Try a different title, branch name, or PR number."
                )
            } else {
                ScrollColumn {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.s) {
                        ForEach(filteredPRs) { pr in
                            pullRequestCard(pr)
                        }
                    }
                    .padding(Theme.Space.l)
                }
            }
        }
    }

    private func pullRequestCard(_ pr: PullRequestSummary) -> some View {
        Card(padding: Theme.Space.m) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: Theme.Space.xs) {
                        checkStatusDot(pr.checkStatus)
                        Text("#\(pr.number)")
                            .font(Theme.Text.mono.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                        Text(pr.title)
                            .font(Theme.Text.bodyBold)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if pr.isDraft {
                            Chip(text: "Draft")
                        }
                        if let review = reviewChip(pr.reviewDecision) {
                            Chip(text: review.text, tint: review.tint)
                        }
                    }

                    HStack(spacing: Theme.Space.s) {
                        Text("\(pr.headRefName) → \(pr.baseRefName)")
                            .font(Theme.Text.mono)
                            .foregroundStyle(Theme.inkSoft)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let author = pr.authorLogin {
                            Text("· @\(author)")
                                .font(Theme.Text.caption)
                                .foregroundStyle(Theme.inkMuted)
                        }
                        if let updated = pr.updatedAt {
                            Text("· \(RiskExplanation.relative(updated, now: Date()))")
                                .font(Theme.Text.caption)
                                .foregroundStyle(Theme.inkMuted)
                        }
                        if let additions = pr.additions, let deletions = pr.deletions {
                            HStack(spacing: 4) {
                                Text("+\(additions)").foregroundStyle(Theme.good)
                                Text("−\(deletions)").foregroundStyle(Theme.critical)
                                if let files = pr.changedFiles {
                                    Text("· \(files)f").foregroundStyle(Theme.inkMuted)
                                }
                            }
                            .font(Theme.Text.caption.monospacedDigit())
                        }
                    }
                }

                Spacer(minLength: Theme.Space.s)

                HStack(spacing: Theme.Space.xs) {
                    Button("Checkout") {
                        workingCopy.checkoutPullRequest(number: pr.number) {
                            dismiss()
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .controlSize(.small)
                    .disabled(workingCopy.writeInFlight)

                    if let root = session.analysis?.root,
                       let compareTarget = resolvedCompareHeadRef(for: pr) {
                        Button("Compare") {
                            let base = resolvedCompareBaseRef(for: pr)
                            dismiss()
                            session.navigation.openCompareWorkspace(
                                from: base,
                                to: compareTarget,
                                in: root
                            )
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .controlSize(.small)
                    }

                    Button("Browser") {
                        NSWorkspace.shared.open(pr.url)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .controlSize(.small)
                }
            }
        }
    }

    private func resolvedCompareHeadRef(for pr: PullRequestSummary) -> String? {
        let branches = session.analysis?.branches ?? []
        if branches.contains(where: { !$0.isRemote && $0.name == pr.headRefName }) {
            return pr.headRefName
        }
        let remoteRef = "origin/\(pr.headRefName)"
        if branches.contains(where: { $0.isRemote && $0.name == pr.headRefName }) {
            return remoteRef
        }
        return nil
    }

    private func resolvedCompareBaseRef(for pr: PullRequestSummary) -> String {
        let branches = session.analysis?.branches ?? []
        if branches.contains(where: { !$0.isRemote && $0.name == pr.baseRefName }) {
            return pr.baseRefName
        }
        return "origin/\(pr.baseRefName)"
    }

    @ViewBuilder
    private func checkStatusDot(_ status: PullRequestSummary.CheckStatus) -> some View {
        switch status {
        case .passing:
            Circle().fill(Theme.good).frame(width: 7, height: 7)
                .help("Checks passing")
        case .failing:
            Circle().fill(Theme.critical).frame(width: 7, height: 7)
                .help("Checks failing")
        case .pending:
            Circle().fill(Theme.warning).frame(width: 7, height: 7)
                .help("Checks in progress")
        case .none:
            EmptyView()
        }
    }

    private func reviewChip(_ decision: String?) -> (text: String, tint: Color)? {
        switch decision {
        case "APPROVED":
            return ("Approved", Theme.good)
        case "CHANGES_REQUESTED":
            return ("Changes requested", Theme.critical)
        case "REVIEW_REQUIRED":
            return ("Review needed", Theme.warning)
        default:
            return nil
        }
    }

    @ViewBuilder
    private var createPRBody: some View {
        let info = session.analysis?.info
        let currentBranch = info?.currentBranch ?? "HEAD"
        let defaultBranch = info?.defaultBranch ?? "main"
        let localBranches = (session.analysis?.branches ?? []).filter { !$0.isRemote }.map(\.name)
        let targetOptions = localBranches.isEmpty ? [defaultBranch] : localBranches
        let onDefaultBranch = currentBranch == defaultBranch || currentBranch == "HEAD"

        ScrollColumn {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                if onDefaultBranch {
                    Card(padding: Theme.Space.m) {
                        HStack(spacing: Theme.Space.s) {
                            Image(systemName: "info.circle.fill").foregroundStyle(Theme.warning)
                            Text("You are currently on “\(currentBranch)”. Switch to a feature branch to open a pull request.")
                                .font(Theme.Text.body)
                                .foregroundStyle(Theme.inkSoft)
                        }
                    }
                }

                Card(padding: Theme.Space.l) {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        HStack(spacing: Theme.Space.m) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Source branch").font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                                Text(currentBranch).font(Theme.Text.mono.weight(.semibold)).foregroundStyle(Theme.ink)
                            }
                            Image(systemName: "arrow.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.inkMuted)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Base branch").font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                                Picker("Base branch", selection: $baseBranch) {
                                    ForEach(targetOptions, id: \.self) { name in
                                        Text(name).tag(name)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 200)
                            }
                            Spacer()
                            Toggle("Draft PR", isOn: $isDraft)
                                .toggleStyle(.switch)
                                .font(Theme.Text.body)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Title").font(Theme.Text.caption).foregroundStyle(Theme.inkSoft)
                            TextField("Pull request title", text: $prTitle)
                                .textFieldStyle(.roundedBorder)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Description").font(Theme.Text.caption).foregroundStyle(Theme.inkSoft)
                            TextEditor(text: $prBody)
                                .font(Theme.Text.body)
                                .frame(height: 150)
                                .scrollContentBackground(.hidden)
                                .padding(6)
                                .background(Theme.page, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                                    .strokeBorder(Theme.hairline))
                        }

                        HStack {
                            if let web = info?.remoteWebURL,
                               let createURL = GitHubBridge.createPRURL(
                                remoteWebURL: web,
                                branch: currentBranch,
                                defaultBranch: baseBranch.isEmpty ? defaultBranch : baseBranch
                               ) {
                                Button("Open on Web…") {
                                    NSWorkspace.shared.open(createURL)
                                }
                                .buttonStyle(SecondaryButtonStyle())
                            }
                            Spacer()
                            if ghAvailable && isGitHubRemote {
                                Button("Create Pull Request") {
                                    let targetBase = baseBranch.isEmpty ? defaultBranch : baseBranch
                                    workingCopy.createPullRequest(
                                        title: prTitle,
                                        body: prBody,
                                        base: targetBase,
                                        draft: isDraft
                                    ) { createdURL in
                                        if let createdURL {
                                            NSWorkspace.shared.open(createdURL)
                                        }
                                        dismiss()
                                    }
                                }
                                .buttonStyle(PrimaryButtonStyle())
                                .disabled(
                                    onDefaultBranch
                                    || prTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    || workingCopy.writeInFlight
                                )
                            }
                        }
                    }
                }
            }
            .padding(Theme.Space.l)
        }
    }

    private func prefillCreateFormIfNeeded() {
        guard !didPrefillCreate, let analysis = session.analysis else { return }
        didPrefillCreate = true
        baseBranch = analysis.info.defaultBranch
        if let headSubject = workingCopy.headCommitInfo?.subject, !headSubject.isEmpty {
            prTitle = headSubject
        } else {
            prTitle = analysis.info.currentBranch
        }
        if let plan = workingCopy.pushPlan, !plan.commits.isEmpty {
            prBody = plan.commits.map { "- \($0.subject)" }.joined(separator: "\n")
        }
    }

    private func emptyState(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: Theme.Space.s) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(Theme.inkMuted)
            Text(title)
                .font(Theme.Text.heading)
                .foregroundStyle(Theme.ink)
            Text(detail)
                .font(Theme.Text.body)
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
