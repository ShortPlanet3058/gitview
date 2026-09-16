import SwiftUI
import GitViewCore

struct OverviewScreen: View {
    @EnvironmentObject private var model: AnalysisModel

    private var attention: Int { (model.levelCounts[.critical] ?? 0) + (model.levelCounts[.high] ?? 0) }
    private var activeThisYear: Int { model.rows.filter { $0.recentCommits > 0 }.count }

    var body: some View {
        Page {
            if let analysis = model.analysis {
                ScreenHeader(title: analysis.root.lastPathComponent, subtitle: summary(analysis))

                HStack(spacing: Theme.Space.l) {
                    StatTile(value: model.rows.count.formatted(), label: "functions with history",
                             caption: "of \(analysis.allUnits.count.formatted()) found in the code")
                    StatTile(value: attention.formatted(), label: "need attention",
                             caption: "critical or high risk")
                    StatTile(value: activeThisYear.formatted(), label: "changed recently",
                             caption: "in \(model.recentWindowLabel)")
                }

                Card {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        CardHeader(title: "Health at a glance",
                                   info: "Every function is scored on how complex it is and how much it has "
                                       + "changed recently, then placed in a band relative to the rest of this "
                                       + "repository. Bands are comparative: the top few percent are “critical” "
                                       + "here even in a tidy project.")
                        LevelDistributionBar(counts: model.levelCounts)
                        Text(healthSentence)
                            .font(Theme.Text.body).foregroundStyle(Theme.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        CardHeader(title: "Top hotspots", subtitle: "click one for the full story",
                                   info: "The functions with the highest combination of complexity and recent "
                                       + "change. These are where a bug is most likely to be hiding, and where a "
                                       + "small refactor pays off most.")
                        VStack(spacing: Theme.Space.s) {
                            ForEach(model.rows.prefix(5)) { row in
                                HotspotCard(row: row, compact: true, selected: model.selectedUnitID == row.id) {
                                    model.selectedUnitID = row.id
                                }
                            }
                        }
                        if model.rows.count > 5 {
                            Button("See all \(model.rows.count.formatted()) →") { model.screen = .hotspots }
                                .buttonStyle(.plain).font(Theme.Text.body).foregroundStyle(Theme.accent)
                        }
                    }
                }

                HStack(alignment: .top, spacing: Theme.Space.l) {
                    Card {
                        VStack(alignment: .leading, spacing: Theme.Space.m) {
                            CardHeader(title: "Where risk lives",
                                       info: "Risk scores of elevated-or-higher functions, added up per folder. "
                                           + "A long bar means a part of the project that deserves more care, "
                                           + "review, or tests.")
                            if model.directoryRisk.isEmpty {
                                Text("Nothing above low risk.").font(Theme.Text.body).foregroundStyle(Theme.inkMuted)
                            } else {
                                let top = model.directoryRisk.first?.score ?? 1
                                VStack(spacing: Theme.Space.m) {
                                    ForEach(model.directoryRisk.prefix(6), id: \.directory) { entry in
                                        BarRow(label: entry.directory.isEmpty ? "(root)" : entry.directory,
                                               detail: "\(entry.units) functions",
                                               fraction: entry.score / max(top, 0.0001))
                                    }
                                }
                            }
                        }
                    }
                    Card {
                        VStack(alignment: .leading, spacing: Theme.Space.m) {
                            CardHeader(title: "Change together",
                                       info: "Pairs of functions that keep being edited in the same commits even "
                                           + "though they live in different folders. Changing one and forgetting "
                                           + "the other is a classic source of bugs.")
                            if model.couplingRows.isEmpty {
                                Text("No strong pairs across folders.").font(Theme.Text.body).foregroundStyle(Theme.inkMuted)
                            } else {
                                VStack(alignment: .leading, spacing: Theme.Space.m) {
                                    ForEach(model.couplingRows.prefix(3)) { pair in
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("\(pair.nameA)  ↔  \(pair.nameB)")
                                                .font(Theme.Text.bodyBold).foregroundStyle(Theme.ink)
                                                .lineLimit(1).truncationMode(.middle)
                                            Text(pair.sentence).font(Theme.Text.caption).foregroundStyle(Theme.inkSoft)
                                        }
                                    }
                                }
                                Button("See all pairs →") { model.screen = .coupling }
                                    .buttonStyle(.plain).font(Theme.Text.body).foregroundStyle(Theme.accent)
                            }
                        }
                    }
                }

                if model.advanced { AdvancedModelCard() }
            }
        }
    }

    private func summary(_ analysis: RepositoryAnalysis) -> String {
        var parts = ["\(analysis.commits.count.formatted()) commits", "\(analysis.authorCount.formatted()) people"]
        if let range = analysis.dateRange {
            let style = Date.FormatStyle().year().month(.abbreviated)
            parts.append("\(range.lowerBound.formatted(style)) – \(range.upperBound.formatted(style))")
        }
        return parts.joined(separator: " · ")
    }

    private var healthSentence: String {
        let critical = model.levelCounts[.critical] ?? 0
        let high = model.levelCounts[.high] ?? 0
        let total = model.rows.count
        guard total > 0 else { return "No functions with history to assess." }
        if critical + high == 0 { return "Nothing stands out right now — no function is both complex and changing much." }
        let share = Int((Double(critical + high) / Double(total) * 100).rounded())
        return "\(critical + high) of \(total) functions (\(share)%) combine high complexity with recent change. "
             + "Those are the ones to look at first."
    }
}

/// Expert controls: the half-life slider and what it trades off.
struct AdvancedModelCard: View {
    @EnvironmentObject private var model: AnalysisModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                CardHeader(title: "Risk model", subtitle: "score = log1p(complexity) × log1p(recency-weighted churn)")
                HStack {
                    Text("Half-life").font(Theme.Text.body).foregroundStyle(Theme.ink)
                    Spacer()
                    Text("\(Int(model.halfLifeDays)) days").font(Theme.Text.body.monospacedDigit()).foregroundStyle(Theme.inkSoft)
                }
                Slider(value: $model.halfLifeDays, in: 30...1095, step: 5)
                Text(halfLifeCaption).font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                if let analysis = model.analysis {
                    HairlineDivider()
                    HStack(spacing: Theme.Space.xl) {
                        Text(String(format: "history %.1fs · parse %.1fs", analysis.historyDuration, analysis.parseDuration))
                        Text("\(analysis.filesParsed) files parsed" + (analysis.filesFailed.isEmpty ? "" : ", \(analysis.filesFailed.count) failed"))
                        if let churn = model.churn {
                            let total = churn.matchedHunks + churn.unmatchedHunks
                            Text(String(format: "%.0f%% of Swift hunks landed inside a unit",
                                        total > 0 ? Double(churn.matchedHunks) / Double(total) * 100 : 0))
                        }
                    }
                    .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                }
            }
        }
    }

    private var halfLifeCaption: String {
        switch model.halfLifeDays {
        case ..<120: return "Short: attribution is most accurate, but function-level churn is sparse enough that change frequency barely registers."
        case ..<550: return "Balanced: keeps most of the attribution accuracy while change frequency still separates units. Measured sweet spot."
        default: return "Long: change frequency dominates, but older commits are attributed to lines that have since drifted, so accuracy drops."
        }
    }
}
