import XCTest
@testable import GitViewCore

final class InlineWordDiffTests: XCTestCase {

    private func slice(_ text: String, _ range: Range<Int>) -> String? {
        let utf16 = text.utf16
        guard range.lowerBound >= 0, range.upperBound <= utf16.count else { return nil }
        let s = utf16.index(utf16.startIndex, offsetBy: range.lowerBound)
        let e = utf16.index(utf16.startIndex, offsetBy: range.upperBound)
        guard let si = String.Index(s, within: text), let ei = String.Index(e, within: text) else {
            return nil
        }
        return String(text[si..<ei])
    }

    func testHighlightsMultipleDisjointTokenEditsSeparately() {
        let old = "let count = compute(alpha, stableMiddleValue, beta)"
        let new = "var count = compute(gamma, stableMiddleValue, delta)"
        let diff = InlineWordDiff.changedUTF16Ranges(old: old, new: new)

        let oldPieces = diff.old.compactMap { slice(old, $0) }
        let newPieces = diff.new.compactMap { slice(new, $0) }
        XCTAssertEqual(oldPieces, ["let", "alpha", "beta"])
        XCTAssertEqual(newPieces, ["var", "gamma", "delta"])
    }

    func testUnrelatedLinesProduceNoNoiseHighlight() {
        let diff = InlineWordDiff.changedUTF16Ranges(old: "Completely different one", new: "Another thing altogether")
        XCTAssertTrue(diff.old.isEmpty)
        XCTAssertTrue(diff.new.isEmpty)
    }

    func testSurrogatePairEmojiIsNeverSplit() {
        let old = "status = \"🚀 ready\" + count"
        let new = "status = \"🚀 done\" + total"
        let diff = InlineWordDiff.changedUTF16Ranges(old: old, new: new)

        for r in diff.old { XCTAssertNotNil(slice(old, r)) }
        for r in diff.new { XCTAssertNotNil(slice(new, r)) }
        XCTAssertEqual(diff.old.compactMap { slice(old, $0) }, ["ready", "count"])
        XCTAssertEqual(diff.new.compactMap { slice(new, $0) }, ["done", "total"])
    }
}
