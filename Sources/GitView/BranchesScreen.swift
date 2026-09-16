import SwiftUI
import GitViewCore
import GitViewGit

struct BranchesScreen: View {
    @EnvironmentObject private var model: AnalysisModel
    @State private var showMerged = false
    @State private var query = ""

    var body: some View {
        if let analysis = model.analysis {
            let all = analysis.branches
            let merged = all.filter { $0.isMerged }
            let shown = all.filter { (showMerged || !$0.isMerged) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
            Page {
                ScreenHeader(title: "Branches", subtitle: "Branches in this repository, newest activity first.")
                HStack(spacing: Theme.Space.m) {
                    SearchField(text: $query, prompt: "Filter branches").frame(maxWidth: 300)
                    Spacer()
                    Text("\(shown.count) of \(all.count)").font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                }
                Card(padding: Theme.Space.s) {
                    VStack(spacing: 0) {
                        TableHeading(columns: [("Name", nil, .leading), ("Last commit", 260, .leading), ("Behind / Ahead", 110, .trailing), ("", 70, .trailing)])
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
                if model.advanced {
                    Text("Behind / ahead are counted against the default branch (\(analysis.info.defaultBranch)). "
                         + "Remote-tracking branches without a local copy are marked “remote”.")
                        .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                }
            }
        }
    }
}

struct BranchRow: View {
    let branch: BranchInfo
    var body: some View {
        HStack(spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
                Text(branch.name).font(branch.isDefault ? Theme.Text.bodyBold : Theme.Text.body).foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.middle)
                if branch.isDefault { Chip(text: "Default", tint: Theme.accent) }
                if branch.isCurrent && !branch.isDefault { Chip(text: "Current") }
                if branch.isRemote { Chip(text: "remote") }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(branch.subject).font(Theme.Text.body).foregroundStyle(Theme.inkSoft).lineLimit(1)
                Text("\(branch.author) · \(RiskExplanation.relative(branch.date, now: Date()))")
                    .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
            }
            .frame(width: 260, alignment: .leading)
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
            Text(branch.isMerged ? "merged" : "")
                .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Space.m).padding(.vertical, 9)
    }
}
