import SwiftUI
import GitViewCore

struct HotspotsScreen: View {
    @EnvironmentObject private var model: AnalysisModel
    @State private var levelFilter: RiskLevel? = nil

    private var shown: [RiskRow] {
        guard let levelFilter else { return model.rows }
        return model.rows.filter { $0.level == levelFilter }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                ScreenHeader(title: "Hotspots",
                             subtitle: "Functions ranked by how complex they are and how much they've changed in \(model.recentWindowLabel).")
                controls
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.top, Theme.Space.xl)
            .padding(.bottom, Theme.Space.l)

            if model.advanced {
                RiskTableView(rows: shown)
                    .padding(.horizontal, Theme.Space.xl)
                    .padding(.bottom, Theme.Space.xl)
            } else {
                ScrollColumn {
                    LazyVStack(spacing: Theme.Space.s) {
                        ForEach(shown) { row in
                            HotspotCard(row: row, compact: false, selected: model.selectedUnitID == row.id) {
                                model.selectedUnitID = row.id
                            }
                        }
                        if shown.isEmpty {
                            Text(model.searchText.isEmpty ? "Nothing matches these filters." : "Nothing matches “\(model.searchText)”.")
                                .font(Theme.Text.body).foregroundStyle(Theme.inkMuted).padding(.top, Theme.Space.xl)
                        }
                    }
                    .padding(.horizontal, Theme.Space.xxl)
                    .padding(.bottom, Theme.Space.xxl)
                    .frame(maxWidth: 980, alignment: .leading)
                }
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m) {
                SearchField(text: $model.searchText, prompt: "Find a function or file")
                    .frame(maxWidth: 320)
                SegmentPicker(options: AnalysisModel.KindFilter.allCases.map { ($0, $0.rawValue) },
                              selection: $model.kindFilter)
                Spacer()
                Text("\(shown.count.formatted()) shown").font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
            }
            HStack(spacing: Theme.Space.s) {
                LevelChip(level: nil, count: model.rows.count, selected: levelFilter == nil) { levelFilter = nil }
                ForEach(RiskLevel.allCases.reversed(), id: \.self) { level in
                    if let count = model.levelCounts[level], count > 0 {
                        LevelChip(level: level, count: count, selected: levelFilter == level) {
                            levelFilter = levelFilter == level ? nil : level
                        }
                    }
                }
                if model.advanced {
                    Spacer()
                    Toggle("Include tests", isOn: Binding(get: { !model.excludeTests }, set: { model.excludeTests = !$0 }))
                        .toggleStyle(.checkbox).font(Theme.Text.caption).foregroundStyle(Theme.inkSoft)
                    Stepper("Min commits: \(model.minimumCommits)", value: $model.minimumCommits, in: 1...25)
                        .font(Theme.Text.caption).foregroundStyle(Theme.inkSoft)
                }
            }
        }
    }
}

struct LevelChip: View {
    let level: RiskLevel?
    let count: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let level {
                    Image(systemName: level.symbolName).font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.color(for: level))
                }
                Text(level?.label ?? "All").font(.system(size: 11, weight: selected ? .semibold : .medium))
                Text(count.formatted()).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.inkMuted)
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(selected ? Theme.raised : Theme.wash,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(selected ? Theme.hairline : .clear))
        }
        .buttonStyle(.plain)
    }
}

struct SearchField: View {
    @Binding var text: String
    let prompt: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.inkMuted)
            TextField(prompt, text: $text).textFieldStyle(.plain).font(Theme.Text.body)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.inkMuted)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.hairline))
    }
}

/// One hotspot, readable without knowing any metric.
struct HotspotCard: View {
    let row: RiskRow
    let compact: Bool
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                RiskBadge(level: row.level, compact: true)
                    .frame(width: 84, alignment: .leading)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.name).font(Theme.Text.bodyBold).foregroundStyle(Theme.ink)
                        .lineLimit(1).truncationMode(.middle)
                    Text(row.location).font(Theme.Text.caption).foregroundStyle(Theme.inkMuted)
                        .lineLimit(1).truncationMode(.head)
                    if !compact {
                        Text(row.explanation.reasons.prefix(2).joined(separator: " "))
                            .font(Theme.Text.caption).foregroundStyle(Theme.inkSoft)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: Theme.Space.m)
                HStack(spacing: Theme.Space.l) {
                    MiniStat(value: "\(row.complexity)", label: "complexity")
                    MiniStat(value: "\(row.recentCommits)", label: "changes")
                    MiniStat(value: "\(row.authorCount)", label: row.authorCount == 1 ? "person" : "people")
                }
                .fixedSize()
            }
            .padding(compact ? Theme.Space.m : Theme.Space.l)
            .background(selected ? Theme.accentWash : (hovering ? Theme.wash : Theme.surface),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(selected ? Theme.accent.opacity(0.5) : Theme.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu { PathActions(path: row.filePath) }
    }
}

struct MiniStat: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value).font(Theme.Text.bodyBold.monospacedDigit()).foregroundStyle(Theme.ink)
            Text(label).font(.system(size: 10)).foregroundStyle(Theme.inkMuted)
        }
    }
}
