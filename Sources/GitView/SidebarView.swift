import SwiftUI
import GitViewCore

struct SidebarView: View {
    @EnvironmentObject private var model: AnalysisModel

    var body: some View {
        List {
            Section("Repository") {
                if let analysis = model.analysis {
                    LabeledContent("Name", value: analysis.root.lastPathComponent)
                    LabeledContent("Commits", value: analysis.commits.count.formatted())
                    LabeledContent("Authors", value: analysis.authorCount.formatted())
                    LabeledContent("Units", value: analysis.allUnits.count.formatted())
                    if let range = analysis.dateRange {
                        LabeledContent("History") {
                            Text(historyLabel(range))
                        }
                    }
                    if !analysis.filesFailed.isEmpty {
                        LabeledContent("Unparsed") {
                            Text("\(analysis.filesFailed.count) files")
                                .foregroundStyle(.orange)
                        }
                        .help(analysis.filesFailed.prefix(10).joined(separator: "\n"))
                    }
                } else {
                    Text("None open").foregroundStyle(.secondary)
                }
                Button("Choose Repository…") { chooseRepository(into: model) }
                    .disabled(model.isLoading)
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Half-life")
                        Spacer()
                        Text("\(Int(model.halfLifeDays)) days")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $model.halfLifeDays, in: 30...1095, step: 5)
                    Text(halfLifeCaption)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(nil)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Risk Model")
            } footer: {
                Text("A commit one half-life old counts half as much as one made today.")
                    .font(.caption2)
            }

            Section("Filters") {
                // Only shown once a repository is loaded — filtering nothing is meaningless.
                //
                // KNOWN WARNING: with any TextField in the window alongside the Table, AppKit
                // logs "reentrant operation in its NSTableView delegate" twice at load when
                // launched as a bundle (`open GitView.app`). Measured across placements:
                // `.searchable`, a toolbar TextField, and a sidebar TextField all trigger it;
                // the same code with no TextField logs nothing, so the trigger is the
                // framework's focus handling, not our state updates. Raw-binary launches of
                // this gated version log nothing. Behaviour is unaffected; revisit if the
                // warning becomes the assert AppKit threatens.
                if model.analysis != nil {
                    TextField("Filter by name or path", text: $model.searchText)
                        .textFieldStyle(.roundedBorder)
                }
                Toggle("Exclude tests", isOn: $model.excludeTests)
                Picker("Kind", selection: $model.kindFilter) {
                    ForEach(AnalysisModel.KindFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                Stepper("Min commits: \(model.minimumCommits)",
                        value: $model.minimumCommits, in: 1...25)
            }

            if model.analysis != nil {
                Section("Showing") {
                    LabeledContent("Ranked", value: model.totalRanked.formatted())
                    if model.matchedCount != model.totalRanked {
                        LabeledContent("Matching search", value: model.matchedCount.formatted())
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func historyLabel(_ range: ClosedRange<Date>) -> String {
        let style = Date.FormatStyle().year().month(.abbreviated)
        return "\(range.lowerBound.formatted(style)) – \(range.upperBound.formatted(style))"
    }

    /// Surfaces the step 4 finding at the point where the user can act on it, rather than
    /// leaving them to discover that a short half-life quietly deletes the churn signal.
    private var halfLifeCaption: String {
        switch model.halfLifeDays {
        case ..<120:
            return "Short: attribution is most accurate here, but function-level churn is "
                 + "sparse enough that change frequency barely registers."
        case ..<550:
            return "Balanced: keeps most of the attribution accuracy while change frequency "
                 + "still separates units."
        default:
            return "Long: change frequency dominates, but older commits are attributed to "
                 + "lines that have since drifted, so accuracy drops."
        }
    }
}
