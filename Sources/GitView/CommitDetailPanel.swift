import SwiftUI
import GitViewCore

/// What one commit actually changed — including which functions it touched, which is the
/// thing GitView knows and a commit viewer normally cannot tell you.
struct CommitDetailPanel: View {
    @EnvironmentObject private var model: AnalysisModel
    let commit: Commit

    private var touched: [RiskRow] {
        guard let churn = model.churn else { return [] }
        return churn.units(touchedBy: commit.sha)
            .compactMap { model.rowsByID[$0] }
            .sorted { $0.score > $1.score }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollColumn {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    functionsCard
                    filesCard
                }
                .padding(Theme.Space.l)
            }
        }
        .background(Theme.surface)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                ShaChip(sha: commit.sha)
                Spacer()
                Button { model.selectedCommitSHA = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.inkMuted).padding(6).background(Theme.wash, in: Circle())
                }
                .buttonStyle(.plain)
            }
            Text(commit.subject.isEmpty ? "(no message)" : commit.subject)
                .font(Theme.Text.title).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            HStack(spacing: Theme.Space.s) {
                Avatar(name: commit.author, size: 22)
                Text(commit.author).font(Theme.Text.body).foregroundStyle(Theme.inkSoft)
                Text("· \(commit.date.formatted(.dateTime.year().month(.abbreviated).day().hour().minute()))")
                    .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
            }
            HStack(spacing: Theme.Space.s) {
                Button("Copy SHA") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(commit.sha, forType: .string)
                }
                .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                if let web = model.analysis?.info.remoteWebURL {
                    Button("View on \(web.host ?? "remote")") {
                        NSWorkspace.shared.open(web.appendingPathComponent("commit").appendingPathComponent(commit.sha))
                    }
                    .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                }
            }
        }
        .padding(Theme.Space.l).padding(.top, Theme.Space.xl)
        .background(Theme.raised)
        .overlay(alignment: .bottom) { HairlineDivider() }
    }

    @ViewBuilder
    private var functionsCard: some View {
        let rows = touched
        Card(padding: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                CardHeader(title: "Functions touched", subtitle: rows.isEmpty ? "none ranked" : "\(rows.count)",
                           info: "Functions whose current line range overlaps this commit's changed lines. "
                               + "Attribution is least reliable for old commits, because the file has moved "
                               + "underneath them since.")
                if rows.isEmpty {
                    Text(emptyReason).font(Theme.Text.body).foregroundStyle(Theme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    let attention = rows.filter { $0.level == .critical || $0.level == .high }
                    if !attention.isEmpty {
                        Text("\(attention.count) of them \(attention.count == 1 ? "is" : "are") a hotspot.")
                            .font(Theme.Text.caption).foregroundStyle(Theme.serious)
                    }
                    VStack(spacing: 2) {
                        ForEach(rows.prefix(25)) { row in
                            Button { model.selectedCommitSHA = nil; model.selectedUnitID = row.id } label: {
                                HStack(spacing: Theme.Space.s) {
                                    RiskBadge(level: row.level, compact: true)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(row.name).font(Theme.Text.body).foregroundStyle(Theme.ink)
                                            .lineLimit(1).truncationMode(.middle)
                                        Text(row.location).font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                                            .lineLimit(1).truncationMode(.head)
                                    }
                                    Spacer()
                                    Text("cx \(row.complexity)").font(Theme.Text.caption.monospacedDigit())
                                        .foregroundStyle(Theme.inkMuted)
                                }
                                .padding(.vertical, 4).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        if rows.count > 25 {
                            Text("and \(rows.count - 25) more…").font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                        }
                    }
                }
            }
        }
    }

    /// A commit can touch no ranked function for several honest reasons; say which.
    private var emptyReason: String {
        if commit.fileChanges.isEmpty {
            return "This commit has no diff of its own — it is a merge, and its changes are counted in the commits it brought in."
        }
        return "This commit changed files GitView does not rank: another language, tests, vendored code, or lines outside any function such as imports."
    }

    private var filesCard: some View {
        Card(padding: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                CardHeader(title: "Files changed", subtitle: "\(commit.fileChanges.count)")
                if commit.fileChanges.isEmpty {
                    Text("None recorded.").font(Theme.Text.body).foregroundStyle(Theme.inkMuted)
                } else {
                    VStack(spacing: 0) {
                        ForEach(commit.fileChanges.prefix(60), id: \.path) { change in
                            HStack(spacing: Theme.Space.s) {
                                Image(systemName: "doc.text").font(.system(size: 10)).foregroundStyle(Theme.inkMuted)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(change.path).font(Theme.Text.body).foregroundStyle(Theme.ink)
                                        .lineLimit(1).truncationMode(.head)
                                    if let oldPath = change.oldPath {
                                        Text("renamed from \(oldPath)").font(Theme.Text.caption)
                                            .foregroundStyle(Theme.inkMuted).lineLimit(1).truncationMode(.head)
                                    }
                                }
                                Spacer()
                                Text("\(change.hunks.count) hunk\(change.hunks.count == 1 ? "" : "s")")
                                    .font(Theme.Text.caption.monospacedDigit()).foregroundStyle(Theme.inkMuted)
                            }
                            .padding(.vertical, 5)
                            if change.path != commit.fileChanges.prefix(60).last?.path { HairlineDivider() }
                        }
                    }
                    if commit.fileChanges.count > 60 {
                        Text("and \(commit.fileChanges.count - 60) more…")
                            .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                    }
                }
            }
        }
    }
}
