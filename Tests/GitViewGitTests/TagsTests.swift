import XCTest
@testable import GitViewGit

final class TagParserTests: XCTestCase {
    private func record(_ fields: [String]) -> String { fields.joined(separator: "\u{1F}") }

    /// swift-nio's tags are all lightweight: `objecttype` is `commit`, the peeled field is
    /// empty, there is no tagger, and what looks like a tag message is the commit's subject.
    func testLightweightTag() throws {
        let output = record(["2.102.0", "commit", "a931f2c1de8d", "", "2026-08-28T13:38:09Z", "",
                             "docs: Document that ByteBuffer is a value type (#3676)"])
        let tag = try XCTUnwrap(TagParser.parse(output).first)
        XCTAssertEqual(tag.name, "2.102.0")
        XCTAssertEqual(tag.commitSHA, "a931f2c1de8d", "the object id is the commit for a lightweight tag")
        XCTAssertFalse(tag.isAnnotated)
        XCTAssertNil(tag.taggerName)
        XCTAssertEqual(tag.subject, "docs: Document that ByteBuffer is a value type (#3676)")
    }

    /// An annotated tag's own object id is not a commit — the peeled field is.
    func testAnnotatedTagPeelsToItsCommit() throws {
        let output = record(["v1.0.0", "tag", "tagobject111", "commitsha222", "2024-01-01T00:00:00Z",
                             "Release Manager", "Version 1.0.0"])
        let tag = try XCTUnwrap(TagParser.parse(output).first)
        XCTAssertTrue(tag.isAnnotated)
        XCTAssertEqual(tag.commitSHA, "commitsha222")
        XCTAssertEqual(tag.taggerName, "Release Manager")
        XCTAssertEqual(tag.subject, "Version 1.0.0")
    }

    func testMultipleAndMalformed() {
        let output = [
            record(["a", "commit", "111", "", "2024-01-02T00:00:00Z", "", "first"]),
            "not a tag record",
            record(["b", "commit", "222", "", "2024-01-01T00:00:00Z", "", "second"]),
        ].joined(separator: "\n")
        XCTAssertEqual(TagParser.parse(output).map(\.name), ["a", "b"])
    }

    func testSubjectMayContainTheSeparatorlessColonsAndPipes() throws {
        let output = record(["v2", "commit", "111", "", "2024-01-01T00:00:00Z", "", "fix: a|b: done"])
        XCTAssertEqual(try XCTUnwrap(TagParser.parse(output).first).subject, "fix: a|b: done")
    }

    func testEmptyOutput() { XCTAssertTrue(TagParser.parse("").isEmpty) }
}

final class DiffStatParserTests: XCTestCase {
    /// Real `git diff --numstat -z` bytes. A rename is the counts, then an *empty* path
    /// field, then the old and new paths as two further records — which is why this is
    /// captured rather than imagined.
    func testRealNumstatIncludingRenameAndBinary() {
        let output = "1\t1\tdata.bin\0" + "1\t0\tkeep.txt\0" + "0\t0\t\0move-me.txt\0moved.txt\0"
        let deltas = DiffStatParser.parseNumstat(output)
        XCTAssertEqual(deltas.count, 3)

        let byPath = Dictionary(uniqueKeysWithValues: deltas.map { ($0.path, $0) })
        XCTAssertEqual(byPath["data.bin"]?.insertions, 1)
        XCTAssertEqual(byPath["keep.txt"]?.insertions, 1)
        XCTAssertEqual(byPath["keep.txt"]?.deletions, 0)
        XCTAssertNotNil(byPath["moved.txt"], "a rename is reported under its new name")
        XCTAssertNil(byPath["move-me.txt"], "and not also under the old one")
    }

    func testBinaryFilesReportDashes() {
        let deltas = DiffStatParser.parseNumstat("-\t-\treal.bin\0")
        XCTAssertEqual(deltas.count, 1)
        XCTAssertTrue(deltas[0].isBinary)
        XCTAssertEqual(deltas[0].insertions, 0, "a dash is not a line count")
        XCTAssertEqual(deltas[0].churn, 0)
    }

    func testSortedByChurn() {
        let output = "1\t1\tsmall.txt\0" + "50\t20\tbig.txt\0" + "5\t0\tmid.txt\0"
        XCTAssertEqual(DiffStatParser.parseNumstat(output).map(\.path), ["big.txt", "mid.txt", "small.txt"])
    }

    func testPathsWithSpaces() {
        let deltas = DiffStatParser.parseNumstat("2\t3\tSources/with space.swift\0")
        XCTAssertEqual(deltas.first?.path, "Sources/with space.swift")
    }

    func testEmptyAndGarbage() {
        XCTAssertTrue(DiffStatParser.parseNumstat("").isEmpty)
        XCTAssertNoThrow(DiffStatParser.parseNumstat("nonsense\0\0"))
    }
}
