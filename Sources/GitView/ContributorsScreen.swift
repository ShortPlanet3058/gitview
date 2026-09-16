import SwiftUI
import AppKit
import GitViewCore

struct ContributorsScreen: View {
    @EnvironmentObject private var model: AnalysisModel
    @State private var query = ""
    @State private var limit = 100

    var body: some View {
        let people = model.contributors.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        let top = people.map(\.share).max() ?? 1
        Page {
            HStack(alignment: .top) {
                ScreenHeader(title: "Contributors",
                             subtitle: "Who works on this, and who to ask about what.")
                Spacer()
                if model.advanced {
                    Button { exportCSV(people) } label: { Label("Export CSV", systemImage: "square.and.arrow.up") }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
            HStack {
                SearchField(text: $query, prompt: "Find a contributor").frame(maxWidth: 300)
                Spacer()
                Text("\(people.count) people").font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
            }
            if let ownership = model.ownership {
                KnowledgeRiskCard(index: ownership)
            }

            Card(padding: Theme.Space.s) {
                VStack(spacing: 0) {
                    TableHeading(columns: [("Name", nil, .leading), ("Commits", 80, .trailing), ("Share", 170, .leading),
                                           ("First commit", 110, .leading), ("Last commit", 110, .leading)])
                    HairlineDivider()
                    ForEach(people.prefix(limit)) { person in
                        Button { model.selectedAuthor = person.name } label: {
                        HStack(spacing: Theme.Space.m) {
                            HStack(spacing: Theme.Space.s) {
                                Avatar(name: person.name, size: 26)
                                Text(person.name).font(Theme.Text.body).foregroundStyle(Theme.ink).lineLimit(1)
                                if person.isBot { Chip(text: "bot") }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(person.commits.formatted()).font(Theme.Text.body.monospacedDigit()).foregroundStyle(Theme.ink)
                                .frame(width: 80, alignment: .trailing)
                            HStack(spacing: 8) {
                                InlineBar(fraction: person.share / top).frame(width: 110)
                                Text(person.share.sharePercent).font(Theme.Text.caption.monospacedDigit()).foregroundStyle(Theme.inkSoft)
                                    .frame(width: 34, alignment: .trailing)
                            }
                            .frame(width: 170, alignment: .leading)
                            Text(person.firstCommit.formatted(.dateTime.year().month(.abbreviated).day()))
                                .font(Theme.Text.caption).foregroundStyle(Theme.inkSoft).frame(width: 110, alignment: .leading)
                            Text(RiskExplanation.relative(person.lastCommit, now: Date()))
                                .font(Theme.Text.caption).foregroundStyle(Theme.inkSoft).frame(width: 110, alignment: .leading)
                        }
                        .padding(.horizontal, Theme.Space.m).padding(.vertical, 8)
                        .background(model.selectedAuthor == person.name ? Theme.accentWash : .clear)
                        .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if person.id != people.prefix(limit).last?.id { HairlineDivider() }
                    }
                    if people.count > limit {
                        HStack { Spacer(); Button("Show \(min(100, people.count - limit)) more") { limit += 100 }.buttonStyle(SecondaryButtonStyle()); Spacer() }
                            .padding(Theme.Space.m)
                    }
                }
            }
            if model.advanced {
                Text("Names are resolved through the repository's .mailmap, so a person who has committed under "
                     + "several spellings appears once. Automation is marked “bot” and is left out of the health "
                     + "check that counts active people.")
                    .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
            }
        }
    }

    private func exportCSV(_ people: [Contributor]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "contributors.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let formatter = ISO8601DateFormatter()
        var csv = "name,commits,share,first_commit,last_commit\n"
        for p in people {
            let name = "\"" + p.name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            csv += "\(name),\(p.commits),\(String(format: "%.4f", p.share)),\(formatter.string(from: p.firstCommit)),\(formatter.string(from: p.lastCommit))\n"
        }
        try? csv.write(to: url, atomically: true, encoding: .utf8)
    }
}
