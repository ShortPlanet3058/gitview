import SwiftUI
import GitViewCore

struct CouplingScreen: View {
    @Environment(AppPreferences.self) private var preferences
    @Environment(RiskStore.self) private var risk
    @Environment(NavigationStore.self) private var navigation

    var body: some View {
        @Bindable var risk = risk
        @Bindable var preferences = preferences
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                ScreenHeader(title: "Change together",
                             subtitle: "Functions that keep being edited in the same commits. When they live in "
                                     + "different folders, changing one and forgetting the other is a classic bug.")
                HStack(spacing: Theme.Space.m) {
                    SegmentPicker(options: RiskStore.CouplingViewMode.allCases.map { ($0, $0.rawValue) },
                                  selection: $risk.couplingViewMode)
                    SegmentPicker(options: RiskStore.CouplingScope.allCases.map { ($0, $0.rawValue) },
                                  selection: $risk.couplingScope)
                    if preferences.advanced {
                        Stepper("At least \(preferences.minSharedCommits) shared commits", value: $preferences.minSharedCommits, in: 2...20)
                            .font(Theme.Text.caption).foregroundStyle(Theme.inkSoft)
                    }
                    Spacer()
                    if let coupling = risk.coupling {
                        Text("\(risk.couplingRows.count.formatted()) pairs"
                             + (preferences.advanced ? " · \(coupling.pairingCommits) commits paired, \(coupling.skippedCommits) sweeps skipped" : ""))
                            .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                    }
                }
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.top, Theme.Space.xl)
            .padding(.bottom, Theme.Space.l)

            if risk.couplingViewMode == .graph {
                graph
                    .padding(.horizontal, Theme.Space.xl)
                    .padding(.bottom, Theme.Space.xl)
            } else {
            ScrollColumn {
                LazyVStack(spacing: Theme.Space.s) {
                    ForEach(risk.couplingRows.prefix(300)) { row in
                        CouplingCard(row: row, selected: navigation.selectedPairID == row.id) {
                            navigation.selectedPairID = row.id
                        }
                    }
                    if risk.couplingRows.isEmpty {
                        Text("No pairs in this scope. Try “Across files” or “All”.")
                            .font(Theme.Text.body).foregroundStyle(Theme.inkMuted).padding(.top, Theme.Space.xl)
                    }
                }
                .padding(.horizontal, Theme.Space.xl)
                .padding(.bottom, Theme.Space.xxl)
                .frame(maxWidth: 1180, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            }
        }
    }

    @ViewBuilder
    private var graph: some View {
        @Bindable var navigation = navigation
        if let graph = risk.graph, !graph.nodes.isEmpty {
            CouplingGraphView(
                graph: graph,
                positions: risk.graphPositions,
                layingOut: risk.graphLayoutInProgress,
                level: { risk.rowsByID[$0]?.level },
                location: { risk.rowsByID[$0]?.location },
                selectedUnitID: $navigation.selectedUnitID,
                selectedPairID: $navigation.selectedPairID
            )
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.hairline))
        } else {
            Text("No pairs in this scope to draw.").font(Theme.Text.body).foregroundStyle(Theme.inkMuted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct CouplingCard: View {
    let row: CouplingRow
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: Theme.Space.l) {
                VStack(alignment: .leading, spacing: 6) {
                    unitLine(row.nameA, row.locationA)
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.arrow.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.accent)
                        Text(row.sentence).font(Theme.Text.caption).foregroundStyle(Theme.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    unitLine(row.nameB, row.locationB)
                }
                Spacer(minLength: Theme.Space.m)
                VStack(alignment: .trailing, spacing: 6) {
                    if row.crossDirectory { Chip(text: "different folders", tint: Theme.serious) }
                    else if row.pair.crossFile { Chip(text: "different files") }
                    else { Chip(text: "same file") }
                    Text("last \(RiskExplanation.relative(row.lastShared, now: Date()))")
                        .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                }
                .fixedSize()
            }
            .padding(Theme.Space.l)
            .background(selected ? Theme.accentWash : (hovering ? Theme.wash : Theme.surface),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(selected ? Theme.accent.opacity(0.5) : Theme.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private func unitLine(_ name: String, _ location: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name).font(Theme.Text.bodyBold).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
            Text(location).font(Theme.Text.caption).foregroundStyle(Theme.inkMuted).lineLimit(1).truncationMode(.head)
        }
    }
}

struct PairDetailPanel: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(RiskStore.self) private var risk
    @Environment(NavigationStore.self) private var navigation
    let row: CouplingRow

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack {
                    Chip(text: row.crossDirectory ? "different folders" : (row.pair.crossFile ? "different files" : "same file"),
                         tint: row.crossDirectory ? Theme.serious : Theme.inkSoft)
                    Spacer()
                    Button { navigation.selectedPairID = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.inkMuted)
                            .padding(6).background(Theme.wash, in: Circle())
                    }.buttonStyle(.plain)
                }
                Text("These two change together").font(Theme.Text.title).foregroundStyle(Theme.ink)
                Text(row.sentence).font(Theme.Text.body).foregroundStyle(Theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Space.l).padding(.top, Theme.Space.xl)
            .background(Theme.raised)
            .overlay(alignment: .bottom) { HairlineDivider() }

            ScrollColumn {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    unitCard(id: row.pair.a, name: row.nameA, location: row.locationA)
                    unitCard(id: row.pair.b, name: row.nameB, location: row.locationB)
                    if let churn = risk.churn, let coupling = risk.coupling {
                        let shared = coupling.sharedCommits(of: row.pair, in: churn)
                        let sweeps = coupling.sweepSharedCommits(of: row.pair, in: churn)
                        Card(padding: Theme.Space.m) {
                            VStack(alignment: .leading, spacing: Theme.Space.s) {
                                CardHeader(title: "Shared commits", subtitle: "\(shared.count)")
                                if !sweeps.isEmpty {
                                    Text("\(sweeps.count) more commit\(sweeps.count == 1 ? "" : "s") touched both but changed "
                                         + "so much of the project (formatting, renames) that they are not counted.")
                                        .font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                VStack(spacing: 0) {
                                    ForEach(shared, id: \.sha) { commit in
                                        CommitLine(commit: commit, point: nil, historyLoaded: false)
                                        if commit.sha != shared.last?.sha { HairlineDivider() }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(Theme.Space.l)
            }
        }
        .background(Theme.surface)
    }

    private func unitCard(id: UUID, name: String, location: String) -> some View {
        let unitRow = risk.rowsByID[id]
        return Button {
            session.show(.hotspots)
            navigation.selectedPairID = nil
            navigation.selectedUnitID = id
        } label: {
            HStack(spacing: Theme.Space.m) {
                if let unitRow { RiskBadge(level: unitRow.level, compact: true) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(Theme.Text.bodyBold).foregroundStyle(Theme.ink).lineLimit(2).truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(location).font(Theme.Text.caption).foregroundStyle(Theme.inkMuted).lineLimit(1).truncationMode(.head)
                }
                Spacer(minLength: Theme.Space.s)
                if let unitRow {
                    MiniStat(value: "\(unitRow.complexity)", label: "cx")
                    MiniStat(value: "\(unitRow.commitCount)", label: "commits")
                }
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.inkMuted)
            }
            .padding(Theme.Space.m)
            .background(Theme.page, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open this function in Hotspots")
    }
}
