import SwiftUI
import GitViewCore
import GitViewGit

/// "Who do I ask about this?" for a file or a folder.
struct OwnershipSection: View {
    @EnvironmentObject private var model: AnalysisModel
    /// Nil for a directory, which has no line-level blame.
    let filePath: String?
    let ownership: FileOwnership?
    let directory: DirectoryOwnership?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            CardHeader(title: "Who to ask",
                       info: "Ranked by how many commits each person has made to this, and how recently. "
                           + "For a single file you can also compute line-level ownership, which asks a "
                           + "different question: not who has changed it most, but who wrote the code that "
                           + "is there now.")
            if let ownership {
                Text(ownership.recommendation(now: Date()))
                    .font(Theme.Text.body).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                shares(ownership.authors, total: ownership.totalCommits, unit: "changes")
                if ownership.isSoleAuthor {
                    HStack(spacing: 6) {
                        Image(systemName: "person.fill.questionmark")
                            .font(.system(size: 11)).foregroundStyle(Theme.warning)
                        Text("Nobody else has ever changed this file.")
                            .font(Theme.Text.caption).foregroundStyle(Theme.inkSoft)
                    }
                }
                if let filePath { blameSection(filePath) }
            } else if let directory, let primary = directory.primary {
                Text("Ask \(primary.name) — \(primary.commits) of \(directory.totalCommits) changes "
                     + "across \(directory.fileCount) \(directory.fileCount == 1 ? "file" : "files").")
                    .font(Theme.Text.body).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                shares(directory.authors, total: directory.totalCommits, unit: "changes")
            } else {
                Text("No recorded history.").font(Theme.Text.body).foregroundStyle(Theme.inkMuted)
            }
        }
    }

    private func shares(_ authors: [AuthorShare], total: Int, unit: String) -> some View {
        VStack(spacing: 5) {
            ForEach(authors.prefix(5)) { author in
                HStack(spacing: Theme.Space.s) {
                    Avatar(name: author.name, size: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(author.name).font(Theme.Text.body).foregroundStyle(Theme.ink).lineLimit(1)
                        Text("\(author.commits) \(unit) · \(RiskExplanation.relative(author.lastTouched, now: Date()))")
                            .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted).lineLimit(1)
                    }
                    Spacer()
                    InlineBar(fraction: author.share).frame(width: 54)
                    Text(author.share.sharePercent)
                        .font(Theme.Text.caption.monospacedDigit()).foregroundStyle(Theme.inkSoft)
                        .frame(width: 34, alignment: .trailing)
                }
            }
            if authors.count > 5 {
                Text("and \(authors.count - 5) more")
                    .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func blameSection(_ path: String) -> some View {
        HairlineDivider()
        if let blame = model.blame[path] {
            VStack(alignment: .leading, spacing: 5) {
                Text("Who wrote the \(blame.totalLines.formatted()) lines that are there now")
                    .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                ForEach(blame.authors.prefix(4)) { author in
                    HStack(spacing: Theme.Space.s) {
                        Circle().fill(Theme.accent.opacity(0.7)).frame(width: 7, height: 7)
                        Text(author.name).font(Theme.Text.body).foregroundStyle(Theme.ink).lineLimit(1)
                        Spacer()
                        Text("\(author.lines.formatted()) lines")
                            .font(Theme.Text.caption.monospacedDigit()).foregroundStyle(Theme.inkMuted)
                        Text(author.share.sharePercent)
                            .font(Theme.Text.caption.monospacedDigit()).foregroundStyle(Theme.inkSoft)
                            .frame(width: 34, alignment: .trailing)
                    }
                }
            }
        } else if model.blameInFlight.contains(path) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Reading blame…").font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
            }
        } else {
            Button("Who wrote the current lines?") { model.loadBlame(for: path) }
                .buttonStyle(SecondaryButtonStyle())
        }
    }
}

/// Files only one person has ever touched, where that person has gone quiet.
struct KnowledgeRiskCard: View {
    @EnvironmentObject private var model: AnalysisModel
    let index: OwnershipIndex

    var body: some View {
        let risks = index.knowledgeRisks(inactiveFor: 180, now: Date(), limit: 40)
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                CardHeader(title: "Knowledge risk",
                           subtitle: "\(index.soleAuthorFileCount.formatted()) files have a single author",
                           info: "Files exactly one person has ever changed, where that person has not "
                               + "committed anywhere in this repository for six months. A file only one "
                               + "person knows is fine while they are around; this is the list for when "
                               + "they are not.")
                if risks.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.good)
                        Text("Everyone who is the only author of a file is still active here.")
                            .font(Theme.Text.body).foregroundStyle(Theme.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("\(risks.count) \(risks.count == 1 ? "file is" : "files are") known only to someone "
                         + "who has not committed in six months.")
                        .font(Theme.Text.body).foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: 0) {
                        ForEach(risks.prefix(6)) { file in
                            HStack(spacing: Theme.Space.s) {
                                Avatar(name: file.primary?.name ?? "?", size: 20)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(file.path).font(Theme.Text.body).foregroundStyle(Theme.ink)
                                        .lineLimit(1).truncationMode(.head)
                                    Text("\(file.primary?.name ?? "") · last \(RiskExplanation.relative(file.lastChange, now: Date()))")
                                        .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted).lineLimit(1)
                                }
                                Spacer()
                                Text("\(file.totalCommits)")
                                    .font(Theme.Text.caption.monospacedDigit()).foregroundStyle(Theme.inkMuted)
                            }
                            .padding(.vertical, 5)
                            if file.id != risks.prefix(6).last?.id { HairlineDivider() }
                        }
                    }
                    if risks.count > 6 {
                        Text("and \(risks.count - 6) more").font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                    }
                }
            }
        }
    }
}

/// What one person knows and has been doing.
struct AuthorDetailPanel: View {
    @EnvironmentObject private var model: AnalysisModel
    let author: String

    private var contributor: Contributor? { model.contributors.first { $0.name == author } }
    private var owned: [FileOwnership] { model.ownership?.filesOwned(by: author) ?? [] }
    private var recent: [Commit] {
        (model.analysis?.commits ?? []).filter { $0.author == author }.prefix(12).map { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollColumn {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    ownsCard
                    recentCard
                }
                .padding(Theme.Space.l)
            }
        }
        .background(Theme.surface)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Avatar(name: author, size: 40)
                Spacer()
                Button { model.selectedAuthor = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.inkMuted).padding(6).background(Theme.wash, in: Circle())
                }
                .buttonStyle(.plain)
            }
            Text(author).font(Theme.Text.title).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let contributor {
                Text("\(contributor.commits.formatted()) commits · \(contributor.share.sharePercent) of all work")
                    .font(Theme.Text.body).foregroundStyle(Theme.inkSoft)
                Text("Active \(RiskExplanation.relative(contributor.firstCommit, now: Date())) "
                     + "to \(RiskExplanation.relative(contributor.lastCommit, now: Date()))")
                    .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
            }
        }
        .padding(Theme.Space.l).padding(.top, Theme.Space.xl)
        .background(Theme.raised)
        .overlay(alignment: .bottom) { HairlineDivider() }
    }

    private var ownsCard: some View {
        Card(padding: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                CardHeader(title: "Knows best", subtitle: "\(owned.count) files",
                           info: "Files where this person has made more changes than anyone else — what to "
                               + "ask them about, and what would be hardest to replace if they left.")
                if owned.isEmpty {
                    Text("Not the main author of any file that still exists.")
                        .font(Theme.Text.body).foregroundStyle(Theme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 0) {
                        ForEach(owned.prefix(15)) { file in
                            HStack(spacing: Theme.Space.s) {
                                Text(file.path).font(Theme.Text.body).foregroundStyle(Theme.ink)
                                    .lineLimit(1).truncationMode(.head)
                                if file.isSoleAuthor { Chip(text: "only author", tint: Theme.warning) }
                                Spacer()
                                Text("\(file.primary?.commits ?? 0)/\(file.totalCommits)")
                                    .font(Theme.Text.caption.monospacedDigit()).foregroundStyle(Theme.inkMuted)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    if owned.count > 15 {
                        Text("and \(owned.count - 15) more").font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                    }
                }
            }
        }
    }

    private var recentCard: some View {
        Card(padding: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                CardHeader(title: "Recent work")
                VStack(spacing: 0) {
                    ForEach(recent, id: \.sha) { commit in
                        Button { model.selectedAuthor = nil; model.selectedCommitSHA = commit.sha } label: {
                            HStack(spacing: Theme.Space.s) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(commit.subject.isEmpty ? "(no message)" : commit.subject)
                                        .font(Theme.Text.body).foregroundStyle(Theme.ink).lineLimit(1)
                                    Text(RiskExplanation.relative(commit.date, now: Date()))
                                        .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                                }
                                Spacer()
                                ShaChip(sha: commit.sha)
                            }
                            .padding(.vertical, 4).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
