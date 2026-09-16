import XCTest
@testable import GitViewGit
import GitViewCore

final class HunkHeaderParserTests: XCTestCase {

    func testStandardHeader() {
        let hunk = HunkHeaderParser.parse("@@ -12,3 +14,5 @@")
        XCTAssertEqual(hunk?.newStart, 14)
        XCTAssertEqual(hunk?.newLineCount, 5)
    }

    func testOmittedCountsDefaultToOne() {
        // "@@ -3 +7 @@" means one line on each side.
        let hunk = HunkHeaderParser.parse("@@ -3 +7 @@")
        XCTAssertEqual(hunk?.newStart, 7)
        XCTAssertEqual(hunk?.newLineCount, 1)
    }

    func testSectionHeadingIsIgnored() {
        let hunk = HunkHeaderParser.parse("@@ -100,0 +101,4 @@ func doSomething() -> Int {")
        XCTAssertEqual(hunk?.newStart, 101)
        XCTAssertEqual(hunk?.newLineCount, 4)
    }

    func testSectionHeadingContainingAtSigns() {
        // A heading with "@@" in it must not truncate the range scan.
        let hunk = HunkHeaderParser.parse("@@ -5,2 +6,3 @@ @@ weird @@ heading")
        XCTAssertEqual(hunk?.newStart, 6)
        XCTAssertEqual(hunk?.newLineCount, 3)
    }

    func testPureDeletionHasZeroNewLines() {
        // Deleting lines adds nothing: git reports "+start,0".
        let hunk = HunkHeaderParser.parse("@@ -42,7 +41,0 @@")
        XCTAssertEqual(hunk?.newStart, 41)
        XCTAssertEqual(hunk?.newLineCount, 0)
    }

    func testNewFileStartsAtLineOne() {
        let hunk = HunkHeaderParser.parse("@@ -0,0 +1,120 @@")
        XCTAssertEqual(hunk?.newStart, 1)
        XCTAssertEqual(hunk?.newLineCount, 120)
    }

    func testMultiDigitValues() {
        let hunk = HunkHeaderParser.parse("@@ -10234,17 +98765,4321 @@")
        XCTAssertEqual(hunk?.newStart, 98765)
        XCTAssertEqual(hunk?.newLineCount, 4321)
    }

    func testRejectsNonHunkLines() {
        XCTAssertNil(HunkHeaderParser.parse("diff --git a/x b/x"))
        XCTAssertNil(HunkHeaderParser.parse("+@@ -1,1 +1,1 @@"))
        XCTAssertNil(HunkHeaderParser.parse("@@ malformed @@"))
        XCTAssertNil(HunkHeaderParser.parse("@@ -1,1 +1,1"))   // no closing marker
        XCTAssertNil(HunkHeaderParser.parse(""))
        XCTAssertNil(HunkHeaderParser.parse("@@ "))
    }

    // MARK: - touchedLineRange

    func testTouchedRangeIsInclusiveAndExact() {
        // 5 lines starting at 14 covers 14...18, NOT 14...19.
        let hunk = Hunk(newStart: 14, newLineCount: 5)
        XCTAssertEqual(hunk.touchedLineRange, 14...18)
        XCTAssertEqual(hunk.touchedLineRange.count, 5)
    }

    func testTouchedRangeSingleLine() {
        XCTAssertEqual(Hunk(newStart: 7, newLineCount: 1).touchedLineRange, 7...7)
    }

    func testTouchedRangeForPureDeletionCollapsesToOneLine() {
        // A deletion has no new lines, but it is still churn for whichever unit
        // surrounds it, so we attribute it to the single line at newStart.
        XCTAssertEqual(Hunk(newStart: 41, newLineCount: 0).touchedLineRange, 41...41)
    }

    func testTouchedRangeClampsLineZero() {
        // "+0,0" appears when a file's entire content is deleted. Line 0 does not exist.
        XCTAssertEqual(Hunk(newStart: 0, newLineCount: 0).touchedLineRange, 1...1)
    }
}
