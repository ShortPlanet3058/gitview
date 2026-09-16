import Foundation
import GitViewCore

/// Flattened view of a `RiskedUnit`.
///
/// Flat because `Table` sorts through `KeyPathComparator`, and comparators over nested
/// key paths make every column declaration noisier for no benefit.
struct RiskRow: Identifiable, Hashable {
    let id: UUID
    let name: String
    let filePath: String
    let fileName: String
    let kind: CodeUnit.Kind
    let lineRange: ClosedRange<Int>
    let score: Double
    let complexity: Int
    let nestingDepth: Int
    let lineCount: Int
    let recency: Double
    let commitCount: Int
    let authorCount: Int
    let lastTouched: Date?

    init(_ risked: RiskedUnit) {
        let unit = risked.unit
        self.id = unit.id
        self.name = unit.name
        self.filePath = unit.filePath
        self.fileName = String(unit.filePath.split(separator: "/").last ?? "")
        self.kind = unit.kind
        self.lineRange = unit.lineRange
        self.score = risked.score
        self.complexity = unit.complexity
        self.nestingDepth = unit.nestingDepth
        self.lineCount = unit.lineCount
        self.recency = risked.recency
        self.commitCount = risked.commitCount
        self.authorCount = risked.authorCount
        self.lastTouched = risked.lastTouched
    }

    var location: String { "\(filePath):\(lineRange.lowerBound)" }
    /// Sorts undated rows last regardless of direction, rather than to 1970.
    var lastTouchedSortKey: Date { lastTouched ?? .distantPast }
}
