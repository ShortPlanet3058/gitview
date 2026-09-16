import SwiftUI
import Charts
import GitViewCore

struct ActivityScreen: View {
    @EnvironmentObject private var model: AnalysisModel
    @State private var range: ActivityRange = .twoYears

    var body: some View {
        if let analysis = model.analysis {
            let now = Date()
            let (from, granularity): (Date, ActivitySeries.Granularity) = {
                switch range {
                case .sixMonths: return (now.addingTimeInterval(-182 * 86_400), .week)
                case .year: return (now.addingTimeInterval(-365 * 86_400), .week)
                case .twoYears: return (now.addingTimeInterval(-730 * 86_400), .month)
                case .all: return (analysis.commits.map(\.date).min() ?? now, .month)
                }
            }()
            let buckets = ActivitySeries.buckets(commits: analysis.commits, granularity: granularity, from: from, to: now)
            let inRange = analysis.commits.filter { $0.date >= from }
            Page {
                HStack(alignment: .top) {
                    ScreenHeader(title: "Activity", subtitle: "How work on this repository is distributed over time.")
                    Spacer()
                    Picker("", selection: $range) { ForEach(ActivityRange.allCases) { Text($0.rawValue).tag($0) } }
                        .labelsHidden().frame(width: 150)
                }
                HStack(spacing: Theme.Space.m) {
                    StatCard(icon: "clock.arrow.circlepath", tint: .blue, value: inRange.count.formatted(), label: "Commits in range")
                    StatCard(icon: "person.2.fill", tint: .aqua, value: Set(inRange.map(\.author)).count.formatted(), label: "People active")
                    StatCard(icon: "calendar", tint: .yellow,
                             value: buckets.isEmpty ? "—" : String(format: "%.1f", Double(inRange.count) / Double(max(buckets.count, 1))),
                             label: granularity == .week ? "Commits per week" : "Commits per month")
                    StatCard(icon: "doc.badge.clock", tint: .orange,
                             value: Set(inRange.flatMap { $0.fileChanges.map(\.path) }).count.formatted(), label: "Files touched")
                }
                Card {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        CardHeader(title: "Commits over time", subtitle: granularity == .week ? "per week" : "per month")
                        ActivityBars(buckets: buckets, granularity: granularity).frame(height: 170)
                    }
                }
                HStack(alignment: .top, spacing: Theme.Space.l) {
                    Card {
                        VStack(alignment: .leading, spacing: Theme.Space.m) {
                            CardHeader(title: "People active over time", subtitle: "distinct authors",
                                       info: "How many different people committed in each period. A shrinking line "
                                           + "while commits stay flat means the work is concentrating on fewer people.")
                            Chart(buckets) { bucket in
                                BarMark(x: .value("Period", bucket.start, unit: granularity == .week ? .weekOfYear : .month),
                                        y: .value("People", bucket.authors), width: .ratio(0.65))
                                    .foregroundStyle(Theme.tint(.aqua)).cornerRadius(2)
                            }
                            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                                AxisValueLabel(format: .dateTime.month(.abbreviated).year(.twoDigits)).foregroundStyle(Theme.inkMuted) } }
                            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                                AxisGridLine().foregroundStyle(Theme.gridline); AxisValueLabel().foregroundStyle(Theme.inkMuted) } }
                            .frame(height: 150)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    Card {
                        VStack(alignment: .leading, spacing: Theme.Space.m) {
                            CardHeader(title: "Busiest days", subtitle: "commits by weekday")
                            WeekdayBars(commits: inRange).frame(height: 150)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                TopChangedFilesCard(commits: analysis.commits)
            }
        }
    }
}

struct WeekdayBars: View {
    let commits: [Commit]
    private struct Day: Identifiable { let id: Int; let name: String; let count: Int }
    private var days: [Day] {
        let calendar = Calendar.current
        var counts = [Int](repeating: 0, count: 7)
        for commit in commits { counts[calendar.component(.weekday, from: commit.date) - 1] += 1 }
        let symbols = calendar.shortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return (0..<7).map { offset in
            let index = (first + offset) % 7
            return Day(id: offset, name: symbols[index], count: counts[index])
        }
    }
    var body: some View {
        Chart(days) { day in
            BarMark(x: .value("Day", day.name), y: .value("Commits", day.count), width: .ratio(0.6))
                .foregroundStyle(Theme.accent).cornerRadius(3)
        }
        .chartXAxis { AxisMarks { _ in AxisValueLabel().foregroundStyle(Theme.inkMuted) } }
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
            AxisGridLine().foregroundStyle(Theme.gridline); AxisValueLabel().foregroundStyle(Theme.inkMuted) } }
    }
}
