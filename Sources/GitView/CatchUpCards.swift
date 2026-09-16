import SwiftUI
import GitViewCore
import GitViewGit

/// "What happened since I last looked" — the question GitHub cannot answer, because it
/// does not know when you last looked. GitView records the tip you saw, per repository.
struct CatchUpCard: View {
    @EnvironmentObject private var model: AnalysisModel
    let catchUp: CatchUp

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(catchUp.headline(now: Date()))
                            .font(Theme.Text.title).foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        if !catchUp.isEmpty {
                            Text(subtitle).font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                        }
                    }
                    Spacer()
                    if !catchUp.isEmpty {
                        Button("Mark as seen") { model.markCatchUpSeen() }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }

                if catchUp.isEmpty {
                    Text("You are up to date with everything committed here.")
                        .font(Theme.Text.body).foregroundStyle(Theme.inkSoft)
                } else {
                    if !catchUp.touchingYourCode.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "person.crop.circle.badge.exclamationmark")
                                .font(.system(size: 12)).foregroundStyle(Theme.serious)
                            Text("\(catchUp.touchingYourCode.count) of them touched files you have worked on")
                                .font(Theme.Text.body).foregroundStyle(Theme.ink)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Theme.serious.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    }

                    VStack(spacing: 0) {
                        ForEach(catchUp.commits.prefix(6), id: \.sha) { commit in
                            Button { model.selectedCommitSHA = commit.sha } label: {
                                HStack(spacing: Theme.Space.s) {
                                    Avatar(name: commit.author, size: 24)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(commit.subject.isEmpty ? "(no message)" : commit.subject)
                                            .font(Theme.Text.body).foregroundStyle(Theme.ink).lineLimit(1)
                                        Text("\(commit.author) · \(RiskExplanation.relative(commit.date, now: Date()))")
                                            .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                                    }
                                    Spacer()
                                    if catchUp.touchingYourCode.contains(where: { $0.sha == commit.sha }) {
                                        Text("your code").font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(Theme.serious)
                                    }
                                    ShaChip(sha: commit.sha)
                                }
                                .padding(.vertical, 5).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if !catchUp.busiestPaths.isEmpty {
                        HairlineDivider()
                        Text("Most changed: " + catchUp.busiestPaths.prefix(3)
                                .map { "\($0.path.split(separator: "/").last ?? "") ×\($0.changes)" }
                                .joined(separator: ", "))
                            .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                            .lineLimit(1)
                    }
                    LinkButton(title: "See all commits →") { model.screen = .commits }
                }
            }
        }
    }

    private var subtitle: String {
        var parts = ["\(catchUp.authorCount) \(catchUp.authorCount == 1 ? "person" : "people")",
                     "\(catchUp.fileCount) \(catchUp.fileCount == 1 ? "file" : "files")"]
        if !catchUp.yours.isEmpty { parts.append("\(catchUp.yours.count) yours") }
        return parts.joined(separator: " · ")
    }
}

/// `git status` without typing it: what is uncommitted, unpushed, or stashed and forgotten.
struct WorkingStateCard: View {
    @EnvironmentObject private var model: AnalysisModel
    let state: WorkingState

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack {
                    CardHeader(title: "Your working copy")
                    Spacer()
                    Button {
                        model.refreshWorkingState()
                    } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.inkMuted)
                    }
                    .buttonStyle(.plain).help("Re-read git status")
                }

                if let operation = state.operation {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12)).foregroundStyle(Theme.warning)
                        Text(operation.label).font(Theme.Text.bodyBold).foregroundStyle(Theme.ink)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.warning.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                }

                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
                    Text(state.branch ?? "detached HEAD")
                        .font(Theme.Text.bodyBold).foregroundStyle(Theme.ink).lineLimit(1)
                    if state.upstream == nil && state.branch != nil {
                        Chip(text: "no upstream", tint: Theme.warning)
                    }
                    Spacer()
                    if state.ahead > 0 || state.behind > 0 {
                        Text("\(state.behind) behind · \(state.ahead) ahead")
                            .font(Theme.Text.caption.monospacedDigit()).foregroundStyle(Theme.inkSoft)
                    }
                }

                if !state.hasLocalWork {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.good)
                        Text("Nothing uncommitted, nothing unpushed.")
                            .font(Theme.Text.body).foregroundStyle(Theme.inkSoft)
                    }
                } else {
                    VStack(spacing: 4) {
                        if state.hasUnpushedCommits {
                            row("arrow.up.circle.fill", Theme.serious,
                                "\(state.ahead) commit\(state.ahead == 1 ? "" : "s") not pushed",
                                "only on this machine")
                        }
                        if !state.conflicted.isEmpty {
                            row("exclamationmark.octagon.fill", Theme.critical,
                                "\(state.conflicted.count) conflicted", "needs resolving")
                        }
                        if !state.staged.isEmpty {
                            row("plus.circle.fill", Theme.good, "\(state.staged.count) staged", "ready to commit")
                        }
                        if !state.unstaged.isEmpty {
                            row("pencil.circle.fill", Theme.warning, "\(state.unstaged.count) modified", "not staged")
                        }
                        if !state.untracked.isEmpty {
                            row("questionmark.circle.fill", Theme.inkMuted,
                                "\(state.untracked.count) untracked", "not in git")
                        }
                        if !state.stashes.isEmpty {
                            row("tray.full.fill", Theme.inkMuted,
                                "\(state.stashes.count) stash\(state.stashes.count == 1 ? "" : "es")",
                                state.stashes.first.map { RiskExplanation.relative($0.date, now: Date()) } ?? "")
                        }
                    }
                    if !changed.isEmpty {
                        HairlineDivider()
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(changed.prefix(4)) { file in
                                Button {
                                    // Staged changes and working-tree edits are different
                                    // diffs; show whichever this file actually has.
                                    model.showDiff(.workingTree(staged: file.unstaged == .unchanged),
                                                   path: file.path,
                                                   title: file.unstaged == .unchanged ? "Staged changes"
                                                                                      : "Uncommitted changes")
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(file.path).font(Theme.Text.caption).foregroundStyle(Theme.inkSoft)
                                            .lineLimit(1).truncationMode(.head)
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                                            .foregroundStyle(Theme.inkMuted)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            if changed.count > 4 {
                                Text("and \(changed.count - 4) more…")
                                    .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                            }
                        }
                    }
                }
            }
        }
    }

    private var changed: [WorkingState.FileStatus] {
        state.files.filter { !$0.isUntracked }
    }

    private func row(_ symbol: String, _ tint: Color, _ title: String, _ detail: String) -> some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(tint).frame(width: 16)
            Text(title).font(Theme.Text.body).foregroundStyle(Theme.ink)
            Spacer()
            Text(detail).font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
        }
    }
}
