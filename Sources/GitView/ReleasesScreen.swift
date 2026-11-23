import SwiftUI
import AppKit
import GitViewCore
import GitViewGit

/// Releases and comparison, together — "what is in this version" and "what changed between
/// these two points" are the same question asked with different refs.
struct ReleasesScreen: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(NavigationStore.self) private var navigation
    @Environment(WorkingCopyStore.self) private var workingCopy
    @Environment(\.staticRendering) private var staticRendering
    @State private var query = ""
    @State private var limit = 60
    @State private var copied = false
    @State private var showingNewTagPopover = false
    @State private var newTagName = ""
    @State private var newTagTarget = "HEAD"
    @State private var newTagMessage = ""

    var body: some View {
        if let analysis = session.analysis {
            let distances = session.commitsBetweenTags()
            let tags = analysis.tags.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            let defaultRemote: String? = analysis.info.remotes.keys.contains("origin")
                ? "origin"
                : analysis.info.remotes.keys.sorted().first
            Page {
                HStack(alignment: .top) {
                    ScreenHeader(title: "Releases",
                                 subtitle: "Tags in this repository, and what changed between any two points.")
                    Spacer()
                    Button {
                        newTagName = ""
                        newTagTarget = "HEAD"
                        newTagMessage = ""
                        showingNewTagPopover = true
                    } label: {
                        Label("New Tag…", systemImage: "tag")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(workingCopy.writeInFlight)
                    .popover(isPresented: $showingNewTagPopover, arrowEdge: .bottom) {
                        newTagPopover(analysis)
                    }
                }

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
                } else if let unreleased = session.unreleasedCount,
                          let latest = analysis.info.unreleased.flatMap({ info in
                              analysis.tags.first(where: { $0.name == info.latestTag })
                          }) ?? analysis.tags.first {
                    unreleasedCard(count: unreleased, since: latest, root: analysis.root)
                }

                compareCard(analysis)

                if let comparison = navigation.comparison {
                    comparisonResult(comparison, root: analysis.root)
                }

                Card(padding: Theme.Space.s) {
                    VStack(spacing: 0) {
                        HStack {
                            Text("ALL TAGS").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.inkMuted)
                            Spacer()
                            SearchField(text: $query, prompt: "Find a tag",
                                        focusTrigger: navigation.focusLocalFindRequest).frame(width: 220)
                        }
                        .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
                        HairlineDivider()
                        ForEach(tags.prefix(limit)) { tag in
                            tagRow(tag, commits: distances[tag.name], allTags: analysis.tags,
                                   root: analysis.root, defaultRemote: defaultRemote)
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

    private func newTagPopover(_ analysis: RepositoryAnalysis) -> some View {
        let trimmedName = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Create Tag").font(Theme.Text.heading).foregroundStyle(Theme.ink)
            VStack(alignment: .leading, spacing: 4) {
                Text("Tag name").font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                TextField("v1.0.0", text: $newTagName).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Target branch, tag, or commit").font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                TextField("HEAD", text: $newTagTarget).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Annotation message (optional)").font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                TextField("Leave blank for lightweight tag", text: $newTagMessage).textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("Cancel") { showingNewTagPopover = false }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Create Tag") {
                    workingCopy.createTag(
                        name: trimmedName,
                        target: newTagTarget,
                        message: newTagMessage
                    )
                    showingNewTagPopover = false
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(trimmedName.isEmpty || workingCopy.writeInFlight)
            }
        }
        .padding(Theme.Space.l)
        .frame(width: 320)
    }

    private func unreleasedCard(count: Int, since latest: TagInfo, root: URL) -> some View {
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
                        navigation.compareFrom = latest.name
                        navigation.compareTo = "HEAD"
                        navigation.runComparison(in: root)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            }
        }
    }

    private func compareCard(_ analysis: RepositoryAnalysis) -> some View {
        @Bindable var navigation = navigation
        var refs = ["HEAD"] + analysis.branches.prefix(30).map { $0.isRemote ? $0.checkoutTarget : $0.name }
                            + analysis.tags.prefix(100).map(\.name)
        for extra in [navigation.compareFrom, navigation.compareTo] where !extra.isEmpty && !refs.contains(extra) {
            refs.insert(extra, at: min(1, refs.count))
        }
        return Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                CardHeader(title: "Compare",
                           info: "Shows what is in the second reference but not the first — the same thing "
                               + "`git log from..to` lists. Works with any mixture of tags, branches and HEAD.")
                HStack(spacing: Theme.Space.s) {
                    if staticRendering {
                        staticRefPill(navigation.compareFrom.isEmpty ? "Choose…" : navigation.compareFrom)
                        Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
                        staticRefPill(navigation.compareTo)
                    } else {
                        Picker("", selection: $navigation.compareFrom) {
                            Text("Choose…").tag("")
                            ForEach(refs, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden().frame(maxWidth: .infinity)
                        Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
                        Picker("", selection: $navigation.compareTo) {
                            ForEach(refs, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden().frame(maxWidth: .infinity)
                    }
                    Button("Compare") { navigation.runComparison(in: analysis.root) }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(navigation.compareFrom.isEmpty || navigation.comparisonInFlight)
                }
                if navigation.comparisonInFlight {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Reading the range…").font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                    }
                }
            }
        }
    }

    private func staticRefPill(_ title: String) -> some View {
        HStack(spacing: 6) {
            Text(title).font(Theme.Text.body).foregroundStyle(Theme.ink).lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.inkMuted)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.hairline))
    }

    private func comparisonResult(_ comparison: ComparisonResult, root: URL) -> some View {
        let stat = comparison.stat
        let notes = ReleaseNotes.markdown(title: "\(comparison.from) → \(comparison.to)",
                                          commits: comparison.commits)
        return Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack {
                    CardHeader(title: "\(comparison.from) → \(comparison.to)")
                    Spacer()
                    if !comparison.isEmpty {
                        Button("Review all \(comparison.deltas.count) file\(comparison.deltas.count == 1 ? "" : "s")") {
                            navigation.openCompareWorkspace(
                                from: comparison.from,
                                to: comparison.to,
                                in: root
                            )
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .controlSize(.small)
                    }
                    Button(copied ? "Copied" : "Copy release notes") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(notes, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .controlSize(.small)
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
                                        Button { navigation.selectedCommitSHA = entry.sha } label: {
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
                                Button {
                                    navigation.openCompareWorkspace(
                                        from: comparison.from,
                                        to: comparison.to,
                                        initialFile: delta.path,
                                        in: root
                                    )
                                } label: {
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
                                .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(width: 320, alignment: .leading)
                    }
                }
            }
        }
    }

    private func tagRow(_ tag: TagInfo, commits: Int?, allTags: [TagInfo],
                        root: URL, defaultRemote: String?) -> some View {
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
                    navigation.compareFrom = allTags[index + 1].name
                } else {
                    navigation.compareFrom = ""
                }
                navigation.compareTo = tag.name
                if !navigation.compareFrom.isEmpty { navigation.runComparison(in: root) }
            }
            .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
            if let defaultRemote {
                Button("Push") {
                    workingCopy.pushTag(name: tag.name, remote: defaultRemote)
                }
                .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                .disabled(workingCopy.writeInFlight)
                .help("Push tag \(tag.name) to \(defaultRemote)")
            }
            Button {
                workingCopy.confirmDeleteTag(tag)
            } label: {
                Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(Theme.critical)
            }
            .buttonStyle(.plain)
            .disabled(workingCopy.writeInFlight)
            .help("Delete local tag \(tag.name)")
        }
        .padding(.horizontal, Theme.Space.m).padding(.vertical, 8)
        .contextMenu {
            if let defaultRemote {
                Button("Push Tag to \(defaultRemote)") {
                    workingCopy.pushTag(name: tag.name, remote: defaultRemote)
                }
            }
            Button("Copy Tag Name") { copyToPasteboard(tag.name) }
            Divider()
            Button("Delete Local Tag", role: .destructive) {
                workingCopy.confirmDeleteTag(tag)
            }
        }
    }
}
