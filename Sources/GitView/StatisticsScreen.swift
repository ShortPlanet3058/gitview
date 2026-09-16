import SwiftUI
import GitViewCore

/// Advanced only: how the analysis ran and what the model is doing.
struct StatisticsScreen: View {
    @EnvironmentObject private var model: AnalysisModel

    var body: some View {
        if let analysis = model.analysis {
            Page {
                ScreenHeader(title: "Statistics", subtitle: "How this analysis was produced, and the model behind the risk scores.")
                HStack(spacing: Theme.Space.m) {
                    StatCard(icon: "timer", tint: .blue, value: String(format: "%.1fs", analysis.historyDuration + analysis.parseDuration),
                             label: "Analysis time", delta: String(format: "history %.1fs · parse & facts %.1fs", analysis.historyDuration, analysis.parseDuration))
                    StatCard(icon: "doc.text.magnifyingglass", tint: .aqua, value: analysis.filesParsed.formatted(), label: "Files parsed",
                             delta: analysis.generatedFiles.isEmpty
                                ? (analysis.filesFailed.isEmpty ? "none failed" : "\(analysis.filesFailed.count) failed")
                                : "\(analysis.generatedFiles.count) vendored or generated")
                    StatCard(icon: "function", tint: .violet, value: analysis.allUnits.count.formatted(), label: "Functions found",
                             delta: "\(model.rows.count.formatted()) ranked with the current filters")
                    StatCard(icon: "arrow.left.arrow.right", tint: .orange,
                             value: "\(Int((analysis.attribution.matchRate * 100).rounded()))%",
                             label: "Hunks inside a function",
                             delta: "\(analysis.attribution.hunksInParsedFiles.formatted()) hunks in parsed files")
                }
                HStack(alignment: .top, spacing: Theme.Space.l) {
                    Card {
                        VStack(alignment: .leading, spacing: Theme.Space.m) {
                            CardHeader(title: "Risk model", subtitle: "half-life \(Int(model.halfLifeDays)) days")
                            Text("score = log1p(complexity) × log1p(Σ 0.5^(age / half-life))")
                                .font(Theme.Text.mono).foregroundStyle(Theme.inkSoft)
                            Text("Complexity counts branch points in the function (if, guard, loops, switch cases, catch, "
                                 + "ternary, &&, ||, ??). Each commit that touched the function adds a weight that halves every "
                                 + "half-life. Both factors are log-damped so one giant switch cannot flatten the ranking.")
                                .font(Theme.Text.body).foregroundStyle(Theme.inkSoft).fixedSize(horizontal: false, vertical: true)
                            LevelDistributionBar(counts: model.levelCounts)
                            Text("Bands are relative to this repository: top 2% critical, next 8% high, next 20% elevated, "
                                 + "with an activity floor so a quiet repository does not always show a critical function.")
                                .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted).fixedSize(horizontal: false, vertical: true)
                            if model.excludedUnitCount > 0 {
                                Text("\(model.excludedUnitCount.formatted()) units are excluded by the current filters "
                                     + "(tests, vendored and generated code, ignored paths).")
                                    .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Button("Change parameters…") { model.showSettings = true }.buttonStyle(SecondaryButtonStyle())
                        }
                    }
                    .frame(maxWidth: .infinity)
                    Card {
                        VStack(alignment: .leading, spacing: Theme.Space.m) {
                            CardHeader(title: "Known imprecision", subtitle: "measured, not assumed")
                            Text("Function line ranges come from today's checkout, while a commit's hunks refer to the file as "
                                 + "it was then. Files drift, so old commits can be attributed to the wrong function.")
                                .font(Theme.Text.body).foregroundStyle(Theme.inkSoft).fixedSize(horizontal: false, vertical: true)
                            VStack(spacing: 0) {
                                precisionRow("Commits under 2 years old", "≈ 88–100% correct")
                                HairlineDivider()
                                precisionRow("2–5 years old", "≈ 57%")
                                HairlineDivider()
                                precisionRow("Over 5 years old", "≈ 42%")
                                HairlineDivider()
                                precisionRow("Recency-weighted (365-day half-life)", "≈ 78%")
                            }
                            Text("This repository: \(Int((analysis.attribution.matchRate * 100).rounded()))% of hunks in "
                                 + "parsed files landed inside a function — the rest are imports, blank lines and drift. Measured "
                                 + "against git log -L on 1,286 attributions in swift-nio. The half-life is what keeps "
                                 + "the score trustworthy: old, unreliable attributions carry almost no weight. A function's "
                                 + "detail panel marks the commits where it did not exist yet.")
                                .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                if let coupling = model.coupling {
                    Card {
                        VStack(alignment: .leading, spacing: Theme.Space.m) {
                            CardHeader(title: "Change together", subtitle: "\(coupling.pairs.count.formatted()) pairs with ≥ \(model.minSharedCommits) shared commits")
                            HStack(spacing: Theme.Space.xl) {
                                metric("Commits that paired functions", coupling.pairingCommits.formatted())
                                metric("Skipped as sweeps (> 50 functions)", coupling.skippedCommits.formatted())
                                metric("Across folders", model.couplingRows.filter(\.crossDirectory).count.formatted())
                            }
                            Text("A pair needs two correct line attributions, so pairs are weighted by recency as well; "
                                 + "repository-wide sweeps (formatting, renames) are not counted as coupling.")
                                .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func precisionRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(Theme.Text.body).foregroundStyle(Theme.ink)
            Spacer()
            Text(value).font(Theme.Text.body.monospacedDigit()).foregroundStyle(Theme.inkSoft)
        }
        .padding(.vertical, 6)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(Theme.Text.hero).foregroundStyle(Theme.ink)
            Text(label).font(Theme.Text.caption).foregroundStyle(Theme.inkSoft)
        }
    }
}
