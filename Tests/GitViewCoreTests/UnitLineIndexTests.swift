import XCTest
@testable import GitViewCore

private func makeUnit(_ name: String, _ range: ClosedRange<Int>, path: String = "A.swift") -> CodeUnit {
    CodeUnit(filePath: path, name: name, kind: .function, lineRange: range,
             complexity: 1, nestingDepth: 0, lineCount: range.count)
}

final class UnitLineIndexTests: XCTestCase {

    private func names(_ units: [CodeUnit], _ index: UnitLineIndex, _ range: ClosedRange<Int>) -> Set<String> {
        let byID = Dictionary(uniqueKeysWithValues: units.map { ($0.id, $0.name) })
        return Set(index.units(overlapping: range).map { byID[$0]! })
    }

    // MARK: - Boundary conditions

    func testOverlapAtEachBoundary() {
        let units = [makeUnit("f", 10...20)]
        let index = UnitLineIndex(units: units)

        XCTAssertEqual(names(units, index, 9...9), [], "line directly before must not match")
        XCTAssertEqual(names(units, index, 10...10), ["f"], "first line must match")
        XCTAssertEqual(names(units, index, 15...15), ["f"], "interior line must match")
        XCTAssertEqual(names(units, index, 20...20), ["f"], "last line must match")
        XCTAssertEqual(names(units, index, 21...21), [], "line directly after must not match")
    }

    func testRangeStraddlingEachEdge() {
        let units = [makeUnit("f", 10...20)]
        let index = UnitLineIndex(units: units)

        XCTAssertEqual(names(units, index, 5...10), ["f"], "ends exactly on first line")
        XCTAssertEqual(names(units, index, 5...9), [], "ends one short of first line")
        XCTAssertEqual(names(units, index, 20...30), ["f"], "starts exactly on last line")
        XCTAssertEqual(names(units, index, 21...30), [], "starts one past last line")
        XCTAssertEqual(names(units, index, 1...100), ["f"], "fully containing range")
    }

    func testAdjacentUnitsDoNotBleed() {
        let units = [makeUnit("a", 1...10), makeUnit("b", 11...20)]
        let index = UnitLineIndex(units: units)

        XCTAssertEqual(names(units, index, 10...10), ["a"])
        XCTAssertEqual(names(units, index, 11...11), ["b"])
        XCTAssertEqual(names(units, index, 10...11), ["a", "b"])
    }

    // MARK: - Nesting

    func testNestedUnitsBothMatch() {
        // A type encloses its methods; a hunk inside a method touches both.
        let units = [makeUnit("Type", 1...100), makeUnit("method", 40...50)]
        let index = UnitLineIndex(units: units)

        XCTAssertEqual(names(units, index, 45...45), ["Type", "method"])
        XCTAssertEqual(names(units, index, 5...5), ["Type"])
    }

    func testEarlyStartingWideUnitIsNotMissed() {
        // The regression the running-max guards against: a long type sorts first, so a
        // naive "stop at the first non-overlapping unit" scan would skip past it.
        let units = [
            makeUnit("Wide", 1...1000),
            makeUnit("a", 10...20),
            makeUnit("b", 30...40),
            makeUnit("c", 50...60),
        ]
        let index = UnitLineIndex(units: units)
        XCTAssertEqual(names(units, index, 900...900), ["Wide"])
        XCTAssertEqual(names(units, index, 55...55), ["Wide", "c"])
    }

    func testIdenticalRanges() {
        let units = [makeUnit("a", 5...10), makeUnit("b", 5...10)]
        let index = UnitLineIndex(units: units)
        XCTAssertEqual(names(units, index, 7...7), ["a", "b"])
    }

    // MARK: - Degenerate input

    func testEmptyIndexReturnsNothing() {
        XCTAssertEqual(UnitLineIndex(units: []).units(overlapping: 1...10), [])
    }

    func testQueryFarBeyondEndOfFile() {
        let units = [makeUnit("f", 1...10)]
        XCTAssertEqual(names(units, UnitLineIndex(units: units), 5000...5001), [])
    }

    func testBufferIsAppendedToNotReplaced() {
        let units = [makeUnit("f", 1...10)]
        let index = UnitLineIndex(units: units)
        var buffer: [UUID] = [UUID()]
        index.units(overlapping: 5...5, into: &buffer)
        XCTAssertEqual(buffer.count, 2, "existing contents must be preserved")
    }

    // MARK: - Agreement with brute force

    func testMatchesBruteForceOnRandomInput() {
        // The index is an optimisation; it must agree exactly with the obvious O(n) answer.
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let units = (0..<Int.random(in: 0...40, using: &generator)).map { i -> CodeUnit in
                let start = Int.random(in: 1...200, using: &generator)
                let length = Int.random(in: 0...60, using: &generator)
                return makeUnit("u\(i)", start...(start + length))
            }
            let index = UnitLineIndex(units: units)
            for _ in 0..<20 {
                let qs = Int.random(in: 1...260, using: &generator)
                let qe = qs + Int.random(in: 0...20, using: &generator)
                let expected = Set(units.filter { $0.lineRange.overlaps(qs...qe) }.map(\.id))
                XCTAssertEqual(Set(index.units(overlapping: qs...qe)), expected)
            }
        }
    }
}
