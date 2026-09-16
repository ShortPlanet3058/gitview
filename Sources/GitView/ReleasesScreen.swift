import SwiftUI
import AppKit
import GitViewCore
import GitViewGit

/// Releases and comparison, together — "what is in this version" and "what changed between
/// these two points" are the same question asked with different refs.
struct ReleasesScreen: View {
    @EnvironmentObject private var model: AnalysisModel
    @State private var query = ""
    @State private var limit = 60
    @State private var copied = false

    var body: some View {
        if let analysis = model.analysis {
            let distances = model.commitsBetweenTags()
            let tags = analysis.tags.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            Page {
                ScreenHeader(title: "Releases",
                             subtitle: "Tags in this repository, and what changed between any two points.")

                if analysis.tags.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            Text("No tags yet").font(Theme.Text.heading).foregroundStyle(Theme.ink)
                            Text("Nothing here is tagged, so there are no releases to compare. You can still "
                                 + "compare two branches or commits below.")
                                .font(Theme.Text.body).foregroundStyle(Theme.inkSoft)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else if let unreleased = model.unreleasedCount, let latest = analysis.tags.first {
                    unreleasedCard(count: unreleased, since: latest)
                }

                compareCard(analysis)

                if let comparison = model.comparison {
                    comparisonResult(comparison)
                }

                Card(padding: Theme.Space.s) {
                    VStack(spacing: 0) {
                        HStack {
                            Text("ALL TAGS").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.inkMuted)
                            Spacer()
                            SearchField(text: $query, prompt: "Find a tag").frame(width: 220)
                        }
                        .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
                        HairlineDivider()
                        ForEach(tags.prefix(limit)) { tag in
                            tagRow(tag, commits: distances[tag.name], allTags: analysis.tags)
                            if tag.id != tags.prefix(limit).last?.id { HairlineDivider() }
                        }
                        if tags.count > limit {
                            Button("Show \(min(60, tags.count - limit)) more") { limit += 60 }
                                .buttonStyle(SecondaryButtonStyle()).padding(Theme.Space.m)
                        }
                    }
                }
            }
        }
    }

    private func unreleasedCard(count: Int, since latest: TagInfo) -> some View {
        Card {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: count == 0 ? "checkmark.circle.fill" : "shippingbox.fill")
                    .font(.system(size: 18)).foregroundStyle(count == 0 ? Theme.good : Theme.accent)
                    .frame(width: 40, height: 40)
                    .background((count == 0 ? Theme.good : Theme.accent).opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(count == 0 ? "Everything is released"
                                    : "\(count) commit\(count == 1 ? "" : "s") since \(latest.name)")
                        .font(Theme.Text.heading).foregroundStyle(Theme.ink)
                    Text(count == 0 ? "\(latest.name) is the newest tag and matches the current branch."
                                    : "Tagged \(RiskExplanation.relative(latest.date, now: Date())). "
                                      + "Compare to see what a new release would contain.")
                        .font(Theme.Text.body).foregroundStyle(Theme.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if count > 0 {
                    Button("What's unreleased") {
                        model.compareFrom = latest.name
                        model.compareTo = "HEAD"
                        model.runComparison()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            }
        }
    }

    private func compareCard(_ analysis: RepositoryAnalysis) -> some View {
        let refs = ["HEAD"] + analysis.branches.prefix(30).map { $0.isRemote ? "origin/\($0.name)" : $0.name }
                            + analysis.tags.prefix(100).map(\.name)
        return Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                CardHeader(title: "Compare",
                           info: "Shows what is in the second reference but not the first — the same thing "
                               + "`git log from..to` lists. Works with any mixture of tags, branches and HEAD.")
                HStack(spacing: Theme.Space.s) {
                    Picker("", selection: $model.compareFrom) {
                        Text("Choose…").tag("")
                        ForEach(refs, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(maxWidth: .infinity)
                    Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
                    Picker("", selection: $model.compareTo) {
                        ForEach(refs, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(maxWidth: .infinity)
                    Button("Compare") { model.runComparison() }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(model.compareFrom.isEmpty || model.comparisonInFlight)
                }
                if model.comparisonInFlight {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Reading the range…").font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                    }
                }
            }
        }
    }

    private func comparisonResult(_ comparison: ComparisonResult) -> some View {
        let stat = comparison.stat
        let notes = ReleaseNotes.markdown(title: "\(comparison.from) → \(comparison.to)",
                                          commits: comparison.commits)
        return Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack {
                    CardHeader(title: "\(comparison.from) → \(comparison.to)")
                    Spacer()
                    Button(copied ? "Copied" : "Copy release notes") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(notes, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }

                if comparison.isEmpty {
                    Text("These two points are identical.").font(Theme.Text.body).foregroundStyle(Theme.inkMuted)
                } else {
                    HStack(spacing: Theme.Space.m) {
                        StatCard(icon: "clock.arrow.circlepath", tint: .blue,
                                 value: comparison.commits.count.formatted(), label: "Commits")
                        StatCard(icon: "person.2.fill", tint: .aqua,
                                 value: comparison.contributors.count.formatted(), label: "Contributors")
                        StatCard(icon: "doc.text.fill", tint: .orange,
                                 value: stat.filesChanged.formatted(), label: "Files changed")
                        StatCard(icon: "plusminus", tint: .violet,
                                 value: "+\(stat.insertions.formatted())", label: "Lines added",
                                 delta: "−\(stat.deletions.formatted()) removed")
                    }

                    HStack(alignment: .top, spacing: Theme.Space.l) {
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            Text("What changed").font(Theme.Text.heading).foregroundStyle(Theme.ink)
                            ForEach(ReleaseNotes.sections(for: comparison.commits).prefix(4)) { section in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(section.title).font(Theme.Text.bodyBold).foregroundStyle(Theme.accent)
                                    ForEach(section.entries.prefix(5)) { entry in
                                        Button { model.selectedCommitSHA = entry.sha } label: {
                                            Text("• \(entry.subject)")
                                                .font(Theme.Text.body).foregroundStyle(Theme.inkSoft)
                                                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    if section.entries.count > 5 {
                                        Text("  and \(section.entries.count - 5) more")
                                            .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            Text("Most changed files").font(Theme.Text.heading).foregroundStyle(Theme.ink)
                            ForEach(comparison.deltas.prefix(8)) { delta in
                                HStack(spacing: Theme.Space.s) {
                                    // Middle, not head: two modules can share a filename, and
                                    // head-truncation makes distinct paths look identical.
                                    Text(delta.path).font(Theme.Text.caption).foregroundStyle(Theme.inkSoft)
                                        .lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    if delta.isBinary {
                                        Text("binary").font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                                    } else {
                                        Text("+\(delta.insertions)").font(Theme.Text.caption.monospacedDigit())
                                            .foregroundStyle(Theme.good)
                                        Text("−\(delta.deletions)").font(Theme.Text.caption.monospacedDigit())
                                            .foregroundStyle(Theme.critical)
                                    }
                                }
                            }
                        }
                        .frame(width: 320, alignment: .leading)
                    }
                }
            }
        }
    }

    private func tagRow(_ tag: TagInfo, commits: Int?, allTags: [TagInfo]) -> some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "tag.fill").font(.system(size: 11)).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(tag.name).font(Theme.Text.bodyBold).foregroundStyle(Theme.ink)
                    if tag.isAnnotated { Chip(text: "annotated") }
                    if tag.name == allTags.first?.name { Chip(text: "latest", tint: Theme.accent) }
                }
                // A lightweight tag has no message of its own; this is the commit it names.
                Text(tag.subject).font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer()
            if let commits {
                Text("\(commits) commit\(commits == 1 ? "" : "s")")
                    .font(Theme.Text.caption.monospacedDigit()).foregroundStyle(Theme.inkSoft)
            }
            Text(tag.date.formatted(.dateTime.year().month(.abbreviated).day()))
                .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted).frame(width: 90, alignment: .trailing)
            Button("What's in it") {
                // The previous release is the next tag in a newest-first list.
                if let index = allTags.firstIndex(where: { $0.name == tag.name }), index + 1 < allTags.count {
                    model.compareFrom = allTags[index + 1].name
                } else {
                    model.compareFrom = ""
                }
                model.compareTo = tag.name
                if !model.compareFrom.isEmpty { model.runComparison() }
            }
            .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
        }
        .padding(.horizontal, Theme.Space.m).padding(.vertical, 8)
    }
}
