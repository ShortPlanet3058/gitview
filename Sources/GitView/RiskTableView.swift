import SwiftUI
import GitViewCore

/// The expert view: every column, sortable. Shown only in Advanced mode.
struct RiskTableView: View {
    @EnvironmentObject private var model: AnalysisModel
    let rows: [RiskRow]
    @State private var sortOrder = [KeyPathComparator(\RiskRow.score, order: .reverse)]
    /// Sorted copy held in state rather than computed in `body`. Re-sorting inside `body`
    /// replaces the table's data while NSTableView is still inside the header-click
    /// delegate callback, which AppKit reports as a reentrant delegate operation.
    @State private var sortedRows: [RiskRow] = []
    @State private var topScore: Double = 0

    var body: some View {
        Table(sortedRows, selection: $model.selectedUnitID, sortOrder: $sortOrder) {
            TableColumn("Level", value: \.level.rawValue) { row in
                RiskBadge(level: row.level, compact: true)
            }
            .width(min: 84, ideal: 92, max: 110)

            TableColumn("Score", value: \.score) { row in
                Text(row.score, format: .number.precision(.fractionLength(2)))
                    .monospacedDigit()
                    .fontWeight(.semibold)
                    .foregroundStyle(scoreColor(row.score))
            }
            .width(min: 56, ideal: 64, max: 80)

            TableColumn("Unit", value: \.name) { row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(row.location)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .help("\(row.name)\n\(row.location)")
            }
            .width(min: 200, ideal: 380)

            TableColumn("Kind", value: \.kind.rawValue) { row in
                Text(row.kind.rawValue)
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 70, max: 90)

            TableColumn("Complexity", value: \.complexity) { row in
                Text(row.complexity, format: .number).monospacedDigit()
            }
            .width(min: 70, ideal: 84, max: 100)

            TableColumn("Recency", value: \.recency) { row in
                Text(row.recency, format: .number.precision(.fractionLength(2)))
                    .monospacedDigit()
                    .help("Sum of exponentially decayed commit weights. A commit made "
                          + "today contributes 1.0.")
            }
            .width(min: 60, ideal: 72, max: 90)

            TableColumn("Commits", value: \.commitCount) { row in
                Text(row.commitCount, format: .number).monospacedDigit()
            }
            .width(min: 60, ideal: 70, max: 90)

            TableColumn("Authors", value: \.authorCount) { row in
                Text(row.authorCount, format: .number).monospacedDigit()
            }
            .width(min: 60, ideal: 70, max: 90)

            TableColumn("Last touched", value: \.lastTouchedSortKey) { row in
                if let date = row.lastTouched {
                    Text(date, format: .dateTime.year().month(.abbreviated).day())
                        .monospacedDigit()
                        .foregroundStyle(ageStyle(date))
                } else {
                    Text("–").foregroundStyle(.tertiary)
                }
            }
            .width(min: 96, ideal: 110, max: 130)

            TableColumn("Lines", value: \.lineCount) { row in
                Text(row.lineCount, format: .number).monospacedDigit()
            }
            .width(min: 50, ideal: 56, max: 70)
        }
        .onAppear(perform: resort)
        .onChange(of: sortOrder) { _ in resort() }
        .onChange(of: rows) { _ in resort() }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.hairline))
        .overlay {
            if rows.isEmpty {
                Text(model.searchText.isEmpty
                     ? "No units match the current filters."
                     : "No units match “\(model.searchText)”.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func resort() {
        sortedRows = rows.sorted(using: sortOrder)
        topScore = rows.map(\.score).max() ?? 0
    }

    /// Scores are relative, so colour is relative to the top of the current table rather
    /// than to any absolute threshold.
    private func scoreColor(_ score: Double) -> Color {
        guard topScore > 0 else { return .primary }
        let ratio = score / topScore
        if ratio > 0.8 { return .red }
        if ratio > 0.55 { return .orange }
        return .primary
    }

    private func ageStyle(_ date: Date) -> Color {
        let days = Date().timeIntervalSince(date) / 86_400
        return days < 90 ? .primary : .secondary
    }
}
